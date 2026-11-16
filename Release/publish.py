#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from email.utils import format_datetime
from pathlib import Path
from xml.etree import ElementTree
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parent.parent


def web_home():
    asked = os.environ.get("BROADWAY_WEB")
    if asked:
        return Path(asked).expanduser().resolve()
    for folder in (ROOT, *ROOT.parents):
        found = folder.parent / "broadway-web"
        if (found / "web").is_dir() and (found / "site").is_dir():
            return found
    return ROOT.parent / "broadway-web"


WEB_HOME = web_home()
WEB = WEB_HOME / "web"
SITE = WEB_HOME / "site"
HOME = "https://broadwaybrowser.com"
FEED_ADDRESS = f"{HOME}/appcast.xml"
BUNDLE = "com.ysmaliak.broadway"
APP = "Broadway.app"
DEFAULT_ICON = "ink"
FEED_KEY = "appcast.xml"
POINTER_KEY = "latest.json"
SPARKLE = "2.10.1"
SPARKLE_ARCHIVE = f"https://github.com/sparkle-project/Sparkle/releases/download/{SPARKLE}/Sparkle-{SPARKLE}.tar.xz"
SPARKLE_SHA256 = "1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
AGENT = "broadway-release-check"
STAGING_ADDRESS = WEB / ".staging-url"
DEPLOY = WEB_HOME / "deploy.py"
TARGETS = {
    "staging": {"base": None, "bucket": "broadway-releases-staging"},
    "production": {"base": HOME, "bucket": "broadway-releases"},
}

USAGE = """\
Publishes a Broadway release, or the site, to Cloudflare.

  ./release.sh build/Broadway.dmg --dry-run
        Check the image and write the feed it would publish into build/release/.
        Nothing is uploaded.
  ./release.sh build/Broadway.dmg
        The same, then upload to the staging Worker and check the public
        addresses. Deploy staging once first (--site-only): that records its
        address in the site repo's web/.staging-url.
  ./release.sh build/Broadway.dmg --production
        Publish for real, to broadwaybrowser.com.
  ./release.sh --site-only [--production] [--dry-run]
        Deploy the site Worker and the www redirect, and nothing else. With
        --dry-run, build both Workers and check them, and upload nothing.
  ./release.sh --unpublish BUILD [--production]
        Take a release back: the feed and /download return to the release
        before it, and its image is removed.

Without --production everything goes to staging: its own Worker and its own
bucket, so the real feed is never touched by a trial.

The site lives in its own repository, which is not public: broadway-web,
cloned beside this one or wherever BROADWAY_WEB points. It is deployed by that
repo's deploy.py, the same script its GitHub Actions workflow runs on main.
From this Mac, --site-only --production and --with-site --production deploy
only from a clean checkout of it whose HEAD is origin/main after a fetch.
Staging deploys from any tree. Without that repo, the Cloudflare account and
the Sparkle key, this script stops before it changes anything.

What is checked before anything leaves this Mac: the version is the one in
VERSION, the build number is newer than every one in the feed, the app carries
the feed address and the public key, wears the default icon, has a valid code
signature, has no /Users/ path and no development provisioning profile inside,
and the image is notarised and stapled. An image that is not notarised is
refused unless --allow-unnotarised is given.

What is uploaded, in this order: the image as releases/Broadway-VERSION-BUILD.dmg,
then appcast.xml, then the pointer /download reads. A published image is never
replaced by different bytes. Running the same command twice changes nothing.

Release notes come from Release/notes/VERSION.html.
The Sparkle key is read from ~/.config/broadway/sparkle-ed25519.key and is
never printed.
"""


class Stop(Exception):
    pass


def say(words=""):
    print(words, flush=True)


def step(words):
    say(f"\n== {words}")


def run(command, cwd=None, check=True, quiet=True):
    result = subprocess.run([str(part) for part in command], cwd=cwd, capture_output=True, text=True)
    if check and result.returncode != 0:
        tail = (result.stdout + result.stderr).strip()[-2000:]
        raise Stop(f"{Path(str(command[0])).name} failed ({result.returncode}):\n{tail}")
    if not quiet:
        say((result.stdout + result.stderr).strip())
    return result


def digest(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            hasher.update(block)
    return hasher.hexdigest()


def need_web():
    if not (WEB.is_dir() and SITE.is_dir()):
        raise Stop(
            f"the site and its Workers were not found at {WEB_HOME}: clone the site's repo, broadway-web, beside broadway-mac, "
            "or point BROADWAY_WEB at it"
        )


MISSING_KEY = "[10007] The specified key does not exist."


def private(words):
    return re.sub(r"/accounts/[0-9a-f]+", "/accounts/…", words)


def cf_binary(folder):
    return folder / "node_modules" / ".bin" / "cf"


def need_deploy():
    need_web()
    if not DEPLOY.exists():
        raise Stop(f"{WEB_HOME} has no deploy.py yet: update the web repo, or point BROADWAY_WEB at a checkout that has it")


def web_script(*arguments):
    need_deploy()
    result = subprocess.run([sys.executable, DEPLOY, *arguments])
    if result.returncode != 0:
        raise Stop(f"{' '.join(['deploy.py', *arguments])} stopped (see above)")


CF_READY = []


def need_cf():
    if not CF_READY:
        web_script("--install")
        CF_READY.append(True)


def cf(*arguments, folder=WEB):
    need_cf()
    result = run([cf_binary(folder), *arguments], cwd=folder, check=False)
    if result.returncode != 0:
        tail = private(result.stdout + result.stderr).strip()[-2000:]
        raise Stop(f"cf {' '.join(str(part) for part in arguments[:3])} failed ({result.returncode}):\n{tail}")
    return result


def missing_key(result, bucket, key):
    lines = [line.strip("│┌└ \t") for line in result.stderr.splitlines()]
    codes = re.findall(r"\[\d+\]", result.stderr)
    spellings = "|".join(re.escape(spelling) for spelling in {key, urllib.parse.quote(key, safe="")})
    address = re.compile(rf"404 Not Found · HTTP /accounts/[0-9a-f]+/r2/buckets/{re.escape(bucket)}/objects/(?:{spellings})")
    return (result.returncode == 1 and codes == ["[10007]"] and MISSING_KEY in lines
            and any(address.fullmatch(line) for line in lines))


def remote_get(bucket, key, destination):
    need_cf()
    with open(destination, "wb") as file:
        result = subprocess.run(
            [str(cf_binary(WEB)), "r2", "objects", "get", key, "--bucket-name", bucket],
            cwd=WEB, stdout=file, stderr=subprocess.PIPE, text=False,
        )
    result.stderr = result.stderr.decode("utf-8", "replace")
    if result.returncode == 0:
        return True
    Path(destination).unlink(missing_ok=True)
    if missing_key(result, bucket, key):
        return False
    raise Stop(f"could not read {key} from {bucket} ({result.returncode}):\n{private(result.stderr).strip()[-1500:]}")


def remote_put(bucket, key, source, content_type):
    result = cf("r2", "objects", "put", key, "--bucket-name", bucket, "--file", source, "--content-type", content_type)
    stored = json.loads(result.stdout)
    md5 = hashlib.md5()
    with open(source, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            md5.update(block)
    if stored.get("key") != key or str(stored.get("size")) != str(os.path.getsize(source)) or stored.get("etag") != md5.hexdigest():
        raise Stop(f"{key} in {bucket} is not what was sent: {stored}")


def remote_delete(bucket, key):
    need_cf()
    result = run([cf_binary(WEB), "r2", "objects", "delete", key, "--bucket-name", bucket, "--force"], cwd=WEB, check=False)
    if result.returncode == 0 and json.loads(result.stdout or "{}").get("key") == key:
        return
    if result.returncode == 1 and re.findall(r"\[\d+\]", result.stderr) == ["[10007]"]:
        say(f"  {key} was already gone")
        return
    raise Stop(f"could not delete {key} from {bucket} ({result.returncode}):\n{private(result.stdout + result.stderr).strip()[-1500:]}")


def sparkle_tool(name):
    places = [
        ROOT / ".build" / "artifacts" / "sparkle" / "Sparkle" / "bin",
        ROOT / ".build" / "sparkle-tools" / SPARKLE / "bin",
    ]
    for place in places:
        if (place / name).exists():
            return place / name
    say(f"fetching Sparkle {SPARKLE} tools into .build/sparkle-tools (once)")
    home = places[1].parent
    home.mkdir(parents=True, exist_ok=True)
    archive = home / "Sparkle.tar.xz"
    request = urllib.request.Request(SPARKLE_ARCHIVE, headers={"User-Agent": AGENT})
    with urllib.request.urlopen(request, timeout=120) as response, open(archive, "wb") as file:
        shutil.copyfileobj(response, file)
    if digest(archive) != SPARKLE_SHA256:
        archive.unlink()
        raise Stop(f"the Sparkle {SPARKLE} archive does not have the expected SHA-256; nothing was unpacked")
    with tarfile.open(archive) as bundle:
        members = [member for member in bundle.getmembers() if member.name.lstrip("./").startswith("bin/")]
        bundle.extractall(home, members=members, filter="data")
    archive.unlink()
    if not (places[1] / name).exists():
        raise Stop(f"{name} is not in the Sparkle {SPARKLE} archive")
    return places[1] / name


def read_key(path, what):
    path = Path(path).expanduser()
    if not path.exists():
        raise Stop(f"{what} is missing: {path}")
    return path


def sign_file(path, key_file):
    result = run([sparkle_tool("sign_update"), "-p", "--ed-key-file", key_file, path])
    signature = result.stdout.strip()
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
        raise Stop("sign_update did not answer with a signature")
    return signature


def sign_feed(path, key_file):
    run([sparkle_tool("sign_update"), "--ed-key-file", key_file, path])


def verifies(public_key, path, signature, length=None):
    command = ["swift", ROOT / "Release" / "verify.swift", public_key, path, signature]
    if length is not None:
        command.append(str(length))
    return run(command, check=False).returncode == 0


def feed_signature(path):
    data = Path(path).read_bytes()
    marker = data.rfind(b"<!-- sparkle-signatures:")
    if marker < 0:
        return None
    tail = data[marker:].decode("utf-8", "replace")
    signature = re.search(r"edSignature:\s*(\S+)", tail)
    length = re.search(r"length:\s*(\d+)", tail)
    if not signature or not length:
        return None
    return signature.group(1), int(length.group(1))


class Mounted:
    def __init__(self, image):
        self.image = image
        self.point = None

    def __enter__(self):
        self.point = tempfile.mkdtemp(prefix="broadway-release-")
        run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", self.point, self.image])
        return Path(self.point)

    def __exit__(self, *_):
        result = run(["hdiutil", "detach", self.point], check=False)
        if result.returncode != 0:
            run(["hdiutil", "detach", "-force", self.point], check=False)
        try:
            os.rmdir(self.point)
        except OSError:
            pass


def icon_pictures(path):
    data = Path(path).read_bytes()
    if data[:4] != b"icns":
        return {}
    pictures = {}
    position = 8
    while position + 8 <= len(data):
        kind = data[position:position + 4].decode("latin1")
        size = struct.unpack(">I", data[position + 4:position + 8])[0]
        if size < 8:
            break
        pictures[kind] = data[position + 8:position + size]
        position += size
    return pictures


def home_paths(app):
    pattern = re.compile(rb"/Users/(?!Shared/)[^\x00-\x20\"'<>]{1,160}")
    found = []
    for folder, _, names in os.walk(app):
        for name in names:
            path = Path(folder) / name
            if path.is_symlink() or not path.is_file():
                continue
            data = path.read_bytes()
            matches = pattern.findall(data)
            if matches:
                found.append((path.relative_to(app), len(matches), matches[0].decode("latin1")))
    return found


def signing(app):
    described = run(["codesign", "-dvv", app], check=False)
    text = described.stdout + described.stderr
    authorities = re.findall(r"^Authority=(.+)$", text, re.M)
    team = re.search(r"^TeamIdentifier=(.+)$", text, re.M)
    runtime = bool(re.search(r"flags=0x[0-9a-f]+\([^)]*runtime", text))
    if "Signature=adhoc" in text or not authorities:
        kind = "ad-hoc"
    elif authorities[0].startswith("Developer ID Application"):
        kind = "Developer ID"
    else:
        kind = authorities[0].split(":")[0]
    return {"kind": kind, "team": team.group(1) if team else "", "runtime": runtime}


def inspect(image, public_key, allow_unnotarised):
    problems = []
    facts = {}
    expected_version = (ROOT / "VERSION").read_text().strip()
    with Mounted(image) as volume:
        apps = sorted(path.name for path in volume.glob("*.app"))
        if apps != [APP]:
            raise Stop(f"the image should hold {APP} and nothing else that is an app; it holds {apps or 'no app'}")
        app = volume / APP
        link = volume / "Applications"
        if not link.is_symlink() or os.readlink(link) != "/Applications":
            problems.append("the image has no Applications shortcut to drag onto")
        if not (volume / ".DS_Store").exists() or not (volume / ".background.tiff").exists():
            problems.append("the image's window is not laid out (no background picture): build it where dmgbuild can run")
        if not (volume / ".VolumeIcon.icns").exists():
            problems.append("the volume has no icon")
        described = run(["diskutil", "info", "-plist", volume], check=False)
        try:
            volume_name = plistlib.loads(described.stdout.encode()).get("VolumeName")
        except Exception:
            volume_name = None
        if volume_name != "Broadway":
            problems.append(f"the volume is named {volume_name!r}, not Broadway")
        with open(app / "Contents" / "Info.plist", "rb") as file:
            info = plistlib.load(file)
        facts["version"] = str(info.get("CFBundleShortVersionString", ""))
        facts["build"] = str(info.get("CFBundleVersion", ""))
        facts["minimum"] = str(info.get("LSMinimumSystemVersion", ""))
        if info.get("CFBundleIdentifier") != BUNDLE:
            problems.append(f"the bundle identifier is {info.get('CFBundleIdentifier')}, not {BUNDLE}")
        if facts["version"] != expected_version:
            problems.append(f"the app says version {facts['version']}; VERSION says {expected_version}")
        if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", facts["version"]):
            problems.append(f"the version {facts['version']!r} is not numbers and dots")
        if not re.fullmatch(r"[0-9]+", facts["build"]):
            problems.append(f"the build number {facts['build']!r} is not a whole number")
        if info.get("SUFeedURL") != FEED_ADDRESS:
            problems.append(f"SUFeedURL is {info.get('SUFeedURL')!r}, not {FEED_ADDRESS}")
        if info.get("SUPublicEDKey") != public_key:
            problems.append("SUPublicEDKey is not the public key in ~/.config/broadway/sparkle-ed25519.pub")
        if info.get("CFBundleName") != "Broadway" or info.get("LSHasLocalizedDisplayName"):
            problems.append("this is a dev build: it does not go by the name Broadway")

        resources = app / "Contents" / "Resources"
        default_icon = resources / "Icons" / f"{DEFAULT_ICON}.png"
        largest = icon_pictures(resources / "AppIcon.icns").get("ic10")
        chosen = info.get("BroadwayAppIcon", DEFAULT_ICON)
        if chosen != DEFAULT_ICON or largest is None or not default_icon.exists() or largest != default_icon.read_bytes():
            problems.append(f"the app does not wear the default icon ({DEFAULT_ICON})")

        binary = app / "Contents" / "MacOS" / str(info.get("CFBundleExecutable", "Broadway"))
        facts["architectures"] = run(["lipo", "-archs", binary], check=False).stdout.split()
        if facts["architectures"] != ["arm64"]:
            problems.append(f"the binary is for {facts['architectures']}, not Apple silicon alone")

        verified = run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", app], check=False)
        if verified.returncode != 0:
            problems.append("the code signature is not valid:\n" + (verified.stdout + verified.stderr).strip()[-600:])
        facts["signing"] = signing(app)

        for path, count, first in home_paths(app)[:6]:
            problems.append(f"{path} has {count} path(s) under /Users/, the first: {first}")

        assessed = run(["spctl", "--assess", "--type", "execute", "-vv", app], check=False)
        verdict = [line.strip() for line in (assessed.stdout + assessed.stderr).splitlines() if line.strip()]
        accepted = assessed.returncode == 0 and any(line == "source=Notarized Developer ID" for line in verdict)
        source = next((line for line in verdict if line.startswith("source=")), None)
        facts["gatekeeper"] = ("accepted" if assessed.returncode == 0 else "rejected") + (f", {source}" if source else "")

        profile = app / "Contents" / "embedded.provisionprofile"
        if profile.exists():
            decoded = run(["security", "cms", "-D", "-i", profile], check=False)
            try:
                entries = plistlib.loads(decoded.stdout.encode())
            except Exception:
                entries = None
            if entries is None:
                problems.append("the embedded provisioning profile cannot be read")
            elif (
                entries.get("ProvisionedDevices")
                or not entries.get("ProvisionsAllDevices")
                or entries.get("Entitlements", {}).get("get-task-allow")
            ):
                problems.append("the embedded provisioning profile is a development one")

    facts["stapled"] = run(["xcrun", "stapler", "validate", image], check=False).returncode == 0
    facts["notarised"] = facts["stapled"] and accepted
    facts["length"] = os.path.getsize(image)
    facts["sha256"] = digest(image)

    signed = facts["signing"]
    say(f"version {facts['version']}, build {facts['build']}, macOS {facts['minimum']}+, {' '.join(facts['architectures'])}")
    say(f"image: {facts['length']:,} bytes, sha256 {facts['sha256']}")
    say(f"signed: {signed['kind']}" + (f", team {signed['team']}" if signed["team"] not in ("", "not set") else "")
        + (", hardened runtime" if signed["runtime"] else ", no hardened runtime"))
    say(f"notarised: {'yes' if facts['notarised'] else 'NO'} (ticket stapled to the image: {'yes' if facts['stapled'] else 'NO'}; "
        f"Gatekeeper on the app: {facts['gatekeeper']})")
    if not facts["notarised"]:
        warning = "this image is not notarised"
        if signed["kind"] != "Developer ID":
            warning += f" and is signed {signed['kind']}: a Mac that downloads it opens it only after Open Anyway in System Settings › Privacy & Security"
        if allow_unnotarised:
            say(f"WARNING: {warning} (--allow-unnotarised was given)")
        else:
            problems.append(f"{warning}; pass --allow-unnotarised to publish it anyway")
    if problems:
        raise Stop("the image was refused:\n" + "\n".join(f"  - {problem}" for problem in problems))
    return facts


def read_feed(path):
    if not Path(path).exists():
        return []
    root = ElementTree.parse(path).getroot()
    items = []
    for element in root.iter("item"):
        enclosure = element.find("enclosure")
        if enclosure is None:
            continue

        def text(tag):
            found = element.find(tag)
            return (found.text or "") if found is not None else ""

        items.append({
            "title": text("title"),
            "date": text("pubDate"),
            "build": text(f"{{{NAMESPACE}}}version"),
            "version": text(f"{{{NAMESPACE}}}shortVersionString"),
            "minimum": text(f"{{{NAMESPACE}}}minimumSystemVersion"),
            "hardware": text(f"{{{NAMESPACE}}}hardwareRequirements"),
            "notes": text("description"),
            "url": enclosure.get("url", ""),
            "length": enclosure.get("length", ""),
            "signature": enclosure.get(f"{{{NAMESPACE}}}edSignature", ""),
        })
    return sorted(items, key=lambda item: int(item["build"]), reverse=True)


def write_feed(items, path):
    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        f'<rss version="2.0" xmlns:sparkle="{NAMESPACE}">',
        "  <channel>",
        "    <title>Broadway</title>",
        f"    <link>{HOME}</link>",
        "    <description>Updates to Broadway, a browser for the Mac.</description>",
        "    <language>en</language>",
    ]
    for item in items:
        notes = item["notes"].strip().replace("]]>", "]]]]><![CDATA[>")
        lines += [
            "    <item>",
            f"      <title>{escape(item['title'])}</title>",
            f"      <pubDate>{escape(item['date'])}</pubDate>",
            f"      <link>{HOME}</link>",
            f"      <sparkle:version>{escape(item['build'])}</sparkle:version>",
            f"      <sparkle:shortVersionString>{escape(item['version'])}</sparkle:shortVersionString>",
            f"      <sparkle:minimumSystemVersion>{escape(item['minimum'])}</sparkle:minimumSystemVersion>",
        ]
        if item["hardware"]:
            lines.append(f"      <sparkle:hardwareRequirements>{escape(item['hardware'])}</sparkle:hardwareRequirements>")
        lines += [
            f"      <description><![CDATA[{notes}]]></description>",
            f"      <enclosure url={quoteattr(item['url'])} length={quoteattr(item['length'])}"
            f' type="application/octet-stream" sparkle:edSignature={quoteattr(item["signature"])}/>',
            "    </item>",
        ]
    lines += ["  </channel>", "</rss>", ""]
    Path(path).write_text("\n".join(lines), encoding="utf-8")


def image_name(item):
    return item["url"].rsplit("/", 1)[-1]


def write_pointer(item, path, sha256=None):
    pointer = {"version": item["version"], "build": item["build"], "file": image_name(item), "length": int(item["length"])}
    if sha256:
        pointer["sha256"] = sha256
    Path(path).write_text(json.dumps(pointer, indent=2) + "\n", encoding="utf-8")


def staging_address():
    address = os.environ.get("BROADWAY_STAGING_URL", "").strip().rstrip("/")
    if not address and STAGING_ADDRESS.exists():
        address = STAGING_ADDRESS.read_text().strip().rstrip("/")
    return address or None


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


def fetch(address, headers=None, follow=True, save=None):
    request = urllib.request.Request(address, headers={"User-Agent": AGENT, **(headers or {})})
    opener = urllib.request.build_opener() if follow else urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=180) as response:
            if save:
                with open(save, "wb") as file:
                    shutil.copyfileobj(response, file)
                body = b""
            else:
                body = response.read()
            return response.status, response.headers, body, response.geturl()
    except urllib.error.HTTPError as error:
        return error.code, error.headers, error.read(), address
    except (urllib.error.URLError, OSError) as error:
        raise Stop(f"{address} could not be reached: {getattr(error, 'reason', error)}")


def expect(condition, words, failures):
    say(f"  {'ok  ' if condition else 'FAIL'} {words}")
    if not condition:
        failures.append(words)


def check_public(target, item, image, public_key, work):
    base = target["base"]
    name = image_name(item)
    failures = []

    status, _, _, _ = fetch(f"{base}/")
    expect(status == 200, f"{base}/ answers 200 (got {status})", failures)

    status, headers, _, _ = fetch(f"{base}/download", follow=False)
    expect(status == 302 and headers.get("Location") == f"/releases/{name}",
           f"/download is a 302 to /releases/{name} (got {status} {headers.get('Location')})", failures)
    expect((headers.get("Cache-Control") or "") == "no-store",
           f"/download is never cached, so it always gives the newest ({headers.get('Cache-Control')})", failures)

    copy = work / "downloaded.dmg"
    status, headers, _, landed = fetch(f"{base}/download", save=copy)
    expect(status == 200 and landed == f"{base}/releases/{name}", f"following /download lands on {name}", failures)
    expect(copy.exists() and digest(copy) == digest(image), "the downloaded bytes hash the same as the local image", failures)
    expect(headers.get("Content-Type") == "application/x-apple-diskimage", f"content type is a disk image ({headers.get('Content-Type')})", failures)
    expect("attachment" in (headers.get("Content-Disposition") or ""), f"it downloads as a file ({headers.get('Content-Disposition')})", failures)
    expect(headers.get("Content-Length") == str(os.path.getsize(image)), f"Content-Length is the image's size ({headers.get('Content-Length')})", failures)
    expect(bool(headers.get("ETag")), f"it has an ETag ({headers.get('ETag')})", failures)
    expect("immutable" in (headers.get("Cache-Control") or ""), f"it is cached forever ({headers.get('Cache-Control')})", failures)

    size = os.path.getsize(image)
    first, last = size // 2, size // 2 + 4095
    status, headers, part, _ = fetch(f"{base}/releases/{name}", headers={"Range": f"bytes={first}-{last}"})
    with open(image, "rb") as file:
        file.seek(first)
        wanted = file.read(last - first + 1)
    expect(status == 206 and part == wanted and headers.get("Content-Range") == f"bytes {first}-{last}/{size}",
           f"a byte range comes back as 206 with the right bytes ({status}, {headers.get('Content-Range')})", failures)

    published = work / "appcast.public.xml"
    status, headers, body, _ = fetch(f"{base}/appcast.xml")
    published.write_bytes(body)
    items = []
    try:
        items = read_feed(published) if status == 200 else []
    except ElementTree.ParseError:
        pass
    expect(status == 200 and bool(items), f"the feed answers 200 and parses ({status}, {len(items)} item(s))", failures)
    if items:
        top = items[0]
        expect(top["build"] == item["build"] and top["url"] == item["url"] and top["length"] == item["length"],
               f"the feed's newest item is build {item['build']} at {item['url']}", failures)
        expect(verifies(public_key, copy, top["signature"]),
               "the feed's signature for the image verifies against the public key", failures)
    embedded = feed_signature(published)
    expect(embedded is not None and verifies(public_key, published, embedded[0], embedded[1]),
           "the feed itself is signed and verifies against the public key", failures)
    copy.unlink(missing_ok=True)
    if failures:
        raise Stop(f"{len(failures)} check(s) of the public addresses failed")


def deploy_site(name, target, dry_run=False):
    step(f"{'Checking' if dry_run else 'Deploying'} the site for {name} with broadway-web's deploy.py")
    web_script(*(["--production"] if name == "production" else []), *(["--dry-run"] if dry_run else []))
    if name == "staging":
        target["base"] = staging_address()


def publish(arguments, name, target):
    image = Path(arguments.image or ROOT / "build" / "Broadway.dmg").resolve()
    if not image.exists():
        raise Stop(f"no image at {image}; make one with ./build.sh release dmg")
    key_file = read_key(arguments.key_file, "the Sparkle private key")
    public_key = read_key(arguments.public_key_file, "the Sparkle public key").read_text().strip()
    if os.stat(key_file).st_mode & 0o077:
        raise Stop(f"{key_file} can be read by others; chmod 600 it first")

    step(f"1. Checking {image.name}")
    facts = inspect(image, public_key, arguments.allow_unnotarised)
    published_name = f"Broadway-{facts['version']}-{facts['build']}.dmg"
    notes = ROOT / "Release" / "notes" / f"{facts['version']}.html"
    if not notes.exists():
        raise Stop(f"no release notes for {facts['version']}: write {notes.relative_to(ROOT)}")

    work = ROOT / "build" / "release" / name
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    step(f"2. Signing and writing the feed ({name})")
    previous = work / "appcast.previous.xml"
    had_feed = remote_get(target["bucket"], FEED_KEY, previous)
    items = read_feed(previous)
    signature = sign_file(image, key_file)
    if not verifies(public_key, image, signature):
        raise Stop("the signature made with the private key does not verify against the public key: they are not a pair")
    same = next((item for item in items if item["build"] == facts["build"]), None)
    if same is not None and same["signature"] != signature:
        raise Stop(f"build {facts['build']} is already in the feed with a different signature: these are not the same bytes")
    newest = max((int(item["build"]) for item in items), default=0)
    if same is None and int(facts["build"]) <= newest:
        raise Stop(f"build {facts['build']} is not newer than {newest}, the newest in the feed")
    entry = {
        "title": facts["version"],
        "date": same["date"] if same else format_datetime(datetime.now(timezone.utc)),
        "build": facts["build"],
        "version": facts["version"],
        "minimum": facts["minimum"],
        "hardware": "arm64",
        "notes": notes.read_text(encoding="utf-8"),
        "url": f"{target['base']}/releases/{published_name}",
        "length": str(facts["length"]),
        "signature": signature,
    }
    items = sorted([item for item in items if item["build"] != facts["build"]] + [entry],
                   key=lambda item: int(item["build"]), reverse=True)
    feed = work / FEED_KEY
    write_feed(items, feed)
    sign_feed(feed, key_file)
    embedded = feed_signature(feed)
    if embedded is None or not verifies(public_key, feed, embedded[0], embedded[1]):
        raise Stop("the signed feed does not verify against the public key")
    pointer = work / POINTER_KEY
    write_pointer(items[0], pointer, facts["sha256"] if items[0]["build"] == facts["build"] else None)
    say(f"feed: {feed.relative_to(ROOT)} ({len(items)} item(s), newest build {items[0]['build']})")
    say(f"pointer: {pointer.relative_to(ROOT)} -> {image_name(items[0])}")
    say(f"image will be: {entry['url']}")

    if arguments.dry_run:
        say("\ndry run: nothing was uploaded")
        return

    if arguments.with_site:
        deploy_site(name, target)
    status = fetch(f"{target['base']}/")[0]
    if status != 200:
        raise Stop(f"{target['base']}/ answers {status}: deploy the site first (./release.sh --site-only"
                   + (" --production" if name == "production" else "") + "), then publish")

    step(f"3. Uploading to {target['bucket']}")
    key = f"releases/{published_name}"
    there = work / "remote.dmg"
    if remote_get(target["bucket"], key, there):
        if digest(there) != facts["sha256"]:
            raise Stop(f"{key} is already published with different bytes; a published image is never replaced")
        say(f"{key}: already there, the same bytes")
    else:
        remote_put(target["bucket"], key, image, "application/x-apple-diskimage")
        say(f"{key}: uploaded")
    there.unlink(missing_ok=True)
    if had_feed and previous.read_bytes() == feed.read_bytes():
        say(f"{FEED_KEY}: already the same")
    else:
        remote_put(target["bucket"], FEED_KEY, feed, "application/rss+xml; charset=utf-8")
        say(f"{FEED_KEY}: uploaded")
    there = work / "latest.previous.json"
    if remote_get(target["bucket"], POINTER_KEY, there) and there.read_bytes() == pointer.read_bytes():
        say(f"{POINTER_KEY}: already the same")
    else:
        remote_put(target["bucket"], POINTER_KEY, pointer, "application/json")
        say(f"{POINTER_KEY}: uploaded")

    if items[0]["build"] != facts["build"]:
        say(f"\nbuild {facts['build']} is published, but {items[0]['build']} is newer and stays the one /download gives")
        return

    step(f"4. Checking {target['base']}")
    check_public(target, entry, image, public_key, work)
    say(f"\npublished: {facts['version']} ({facts['build']}) at {target['base']}/download")


def unpublish(arguments, name, target):
    build = arguments.unpublish
    key_file = read_key(arguments.key_file, "the Sparkle private key")
    public_key = read_key(arguments.public_key_file, "the Sparkle public key").read_text().strip()
    work = ROOT / "build" / "release" / name
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)

    step(f"Taking build {build} back from {name}")
    previous = work / "appcast.previous.xml"
    if not remote_get(target["bucket"], FEED_KEY, previous):
        raise Stop("there is no feed to take anything back from")
    items = read_feed(previous)
    gone = next((item for item in items if item["build"] == build), None)
    if gone is None:
        raise Stop(f"build {build} is not in the feed; it has {', '.join(item['build'] for item in items) or 'nothing'}")
    kept = [item for item in items if item["build"] != build]
    if arguments.dry_run:
        say(f"dry run: would remove {image_name(gone)} and leave {len(kept)} item(s); nothing was changed")
        return

    feed = work / FEED_KEY
    pointer = work / POINTER_KEY
    if kept:
        write_pointer(kept[0], pointer)
        remote_put(target["bucket"], POINTER_KEY, pointer, "application/json")
        say(f"{POINTER_KEY}: now {image_name(kept[0])}")
        write_feed(kept, feed)
        sign_feed(feed, key_file)
        remote_put(target["bucket"], FEED_KEY, feed, "application/rss+xml; charset=utf-8")
        say(f"{FEED_KEY}: {len(kept)} item(s), newest build {kept[0]['build']}")
    else:
        remote_delete(target["bucket"], POINTER_KEY)
        remote_delete(target["bucket"], FEED_KEY)
        say("that was the only release: the feed and the pointer are removed")
    remote_delete(target["bucket"], f"releases/{image_name(gone)}")
    say(f"releases/{image_name(gone)}: removed")

    step(f"Checking {target['base']}")
    base = target["base"]
    failures = []
    status, _, _, _ = fetch(f"{base}/releases/{image_name(gone)}")
    expect(status == 404, f"the image is gone ({status})", failures)
    status, headers, _, _ = fetch(f"{base}/download", follow=False)
    status_feed, _, body, _ = fetch(f"{base}/appcast.xml")
    if kept:
        expect(status == 302 and headers.get("Location") == f"/releases/{image_name(kept[0])}",
               f"/download is back on {image_name(kept[0])} ({status} {headers.get('Location')})", failures)
        published = work / "appcast.public.xml"
        published.write_bytes(body)
        builds = [item["build"] for item in read_feed(published)] if status_feed == 200 else []
        expect(build not in builds and builds[:1] == [kept[0]["build"]], f"the feed's newest is build {kept[0]['build']} again", failures)
        embedded = feed_signature(published)
        expect(embedded is not None and verifies(public_key, published, embedded[0], embedded[1]),
               "the feed is signed and verifies against the public key", failures)
    else:
        expect(status == 404, f"/download answers 404 ({status})", failures)
        expect(status_feed == 404, f"the feed answers 404 ({status_feed})", failures)
    if failures:
        raise Stop(f"{len(failures)} check(s) failed after taking the release back")
    say(f"\nunpublished: build {build}")


def main():
    parser = argparse.ArgumentParser(
        prog="./release.sh", description=USAGE, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("image", nargs="?", help="the disk image to publish (default: build/Broadway.dmg)")
    parser.add_argument("--production", action="store_true", help="publish to broadwaybrowser.com instead of staging")
    parser.add_argument("--dry-run", action="store_true", help="check, sign and write the feed into build/release/; upload nothing")
    parser.add_argument("--allow-unnotarised", action="store_true", help="publish an image that is not notarised and stapled")
    parser.add_argument("--with-site", action="store_true", help="deploy the site Worker before uploading the release")
    parser.add_argument("--site-only", action="store_true", help="deploy the site Worker and the www redirect, and stop")
    parser.add_argument("--unpublish", metavar="BUILD", help="take the release with this build number back")
    parser.add_argument("--key-file", default="~/.config/broadway/sparkle-ed25519.key", help="the Sparkle private key file")
    parser.add_argument("--public-key-file", default="~/.config/broadway/sparkle-ed25519.pub", help="the Sparkle public key file")
    arguments = parser.parse_args()
    name = "production" if arguments.production else "staging"
    target = TARGETS[name]
    if name == "staging":
        target["base"] = staging_address()
    try:
        if not target["base"] and not arguments.site_only:
            raise Stop("staging's address is not known in this checkout: run ./release.sh --site-only once "
                       "(it deploys staging and remembers the address), or set BROADWAY_STAGING_URL")
        if arguments.site_only:
            if arguments.image or arguments.unpublish:
                raise Stop("--site-only takes no image and no --unpublish")
            deploy_site(name, target, arguments.dry_run)
        elif arguments.unpublish:
            unpublish(arguments, name, target)
        else:
            publish(arguments, name, target)
    except Stop as stop:
        say(f"\nstopped: {stop}")
        sys.exit(1)


if __name__ == "__main__":
    main()

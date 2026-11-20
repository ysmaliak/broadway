#!/usr/bin/env python3
import datetime
import json
import os
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PUBLIC = ROOT / "build" / "Broadway.app"
TOOLS = ROOT / ".build" / "artifacts" / "sparkle" / "Sparkle" / "bin"
SHOTS = ROOT / ".context" / "update-run"
HOME = Path.home()
BUNDLE = "com.ysmaliak.broadway.updatetest"
REAL = "com.ysmaliak.broadway"
WORLD = f"update-{os.getpid()}"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
SUPPORT = HOME / "Library" / "Application Support" / f"Broadway ({WORLD})"
SOCK = SUPPORT / "bench.sock"
SCRATCH = Path(tempfile.mkdtemp(prefix="broadway-update-")).resolve()
BUILD_ENV = Path(os.environ.get("BROADWAY_BUILD_ENV", HOME / ".config" / "broadway" / "build.env"))


def build_env(key):
    if not BUILD_ENV.is_file():
        return ""
    for line in BUILD_ENV.read_text().splitlines():
        name, _, value = line.partition("=")
        if name.strip() == key:
            return value.strip().strip('"').strip("'")
    return ""


TEAM = build_env("TEAM")

served = {}
asked = []
slow = {}
lock = threading.Lock()


class Feed(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            asked.append(self.path)
            body = served.get(self.path)
            seconds = slow.get(self.path, 0)
        if body is None:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        kind = "application/rss+xml" if self.path.endswith(".xml") else "text/html" if self.path.startswith("/page/") else "application/octet-stream"
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if not seconds:
            self.wfile.write(body)
            return
        steps = 120
        size = max(1, len(body) // steps + 1)
        for at in range(0, len(body), size):
            try:
                self.wfile.write(body[at:at + size])
                self.wfile.flush()
            except OSError:
                return
            time.sleep(seconds / steps)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Feed)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"

passed = failed = 0
notes = []
fronts = []
relaunch_fronts = []
current = [""]
relaunching = threading.Event()
watching = threading.Event()


def in_front():
    front = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    said = subprocess.run(["lsappinfo", "info", "-only", "bundleid", front], capture_output=True, text=True).stdout
    return f'"{BUNDLE}"' in said


def give_back():
    try:
        updates(behind=True)
    except OSError:
        pass
    back = wait("behind", lambda: not in_front(), within=10, every=0.25)
    ok("after Sparkle's relaunch, B gives the front back", back is not None)
    relaunching.clear()


def watch_front():
    while not watching.is_set():
        if in_front():
            (relaunch_fronts if relaunching.is_set() else fronts).append(f"{time.strftime('%H:%M:%S')} {current[0]}")
        watching.wait(0.25)


def ok(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print("  ok  ", name, flush=True)
    else:
        failed += 1
        print("  FAIL", name, extra, flush=True)


def note(text):
    notes.append(text)
    print("  note", text, flush=True)


def run(*args, **kw):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, **kw)


def team_identity():
    if not TEAM:
        return None
    listed = run("security", "find-identity", "-v", "-p", "codesigning").stdout
    for line in listed.splitlines():
        if '"Apple Development: ' not in line:
            continue
        found = line.split()[1]
        probe = SCRATCH / "identity-probe"
        shutil.copy("/usr/bin/true", probe)
        run("codesign", "--force", "--sign", found, probe)
        if f"TeamIdentifier={TEAM}" in run("codesign", "-dv", probe).stderr:
            probe.unlink()
            return found
        probe.unlink()
    return None


def make_keys():
    out = run("swift", ROOT / "Tests" / "UpdateKey.swift").stdout.split()
    secret = SCRATCH / "run.key"
    secret.write_text(out[0])
    secret.chmod(0o600)
    return secret, out[1]


def info(app):
    with open(Path(app) / "Contents" / "Info.plist", "rb") as f:
        return plistlib.load(f)


def sparkle_settings():
    text = (ROOT / "build.sh").read_text()
    found = {}
    for key, kind, value in re.findall(r"<key>(SU\w+)</key><(true|false|integer)/?>(\d*)", text):
        found[key] = int(value) if kind == "integer" else kind == "true"
    return found


def copy(name, short, build, public_key, identity, feed=None, world=True):
    folder = SCRATCH / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    app = folder / "Broadway.app"
    run("ditto", PUBLIC, app)
    path = app / "Contents" / "Info.plist"
    with open(path, "rb") as f:
        plist = plistlib.load(f)
    plist.update(sparkle_settings())
    plist.update({"CFBundleIdentifier": BUNDLE, "CFBundleShortVersionString": short, "CFBundleVersion": build,
                  "SUFeedURL": feed or f"{BASE}/appcast.xml", "SUPublicEDKey": public_key})
    if world:
        plist["BroadwayWorld"] = WORLD
    with open(path, "wb") as f:
        plistlib.dump(plist, f)
    if identity:
        signed = run(ROOT / "sign.sh", app, identity, ROOT / "Search.entitlements", "--timestamp", "--options", "runtime")
    else:
        signed = run(ROOT / "sign.sh", app, "-", "")
    if signed.returncode != 0:
        raise RuntimeError(signed.stderr)
    return app


def image(app, name, volume="Broadway"):
    stage = SCRATCH / f"stage-{name}"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir()
    run("ditto", app, stage / "Broadway.app")
    os.symlink("/Applications", stage / "Applications")
    out = SCRATCH / name
    out.unlink(missing_ok=True)
    made = run("hdiutil", "create", "-volname", volume, "-srcfolder", stage, "-ov", "-format", "UDZO", "-quiet", out)
    if made.returncode != 0:
        raise RuntimeError(made.stderr)
    shutil.rmtree(stage)
    return out


def signature(file, secret):
    return run(TOOLS / "sign_update", "--ed-key-file", secret, "-p", file).stdout.strip()


def appcast(items):
    body = ""
    for item in items:
        body += f"""
    <item>
      <title>{item['short']}</title>
      <pubDate>{datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S +0000')}</pubDate>
      <sparkle:version>{item['build']}</sparkle:version>
      <sparkle:shortVersionString>{item['short']}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>27.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<h2>Broadway {item['short']}</h2><ul><li>The release notes from the feed show here.</li><li>A second line, to see the list.</li></ul>]]></description>
      <enclosure url="{BASE}{item['path']}" sparkle:edSignature="{item['signature']}" length="{item['length']}" type="application/octet-stream"/>
    </item>"""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Broadway</title>{body}
  </channel>
</rss>
""".encode()


def serve(feed, files=None, slowly=None):
    with lock:
        served.clear()
        slow.clear()
        served["/appcast.xml"] = feed
        for path, body in (files or {}).items():
            served[path] = body
        for path in slowly or []:
            slow[path] = 8
        asked.clear()


def requests():
    with lock:
        return list(asked)


def pids(app):
    return set(run("pgrep", "-f", f"{app}/Contents/MacOS/Broadway").stdout.split())


unanswered = []


def cmd(req, timeout=20):
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    try:
        c.connect(str(SOCK))
        c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
    except TimeoutError:
        unanswered.append(c)
        raise
    except OSError:
        c.close()
        raise
    c.close()
    return json.loads(data.split(b"\n", 1)[0] or b"{}")


in_modal = False


def modal(press=None, wait=20):
    asked, said = SUPPORT / "updates.ask", SUPPORT / "updates.say"
    said.unlink(missing_ok=True)
    asked.write_text(json.dumps({"press": press} if press else {}))
    for _ in range(wait):
        time.sleep(0.2)
        if said.exists():
            try:
                answer = json.loads(said.read_text())
            except ValueError:
                continue
            said.unlink(missing_ok=True)
            return answer
    asked.unlink(missing_ok=True)
    return None


def updates(**f):
    global in_modal
    if not f and SUPPORT.exists():
        answer = modal(wait=10 if in_modal else 3)
        if answer is not None:
            in_modal = True
            return answer
        in_modal = False
    try:
        answer = cmd({"do": "updates", **f}, timeout=5)
        in_modal = False
        return answer
    except OSError:
        if f:
            raise
        answer = modal()
        if answer is None:
            raise
        in_modal = True
        return answer


def wait(what, check, within=60, every=0.5):
    until = time.time() + within
    last = None
    while time.time() < until:
        try:
            last = check()
        except (OSError, ValueError):
            last = None
        if last:
            return last
        time.sleep(every)
    return None


def launch(app, env=None):
    SOCK.unlink(missing_ok=True)
    before = pids(app)
    command = ["open", "-n", "-g"]
    for key, value in (env or {}).items():
        command += ["--env", f"{key}={value}"]
    opened = run(*command, app)
    for _ in range(3):
        if opened.returncode == 0:
            break
        note(f"open refused {Path(app).parent.name}/{Path(app).name} once ({opened.stderr.strip()[:120]}), asked again")
        time.sleep(3)
        opened = run(*command, app)
    wait("socket", lambda: SOCK.exists(), within=30, every=0.1)
    started = wait("process", lambda: pids(app) - before, within=10, every=0.2) or set()
    if not SOCK.exists():
        raise RuntimeError(f"{app} did not open its bench socket: open ended {opened.returncode} {opened.stderr.strip()!r}, "
                           f"its processes are {sorted(pids(app))}")
    wait("answer", lambda: updates().get("pid"), within=15)
    return started


def quit(app):
    try:
        cmd({"do": "quit"})
    except (OSError, ValueError):
        pass
    if wait("gone", lambda: not pids(app), within=20, every=0.3) is None:
        for pid in pids(app):
            run("kill", pid)
        wait("gone", lambda: not pids(app), within=10, every=0.3)


def idle(within=120):
    return wait("idle", lambda: updates().get("canCheck") is True and updates().get("busy") is False, within=within)


def same(ctx):
    item = {"short": "0.1", "build": ctx["old"], "path": "/releases/Broadway-0.1.dmg", "signature": ctx["item"]["signature"],
            "length": ctx["item"]["length"]}
    return appcast([item])


def window(titled=None, saying=None, within=40):
    def look():
        for w in updates().get("windows", []):
            text = " ".join([w.get("title", "")] + w.get("texts", []) + w.get("buttons", []))
            if (titled is None or titled in w.get("title", "")) and (saying is None or saying.lower() in text.lower()):
                return w
        return None
    return wait("window", look, within=within)


def shot(w, name):
    SHOTS.mkdir(parents=True, exist_ok=True)
    out = SHOTS / f"{name}.png"
    time.sleep(0.8)
    run("screencapture", "-x", "-o", f"-l{w['id']}", out)
    return out.exists()


def press(title, within=20):
    global in_modal
    if in_modal:
        answer = modal(press=title) or {}
        in_modal = False
        time.sleep(1)
        return answer.get("pressed")
    return wait("press", lambda: updates(press=title).get("pressed"), within=within)


def sparkle_defaults(domain):
    read = run("defaults", "read", domain).stdout
    return sorted({line.split("=")[0].strip().strip('"') for line in read.splitlines() if line.strip().startswith(("SU", '"SU'))})


def forget():
    for domain in (BUNDLE, SUITE):
        run("defaults", "delete", domain)
        (HOME / "Library" / "Preferences" / f"{domain}.plist").unlink(missing_ok=True)
    shutil.rmtree(SUPPORT, ignore_errors=True)
    for place in ("Caches", "HTTPStorages", "WebKit", "Saved Application State", "Application Scripts", "Containers"):
        for found in (HOME / "Library" / place).glob(f"{BUNDLE}*"):
            shutil.rmtree(found, ignore_errors=True) if found.is_dir() else found.unlink(missing_ok=True)


def fresh():
    forget()
    run("defaults", "write", SUITE, "bench", "-bool", "true")


def case_inert(ctx):
    print("inert: a build with the feed, started as a probe", flush=True)
    fresh()
    before = sparkle_defaults(REAL)
    app = copy("inert", "0.1", ctx["old"], ctx["public"], ctx["identity"], world=False)
    serve(ctx["feed"], ctx["files"])
    started = launch(app, env={"SEARCH_PROBE": WORLD})
    try:
        said = updates(check=True)
        ok("a probe of the public build has no updater", said.get("runs") is False and "feed" not in said, said)
        ok("its Broadway menu has no Check for Updates…", "Check for Updates…" not in said.get("menu", []), said.get("menu"))
        ok("its Settings line says so", said.get("line", "").endswith("This build doesn't update itself"), said.get("line"))
        time.sleep(3)
        ok("no update window came up", not updates().get("windows"), updates().get("windows"))
        ok("it never asked the feed", not requests(), requests())
    finally:
        quit(app)
    ok("the probe wrote no SU defaults of its own", sparkle_defaults(SUITE) == [], sparkle_defaults(SUITE))
    ok("the real app's SU defaults are as they were", sparkle_defaults(REAL) == before, (before, sparkle_defaults(REAL)))
    ok("the probe was this run's own process", len(started) == 1, started)


def case_current(ctx):
    print("current: Check for Updates… with nothing newer", flush=True)
    fresh()
    app = copy("current", "0.1", ctx["old"], ctx["public"], ctx["identity"])
    serve(same(ctx))
    launch(app)
    try:
        said = updates()
        ok("the copy has an updater on the local feed", said.get("runs") is True and said.get("feed") == f"{BASE}/appcast.xml", said)
        ok("its menu has Check for Updates… under About", said.get("menu", [])[:2] == ["About Broadway", "Check for Updates…"], said.get("menu"))
        ok("checks and installs are on with no question asked", said.get("checks") is True and said.get("installs") is True
           and not said.get("windows"), said)
        ok("it checks every four hours", said.get("interval") == 14400, said.get("interval"))
        first = wait("first check", lambda: "/appcast.xml" in requests(), within=120)
        ok("it asked the feed by itself on its first launch", bool(first), requests())
        idle()
        ok("finding nothing newer by itself, it shows nothing", not updates().get("windows"), updates().get("windows"))
        serve(same(ctx))
        updates(check=True)
        ok("Sparkle's own automatic downloads stay off, Broadway downloads quietly itself", said.get("sparkleDownloads") is False, said)
        w = window(saying="up to date")
        ok("Check for Updates… says it is up to date", w is not None, (updates().get("windows"), updates().get("trail")))
        if w:
            print("       ", " | ".join(w["texts"]), flush=True)
            ok("in Broadway's own alert, with the version", "Broadway is up to date" in w["texts"]
               and "Version 0.1 is the newest" in w["texts"] and w["buttons"] == ["OK"], w)
            shot(w, "1-up-to-date")
            press(w["buttons"][0])
        ok("it asked the feed", "/appcast.xml" in requests(), requests())
        line = wait("line", lambda: "Last checked today" in updates().get("line", "") and updates().get("line"), within=10)
        ok("Settings says when it last checked", bool(line), updates().get("line"))
        ok("the real app's defaults domain has nothing of this", "SUFeedURL" not in sparkle_defaults(REAL))
    finally:
        quit(app)
    ok("Sparkle's own settings went to the test copy's domain", "SULastCheckTime" in sparkle_defaults(BUNDLE), sparkle_defaults(BUNDLE))


PAGES = {f"/page/{name}": f"<!doctype html><title>Page {name.upper()}</title><p>Page {name.upper()}</p>".encode()
         for name in ("a", "b", "c", "d")}


def page(name):
    return f"{BASE}/page/{name}"


def staged(ctx, name):
    fresh()
    app = copy(name, "0.1", ctx["old"], ctx["public"], ctx["identity"])
    serve(ctx["feed"], {**ctx["files"], **PAGES}, slowly=[ctx["path"]])
    launch(app)
    old_pid = updates().get("pid")
    early = wait("found", lambda: (lambda s: s if s.get("phase") == "available" and not s.get("staged") else None)(updates()), within=240)
    ok("the card shows Update Available as soon as B is found, while B downloads quietly", early is not None
       and early.get("quiet") is True and (early.get("found") or {}).get("build") == ctx["new"], early)
    ready = wait("ready", lambda: updates().get("staged"), within=240)
    ok("A finds B by itself and stages it", ready == "Version 0.2", updates())
    return app, old_pid


def waiting_facts():
    said = updates()
    ok("nothing asked, and the card says it is waiting", not said.get("windows") and said.get("card") is True
       and said.get("staged") == "Version 0.2", said)
    return said


def installed_on_quit(ctx, app, old_pid):
    ok("A is still the old build on disk", info(app)["CFBundleVersion"] == ctx["old"])
    quit(app)
    swapped = wait("swap", lambda: info(app)["CFBundleVersion"] == ctx["new"], within=90)
    ok("after an ordinary quit, the app on disk is B", bool(swapped), info(app)["CFBundleVersion"])
    again = wait("relaunch", lambda: pids(app), within=15)
    ok("an ordinary quit leaves the app closed", not again, again)
    launch(app)
    said = wait("B", lambda: updates().get("pid") not in (None, old_pid) and updates(), within=40) or {}
    ok("the next run is B", "0.2" in said.get("version", "") and ctx["new"] in said.get("version", ""), said.get("version"))
    ok("B keeps the same world and the same place", said.get("path") == str(app) and SOCK.exists(), said.get("path"))
    ok("B is validly signed", run("codesign", "--verify", "--deep", "--strict", app).returncode == 0)
    ok("nothing waits in B and there is no card", not said.get("staged") and said.get("card") is False, said)
    return said


def relaunched(ctx, app, old_pid, short="0.2", build=None, name="B"):
    build = build or ctx["new"]
    relaunching.set()
    gone = wait("A quits", lambda: str(old_pid) not in pids(app), within=40, every=0.3)
    ok("A quits", gone is not None, pids(app))
    swapped = wait("swap", lambda: info(app)["CFBundleVersion"] == build, within=90)
    ok(f"the app on disk is {name}", bool(swapped), info(app)["CFBundleVersion"])
    again = wait("relaunch", lambda: pids(app), within=40)
    ok(f"Sparkle opens {name} by itself", bool(again), pids(app))
    if not again:
        return {}
    wait("socket", lambda: SOCK.exists(), within=30, every=0.2)
    said = wait(name, lambda: updates().get("pid") not in (None, old_pid) and updates(), within=40) or {}
    give_back()
    ok(f"the running app is {name}", short in said.get("version", "") and build in said.get("version", ""), said.get("version"))
    ok(f"{name} runs from the same place in the same world", said.get("path") == str(app), said.get("path"))
    ok(f"{name} is validly signed", run("codesign", "--verify", "--deep", "--strict", app).returncode == 0)
    ok(f"nothing waits in {name} and there is no card", not said.get("staged") and said.get("card") is False, said)
    return said


def checks_again(ctx):
    serve(ctx["feed"], {**ctx["files"], **PAGES})
    ok("B is free to check", idle(within=90) is not None, updates())
    updates(check=True)
    asked_feed = wait("feed", lambda: "/appcast.xml" in requests(), within=30)
    ok("B asks the feed again", bool(asked_feed), requests())
    w = window(saying="up to date", within=30)
    ok("and says it is up to date", w is not None, updates().get("windows"))
    if w:
        press(w["buttons"][0])


def windows():
    return cmd({"do": "windows"}).get("windows", [])


def case_automatic(ctx):
    print("automatic: A finds B by itself and installs it on quit", flush=True)
    app, old_pid = staged(ctx, "automatic")
    said = waiting_facts()
    ok("Settings says Broadway 0.2 is available", said.get("line", "").endswith(" · Broadway 0.2 is available"), said.get("line"))
    ok("the menu has Install Update, enabled", "Install Update" in said.get("menu", []) and "Install Update" not in said.get("menuOff", []),
       (said.get("menu"), said.get("menuOff")))
    card = (said.get("sidebar") or {}).get("card") or {}
    ok("the card says Update Available with Install", card.get("title") == "Update Available" and card.get("buttonTitle") == "Install"
       and card.get("label") == "Update available, version 0.2" and card.get("tip") == "Version 0.2", card)
    ok("Check for Updates… stays enabled while B waits", "Check for Updates…" not in said.get("menuOff", [])
       and said.get("canCheck") is True, (said.get("menuOff"), said.get("canCheck")))
    serve(ctx["feed"], ctx["files"])
    updates(check=True)
    read = wait("feed", lambda: "/appcast.xml" in requests(), within=30)
    time.sleep(2)
    said = updates()
    ok("Check for Updates… while B waits reads the feed live", bool(read), requests())
    ok("and, with the card in view, asks nothing and keeps B", not said.get("windows") and said.get("staged") == "Version 0.2"
       and ctx["path"] not in requests(), said)
    installed_on_quit(ctx, app, old_pid)
    checks_again(ctx)
    quit(app)


def case_restart(ctx):
    print("restart: the card's Restart installs B now and Sparkle relaunches it", flush=True)
    app, old_pid = staged(ctx, "restart")
    waiting_facts()
    a = cmd({"do": "split", "action": "open", "url": page("a")})["resultID"]
    b = cmd({"do": "split", "action": "open", "url": page("b")})["resultID"]
    c = cmd({"do": "split", "action": "open", "url": page("c")})["resultID"]
    paired = cmd({"do": "split", "action": "pair", "id": b, "with": a, "side": "right"})
    ok("A has a Split View pair", len(paired.get("splits", [])) == 1, paired.get("splits"))
    grouped = cmd({"do": "split", "action": "group", "id": c})
    group = next((g["id"] for g in grouped.get("groups", [])), None)
    folded = cmd({"do": "split", "action": "collapse", "group": group}) if group else {}
    ok("A has a folded folder", [g.get("collapsed") for g in folded.get("groups", [])] == [True], folded.get("groups"))
    cmd({"do": "ui", "spaces": True})
    cmd({"do": "space", "action": "new", "name": "Later"})
    cmd({"do": "space", "action": "go", "index": 2})
    cmd({"do": "split", "action": "save"})
    cmd({"do": "windows", "action": "new"})
    time.sleep(1)
    before = windows()
    ok("A has two windows and its first is on the second space",
       len(before) == 2 and sorted(w["space"] for w in before).count("Later") >= 1, [(w["space"], w["tabs"]) for w in before])
    cmd({"do": "split", "action": "save"})
    serve(ctx["feed"], {**ctx["files"], **PAGES})
    try:
        updates(install=True)
    except OSError:
        pass
    seen = watch(old_pid)
    asked_now = requests()
    said = relaunched(ctx, app, old_pid)
    ok("Install read the feed live before installing", "/appcast.xml" in asked_now, asked_now)
    ok("B was still the newest, so it installed at once with no download", ctx["path"] not in asked_now
       and not any(phase == "downloading" for phase, _ in seen), (asked_now, seen[:20]))
    if not said:
        return
    after = wait("windows", lambda: len(windows()) == 2 and windows(), within=20) or windows()
    ok("both windows are back", len(after) == 2 and not any(w["private"] for w in after), [(w["space"], w["tabs"]) for w in after])
    later = [i + 1 for i, w in enumerate(after) if w["space"] == "Later"]
    ok("the second space is still picked", bool(later), [w["space"] for w in after])
    found = None
    for n in later:
        cmd({"do": "space", "action": "go", "index": 1, "window": n})
        time.sleep(0.6)
        state = cmd({"do": "split", "action": "state", "window": n})
        urls = {t["id"]: t["url"] for t in state.get("tabs", [])}
        pairs = [sorted([urls.get(s["left"]), urls.get(s["right"])]) for s in state.get("splits", [])]
        held = [t["url"] for t, g in zip(state.get("tabs", []), state.get("groupIDs", [])) if g]
        found = (pairs, [g.get("collapsed") for g in state.get("groups", [])], held)
        if pairs:
            break
    pairs, collapsed, held = found or ([], [], [])
    ok("the Split View pair is back", pairs == [[page("a"), page("b")]], found)
    ok("the folder is back, still folded, with its tab", collapsed == [True] and held == [page("c")], found)
    quit(app)


def private_restart(ctx, name):
    app, old_pid = staged(ctx, name)
    waiting_facts()
    cmd({"do": "split", "action": "open", "url": page("a")})
    cmd({"do": "windows", "action": "private"})
    cmd({"do": "open", "url": page("d"), "private": True})
    time.sleep(1)
    ok("a private window is open", any(w["private"] for w in windows()), windows())
    cmd({"do": "split", "action": "save"})
    updates(install=True)
    w = window(saying="Restart to update?", within=15)
    ok("Install asks first, in a sheet", w is not None, updates().get("windows"))
    if w:
        print("       ", " | ".join(w["texts"]), "|", ", ".join(w["buttons"]), flush=True)
        shot(w, f"8-{name}-asks")
        ok("it says the private window closes", any("private window" in t for t in w["texts"])
           and {"Restart", "Not Now"} <= set(w["buttons"]), w)
    return app, old_pid, w


def case_ask(ctx):
    print("ask: a private window, Install asks first, Not Now keeps A", flush=True)
    app, old_pid, w = private_restart(ctx, "ask")
    if not w:
        quit(app)
        return
    press("Not Now")
    time.sleep(1.5)
    said = updates()
    ok("Not Now keeps A running", said.get("pid") == old_pid and str(old_pid) in pids(app), (said.get("pid"), pids(app)))
    ok("B is still staged, with its card", said.get("staged") == "Version 0.2" and said.get("card") is True, said)
    ok("the sheet is gone", not said.get("windows"), said.get("windows"))
    ok("the private window stays", any(w["private"] for w in windows()), windows())
    installed_on_quit(ctx, app, old_pid)
    ok("the private window does not come back", not any(w["private"] for w in windows()), windows())
    quit(app)


def case_ask_restart(ctx):
    print("ask: a private window, Install asks first, Restart installs and relaunches", flush=True)
    app, old_pid, w = private_restart(ctx, "askrestart")
    if not w:
        quit(app)
        return
    try:
        press("Restart")
    except OSError:
        pass
    said = relaunched(ctx, app, old_pid)
    if said:
        after = wait("windows", lambda: windows(), within=20) or []
        ok("the private window does not come back", after and not any(w["private"] for w in after), after)
        ok("the ordinary window does", any(page("a") in w["tabs"] for w in after), [w["tabs"] for w in after])
    quit(app)


def case_hidden(ctx):
    print("hidden: the card's × hides it and the update still installs on quit", flush=True)
    app, old_pid = staged(ctx, "hidden")
    waiting_facts()
    said = updates(hide=True)
    ok("the × hides the card", said.get("card") is False, said)
    ok("B is still staged and the menu still offers it", said.get("staged") == "Version 0.2"
       and "Install Update" in said.get("menu", []), said)
    ok("Settings still says Broadway 0.2 is available", said.get("line", "").endswith(" · Broadway 0.2 is available"), said.get("line"))
    installed_on_quit(ctx, app, old_pid)
    quit(app)


def bookmarks_file(count):
    out = SCRATCH / "held-import.html"
    rows = "".join(f'<DT><A HREF="https://held-import.invalid/{n}" ADD_DATE="1700000000">Held {n}</A>\n' for n in range(count))
    out.write_text(f"<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n{rows}</DL><p>\n")
    return out


def kept_import():
    return any("held-import.invalid" in f.read_text(errors="ignore") for f in SUPPORT.rglob("*.json") if f.is_file())


def case_held(ctx):
    print("held: Install while a file import runs, the first terminate is cancelled", flush=True)
    app, old_pid = staged(ctx, "held")
    waiting_facts()
    big = bookmarks_file(800000)
    cmd({"do": "import-file-start", "path": str(big)})
    time.sleep(1)
    running = cmd({"do": "import-file-status"})
    ok("an import is running", running.get("running") is True, running)
    started = time.time()
    try:
        updates(install=True)
    except OSError:
        pass
    said = relaunched(ctx, app, old_pid)
    note(f"held: B answered {time.time() - started:.0f} s after Install")
    if said:
        ok("the import was cancelled by the quit, so the terminate was held", not kept_import())
    quit(app)


def watch(old_pid, within=180):
    seen = []
    until = time.time() + within
    while time.time() < until:
        try:
            said = cmd({"do": "updates"}, timeout=3)
        except (OSError, ValueError):
            break
        if said.get("pid") != old_pid:
            break
        seen.append((said.get("phase"), said.get("progress")))
        time.sleep(0.15)
    return seen


def progressed(seen):
    return [part for phase, part in seen if phase == "downloading" and isinstance(part, (int, float))]


def case_asks(ctx):
    print("manual: automatic install off, the card offers B, Install downloads it with progress, and a change of signing identity", flush=True)
    fresh()
    app = copy("asks", "0.1", ctx["old"], ctx["public"], None)
    ok("A is signed ad-hoc and B with the team certificate",
       "Signature=adhoc" in run("codesign", "-dv", app).stderr and ctx["identity"] is not None)
    serve(same(ctx))
    launch(app)
    wait("first check", lambda: "/appcast.xml" in requests(), within=120)
    idle()
    said = updates(installs=False)
    time.sleep(1.5)
    quit(app)
    kept = run("defaults", "read", BUNDLE, "SUAutomaticallyUpdate").stdout.strip()
    ok("the switch wrote the same setting as before", kept == "0", (kept, said.get("installs")))
    run("defaults", "write", BUNDLE, "SULastCheckTime", "-date", "2026-11-10 09:00:00 +0000")
    serve(ctx["feed"], ctx["files"], slowly=[ctx["path"]])
    launch(app)
    old_pid = updates().get("pid")
    found = wait("feed", lambda: "/appcast.xml" in requests(), within=120)
    ok("a day later it asks the feed by itself", bool(found), requests())
    offered = wait("offer", lambda: (lambda s: s if s.get("phase") == "available" else None)(updates()), within=30) or {}
    ok("the card offers B in the sidebar", (offered.get("found") or {}).get("build") == ctx["new"] and offered.get("card") is True, offered)
    ok("with no window of Sparkle's own", not offered.get("windows"), offered.get("windows"))
    time.sleep(2)
    ok("it has not downloaded anything unasked", ctx["path"] not in requests(), requests())
    serve(ctx["feed"], ctx["files"], slowly=[ctx["path"]])
    try:
        updates(install=True)
    except OSError:
        pass
    seen = watch(old_pid)
    parts = progressed(seen)
    asked_now = requests()
    ok("Install asks the feed live first, then downloads", "/appcast.xml" in asked_now and ctx["path"] in asked_now
       and asked_now.index("/appcast.xml") < asked_now.index(ctx["path"]), asked_now)
    ok("the card shows Downloading while it does", "downloading" in [phase for phase, _ in seen], seen[:20])
    ok("a download progress above 0 and below 1 was seen", any(0 < part < 1 for part in parts), parts[:40])
    ok("the progress only went forward", parts == sorted(parts), parts[:40])
    note(f"manual: {len(parts)} progress samples, {len(set(parts))} distinct")
    relaunching.set()
    new = relaunched(ctx, app, old_pid)
    ok("B is signed by the team certificate", f"TeamIdentifier={TEAM}" in run("codesign", "-dv", app).stderr)
    quit(app)


def case_alert(ctx):
    print("alert: with the sidebar folded, Check for Updates… offers B in an alert, and Install there installs it", flush=True)
    fresh()
    app = copy("alert", "0.1", ctx["old"], ctx["public"], None)
    serve(same(ctx))
    launch(app)
    wait("first check", lambda: "/appcast.xml" in requests(), within=120)
    idle()
    updates(installs=False)
    cmd({"do": "ui", "folded": True})
    time.sleep(0.8)
    serve(ctx["feed"], ctx["files"], slowly=[ctx["path"]])
    old_pid = updates().get("pid")
    updates(check=True)
    w = window(saying="Broadway 0.2 is available")
    ok("with no card in view, Check for Updates… offers B in an alert", w is not None, (updates().get("windows"), updates().get("trail")))
    if not w:
        quit(app)
        return
    print("       ", " | ".join(w["texts"]), "|", ", ".join(w["buttons"]), flush=True)
    ok("its buttons are Install and Not Now", w["buttons"] == ["Install", "Not Now"], w)
    shot(w, "7-available-alert")
    ok("nothing was downloaded before Install", ctx["path"] not in requests(), requests())
    press("Install")
    seen = watch(old_pid)
    parts = progressed(seen)
    ok("Install in the alert downloads B with progress", any(0 < part < 1 for part in parts), (seen[:20], parts[:20]))
    note(f"alert: {len(parts)} progress samples")
    relaunched(ctx, app, old_pid)
    quit(app)


def case_newer(ctx):
    print("newer: A runs, B is staged, C is published, Install installs C with progress, not B", flush=True)
    app, old_pid = staged(ctx, "newer")
    waiting_facts()
    serve(appcast([ctx["item"], ctx["c_item"]]), {**ctx["files"], **ctx["c_files"]}, slowly=[ctx["c_path"]])
    try:
        updates(install=True)
    except OSError:
        pass
    seen = watch(old_pid)
    asked_now = requests()
    parts = progressed(seen)
    try:
        last = cmd({"do": "updates"}, timeout=3)
        note(f"newer: {last.get('flow')} busy {last.get('busy')} trail {last.get('trail')}")
    except (OSError, ValueError):
        pass
    ok("Install read the feed live", "/appcast.xml" in asked_now, asked_now)
    ok("it downloaded C and not B again", ctx["c_path"] in asked_now and ctx["path"] not in asked_now, asked_now)
    ok("a download progress above 0 and below 1 was seen", any(0 < part < 1 for part in parts), parts[:40])
    ok("the card went Checking, Downloading, then Installing", [p for p in dict.fromkeys(phase for phase, _ in seen)
       if p in ("checking", "downloading", "installing")] == ["checking", "downloading", "installing"], seen[:40])
    note(f"newer: {len(parts)} progress samples")
    relaunched(ctx, app, old_pid, short="0.3", build=ctx["newest"], name="C")
    quit(app)


def refused(ctx, name, feed, files, picture):
    fresh()
    app = copy(name, "0.1", ctx["old"], ctx["public"], ctx["identity"])
    serve(same(ctx))
    launch(app)
    wait("first check", lambda: "/appcast.xml" in requests(), within=120)
    idle()
    updates(installs=False)
    time.sleep(1.5)
    serve(feed, files)
    idle()
    updates(check=True)
    offered = wait("offer", lambda: (lambda s: s if s.get("phase") == "available" else None)(updates()), within=60)
    ok("it offers the update on the card", offered is not None and not offered.get("windows"), updates())
    if offered:
        updates(install=True)
    failed = wait("failed", lambda: (lambda s: s if s.get("phase") == "failed" else None)(updates()), within=120) or {}
    card = (failed.get("sidebar") or {}).get("card") or {}
    ok("the image is refused and the card says Couldn't Update with Try Again", card.get("title") == "Couldn't Update"
       and card.get("buttonTitle") == "Try Again", card)
    ok("the reason is on the card's tooltip and in Settings' line", "improperly signed" in card.get("tip", "")
       and "Couldn't update · " in failed.get("line", "") and "improperly signed" in failed.get("line", ""), (card.get("tip"), failed.get("line")))
    print("       ", failed.get("line", ""), flush=True)
    time.sleep(2)
    ok("the app on disk is still A", info(app)["CFBundleVersion"] == ctx["old"], info(app)["CFBundleVersion"])
    ok("nothing is waiting to install", not updates().get("staged"), updates().get("staged"))
    quit(app)
    time.sleep(3)
    ok("and still A after quitting", info(app)["CFBundleVersion"] == ctx["old"], info(app)["CFBundleVersion"])


def case_tampered(ctx):
    print("tampered: an image changed after signing", flush=True)
    body = bytearray(ctx["files"][ctx["path"]])
    for at in range(len(body) // 2, len(body) // 2 + 64):
        body[at] ^= 0xFF
    refused(ctx, "tampered", ctx["feed"], {ctx["path"]: bytes(body)}, "4-tampered-refused")
    print("tampered: an image signed with somebody else's key", flush=True)
    other, _ = make_keys()
    item = dict(ctx["item"], signature=signature(ctx["dmg"], other))
    refused(ctx, "otherkey", appcast([item]), ctx["files"], "5-other-key-refused")


def case_image(ctx):
    print("image: run from the disk image", flush=True)
    fresh()
    app = copy("image", "0.1", ctx["old"], ctx["public"], ctx["identity"])
    dmg = image(app, "Broadway-test.dmg", volume="Broadway update run")
    mount = SCRATCH / "mounted"
    mount.mkdir(exist_ok=True)
    attached = run("hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mount, dmg)
    if attached.returncode != 0:
        ok("the image mounts", False, attached.stderr)
        return
    there = mount / "Broadway.app"
    serve(ctx["feed"], ctx["files"])
    try:
        launch(there)
        w = window(saying="Move Broadway to your Applications folder", within=20)
        ok("it says so at launch", w is not None, updates().get("windows"))
        if w:
            print("       ", " | ".join(w["texts"]), "|", ", ".join(w["buttons"]), flush=True)
            shot(w, "6-run-from-disk-image")
            press("Not Now")
        time.sleep(1)
        said = updates()
        ok("it knows it runs from a disk image", said.get("moveOffer") == "diskImage", said.get("moveOffer"))
        ok("Settings says to move it", "Move Broadway to Applications" in updates().get("line", ""), updates().get("line"))
        time.sleep(8)
        ok("left alone it downloads nothing", ctx["path"] not in requests(), requests())
        updates(check=True)
        err = window(saying="Couldn't check for updates", within=30)
        ok("Check for Updates… says why it can't, in Broadway's own alert", err is not None, updates().get("windows"))
        if err:
            print("       ", " | ".join(err["texts"]), flush=True)
            shot(err, "7-check-from-disk-image")
            press(err["buttons"][0])
    finally:
        quit(there)
        for _ in range(5):
            if run("hdiutil", "detach", mount).returncode == 0:
                break
            time.sleep(2)


CASES = {"inert": case_inert, "current": case_current, "automatic": case_automatic, "restart": case_restart, "newer": case_newer,
         "ask": case_ask, "askrestart": case_ask_restart, "hidden": case_hidden, "held": case_held, "asks": case_asks, "alert": case_alert,
         "tampered": case_tampered, "image": case_image}


def main():
    wanted = [a for a in sys.argv[1:] if a in CASES] or list(CASES)
    public = info(PUBLIC)
    settings = sparkle_settings()
    if len(settings) != 5 or not settings.get("SUAutomaticallyUpdate") or settings.get("SUAllowsAutomaticUpdates") is not False:
        sys.exit(f"build.sh's Sparkle settings were not read: {settings}")
    if run("pgrep", "-f", f"{SCRATCH}").stdout.strip():
        sys.exit("a copy from this scratch folder is already running")
    ctx = {"identity": team_identity()}
    secret, ctx["public"] = make_keys()
    ctx["old"] = public["CFBundleVersion"]
    ctx["new"] = str(int(ctx["old"]) + 1)
    ctx["newest"] = str(int(ctx["old"]) + 2)
    print(f"A is 0.1 ({ctx['old']}), B is 0.2 ({ctx['new']}), C is 0.3 ({ctx['newest']}); feed {BASE}/appcast.xml; world {WORLD}; "
          f"signed by {'the team certificate' if ctx['identity'] else 'nobody (ad-hoc)'}", flush=True)
    try:
        newer = copy("B", "0.2", ctx["new"], ctx["public"], ctx["identity"])
        ctx["dmg"] = image(newer, f"Broadway-0.2-{ctx['new']}.dmg")
        ctx["path"] = f"/releases/{ctx['dmg'].name}"
        ctx["item"] = {"short": "0.2", "build": ctx["new"], "path": ctx["path"], "signature": signature(ctx["dmg"], secret),
                       "length": ctx["dmg"].stat().st_size}
        ctx["feed"] = appcast([ctx["item"]])
        ctx["files"] = {ctx["path"]: ctx["dmg"].read_bytes()}
        if any(name in wanted for name in ("newer",)):
            newest = copy("C", "0.3", ctx["newest"], ctx["public"], ctx["identity"])
            c_dmg = image(newest, f"Broadway-0.3-{ctx['newest']}.dmg")
            ctx["c_path"] = f"/releases/{c_dmg.name}"
            ctx["c_item"] = {"short": "0.3", "build": ctx["newest"], "path": ctx["c_path"], "signature": signature(c_dmg, secret),
                             "length": c_dmg.stat().st_size}
            ctx["c_files"] = {ctx["c_path"]: c_dmg.read_bytes()}
        threading.Thread(target=watch_front, daemon=True).start()
        for name in wanted:
            current[0] = name
            try:
                CASES[name](ctx)
            except Exception as error:
                ok(f"{name} ran to its end", False, repr(error))
                for folder in SCRATCH.iterdir():
                    for pid in pids(folder / "Broadway.app"):
                        run("kill", pid)
    finally:
        watching.set()
        ok("no test copy came to the front, except as Sparkle relaunched it", not fronts, fronts[:5])
        if relaunch_fronts:
            note(f"Sparkle's relaunch put B in front until it gave the front back, {len(relaunch_fronts)} samples a quarter "
                 f"second apart: " + ", ".join(sorted(set(relaunch_fronts))))
        for found in list(SCRATCH.glob("*/Broadway.app")) + [SCRATCH / "mounted" / "Broadway.app"]:
            for pid in pids(found):
                run("kill", pid)
        run("hdiutil", "detach", SCRATCH / "mounted", "-force")
        time.sleep(1)
        register = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        for found in SCRATCH.glob("*/Broadway.app"):
            run(register, "-u", found)
        forget()
        shutil.rmtree(SCRATCH, ignore_errors=True)
    print(f"{passed} passed, {failed} failed", flush=True)
    for text in notes:
        print("note:", text)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

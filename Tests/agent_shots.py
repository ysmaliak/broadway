#!/usr/bin/env python3
import base64
import io
import json
import os
import signal
import statistics
import struct
import subprocess
import sys
import tarfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")
sv.use(f"shots-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE
HERE = Path(os.environ.get("SHOTS_OUT", "/tmp")) / f"agent-shots-{os.getpid()}"
BASE = ""

PARAGRAPH = "Line of plain text that wraps across the page so that tiles have something to cut. " * 6
LONG = ("""<!doctype html><title>Long</title><style>
body{margin:0;font:16px/24px -apple-system,sans-serif;background:#fff;color:#111}
header{position:sticky;top:0;height:56px;background:#123;color:#fff;display:flex;align-items:center;padding:0 16px;z-index:5}
main{padding:0 24px}
img{display:block;width:400px;height:200px;background:#eee}
</style><header id=head>Sticky header</header><main>"""
    + "".join(f'<h2 id="s{n}">Section {n}</h2><p>{PARAGRAPH}</p><p><a href="#s{n}">Link {n}</a> <button>Button {n}</button></p>'
              + (f'<img loading="lazy" src="/pic/{n}.png" alt="pic {n}">' if n % 3 == 0 else "") for n in range(1, 41))
    + '<p><input name="password" id="pw" value="hunter2-secret-pass" style="font:28px monospace;width:420px"> <input id="plain" value="plain words here" style="font:28px monospace;width:420px"></p></main>'
    + '<div id=bar style="position:fixed;left:0;right:0;bottom:0;height:40px;background:#a50;color:#fff">Cookie bar</div>')

SHORT = """<!doctype html><title>Short</title><style>body{font:16px -apple-system;margin:40px}</style>
<h1>Short page</h1><p>Small text</p><button id=go onclick="document.getElementById('out').textContent='Changed a lot of words on this page now'">Go</button>
<p id=out style="font-size:48px">Before</p><input type=password value="hunter2-secret-pass">"""

FORM = """<!doctype html><title>Give</title><form method=post enctype=multipart/form-data action=/sent>
<input type=file name=doc id=doc><button id=send>Send it</button></form>"""

FILE = b"attached over standard input " * 40


def png(width, height, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


PIC = png(400, 200, (40, 160, 90))
seen_pics = set()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/pic/"):
            seen_pics.add(self.path)
            time.sleep(0.3)
            return self.reply(PIC, "image/png")
        if self.path.startswith("/file.bin"):
            self.send_response(200)
            self.send_header("content-type", "application/octet-stream")
            self.send_header("content-disposition", 'attachment; filename="file.bin"')
            self.send_header("content-length", str(len(FILE)))
            self.end_headers()
            self.wfile.write(FILE)
            return
        body = SHORT if self.path.startswith("/short") else FORM if self.path.startswith("/form") else LONG
        self.reply(body.encode(), "text/html")

    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        Page.posted.append(body)
        self.reply(b"<!doctype html><title>Sent</title><p>sent", "text/html")

    posted = []

    def reply(self, body, kind):
        self.send_response(200)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def log_message(self, *_):
        pass


failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:600], flush=True)
    if not ok:
        failures.append(name)


def broadway(*words, stdin=subprocess.DEVNULL, env=None, text=True, timeout=120, input=None):
    environment = dict(os.environ, **(env or {}))
    if input is not None:
        return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=text, input=input, env=environment, timeout=timeout)
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=text, stdin=stdin, env=environment, timeout=timeout)


def envelope(*words, **options):
    result = broadway(*words, "--json", **options)
    try:
        return result, json.loads(result.stdout)
    except ValueError:
        return result, {"ok": False, "raw": result.stdout + result.stderr}


def bench(*words):
    return subprocess.run([BENCH, "--world", WORLD, *words], capture_output=True, text=True, timeout=30).stdout


def desk():
    try:
        return json.loads(bench("knowing", "desk", "list"))["pending"]
    except (ValueError, KeyError):
        return []


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        if condition():
            return True
        time.sleep(0.1)
    return False


def answered(answer, *words, stdin=None):
    running = subprocess.Popen([BROADWAY, "--world", WORLD, *words, "--json"], stdin=stdin if stdin is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if wait_for(desk, 10):
        bench("knowing", "desk", answer)
    output, errors = running.communicate(timeout=60)
    try:
        return running.returncode, json.loads(output), errors.decode(errors="replace")
    except ValueError:
        return running.returncode, {"ok": False, "raw": output[:300]}, errors.decode(errors="replace")


class Picture:
    def __init__(self, path):
        bmp = HERE / (Path(path).name + ".bmp")
        subprocess.run(["sips", "-s", "format", "bmp", str(path), "--out", str(bmp)], capture_output=True, check=True)
        raw = bmp.read_bytes()
        start = struct.unpack("<I", raw[10:14])[0]
        self.width, height = struct.unpack("<ii", raw[18:26])
        self.depth = struct.unpack("<H", raw[28:30])[0] // 8
        self.top_down = height < 0
        self.height = abs(height)
        self.row = (self.width * self.depth + 3) // 4 * 4
        self.raw = raw
        self.start = start

    def at(self, x, y):
        line = y if self.top_down else self.height - 1 - y
        i = self.start + line * self.row + x * self.depth
        b, g, r = self.raw[i], self.raw[i + 1], self.raw[i + 2]
        return r, g, b

    def count(self, wanted, near=6, box=None):
        left, top, right, bottom = box or (0, 0, self.width, self.height)
        found = 0
        for y in range(max(0, top), min(self.height, bottom)):
            for x in range(max(0, left), min(self.width, right)):
                pixel = self.at(x, y)
                if all(abs(pixel[k] - wanted[k]) <= near for k in range(3)):
                    found += 1
        return found

    def dark(self, box):
        left, top, right, bottom = box
        found = 0
        for y in range(max(0, top), min(self.height, bottom)):
            for x in range(max(0, left), min(self.width, right)):
                if sum(self.at(x, y)) < 250:
                    found += 1
        return found


class Client:
    def __init__(self, env=None):
        self.process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                        env=dict(os.environ, **(env or {})))
        self.number = 0

    def rpc(self, method, params=None):
        self.number += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.number, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            message = json.loads(self.process.stdout.readline())
            if "id" in message:
                return message

    def call(self, name, /, **arguments):
        return self.rpc("tools/call", {"name": name, "arguments": arguments})["result"]

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)


def refs(tab):
    _, parsed = envelope("snapshot", "--all", "--tab", tab)
    return {element.get("name", ""): "@" + element["ref"] for element in (parsed.get("data") or {}).get("elements", [])}


def sizes(tab):
    result, parsed = envelope("shot", "--tab", tab, "-o", str(HERE / "probe.png"))
    data = (parsed.get("data") or {})
    return result, data


def sized(tab):
    plain = HERE / "measure.png"
    broadway("shot", "--tab", tab, "-o", str(plain))
    return png_size(plain.read_bytes())


def size_and_format(tab):
    result, parsed = envelope("shot", "--width", "640", "--tab", tab, "-o", str(HERE / "w640.png"))
    data = (parsed.get("data") or {})
    check("--width 640 gives a picture 640 pixels wide", result.returncode == 0 and (HERE / "w640.png").exists() and png_size((HERE / "w640.png").read_bytes()) == (640, 448), (result.stderr, parsed))
    check("the answer gives the size in pixels", data.get("width") == 640 and data.get("height") == 448, data)
    told = broadway("shot", "--width", "640", "--tab", tab, "-o", str(HERE / "w640b.png"))
    check("the plain answer says the size", "640 by 448 pixels" in told.stderr and told.stdout.strip() == str(HERE / "w640b.png"), told.stdout + told.stderr)
    result, parsed = envelope("shot", "--scale", "2", "--tab", tab, "-o", str(HERE / "x2.png"))
    check("--scale 2 gives two pixels for each point", result.returncode == 0 and (HERE / "x2.png").exists() and png_size((HERE / "x2.png").read_bytes()) == (2000, 1400), (result.stderr, parsed))
    result, parsed = envelope("shot", "--tab", tab, "-o", str(HERE / "x1.png"))
    check("a shot is one pixel for each point by default", result.returncode == 0 and png_size((HERE / "x1.png").read_bytes()) == (1000, 700), parsed)
    both, parsed = envelope("shot", "--scale", "2", "--width", "500", "--tab", tab)
    check("--scale and --width together is a usage mistake", both.returncode == 2 and (parsed.get("error") or {}).get("code") == "usage", parsed)
    result, parsed = envelope("shot", "--format", "jpeg", "--quality", "60", "--tab", tab, "-o", str(HERE / "small.jpg"))
    jpeg = (HERE / "small.jpg").read_bytes() if (HERE / "small.jpg").exists() else b""
    check("--format jpeg writes a JPEG", result.returncode == 0 and jpeg[:2] == b"\xff\xd8" and png_size(jpeg) == (1000, 700), (result.stderr, parsed))
    check("and it is smaller than the PNG", (HERE / "x1.png").exists() and 0 < len(jpeg) < (HERE / "x1.png").stat().st_size, len(jpeg))
    named, parsed = envelope("shot", "--format", "jpeg", "--tab", tab)
    path = (parsed.get("data") or {}).get("path", "")
    check("a JPEG shot without -o is named .jpg", path.endswith(".jpg"), parsed)
    if path:
        Path(path).unlink(missing_ok=True)


def one_element(tab):
    named = refs(tab)
    button = named.get("Go")
    result, parsed = envelope("shot", button, "--tab", tab, "-o", str(HERE / "button.png"))
    whole = png_size((HERE / "button.png").read_bytes()) if result.returncode == 0 else None
    check("shot TARGET is the element with a margin", result.returncode == 0 and whole and whole[0] > 40 and whole[1] >= 40, (whole, parsed))
    picture = Picture(HERE / "button.png") if result.returncode == 0 else None
    check("the margin shows the page around it", picture and picture.at(2, 2) == picture.at(picture.width - 3, picture.height - 3) and sum(picture.at(2, 2)) > 600, picture and picture.at(2, 2))


def marks(tab):
    result, parsed = envelope("shot", "--marks", "--tab", tab, "-o", str(HERE / "marks.png"))
    data = (parsed.get("data") or {})
    drawn = data.get("marks") or []
    named = refs(tab)
    check("--marks lists the refs it drew", result.returncode == 0 and any("@" + mark["ref"] == named.get("Go") for mark in drawn), (parsed, named))
    picture = Picture(HERE / "marks.png") if result.returncode == 0 else None
    check("the refs are drawn on the picture", picture and picture.count((209, 0, 107), near=30) > 50, picture and picture.count((209, 0, 107), near=30))
    broadway("shot", "--tab", tab, "-o", str(HERE / "after-marks.png"))
    check("and never into the page", picture is not None and Picture(HERE / "after-marks.png").count((209, 0, 107), near=30) == 0)


def if_changed(tab):
    first = broadway("shot", "--tab", tab, "-o", str(HERE / "a.png"))
    again, parsed = envelope("shot", "--if-changed", "--tab", tab, "-o", str(HERE / "b.png"))
    data = (parsed.get("data") or {})
    check("--if-changed gives no file when nothing changed", first.returncode == 0 and again.returncode == 0 and data.get("unchanged") is True and not (HERE / "b.png").exists(), (again.stderr, parsed))
    check("and says how much changed", "Unchanged since your last shot of this tab" in data.get("message", ""), data)
    plain = broadway("shot", "--if-changed", "--tab", tab, "-o", str(HERE / "b.png"))
    check("the plain answer says so", plain.stdout.startswith("Unchanged since your last shot of this tab (") and "of pixels)" in plain.stdout, plain.stdout + plain.stderr)
    broadway("click", "Go", "--tab", tab)
    changed, parsed = envelope("shot", "--if-changed", "--tab", tab, "-o", str(HERE / "c.png"))
    check("a changed page gives the picture", changed.returncode == 0 and (HERE / "c.png").exists() and not (parsed.get("data") or {}).get("unchanged"), parsed)
    other, parsed = envelope("shot", "--if-changed", "--width", "500", "--tab", tab, "-o", str(HERE / "d.png"))
    check("another size is not the same shot", other.returncode == 0 and (HERE / "d.png").exists(), parsed)


def tiles(tab):
    broadway("resize", "1000", "700", "--tab", tab)
    broadway("wait", "Section 40", "--tab", tab)
    page = int(float(bench("eval", tab, "document.documentElement.scrollHeight").strip() or 0))
    broadway("scroll", "900", "--tab", tab)
    before = bench("eval", tab, "scrollY").strip()
    folder = HERE / "tiles"
    result, parsed = envelope("shot", "--tiles", "--tab", tab, "-o", str(folder))
    data = (parsed.get("data") or {})
    rows = data.get("tiles") or []
    overlap = data.get("overlap", 0)
    step = 700 - overlap
    expected = 1 + -(-(page - 700) // step)
    check("--tiles takes the whole page", result.returncode == 0 and data.get("total") == expected and len(rows) == min(expected, 20), (result.stderr, page, overlap, {k: v for k, v in data.items() if k != "tiles"}))
    check("each tile has its path and offset", rows and all(Path(row.get("path", "")).exists() and Path(row["path"]).parent == folder for row in rows), rows[:2])
    offsets = [row.get("offset") for row in rows]
    check("tiles overlap a little and end at the bottom", offsets[:2] == [0, step] and offsets[-1] == page - 700 and 30 <= overlap <= 80, (offsets, overlap))
    after = bench("eval", tab, "scrollY").strip()
    check("the page's scroll is put back", before == after and before not in ("", "0"), (before, after))
    pictures = [Picture(row["path"]) for row in rows if row.get("path")]
    check("tiles are one window high", pictures and all((pic.width, pic.height) == (1000, 700) for pic in pictures), [(pic.width, pic.height) for pic in pictures])
    check("the sticky header shows in the first tile", pictures and pictures[0].at(500, 10) == (17, 34, 51), pictures and pictures[0].at(500, 10))
    check("and not again in the others", len(pictures) > 2 and all(pic.at(500, 10) != (17, 34, 51) for pic in pictures[1:]), [pic.at(500, 10) for pic in pictures[1:]])
    check("a fixed bar shows once", pictures and pictures[0].at(500, 690) == (170, 85, 0) and all(pic.at(500, 690) != (170, 85, 0) for pic in pictures[1:]), [pic.at(500, 690) for pic in pictures])
    loading = [index + 1 for index, pic in enumerate(pictures) if pic.count((238, 238, 238), near=0, box=(0, 0, 1000, 700)) > 4000]
    check("lazy pictures had time to load", len(seen_pics) == 13 and not loading, (len(seen_pics), loading))
    green = sum(1 for pic in pictures if pic.count((40, 160, 90), near=4) > 4000)
    check("and they are in the tiles", pictures and green >= len(pictures) // 2, (green, len(pictures)))
    marked, parsed = envelope("shot", "--tiles", "--marks", "--tab", tab, "-o", str(HERE / "marked"))
    last = ((parsed.get("data") or {}).get("tiles") or [{}])[-1]
    spots = {mark["ref"]: mark for mark in last.get("marks", [])}
    named = refs(tab)
    secret = spots.get(named.get("password", "@x")[1:]) or next((mark for mark in last.get("marks", []) if mark.get("role") == "textbox"), None)
    textboxes = [mark for mark in last.get("marks", []) if mark.get("role") == "textbox"]
    if len(textboxes) >= 2 and last.get("path"):
        picture = Picture(last["path"])
        hidden, shown = textboxes[0], textboxes[1]
        lines = lambda mark: picture.dark((mark["x"] - 180, mark["y"] - 8, mark["x"] + 120, mark["y"] + 8))
        check("a password box shown as text stays blank in a tile", lines(hidden) == 0 and lines(shown) > 40, (lines(hidden), lines(shown), textboxes))
    else:
        check("a password box shown as text stays blank in a tile", False, (secret, last))
    some, parsed = envelope("shot", "--tiles", "--from", "2", "--count", "2", "--tab", tab, "-o", str(HERE / "some"))
    data = (parsed.get("data") or {})
    check("--from and --count take part of the page", [row.get("tile") for row in data.get("tiles", [])] == [2, 3] and data.get("total") == expected, data)
    plain = broadway("shot", "--tiles", "--from", "2", "--count", "2", "--tab", tab, "-o", str(HERE / "some"))
    check("and say where the rest starts", "More: broadway shot --tiles --from 4" in plain.stdout and "Tiles 2 to 3 of" in plain.stdout, plain.stdout)
    repeat, parsed = envelope("shot", "--tiles", "--if-changed", "--tab", tab, "-o", str(HERE / "again"))
    rows = (parsed.get("data") or {}).get("tiles") or []
    check("--if-changed holds for each tile", rows and all(row.get("unchanged") for row in rows) and not any(row.get("path") for row in rows), rows[:2])
    person = broadway("shot", "--tiles", "--tab", person_tab(tab))
    check("tiles never scroll the person's tab", person.returncode != 0 and "tab of your own" in person.stderr, person.stderr)
    return expected


def person_tab(base_tab):
    made, parsed = envelope("tabs", "new", BASE + "short", "--front")
    ident = str((parsed.get("data") or {}).get("id") or (parsed.get("data") or {}).get("tab") or "")
    print("     person tab:", made.stdout.strip()[:300], flush=True)
    until = time.time() + 10
    while time.time() < until:
        _, listed = envelope("tabs", "--all")
        rows = (listed.get("data") or {}).get("tabs", [])
        row = next((r for r in rows if not r.get("agent") and "short" in str(r.get("url", ""))), None)
        if row:
            return row["id"]
        time.sleep(0.3)
    print("     no tab of the person's:", listed, flush=True)
    return ident or "none"


def streams(tab, count):
    out = broadway("shot", "--out", "-", "--tab", tab, text=False)
    check("shot --out - writes the bytes and nothing else", out.returncode == 0 and out.stdout[:8] == b"\x89PNG\r\n\x1a\n" and png_size(out.stdout) == (1000, 700) and not list(Path.cwd().glob("-")), (out.returncode, out.stdout[:40], out.stderr[-300:]))
    dash = broadway("shot", "-o", "-", "--tab", tab, text=False)
    check("-o - is the same", dash.returncode == 0 and dash.stdout[:4] == b"\x89PNG", dash.stderr[-200:])
    mixed = broadway("shot", "--out", "-", "--json", "--tab", tab)
    check("--out - with --json is a usage mistake", mixed.returncode == 2, mixed.stdout + mixed.stderr)
    pdf = broadway("pdf", "--out", "-", "--tab", tab, text=False)
    check("pdf --out - writes the PDF's bytes", pdf.returncode == 0 and pdf.stdout[:5] == b"%PDF-", (pdf.returncode, pdf.stdout[:20], pdf.stderr[-200:]))
    tar = broadway("shot", "--tiles", "--out", "-", "--tab", tab, text=False)
    names = []
    try:
        with tarfile.open(fileobj=io.BytesIO(tar.stdout)) as archive:
            names = archive.getnames()
            first = archive.extractfile(names[0]).read()
    except (tarfile.TarError, IndexError):
        first = b""
    check("shot --tiles --out - writes one tar", tar.returncode == 0 and len(names) == min(count, 20) and first[:4] == b"\x89PNG", (tar.returncode, names, tar.stderr[-300:]))
    away = {"SSH_CONNECTION": "10.0.0.2 50000 10.0.0.1 22"}
    told = broadway("shot", "--tab", tab, "-o", str(HERE / "ssh.png"), env=away)
    check("over ssh, an answer with a path names --out -", told.returncode == 0 and "--out -" in told.stderr and told.stdout.strip() == str(HERE / "ssh.png"), told.stdout + told.stderr)
    _, parsed = envelope("shot", "--tab", tab, "-o", str(HERE / "ssh.png"), env=away)
    check("and in JSON too", "--out -" in (parsed.get("data") or {}).get("ssh", ""), parsed)
    quiet = broadway("shot", "--out", "-", "--tab", tab, text=False, env=away)
    check("but not when the bytes come", b"--out" not in quiet.stderr, quiet.stderr)
    near = broadway("shot", "--tab", tab, "-o", str(HERE / "near.png"))
    check("and not without ssh", "--out -" not in near.stderr, near.stderr)
    pdfs = broadway("pdf", "--json", "--tab", tab, env=away)
    check("pdf names it too", "--out -" in pdfs.stdout, pdfs.stdout)


def given(base):
    form = broadway("open", base + "form").stdout.strip()
    broadway("wait", "Send it", "--tab", form)
    named = refs(form)
    field = named.get("doc") or next((ref for name, ref in named.items() if "file" in name.lower() or "choose" in name.lower()), None) or "Choose File"
    code, parsed, errors = answered("yes", "upload", field, "--stdin", "note.txt", "--tab", form, stdin=open(HERE / "note-in.txt", "rb"))
    attached = json.dumps(parsed)
    check("upload --stdin NAME gives the bytes as a file", code == 0 and parsed.get("ok") and "note.txt" in attached, (code, parsed, errors[-300:]))
    paths = [Path(found) for found in json.dumps(parsed).split('"') if "broadway-stdin-" in found and found.startswith("/")]
    answered("yes", "click", "Send it", "--tab", form)
    wait_for(lambda: Page.posted, 10)
    sent = Page.posted[-1] if Page.posted else b""
    check("the page sends the bytes", FILE in sent and b'filename="note.txt"' in sent, sent[:300])
    check("the copy stays while the tab is open", paths and all(path.exists() for path in paths), paths)
    tty = broadway("upload", field, "--stdin", "x.txt", "--tab", form)
    check("--stdin without bytes is a usage mistake", tty.returncode == 2, tty.stderr)
    broadway("close", "--tab", form)
    check("and is removed once the tab is closed", wait_for(lambda: not any(path.exists() for path in paths), 40), paths)


def plain_upload(base):
    for remove in (False, True):
        one_upload(base, remove)


def one_upload(base, remove):
    opened = broadway("open", base + "form")
    form = opened.stdout.strip()
    print("     opened", opened.returncode, opened.stdout[-200:], opened.stderr[-200:], flush=True)
    broadway("wait", "Send it", "--tab", form)
    named = refs(form)
    print("     refs", named, flush=True)
    copy = Path(f"/tmp/plain-note-{os.getpid()}-{int(remove)}.txt")
    copy.write_bytes(FILE)
    before = len(Page.posted)
    code, parsed, errors = answered("yes", "upload", named.get("doc") or "Choose File", str(copy), "--tab", form)
    print("     upload", remove, code, json.dumps(parsed)[:200], errors[-200:], flush=True)
    if remove:
        copy.unlink()
    clicked = answered("yes", "click", "Send it", "--tab", form)
    print("     click", clicked[0], json.dumps(clicked[1])[:300], flush=True)
    wait_for(lambda: len(Page.posted) > before, 10)
    print("     posted", remove, len(Page.posted) - before, (Page.posted[-1][:260] if len(Page.posted) > before else b""), flush=True)
    broadway("close", "--tab", form)


def hold(base):
    tab = broadway("open", base + "long").stdout.strip()
    broadway("wait", "Section 40", "--tab", tab)
    broadway("resize", "1000", "700", "--tab", tab)
    form = broadway("open", base + "form").stdout.strip()
    broadway("wait", "Send it", "--tab", form)
    stop = HERE / "stop"
    (HERE / "hold.json").write_text(json.dumps({"world": WORLD, "tab": tab, "form": form, "base": base, "stop": str(stop), "here": str(HERE)}))
    print("hold", json.dumps({"world": WORLD, "tab": tab, "form": form, "base": base}), flush=True)
    until = time.time() + 1200
    while time.time() < until and not stop.exists():
        time.sleep(0.5)
    print("posted", [len(body) for body in Page.posted], [FILE in body for body in Page.posted], flush=True)


def downloads(base, tab):
    result, parsed = envelope("download", "--url", base + "file.bin", "--tab", tab)
    data = (parsed.get("data") or {}).get("download") or {}
    ident = data.get("id", "")
    check("download answers with an id", result.returncode == 0 and len(ident) == 8, parsed)
    got = broadway("downloads", "get", ident, "--out", "-", text=False)
    check("downloads get ID --out - writes the file's bytes", got.returncode == 0 and got.stdout == FILE, (got.returncode, got.stdout[:60], got.stderr[-200:]))
    copy = HERE / "copied.bin"
    kept = broadway("downloads", "get", ident, "-o", str(copy))
    check("downloads get ID -o FILE copies it", kept.returncode == 0 and copy.exists() and copy.read_bytes() == FILE, kept.stdout + kept.stderr)
    away = broadway("downloads", "get", ident, env={"SSH_CONNECTION": "10.0.0.2 50000 10.0.0.1 22"})
    check("downloads get over ssh names --out -", away.returncode == 0 and "--out -" in away.stderr and away.stdout.strip() == data.get("path"), away.stdout + away.stderr)
    dl = broadway("download", "--url", base + "file.bin", "--tab", tab, env={"SSH_CONNECTION": "10.0.0.2 50000 10.0.0.1 22"})
    check("download over ssh names downloads get", "downloads get" in dl.stderr and "--out -" in dl.stderr, dl.stdout + dl.stderr)


def mcp(base):
    client = Client()
    client.rpc("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "probe"}})
    listed = client.rpc("tools/list")["result"]["tools"]
    shot = next((tool for tool in listed if tool["name"] == "shot"), {})
    keys = set(shot.get("inputSchema", {}).get("properties", {}))
    check("the short MCP list keeps shot as it was", keys == {"ref", "full", "tab"}, keys)
    size = len(json.dumps(listed, separators=(",", ":")))
    check("the short tools/list stays under 6 KB", size < 6144, size)
    opened = client.call("open", url=base + "long")
    tab = meta(opened).get("tab") or meta(opened).get("id")
    client.call("wait", text="Section 40")
    one = client.call("shot", width=500)
    images = [part for part in one["content"] if part["type"] == "image"]
    check("an MCP shot is one image of the asked width", len(images) == 1 and png_size(base64.b64decode(images[0]["data"]))[0] == 500, [part.get("text") for part in one["content"]])
    jpeg = client.call("shot", format="jpeg")
    images = [part for part in jpeg["content"] if part["type"] == "image"]
    check("a JPEG comes as image/jpeg", images and images[0]["mimeType"] == "image/jpeg", jpeg["content"][:1])
    tiled = client.call("shot", tiles=True)
    images = [part for part in tiled["content"] if part["type"] == "image"]
    text = "".join(part.get("text", "") for part in tiled["content"])
    check("MCP tiles come as images, eight at most by default", len(images) == 8 and "Tiles 1 to 8 of" in text, (len(images), text[:300]))
    again = client.call("shot", if_changed=True)
    client.call("shot")
    same = client.call("shot", if_changed=True)
    check("an unchanged MCP shot sends no image", not [part for part in same["content"] if part["type"] == "image"] and "Unchanged since your last shot" in "".join(part.get("text", "") for part in same["content"]), same["content"])
    client.close()


def meta(result, key="data"):
    return (result.get("_meta") or {}).get("com.broadway/" + key) or {}


def png_size(data):
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", data[16:24])
    if data[:2] == b"\xff\xd8":
        index = 2
        while index < len(data):
            marker, length = data[index + 1], struct.unpack(">H", data[index + 2:index + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2):
                height, width = struct.unpack(">HH", data[index + 5:index + 9])
                return width, height
            index += 2 + length
    return None


def timed(times, *words):
    began = time.perf_counter()
    result = broadway(*words)
    times.append((time.perf_counter() - began) * 1000)
    return result


def summary(name, times):
    print(f"     time {name}: median {statistics.median(times):.0f} ms, min {min(times):.0f} ms, runs {len(times)}", flush=True)


def speed(base):
    tab = broadway("open", base + "long").stdout.strip()
    broadway("wait", "Section 40", "--tab", tab)
    plain, whole, ten = [], [], []
    for _ in range(7):
        timed(plain, "shot", "--tab", tab, "-o", str(HERE / "plain.png"))
    for _ in range(5):
        timed(whole, "shot", "--full", "--tab", tab, "-o", str(HERE / "full.png"))
    tiles = "tiles" in broadway("help", "shot").stdout
    for _ in range(3):
        began = time.perf_counter()
        if tiles:
            broadway("shot", "--tiles", "--count", "10", "--tab", tab, "-o", str(HERE / "tiles"))
        else:
            broadway("scroll", "top", "--tab", tab)
            for index in range(10):
                broadway("shot", "--tab", tab, "-o", str(HERE / f"tile-{index}.png"))
                broadway("scroll", "down", "--tab", tab)
        ten.append((time.perf_counter() - began) * 1000)
    summary("plain shot", plain)
    summary("full-page shot", whole)
    summary("ten tiles" if tiles else "ten scroll-and-shot pairs", ten)
    broadway("close", "--tab", tab)


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = "Shots Probe"
    os.environ.pop("BROADWAY_TAB", None)
    os.environ.pop("SSH_CONNECTION", None)
    HERE.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    global BASE
    BASE = base
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sv.wipe()
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        wanted = sys.argv[1:] or ["all"]
        if "speed" in wanted:
            speed(base)
        if "all" in wanted or "shots" in wanted:
            shots(base)
        if "person" in wanted:
            print(broadway("shot", "--tiles", "--tab", person_tab("")).stderr, flush=True)
        if "hold" in wanted:
            hold(base)
        if "given" in wanted:
            (HERE / "note-in.txt").write_bytes(FILE)
            given(base)
        if "kept" in wanted:
            plain_upload(base)
    finally:
        subprocess.run([BENCH, "--world", WORLD, "quit"], capture_output=True)
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good", flush=True)
    sys.exit(1 if failures else 0)


def shots(base):
    (HERE / "note-in.txt").write_bytes(FILE)
    tab = broadway("open", base + "short").stdout.strip()
    broadway("wait", "Small text", "--tab", tab)
    broadway("resize", "1000", "700", "--tab", tab)
    size_and_format(tab)
    one_element(tab)
    marks(tab)
    if_changed(tab)
    broadway("close", "--tab", tab)
    tab = broadway("open", base + "long").stdout.strip()
    count = tiles(tab)
    streams(tab, count)
    downloads(base, tab)
    broadway("close", "--tab", tab)
    given(base)
    mcp(base)


main()

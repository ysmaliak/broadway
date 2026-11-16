#!/usr/bin/env python3
"""Every popover's arrow is the colour of the popover it hangs from.

Build first (`./build.sh`), then `python3 Tests/popover_arrow.py [OUT]`. A test
copy in a world of its own, its window shown below the desktop, where nothing
shows on a screen and a capture still pictures it. Each popover is opened
through the bench (the bookmark card and list, the extensions list, a space's
Look, the blocked pop-ups and translation signs, an extension's own popup),
dark and light, over a white and a black page, the column on the left and on
the right, in a glass space and in a navy one. The popover's own rect is pictured, and the
browser's whole window, into OUT (`.context/popover-arrow` by default), with
the arrow zoomed. Its arrow and its body just past the arrow's base are read and
must be the same colour. BROADWAY_APP picks another build, for before and after.
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("popover-arrow")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/popover-arrow")
SHOT = Path(tempfile.gettempdir()) / f"broadway-windows-shot-{os.getpid()}"
WIDTH, HEIGHT = 1100, 700
WINDOW = [0]
PID = [0]
FRAMED = [""]
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.strip("/")
        if path.startswith("popups"):
            body = ("<!doctype html><title>Pop</title><body style='background:white'>"
                    "<script>setTimeout(function(){ window.open('/white', '_blank', 'width=300,height=200') }, 300)</script>")
        elif path.startswith("french"):
            words = " ".join(["Bonjour tout le monde, voici une page en français."] * 40)
            body = f"<!doctype html><html lang=fr><title>Fr</title><body style='background:white'><p>{words}</p>"
        else:
            colour = "black" if path.startswith("black") else "white"
            ink = "white" if colour == "black" else "black"
            words = " ".join(["words"] * 400)
            body = (f"<!doctype html><title>{path.title()}</title>"
                    f"<body style='margin:12px;background:{colour};color:{ink};font:20px system-ui'><p>{words}</p>")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def read_png(path):
    data = Path(path).read_bytes()
    pos, idat, width, height, kind = 8, b"", 0, 0, 6
    while pos < len(data):
        size, name = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + size]
        pos += 12 + size
        if name == b"IHDR":
            width, height, _, kind = struct.unpack(">IIBB", body[:10])
        elif name == b"IDAT":
            idat += body
    step = {6: 4, 2: 3}[kind]
    raw, stride = zlib.decompress(idat), width * step
    rows, above, at = [], bytearray(stride), 0
    for _ in range(height):
        kind_of, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            a = line[x - step] if x >= step else 0
            b = above[x]
            c = above[x - step] if x >= step else 0
            if kind_of == 1: line[x] = (line[x] + a) & 255
            elif kind_of == 2: line[x] = (line[x] + b) & 255
            elif kind_of == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif kind_of == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        above = line
    return width, height, step, rows


def pixel(picture, x, y):
    width, height, step, rows = picture
    x, y = max(0, min(width - 1, int(x))), max(0, min(height - 1, int(y)))
    return tuple(rows[y][x * step:x * step + step])


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(name, body):
        return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF)
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    Path(path).write_bytes(data)


def zoom(picture, path, cx, cy, half=40, by=6):
    out = []
    for y in range(2 * half):
        line = bytearray()
        for x in range(2 * half):
            line += bytes(pixel(picture, cx - half + x, cy - half + y)[:3]) * by
        out += [line] * by
    write_png(path, 2 * half * by, 2 * half * by, out)


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1",
                    "--env", "SEARCH_TRANSLATE_FAKE=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def stage(dark):
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})
    WINDOW[0], PID[0] = staged["window"], staged["pid"]
    time.sleep(0.8)


def popovers():
    return [w for w in sv.cmd({"do": "probe"})["windows"] if "Popover" in w["kind"] and w["visible"]]


def until(check, within=6.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.15)
    return check()


def shoot(numbers, path, framing=None):
    path.unlink(missing_ok=True)
    command = [str(SHOT), str(PID[0]), ",".join(str(n) for n in numbers), str(path)]
    if framing:
        command.append(str(framing))
    said = subprocess.run(command, capture_output=True, text=True).stdout
    FRAMED[0] = said.rsplit(" at ", 1)[-1].strip() if " at " in said else ""
    return read_png(path) if path.exists() else None


BAND = 13


def changed(over, under, x, y):
    if over[2] == 4 and pixel(over, x, y)[3] < 200:
        return False
    return max(abs(p - q) for p, q in zip(pixel(over, x, y)[:3], pixel(under, x, y)[:3])) > 2


def arrow(over, under, scale):
    width, height = over[0], over[1]
    band, corner = int(BAND * scale), int(24 * scale)
    best = None
    for side in ("top", "bottom", "left", "right"):
        along = range(corner, (width if side in ("top", "bottom") else height) - corner)
        counts = []
        for i in along:
            n = 0
            for d in range(band):
                x, y = {"top": (i, d), "bottom": (i, height - 1 - d),
                        "left": (d, i), "right": (width - 1 - d, i)}[side]
                n += changed(over, under, x, y)
            counts.append(n)
        stretch = int(30 * scale)
        usual = sorted(counts)[len(counts) // 2]
        sums = [sum(counts[k:k + stretch]) - usual * stretch for k in range(max(1, len(counts) - stretch))]
        k = max(range(len(sums)), key=lambda k: sums[k])
        peak = max(range(k, min(len(counts), k + stretch)), key=lambda j: counts[j]) + corner
        if best is None or sums[k] > best[0]:
            best = (sums[k], side, peak)
    return best[1], best[2]


def read(picture, side, middle, scale):
    width, height = picture[0], picture[1]

    def at(depth):
        d = int(depth * scale)
        return {"top": (middle, d), "bottom": (middle, height - 1 - d),
                "left": (d, middle), "right": (width - 1 - d, middle)}[side]
    tip, body = at(BAND - 5), at(BAND + 8)
    return tip, body, pixel(picture, *tip)[:3], pixel(picture, *body)[:3]


def near(a, b, by):
    return max(abs(p - q) for p, q in zip(a, b)) <= by


def capture(name, label, closer=None):
    up = until(popovers, 4)
    if not up:
        t.ok(f"{label}: the popover opened", False)
        return
    time.sleep(0.9)
    number = up[-1]["number"]
    shoot([WINDOW[0]], OUT / f"{name}-in-window.png")
    over = shoot([WINDOW[0]], OUT / f"{name}.png", framing=number)
    rect = FRAMED[0]
    (closer or shut)()
    if not until(lambda: not popovers(), 3):
        t.ok(f"{label}: the popover closed for the picture under it", False)
        return
    time.sleep(0.6)
    (OUT / "under").mkdir(exist_ok=True)
    under = shoot([WINDOW[0]], OUT / "under" / f"{name}.png", framing=rect)
    if not over or not under:
        t.ok(f"{label}: pictured", False, "no picture (screen recording permission?)")
        return
    scale = over[0] / up[-1]["frame"][2]
    side, middle = arrow(over, under, scale)
    readings = [read(over, side, middle + int(shift * scale), scale) for shift in (0, -3, 3, -6, 6, -9, 9, -12, 12)]
    inside = [r for r in readings if changed(over, under, *r[0])] or readings[:1]
    tip, body, a, b = next((r for r in inside if near(r[2], r[3], 8)), inside[0])
    zoom(over, OUT / f"{name}-arrow.png", (tip[0] + body[0]) // 2, (tip[1] + body[1]) // 2, half=int(22 * scale))
    t.ok(f"{label}: the arrow ({side}) is the popover's colour", near(a, b, 8), (a, b))


def shut():
    sv.cmd({"do": "ui", "bookmarksList": False, "editlook": False, "extensions": False})
    if popovers():
        sv.cmd({"do": "ui", "windowPointer": [WIDTH / 2, HEIGHT - 40], "pointerPhase": "down"})
        sv.cmd({"do": "ui", "windowPointer": [WIDTH / 2, HEIGHT - 40], "pointerPhase": "up"})
    until(lambda: not popovers(), 3)
    time.sleep(0.6)


def close():
    shut()


def press_sign(tab, offset):
    rows = sv.cmd({"do": "rowframes"})["rows"]
    x, y, w, h = rows[tab]
    at = [x + offset, y + h / 2]
    sv.cmd({"do": "ui", "windowPointer": at, "pointerPhase": "down"})
    sv.cmd({"do": "ui", "windowPointer": at, "pointerPhase": "up"})


def open_sign(tab):
    for offset in (40, 34, 46, 28, 52):
        press_sign(tab, offset)
        if until(popovers, 1.2):
            return lambda: press_sign(tab, offset)
    return None


def extension_folder():
    folder = Path(tempfile.mkdtemp(prefix="broadway-popover-ext-"))
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Arrow", "version": "1.0",
        "action": {"default_title": "Arrow", "default_popup": "popup.html"},
    }))
    (folder / "popup.html").write_text(
        "<!doctype html><title>Arrow</title><style>@media (prefers-color-scheme: dark) { html { background: #1e1e1e; color: #eee } }</style>"
        "<body style='margin:0;width:260px;height:160px'><p style='margin:20px;font:13px system-ui'>An extension's popup</p>")
    return folder


def wanted(name):
    return not ONLY or any(name.startswith(o) for o in ONLY)


def round_of(dark, page, side, glass=False, navy=False):
    tag = f"{'dark' if dark else 'light'}-{page}-{side}" + ("-glass" if glass else "") + ("-navy" if navy else "")
    stage(dark)
    sv.cmd({"do": "ui", "side": side})
    deep = {"colours": ["000354", "2404AA"], "intensity": 1, "grain": 0} if navy else {}
    sv.cmd({"do": "space", "action": "look", "glass": glass, "transparency": 0.6 if glass else 0, **deep})
    sv.cmd({"do": "select", "id": sv.sp("open", url=f"{BASE}/{page}")["resultID"]})
    time.sleep(1.2)

    if wanted("bookmark-card"):
        sv.cmd({"do": "ui", "bookmarkCard": True})
        capture(f"bookmark-card-{tag}", f"bookmark card, {tag}")
        close()
    if wanted("space-look"):
        sv.cmd({"do": "ui", "editlook": True})
        capture(f"space-look-{tag}", f"space look, {tag}")
        close()


def signs(dark, side):
    tag = f"{'dark' if dark else 'light'}-{side}"
    stage(dark)
    sv.cmd({"do": "ui", "side": side})
    if wanted("blocked-popups"):
        tab = sv.sp("open", url=f"{BASE.replace('127.0.0.1', 'localhost')}/popups")["resultID"]
        time.sleep(1.5)
        capture(f"blocked-popups-{tag}", f"blocked pop-ups, {tag}", open_sign(tab))
        sv.sp("close", id=tab)
    if wanted("translate"):
        tab = sv.sp("open", url=f"{BASE}/french")["resultID"]
        time.sleep(1.2)
        sv.cmd({"do": "translate", "id": tab})
        time.sleep(1.5)
        capture(f"translate-{tag}", f"translate, {tag}", open_sign(tab))
        sv.sp("close", id=tab)


EXTENSION = [""]


def install():
    sv.cmd({"do": "ext-folder", "path": str(extension_folder()), "yes": True})
    loaded = until(lambda: [e for e in sv.cmd({"do": "extensions"}).get("extensions", []) if e.get("name") == "Arrow" and e.get("loaded")], 10)
    t.ok("the test extension loaded", bool(loaded), sv.cmd({"do": "extensions"}))
    if loaded:
        EXTENSION[0] = loaded[0]["id"]
        sv.cmd({"do": "ext-pin", "id": EXTENSION[0], "on": True})
        time.sleep(0.6)


def extension(dark, side):
    if not wanted("extension-popup") or not EXTENSION[0]:
        return
    tag = f"{'dark' if dark else 'light'}-{side}"
    stage(dark)
    sv.cmd({"do": "ui", "side": side})
    time.sleep(0.6)
    sv.cmd({"do": "ext-press", "id": EXTENSION[0]})
    time.sleep(3.5)
    capture(f"extension-popup-{tag}", f"extension popup, {tag}", lambda: sv.cmd({"do": "ext-press", "id": EXTENSION[0]}))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowsShot.swift"), "-o", str(SHOT)], check=True)
    try:
        sv.setup(sidebar=True)
        launch()
        sv.cmd({"do": "window"})
        install()
        for dark in (True, False):
            for page in ("white", "black"):
                for side in ("left", "right"):
                    round_of(dark, page, side)
        for dark in (True, False):
            round_of(dark, "white", "left", glass=True)
        for dark in (True, False):
            round_of(dark, "white", "left", navy=True)
        for dark in (True, False):
            for side in ("left", "right"):
                signs(dark, side)
        for dark in (True, False):
            for side in ("left", "right"):
                extension(dark, side)
    finally:
        t.done()
        sv.finish()
        SHOT.unlink(missing_ok=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

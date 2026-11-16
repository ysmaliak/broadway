#!/usr/bin/env python3
"""The load pill, seen: window-only captures of a test copy while its page
is still loading, in each layout, with the pill's pixels measured.

A local page answers at once but holds an image open, so the tab stays
loading for as long as the probe wants. In each layout the probe sends the
tab in front to such a page, waits past the pill's 200 ms, and shoots the
window three times. Around the top centre of the page in front (above its
bar in a pair) it looks for a band that differs from the ground beside it,
and reports that band's size, place and contrast.

Run: python3 Tests/load_pill.py [out-dir]
"""
import json
import struct
import zlib
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

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


def rgb(picture, x, y):
    width, height, step, rows = picture
    x, y = max(0, min(width - 1, int(x))), max(0, min(height - 1, int(y)))
    return tuple(rows[y][x * step:x * step + 3])


sv.use("load-pill")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/load-pill")
WIDTH, HEIGHT = 1100, 700
BAR = 32
PILL = 128
WINDOW = [0]
t = sv.T()
results = []


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0].strip("/")
        if path.startswith("hang"):
            wait = float(path.split("-")[1]) if "-" in path else 120
            time.sleep(wait)
            body = b"GIF89a"
            kind = "image/gif"
        else:
            dark = path.startswith("dark")
            style = ("background:#111;color:#eee" if dark else "background:white;color:black") + ";font:18px system-ui"
            hold = path.split("~")[1] if "~" in path else "120"
            body = (f'<html style="{style};overflow:hidden"><title>{path}</title>'
                    f'<body style="margin:0;padding:60px 24px"><h1>{path}</h1><p>{" ".join(["words"] * 300)}</p>'
                    f'<img src="/hang-{hold}?{time.time()}" width=1 height=1></body></html>').encode()
            kind = "text/html"
        try:
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
COUNT = [0]
ALL = os.environ.get("LOAD_PILL_ALL") == "1"


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})["window"]
    time.sleep(0.9)


def shoot(name):
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    return read_png(path) if path.exists() else None


def state():
    return sv.sp("state")


def tab(id):
    return next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == id), None)


def load(page="white", hold=120):
    COUNT[0] += 1
    sv.cmd({"do": "ui", "go": f"{BASE}/{page}-{COUNT[0]}~{hold}"})


def lum(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def find_pill(picture, frame, paired):
    """The band that differs from the ground around the top centre of the
    page in front: (left, top, right, bottom) in points, its strongest
    contrast against what is beside it, and that ground."""
    scale = picture[0] / WIDTH
    top = frame["y"] - (BAR if paired else 0)
    mid = frame["x"] + frame["width"] / 2
    hits = []
    strongest, ground = 0, None
    y0, y1 = int((top - 12) * scale), int((top + 10) * scale)
    for y in range(max(0, y0), y1):
        left_ref = rgb(picture, (mid - PILL / 2 - 14) * scale, y)
        right_ref = rgb(picture, (mid + PILL / 2 + 14) * scale, y)
        for x in range(int((mid - PILL / 2 - 8) * scale), int((mid + PILL / 2 + 8) * scale)):
            c = rgb(picture, x, y)
            ref = left_ref if x < mid * scale else right_ref
            d = max(abs(p - q) for p, q in zip(c, ref))
            if d > 7:
                hits.append((x, y))
                if abs(lum(c) - lum(ref)) > strongest:
                    strongest, ground = abs(lum(c) - lum(ref)), ref
    if not hits:
        return None
    rows = {}
    for x, y in hits:
        rows.setdefault(y, []).append(x)
    band = [y for y, xs in rows.items() if len(xs) >= PILL * scale * 0.5]
    if not band:
        return None
    xs = [x for y in band for x in rows[y]]
    return {"left": min(xs) / scale, "right": (max(xs) + 1) / scale,
            "top": min(band) / scale, "bottom": (max(band) + 1) / scale,
            "contrast": round(strongest, 1), "ground": ground, "pageTop": top, "mid": mid}


def measure(label, front, paired):
    frames = {f["id"]: f for f in state()["paneFrames"]}
    frame = frames.get(front)
    if not frame:
        t.ok(f"{label}: the page in front is placed", False, list(frames))
        return
    best = None
    for n in range(3):
        picture = shoot(f"{label}" if n == 0 else f"{label}-{n}")
        if not picture:
            continue
        found = find_pill(picture, frame, paired)
        if found and (best is None or found["contrast"] > best["contrast"]):
            best = found
        time.sleep(0.17)
    loading = (tab(front) or {}).get("loading")
    entry = {"layout": label, "loading": loading, "pill": best}
    results.append(entry)
    print(f"      {label}: loading={loading} pill={json.dumps(best)}")
    t.ok(f"{label}: the page is still loading", loading is True, loading)
    t.ok(f"{label}: a pill shows", best is not None)
    if not best:
        return
    width, height = best["right"] - best["left"], best["bottom"] - best["top"]
    centre = (best["left"] + best["right"]) / 2
    t.ok(f"{label}: it is the pill's size (128×3)", 122 <= width <= 132 and 2 <= height <= 4.5, (width, height))
    t.ok(f"{label}: centred on the page in front", abs(centre - best["mid"]) <= 2, (centre, best["mid"]))
    t.ok(f"{label}: it stands out from what it sits on", best["contrast"] >= 60, best["contrast"])


def extra_layouts(a):

    stage(True)
    sv.cmd({"do": "ui", "side": "right"})
    time.sleep(1.2)
    load()
    time.sleep(0.8)
    measure("right-dark", a, False)
    sv.cmd({"do": "ui", "side": "left"})
    time.sleep(1.2)

    sv.cmd({"do": "ui", "folded": True})
    time.sleep(1.2)
    load()
    time.sleep(0.8)
    measure("folded-dark", a, False)
    sv.cmd({"do": "ui", "folded": False})
    time.sleep(1.2)

    for name, look in (("glass", {"glass": True, "transparency": 0.6}),
                       ("deep", {"colours": ["000354", "2404AA"], "intensity": 1.0}),
                       ("pale", {"colours": ["F0B4FF"], "intensity": 0.2})):
        sv.cmd({"do": "space", "action": "look", **look})
        time.sleep(1.2)
        for dark in (True, False):
            stage(dark)
            load()
            time.sleep(0.8)
            measure(f"{name}-{'dark' if dark else 'light'}", a, False)
        sv.cmd({"do": "space", "action": "look", "glass": False, "transparency": 0.0,
                "colours": ["8E8E93"], "intensity": 0.0})
        time.sleep(1)



def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False,
                    "tabs.groups": False, "bookmarks.bar": True})
        launch()
        sv.cmd({"do": "window"})
        sv.sp("enabled", on=True)
        stage(True)
        sv.cmd({"do": "space", "action": "new", "name": "Load"})
        time.sleep(1)
        a = sv.sp("open", url=f"{BASE}/white-a~1")["resultID"]
        time.sleep(1.5)

        for dark in (True, False):
            stage(dark)
            load()
            time.sleep(0.8)
            measure(f"single-{'dark' if dark else 'light'}", a, False)

        stage(True)
        load("dark")
        time.sleep(0.8)
        measure("single-dark-page", a, False)

        if ALL:
            extra_layouts(a)

        b = sv.sp("open", url=f"{BASE}/white-b~1")["resultID"]
        time.sleep(1.5)
        sv.sp("pair", id=b, **{"with": a}, side="right")
        time.sleep(1.5)
        for dark, front in ((True, a), (False, b)):
            stage(dark)
            sv.sp("focus", id=front)
            time.sleep(0.5)
            load()
            time.sleep(0.8)
            measure(f"pair-{'left' if front == a else 'right'}-{'dark' if dark else 'light'}", front, True)

        if ALL:
            stage(True)
            sv.cmd({"do": "ui", "folded": True})
            time.sleep(1.2)
            sv.sp("focus", id=a)
            time.sleep(0.3)
            load()
            time.sleep(0.8)
            measure("pair-folded-dark", a, True)
            sv.cmd({"do": "ui", "folded": False})
            time.sleep(1.2)

        sv.cmd({"do": "ui", "cards": False})
        time.sleep(1.2)
        if ALL:
            for dark in (True, False):
                stage(dark)
                sv.sp("focus", id=b)
                time.sleep(0.3)
                load()
                time.sleep(0.8)
                measure(f"cards-off-pair-{'dark' if dark else 'light'}", b, True)

        sv.sp("detach", id=b)
        time.sleep(1.2)
        sv.sp("select", id=a)
        time.sleep(0.8)
        for dark in (True, False):
            stage(dark)
            load()
            time.sleep(0.8)
            measure(f"cards-off-single-{'dark' if dark else 'light'}", a, False)
        stage(True)
        load("dark")
        time.sleep(0.8)
        measure("cards-off-single-dark-page", a, False)
        sv.cmd({"do": "ui", "cards": True})
        time.sleep(1.2)

        if ALL:
            sv.cmd({"do": "ui", "bookmarkCard": True})
            time.sleep(0.8)
            sv.cmd({"do": "ui", "bookmarksList": False})
            time.sleep(1.2)
            for dark in (True, False):
                stage(dark)
                load()
                time.sleep(0.8)
                measure(f"bookmarks-{'dark' if dark else 'light'}", a, False)

        names = [x["name"] for x in sv.cmd({"do": "space"})["spaces"]]
        sv.cmd({"do": "space", "action": "new", "name": "Other"})
        time.sleep(1)
        sv.sp("open", url=f"{BASE}/dark-other~1")
        time.sleep(1.2)
        sv.cmd({"do": "space", "action": "slide", "index": names.index("Load") + 1})
        time.sleep(1.6)
        stage(True)
        load()
        time.sleep(0.8)
        frame = {f["id"]: f for f in state()["paneFrames"]}.get(a)
        sv.cmd({"do": "space", "action": "hold", "dx": -40})
        time.sleep(0.5)
        picture = shoot("sliding")
        if picture and frame:
            scale = picture[0] / WIDTH
            row = int((frame["y"] - 4) * scale)
            ground = rgb(picture, (frame["x"] + 20) * scale, row)
            marks = [x / scale for x in range(int(12 * scale), picture[0] - int(12 * scale)) if abs(lum(rgb(picture, x, row)) - lum(ground)) > 20]
            print(f"      sliding: margin marks from {min(marks) if marks else None} to {max(marks) if marks else None}, stage from {frame['x']}")
            t.ok("sliding: the pill moves with its page", bool(marks) and (min(marks) + max(marks)) / 2 < frame["x"] + frame["width"] / 2 - 10,
                 (marks[:1], marks[-1:]))
            t.ok("sliding: and is never drawn over the column", bool(marks) and min(marks) >= frame["x"] - 1, marks[:3])
        sv.cmd({"do": "space", "action": "release"})
        time.sleep(1.6)

        stage(True)
        load(hold=1.4)
        time.sleep(0.6)
        picture = shoot("landing-before")
        frame = {f["id"]: f for f in state()["paneFrames"]}.get(a)
        seen = find_pill(picture, frame, False) if picture and frame else None
        time.sleep(2.2)
        picture = shoot("landing-after")
        gone = find_pill(picture, frame, False) if picture and frame else None
        t.ok("landing: the pill shows mid-load", seen is not None, seen)
        t.ok("landing: and is gone once the page has landed", gone is None and tab(a).get("loading") is False, gone)
    finally:
        (OUT / "measures.json").write_text(json.dumps(results, indent=1))
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import os
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pane-corners")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/after")
TAG = os.environ.get("TAG", "after")
SIZES = {1600: 960, 1000: 680}
WIDTHS = [int(w) for w in os.environ.get("WIDTHS", "1600,1000").split(",")]
ALL_LOOKS = {
    "pale": {"custom": "F2EEE6", "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1, "glass": False, "transparency": 0, "grain": 0},
    "black": {"custom": "000000", "intensity": 2, "glass": False, "transparency": 0, "grain": 0},
    "glass": {"custom": "8A93A6", "intensity": 0.6, "glass": True, "transparency": 0.7, "grain": 0},
}
LOOKS = [n for n in os.environ.get("LOOKS", "pale,vivid,black").split(",") if n in ALL_LOOKS]
THEMES = [x for x in os.environ.get("THEMES", "light,dark").split(",") if x in ("light", "dark")]
STATES = set(filter(None, os.environ.get("STATES", "").split(",")))
CORNER, BAR = 11, 32
WINDOW = [0]
SIZE = [1600, 960]
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0] or "page"
        dark = name.startswith("dark")
        style = "background:#1c1c1e;color:#eee" if dark else "background:white;color:#222"
        words = " ".join(["Words on a page in its card."] * 120)
        body = (f"<!doctype html><meta charset=utf-8><title>{name}</title>"
                f"<html style='{style};overflow:hidden'><body style='font:16px -apple-system;margin:40px'>"
                f"<h1>{name}</h1><p>{words}</p></body></html>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
server.daemon_threads = True
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


def rgb(picture, x, y):
    width, height, step, rows = picture
    x, y = max(0, min(width - 1, int(x))), max(0, min(height - 1, int(y)))
    return tuple(rows[y][x * step:x * step + 3])


def near(a, b, by=12):
    return all(abs(p - q) <= by for p, q in zip(a, b))


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(name, body):
        return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF)
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    Path(path).write_bytes(data)


def crop(picture, name, x0, y0, w, h, zoom=1):
    out = []
    for y in range(int(h)):
        line = bytearray()
        for x in range(int(w)):
            line += bytes(rgb(picture, x0 + x, y0 + y)) * zoom
        for _ in range(zoom):
            out.append(line)
    write_png(OUT / f"{TAG}-{name}.png", int(w) * zoom, int(h) * zoom, out)


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def stage(dark, width):
    SIZE[:] = [width, SIZES[width]]
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": SIZE})
    WINDOW[0] = staged["window"]
    sv.cmd({"do": "ui", "look": "dark" if dark else "light"})
    time.sleep(0.8)


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{TAG}-{name}.png"
    path.unlink(missing_ok=True)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    if not path.exists():
        t.ok(f"{name}: pictured", False)
        return None
    return read_png(path)


def panes():
    return {f["id"]: f for f in sv.sp("state")["paneFrames"]}


def pair_frames(a, b):
    frames = panes()
    if a not in frames or b not in frames:
        return None
    fa, fb = frames[a], frames[b]
    return (fa, fb) if fa["x"] < fb["x"] else (fb, fa)


def inner_corners(name, picture, frames):
    s = picture[0] / SIZE[0]
    left, right = frames
    gx = (left["x"] + left["width"] + right["x"]) / 2
    top = left["y"] - BAR
    bottom = left["y"] + left["height"]
    crop(picture, f"{name}-gutter-top", (gx - 60) * s, (top - 16) * s, 120 * s, 70 * s, zoom=2)
    crop(picture, f"{name}-gutter-bottom", (gx - 60) * s, (bottom - 50) * s, 120 * s, 66 * s, zoom=2)
    crop(picture, f"{name}-outer-top", (left["x"] - 16) * s, (top - 16) * s, 90 * s, 70 * s, zoom=2)
    crop(picture, f"{name}-outer-bottom", (right["x"] + right["width"] - 74) * s, (bottom - 50) * s, 90 * s, 66 * s, zoom=2)
    inset = 1.5
    spots = {
        "left top-right": (left["x"] + left["width"] - inset, top + inset),
        "right top-left": (right["x"] + inset, top + inset),
        "left bottom-right": (left["x"] + left["width"] - inset, bottom - inset),
        "right bottom-left": (right["x"] + inset, bottom - inset),
    }
    report, good = [], True
    for label, (x, y) in spots.items():
        gutter = rgb(picture, gx * s, y * s)
        deep = rgb(picture, (x - inset * 4 if "left " in label[:5] else x + inset * 4) * s,
                   (y + inset * 4 if "top" in label else y - inset * 4) * s)
        corner = rgb(picture, x * s, y * s)
        round_ = near(corner, gutter, 14) and not near(deep, gutter, 6)
        good &= round_
        report.append((label, corner, gutter, deep))
    t.ok(f"{name}: every corner where the cards meet is round", good, report)


def opened(name):
    id = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
    time.sleep(0.6)
    return id


def wanted(state):
    return not STATES or state in STATES


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False, "tabs.groups": False,
                    "welcome.show": False})
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "250"], check=True)
        launch()
        sv.cmd({"do": "window"})
        sv.sp("enabled", on=True)
        stage(False, WIDTHS[0])
        sv.cmd({"do": "space", "action": "new", "name": "Corners"})
        time.sleep(1)
        a = opened("left-page")
        b = opened("right-page")
        c = opened("single-page")
        sv.sp("select", id=a)
        sv.sp("pair", id=b, **{"with": a}, side="right")
        time.sleep(1.4)
        for theme in THEMES:
            for look in LOOKS:
                for width in WIDTHS:
                    tag = f"{theme}-{look}-{width}"
                    stage(theme == "dark", width)
                    sv.cmd({"do": "space", "action": "look", **ALL_LOOKS[look]})
                    sv.sp("focus", id=a)
                    time.sleep(1.2)
                    if wanted("pair"):
                        picture = shoot(f"{tag}-pair")
                        frames = pair_frames(a, b)
                        if picture and frames:
                            inner_corners(f"{tag}-pair", picture, frames)
        theme_states = THEMES
        for theme in theme_states:
            tag = f"{theme}-pale-1600"
            stage(theme == "dark", 1600)
            sv.cmd({"do": "space", "action": "look", **ALL_LOOKS["pale"]})
            time.sleep(0.8)
            if wanted("focus"):
                sv.sp("focus", id=b)
                time.sleep(0.8)
                picture = shoot(f"{tag}-focus-right")
                frames = pair_frames(a, b)
                if picture and frames:
                    inner_corners(f"{tag}-focus-right", picture, frames)
                sv.sp("focus", id=a)
                time.sleep(0.6)
            if wanted("drag"):
                frames = pair_frames(a, b)
                if frames:
                    left = frames[0]
                    x, y = left["x"] + left["width"] / 2, left["y"] - BAR / 2
                    sv.sp("mouse", points=[[x, y], [x + 20, y], [x + 80, y], [x + 160, y]], hold=True, to="view")
                    time.sleep(0.5)
                    picture = shoot(f"{tag}-drag")
                    if picture:
                        s = picture[0] / SIZE[0]
                        crop(picture, f"{tag}-drag-gutter-top", (left["x"] + left["width"] - 40) * s, (left["y"] - BAR - 20) * s,
                             300 * s, 90 * s, zoom=2)
                    sv.sp("mouse", points=[[x + 160, y], [x, y]], resume=True, to="view")
                    time.sleep(1.2)
            if wanted("swap"):
                sv.sp("swap")
                time.sleep(0.09)
                shoot(f"{tag}-swap-mid")
                time.sleep(1.2)
                sv.sp("swap")
                time.sleep(1.2)
            if wanted("apart"):
                sv.sp("detach", id=b)
                time.sleep(0.08)
                shoot(f"{tag}-apart-mid")
                time.sleep(1.2)
                sv.sp("select", id=a)
                sv.sp("pair", id=b, **{"with": a}, side="right")
                time.sleep(0.08)
                shoot(f"{tag}-forming-mid")
                time.sleep(1.4)
            if wanted("find"):
                sv.sp("focus", id=a)
                sv.cmd({"do": "find", "text": "Words"})
                time.sleep(0.9)
                picture = shoot(f"{tag}-find")
                frames = pair_frames(a, b)
                if picture and frames:
                    inner_corners(f"{tag}-find", picture, frames)
                sv.cmd({"do": "find", "close": True})
                time.sleep(0.8)
            if wanted("dev"):
                sv.sp("focus", id=a)
                time.sleep(0.4)
                try:
                    sv.cmd({"do": "dev", "action": "off", "values": []})
                    time.sleep(2)
                    picture = shoot(f"{tag}-developer")
                    frames = pair_frames(a, b)
                    if picture and frames:
                        inner_corners(f"{tag}-developer", picture, frames)
                    sv.cmd({"do": "dev", "action": "off", "values": []})
                except RuntimeError as error:
                    print("  ..   developer mode:", error)
                time.sleep(1)
            if wanted("single"):
                sv.sp("select", id=c)
                time.sleep(1)
                shoot(f"{tag}-single")
                if wanted("peek"):
                    sv.cmd({"do": "peek", "url": f"{BASE}/peeked-page"})
                    time.sleep(1.4)
                    shoot(f"{tag}-peek")
                    sv.cmd({"do": "peek", "url": "close"})
                    time.sleep(0.8)
                sv.sp("select", id=a)
                time.sleep(1)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

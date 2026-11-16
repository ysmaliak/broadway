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

sv.use("page-clip")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/page-clip")
WIDTH, HEIGHT = 1100, 700
CORNER = 11
BAR = 32
WINDOW = [0]
COLOURS = {"A": (0x2f, 0x7d, 0x9a), "B": (0xb0, 0x55, 0x30), "C": (0x4a, 0x8a, 0x4a)}
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        key = name.split("-")[0]
        if key == "white":
            style = "background:white;color:black;font:20px Times"
        else:
            r, g, b = COLOURS.get(key, (0x55, 0x55, 0x55))
            style = f"background:rgb({r},{g},{b});color:white;font:20px system-ui"
        words = " ".join(["words"] * 600)
        body = (f'<html style="{style};overflow:hidden"><title>{name}</title>'
                f'<body style="margin:12px"><h1 style="font-size:56px">{name}</h1><p>{words}</p></body></html>').encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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


def rgb(picture, x, y):
    width, height, step, rows = picture
    x, y = max(0, min(width - 1, int(x))), max(0, min(height - 1, int(y)))
    return tuple(rows[y][x * step:x * step + 3])


def near(a, b, by=14):
    return all(abs(p - q) <= by for p, q in zip(a, b))


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(name, body):
        return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF)
    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))
    Path(path).write_bytes(data)


def crop(picture, name, cx, cy, half=26, zoom=8):
    width, height, step, rows = picture
    x0, y0 = int(cx - half), int(cy - half)
    out = []
    for y in range(2 * half):
        line = bytearray()
        for x in range(2 * half):
            line += bytes(rgb(picture, x0 + x, y0 + y)) * zoom
        for _ in range(zoom):
            out.append(line)
    write_png(OUT / f"{name}.png", 2 * half * zoom, 2 * half * zoom, out)


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


def of(c, key, by=30):
    return near(c, COLOURS[key], by)


def box(picture, key, row):
    width, height = picture[0], picture[1]
    xs = [x for r in range(row - 24, row + 25, 4) for x in range(width) if of(rgb(picture, x, r), key)]
    if not xs:
        return None
    left, right = min(xs), max(xs)
    columns = [(left + right) // 2, left + 20, right - 20]
    ends = [[y for y in range(height) if of(rgb(picture, x, y), key)] for x in columns]
    ends = [ys for ys in ends if ys]
    return (left, min(ys[0] for ys in ends), right, max(ys[-1] for ys in ends)) if ends else None


def meeting(label, picture, scale, whole=True):
    if not picture:
        t.ok(f"{label}: pictured", False)
        return
    row = int(picture[1] * 0.6)
    a, b = box(picture, "A", row), box(picture, "B", row)
    t.ok(f"{label}: both pages found", a is not None and b is not None, (a, b))
    if not a or not b:
        return
    gutter = (a[2] + b[0]) / 2
    top, bottom = max(a[1], b[1]), min(a[3], b[3])
    crop(picture, f"{label}-top", gutter, top, half=int(18 * scale))
    crop(picture, f"{label}-bottom", gutter, bottom, half=int(18 * scale))
    inset = int(2 * scale)
    reach = int(CORNER * scale)
    seam = []
    for key, x, y in (("A", a[2] - inset, a[1] + inset), ("B", b[0] + inset, b[1] + inset)):
        seam.append((key, x, y, rgb(picture, x, y), of(rgb(picture, x, y), key)))
    t.ok(f"{label}: each page meets its bar square", all(s[-1] for s in seam), seam)
    mid_y = top + (bottom - top) // 3
    ground = rgb(picture, gutter, mid_y)
    deep = int(CORNER * scale * 0.85)
    round_ = []
    for key, x, y, dx, dy in (("A", a[2], a[3], -1, -1), ("B", b[0], b[3], 1, -1)):
        corner, inside = rgb(picture, x + dx * inset // 2, y + dy * inset // 2), rgb(picture, x + dx * deep, y + dy * deep)
        round_.append((key, corner, inside, not of(corner, key) and of(inside, key)))
    bar_top = top - int(BAR * scale)
    for x in (a[2] - inset // 2, b[0] + inset // 2):
        corner = rgb(picture, x, bar_top + inset // 2)
        round_.append(("bar", corner, ground, near(corner, ground, 14)))
    t.ok(f"{label}: where the cards meet, their corners are round (the pages' bottoms, the bars' tops)",
         all(r[-1] for r in round_), round_)
    columns = [x for x in range(a[2] + 1, b[0]) if abs(x - gutter) <= 1.5 * scale
               and not of(rgb(picture, x, mid_y), "A") and not of(rgb(picture, x, mid_y), "B")]
    uneven = []
    for x in columns:
        at_mid = rgb(picture, x, mid_y)
        for y in list(range(top + inset, top + reach)) + list(range(bottom - reach, bottom - inset)):
            if not near(rgb(picture, x, y), at_mid, 18):
                uneven.append((x, y, rgb(picture, x, y), at_mid))
    t.ok(f"{label}: the gutter is the same at the frame's top and bottom edges as in its middle",
         len(columns) > 0 and not uneven, (len(columns), uneven[:4]))
    if whole:
        outer(label, picture, (a[0], top, b[2], bottom), scale)


def outer(label, picture, frame, scale):
    left, top, right, bottom = frame
    top -= int(BAR * scale)
    inset = int(CORNER * scale * 0.85)
    report, good = [], True
    for x, y, dx, dy, key in ((left, top, 1, 1, None), (right, top, -1, 1, None),
                              (left, bottom, 1, -1, "A"), (right, bottom, -1, -1, "B")):
        ground = rgb(picture, x - dx * 3 * scale, y + dy * 2 * scale)
        corner, inside = rgb(picture, x + dx, y + dy), rgb(picture, x + dx * inset, y + dy * inset)
        ok = near(corner, ground, 20) and (of(inside, key) if key else not near(inside, ground, 4))
        good &= ok
        report.append((corner, ground, inside))
    t.ok(f"{label}: the frame's four outer corners are round", good, report)


def single(label, picture, scale, round_=True):
    row = int(picture[1] * 0.6)
    a = box(picture, "C", row)
    t.ok(f"{label}: the page is found", a is not None)
    if not a:
        return
    left, top, right, bottom = a
    crop(picture, f"{label}-corner", left, top, half=int(18 * scale))
    corner = rgb(picture, left + 1, top + 1)
    inside = rgb(picture, left + int(CORNER * scale * 0.85), top + int(CORNER * scale * 0.85))
    if round_:
        t.ok(f"{label}: the page's corner is round", not of(corner, "C") and of(inside, "C"), (corner, inside))
    else:
        t.ok(f"{label}: the page's corner is square", of(corner, "C"), corner)


def white_meeting(label, picture, scale, left_id, right_id):
    frames = {f["id"]: f for f in state()["paneFrames"]}
    if left_id not in frames or right_id not in frames:
        t.ok(f"{label}: both pages placed", False, list(frames))
        return
    fa, fb = frames[left_id], frames[right_id]
    gx = (fa["x"] + fa["width"] + fb["x"]) / 2 * scale
    top, bottom = fa["y"] * scale, (fa["y"] + fa["height"]) * scale
    crop(picture, f"{label}-top", gx, top, half=int(18 * scale))
    crop(picture, f"{label}-bottom", gx, bottom, half=int(18 * scale))
    white = (255, 255, 255)
    inset = 2 * scale
    spots = [((fa["x"] + fa["width"]) * scale - inset, top + inset), (fb["x"] * scale + inset, top + inset)]
    seen = [(x, y, rgb(picture, x, y)) for x, y in spots]
    t.ok(f"{label}: white pages meet their bars square", all(near(c, white, 10) for _, _, c in seen), seen)
    edge = 1.5 * scale
    spots = [((fa["x"] + fa["width"]) * scale - edge, bottom - edge), (fb["x"] * scale + edge, bottom - edge)]
    seen = [(x, y, rgb(picture, x, y)) for x, y in spots]
    t.ok(f"{label}: white pages are round at the bottom where they meet", all(not near(c, white, 10) for _, _, c in seen), seen)


def state():
    return sv.sp("state")


def look(label, dark):
    stage(dark)
    picture = shoot(label)
    if picture:
        meeting(label, picture, picture[0] / WIDTH)
    return picture


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False,
                    "tabs.groups": False})
        launch()
        sv.cmd({"do": "window"})
        sv.sp("enabled", on=True)
        stage(True)
        sv.cmd({"do": "space", "action": "new", "name": "Clip"})
        time.sleep(1)
        white_a = sv.sp("open", url=f"{BASE}/white-two-a")["resultID"]
        time.sleep(0.6)
        white_b = sv.sp("open", url=f"{BASE}/white-two-b")["resultID"]
        time.sleep(0.6)
        sv.sp("pair", id=white_b, **{"with": white_a}, side="right")
        time.sleep(1.2)
        for dark in (True, False):
            stage(dark)
            picture = shoot(f"white-{'dark' if dark else 'light'}")
            if picture:
                white_meeting(f"white-{'dark' if dark else 'light'}", picture, picture[0] / WIDTH, white_a, white_b)

        sv.cmd({"do": "space", "action": "new", "name": "Pair"})
        time.sleep(1)
        a = sv.sp("open", url=f"{BASE}/A")["resultID"]
        time.sleep(0.6)
        b = sv.sp("open", url=f"{BASE}/B")["resultID"]
        time.sleep(0.6)
        sv.sp("pair", id=b, **{"with": a}, side="right")
        time.sleep(1.2)

        look("dark", True)
        look("light", False)

        stage(True)
        sv.cmd({"do": "ui", "toggleFold": True})
        time.sleep(1.2)
        picture = shoot("folded")
        if picture:
            meeting("folded", picture, picture[0] / WIDTH)
        sv.cmd({"do": "ui", "toggleFold": True})
        time.sleep(1.2)

        sv.cmd({"do": "ui", "side": "right"})
        time.sleep(1.2)
        look("right", True)
        sv.cmd({"do": "ui", "side": "left"})
        time.sleep(1.2)

        stage(True)
        frames = {f["id"]: f for f in state()["paneFrames"]}
        fa, fb = frames[a], frames[b]
        x = (fa["x"] + fa["width"] + fb["x"]) / 2
        y = fa["y"] + fa["height"] / 2
        sv.sp("mouse", points=[[x, y], [x - 30, y], [x - 80, y], [x - 120, y]], hold=True, to="view")
        time.sleep(0.4)
        picture = shoot("dragging")
        if picture:
            meeting("dragging", picture, picture[0] / WIDTH, whole=False)
        sv.sp("mouse", points=[[x - 120, y], [x - 120, y]], resume=True, to="view")
        time.sleep(0.8)
        sv.sp("even")
        time.sleep(1)

        sv.sp("swap")
        moving = []
        for _ in range(30):
            moving = sv.sp("motion")["motion"]
            if moving:
                break
            time.sleep(0.02)
        picture = shoot("swapping")
        t.ok("swapping: two pictures move", len(moving) == 2, moving)
        t.ok("swapping: the moving pictures carry the card's corner",
             len(moving) == 2 and all(m.get("framed") == [1] and m.get("radius") == [CORNER] for m in moving), moving)
        if picture:
            scale = picture[0] / WIDTH
            placed = [f for f in state()["paneFrames"] if f["id"] in (a, b)]
            if len(placed) == 2:
                left = min(f["x"] for f in placed) * scale
                bottom = max(f["y"] + f["height"] for f in placed) * scale
                crop(picture, "swapping-left-bottom", left, bottom, half=int(18 * scale))
                corner, ground = rgb(picture, left + 1, bottom - 1), rgb(picture, left - 3 * scale, bottom - 1)
                t.ok("swapping: the card's outer corner stays round while they move", near(corner, ground, 20),
                     (corner, ground))
        time.sleep(1.2)
        sv.sp("swap")
        time.sleep(1.2)

        names = [s["name"] for s in sv.cmd({"do": "space"})["spaces"]]
        here = names.index("Pair")
        stage(True)
        sv.cmd({"do": "space", "action": "hold", "dx": 30 if here > 0 else -30})
        time.sleep(0.5)
        picture = shoot("sliding")
        t.ok("sliding: pictured", picture is not None)
        sv.cmd({"do": "space", "action": "release"})
        time.sleep(1.4)

        c = sv.sp("open", url=f"{BASE}/C")["resultID"]
        time.sleep(1)
        sv.sp("select", id=c)
        time.sleep(1)
        stage(True)
        picture = shoot("single")
        if picture:
            single("single", picture, picture[0] / WIDTH)
        sv.cmd({"do": "ui", "cards": False})
        time.sleep(1)
        picture = shoot("cards-off")
        if picture:
            single("cards-off", picture, picture[0] / WIDTH, round_=False)
        sv.cmd({"do": "ui", "cards": True})
        time.sleep(1)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

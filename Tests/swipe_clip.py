#!/usr/bin/env python3
"""The column and the page card while spaces slide, and where they come to rest.

Build first (`./build.sh`), then `python3 Tests/swipe_clip.py [OUT]`. A test
copy in a world of its own (SEARCH_SHOWN, so motion runs as on screen), its
window put below the desktop where `screencapture -l` still pictures it
alone: cards on, the column on the left, a space "Work" with a grid of pins
and a space "Play" with rows, each on a page of its own strong colour.

- Mid-swipe, the columns run edge to edge: the clip is the sidebar's own
  frame, and the outgoing column's content right up to the sidebar's left
  edge (and the incoming one's up to its right edge) is the resting column
  moved by the swipe, pixel for pixel: no fade, no early cut at the inset.
  The page card's four corners stay round: ground at the corner, page
  inside it.
- A window-only film of a swipe and of a ⌃2 switch (FILM=0 skips it).
- After each interruption (a short slow swipe, one let go at half, one
  cancelled, the floating video's hover arriving mid-swipe, ⌃2 mid-swipe,
  a resize mid-swipe, a swipe into a running slide), the column is a whole
  page: no offset, no neighbour drawn, the edges as at rest.
- Light and dark, glass, cards off, and a split pair.
BROADWAY_APP picks another build, for before and after.
"""
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

sv.use("swipe-clip")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/swipe-clip")
WIDTH, HEIGHT = 1100, 700
WINDOW = [0]
COLOURS = {"Work": (0x34, 0x72, 0x91), "Play": (0x86, 0x48, 0x37), "Side": (0x3a, 0x8a, 0x4a)}
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("-")[0]
        r, g, b = COLOURS.get(name, (0x55, 0x55, 0x55))
        body = (f'<html style="background:rgb({r},{g},{b});color:white;font:40px system-ui">'
                f'<title>{self.path.strip("/")} WWWWWWWWWWWWWWWWWWWWWWWW</title><h1>{self.path.strip("/")}</h1></html>').encode()
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


def paged(c):
    return any(near(c, v, 26) for v in COLOURS.values())


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


def space(**f): return sv.cmd({"do": "space", **f})


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})["window"]
    time.sleep(0.8)


def shoot(name):
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    return read_png(path) if path.exists() else None


def column_width():
    return sv.cmd({"do": "probe"}).get("columnWidth", 252)


def card(picture, scale, column):
    """The page card's rectangle at rest, in pixels: where the page's colour starts and ends."""
    width, height = picture[0], picture[1]
    y = height // 2
    xs = [x for x in range(int(column * scale), width) if paged(rgb(picture, x, y))]
    if not xs:
        return None
    x = (xs[0] + xs[-1]) // 2
    ys = [yy for yy in range(height) if paged(rgb(picture, x, yy))]
    return (xs[0], ys[0], xs[-1], ys[-1]) if ys else None


def corners_round(label, picture, box, rest, scale):
    if not box:
        t.ok(f"{label}: the card is found", False)
        return
    left, top, right, bottom = box
    inset = int(10 * scale * 0.85)
    report = []
    good = True
    for x, y, dx, dy in ((left, top, 1, 1), (right, top, -1, 1), (left, bottom, 1, -1), (right, bottom, -1, -1)):
        corner, inside = rgb(picture, x + dx, y + dy), rgb(picture, x + dx * inset, y + dy * inset)
        ground = rgb(rest, x + dx, y + dy)
        ok = not paged(corner) and near(corner, ground, 24) and paged(inside)
        good &= ok
        report.append((corner, ground, inside))
    t.ok(f"{label}: the card's four corners stay round mid-slide", good, report)


def pages_x(column):
    edges = sv.cmd({"do": "columnscroll"}).get("edges", {})
    return edges.get("pagesMinX", 0), edges.get("pagesMaxX", column - 16)


def bounds_at_sides(label, column):
    left, far = pages_x(column)
    t.ok(f"{label}: mid-slide the clip is the sidebar's own edges", abs(left) < 0.5 and abs(far - column) < 0.5,
         (left, far, column))


def continuous(label, side, picture, source, shift, scale, near_edge, span=30, lo=None, hi=None):
    """Mid-slide pixels by the sidebar's edge are the resting column's, moved by SHIFT points."""
    height = picture[1]
    xs = range(int(lo), int(hi))
    matched = content = touching = at_edge = 0
    misses = []
    for y in range(int(150 * scale), height - int(70 * scale), 2):
        ground = rgb(source, 2 * scale, y)
        for x in xs:
            from_x = x - shift * scale
            want = [rgb(source, from_x + d, y) for d in (-1, 0, 1)]
            if all(near(w, ground, 40) for w in want):
                continue
            content += 1
            if abs(x - near_edge) <= 2:
                at_edge += 1
            if any(near(rgb(picture, x, y), w, 24) for w in want):
                matched += 1
                if abs(x - near_edge) <= 2:
                    touching += 1
            elif len(misses) < 4:
                misses.append((x, y, rgb(picture, x, y), want[1]))
    share = matched / content if content else 0
    t.ok(f"{label}: by the {side} edge the column is the resting one moved along, no fade, nothing cut early",
         content >= 40 and share >= 0.93 and touching >= min(3, at_edge), (content, round(share, 3), touching, at_edge, misses))


def edges_reach(label, picture, rest, coming, scale, column, swipe, cards):
    width = picture[0]
    edge = column * scale
    continuous(label, "left", picture, rest, swipe, scale, 0, lo=0, hi=30 * scale)
    if coming is not None:
        limit = edge - (0 if cards else 1.5 * scale)
        continuous(label, "right", picture, coming, column + swipe, scale, limit - 1,
                   lo=edge - 30 * scale, hi=limit)


def whole(label):
    time.sleep(1.4)
    s = space()
    t.ok(f"{label}: the column at rest on a whole page", s["swipe"] == 0 and s["next"] == -1,
         (s["swipe"], s["next"], s["current"]))
    return s


def mid(label, rest, scale, column, box, coming=None, dx=-110, cards=True):
    space(action="hold", dx=dx)
    time.sleep(0.5)
    picture = shoot(f"{label}-mid")
    s = space()
    t.ok(f"{label}: mid-swipe", s["swipe"] != 0 and s["next"] != -1, (s["swipe"], s["next"]))
    bounds_at_sides(label, column)
    if picture:
        edges_reach(label, picture, rest, coming, scale, column, s["swipe"], cards)
        if box:
            corners_round(label, picture, box, rest, scale)
    space(action="release")
    time.sleep(1.2)


WORK = [1]
CAPTURE = Path(os.environ["BROADWAY_PROBE_TOOLS"]) / "capture" if os.environ.get("BROADWAY_PROBE_TOOLS") else ROOT / ".context/capture"


def film(name, act, seconds=1.6):
    if os.environ.get("FILM") == "0":
        return
    if not CAPTURE.exists():
        CAPTURE.parent.mkdir(parents=True, exist_ok=True)
        made = subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)],
                              capture_output=True, text=True)
        if made.returncode:
            t.ok(f"film {name}: the window capture builds", False, made.stderr[-400:])
            return
    pid = next(iter(sv.holding() & sv.running()), None)
    folder = OUT / f"film-{name}"
    subprocess.run(["rm", "-rf", str(folder)])
    folder.mkdir(parents=True)
    run = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(WINDOW[0])], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or run.poll() is not None:
            break
        time.sleep(0.025)
    if run.poll() is not None:
        t.ok(f"film {name}: the test window is filmed", False, run.communicate()[0])
        return
    time.sleep(0.15)
    act()
    said = run.communicate()[0].strip()
    frames = sorted(folder.glob("*.png"))
    t.ok(f"film {name}: window-only frames", len(frames) >= 20, (len(frames), said))
    if frames and subprocess.run(["which", "ffmpeg"], capture_output=True).returncode == 0:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")])
        picture = read_png(frames[0])
        crop = int(column_width() * picture[0] / WIDTH) + 40
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                        "-vf", f"crop={crop}:ih:0:0,select='not(mod(n\\,4))',scale=iw/2:-1,tile=8x1",
                        "-frames:v", "1", str(OUT / f"{name}-strip.png")])


def go(index):
    space(action="go", index=WORK[0] + index - 1)
    time.sleep(1.2)


def look(label, dark, cards=True):
    stage(dark)
    go(2)
    coming = shoot(f"{label}-next-rest")
    go(1)
    rest = shoot(f"{label}-rest")
    scale = rest[0] / WIDTH
    column = column_width()
    box = card(rest, scale, column) if cards else None
    if cards:
        t.ok(f"{label}: the card is found at rest", box is not None)
    mid(label, rest, scale, column, box, coming, cards=cards)
    go(1)
    return rest, scale, column


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False,
                    "tabs.groups": False, "split": False})
        launch()
        sv.cmd({"do": "window"})
        stage(True)
        space(action="new", name="Work")
        time.sleep(1)
        for i in range(8):
            pin = sv.sp("open", url=f"{BASE}/Side-{i}")["resultID"]
            time.sleep(0.3)
            sv.cmd({"do": "pin", "id": pin})
        sv.sp("open", url=f"{BASE}/Work")
        time.sleep(0.8)
        space(action="new", name="Play")
        time.sleep(1)
        for i in range(5):
            sv.sp("open", url=f"{BASE}/Play-{i}")
            time.sleep(0.3)
        names = [s["name"] for s in space()["spaces"]]
        first = names.index("Work") + 1
        play = names.index("Play") + 1
        WORK[0] = first
        t.ok("Work then Play, side by side", play == first + 1, names)

        rest, scale, column = look("dark", True)
        look("light", False)
        stage(True)
        space(action="look", glass=True, transparency=0.6)
        time.sleep(1.2)
        look("glass-dark", True)
        space(action="look", glass=False, transparency=0.0)
        time.sleep(0.8)
        sv.cmd({"do": "ui", "cards": False})
        time.sleep(0.8)
        look("cards-off-dark", True, cards=False)
        sv.cmd({"do": "ui", "cards": True})
        time.sleep(0.8)

        stage(True)
        go(1)
        half = column / 2

        space(action="trackpad", stops=[-40], speed=60, momentum=False)
        whole("slow-short")
        go(1)
        space(action="trackpad", stops=[-half], speed=200, momentum=False)
        whole("half")
        go(1)
        space(action="trackpad", stops=[-half], speed=300, cancel=True)
        whole("cancelled")
        go(1)

        space(action="trackpad", stops=[-150], speed=250, momentum=True)
        time.sleep(0.25)
        space(action="held", on=True)
        time.sleep(0.2)
        space(action="held", on=False)
        whole("floating-video-hover-mid-swipe")
        go(1)

        space(action="hold", dx=-60)
        space(action="key", index=WORK[0] + 1)
        time.sleep(0.1)
        space(action="release")
        whole("ctrl-2-mid-swipe")
        go(1)

        space(action="hold", dx=-90)
        sv.cmd({"do": "resize", "width": WIDTH - 160, "height": HEIGHT - 60, "steps": 6})
        space(action="release")
        whole("resize-mid-swipe")
        stage(True)
        go(1)

        space(action="slide", index=WORK[0] + 1)
        time.sleep(0.08)
        space(action="trackpad", stops=[60], speed=400, momentum=False)
        whole("swipe-into-slide")
        go(1)
        whole("back-on-work")

        film("swipe", lambda: space(action="trackpad", stops=[-170], speed=260, momentum=True))
        whole("filmed-swipe")
        go(1)
        film("ctrl-2", lambda: space(action="key", index=WORK[0] + 1))
        whole("filmed-ctrl-2")
        go(1)

        go(2)
        for i in range(5, 30):
            sv.sp("open", url=f"{BASE}/Play-{i}")
            time.sleep(0.15)
        time.sleep(0.6)
        sv.cmd({"do": "columnscroll", "wheel": 300})
        time.sleep(0.15)
        shoot("scroller-rest")
        sv.cmd({"do": "columnscroll", "wheel": 60})
        space(action="hold", dx=110)
        time.sleep(0.2)
        shoot("scroller-mid")
        space(action="release")
        whole("scroller-released")
        go(1)

        try:
            sv.sp("enabled", on=True)
            front = sv.sp("state")["activeID"]
            a = sv.sp("open", url=f"{BASE}/Work-split")["resultID"]
            time.sleep(0.7)
            sv.sp("pair", id=a, **{"with": front}, side="right")
            time.sleep(1)
            stage(True)
            split_rest = shoot("split-rest")
            box = card(split_rest, scale, column)
            mid("split-dark", split_rest, scale, column, box)
            go(1)
        except Exception as error:
            t.ok("split pair staged", False, error)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

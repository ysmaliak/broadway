#!/usr/bin/env python3
"""The page's frame while spaces slide: it stays where it rests, and only what is inside it moves.

Build first (`./build.sh`), then `python3 Tests/swipe_frame.py [OUT]`. A test
copy in a world of its own (SEARCH_SHOWN, so motion runs as on screen), its
window below the desktop and filmed alone by its window id at 60 fps and 2x.
Three spaces side by side, each on a page of its own strong colour, all in
one look so the frame's ink is the same in each.

Every frame of every film is read against the film's first frame, at rest:

- The frame's edges: along the top, right and bottom sides the ground
  outside the card is the resting ground, and the edge's own pixels are
  a line that is neither that ground nor the page just inside it (the
  hairline is drawn over the page, so its colour follows the page under
  it); along the left side, where the sidebar's rows pass, the line is.
- A pair at rest draws its own outline, and its focused pane's is two
  pixels wide where a page's is one, on main too: a film that begins on a
  page and ends on a pair, or the other way, reads each spot of ground
  against the rests it knows (the first frame, the last, and a page
  alone), within 6. Two looks
  have a ground that is not one flat colour and a frame whose ink
  cross-fades, which ripples the line's soft pixels by a few levels; they
  are also read against the ground beside each spot in the same frame,
  within 16 (a card's edge crossing a spot moves it by 40 or more).
- The frame's corners: every pixel that is ground at rest (outside the
  curve) is the same ground, and every pixel that is page at rest (inside
  it) is not ground.
- Nothing bare inside: no pixel of the page area shows the ground.
- Pulled past the first or the last space, the page area is the resting
  picture, and the column's rows give no more than SpaceMotion.give.

Filmed: a swipe each way, a slow drag out and back, a pull past each end, a
pull past a whole page toward a neighbour, a hard flick onto the first and
the last space, ⌃-number to the next space and across two, the mouse wheel
at the last space; then a sidebar off the pixel grid, cards off, the folded
sidebar, a split pair, two looks, and a new tab page and History (a page
of the browser's own; Settings is a window whenever the app is on
screen). ONLY=name,name runs some of them.
BROADWAY_PROBE_APP picks another build, for before and after.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("swipe-frame")

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/swipe-frame")
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
WIDTH, HEIGHT = 1100, 700
WINDOW = [0]
GIVE = 18
COLOURS = {"One": (0x2f, 0x7d, 0x9c), "Two": (0x9c, 0x4a, 0x2f), "Three": (0x3a, 0x8a, 0x4a), "Pair": (0x7a, 0x3a, 0x8a)}
CAPTURE = Path(os.environ["BROADWAY_PROBE_TOOLS"]) / "capture" if os.environ.get("BROADWAY_PROBE_TOOLS") else ROOT / ".context/capture"
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("-")[0]
        r, g, b = COLOURS.get(name, (0x66, 0x55, 0x22))
        body = (f'<html style="background:rgb({r},{g},{b});color:white;font:44px system-ui"><title>{self.path.strip("/")}</title>'
                f'<h1 style="margin:120px 80px">{self.path.strip("/")}</h1></html>').encode()
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


def stage(dark=True):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})["window"]
    time.sleep(0.8)


def press(code, chars, *mods):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})
    time.sleep(0.8)


def go(index):
    space(action="go", index=index)
    time.sleep(1.3)


class Film:
    def __init__(self, folder, width, height, count):
        self.folder, self.width, self.height, self.count = folder, width, height, count

    def last(self):
        size = self.width * self.height * 3
        return subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(sorted(self.folder.glob("*.png"))[-1]),
                               "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout[:size]

    def frames(self):
        size = self.width * self.height * 3
        run = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-framerate", "60", "-i", str(self.folder / "%04d.png"),
                                "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], stdout=subprocess.PIPE)
        while True:
            data = run.stdout.read(size)
            if len(data) < size:
                break
            yield data
        run.wait()


def film(name, act, seconds=1.8):
    if not CAPTURE.exists():
        CAPTURE.parent.mkdir(parents=True, exist_ok=True)
        made = subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)],
                              capture_output=True, text=True)
        if made.returncode:
            t.ok(f"{name}: the window capture builds", False, made.stderr[-400:])
            return None
    pid = next(iter(sv.holding() & sv.running()), None)
    folder = OUT / f"film-{name}"
    subprocess.run(["rm", "-rf", str(folder)])
    folder.mkdir(parents=True)
    run = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(WINDOW[0]), "2"], stdout=subprocess.PIPE, text=True)
    for _ in range(240):
        if (folder / "ready").exists() or run.poll() is not None:
            break
        time.sleep(0.025)
    if run.poll() is not None:
        t.ok(f"{name}: the test window is filmed", False, run.communicate()[0])
        return None
    time.sleep(0.25)
    act()
    said = run.communicate()[0].strip()
    frames = sorted(folder.glob("*.png"))
    if len(frames) < 20:
        t.ok(f"{name}: window-only frames", False, (len(frames), said))
        return None
    probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                            "-of", "csv=p=0", str(frames[0])], capture_output=True, text=True).stdout.strip().split(",")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")])
    step = max(1, len(frames) // 24)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", f"select='not(mod(n\\,{step}))',scale=iw/4:-1,tile=6x4:padding=6", "-frames:v", "1",
                    str(OUT / f"{name}-sheet.jpg")])
    return Film(folder, int(probe[0]), int(probe[1]), len(frames))


def px(data, width, x, y):
    at = (y * width + x) * 3
    return data[at], data[at + 1], data[at + 2]


def off(a, b):
    return max(abs(a[0] - b[0]), abs(a[1] - b[1]), abs(a[2] - b[2]))


class Frame:
    """Where the page's frame rests, read from a film's first frame."""

    def __init__(self, rest, width, height, column, scale):
        self.rest, self.width, self.height = rest, width, height
        y = height // 2
        start = int(column * scale)
        self.ground = None
        self.box = None
        row = [px(rest, width, x, y) for x in range(width)]
        side = row[max(0, start - 8)]
        inside = [x for x in range(start - 2, width) if x >= 0 and off(row[x], side) > 40]
        if not inside:
            return
        mid = (inside[0] + inside[-1]) // 2
        page = row[mid]
        xs = [x for x in range(start - 6, width) if x >= 0 and off(row[x], page) <= 30]
        column_pixels = [px(rest, width, mid, yy) for yy in range(height)]
        ys = [yy for yy in range(height) if off(column_pixels[yy], page) <= 30]
        if not xs or not ys:
            return
        self.page = (xs[0], ys[0], xs[-1], ys[-1])
        self.outside = xs[-1] + 8 < width
        self.ground = row[min(width - 1, xs[-1] + 8)] if self.outside else side
        left = xs[0]
        while left > 0 and off(row[left - 1], side) > 2 and xs[0] - left < 4:
            left -= 1
        right = xs[-1]
        while right < width - 1 and off(row[right + 1], self.ground) > 2 and right - xs[-1] < 4:
            right += 1
        top = ys[0]
        while top > 0 and off(column_pixels[top - 1], self.ground) > 2 and ys[0] - top < 4:
            top -= 1
        bottom = ys[-1]
        while bottom < height - 1 and off(column_pixels[bottom + 1], self.ground) > 2 and bottom - ys[-1] < 4:
            bottom += 1
        self.box = (left, top, right, bottom)
        self.rim = (xs[0] - left, ys[0] - top, right - xs[-1], bottom - ys[-1])
        self.reach = int(16 * scale)
        self.build(scale)

    def over(self, rest):
        made = Frame.__new__(Frame)
        made.__dict__.update(self.__dict__)
        made.rest = rest
        made.other = self.rest
        made.ground = px(rest, self.width, *self.far) if self.far else self.ground
        return made

    def build(self, scale):
        left, top, right, bottom = self.box
        width, rest, reach = self.width, self.rest, self.reach
        self.same = []
        self.filled = []
        self.far = (min(width - 1, right + 6), (top + bottom) // 2) if self.outside else None
        out = 6
        deep = max(self.rim) + 4
        above, below = max(0, top - 5), min(self.height - 1, bottom + 5)
        for at in range(left + reach, right - reach, max(2, (right - left) // 60)):
            for y in range(max(0, top - out), top):
                self.same.append((at, y, "ground", at, above))
            for y in range(top, top + min(self.rim[1], 2)):
                self.same.append((at, y, "edge", at, top + deep))
            for y in range(bottom + 1, min(self.height, bottom + out + 1)):
                self.same.append((at, y, "ground", at, below))
            for y in range(bottom - min(self.rim[3], 2) + 1, bottom + 1):
                self.same.append((at, y, "edge", at, bottom - deep))
        beside = min(width - 1, right + 5)
        for at in range(top + reach, bottom - reach, max(2, (bottom - top) // 40)):
            for x in range(right + 1, min(width, right + out + 1)):
                self.same.append((x, at, "ground", beside, at))
            for x in range(right - min(self.rim[2], 2) + 1, right + 1):
                self.same.append((x, at, "edge", right - deep, at))
            for x in range(left, left + min(self.rim[0], 2)):
                self.same.append((x, at, "edge", left + deep, at))
        centre = px(rest, width, (left + right) // 2, (top + bottom) // 2)
        for cx, cy in ((left, top), (right, top), (left, bottom), (right, bottom)):
            xs = range(cx, cx + reach) if cx == left else range(cx - reach + 1, cx + 1)
            ys = range(cy, cy + reach) if cy == top else range(cy - reach + 1, cy + 1)
            ref = (cx + reach if cx == left else cx - reach, above if cy == top else below)
            for y in ys:
                for x in xs:
                    was = px(rest, width, x, y)
                    if off(was, self.ground) <= 2:
                        self.same.append((x, y, "ground", ref[0], ref[1]))
                    elif off(was, centre) <= 30:
                        self.filled.append((x, y))
        inset = 3 + max(self.rim)
        for y in range(top + inset, bottom - inset, 6):
            for x in range(left + inset, right - inset, 6):
                if off(px(rest, width, x, y), self.ground) > 12:
                    self.filled.append((x, y))
        for y in (top + inset, bottom - inset):
            for x in range(left + reach, right - reach, 2):
                if off(px(rest, width, x, y), self.ground) > 12:
                    self.filled.append((x, y))
        for x in (left + inset, right - inset):
            for y in range(top + reach, bottom - reach, 2):
                if off(px(rest, width, x, y), self.ground) > 12:
                    self.filled.append((x, y))
        self.same = [spot for spot in self.same if spot[2] != "edge" or self.line(rest, spot, self.ground)]

    def line(self, data, spot, ground):
        now = px(data, self.width, spot[0], spot[1])
        return off(now, px(data, self.width, spot[3], spot[4])) > 12 and off(now, ground) > 3

    def read(self, data, loose=False, lined=True, soft=3, after=None):
        width, rest = self.width, self.rest
        ground = px(data, width, *self.far) if loose and self.far else self.ground
        rests = [known for known in (rest, after, getattr(self, "other", None)) if known]
        moved = []
        for x, y, kind, rx, ry in self.same:
            now = px(data, width, x, y)
            if kind == "edge":
                if lined and not self.line(data, (x, y, kind, rx, ry), ground):
                    moved.append((x, y, kind, now, px(data, width, rx, ry)))
            elif any(off(now, px(known, width, x, y)) <= soft for known in rests):
                continue
            elif not loose or off(now, px(data, width, rx, ry)) > max(soft, 16):
                moved.append((x, y, kind, now, px(rest, width, x, y)))
        bare = [(x, y, px(data, width, x, y)) for x, y in self.filled if off(px(data, width, x, y), ground) <= 8]
        return moved, bare

    def still(self, data):
        left, top, right, bottom = self.box
        width, rest = self.width, self.rest
        checked = changed = 0
        first = None
        for y in range(top, bottom + 1, 3):
            for x in range(left, right + 1, 3):
                checked += 1
                if off(px(data, width, x, y), px(rest, width, x, y)) > 6:
                    changed += 1
                    first = first or (x, y, px(data, width, x, y), px(rest, width, x, y))
        return checked, changed, first


def column_width():
    return sv.cmd({"do": "probe"}).get("columnWidth", 252)


KEPT = {}
LINED = [True]


def watch(name, act, seconds=1.8, still=False, travels=True, inside=True, loose=False, lined=True, column=None, like=None, soft=3,
          settles=False):
    group = name.split("/")[0]
    if ONLY and name not in ONLY and group not in ONLY and not (group == "split" and ONLY & {"looks", "pages"}):
        return
    label = name.replace("/", "-")
    made = film(label, act, seconds)
    time.sleep(0.6)
    if not made:
        return
    frame = None
    worst_moved = worst_bare = 0
    first_moved = first_bare = first_still = None
    bad_moved = bad_bare = bad_still = 0
    different = 0
    after = made.last() if settles else None
    for index, data in enumerate(made.frames()):
        if frame is None:
            if like:
                frame = KEPT[like].over(data)
            else:
                frame = Frame(data, made.width, made.height, column_width() if column is None else column, made.width / WIDTH)
            if not frame.box:
                t.ok(f"{name}: the page's frame is found at rest", False)
                return
            KEPT.setdefault(name.split("/")[0], frame)
            continue
        moved, bare = frame.read(data, loose, lined and LINED[0], soft, after)
        if not inside:
            bare = []
        if moved:
            bad_moved += 1
            worst_moved = max(worst_moved, len(moved))
            first_moved = first_moved or (index, moved[:3])
        if bare:
            bad_bare += 1
            worst_bare = max(worst_bare, len(bare))
            first_bare = first_bare or (index, bare[:3])
        checked, changed, where = frame.still(data)
        if changed > checked * 0.002:
            different += 1
            if still:
                bad_still += 1
                first_still = first_still or (index, changed, checked, where)
    box = [round(v / (made.width / WIDTH), 1) for v in frame.box]
    t.ok(f"{name}: the frame's edges and corners stay where they rest in all {made.count} frames", bad_moved == 0,
         (f"{bad_moved} frames", f"worst {worst_moved} of {len(frame.same)} pixels", first_moved, "box", box, "rim", frame.rim))
    if inside:
        t.ok(f"{name}: no bare ground inside the frame in all {made.count} frames", bad_bare == 0,
             (f"{bad_bare} frames", f"worst {worst_bare} of {len(frame.filled)} pixels", first_bare))
    if still:
        t.ok(f"{name}: the page does not move", bad_still == 0, (f"{bad_still} frames", first_still))
    elif travels:
        t.ok(f"{name}: the pages do travel inside the frame", different >= 4, different)


def trackpad(**f):
    return lambda: space(action="trackpad", **f)


def whole(label):
    time.sleep(0.4)
    s = space()
    t.ok(f"{label}: at rest on a whole page", s["swipe"] == 0 and s["next"] == -1, (s["swipe"], s["next"], s["current"]))


def give(label, dx):
    space(action="hold", dx=dx)
    time.sleep(0.3)
    s = space()
    t.ok(f"{label}: the column's rows give, and no more than {GIVE} points", 0 < abs(s["swipe"]) <= GIVE and s["next"] == -1,
         (s["swipe"], s["next"]))
    space(action="release")
    time.sleep(1.0)


def gestures(prefix, first, last, wide=True):
    mid = first + 1
    go(mid)
    watch(f"{prefix}/swipe-next", trackpad(stops=[-180], speed=700, momentum=True))
    whole(f"{prefix}/swipe-next")
    watch(f"{prefix}/swipe-back", trackpad(stops=[180], speed=700, momentum=True))
    whole(f"{prefix}/swipe-back")
    go(mid)
    watch(f"{prefix}/drag-out-and-back", trackpad(stops=[-200, 0], speed=320, momentum=False), seconds=2.4)
    whole(f"{prefix}/drag-out-and-back")
    go(last)
    watch(f"{prefix}/past-the-last", trackpad(stops=[-320], speed=420, momentum=False), seconds=2.2, still=True)
    whole(f"{prefix}/past-the-last")
    give(f"{prefix}/past-the-last", -320)
    go(first)
    watch(f"{prefix}/past-the-first", trackpad(stops=[320], speed=420, momentum=False), seconds=2.2, still=True)
    whole(f"{prefix}/past-the-first")
    give(f"{prefix}/past-the-first", 320)
    go(mid)
    watch(f"{prefix}/swipe-and-on-past-the-last", trackpad(gestures=[
        {"stops": [-180], "speed": 700, "momentum": False},
        {"at": 0.42, "stops": [-320], "speed": 420, "momentum": False}]), seconds=2.8)
    whole(f"{prefix}/swipe-and-on-past-the-last")
    go(mid)
    watch(f"{prefix}/swipe-and-on-past-the-first", trackpad(gestures=[
        {"stops": [180], "speed": 700, "momentum": False},
        {"at": 0.42, "stops": [320], "speed": 420, "momentum": False}]), seconds=2.8)
    whole(f"{prefix}/swipe-and-on-past-the-first")
    if not wide:
        return
    go(mid)
    column = column_width()
    watch(f"{prefix}/past-a-whole-page", trackpad(stops=[-(column + 260)], speed=900, momentum=False), seconds=2.4)
    whole(f"{prefix}/past-a-whole-page")
    go(mid)
    watch(f"{prefix}/flick-onto-the-last", trackpad(stops=[-90], speed=4200, momentum=True))
    whole(f"{prefix}/flick-onto-the-last")
    go(mid)
    watch(f"{prefix}/flick-onto-the-first", trackpad(stops=[90], speed=4200, momentum=True))
    whole(f"{prefix}/flick-onto-the-first")
    go(mid)
    watch(f"{prefix}/ctrl-number", lambda: space(action="key", index=last))
    whole(f"{prefix}/ctrl-number")
    go(first)
    watch(f"{prefix}/ctrl-number-across-two", lambda: space(action="key", index=last))
    whole(f"{prefix}/ctrl-number-across-two")
    go(last)
    watch(f"{prefix}/wheel-at-the-last", lambda: space(action="wheel", dx=-1), seconds=1.2, still=True)
    whole(f"{prefix}/wheel-at-the-last")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False, "tabs.groups": False})
        launch()
        sv.cmd({"do": "window"})
        stage()
        sv.sp("enabled", on=True)
        names = [s["name"] for s in space()["spaces"]]
        sv.sp("open", url=f"{BASE}/One")
        time.sleep(0.8)
        for name in ("Two", "Three"):
            space(action="new", name=name)
            time.sleep(1)
            for i in range(4):
                sv.sp("open", url=f"{BASE}/{name}-{i}")
                time.sleep(0.3)
            sv.sp("open", url=f"{BASE}/{name}")
            time.sleep(0.8)
        names = [s["name"] for s in space()["spaces"]]
        first = len(names) - 2
        t.ok("three spaces side by side, the first and the last at the ends", first == 1 and names[-2:] == ["Two", "Three"], names)
        last = first + 2
        sv.cmd({"do": "ui", "glassBars": []})
        stage()

        gestures("dark", first, last)

        if not ONLY or "offgrid" in ONLY:
            side = sv.cmd({"do": "probe"}).get("sideWidth", 252)
            sv.cmd({"do": "ui", "sideWidth": 278.27})
            time.sleep(1.0)
            stage()
            gestures("offgrid", first, last, wide=False)
            sv.cmd({"do": "ui", "sideWidth": side})
            time.sleep(0.8)

        if not ONLY or "cards-off" in ONLY:
            sv.cmd({"do": "ui", "cards": False})
            time.sleep(1.0)
            stage()
            LINED[0] = False
            gestures("cards-off", first, last, wide=False)
            LINED[0] = True
            sv.cmd({"do": "ui", "cards": True})
            time.sleep(0.8)

        if not ONLY or "folded" in ONLY:
            stage()
            go(first)
            sv.cmd({"do": "ui", "folded": True})
            time.sleep(1.2)
            watch("folded/ctrl-number", lambda: space(action="key", index=first + 1), travels=False, column=0)
            whole("folded/ctrl-number")
            watch("folded/ctrl-number-across-two", lambda: space(action="key", index=first + 1) or time.sleep(0.9) or space(action="key", index=last),
                  seconds=2.6, travels=False, column=0)
            whole("folded/ctrl-number-across-two")
            sv.cmd({"do": "ui", "folded": False})
            time.sleep(0.8)
        if not ONLY or ONLY & {"split", "looks", "pages"}:
            go(first + 1)
            front = sv.sp("state")["activeID"]
            other = sv.sp("open", url=f"{BASE}/Pair")["resultID"]
            time.sleep(0.7)
            sv.sp("pair", id=other, **{"with": front}, side="right")
            time.sleep(1.2)
            stage()
            go(first)
            pair = dict(inside=False, lined=False, soft=6, settles=True)
            watch("split/single-to-pair", trackpad(stops=[-180], speed=700, momentum=True), **pair)
            whole("split/single-to-pair")
            watch("split/pair-to-single", trackpad(stops=[-180], speed=700, momentum=True), like="split", **pair)
            whole("split/pair-to-single")
            go(first)
            watch("split/single-back-to-pair", lambda: space(action="key", index=first + 1), **pair)
            whole("split/single-back-to-pair")
            watch("split/pair-dragged-out-and-back", trackpad(stops=[-200, 0], speed=320, momentum=False), seconds=2.4, like="split", **pair)
            whole("split/pair-dragged-out-and-back")
            watch("split/pair-past-the-first", trackpad(gestures=[
                {"stops": [180], "speed": 700, "momentum": False},
                {"at": 0.42, "stops": [320], "speed": 420, "momentum": False}]), seconds=2.8, like="split", **pair)
            whole("split/pair-past-the-first")

        if not ONLY or ONLY & {"looks", "pages"}:
            go(first + 1)
            space(action="look", colour="custom", custom="1B2A8A")
            time.sleep(0.8)
            go(last)
            space(action="look", colour="custom", custom="7A1420")
            time.sleep(0.8)
            go(first + 1)
            watch("looks/swipe-next", trackpad(stops=[-180], speed=700, momentum=True), inside=False, loose=True, lined=False, like="split",
                  soft=6, settles=True)
            whole("looks/swipe-next")
            watch("looks/past-the-last", trackpad(stops=[-320], speed=420, momentum=False), seconds=2.2, still=True, inside=False, loose=True,
                  lined=False, like="split", soft=6, settles=True)
            whole("looks/past-the-last")

        if not ONLY or "pages" in ONLY:
            go(first)
            sv.cmd({"do": "ui", "lead": "history"})
            time.sleep(1.0)
            go(last)
            press(17, "t", "cmd")
            state = sv.sp("state")
            front = next((tab for tab in state["tabs"] if tab["id"] == state["activeID"]), {})
            t.ok("pages: the last space is on a new tab page", front.get("blank") is True, front)
            go(first)
            state = sv.sp("state")
            front = next((tab for tab in state["tabs"] if tab["id"] == state["activeID"]), {})
            t.ok("pages: the first space is on History, a page of the browser's own", "history" in str(front.get("internal", "")), front)
            stage()
            go(first + 1)
            plain = dict(inside=False, loose=True, lined=False, like="split", soft=6, settles=True)
            watch("pages/to-the-new-tab-page", trackpad(stops=[-180], speed=700, momentum=True), **plain)
            whole("pages/to-the-new-tab-page")
            watch("pages/new-tab-page-past-the-last", trackpad(stops=[-320], speed=420, momentum=False), seconds=2.2, still=True, **plain)
            whole("pages/new-tab-page-past-the-last")
            watch("pages/from-the-new-tab-page", trackpad(stops=[180], speed=700, momentum=True), **plain)
            whole("pages/from-the-new-tab-page")
            watch("pages/to-history", trackpad(stops=[180], speed=700, momentum=True), **plain)
            whole("pages/to-history")
            watch("pages/history-past-the-first", trackpad(stops=[320], speed=420, momentum=False), seconds=2.2, still=True, **plain)
            whole("pages/history-past-the-first")
            watch("pages/from-history", lambda: space(action="key", index=first + 1), **plain)
            whole("pages/from-history")

    finally:
        t.done()
        (OUT / "result.json").write_text(json.dumps({"passed": t.passed, "failed": t.failed}))
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

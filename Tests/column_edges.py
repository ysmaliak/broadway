#!/usr/bin/env python3
"""The column's top and bottom edges over cards, pictured window-only.

Build first (`./build.sh`), then `python3 Tests/column_edges.py [OUT]`. A test
copy in a world of its own, started hidden: cards on, the column on the left,
the address pill on, loose tabs past the window's height, then a pinned live
folder at the top of the space. The window is put below the desktop, where
nothing shows on a screen and `screencapture -l` still pictures it alone.

The list's edges are a clean cut with a hairline, no fade. Read in the
column's margin (where no row draws) and down a card's own left edge: rows
are cut whole at each edge; a line shows at an edge only while rows are
hidden beyond it; pinned folders scroll with the tabs, so with them the top
edge is the same hairline; the New Tab row is the list's last row, held 6 points over the foot
while rows run on under it (the bottom line right over it), in its own place
after the last tab at the end and directly under it in a short list, and a
press on it opens a tab; and nothing of the list comes within 7 points of the
foot's space marks. Dark and light, cards off, a glass window and stacked
spaces in dark. BROADWAY_APP picks another build, for before and after.
"""
import os
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("column-edges")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/edges")
HEIGHT = 640
WIDTH = 1000
MARGIN = 4
t = sv.T()
WINDOW = [0]


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


def grey(picture, x, y):
    width, height, step, rows = picture
    r, g, b = rows[y][x * step:x * step + 3]
    return (r * 299 + g * 587 + b * 114) // 1000


def line(picture, x, top, bottom, scale):
    return [grey(picture, int(x * scale), y) for y in range(int(top * scale), int(bottom * scale))]


def col(**f):
    wheel = f.get("wheel")
    if wheel and abs(wheel) > 200:
        now = sv.cmd({"do": "columnscroll"})
        if "content" in now:
            room = now["offset"] if wheel < 0 else now["content"] - now["visible"] - now["offset"]
            f["wheel"] = min(abs(wheel), max(0, room) + 40) * (1 if wheel > 0 else -1)
    return sv.cmd({"do": "columnscroll", **f})


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})["window"]
    time.sleep(0.8)


def shoot(name):
    path = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    return path if path.exists() else None


def list_frame(c):
    """The list's scroll view from the window's top, in points: the tallest
    one in the column, reaching down under the foot."""
    width = 400
    shown = [r for r in c.get("all", []) if r[0] < width and r[3] > 60]
    x, y, w, h = max(shown, key=lambda r: r[3])
    return x, c["height"] - (y + h), w, c["height"] - y


def fill():
    loose = [sv.page(f"Loose tab {i:02d}") for i in range(22)]
    for other in [k for k in sv.cmd({"do": "rowframes"})["rows"] if k not in loose]:
        sv.sp("close", id=other)
    time.sleep(0.6)
    return loose


def live_folder():
    sv.cmd({"do": "live", "args": ["on"]})
    sv.cmd({"do": "live", "args": ["add", "Pull Requests", "https://github.com/pulls"]})
    time.sleep(0.8)


def foot(c):
    return c["height"] - 36


LINE = 3
SAME = 4
ROW_GAP = 3


def held(c):
    """The New Tab row held over the foot: drawn, its bottom 6 points over
    the foot, with rows running on under it."""
    e = c["edges"]
    y, h = e.get("newTabY", -1), e.get("newTabH", 0)
    return y > 0 and abs(y + h - (foot(c) - 6)) <= 0.5 and e.get("bottom") == 1


def floor_of(c):
    """Where the list's rows stop, in points from the window's top: at the
    line over the held New Tab row, or 6 points over the foot."""
    return c["edges"]["newTabY"] - ROW_GAP if held(c) else foot(c) - 6


def picture_of(label):
    path = shoot(label)
    if not path:
        t.ok(f"{label}: pictured", False, WINDOW[0])
        return None, 1
    picture = read_png(path)
    return picture, picture[0] / WIDTH


def at(picture, x, y, scale):
    return grey(picture, int(x * scale), int(y * scale))


def frames_now(loose):
    answer = sv.cmd({"do": "rowframes"})
    rows = answer["rows"]
    return {k: rows[k] for k in loose if k in rows and k != answer.get("active")}


def straddler(loose, cut, side="top"):
    """A loose row (not the selected one, which wears a card) with its
    middle just inside the edge at CUT, wheeling the list until one is."""
    aim = cut + 3 if side == "top" else cut - 3
    tried = []
    for _ in range(6):
        mine = frames_now(loose)
        for r in mine.values():
            if abs(r[1] + r[3] / 2 - aim) <= 3:
                return r
        if not mine: break
        ahead = [r for r in mine.values() if r[1] + r[3] / 2 > aim]
        r = min(ahead or mine.values(), key=lambda r: abs(r[1] + r[3] / 2 - aim))
        step = int(round(r[1] + r[3] / 2 - aim))
        tried.append((r[1], step))
        col(wheel=int(step / 2) or (1 if step > 0 else -1)); time.sleep(0.7)
    print("  no row across", side, cut, tried)
    return None


def whole_row(loose, top, floor, other):
    for r in frames_now(loose).values():
        if r[1] > top + 8 and r[1] + r[3] < floor - 8 and r != other:
            return r
    return None


def patch(picture, x0, x1, y0, y1, scale):
    return [[grey(picture, x, y) for x in range(int(x0 * scale), int(x1 * scale))]
            for y in range(int(y0 * scale), int(y1 * scale))]


def cut_whole(label, picture, scale, row, ref, cut, side, ground):
    """ROW is drawn exactly as the whole row REF up to CUT (its badge, port
    and the start of its title, which are the same on every loose row), and
    past CUT nothing of it is."""
    if not row or not ref:
        t.ok(f"{label}: a row across the {side} edge and a whole one", False, (row, ref, cut)); return
    x0, x1 = row[0] + 2, row[0] + 120
    past = max(0.5, 1 / scale)
    near = (cut + past, min(cut + 12, row[1] + row[3])) if side == "top" else (max(cut - 12, row[1]), cut - past)
    shift = ref[1] - row[1]
    cut_patch = patch(picture, x0, x1, near[0], near[1], scale)
    ref_patch = patch(picture, x0, x1, near[0] + shift, near[1] + shift, scale)
    ink = max(max(r) for r in ref_patch) - min(min(r) for r in ref_patch)
    worst = max(abs(a - b) for ra, rb in zip(cut_patch, ref_patch) for a, b in zip(ra, rb))
    t.ok(f"{label}: up to the {side} edge the row is drawn whole, not faded", ink > 40 and worst <= 12,
         (row, ref, cut, "ink", ink, "worst", worst))
    far = (cut - 3, cut - 1.5) if side == "top" else (cut + 1.5, cut + 3)
    beyond = patch(picture, x0, x1, far[0], far[1], scale)
    off = max(abs(v - ground) for r in beyond for v in r)
    t.ok(f"{label}: past the {side} edge, nothing of the row", off <= SAME, (far, off, ground))


def line_at(picture, x, y, scale, ground):
    return abs(at(picture, x, y, scale) - ground) >= LINE


def bare(label, loose):
    """Loose tabs only: the list's own top line."""
    sv.sp("select", id=loose[0]); time.sleep(0.6)
    col(wheel=-3000); time.sleep(0.8)
    c = col()
    picture, scale = picture_of(f"{label}-top")
    if not picture: return
    x, top, w, bottom = list_frame(c)
    ground = at(picture, x + MARGIN, top + 4, scale)
    t.ok(f"{label}: at the top nothing is hidden", c["edges"].get("top") == 0, c["edges"])
    t.ok(f"{label}: at the top no line", not line_at(picture, x + MARGIN, top + 0.25, scale, ground),
         (at(picture, x + MARGIN, top + 0.25, scale), ground))
    col(wheel=90); time.sleep(0.6)
    row = straddler(loose, top)
    c = col()
    ref = whole_row(loose, top, floor_of(c), row)
    picture, scale = picture_of(f"{label}-scrolled")
    if not picture: return
    t.ok(f"{label}: scrolled, rows are under the top", c["edges"].get("top") == 1, c["edges"])
    ground = at(picture, x + MARGIN, top - 3, scale)
    t.ok(f"{label}: scrolled, a hairline at the top", line_at(picture, x + MARGIN, top + 0.25, scale, ground),
         (at(picture, x + MARGIN, top + 0.25, scale), ground))
    t.ok(f"{label}: the line runs the sidebar's width", line_at(picture, x + 1, top + 0.25, scale, ground)
         and line_at(picture, x + w - 2, top + 0.25, scale, ground))
    cut_whole(label, picture, scale, row, ref, top, "top", ground)


def middle(label, loose):
    sv.sp("select", id=loose[9])
    time.sleep(0.6)
    col(wheel=-3000); time.sleep(0.4)
    col(wheel=90); time.sleep(0.8)
    c = col()
    x, top, w, bottom = list_frame(c)
    cut = top
    row = straddler(loose, cut)
    c = col()
    floor = floor_of(c)
    ref = whole_row(loose, top, floor, row)
    picture, scale = picture_of(label)
    if not picture: return
    t.ok(f"{label}: rows under both edges", (c["edges"].get("top"), c["edges"].get("bottom")) == (1, 1), c["edges"])
    ground = at(picture, x + MARGIN, cut - 3, scale)
    t.ok(f"{label}: the pinned folder scrolled away with the tabs, and a hairline is the top edge",
         line_at(picture, x + MARGIN, cut + 0.25, scale, ground), (at(picture, x + MARGIN, cut + 0.25, scale), ground))
    cut_whole(label, picture, scale, row, ref, cut, "top", ground)
    col(wheel=-3000); time.sleep(0.6)
    low = straddler(loose, floor, "bottom")
    c = col()
    ref = whole_row(loose, top, floor, low)
    picture, scale = picture_of(f"{label}-low")
    if not picture: return
    ground = at(picture, x + MARGIN, floor - 4, scale)
    t.ok(f"{label}: a hairline at the bottom while rows run on", line_at(picture, x + MARGIN, floor - 0.25, scale, ground),
         (at(picture, x + MARGIN, floor - 0.25, scale), ground))
    cut_whole(label, picture, scale, low, ref, floor, "bottom", ground)
    t.ok(f"{label}: the New Tab row is held over the foot", held(c), c["edges"])
    e = c["edges"]
    under = line(picture, (low or ref or [x + 8])[0] + 4, floor + 0.5, e["newTabY"] + e["newTabH"] - 0.5, scale)
    t.ok(f"{label}: nothing of the rows under the New Tab row shows through", max(under) - min(under) <= 1,
         (min(under), max(under), under[::4]))


def end(label, loose):
    sv.sp("select", id=loose[-1])
    time.sleep(0.6)
    col(wheel=3000); time.sleep(0.8)
    c = col()
    picture, scale = picture_of(label)
    if not picture: return
    x, top, w, bottom = list_frame(c)
    e = c["edges"]
    floor = e["newTabY"] - ROW_GAP if e.get("newTabY", -1) > 0 else floor_of(c)
    t.ok(f"{label}: no edge at the bottom at the end", c["edges"].get("bottom") == 0, c["edges"])
    ground = at(picture, x + MARGIN, floor - 4, scale)
    t.ok(f"{label}: at the end no line at the bottom", not line_at(picture, x + MARGIN, floor - 0.25, scale, ground),
         (at(picture, x + MARGIN, floor - 0.25, scale), ground))
    row = sv.cmd({"do": "rowframes"})["rows"].get(loose[-1])
    if not row:
        t.ok(f"{label}: the last row is drawn", False, row); return
    card = line(picture, row[0] + 4, row[1] + 6, row[1] + row[3] - 6, scale)
    t.ok(f"{label}: the last card is whole", max(card) - min(card) <= 3,
         (row, min(card), max(card), card[::4]))
    t.ok(f"{label}: the last card clears the floor", row[1] + row[3] <= floor + 0.5, (row, floor))


def new_tab_row(label, loose):
    """The New Tab row is the list's last row. Long: held 6 points over the
    foot while the list scrolls, rows under it; at the end in its own place
    right after the last tab, where it was held. A press opens a tab. Short:
    right after the last tab, nowhere near the foot. Returns the loose tabs,
    the closed ones opened again."""
    sv.sp("select", id=loose[4]); time.sleep(0.6)
    col(wheel=-3000); time.sleep(0.6)
    seen, lines = [], []
    for wheel in (0, 40, 40):
        if wheel: col(wheel=wheel); time.sleep(0.6)
        c = col()
        e = c["edges"]
        seen.append((round(e.get("newTabY", -1), 2), round(e.get("offsetY", -1), 1), held(c)))
        lines.append((round(e.get("lineY", -1), 2), round(e.get("newTabY", -1) - ROW_GAP, 2)))
    t.ok(f"{label}: the New Tab row is drawn", all(y > 0 for y, _, _ in seen), seen)
    t.ok(f"{label}: held, the bottom line sits right over it", all(abs(a - b) <= 0.5 for a, b in lines), lines)
    t.ok(f"{label}: scrolled anywhere short of the end, it is held over the foot with rows under it",
         all(h for _, _, h in seen) and len({o for _, o, _ in seen}) == 3, seen)
    t.ok(f"{label}: held, it stays at one y", len({y for y, _, _ in seen}) == 1, seen)
    col(wheel=3000); time.sleep(0.8)
    c = col()
    e = c["edges"]
    last = sv.cmd({"do": "rowframes"})["rows"].get(loose[-1])
    t.ok(f"{label}: at the end nothing is under it", e.get("bottom") == 0, e)
    t.ok(f"{label}: at the end it sits right after the last tab",
         last is not None and abs(e.get("newTabY", -1) - (last[1] + last[3] + ROW_GAP)) <= 0.5, (last, e.get("newTabY")))
    t.ok(f"{label}: at the end it is where it was held", abs(e.get("newTabY", -1) - seen[0][0]) <= 0.5,
         (e.get("newTabY"), seen[0][0]))
    if e.get("newTabW"):
        before = sv.cmd({"do": "rowframes"})
        try:
            sv.cmd({"do": "axpress", "identifier": "column-new-tab"})
        except RuntimeError as error:
            t.ok(f"{label}: the New Tab row takes a press", False, str(error)); return loose
        time.sleep(1.0)
        after = sv.cmd({"do": "rowframes"})
        opened = after["active"] not in before["rows"] and len(after["rows"]) == len(before["rows"]) + 1
        t.ok(f"{label}: a press on New Tab opens a tab", opened,
             (before["active"], after["active"], len(before["rows"]), len(after["rows"])))
        if opened:
            sv.sp("close", id=after["active"]); time.sleep(0.8)
    keep = 5
    for tab in loose[keep:]:
        sv.sp("close", id=tab)
    time.sleep(1.0)
    c = col()
    e = c["edges"]
    last = sv.cmd({"do": "rowframes"})["rows"].get(loose[keep - 1])
    t.ok(f"{label}: short, the list fits", c["measured"].get("fits") == 1, c["measured"])
    t.ok(f"{label}: short, it sits right after the last tab",
         last is not None and abs(e.get("newTabY", -1) - (last[1] + last[3] + ROW_GAP)) <= 0.5, (last, e.get("newTabY")))
    t.ok(f"{label}: short, it is not held at the window's bottom", e.get("newTabY", 1e9) + e.get("newTabH", 0) < foot(c) - 6 - 100,
         (e.get("newTabY"), foot(c)))
    shoot(f"{label}-short")
    again = [sv.page(f"Loose tab {i:02d}") for i in range(keep, len(loose))]
    time.sleep(0.6)
    return loose[:keep] + again


def stacked_new_tab(label, loose):
    """Stacked spaces: one New Tab row, the active section's, held 6 points
    over the foot while that section runs on under it, and right after its
    last tab once the section ends in view."""
    col(wheel=-2000); time.sleep(0.8)
    seen = []
    for wheel in (0, 40):
        if wheel: col(wheel=wheel); time.sleep(0.6)
        c = col()
        e = c["edges"]
        seen.append((round(e.get("newTabY", -1), 2), round(e.get("newTabH", -1), 2), e.get("newTabHeld"), foot(c),
                     round(e.get("lineY", -1), 2)))
    t.ok(f"{label}: the active section's New Tab is held over the foot",
         all(h == 1 and abs(y + hh - (f - 6)) <= 0.5 for y, hh, h, f, _ in seen), seen)
    t.ok(f"{label}: held, the bottom line sits right over it",
         all(abs(ly - (y - ROW_GAP)) <= 0.5 for y, _, _, _, ly in seen), seen)
    col(wheel=2000); time.sleep(0.8)
    c = col()
    e = c["edges"]
    rows = sv.cmd({"do": "rowframes"})["rows"]
    ends = [rows[k][1] + rows[k][3] for k in loose if k in rows]
    gap = e.get("newTabY", -1) - max(ends) if ends else None
    t.ok(f"{label}: past the section's end it is no longer held", e.get("newTabHeld") == 0, e)
    t.ok(f"{label}: not held, the bottom line is back on the floor over the foot",
         abs(e.get("lineY", -1) - (foot(c) - 6)) <= 0.5, (e.get("lineY"), foot(c)))
    t.ok(f"{label}: past the section's end it sits right after the last tab (or its folder)",
         gap is not None and ROW_GAP - 0.5 <= gap <= 12, (gap, e.get("newTabY")))


FOOT_GAP = 7
LIT = 1.08
INK = 14


def ink_rows(picture, left, right, top, bottom, ground, scale):
    """The rows from TOP to BOTTOM (points) where anything between LEFT and
    RIGHT differs from GROUND by more than INK levels, as point offsets."""
    hit = []
    for y in range(int(top * scale), int(bottom * scale)):
        if any(abs(grey(picture, x, y) - ground) > INK for x in range(int(left * scale), int(right * scale))):
            hit.append(y / scale)
    return hit


def blobs(picture, top, bottom, left, right, ground, scale):
    """The marks in the foot's middle, left to right: runs of columns with
    ink, each with its inked top and bottom in points."""
    columns = []
    for x in range(int(left * scale), int(right * scale)):
        ys = [y for y in range(int(top * scale), int(bottom * scale)) if abs(grey(picture, x, y) - ground) > INK]
        columns.append((x, ys))
    found, run = [], []
    for x, ys in columns + [(None, [])]:
        if ys: run.append((x, ys)); continue
        if len(run) >= 3 * scale:
            every = [y for _, ys in run for y in ys]
            found.append({"left": run[0][0] / scale, "right": run[-1][0] / scale,
                          "top": min(every) / scale, "bottom": (max(every) + 1) / scale})
        run = []
    return found


def foot_span(c):
    width = c.get("column") or 260
    return 9 + 28 + 4, width - 9 - 28 - 4


def foot_marks(picture, c, scale):
    bottom = c["height"]
    left, right = foot_span(c)
    ground = grey(picture, int(38 * scale), int((bottom - 20) * scale))
    return ground, blobs(picture, bottom - 36, bottom - 8, left, right, ground, scale)


def foot_room(label, loose, shifts=(0, 5, 10, 15)):
    """The space marks in the foot: an emoji as tall as a symbol, and nothing
    of the list drawn just above them, mid-list and at the end."""
    sv.sp("select", id=loose[4])
    time.sleep(0.6)
    col(wheel=-3000); time.sleep(0.4)
    col(wheel=120); time.sleep(0.6)
    gaps = []
    for n, shift in enumerate(shifts):
        if shift: col(wheel=5); time.sleep(0.5)
        c = col()
        path = shoot(f"{label}-middle-{n}")
        if not path:
            t.ok(f"{label}: pictured", False, WINDOW[0]); return
        picture = read_png(path)
        scale = picture[0] / WIDTH
        x, top, w, bottom = list_frame(c)
        c["column"] = x + w
        ground = grey(picture, int(38 * scale), int((c["height"] - 20) * scale))
        if n == 0:
            ground, marks = foot_marks(picture, c, scale)
            if len(marks) != 2 or any(m["right"] - m["left"] > 24 for m in marks):
                t.ok(f"{label}: two space marks in the foot, apart from the list", False, marks); return
            mark_top = min(m["top"] for m in marks)
        inked = ink_rows(picture, *foot_span(c), mark_top - 40, mark_top, ground, scale)
        gaps.append(mark_top - (inked[-1] + 1 / scale) if inked else 40)
        if n == 0:
            emoji, symbol = marks[0], marks[1]
            tall = ((emoji["bottom"] - emoji["top"]) / LIT, symbol["bottom"] - symbol["top"])
            t.ok(f"{label}: the emoji is no taller than a symbol to the eye", tall[0] <= tall[1] + 1, (tall, marks))
            middle_e, middle_s = (emoji["top"] + emoji["bottom"]) / 2, (symbol["top"] + symbol["bottom"]) / 2
            t.ok(f"{label}: the emoji sits on the symbols' line", abs(middle_e - middle_s) <= 1, (middle_e, middle_s))
            framed = c.get("marks") or {}
            if not os.environ.get("BROADWAY_APP"):
                t.ok(f"{label}: the bench reports the foot marks' frames", len(framed) >= 2, framed)
            if framed:
                heights = sorted({round(v[3], 1) for v in framed.values()})
                t.ok(f"{label}: every space mark's frame is the same height", len(heights) == 1, framed)
    t.ok(f"{label}: mid-list, nothing of the list within {FOOT_GAP} points over the marks", min(gaps) >= FOOT_GAP,
         [round(g, 1) for g in gaps])
    sv.sp("select", id=loose[-1])
    time.sleep(0.6)
    col(wheel=3000); time.sleep(0.8)
    c = col()
    path = shoot(f"{label}-end")
    if not path:
        t.ok(f"{label}: pictured", False, WINDOW[0]); return
    picture = read_png(path)
    scale = picture[0] / WIDTH
    x, top, w, bottom = list_frame(c)
    c["column"] = x + w
    ground, marks = foot_marks(picture, c, scale)
    if not marks:
        t.ok(f"{label}: the space marks are drawn at the end", False, marks); return
    mark_top = min(m["top"] for m in marks)
    inked = ink_rows(picture, *foot_span(c), mark_top - 40, mark_top, ground, scale)
    gap = mark_top - (inked[-1] + 1 / scale) if inked else 40
    t.ok(f"{label}: at the end the last card stops {FOOT_GAP} points or more over the marks", gap >= FOOT_GAP,
         (round(gap, 1), mark_top))
    t.ok(f"{label}: at the end the foot keeps its place", abs(mark_top - (c["height"] - 36)) <= 8, (mark_top, c["height"]))


def folder_at_end(loose):
    first = sv.sp("group", id=loose[-3])
    group = first["groups"][-1]["id"]
    for tab in loose[-2:]:
        sv.sp("group", id=tab, group=group)
    time.sleep(0.6)
    return group


def wear_icons():
    sv.cmd({"do": "ui", "spaces": True})
    sv.cmd({"do": "space", "action": "new", "name": "Work"}); time.sleep(0.8)
    sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.8)
    try:
        sv.cmd({"do": "icon", "args": ["set", "space", "1", "emoji", "🤯"]})
        worn = sv.cmd({"do": "icon", "args": ["set", "space", "2", "symbol", "briefcase"]})
    except RuntimeError:
        worn = {}
    if not worn.get("spaces"):
        broadway = str(Path(sv.APP) / "Contents/Helpers/broadway")
        for space, icon in (("Personal", "🤯"), ("Work", "briefcase")):
            done = subprocess.run([broadway, "--world", sv.W, "spaces", "icon", space, icon], capture_output=True, text=True, timeout=30)
            print("  broadway spaces icon", space, icon, done.returncode, done.stdout.strip()[:200], done.stderr.strip()[:200])
    time.sleep(0.8)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "sidebar.address": True, "live.on": True,
                    "tabs.newAtBottom": True,
                    "agents.on": bool(os.environ.get("BROADWAY_APP"))})
        sv.launch()
        sv.cmd({"do": "window"})
        stage(True)
        loose = fill()
        for dark in (True, False):
            stage(dark)
            bare("bare-" + ("dark" if dark else "light"), loose)
        loose = new_tab_row("new-tab", loose)
        live_folder()
        for dark in (True, False) if not os.environ.get("FOOT_ONLY") else ():
            stage(dark)
            look = "dark" if dark else "light"
            middle(f"middle-{look}", loose)
            end(f"end-{look}", loose)
        if not os.environ.get("FOOT_ONLY"):
            stage(True)
            sv.cmd({"do": "ui", "cards": False}); time.sleep(0.8)
            middle("cards-off-middle-dark", loose)
            end("cards-off-end-dark", loose)
            sv.cmd({"do": "ui", "cards": True})
            sv.cmd({"do": "space", "action": "look", "glass": True, "transparency": 0.6}); time.sleep(1.2)
            stage(True)
            middle("glass-middle-dark", loose)
            end("glass-end-dark", loose)
            sv.cmd({"do": "space", "action": "look", "glass": False, "transparency": 0.0}); time.sleep(0.8)
        wear_icons()
        folder_at_end(loose)
        for dark in (True, False):
            stage(dark)
            foot_room("foot-" + ("dark" if dark else "light"), loose)
        stage(True)
        sv.cmd({"do": "ui", "cards": False}); time.sleep(0.8)
        foot_room("foot-cards-off-dark", loose)
        sv.cmd({"do": "ui", "cards": True})
        sv.cmd({"do": "space", "action": "look", "glass": True, "transparency": 0.6}); time.sleep(1.2)
        stage(True)
        foot_room("foot-glass-dark", loose)
        sv.cmd({"do": "space", "action": "look", "glass": False, "transparency": 0.0}); time.sleep(0.8)
        sv.cmd({"do": "ui", "spaces": True})
        sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"}); time.sleep(1.2)
        stage(True)
        stacked_new_tab("stacked", loose)
        col(wheel=1500); time.sleep(0.8)
        shoot("stacked-end-dark")
        col(wheel=-200); time.sleep(0.8)
        shoot("stacked-middle-dark")
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

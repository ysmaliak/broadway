#!/usr/bin/env python3
"""The downloads popover's pointer, checked and pictured in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/downloads_pointer.py [LABEL]`.
The app starts hidden in a world of its own and its window is staged below
the desktop, so nothing comes onto a screen. The downloads list is opened from
the button at the foot of the sidebar: the sidebar on the left and on the
right, empty and with a long list, dark and light, folded with its card out,
narrow, in the smallest window and with the window on a display's edge. Each
time the popover's own window is pictured by its id and its pointer is found
from a picture of the window with it against one without it: the pointer
has to be on the bottom edge, its tip over the button, and its base on the
straight part of that edge, clear of both corners' 17 pt curves. With the
window on a display's left edge no popover kept on the screen can do both, so
there the tip may sit up to 13 pt past the button. The popover's body has to
stay below the window's top. Pictures go to
`.context/downloads-pointer/LABEL` (`now` by default), with the pointer zoomed
three times. BROADWAY_APP picks another build, for before and after. CHECK=0
only pictures, for a build that is known to fail.
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("downloads-pointer")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
OUT = ROOT / ".context/downloads-pointer" / LABEL
TOOLS = ROOT / ".build/downloads-pointer"
WINDOWS = TOOLS / "windows-shot"
CHECK = os.environ.get("CHECK", "1") == "1"
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
SIZE = (1100, 720)
SMALLEST = (640, 420)
EDGE = 45
SCREEN = [0]
EDGE_REACH = 13
CORNER = 17
CORNER_SLACK = 1
STATE = {"window": 0, "pid": 0}
t = sv.T()


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Tests/WindowsShot.swift"
    if not WINDOWS.exists() or WINDOWS.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(WINDOWS)], check=True)


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
            if kind_of == 1:
                line[x] = (line[x] + a) & 255
            elif kind_of == 2:
                line[x] = (line[x] + b) & 255
            elif kind_of == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif kind_of == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        above = line
    return width, height, step, rows


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(name, body):
        return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def pixel(picture, x, y):
    width, height, step, rows = picture
    x, y = max(0, min(width - 1, int(x))), max(0, min(height - 1, int(y)))
    return tuple(rows[y][x * step:x * step + step])


def zoom(picture, path, cx, cy, half_w=60, half_h=36, by=3):
    out = []
    for y in range(2 * half_h):
        line = bytearray()
        for x in range(2 * half_w):
            line += bytes(pixel(picture, cx - half_w + x, cy - half_h + y)[:3]) * by
        out += [line] * by
    write_png(path, 2 * half_w * by, 2 * half_h * by, out)


def changed(over, under):
    width, height, step, rows = over
    below = under[3]
    if under[0] != width or under[1] != height:
        return [[False] * width for _ in range(height)]
    def differs(y, x):
        at = x * step
        if step == 4 and rows[y][at + 3] < 200:
            return False
        if step == 4 and below[y][at + 3] < 200:
            return True
        return max(abs(rows[y][at + c] - below[y][at + c]) for c in range(3)) > 6
    return [[differs(y, x) for x in range(width)] for y in range(height)]


def runs(line):
    found = [i for i, on in enumerate(line) if on]
    return (found[0], found[-1]) if found else None


def pointer(mask):
    height, width = len(mask), len(mask[0])
    row_spans = [runs(line) for line in mask]
    col_spans = [runs([mask[y][x] for y in range(height)]) for x in range(width)]
    rows_on = [y for y, s in enumerate(row_spans) if s]
    cols_on = [x for x, s in enumerate(col_spans) if s]
    if not rows_on or not cols_on:
        return None
    widest = max(s[1] - s[0] for s in row_spans if s)
    tallest = max(s[1] - s[0] for s in col_spans if s)
    body_rows = [y for y, s in enumerate(row_spans) if s and s[1] - s[0] >= widest * 0.7]
    body_cols = [x for x, s in enumerate(col_spans) if s and s[1] - s[0] >= tallest * 0.7]
    top, bottom, left, right = body_rows[0], body_rows[-1], body_cols[0], body_cols[-1]
    sides = {"top": top - rows_on[0], "bottom": rows_on[-1] - bottom, "left": left - cols_on[0], "right": cols_on[-1] - right}
    side = max(sides, key=sides.get)
    below = row_spans[bottom + 2] if bottom + 2 < height else None
    tip_row = None
    if below and 4 < below[1] - below[0] < (right - left) * 0.4:
        side, tip_row, span = "bottom", bottom + 2, below
        for y in range(bottom + 3, height):
            line = [x for x in range(span[0] - 2, span[1] + 3) if 0 <= x < width and mask[y][x]]
            if not line or line[-1] - line[0] > span[1] - span[0] + 1:
                break
            tip_row, span = y, (line[0], line[-1])
    if sides[side] < 4 and tip_row is None:
        return None
    if side in ("top", "bottom"):
        if tip_row is None:
            tip_row = rows_on[0] if side == "top" else rows_on[-1]
        tip = ((row_spans[tip_row][0] + row_spans[tip_row][1]) / 2, tip_row)
        base_row = top - 1 if side == "top" else bottom + 1
        base = row_spans[base_row]
        start, end = left, right
        edge_line = top if side == "top" else bottom
    else:
        tip_col = cols_on[0] if side == "left" else cols_on[-1]
        tip = (tip_col, (col_spans[tip_col][0] + col_spans[tip_col][1]) / 2)
        base_col = left - 1 if side == "left" else right + 1
        base = col_spans[base_col]
        start, end = top, bottom
        edge_line = left if side == "left" else right
    corner_row = bottom if side == "top" else top
    radius = 0
    for d in range(0, (bottom - top) // 2):
        y = corner_row + d if corner_row == top else corner_row - d
        x = left if side != "left" else right
        if mask[y][x]:
            break
        radius += 1
    return {"side": side, "tip": tip, "base": base, "edge": [start, end], "edgeLine": edge_line, "radius": radius,
            "body": [left, top, right, bottom], "size": [width, height]}


def until(check, within=6.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.15)
    return check()


def windows():
    return sv.cmd({"do": "probe"})["windows"]


def popover():
    found = [w for w in windows() if w["kind"] == "_NSPopoverWindow" and w["visible"]]
    return found[-1] if found else None


def main_window():
    return next(w for w in windows() if w["number"] == STATE["window"])


def door():
    doors = sv.cmd({"do": "layoutwatch", "action": "doors"})["doors"]
    held = [d for d in doors if d["anchor"]] or doors
    return held[0] if held else None


def stage(dark, size=SIZE):
    if not STATE["window"]:
        sv.cmd({"do": "pages", "on": True})
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": list(size)})
    STATE["window"], STATE["pid"] = staged["window"], staged["pid"]
    time.sleep(0.8)


def launch():
    sv.setup()
    sv.launch()
    sv.page("page")
    time.sleep(0.4)


def caught(answer):
    return answer.get("onScreen") or []


def shut():
    sv.cmd({"do": "ui", "recentdownloads": False})
    until(lambda: not popover(), 3)
    time.sleep(0.3)


def shot(name, theme, side, stage_name, place="middle", size=SIZE, width=None, folded=False, picture=True):
    if ONLY and not (set(name.split("-")) & ONLY or name in ONLY):
        return
    sv.quit()
    STATE["window"] = 0
    launch()
    stage(theme == "dark", size)
    sv.cmd({"do": "ui", "side": side})
    if width:
        sv.cmd({"do": "ui", "sideWidth": width})
    sv.cmd({"do": "ui", "windowAt": place})
    time.sleep(0.5)
    if folded:
        sv.cmd({"do": "ui", "toggleFold": True})
        time.sleep(0.8)
        sv.cmd({"do": "columnscroll", "peek": True})
        time.sleep(0.6)
        sv.cmd({"do": "layoutwatch", "action": "doors", "press": "card"})
    else:
        sv.cmd({"do": "ui", "downloadsStage": stage_name})
        time.sleep(0.3)
        sv.cmd({"do": "ui", "recentdownloads": True})
    if folded:
        sv.cmd({"do": "ui", "downloadsStage": stage_name})
    up = until(popover)
    t.ok(f"{name}: opened", bool(up))
    if not up:
        return
    time.sleep(0.9)
    up = popover() or up
    answer = sv.cmd({"do": "probe"})
    t.ok(f"{name}: nothing came onto a screen", not caught(answer), str(caught(answer)))
    t.ok(f"{name}: the popover is below the desktop", up["level"] < 0, str(up["level"]))
    held = door()
    main = main_window()
    OUT.mkdir(parents=True, exist_ok=True)
    alone = Path(tempfile.gettempdir()) / f"downloads-pointer-{os.getpid()}.png"
    alone.unlink(missing_ok=True)
    under = alone.with_name(alone.stem + "-under.png")
    under.unlink(missing_ok=True)
    pid, number = str(STATE["pid"]), str(up["number"])
    said = subprocess.run([str(WINDOWS), pid, f"{STATE['window']},{number}", str(alone), number],
                          capture_output=True, text=True).stdout.strip()
    if picture:
        whole = OUT / f"{name}.png"
        subprocess.run([str(WINDOWS), pid, f"{STATE['window']},{number}", str(whole)], capture_output=True, text=True)
    framing = said.rsplit(" at ", 1)[-1] if " at " in said else ""
    shut()
    time.sleep(0.4)
    if framing:
        subprocess.run([str(WINDOWS), pid, str(STATE["window"]), str(under), framing], capture_output=True, text=True)
    if not alone.exists() or not under.exists():
        t.ok(f"{name}: pictured", False, said)
        return
    picture_alone = read_png(alone)
    scale = picture_alone[0] / up["frame"][2]
    found = pointer(changed(picture_alone, read_png(under)))
    under.unlink(missing_ok=True)
    if not found:
        t.ok(f"{name}: a pointer is drawn", False)
        alone.unlink(missing_ok=True)
        return
    zoom(picture_alone, OUT / f"{name}-pointer.png", found["tip"][0], found["tip"][1] - (24 if found["side"] == "bottom" else 0))
    frame = up["frame"]
    tip_x = frame[0] + found["tip"][0] / scale
    tip_y = frame[1] + frame[3] - found["tip"][1] / scale
    door_box = [float(v) for v in held["screen"].strip("{}").replace("{", "").replace("}", "").split(",")] if held else None
    room = found["radius"]
    base = found["base"]
    clear = [(base[0] - found["edge"][0]) / scale, (found["edge"][1] - base[1]) / scale] if base else [0, 0]
    record = {"name": name, "popover": frame, "window": main["frame"], "door": door_box, "side": found["side"],
              "tip": [tip_x, tip_y], "radius": room / scale, "clear": clear, "baseWidth": (base[1] - base[0]) / scale if base else 0}
    (OUT / f"{name}.json").write_text(json.dumps(record, indent=1))
    print(f"  {name}: pointer {found['side']}, tip {tip_x:.1f},{tip_y:.1f}, door {door_box}, corner radius "
          f"{room / scale:.1f}, base clear of corners {clear[0]:.1f} / {clear[1]:.1f}")
    if CHECK and door_box:
        x, y, w, h = door_box
        t.ok(f"{name}: the pointer is on the popover's bottom edge", found["side"] == "bottom", found["side"])
        past = EDGE_REACH if place != "middle" and x - SCREEN[0] < EDGE else 0
        t.ok(f"{name}: the tip is over the button" + (", or just past it on a display's edge" if past else ""),
             x - past <= tip_x <= x + w + past, f"tip {tip_x:.1f}, button {x:.1f}...{x + w:.1f}")
        t.ok(f"{name}: the tip points down at the button", y + h - 1 <= tip_y <= y + h + 12, f"tip {tip_y:.1f}, button top {y + h:.1f}")
        t.ok(f"{name}: the pointer's base is clear of both corners", min(clear) >= CORNER - CORNER_SLACK,
             f"clear {clear[0]:.1f} / {clear[1]:.1f}, corner {CORNER}")
        body_top = frame[1] + frame[3] - found["body"][1] / scale
        t.ok(f"{name}: the popover stays below the window's top",
             body_top <= main["frame"][1] + main["frame"][3] + 1, f"body top {body_top:.1f}, window {main['frame']}")
    alone.unlink(missing_ok=True)
    if folded:
        sv.cmd({"do": "columnscroll", "peek": False})
        sv.cmd({"do": "ui", "toggleFold": True})
        time.sleep(0.6)


def main():
    tools()
    try:
        for theme in ("dark", "light"):
            for side in ("left", "right"):
                for stage_name in ("empty", "many"):
                    shot(f"{side}-{stage_name}-{theme}", theme, side, stage_name)
        for side in ("left", "right"):
            shot(f"{side}-folded-peeking", "dark", side, "kept", folded=True)
            shot(f"{side}-narrow", "dark", side, "many", width=180)
            shot(f"{side}-smallest", "light", side, "many", size=SMALLEST)
            shot(f"{side}-display-edge", "dark", side, "many", place=side)
            shot(f"{side}-display-corner", "light", side, "empty", place="corner" if side == "left" else "rightcorner")
        shot("left-folded-display-corner", "dark", "left", "kept", place="corner", folded=True)
    finally:
        sv.quit()
        sv.wipe()
    t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

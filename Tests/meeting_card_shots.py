#!/usr/bin/env python3
import base64
import struct
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
ONLY = set(sys.argv[2].split(",")) if len(sys.argv) > 2 else set()
ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".context" / "meeting-card" / LABEL
sv.use("meeting-card")
t = sv.T()

THREE = [{"name": "Dara Cole", "email": "dara@example.test"}, {"name": "Bea Chen", "email": "bea@example.test"},
         {"name": "Mara Mills", "email": "mara@example.test"}]
CROWD = THREE + [{"name": "Bartholomew Featherstonehaugh-Winterbourne", "email": "bartholomew@example.test"},
                 {"name": "Ines Okonkwo", "email": "ines@example.test"}, {"name": "Jun Castellanos", "email": "jun@example.test"},
                 {"name": "", "email": "a.very.long.address.for.a.shared.mailbox@example.test"}]


def cases():
    meet = f"{sv.BASE}/abc-defg-hij"
    return {
        "standup": [{"title": "MM Stand Up", "in": 0.2, "minutes": 25, "link": meet, "people": THREE}],
        "soon": [{"title": "Design sync", "in": 4, "minutes": 30, "link": meet, "people": CROWD[:4], "location": "Room 4",
                  "pending": True, "external": "design-sync@example.test"}],
        "late": [{"title": "Weekly check-in", "in": -3, "minutes": 30, "notes": "https://zoom.us/j/123456789?pwd=abc"}],
        "plain": [{"title": "Lunch", "in": 2, "minutes": 60, "location": "The canteen", "people": THREE[:1]}],
        "long": [{"title": "Quarterly planning review for every product area with the leadership team and the guests from finance",
                  "in": 4, "minutes": 30, "link": meet, "people": list(reversed(CROWD)), "pending": True,
                  "location": "Building 12, fourth floor, the large corner room beside the kitchen and the lifts",
                  "external": "long@example.test"}],
        "three": [{"title": "MM Stand Up", "in": 0.2, "minutes": 25, "link": meet, "people": THREE},
                  {"title": "Weekly check-in", "id": "b", "in": -3, "minutes": 30, "notes": "https://zoom.us/j/123456789?pwd=abc"},
                  {"title": "Lunch", "id": "c", "in": 2, "minutes": 60, "location": "The canteen", "people": THREE[:1], "pending": True}],
    }


def read_png(data):
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


def shade(name, state):
    if not (WORK / f"{name}.png").exists():
        return
    width, height, step, rows = read_png((WORK / f"{name}.png").read_bytes())
    if step != 4:
        t.ok(f"{name}: the picture keeps its alpha", False, step)
        return
    def alpha(x, y):
        return rows[y][x * step + 3] if 0 <= x < width and 0 <= y < height else 0
    sx, sy, sw, sh = state["spots"]["stack"]
    cx, cy, cw, ch = state["spots"]["card0"]
    ring = [alpha(x, y) for x in range(sx, sx + sw) for y in (sy, sy + sh - 1)] + \
           [alpha(x, y) for y in range(sy, sy + sh) for x in (sx, sx + sw - 1)]
    middle_x, middle_y = cx + cw // 2, cy + ch // 2
    out = {"left": [alpha(cx - d, middle_y) for d in range(1, cx - sx + 1)],
           "right": [alpha(cx + cw - 1 + d, middle_y) for d in range(1, sx + sw - cx - cw + 1)],
           "above": [alpha(middle_x, cy - d) for d in range(1, cy - sy + 1)],
           "below": [alpha(middle_x, cy + ch - 1 + d) for d in range(1, sy + sh - cy - ch + 1)]}
    for side, values in out.items():
        print(f"        {name:22} {side:6} alpha going out {values[::2]}")
    t.ok(f"{name}: the shadow is gone before the panel ends", max(ring) <= 1, max(ring))


def shoot(name, dark, ground=None):
    request = {"do": "meetalert", "action": "shot-start", "dark": dark}
    if ground:
        request["ground"] = ground
    for _ in range(4):
        state = sv.cmd(request)
        try:
            time.sleep(0.9)
            took = sv.cmd({"do": "meetalert", "action": "shot-take"})
        finally:
            sv.cmd({"do": "meetalert", "action": "shot-end"})
        png = base64.b64decode(took.get("png") or "")
        if png:
            break
        time.sleep(0.5)
    if png:
        (WORK / f"{name}.png").write_bytes(png)
    t.ok(f"{name}: a picture of the probe's own window", bool(png), {k: v for k, v in took.items() if k != "png"})
    return state


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    sv.setup()
    sv.launch()
    try:
        for name, events in cases().items():
            if ONLY and name not in ONLY:
                continue
            state = sv.cmd({"do": "meetalert", "action": "fixture", "lead": "10", "hosts": {"127.0.0.1": "meet"}, "events": events})
            t.ok(f"{name}: {len(events)} up", len(state.get("due", [])) == len(events), state.get("due"))
            for theme in ("dark", "light"):
                shoot(f"{name}-{theme}", theme == "dark")
            if name == "standup":
                for theme in ("dark", "light"):
                    for ground in ("white", "black"):
                        shoot(f"{name}-{theme}-on-{ground}", theme == "dark", ground)
                    shade(f"{name}-{theme}-clear", shoot(f"{name}-{theme}-clear", theme == "dark", "clear"))
            if name == "three":
                shade(f"{name}-dark-clear", shoot(f"{name}-dark-clear", True, "clear"))
        print("        pictures in", WORK)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

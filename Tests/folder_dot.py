#!/usr/bin/env python3
"""A folded live folder's unseen mark is a round dot in every state.

Build first (`./build.sh debug`), then `python3 Tests/folder_dot.py [LABEL]`.

A hidden test copy in a world of its own against pr_rows.py's fake GitHub;
nothing is shown on a screen. Two live folders, "PRs" and "My Issues", read
the same fake. Activity lands while they are folded, so each heading carries
a count and the mark beside it, and the folders are taken through what a real
sidebar went through: a mark that came before a change of look and one that
came after it, light and dark, a fold and an unfold, a count that grows, a
hover, a refresh with nothing new.

After every step `unseenmarks` reads each mark shown in the window
(UnseenDotView: its frame and the corner radius its layer has, as set and as
shown); a mark whose radius is not half its side is a square. At the key
steps the window is pictured from the hidden probe itself (`picture`, the
app's own drawing) and each heading's mark is sampled: the corners of its
box are the row's ground and its centre is ink. The headings are cut out at
2x and 8x into .context/shots/folder-dot/LABEL/.
"""
import json
import shutil
import struct
import subprocess
import sys
import time
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

OUT = ROOT / ".context" / "shots" / "folder-dot" / LABEL
t = sv.T()
FOLDERS = ("PRs", "My Issues", "Bugs")
TWO = ("PRs", "My Issues")
SAID = {}


def talk(number):
    hour = SAID.get(number)
    said = "" if hour is None else (f'<div class="js-timeline-item" data-gid="PRR_{number}_{hour}"><a class="author" href="/lee">lee</a>'
                                    f'<relative-time datetime="2026-11-05T{hour:02d}:00:00Z"></relative-time> commented</div>')
    return said + '<div class="discussion-timeline-actions"></div>'


pr.talk = talk


def touched(*numbers):
    touched.turn = getattr(touched, "turn", 0) + 1
    for number in numbers:
        SAID[number] = 10 + touched.turn
        pr.STAMPS[number] = f"2026-11-06T00:{touched.turn:02d}:00Z"


def marks():
    return sv.cmd({"do": "unseenmarks"})["marks"]


def round_enough(mark):
    side = min(mark["frame"][2], mark["frame"][3])
    return side > 0 and abs(mark["radius"] - side / 2) < 0.01 and abs(mark["model"] - side / 2) < 0.01


def check(step, want=TWO):
    time.sleep(0.8)
    every = marks()
    shown = {m["heading"]: m for m in every if m["heading"] in FOLDERS}
    print(f"  {step}:", json.dumps({k: [v["frame"][2:], v["radius"], v["model"]] for k, v in shown.items()}),
          f"and {len(every) - len(shown)} row marks", flush=True)
    t.ok(f"{step}: a mark beside each folded heading's count", sorted(shown) == sorted(want), sorted(shown))
    t.ok(f"{step}: every mark in the window is round", all(round_enough(m) for m in every),
         [(m["host"], m["heading"] or "row", m["frame"][2:], m["radius"], m["model"]) for m in every if not round_enough(m)])
    return shown


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


def write_png(path, width, height, pixel):
    raw = b"".join(b"\x00" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))

    def chunk(name, body):
        return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body) & 0xFFFFFFFF)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def grey(rgb):
    return (rgb[0] * 299 + rgb[1] * 587 + rgb[2] * 114) // 1000


LEAD, ABOVE, WIDE = 22, 9, 60


def pictured(name, shown):
    """The window from the hidden probe; per heading, the mark's box sampled
    and the heading's end (count, mark, pill) cut out at 2x and 8x."""
    whole = OUT / f"{name}-window.png"
    said = sv.cmd({"do": "picture", "path": str(whole), "page": False})
    scale = said["pixels"][0] / said["points"][0]
    for heading, mark in shown.items():
        x, y, w, h = mark["frame"]
        slug = heading.replace(" ", "-").lower()
        crop = OUT / f"{name}-{slug}-2x.png"
        subprocess.run(["sips", "-c", str(int((h + 2 * ABOVE) * scale)), str(int(WIDE * scale)),
                        "--cropOffset", str(int((y - ABOVE) * scale)), str(int((x - LEAD) * scale)), str(whole), "--out", str(crop)],
                       capture_output=True, check=True)
        width, height, step, rows = read_png(crop)

        def at(px, py):
            return tuple(rows[py][px * step:px * step + 3])
        bx, by, bw, bh = int(LEAD * scale), int(ABOVE * scale), int(w * scale), int(h * scale)
        ground = grey(at(bx + bw // 2, by - int(4 * scale)))
        centre = grey(at(bx + bw // 2, by + bh // 2))
        corners = [grey(at(px, py)) for px, py in ((bx, by), (bx + bw - 1, by), (bx, by + bh - 1), (bx + bw - 1, by + bh - 1))]
        t.ok(f"{name}: {heading}'s mark has ink at its centre", abs(centre - ground) > 60, (ground, centre))
        t.ok(f"{name}: {heading}'s mark leaves the corners of its box to the ground, a dot not a square",
             all(abs(c - ground) < 24 for c in corners), (ground, corners, centre))
        big = 4
        write_png(OUT / f"{name}-{slug}-8x.png", width * big, height * big, lambda px, py: at(px // big, py // big))


def fold(name):
    sv.cmd({"do": "group", "name": name, "fold": True})


def added(name):
    pr.live("add-page", name, "pullRequests", f"{pr.BASE}{pr.PULLS}")
    pr.live("unfold", name)
    got = pr.folder(pr.live("update", name), name)
    t.ok(f"{name}: reads the fake, nothing new at first", got["state"] == "fine" and got["fresh"] == 0, got)
    fold(name)
    time.sleep(1)


def look(theme):
    sv.cmd({"do": "ui", "look": theme})
    time.sleep(0.8)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("folder-dot-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "start.fresh": False, "spaces": True})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "open", "url": f"{pr.BASE}/home?Notes"})
        sv.cmd({"do": "window"})
        for name in TWO:
            added(name)

        touched(512, 36, 41)
        pr.live("update", "My Issues")
        check("activity lands on folded My Issues", want=("My Issues",))
        look("light")
        look("dark")
        check("light and back to dark", want=("My Issues",))
        pr.live("update", "PRs")
        shown = check("then activity lands on folded PRs")
        pictured("dark", shown)

        look("light")
        added("Bugs")
        touched(44)
        pr.live("update", "Bugs")
        shown = check("light: activity lands on Bugs, folded since it was made", want=FOLDERS)
        pictured("light", shown)
        fold("PRs")
        time.sleep(0.6)
        fold("PRs")
        check("light, PRs unfolded and folded again", want=FOLDERS)
        look("dark")

        touched(37)
        pr.live("update", "PRs")
        check("PRs' count goes from 3 to 4", want=FOLDERS)
        sv.cmd({"do": "group", "name": "PRs", "look": "hover"})
        check("the pointer on PRs' heading", want=FOLDERS)
        sv.cmd({"do": "group", "name": "PRs", "look": "clear"})
        pr.live("update", "My Issues")
        check("a refresh of My Issues with nothing new", want=FOLDERS)
        fold("My Issues")
        time.sleep(0.6)
        unfolded = check("My Issues unfolded: its rows carry the marks", want=("PRs", "Bugs"))
        t.ok("unfolded, My Issues' rows show their own marks", len(marks()) > len(unfolded), marks())
        fold("My Issues")
        shown = check("My Issues folded again", want=FOLDERS)
        pictured("after-everything", shown)
    finally:
        sv.finish()
    print("pictures in", OUT)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

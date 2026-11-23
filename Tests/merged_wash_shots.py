#!/usr/bin/env python3
"""The wash: a pull request row at the moment it turns merged, pictured.

Build first (`./build.sh`), then `python3 Tests/merged_wash_shots.py [OUT]`.
Window pictures need a screen recording grant, so on the mini run it from a
Rex pane, not over ssh.

A hidden test copy in a world of its own reads a fake signed-in GitHub on
::1 through `integrations.api` (the fake of Tests/merged_stack.py), so the
rows carry github.com addresses and nothing is asked of the real site. Every
pull request, repository and person is invented.

A row turns merged and the copy draws its own sidebar at fixed moments
through the turn (`mergedturn`, test runs only), as its layers stand at that
moment: merge purple wipes across the row from its leading edge with a soft
crest, the row rests on the tinted ground through the hold, and the row
leaves with its ground. Nothing is taken from a screen. The scenes: a plain
row, the row of the page in front and a stack of three, each light and dark
on a plain sidebar, the plain and the front row on a saturated tint and on
a pale one, the row
under the pointer, three unrelated rows in one go, and Reduce Motion.

The probe also asks each row how it turned and measures the pictures: the
row in front stands apart from the sidebar at least as clearly as a plain
row, the rows of a stack keep the list's gap between their grounds, and the
ground is still on the row as it starts to leave.

OUT (default .context/merged-wash-shots) gets one folder per scene with
every frame, sheet-turn.png, sheet-rows.png and merged-wash-shots.json.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import merged_stack as ms  # noqa: E402
import split_view as sv  # noqa: E402

OUT = (Path(ARGS[0]) if ARGS else ROOT / ".context" / "merged-wash-shots").resolve()
HOLD = 1.6
TIMES = [0.06, 0.14, 0.24, 0.36, 0.5, 0.8, 1.2, 1.5]
AFTER = [0.02, 0.06, 0.1, 0.4]
MOMENTS = ["before"] + [f"{m:.2f}" for m in TIMES] + [f"left-{m:.2f}" for m in AFTER]
LEAVING = "left-0.06"
GONE = "left-0.40"
LATE = 0.045
PEAK = "0.14"
REST = "1.20"
SIGN = 2
TINT = {"custom": "3139FB", "intensity": 2.0, "glass": False, "transparency": 0, "grain": 0}
PALE = {"custom": "FFD3E0", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0}
SCALE = 2
TALL = 150
TOOLS = ROOT / ".context" / "merged-wash-tools"
SHEET = TOOLS / "sheet"
t = sv.T()
rounds = [0]


def seed():
    rounds[0] += 1
    n = 100 * rounds[0]
    rows = {
        n + 1: ("acme/rocket", "main", f"guide-{n}", None, None, "Fix a typo in the guide"),
        n + 2: ("acme/rocket", "main", f"graph-{n}", None, None, "Cache the build graph so cold builds stop resolving every package"),
        n + 3: ("acme/rocket", "main", f"swift-{n}", None, None, "Bump Swift to 6.2"),
        n + 4: ("acme/rocket", "main", f"rail-model-{n}", n, 1, "Rail - Add the model"),
        n + 5: ("acme/rocket", f"rail-model-{n}", f"rail-store-{n}", n, 2, "Rail - Keep rails in the store"),
        n + 6: ("acme/rocket", f"rail-store-{n}", f"rail-view-{n}", n, 3, "Rail - Show the rail beside the list"),
        n + 7: ("acme/rocket", "main", f"count-{n}", None, None, "Teach the rocket to count"),
    }
    ms.PR.clear()
    ms.PR.update(rows)
    ms.ORDER[:] = sorted(rows)
    ms.STATE.clear()
    ms.STATE.update({k: "open" for k in rows})
    ms.STAMPS.clear()
    ms.STAMPS.update({k: "2026-11-10T09:00:00Z" for k in rows})
    found = ms.read()
    for _ in range(30):
        if sorted(found) == sorted(rows) and " 3/3" in (found.get(n + 6) or {}).get("byline", ""):
            break
        time.sleep(0.5)
        found = ms.read()
    for k in rows:
        ms.live("seen", ms.url(k))
    time.sleep(0.4)
    return n, found


def turn(**fields):
    return sv.cmd({"do": "mergedturn", **fields})


def frames(name, turned, around, extra=(), **fields):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    for number in turned:
        ms.STATE[number] = "merged"
    drawn = Path(tempfile.mkdtemp())
    try:
        got = turn(frames=str(drawn), turn=[ms.url(k) for k in turned], place=[ms.url(around)] + [ms.url(k) for k in extra], times=TIMES, after=AFTER, scale=SCALE, height=430, **fields)
        for file in sorted(drawn.glob("*.png")):
            shutil.move(str(file), str(folder / file.name))
    finally:
        shutil.rmtree(drawn, ignore_errors=True)
    got["folder"] = str(folder)
    (folder / "frames.json").write_text(json.dumps(got, indent=1, sort_keys=True))
    time.sleep(0.5)
    return got


def lateness(got):
    worst = 0
    for shot in got["frames"]:
        name = shot["name"]
        if name == "before":
            continue
        asked = float(name.split("-")[-1])
        worst = max(worst, abs(shot["t"] - asked))
    return worst


def crop(got, name, moment, around):
    shot = next((f for f in got["frames"] if f["name"] == moment and f.get("file")), None)
    if not shot:
        return None
    x, y, w, h = got["rows"][ms.url(around)]
    top = max(0, min(got["size"][1] - TALL, y + h / 2 - TALL / 2))
    out = OUT / f"{name}-{moment}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(Path(got["folder"]) / shot["file"]), "-vf",
                    f"crop={int(got['size'][0] * SCALE)}:{int(TALL * SCALE)}:0:{int(top * SCALE)},scale=iw*2:ih*2:flags=lanczos", str(out)], check=True)
    return out


def sheet(out, columns, cells, width):
    if not SHEET.exists():
        TOOLS.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/ContactSheet.swift"), "-o", str(SHEET)], check=True)
    made = [f"{label}={path}" for label, path in cells if path]
    subprocess.run([str(SHEET), str(out), str(columns), str(width * SCALE * 2), str(TALL * SCALE * 2), *made], check=True, capture_output=True)
    return out.exists()


def tab_of(number):
    for tab in ms.prs().get("tabs", []):
        if tab["key"] == ms.url(number):
            return tab["id"]
    raise RuntimeError(f"no row for #{number}")


def pixel(got, moment, x, y):
    shot = next((f for f in got["frames"] if f["name"] == moment and f.get("file")), None)
    if not shot:
        return None
    px, py = int(x * SCALE), int(y * SCALE)
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(Path(got["folder"]) / shot["file"]), "-vf",
                          f"crop=3:3:{px - 1}:{py - 1}", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         check=True, capture_output=True, stdin=subprocess.DEVNULL).stdout
    chans = [sorted(raw[i::3])[4] for i in range(3)]
    return tuple(c / 255 for c in chans)


def lab(rgb):
    def line(v):
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (line(v) for v in rgb)
    l_ = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m_ = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s_ = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_)


def apart(a, b):
    if a is None or b is None:
        return 0
    x, y = lab(a), lab(b)
    return sum((p - q) ** 2 for p, q in zip(x, y)) ** 0.5


INKS = [(0x82 / 255, 0x50 / 255, 0xDF / 255), (0xA3 / 255, 0x71 / 255, 0xF7 / 255), (0xC2 / 255, 0x97 / 255, 0xFF / 255),
        (0x66 / 255, 0x39 / 255, 0xBA / 255)]


def toward(plate, washed):
    if plate is None or washed is None or apart(plate, washed) < 0.02:
        return False
    a, b = lab(plate), lab(washed)
    moved = [q - p for p, q in zip(a, b)]
    for ink in INKS:
        way = [q - p for p, q in zip(a, lab(ink))]
        dot = sum(m * w for m, w in zip(moved, way))
        size = (sum(m * m for m in moved) * sum(w * w for w in way)) ** 0.5
        if size and dot / size > 0.75:
            return True
    return False


def ground_of(got, number, moment):
    x, y, w, h = got["rows"][ms.url(number)]
    return pixel(got, moment, x + w - 6, y + h / 2)


def side_of(got, number, moment):
    x, y, w, h = got["rows"][ms.url(number)]
    return pixel(got, moment, min(got["size"][0] - 2, x + w + 4), y + h / 2)


def said_at(got, moment):
    shot = next((f for f in got["frames"] if f["name"] == moment), None)
    return {row["url"]: row for row in (shot or {}).get("rows", [])}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("merged-wash-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", ms.BASE], check=True)
    sv.launch()
    said = {"scenes": {}}
    cells = []
    try:
        ms.PR.clear()
        ms.ORDER[:] = []
        ms.live("add-page", "PRs", "pullRequests", ms.PULLS)
        ms.live("unfold", "PRs")
        set_up = turn(hold=HOLD, sight=True)
        t.ok("the row is held for the hold", set_up["hold"] == HOLD, set_up)
        width = None

        def scene(label, turned, forms, around=None, moments=None, before=None, also=(), **fields):
            nonlocal width
            slow = 0
            for attempt in range(4):
                n, found = seed()
                numbers = [n + k for k in turned]
                if before:
                    before(n)
                    time.sleep(0.6)
                middle = n + (around or turned[len(turned) // 2])
                got = frames(label, numbers, middle, extra=[n + k for k in also], **fields)
                slow = lateness(got)
                if slow <= LATE:
                    break
            width = got["size"][0]
            shown = [f for f in got["frames"] if f.get("file")]
            t.ok(f"{label}: every frame is drawn", len(shown) == len(MOMENTS), [f["name"] for f in got["frames"]])
            t.ok(f"{label}: every frame is taken at its moment", slow <= LATE, (slow, attempt))
            t.ok(f"{label}: the row is let go when the hold ends", HOLD - 0.01 <= got["left"] <= HOLD + 0.3, got["left"])
            held = said_at(got, REST)
            watched = numbers + [m for m in [middle] + [n + k for k in also] if m not in numbers]
            how = [held.get(ms.url(k), {}).get("form") for k in watched]
            t.ok(f"{label}: the rows turn as {' and '.join(forms)}", sorted(how) == sorted(forms), how)
            t.ok(f"{label}: every turning row wears the wash", all(held.get(ms.url(k), {}).get("drawn") == SIGN for k in watched), held)
            first = said_at(got, "before")
            played = sum(row.get("plays", 0) for row in held.values()) - sum(row.get("plays", 0) for row in first.values())
            t.ok(f"{label}: one row plays at most", played == forms.count("full"), (first, held))
            gone = said_at(got, GONE)
            t.ok(f"{label}: nothing of it is left after the hold",
                 all(not gone.get(ms.url(k), {}).get("merging") and gone.get(ms.url(k), {}).get("drawn", 0) == 0 for k in watched), gone)
            got["numbers"] = numbers
            got["watched"] = watched
            said["scenes"][label] = {"late": round(slow, 3), "left": got["left"], "tries": attempt + 1, "forms": how,
                                     "frames": [(f["name"], f["t"], [(r["merging"], r["shown"], r["form"], r["plays"], r["drawn"]) for r in f["rows"]])
                                                for f in got["frames"]]}
            for moment in moments or MOMENTS:
                cells.append((f"{label} {moment}", crop(got, label, moment, middle)))
            return got

        few = ["before", PEAK, "0.24", REST, LEAVING]
        clear = {}

        def measure(label, got, lit):
            number = got["numbers"][0]
            rest = ground_of(got, number, REST)
            side = side_of(got, number, REST)
            plate = ground_of(got, number, "before")
            stands = apart(rest, side)
            own = apart(rest, plate)
            purple = toward(plate, rest)
            clear[label] = {"rest": rest, "side": side, "plate": plate, "from side": round(stands, 4), "from plate": round(own, 4)}
            t.ok(f"{label}: the ground at rest has moved toward merge purple", purple, clear[label])
            if lit:
                plain = clear.get(lit)
                t.ok(f"{label}: the row in front stands apart from the sidebar at least as clearly as a plain row",
                     plain is not None and stands >= plain["from side"] * 0.95, (clear[label], plain))
                t.ok(f"{label}: the row in front is washed at least as clearly as a plain row",
                     plain is not None and own >= plain["from plate"] * 0.95, (clear[label], plain))
            leaving = ground_of(got, number, "left-0.02")
            t.ok(f"{label}: the ground is still on the row as it starts to leave",
                 apart(leaving, side) >= stands * 0.4, (leaving, rest, side))

        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(0.5)
            measure(f"plain-{look}", scene(f"plain-{look}", [2], ["full"]), None)
            measure(f"selected-{look}", scene(f"selected-{look}", [2], ["full"], before=lambda n: turn(lit=ms.url(n + 2))), f"plain-{look}")
            got = scene(f"stack-{look}", [6], ["full", "follow", "follow"], around=5, also=[4])
            n = got["numbers"][0] - 6
            boxes = sorted((got["rows"][ms.url(n + k)] for k in (6, 5, 4)), key=lambda b: b[1])
            gaps = [round(lower[1] - (upper[1] + upper[3]), 2) for upper, lower in zip(boxes, boxes[1:])]
            t.ok(f"stack-{look}: the three rows keep the list's gap", all(2.5 <= g <= 3.5 for g in gaps), gaps)
            side = side_of(got, n + 6, REST)
            seams = [pixel(got, REST, b[0] + b[2] / 2, b[1] + b[3] + 1.5) for b in boxes[:2]]
            t.ok(f"stack-{look}: the sidebar shows between the washed rows", all(apart(s, side) < 0.02 for s in seams), (seams, side))
            frames_of = {f["name"]: {row["url"]: row for row in f["rows"]} for f in got["frames"]}
            started = [next((m for m in MOMENTS[1:] if frames_of.get(m, {}).get(ms.url(n + k), {}).get("form")), None) for k in (6, 5, 4)]
            t.ok(f"stack-{look}: the rows turn from the top down", all(s is not None for s in started)
                 and [MOMENTS.index(s) for s in started] == sorted(MOMENTS.index(s) for s in started), started)
            def early(k):
                x, y, w, h = got["rows"][ms.url(n + k)]
                return pixel(got, "0.14", x + w * 0.3, y + 2.5)
            mid = [early(k) for k in (6, 5, 4)]
            t.ok(f"stack-{look}: mid-cascade the top row is further on than the bottom one",
                 apart(mid[0], side) > apart(mid[2], side), [round(apart(m, side), 4) for m in mid])
        sv.cmd({"do": "ui", "look": "light"})
        time.sleep(0.5)
        scene("hovered", [2], ["full"], moments=few, before=lambda n: sv.cmd({"do": "rowhover", "id": tab_of(n + 2), "on": True}))
        scene("three", [1, 2, 3], ["full", "quiet", "quiet"], moments=few)
        turn(reduced=True)
        got = scene("reduced", [2], ["still"], moments=few)
        number = got["numbers"][0]
        rest = ground_of(got, number, REST)
        side = side_of(got, number, REST)
        t.ok("reduced: the ground is there from the first frame", apart(ground_of(got, number, "0.06"), rest) < 0.01,
             (ground_of(got, number, "0.06"), rest))
        t.ok("reduced: the row fades as it leaves", apart(ground_of(got, number, "left-0.06"), side) > 0.005, (ground_of(got, number, "left-0.06"), side))
        turn(reduced=None)
        sv.cmd({"do": "space", "action": "look", **TINT})
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(0.6)
            measure(f"tinted-{look}", scene(f"tinted-{look}", [2], ["full"]), None)
            measure(f"tinted-selected-{look}", scene(f"tinted-selected-{look}", [2], ["full"], before=lambda n: turn(lit=ms.url(n + 2))), f"tinted-{look}")
        sv.cmd({"do": "space", "action": "look", **PALE})
        sv.cmd({"do": "ui", "look": "light"})
        time.sleep(0.6)
        measure("pale-light", scene("pale-light", [2], ["full"]), None)
        measure("pale-selected-light", scene("pale-selected-light", [2], ["full"], before=lambda n: turn(lit=ms.url(n + 2))), "pale-light")
        said["clear"] = clear
        ordered = [c for c in cells if c[0].startswith(("plain-", "tinted-", "selected-", "stack-", "pale-"))]
        t.ok("a contact sheet of the turn on four grounds", sheet(OUT / "sheet-turn.png", len(MOMENTS), ordered, width))
        rest = [c for c in cells if not c[0].startswith(("plain-", "tinted-", "selected-", "stack-", "pale-"))]
        t.ok("a contact sheet of the other rows", sheet(OUT / "sheet-rows.png", len(few), rest, width))
        said["width"] = width
    finally:
        sv.finish()
        (OUT / "merged-wash-shots.json").write_text(json.dumps(said, indent=1))
        shutil.rmtree(TOOLS, ignore_errors=True)
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

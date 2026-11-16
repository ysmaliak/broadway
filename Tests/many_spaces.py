#!/usr/bin/env python3
"""The row of spaces at the foot of the sidebar, with few spaces and with many.

Build first (`./build.sh`), then `python3 Tests/many_spaces.py [folder]`.
It makes 3, 9, 12 and 30 spaces in a probe's own world and, at the narrowest,
the default and the widest sidebar, on the left and on the right, light and
dark, reads from the app where each space's mark is drawn. Every drawn mark
must lie between the downloads key and the plus key, the space in front must
be drawn there at full size and lit, and every space must be reachable by
the pointer: the row is scrolled until the mark is in view, the mark is
pressed, and the app must then be in that space.

`--trace` also slides from the first space to the last and back, with and
without Reduce Motion, and checks the row's position frame by frame.

The window is staged behind the desktop and pictured by its own id.
"""
import argparse
import json
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("many-spaces")
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("out", nargs="?", default=str(ROOT / ".context/many-spaces/run"))
parser.add_argument("--trace", action="store_true")
parser.add_argument("--counts", default="3,9,12,30")
parser.add_argument("--quick", action="store_true")
options = parser.parse_args()
OUT = Path(options.out)
SIZE = (1100, 700)
COUNTS = [int(v) for v in options.counts.split(",")]
WIDTHS = (200, 258, 440)
FULL = 18
WINDOW = [0]
PID = [0]
TOOL = ROOT / ".build" / "side-chrome-shot"
t = sv.T()
FACTS = {}


def name_of(index):
    return f"S{index:02d}"


def stage(dark):
    said = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": list(SIZE)})
    WINDOW[0], PID[0] = said["window"], said["pid"]
    time.sleep(0.8)


def shoot(name):
    path = OUT / f"{name}.png"
    said = ""
    for turn in range(6):
        said = subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True, text=True).stderr
        if path.exists():
            return path
        if not TOOL.exists():
            TOOL.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(TOOL)], check=True)
        said += subprocess.run([str(TOOL), str(PID[0]), str(WINDOW[0]), str(path)], capture_output=True, text=True).stdout
        if path.exists():
            return path
        time.sleep(1.0)
    raise RuntimeError(f"no picture of window {WINDOW[0]}: {said.strip()}")


def scale_of(path):
    with open(path, "rb") as file:
        head = file.read(24)
    return struct.unpack(">I", head[16:20])[0] / SIZE[0]


def crop(path, name, box, zoom=2):
    k = scale_of(path)
    x, y, w, h = [round(v * k) for v in box]
    out = OUT / f"{name}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(path), "-vf",
                    f"crop={w}:{h}:{x}:{y},scale=iw*{zoom}:ih*{zoom}:flags=lanczos", str(out)], check=True)
    return out


def contrast(path, box):
    k = scale_of(path)
    x, y, w, h = [max(1, round(v * k)) for v in box]
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-vf", f"crop={w}:{h}:{x}:{y}",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    lum = [(raw[i] * 299 + raw[i + 1] * 587 + raw[i + 2] * 114) // 1000 for i in range(0, len(raw) - 2, 3)]
    if not lum:
        return 0
    ground = sorted(lum)[len(lum) // 2]
    return max(abs(v - ground) for v in lum)


def sheet(name, paths):
    paths = [path for path in paths if path.exists()]
    if len(paths) < 2:
        return
    widest = 0
    for path in paths:
        with open(path, "rb") as file:
            widest = max(widest, struct.unpack(">I", file.read(24)[16:20])[0])
    args = sum([["-i", str(path)] for path in paths], [])
    pads = "".join(f"[{i}:v]pad={widest}:ih:0:0:color=gray[p{i}];" for i in range(len(paths)))
    stack = "".join(f"[p{i}]" for i in range(len(paths))) + f"vstack=inputs={len(paths)}"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *args, "-filter_complex", pads + stack, str(OUT / f"{name}.png")], check=True)


def door(kind):
    said = sv.cmd({"do": "space", "action": "point", "door": kind, "on": False}).get("doors", [])
    return said[0]["plate"] if said else None


def marks():
    return sv.cmd({"do": "columnscroll"}).get("marks", {})


def state():
    return sv.cmd({"do": "space"})


def room():
    keys = sorted([door("downloads"), door("plus")], key=lambda r: r[0])
    return {"from": keys[0][0] + keys[0][2], "to": keys[1][0], "top": keys[0][1], "height": keys[0][3], "keys": keys}


def inside(rect, at):
    return (rect[0] >= at["from"] - 0.5 and rect[0] + rect[2] <= at["to"] + 0.5
            and rect[1] >= at["top"] - 2 and rect[1] + rect[3] <= at["top"] + at["height"] + 2)


def drawn(found, names):
    return {name: found[name] for name in names if name in found and found[name][2] > 0.5 and found[name][3] > 0.5}


def look(scene, names, front, at):
    found = drawn(marks(), names)
    out = [name for name, rect in found.items() if not inside(rect, at)]
    t.ok(f"{scene}: every drawn mark lies between the two keys", not out,
         f"{len(out)} outside {at['from']:.0f}…{at['to']:.0f}: " + ", ".join(f"{n}@{found[n][0]:.0f}" for n in out[:6]))
    order = sorted(found.items(), key=lambda item: item[1][0])
    over = [(a[0], b[0]) for a, b in zip(order, order[1:]) if a[1][0] + a[1][2] > b[1][0] + 0.5]
    t.ok(f"{scene}: no mark lies over another", not over, over[:4])
    rect = found.get(front)
    widest = max((r[2] for r in found.values()), default=0)
    good = bool(rect) and inside(rect, at) and rect[2] >= FULL and rect[2] >= widest - 0.5
    t.ok(f"{scene}: the space in front is in view at full size", good, (front, rect, widest))
    return found


def reach(scene, names, name, at):
    said = state()
    order = [space["name"] for space in said["spaces"]]
    last = None
    for turn in range(60):
        found = drawn(marks(), names)
        rect = found.get(name)
        if rect and rect[2] >= FULL and inside(rect, at):
            sv.cmd({"do": "hit", "x": rect[0] + rect[2] / 2, "y": rect[1] + rect[3] / 2, "click": True})
            time.sleep(0.35)
            return state()["current"] == name, turn
        full = [order.index(n) for n, r in found.items() if r[2] >= FULL and inside(r, at)]
        if not full:
            return False, turn
        key = json.dumps(found, sort_keys=True)
        if key == last:
            return False, turn
        last = key
        step = 60 if order.index(name) > max(full) else -60
        sv.cmd({"do": "space", "action": "footwheel", "dx": step})
        time.sleep(0.25)
    return False, 60


def pictured(count, side, dark, width, front):
    middle = (count + 1) // 2
    if options.quick:
        return side == "left" and not dark and width == 258 and front == middle
    if side == "left" and not dark:
        return front == middle or width == 258
    return width == 258 and front == middle


def scenes(count, names):
    fronts = sorted({1, (count + 1) // 2, count})
    shots = []
    for side in ("left", "right"):
        sv.cmd({"do": "ui", "side": side})
        for dark in (False, True):
            stage(dark)
            for width in WIDTHS:
                sv.cmd({"do": "ui", "sideWidth": width})
                time.sleep(0.5)
                at = room()
                column = [0, width] if side == "left" else [SIZE[0] - width, SIZE[0]]
                for front in fronts:
                    sv.cmd({"do": "space", "action": "go", "index": front})
                    time.sleep(0.45)
                    scene = f"{count}-{side}-{'dark' if dark else 'light'}-{width}-front{front}"
                    t.ok(f"{scene}: the keys are inside the sidebar",
                         at["keys"][0][0] >= column[0] and at["keys"][1][0] + at["keys"][1][2] <= column[1], (at["keys"], column))
                    found = look(scene, names, name_of(front), at)
                    FACTS[scene] = {"room": [at["from"], at["to"]], "marks": found}
                    if not pictured(count, side, dark, width, front):
                        continue
                    path = shoot(scene)
                    rect = found.get(name_of(front))
                    if rect and inside(rect, at):
                        lit = contrast(path, [rect[0], rect[1], rect[2], rect[3]])
                        t.ok(f"{scene}: the space in front is lit", lit >= 70, lit)
                    lead = max(0, column[0] - 60) if side == "right" else 0
                    shots.append(crop(path, f"foot-{scene}", [lead, SIZE[1] - 56, min(SIZE[0] - lead, width + 60), 56]))
                    path.unlink()
    sheet(f"sheet-{count}", shots)


def walk(count, names):
    sv.cmd({"do": "ui", "side": "left"})
    stage(False)
    for width in WIDTHS:
        sv.cmd({"do": "ui", "sideWidth": width})
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(0.6)
        at = room()
        missed = []
        turns = 0
        lost = []
        for index in list(range(1, count + 1)) + [1]:
            name = name_of(index)
            got, took = reach(f"{count}-{width}", names, name, at)
            turns = max(turns, took)
            if not got:
                missed.append(name)
                sv.cmd({"do": "space", "action": "go", "index": index})
                time.sleep(0.4)
                continue
            rect = drawn(marks(), names).get(name)
            if not (rect and rect[2] >= FULL and inside(rect, at)):
                lost.append(name)
        t.ok(f"{count} spaces at {width}: every space is reached by the pointer", not missed,
             f"{len(missed)} not reached: {', '.join(missed[:8])}")
        t.ok(f"{count} spaces at {width}: each space is in view once it is in front", not lost, lost[:8])
        FACTS[f"reach-{count}-{width}"] = {"missed": missed, "mostScrolls": turns}


def trace(count, names):
    sv.cmd({"do": "ui", "side": "left", "sideWidth": 258})
    stage(False)
    for reduced in (False, True):
        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true" if reduced else "false"], check=True)
        time.sleep(0.4)
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(0.8)
        label = "reduced" if reduced else "moving"
        for target in (count, 1):
            sv.cmd({"do": "space", "action": "foottrace", "on": True})
            sv.cmd({"do": "space", "action": "slide", "index": target})
            time.sleep(2.2)
            said = sv.cmd({"do": "space", "action": "foottrace", "on": False}).get("foottrace")
            leg = f"{label}-to-{target}"
            if said is None:
                t.ok(f"trace {leg}: the app reports the row frame by frame", False, "no foottrace in this build")
                continue
            frames = said["frames"]
            FACTS[f"trace-{leg}"] = said
            (OUT / f"trace-{leg}.json").write_text(json.dumps(said))
            t.ok(f"trace {leg}: the app is in {name_of(target)}", state()["current"] == name_of(target), state()["current"])
            ends = frames[-1] if frames else {}
            t.ok(f"trace {leg}: the row ends on the space in front", bool(frames) and abs(ends["focus"] - (target - 1)) < 0.01, ends)
            steps = [abs(b["scroll"] - a["scroll"]) for a, b in zip(frames, frames[1:])]
            turns = [abs(b["focus"] - a["focus"]) for a, b in zip(frames, frames[1:])]
            away = max((abs(f["scroll"] - f["wanted"]) for f in frames), default=0)
            t.ok(f"trace {leg}: the row is where its focus puts it on every frame", away < 0.5, away)
            if reduced:
                t.ok(f"trace {leg}: with Reduce Motion the row moves at once", len([s for s in steps if s > 0.5]) <= 1, len(steps))
                t.ok(f"trace {leg}: with Reduce Motion the row cross-fades", said.get("fades", 0) >= 1, said.get("fades"))
            else:
                start = frames[0]["focus"] if frames else 0
                riding = [f for f in frames if f["progress"] > 0]
                off = max((abs(f["focus"] - (start + (target - 1 - start) * f["progress"])) for f in riding), default=9)
                t.ok(f"trace {leg}: on every frame of the slide the row is as far along as the page", off < 0.02, off)
                way = 1 if target - 1 >= start else -1
                back = min(((b["focus"] - a["focus"]) * way for a, b in zip(frames, frames[1:])), default=0)
                t.ok(f"trace {leg}: the row never turns back", back > -0.001, back)
                landed = [index for index, f in enumerate(frames) if index and f["progress"] == 0 and frames[index - 1]["progress"] > 0]
                jump = max((abs(frames[index]["scroll"] - frames[index - 1]["scroll"]) for index in landed), default=9)
                t.ok(f"trace {leg}: the row does not move when the slide lands", jump < 0.5, jump)
            travel = [index for index, step in enumerate(steps) if step > 0.01]
            FACTS[f"trace-{leg}-sum"] = {"frames": len(frames), "largestStep": max(steps, default=0), "largestTurn": max(turns, default=0),
                                         "stripFrames": len(travel),
                                         "stripSeconds": frames[travel[-1] + 1]["t"] - frames[travel[0]]["t"] if travel else 0,
                                         "slideSeconds": frames[-1]["t"] - frames[0]["t"] if frames else 0}
    subprocess.run(["defaults", "delete", sv.SUITE, "motion.testReduced"], capture_output=True)
    stage(False)
    sv.cmd({"do": "space", "action": "go", "index": 1})
    time.sleep(0.8)
    held = []
    for share in (0.0, 0.25, 0.5, 0.75):
        if share:
            sv.cmd({"do": "space", "action": "hold", "dx": -258 * share})
            time.sleep(0.4)
        path = shoot(f"held-{int(share * 100)}")
        held.append(crop(path, f"foot-held-{int(share * 100)}", [0, SIZE[1] - 56, 318, 56]))
        path.unlink()
        if share:
            sv.cmd({"do": "space", "action": "release"})
            time.sleep(1.2)
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.6)
    sheet("sheet-held", held)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    sv.setup(spaces=True)
    sv.launch()
    try:
        stage(False)
        sv.cmd({"do": "ui", "spaces": True, "cards": True, "downloadsbutton": True, "sideWidth": 258})
        sv.cmd({"do": "space", "action": "rename", "name": name_of(1)})
        made = 1
        for count in COUNTS:
            while made < count:
                made += 1
                sv.cmd({"do": "space", "action": "new", "name": name_of(made)})
                time.sleep(0.45)
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.8)
            names = [name_of(index) for index in range(1, count + 1)]
            said = state()
            t.ok(f"{count} spaces are made", [space["name"] for space in said["spaces"]] == names, len(said["spaces"]))
            scenes(count, names)
            walk(count, names)
            if options.trace and count == COUNTS[-1]:
                trace(count, names)
        icons = [space.get("icon") for space in json.load(open(f"{sv.SUPPORT}/spaces.json"))]
        FACTS["icons"] = icons
        worn = max((icons.count(icon) for icon in set(icons) if icon), default=0)
        t.ok("no icon is worn by more than two of the spaces made here", worn <= 2, (worn, icons))
    finally:
        sv.finish()
    (OUT / "facts.json").write_text(json.dumps(FACTS, indent=1))
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The floating video's play and pause key, filmed through a change each way.

Build first (`./build.sh`), then `python3 Tests/float_toggle_film.py [OUT]`. Needs
ffmpeg and screen recording. The bench's `glasskeys` gallery holds the floating
video's real row of keys in a window of its own. A shown test copy opens it
behind every other window with one pixel on the screen, and that window is
filmed by its number (Tests/WindowCapture.swift), never a region of the
display. Nothing comes to the front and nothing makes a sound.

The key goes from pause to play and back. Between the two marks the film has to
show a smaller mark: the old one shrinking away, then the new one growing back.
A change with nothing between, or a crossfade at full size, fails.

The skip key's wiggle, another of the system's symbol effects, is filmed first
in the same window. Where the window gives no frames, or the wiggle does not
draw either, this screen cannot show a symbol effect (a locked screen is one):
the probe proves by state what it can, says "cannot tell on this screen" and
exits with 3. The drawn middle of the mark, its box and its weight, is measured in every
frame and written as "middles". "travel" finds each change as the first new
frame after a still stretch and gives the largest step of the middle from one
frame to the next, when it came and how big the mark was then, and how far a
whole mark stands from where it comes to rest. `--again JSON` measures a saved
film the same way. OUT (default
.context/float-toggle) gets the frames, a strip of
the key around each change and float-toggle.json.

Exit 0 passed, 1 failed, 3 cannot tell on this screen.
"""
import json
import shutil
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARGS = sys.argv[1:]
OUT = Path(ARGS[0] if ARGS else ROOT / ".context" / "float-toggle")
sys.path.insert(0, str(ROOT / "Tests"))
import glass_keys as gk  # noqa: E402
import split_view as sv  # noqa: E402

sv.use("float-toggle")

CANNOT_TELL = 3
SMALL = 0.6
CORE = 28


def ink(pixels, side, floor):
    rows = [y for y in range(side) if any(p > floor for p in pixels[y * side:(y + 1) * side])]
    columns = [x for x in range(side) if any(pixels[y * side + x] > floor for y in range(side))]
    if not rows or not columns:
        return 0
    return max(rows[-1] - rows[0] + 1, columns[-1] - columns[0] + 1)


def spot_of(pixels, side, floor, scale):
    rows = [y for y in range(side) if any(p > floor for p in pixels[y * side:(y + 1) * side])]
    columns = [x for x in range(side) if any(pixels[y * side + x] > floor for y in range(side))]
    if not rows or not columns:
        return None
    centre = side / 2
    weight = across = down = 0.0
    for y in range(side):
        for x in range(side):
            lift = pixels[y * side + x] - floor
            if lift > 0:
                weight += lift
                across += lift * (x + 0.5)
                down += lift * (y + 0.5)
    box = ((columns[0] + columns[-1] + 1) / 2 - centre, (rows[0] + rows[-1] + 1) / 2 - centre)
    return [round(box[0] / scale, 2), round(box[1] / scale, 2), round((across / weight - centre) / scale, 2), round((down / weight - centre) / scale, 2)]


def starts(trace):
    return [trace[i][0] for i in range(1, len(trace))
            if trace[i][0] - trace[i - 1][0] >= 0.3 and trace[i][1:] != trace[i - 1][1:]]


def travel(trace, start, until):
    rows = [row for row in trace if row[2]]
    before = [row for row in rows if row[0] < start]
    during = [row for row in rows if start <= row[0] < until]
    if not before or not during:
        return {"error": "no frames around the change"}
    rest = before[-1]
    end = during[-1]
    full = max(row[1] for row in [rest] + during)
    least = min(during, key=lambda row: row[1])
    chain = [rest] + during
    steps = [(row[0] - prior[0], abs(row[2][2] - prior[2][2]), abs(row[2][0] - prior[2][0]), row) for prior, row in zip(chain, chain[1:])]
    weight = max(steps, key=lambda step: step[1])
    box = max(steps, key=lambda step: step[2])
    whole = [row for row in during if row[0] > least[0] and row[1] >= full * 0.9]
    far = max([max(abs(row[2][2] - end[2][2]), abs(row[2][3] - end[2][3])) for row in whole] or [0])
    return {"restBefore": rest[2], "restAfter": end[2], "smallestAfter": round(least[0] - start, 3), "smallest": least[1],
            "weightStep": round(weight[1], 2), "weightStepAfter": round(weight[3][0] - start, 3), "weightStepSize": weight[3][1],
            "boxStep": round(box[2], 2), "boxStepAfter": round(box[3][0] - start, 3),
            "wholeFrames": len(whole), "farthestFromRest": round(far, 2),
            "weightAcross": [round(row[2][2], 2) for row in during]}


def measure(trace):
    found = starts(trace)
    if len(found) < 2:
        return {"error": f"found {len(found)} changes in the film, not two", "starts": found}
    ends = found[1:] + [float("inf")]
    return {"starts": found[:2], **{word: travel(trace, start, until) for word, start, until in zip(("toPlay", "toPause"), found, ends)}}


def floor_of(pixels):
    ground = statistics.median(pixels)
    return ground + (max(pixels) - ground) * 0.3


def judge(sizes, at):
    before = [size for moment, size in sizes if moment < at - 0.05]
    during = [(moment, size) for moment, size in sizes if at - 0.05 <= moment <= at + 0.7]
    if not before or not during:
        return {"frames": len(during), "small": 0, "error": "no frames around the change"}
    rest = min(before[-1], during[-1][1])
    small = [(round(moment - at, 3), size) for moment, size in during if size <= rest * SMALL]
    return {"frames": len(during), "rest": rest, "least": min(size for _, size in during), "small": len(small), "smallFrames": small}


def main():
    if not shutil.which("ffmpeg"):
        sys.exit("float_toggle_film needs ffmpeg")
    t = sv.T()
    OUT.mkdir(parents=True, exist_ok=True)
    if not gk.CAPTURE.exists():
        gk.CAPTURE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(gk.CAPTURE)], check=True)
    report = {}
    unseen = None
    try:
        sv.setup(sidebar=True)
        gk.launch()
        pid = next(iter(sv.started))
        opened = gk.glass("open", look="dark", behind=True)
        time.sleep(0.8)
        window, scale = opened["window"], opened["scale"]
        gk.SCALE[0] = scale
        row = next(key["frame"] for key in opened["keys"] if key["name"] == "float play")
        middle = [row[0] + row[2] / 2, row[1] + row[3] / 2]
        key = gk.scaled([middle[0] - CORE / 2, middle[1] - CORE / 2, CORE, CORE], scale, pad=0)
        skip = gk.scaled([row[0], row[1] + (row[3] - 40) / 2, 40, 40], scale, pad=0)
        gk.glass("play", playing=True)
        time.sleep(0.8)
        before = gk.glass("state")
        t.ok("the test copy's motion is not reduced", before.get("reduced") is False, before)
        t.ok("the key rests on pause, on its own centre", before["mark"] == "pause" and before.get("rests") is True, before)
        marks = {}

        def act(start):
            time.sleep(0.5)
            marks["skip"] = time.time() - start
            gk.glass("skip")
            time.sleep(1.0)
            marks["play"] = time.time() - start
            report["toPlay"] = gk.glass("play", playing=False)
            time.sleep(1.3)
            marks["pause"] = time.time() - start
            report["toPause"] = gk.glass("play", playing=True)
            time.sleep(1.0)

        shot, said = gk.film(pid, window, OUT / "film", 4.4, act)
        time.sleep(0.4)
        after = gk.glass("state")
        report["state"] = {"before": before, "after": after}
        t.ok("to play: the key swaps its mark", report["toPlay"]["mark"] == "play" and report["toPlay"].get("swap") is True,
             report["toPlay"])
        t.ok("to play: the old mark keeps its place while it leaves", report["toPlay"]["nudge"] == before["nudge"], (before, report["toPlay"]))
        t.ok("to pause: the key swaps back", report["toPause"]["mark"] == "pause" and report["toPause"].get("swap") is True,
             report["toPause"])
        t.ok("pause to play and back is two swaps", after["swaps"] - before["swaps"] == 2, (before, after))
        t.ok("the key ends on pause, on its own centre", after["mark"] == "pause" and after.get("rests") is True and after["nudge"] == before["nudge"], after)
        if shot is None:
            unseen = f"the window gave no frames ({said.strip()})"
        else:
            side = key[2]
            frames = [(moment, gk.gray(frame, key), gk.gray(frame, skip)) for moment, frame in shot]
            still = [row for row in frames if row[0] < marks["skip"] - 0.05]
            wiggle = [row for row in frames if marks["skip"] <= row[0] <= marks["skip"] + 0.7]
            noise = max([gk.distance(still[0][2], row[2]) for row in still] or [0])
            moved = max([gk.distance(still[0][2], row[2]) for row in wiggle] or [0]) if still else 0
            report["wiggle"] = {"frames": len(wiggle), "moved": moved, "noise": noise}
            drawn = moved > max(0.003, noise * 3)
            floor = floor_of(frames[0][1])
            sizes = [(moment, ink(pixels, side, floor)) for moment, pixels, _ in frames]
            report["sizes"] = [[round(moment, 3), size] for moment, size in sizes]
            report["changes"] = {word: judge(sizes, marks[word]) for word in ("play", "pause")}
            trace = [(moment, ink(pixels, side, floor), spot_of(pixels, side, floor, scale)) for moment, pixels, _ in frames]
            report["middles"] = [[round(moment, 3), size, spot] for moment, size, spot in trace]
            report["marks"] = marks
            report["travel"] = measure(trace)
            for word in ("play", "pause"):
                start = next((index for index, row in enumerate(shot) if row[0] >= marks[word] - 0.05), 0)
                gk.sheet(shot[start:start + 32], gk.scaled([middle[0] - 24, middle[1] - 24, 48, 48], scale, pad=4), OUT / f"to-{word}")
            print(f"  wiggle: moved {moved:.4f} against {noise:.4f} at rest, in {len(wiggle)} frames")
            for word, found in report["changes"].items():
                print(f"  to {word}: {found}")
            for word, found in report["travel"].items():
                print(f"  travel {word}: {found}")
            if drawn:
                for word, found in report["changes"].items():
                    t.ok(f"to {word}: a smaller mark between the two", found["small"] >= 2, found)
            else:
                unseen = "the window is filmed, and neither the wiggle nor the swap draws in it"
        gk.glass("close")
    finally:
        report["cannotTell"] = unseen
        (OUT / "float-toggle.json").write_text(json.dumps(report, indent=2, sort_keys=True))
        t.done()
        sv.finish()
    if t.failed:
        return 1
    if unseen:
        print(f"cannot tell on this screen: {unseen}")
        return CANNOT_TELL
    return 0


def again(path):
    saved = json.loads(Path(path).read_text())
    trace = [(moment, size, spot) for moment, size, spot in saved["middles"]]
    print(json.dumps(measure(trace), indent=2))
    return 0


if __name__ == "__main__":
    if len(ARGS) == 2 and ARGS[0] == "--again":
        sys.exit(again(ARGS[1]))
    sys.exit(main())

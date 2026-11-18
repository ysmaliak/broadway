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
exits with 3. OUT (default .context/float-toggle) gets the frames, a strip of
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
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "float-toggle")
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
        t.ok("to play: the key asks the system for its down-up replace", report["toPlay"]["mark"] == "play" and report["toPlay"].get("downUp") is True,
             report["toPlay"])
        t.ok("to play: the old mark keeps its place while it leaves", report["toPlay"]["nudge"] == before["nudge"], (before, report["toPlay"]))
        t.ok("to pause: the key asks for the same replace", report["toPause"]["mark"] == "pause" and report["toPause"].get("downUp") is True,
             report["toPause"])
        t.ok("pause to play and back is two replaces", after["swaps"] - before["swaps"] == 2, (before, after))
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
            shown = all(found["small"] >= 2 for found in report["changes"].values())
            for word in ("play", "pause"):
                start = next((index for index, row in enumerate(shot) if row[0] >= marks[word] - 0.05), 0)
                gk.sheet(shot[start:start + 32], gk.scaled([middle[0] - 24, middle[1] - 24, 48, 48], scale, pad=4), OUT / f"to-{word}")
            print(f"  wiggle: moved {moved:.4f} against {noise:.4f} at rest, in {len(wiggle)} frames")
            for word, found in report["changes"].items():
                print(f"  to {word}: {found}")
            if shown:
                t.ok("to play: a smaller mark between the two", True)
                t.ok("to pause: a smaller mark between the two", True)
            elif drawn:
                for word, found in report["changes"].items():
                    t.ok(f"to {word}: a smaller mark between the two", found["small"] >= 2, found)
            else:
                unseen = "the window is filmed, and neither the wiggle nor the replace draws in it"
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


if __name__ == "__main__":
    sys.exit(main())

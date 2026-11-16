#!/usr/bin/env python3
"""The Broadway onboarding, filmed from a test copy in a world of its own.

The onboarding window is raised on one display, behind every other window
unless --front, and filmed by window id, so nothing covers the screen in use.
Each scene keeps an mp4, the frame times (for pacing) and contact sheets.

Scenes: intro (the drawing and the card rising), steps (every step and the
hand-off), skip (a click a second in), calm (Reduce Motion), and launch (a
first launch over the desktop through to the browser window; it films the
whole display, so it is only made when asked for with --only launch).

Run: python3 Tests/onboarding_film.py LABEL [--screen N] [--size W,H] [--look dark|light]
     [--only intro,steps] [--front] [--display] [--fps 120] [--active]

--active, with --only launch, lets the test copy come forward the way a real
first launch does (key window, menu bar and Dock tucked away). It takes the
keyboard for the fifteen seconds of the film.
"""
import argparse
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("label")
parser.add_argument("--screen", type=int, default=1)
parser.add_argument("--size", default="")
parser.add_argument("--look", default="dark")
parser.add_argument("--only", default="")
parser.add_argument("--front", action="store_true")
parser.add_argument("--display", action="store_true")
parser.add_argument("--active", action="store_true")
parser.add_argument("--fps", type=int, default=120)
parser.add_argument("--scale", type=float, default=1.0)
options = parser.parse_args()
OUT = ROOT / ".context" / "onboarding" / options.label
FILM = ROOT / ".context" / "onboarding" / "tools" / "film"
only = set(filter(None, options.only.split(",")))
pid = None
WAS = 3.7
later = 0.0


def cmd(**request):
    return sv.cmd(request)


def onboarding(action="state", **more):
    return cmd(do="onboarding", action=action, **more)


def after(delay, work):
    threading.Timer(delay, work).start()


def sheet(name, seconds, every=0.1, columns=8, width=560):
    film = OUT / f"{name}.mp4"
    if not film.exists():
        return
    rows = int((seconds / every + columns - 1) // columns)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(film), "-vf",
                    f"fps={1 / every},scale={width}:-1,tile={columns}x{rows}:padding=4:color=0x808080",
                    "-frames:v", "1", str(OUT / f"{name}-sheet.png")], check=False)


def still(name, at, label):
    film = OUT / f"{name}.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{at:.3f}", "-i", str(film), "-frames:v", "1",
                    str(OUT / f"{name}-{label}.png")], check=False)


def strip(name, label, start, count, columns=6, every=1 / 30, crop="", width=330):
    film = OUT / f"{name}.mp4"
    if not film.exists():
        return
    rows = (count + columns - 1) // columns
    chain = f"fps={1 / every}" + (f",crop={crop}" if crop else "")
    chain += f",scale={width}:-1:flags=lanczos,tile={columns}x{rows}:padding=4:color=0x808080"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{start:.3f}", "-t", f"{every * count:.3f}", "-i", str(film),
                    "-vf", chain, "-frames:v", "1", str(OUT / f"{name}-{label}.png")], check=False)


def pacing(name):
    path = OUT / f"{name}.json"
    if not path.exists():
        return
    gaps = json.loads(path.read_text())["gaps"]
    if not gaps:
        return
    ordered = sorted(gaps)
    late = [round(g, 1) for g in gaps if g > 1000 / options.fps * 1.6]
    print(f"       {name}: {len(gaps) + 1} frames, median gap {ordered[len(ordered) // 2]:.1f} ms, "
          f"{len(late)} late: {sorted(late)[-8:]}", flush=True)


def film(name, seconds, act, hold=True, reduced=False, whole=False):
    global later
    if only and name not in only:
        return
    OUT.mkdir(parents=True, exist_ok=True)
    state = onboarding("replay", hold=hold, reduced=reduced)
    time.sleep(0.4)
    state = onboarding()
    later = 0.0 if reduced else state.get("ends", WAS) - WAS
    if whole:
        seconds += later
    if options.display:
        target = ["display", str(options.screen), "0"]
    else:
        target = ["window", str(pid), str(state["window"])]
    taker = subprocess.Popen([str(FILM), *target, str(OUT / f"{name}.mp4"), str(seconds), str(options.fps), str(options.scale)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: not filmed: {line} {taker.stderr.read()}")
    time.sleep(0.25)
    if hold:
        onboarding("roll")
    act()
    taker.communicate()
    sheet(name, seconds, columns=10 if name == "intro" else 8)
    if state.get("frame"):
        w, h = state["frame"][2], state["frame"][3]
        middle = f"{min(w, 760)}:{min(h, 900)}:{max((w - 760) // 2, 0)}:{max((h - 900) // 2, 0)}"
        if name == "intro":
            strip(name, "settle", 3.85 + later, 24, crop=middle)
        if name == "skip":
            strip(name, "cut", 1.45, 12, crop=middle)
        if name == "calm":
            strip(name, "cut", 1.9, 12, crop=middle)
        if name == "steps":
            for label, at in [("turn-1", 5.8), ("turn-2", 7.5), ("turn-3", 8.5), ("turn-4", 9.5), ("turn-5", 10.5)]:
                strip(name, label, at + later, 12, crop=middle)
            for index, at in enumerate([4.9, 5.5, 7.0, 8.1, 9.1, 10.1, 11.1, 12.1, 12.9]):
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", f"{at + later:.2f}", "-i", str(OUT / "steps.mp4"), "-frames:v", "1",
                                "-vf", f"crop={middle}", str(OUT / f"steps-{index + 1}.png")], check=False)
            for half, picks in (("a", "123"), ("b", "456"), ("c", "789")):
                inputs = [part for pick in picks for part in ("-i", str(OUT / f"steps-{pick}.png"))]
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", f"hstack=inputs={len(picks)}", str(OUT / f"steps-{half}.png")], check=False)
    pacing(name)
    print(f"  ok   {name}", flush=True)


def steps():
    plan = [
        (4.2, lambda: onboarding("name:Home")),
        (4.5, lambda: onboarding("look:glass")),
        (5.0, lambda: onboarding("look:dusk")),
        (5.6, lambda: onboarding("primary")),
        (6.6, lambda: onboarding("side:right")),
        (7.3, lambda: onboarding("primary")),
        (8.3, lambda: onboarding("primary")),
        (9.3, lambda: onboarding("later")),
        (10.3, lambda: onboarding("primary")),
        (11.3, lambda: onboarding("source:Arc")),
        (12.2, lambda: onboarding("primary")),
    ]
    for at, work in plan:
        after(at + later, work)


def fabricate():
    for folder in ("Google/Chrome/Default", "Arc/User Data/Default", "BraveSoftware/Brave-Browser/Default"):
        made = Path(sv.SUPPORT) / "Import" / folder
        made.mkdir(parents=True, exist_ok=True)
        (made / "Bookmarks").write_text('{"roots":{"bookmark_bar":{"children":[],"type":"folder"}}}')


def prefs():
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", options.look], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "onboarding.screen", "-int", str(options.screen)], check=True)
    if options.size:
        w, h = options.size.split(",")
        subprocess.run(["defaults", "write", sv.SUITE, "onboarding.size", "-array", "-float", w, "-float", h], check=True)


def launch_scene():
    """A first launch: the recorder runs before the app does."""
    seconds = 15.0
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("onboarding-launch-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False, "onboarding.back": False, "onboarding.show": True, "onboarding.active": options.active})
    prefs()
    fabricate()
    taker = subprocess.Popen([str(FILM), "display", str(options.screen), "0", str(OUT / "launch.mp4"), str(seconds), "60", "1"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"launch: not filmed: {line} {taker.stderr.read()}")
    time.sleep(0.8)
    began = time.time()
    before = sv.running()
    quiet = [] if options.active else ["-g"]
    subprocess.run(["open", "-n", *quiet, "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.05)
    sv.started.update(sv.running() - before)
    try:
        time.sleep(0.5)
        state = onboarding()
        shift = state.get("ends", WAS) - WAS
        x, y, w, h = state["frame"]
        sv.cmd({"do": "windows", "action": "frame", "n": 1, "frame": [x + w * 0.12, y + h * 0.1, w * 0.76, h * 0.78]})
        print("       launch:", {k: state[k] for k in ("phase", "seen", "mainShown")}, flush=True)
        for at, work in [(5.4, lambda: onboarding("name:Home")), (5.8, lambda: onboarding("look:noir")), (6.6, lambda: onboarding("primary")),
                         (7.6, lambda: onboarding("primary")), (8.5, lambda: onboarding("later")), (9.3, lambda: onboarding("later")),
                         (10.2, lambda: onboarding("later"))]:
            after(max(began + at + shift - time.time(), 0), work)
        taker.communicate()
        state = onboarding()
        print("       launch:", {k: state[k] for k in ("phase", "seen", "mainShown")}, flush=True)
        sheet("launch", seconds, every=0.2, columns=8, width=560)
        print("  ok   launch", flush=True)
    finally:
        sv.quit()
        sv.wipe()


def main():
    global pid
    if not FILM.exists() or FILM.stat().st_mtime < (ROOT / "Tests/onboarding_film.swift").stat().st_mtime:
        FILM.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(ROOT / "Tests/onboarding_film.swift"), "-o", str(FILM)], check=True)
    if "launch" in only:
        launch_scene()
        only.discard("launch")
        if not only:
            return
    sv.use("onboarding-film-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False, "onboarding.back": not options.front})
    prefs()
    fabricate()
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        film("intro", 5.2, lambda: None, whole=True)
        film("steps", 13.6, steps, whole=True)
        film("skip", 3.0, lambda: after(1.3, lambda: onboarding("skip")))
        film("calm", 3.4, lambda: None, reduced=True)
        print(json.dumps(onboarding(), indent=1))
    finally:
        sv.quit()
        sv.wipe()


if __name__ == "__main__":
    main()

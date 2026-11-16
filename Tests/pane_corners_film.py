#!/usr/bin/env python3
import json
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pane_corners as pc  # noqa: E402

sv = pc.sv
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/after/film")
FILM = ROOT / ".context" / "pin-motion" / "pin-film"
PID = [0]


def stage(dark):
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [1600, 960]})
    pc.WINDOW[0], PID[0] = staged["window"], staged["pid"]
    pc.SIZE[:] = [1600, 960]
    sv.cmd({"do": "ui", "look": "dark" if dark else "light"})
    time.sleep(0.8)


def film(name, act, crop, seconds=1.2):
    crop = ",".join(str(v / 2) for v in map(float, crop.split(",")))
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("0*.png"):
        old.unlink()
    taker = subprocess.Popen([str(FILM), str(PID[0]), str(pc.WINDOW[0]), str(folder), str(seconds), crop],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        print(f"  FAIL {name}: not filmed: {line} {taker.stderr.read()}")
        return
    time.sleep(0.12)
    act()
    taker.communicate()
    count = len(list(folder.glob("0*.png")))
    print(f"  ok   {name}: {count} frames", flush=True)


def after(delay, fn):
    threading.Timer(delay, fn).start()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Tests/pin_film.swift"
    FILM.parent.mkdir(parents=True, exist_ok=True)
    if not FILM.exists() or FILM.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(FILM)], check=True)
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False, "tabs.groups": False,
                    "welcome.show": False})
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "250"], check=True)
        pc.launch()
        sv.cmd({"do": "window"})
        sv.sp("enabled", on=True)
        stage(False)
        sv.cmd({"do": "space", "action": "new", "name": "Film"})
        time.sleep(1)
        a = pc.opened("left-page")
        b = pc.opened("right-page")
        sv.sp("select", id=a)
        sv.sp("pair", id=b, **{"with": a}, side="right")
        time.sleep(1.4)
        for dark in (False, True):
            theme = "dark" if dark else "light"
            stage(dark)
            sv.cmd({"do": "space", "action": "look", **pc.ALL_LOOKS["pale"]})
            sv.sp("focus", id=a)
            time.sleep(1)
            left, right = pc.pair_frames(a, b)
            gx = (left["x"] + left["width"] + right["x"]) / 2
            strip = f"{int(gx - 180)},0,360,960"
            film(f"{theme}-swap", lambda: after(0.1, lambda: sv.sp("swap")), strip)
            time.sleep(1)
            sv.sp("swap")
            time.sleep(1.2)
            film(f"{theme}-apart", lambda: after(0.1, lambda: sv.sp("detach", id=b)), strip)
            time.sleep(1)
            sv.sp("select", id=a)
            time.sleep(0.6)
            film(f"{theme}-forming", lambda: after(0.1, lambda: sv.sp("pair", id=b, **{"with": a}, side="right")), strip)
            time.sleep(1.2)
            left, right = pc.pair_frames(a, b)
            x, y = left["x"] + left["width"] / 2, left["y"] - pc.BAR / 2
            steps = [[x + 4 * k * k, y] for k in range(0, 13)]

            def carry():
                sv.sp("mouse", points=steps, hold=True, to="view")
                time.sleep(0.3)
                sv.sp("mouse", points=[steps[-1], steps[-1]], resume=True, to="view")
            film(f"{theme}-drag", lambda: after(0.1, carry), f"{int(left['x'] + left['width'] - 200)},0,760,960", seconds=2.2)
            time.sleep(1.4)
            order = [f["id"] for f in sorted(sv.sp("state")["paneFrames"], key=lambda f: f["x"]) if f["id"] in (a, b)]
            if order != [a, b]:
                sv.sp("swap")
                time.sleep(1.2)
    finally:
        sv.finish()


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The traffic lights go grey when their window is not in front.

Build first (`./build.sh`), then `python3 Tests/lights_dim.py OUT`. One
SEARCH_SHOWN run of a few seconds: a small test window at the bottom right
of the screen, brought forward once. Its own window is captured by its id
(never a region of the display) while it is key, after a second window of
the test copy takes key, and with the test copy inactive (NSApp.deactivate).
With `behind` as the third argument the test copy is never brought
forward and only the inactive capture is taken, which takes no focus.
The three buttons are read from each capture: lit is red, yellow and green,
not in focus is three greys. Crops at 3x and the pixel values go to OUT.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("lights-dim")
t = sv.T()
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/lights-dim").resolve()
LABEL = sys.argv[2] if len(sys.argv) > 2 else "run"
LOCKED = '"CGSSessionScreenIsLocked"=Yes' in subprocess.run(["ioreg", "-n", "Root", "-d1"], capture_output=True, text=True).stdout
BEHIND = "behind" in sys.argv[3:] or LOCKED
if LOCKED:
    print("  the screen is locked, so the test copy cannot come to the front: only the picture with it inactive is taken")
TOOLS = OUT / "tools"
WIDTH, HEIGHT = 660, 430


def c(**r):
    return sv.cmd(r)


def tool(name):
    binary = TOOLS / name
    if not binary.exists():
        TOOLS.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(sv.ROOT / "Tests" / f"{name}.swift"), "-o", str(binary)], check=True)
    return str(binary)


SCREEN = """import AppKit
let f = NSScreen.screens[0].frame, v = NSScreen.screens[0].visibleFrame
print(Int(v.minX), Int(v.minY), Int(v.width), Int(v.height), Int(f.minX), Int(f.minY), Int(f.width), Int(f.height))
"""


def screen():
    source = TOOLS / "Screen.swift"
    TOOLS.mkdir(parents=True, exist_ok=True)
    source.write_text(SCREEN)
    if not (TOOLS / "Screen").exists():
        subprocess.run(["swiftc", str(source), "-o", str(TOOLS / "Screen")], check=True)
    return [int(v) for v in subprocess.run([str(TOOLS / "Screen")], capture_output=True, text=True, check=True).stdout.split()]


def launch_shown(frame):
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", *(["-g"] if BEHIND else []), "--env", "SEARCH_SHOWN=1", "--env", f"SEARCH_PROBE={sv.W}", sv.APP,
                    "--args", f"-NSWindow Frame search ({sv.W})", frame], check=True)
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(1)
    sv.started.update((sv.running() - before) & sv.holding())
    return sv.pids()


def kind(rgb):
    r, g, b = rgb
    if max(rgb) - min(rgb) < 30:
        return "grey"
    if r > 170 and g < 140 and b < 140:
        return "red"
    if r > 170 and g > 130 and b < 120:
        return "yellow"
    if g > 130 and r < 160 and b < 160:
        return "green"
    return "other"


def png_width(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return int.from_bytes(head[16:20], "big")


GLASS = [(200, 95), (200, 137), (400, 182)]


def shoot(name, pid, number, report, keep=False):
    png = OUT / f"{LABEL}-{name}-full.png"
    subprocess.run([tool("WindowShot"), str(pid), str(number), str(png)], check=True)
    if not png.exists():
        raise RuntimeError("WindowShot made no picture: screen recording permission or no window")
    browser = next(b for b in report["browsers"] if b["number"] == number)
    scale = png_width(png) / WIDTH
    frames = [b["frame"] for b in browser["buttons"]]
    points = [f"{f[0] + f[2] / 2},{f[1] + f[3] / 2}" for f in frames] + [f"{x},{y}" for x, y in GLASS]
    left = min(f[0] for f in frames) - 8
    top = min(f[1] for f in frames) - 8
    right = max(f[0] + f[2] for f in frames) + 8
    bottom = max(f[1] + f[3] for f in frames) + 8
    crop = OUT / f"{LABEL}-{name}.png"
    line = subprocess.run([tool("LightsCrop"), str(png), str(crop), str(left), str(top), str(right - left), str(bottom - top), str(scale), *points],
                          capture_output=True, text=True, check=True).stdout.strip()
    if not keep:
        png.unlink(missing_ok=True)
    rgbs = [[int(v) for v in s[4:-1].split(",")] for s in line.split()]
    return {"lights": rgbs[:3], "kinds": [kind(p) for p in rgbs[:3]], "glass": rgbs[3:], "key": browser["key"], "main": browser["main"],
            "active": report["active"], "keyWindow": report["keyWindow"], "mainWindow": report["mainWindow"]}


def expect(report, active, key, number):
    browser = next(b for b in report["browsers"] if b["number"] == number)
    if report["active"] != active or browser["key"] != key:
        raise RuntimeError(f"wrong state for a capture: active {report['active']} key {browser['key']}, wanted {active} {key}")


results = {}
LIT = ["red", "yellow", "green"]
GREY = ["grey"] * 3
try:
    OUT.mkdir(parents=True, exist_ok=True)
    tool("WindowShot")
    tool("LightsCrop")
    vx, vy, vw, vh, fx, fy, fw, fh = screen()
    first_frame = [vx + vw - WIDTH, vy, WIDTH, HEIGHT]
    sv.setup(**{"sidebar": True, "start.fresh": False, "spaces": True})
    pids = launch_shown(f"{first_frame[0]} {first_frame[1]} {WIDTH} {HEIGHT} {fx} {fy} {fw} {fh}")
    c(do="windows", action="frame", n=1, frame=first_frame)
    t.ok("one test copy", len(pids) == 1, pids)
    pid = int(pids[0])
    time.sleep(1)
    report = c(do="lights")
    first = report["browsers"][0]["number"]
    if BEHIND:
        expect(report, False, False, first)
        results["inactive"] = shoot("inactive", pid, first, report, keep=True)
        t.ok("never in front since launch: grey", results["inactive"]["kinds"] == GREY, results["inactive"])
    else:
        try:
            expect(report, True, True, first)
            results["key"] = shoot("key", pid, first, report)
            c(do="windows", action="new")
            c(do="windows", action="frame", n=2, frame=[first_frame[0] - WIDTH - 20, vy, WIDTH, HEIGHT])
            time.sleep(0.6)
            report = c(do="lights")
            expect(report, True, False, first)
            results["other"] = shoot("other", pid, first, report)
        finally:
            c(do="idle", action="give")
        time.sleep(0.8)
        report = c(do="lights")
        expect(report, False, False, first)
        results["inactive"] = shoot("inactive", pid, first, report)
        t.ok("key: lit", results["key"]["kinds"] == LIT, results["key"])
        t.ok("another window of the app key: grey", results["other"]["kinds"] == GREY, results["other"])
        t.ok("app inactive: grey", results["inactive"]["kinds"] == GREY, results["inactive"])
except Exception:
    import traceback
    traceback.print_exc()
    t.failed += 1
finally:
    (OUT / f"{LABEL}.json").write_text(json.dumps(results, indent=1))
    sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)

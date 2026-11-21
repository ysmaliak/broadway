#!/usr/bin/env python3
import argparse
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="now")
parser.add_argument("--on", action="store_true")
parser.add_argument("--width", type=float, default=258)
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("selected-shortcut-" + uuid.uuid4().hex[:6])
TMP = Path("/tmp") / f"broadway-shortcut-{os.getpid()}"
OUT = ROOT / ".context" / "selected-shortcut" / args.label
rl.SHOT = TMP / "shot"
pid = number = None


def shoot(name):
    raw = TMP / f"{name}-raw.png"
    for attempt in range(4):
        try:
            rl.shoot(pid, number, raw)
            break
        except RuntimeError:
            if attempt == 3:
                raise
            sv.cmd({"do": "idle", "action": "unhide"})
            time.sleep(0.8)
    k = rl.scale_of(raw)
    out = OUT / f"{name}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-vf",
                    f"crop={int((args.width + 14) * k)}:ih:0:0", str(out)], check=True)
    print("  pictured", out)
    return out


def wheel(dy):
    for _ in range(6):
        try:
            sv.cmd({"do": "columnscroll", "wheel": dy})
        except RuntimeError as e:
            print("  wheel:", e)


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    copy = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", copy)
    subprocess.run(["swiftc", "-parse-as-library", str(copy), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(**{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(args.width)], check=True)
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
        sv.cmd({"do": "resize", "width": 1000, "height": 640, "steps": 1})
        ids = [sv.page(f"row-{n:02d}") for n in range(30)]
        made = {i[:8].lower() for i in ids}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        if args.on:
            sv.cmd({"do": "settings", "find": "", "set": "sidebar.selected", "value": True})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
            sv.sp("select", id=ids[1])
            time.sleep(0.8)
            wheel(600)
            time.sleep(1.2)
            t.ok(f"{theme}: above", shoot(f"above-{theme}").exists())
            sv.sp("select", id=ids[-2])
            time.sleep(0.8)
            wheel(-600)
            time.sleep(1.2)
            t.ok(f"{theme}: below", shoot(f"below-{theme}").exists())
            sv.cmd({"do": "columnscroll", "wheel": 120})
            t.ok(f"{theme}: while scrolling", shoot(f"scrolling-{theme}").exists())
            time.sleep(1.2)
            t.ok(f"{theme}: settled again", shoot(f"settled-{theme}").exists())
    finally:
        t.done()
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

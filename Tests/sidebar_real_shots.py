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
parser.add_argument("--width", type=float, default=258)
parser.add_argument("--looks", default="dark-black,dark-near,light-pale,dark-vivid,light-vivid")
parser.add_argument("--out", default=str(ROOT / ".context" / "sidebar-real"))
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("real-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
TMP = Path("/tmp") / f"broadway-real-{os.getpid()}"
OUT = Path(args.out) / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"

GROUNDS = {"pale": "F2EEE6", "vivid": "3139FB", "near": "171616", "black": "000000"}
PINS = ["https://github.com", "https://news.ycombinator.com", "https://www.youtube.com", "https://www.figma.com",
        "https://linear.app", "https://www.notion.com"]
DESIGN = ["https://fonts.google.com", "https://dribbble.com", "https://www.apple.com/macos/"]
READING = ["https://www.theverge.com", "https://arstechnica.com"]
LOOSE = ["https://en.wikipedia.org/wiki/Web_browser", "https://stripe.com", "https://vercel.com", "https://x.com",
         "https://developer.mozilla.org/en-US/", "https://www.swift.org", "https://tailwindcss.com", "https://www.apple.com"]


def opened(url):
    id = sv.sp("open", url=url)["resultID"]
    time.sleep(0.4)
    return id


def look(theme, ground):
    sv.cmd({"do": "ui", "look": theme})
    sv.cmd({"do": "space", "action": "look", "custom": GROUNDS[ground], "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0})


def group(**r):
    return sv.cmd({"do": "group", **r})


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False})
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
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        pins = [opened(u) for u in PINS]
        design = [opened(u) for u in DESIGN]
        reading = [opened(u) for u in READING]
        loose = [opened(u) for u in LOOSE]
        time.sleep(8)
        made = {i[:8].lower() for i in pins + design + reading + loose}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError:
                    pass
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        group(id=design[0][:8].lower(), new=True, name="Design")
        for id in design[1:]:
            group(id=id[:8].lower(), name="Design")
        group(id=reading[0][:8].lower(), new=True, name="Reading")
        group(id=reading[1][:8].lower(), name="Reading")
        group(name="Reading", fold=True)
        time.sleep(2)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        crop = int(args.width + 14)

        def shot(name):
            still = TMP / f"{name}.png"
            rl.shoot(pid, number, still)
            k = rl.scale_of(still)
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                            f"crop={crop * k}:ih:0:0", str(OUT / f"{name}.png")], check=True)
            print(OUT / f"{name}.png")

        for pair in args.looks.split(","):
            theme, ground = pair.split("-")
            look(theme, ground)
            sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
            sv.sp("select", id=loose[0])
            time.sleep(1.2)
            sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": True})
            time.sleep(0.6)
            shot(f"{pair}-loose")
            sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": False})
            sv.sp("select", id=design[1])
            time.sleep(0.8)
            group(name="Reading", look="hover")
            sv.cmd({"do": "rowhover", "id": design[2][:8], "on": True})
            time.sleep(0.6)
            shot(f"{pair}-card")
            sv.cmd({"do": "rowhover", "id": design[2][:8], "on": False})
            group(name="Reading", look="clear")
            sv.sp("select", id=pins[0])
            time.sleep(0.8)
            sv.cmd({"do": "rowhover", "id": pins[2][:8], "on": True})
            time.sleep(0.6)
            shot(f"{pair}-pin")
            sv.cmd({"do": "rowhover", "id": pins[2][:8], "on": False})
            sv.sp("select", id=pins[1])
            time.sleep(0.8)
            sv.sp("pick", ids=[pins[3], pins[5], loose[4]])
            sv.cmd({"do": "rowhover", "id": pins[4][:8], "on": True})
            time.sleep(0.8)
            shot(f"{pair}-pinstates")
            sv.cmd({"do": "rowhover", "id": pins[4][:8], "on": False})
            sv.sp("pick", ids=[])
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)


if __name__ == "__main__":
    main()

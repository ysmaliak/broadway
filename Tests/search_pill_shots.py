#!/usr/bin/env python3
"""The sidebar's address pill at rest, hovered and riding a space switch.

Build first (`./build.sh`), then
`python3 Tests/search_pill_shots.py LABEL [--themes dark,light] [--grounds near,vivid,pale] [--no-film]`.

Three spaces in a test copy of their own (SEARCH_SHOWN, behind the app in
front): Personal and Work with pins and loose tabs from a local server
(127.0.0.1 and localhost, so their pills read differently), and Empty with
only a blank tab. Window-only stills of the column's top go to
.context/pill/LABEL/: THEME-GROUND-rest.png and -hover.png (the pill hovered
through the bench), narrow-*.png at the narrowest column, prompt-*.png on the
blank space, and, unless --no-film, contact sheets of a trackpad stroke and a
⌃-number switch filmed at 60 fps with the window-only film tool, cropped to
the column's top (slide-*.png).
"""
import argparse
import json
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
parser.add_argument("--grounds", default="near,vivid,pale")
parser.add_argument("--themes", default="dark,light")
parser.add_argument("--no-film", action="store_true")
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402
import motion_audit as ma  # noqa: E402

sv.use("pill-" + uuid.uuid4().hex[:6])
TMP = Path("/tmp") / f"broadway-pill-{os.getpid()}"
OUT = ROOT / ".context" / "pill" / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"
PORT = rl.server.server_port

LOOKS = {
    "near": {"custom": "000000", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "warm": {"custom": "FF8A1F", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
}


def opened(host, icon, title):
    rl.counter[0] += 1
    id = sv.sp("open", url=f"http://{host}:{PORT}/p{rl.counter[0]}/{icon}/{title.encode().hex()}")["resultID"]
    time.sleep(0.3)
    return id


def space(**f):
    return sv.cmd({"do": "space", **f})


def hover(on, **more):
    try:
        return sv.cmd({"do": "addresshover", "on": on, **more})
    except RuntimeError as e:
        print("  no bench hover:", e)
        return {}


def size_of(still):
    said = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(still)], capture_output=True, text=True).stdout.split()
    return int(said[said.index("pixelWidth:") + 1]), int(said[said.index("pixelHeight:") + 1])


def main():
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    (TMP / "pixel.swift").write_text(rl.PIXEL_SOURCE)
    subprocess.run(["swiftc", "-O", str(TMP / "pixel.swift"), "-o", str(rl.PIXEL)], check=True, cwd=TMP)
    if not args.no_film:
        ma.build_film()
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True})
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
    report = {}
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        worlds = [("Personal", "127.0.0.1", ["black", "orange", "blue", "green"], ["Weekend plans", "Mobile Sync", "Wide Layout Pass"]),
                  ("Work", "localhost", ["violet", "red", "black"], ["Pull requests", "Roadmap", "Standup notes"])]
        chosen = {}
        for index, (name, host, pins, loose) in enumerate(worlds):
            if index > 0:
                space(action="new", name=name)
            space(action="go", index=index + 1)
            made_pins = [opened(host, icon, f"{name} pin {k}") for k, icon in enumerate(pins)]
            made = [opened(host, "grey", title) for title in loose]
            time.sleep(1.5)
            for id in made_pins:
                sv.cmd({"do": "pin", "id": id})
            ids = {i[:8].lower() for i in made_pins + made}
            for tab in sv.cmd({"do": "tabs"})["tabs"]:
                if tab["id"][:8].lower() not in ids and not tab["url"].startswith("http"):
                    try:
                        sv.sp("close", id=tab["id"])
                    except RuntimeError:
                        pass
            sv.sp("select", id=made[1])
            chosen[name] = made[1]
        space(action="new", name="Empty")
        space(action="go", index=1)
        time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        width = args.width + 6
        height = 230

        def shoot(name, crop_height=height):
            raw = TMP / f"{name}-raw.png"
            rl.shoot(pid, number, raw)
            k = max(1, round(size_of(raw)[0] / 1000))
            out = OUT / f"{name}.png"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-vf",
                            f"crop={int(width * k)}:{int(crop_height * k)}:0:0", str(out)], check=True)
            return raw, k

        def looks(ground):
            for index in (1, 2, 3):
                space(action="go", index=index)
                space(action="look", **LOOKS[ground])
            space(action="go", index=1)

        for theme in args.themes.split(","):
            for ground in args.grounds.split(","):
                if theme == "light" and ground == "near":
                    continue
                if theme == "dark" and ground == "pale":
                    continue
                sv.cmd({"do": "ui", "look": theme})
                looks(ground)
                sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
                time.sleep(1.2)
                name = f"{theme}-{ground}"
                raw, k = shoot(f"{name}-rest")
                hovered = hover(True)
                time.sleep(0.5)
                shoot(f"{name}-hover")
                hover(True, press=True)
                time.sleep(0.4)
                shoot(f"{name}-pressed")
                hover(False, press=False)
                frame = hovered.get("frame") or []
                if frame:
                    x, y, w, h = frame
                    top = 760 - y - h
                    report[name] = {"frame": frame, "scale": k,
                                    "fill": rl.pixels(raw, [(round((x + w - 40) * k), round((top + h / 2) * k))])[0],
                                    "ground": rl.pixels(raw, [(round((x - 3) * k), round((top + h / 2) * k))])[0],
                                    "trace": rl.trace(raw, x + w - 40, top - 3, top + h + 3)}
                t.ok(f"pictured {name}", (OUT / f"{name}-hover.png").exists())
        sv.cmd({"do": "ui", "look": "dark"})
        looks("near")
        space(action="go", index=3)
        time.sleep(1.2)
        shoot("prompt-dark-near")
        space(action="go", index=1)
        time.sleep(1.0)
        if not args.no_film:
            column = args.width
            for name, act in (("slide-trackpad", lambda: space(action="trackpad", gestures=[{"stops": [-120], "speed": 420, "momentum": True}])),
                              ("slide-key", lambda: space(action="key", index=2)),
                              ("slide-hovered", lambda: space(action="trackpad", gestures=[{"stops": [-120], "speed": 420, "momentum": True}])),
                              ("slide-new-space", lambda: space(action="trackpad", gestures=[{"stops": [-260], "speed": 900, "momentum": True}]))):
                if name == "slide-new-space":
                    space(action="go", index=3)
                    time.sleep(1.4)
                else:
                    space(action="go", index=1)
                    time.sleep(1.4)
                if name == "slide-hovered":
                    hover(True)
                    time.sleep(0.5)
                taker = subprocess.Popen([str(ma.FILM), "--pid", str(pid), "--seconds", "1.4", "--out", str(TMP / name), "--scale", "1",
                                          "--fps", "60", "--columns", "6", "--crop", f"0,0,{column + 8},{height}"],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                line = taker.stdout.readline()
                if not line.startswith("ready"):
                    taker.wait()
                    t.ok(f"filmed {name}", False, line + taker.stderr.read())
                    continue
                act()
                taker.wait()
                hover(False)
                for suffix in ("", "-first", "-last"):
                    made = TMP / f"{name}{suffix}.png"
                    if made.exists():
                        shutil.copy(made, OUT / f"{name}{suffix}.png")
                t.ok(f"filmed {name}", (OUT / f"{name}.png").exists())
        space(action="go", index=1)
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        sv.cmd({"do": "ui", "sideWidth": 200})
        time.sleep(1.0)
        width = 206
        shoot("narrow-dark-near-rest")
        hover(True)
        time.sleep(0.5)
        shoot("narrow-dark-near-hover")
        hover(False)
        (OUT / "measure.json").write_text(json.dumps(report, indent=1))
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

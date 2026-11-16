#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

parser = argparse.ArgumentParser(description="Stills of the onboarding, of a probe's own windows by id, into .context/LABEL/: every step "
                                 "in dark and light, the Bring step with and without browsers found, the later steps in four looks, the look "
                                 "chooser with each look picked, the New Space card, and a window whose space took a look in the onboarding, "
                                 "with the mean colour of an empty patch of its sidebar.")
parser.add_argument("label")
parser.add_argument("--only", default="", help="any of steps,bring,chooser,card,window")
parser.add_argument("--look", default="noir", help="the look the window takes")
options = parser.parse_args()
OUT = ROOT / ".context" / options.label
TOOLS = ROOT / ".context" / "visual-tools"
only = set(filter(None, options.only.split(",")))
STEPS = ["space", "side", "links", "agents", "key", "bring"]
PLATE = "1A1C21"
WEARS = ["noir", "glass", "dusk", "paper"]
pid = None


def tool(name, source):
    TOOLS.mkdir(parents=True, exist_ok=True)
    out = TOOLS / name
    src = ROOT / "Tests" / source
    if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(src), "-o", str(out)], check=True)
    return out


def cmd(**request):
    return sv.cmd(request)


def onboarding(action="state", **more):
    return cmd(do="onboarding", action=action, **more)


def shoot(number, name):
    path = OUT / f"{name}.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    print(f"  {name}: {said}", flush=True)
    return path


def surface(name, shot, look, **more):
    shown = cmd(do="surface", name=name, look=look, **more)
    time.sleep(0.7)
    path = shoot(shown["number"], shot)
    cmd(do="surface", action="close")
    return path


def mean(path, box):
    read = subprocess.run([str(PIXEL), str(path), *[str(v) for v in box]], capture_output=True, text=True).stdout
    return json.loads(read or "{}")


def fabricate():
    for folder in ("Google/Chrome/Default", "Dia/User Data/Default", "Arc/User Data/Default", "BraveSoftware/Brave-Browser/Default"):
        made = Path(sv.SUPPORT) / "Import" / folder
        made.mkdir(parents=True, exist_ok=True)
        (made / "Bookmarks").write_text('{"roots":{"bookmark_bar":{"children":[],"type":"folder"}}}')


def launch():
    global pid
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))


def steps():
    for look in ("dark", "light"):
        cmd(do="ui", look=look)
        time.sleep(0.4)
        for index, step in enumerate(STEPS):
            surface("onboarding", f"step-{index + 1}-{step}-{look}", look, step=index + 1, pad=0, ground=PLATE)
        surface("onboarding", f"step-{STEPS.index('key') + 1}-key-refused-{look}", look, step=STEPS.index("key") + 1,
                keyNote="OpenRouter turned this key down", pad=0, ground=PLATE)
    bring()
    for wears in WEARS:
        onboarding("replay", reduced=True)
        time.sleep(0.4)
        onboarding("skip")
        onboarding(f"look:{wears}")
        onboarding("primary")
        onboarding("close")
        time.sleep(1.2)
        for look in ("dark", "light"):
            cmd(do="ui", look=look)
            time.sleep(0.4)
            for index in range(1, len(STEPS) - 1):
                surface("onboarding", f"wearing-{wears}-{index + 1}-{STEPS[index]}-{look}", look, step=index + 1, pad=0, ground=PLATE)


def bring():
    for look in ("dark", "light"):
        cmd(do="ui", look=look)
        time.sleep(0.4)
        surface("onboarding", f"step-{len(STEPS)}-bring-safari-alone-{look}", look, step=len(STEPS), pad=0, ground=PLATE)
    fabricate()
    print(f"  offered: {onboarding()['sources']}", flush=True)
    for look in ("dark", "light"):
        cmd(do="ui", look=look)
        time.sleep(0.4)
        surface("onboarding", f"step-{len(STEPS)}-bring-sources-{look}", look, step=len(STEPS), pad=0, ground=PLATE)
        surface("onboarding", f"step-{len(STEPS)}-bring-safari-picked-{look}", look, step=len(STEPS), source="Safari", pad=0, ground=PLATE)
        surface("import-page", f"panel-on-safari-{look}", look, style="Safari", pad=0)


def chooser():
    looks = cmd(do="space")["looks"]
    for look in ("dark", "light"):
        cmd(do="ui", look=look)
        time.sleep(0.4)
        for picked in looks:
            surface("space-look-chooser", f"chooser-{picked}-{look}", look, pick=picked, pad=28, ground=PLATE)


def card():
    for look in ("dark", "light"):
        cmd(do="ui", look=look)
        time.sleep(0.4)
        surface("new-space-card", f"new-space-card-{look}", look, pad=20)


def window():
    cmd(do="windows", action="frame", n=1, frame=[80, 80, 1180, 760])
    number = cmd(do="idle", action="unhide")["number"]
    onboarding("replay", reduced=True)
    time.sleep(0.5)
    onboarding("skip")
    onboarding(f"look:{options.look}")
    time.sleep(0.3)
    state = onboarding("primary")
    onboarding("close")
    time.sleep(1.6)
    print(f"  the space took {state['look']}", flush=True)
    for look in ("dark", "light"):
        cmd(do="ui", look=look)
        time.sleep(0.9)
        path = shoot(number, f"window-{options.look}-{look}")
        if path.exists():
            print(f"  sidebar ground, {look}: {mean(path, [0.02, 0.45, 0.19, 0.8])}", flush=True)


def main():
    global SHOT, PIXEL
    SHOT = tool("window-shot", "WindowShot.swift")
    PIXEL = tool("ground-pixel", "GroundPixel.swift")
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("onboarding-shots-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    launch()
    try:
        for name, work in (("steps", steps), ("bring", bring), ("chooser", chooser), ("card", card), ("window", window)):
            if name == "bring" and (not only or "steps" in only):
                continue
            if not only or name in only:
                work()
    finally:
        sv.finish()


if __name__ == "__main__":
    main()

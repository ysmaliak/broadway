#!/usr/bin/env python3
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
import split_view as sv  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "now"
parts = set(sys.argv[2:]) or {"migrate", "card"}
sv.use("look-card-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "look-card" / label
WORK = ROOT / ".context" / "look-card-tools"
SHOT = WORK / "shot"
POP = WORK / "popover"

FIRST = "00000000-0000-0000-0000-000000000001"


def stored(**fields):
    return {"transparency": 0, "grain": 0, "glass": False, "v": 4, **fields}


PRESETS = ["graphite", "gray", "paper", "coral", "peach", "sage", "sky", "lavender", "rose"]
THEMES = [
    ("cobalt", ["3139FB"], 1), ("ember", ["FB3A4D"], 1), ("midnight", ["000354", "2404AA"], 1), ("ink", ["000000"], 1),
    ("sunset", ["FF89B3", "FF8A1F"], 0.75), ("lagoon", ["0F9D94", "8CACFF"], 0.8), ("lilac", ["F0B4FF", "8CACFF"], 0.75),
    ("citrus", ["E8FF1A", "8BE33A"], 0.6), ("aurora", ["8BE33A", "7CC4F2", "7B3FE4"], 0.7), ("onyx", ["000000"], 2),
    ("abyss", ["000354"], 2), ("volt", ["p3:3029FF"], 2),
]


def theme(colours, intensity, **more):
    look = stored(colour="custom", custom=colours[0], intensity=intensity, **more)
    if len(colours) > 1:
        look["colours"] = colours
    return look


FIXTURES = [("preset-" + p, stored(colour=p)) for p in PRESETS]
FIXTURES += [("theme-" + n, theme(c, i)) for n, c, i in THEMES]
FIXTURES += [
    ("custom-calm", stored(colour="custom", custom="7B3FE4")),
    ("custom-half", theme(["FF8A1F"], 0.5)),
    ("custom-vivid", theme(["0F9D94"], 1.5)),
    ("two-stops", theme(["FF89B3", "3139FB"], 0.8)),
    ("three-stops", theme(["000354", "FB3A4D", "F0B4FF"], 1.2)),
    ("clear", stored(colour="sky", transparency=0.5)),
    ("grain", theme(["E8FF1A", "8BE33A"], 0.6, grain=0.8)),
    ("glass", stored(colour="gray", glass=True)),
    ("glass-custom", theme(["3139FB"], 0.8, glass=True, transparency=0.5)),
    ("noir", theme(["000000"], 2, grain=0.3)),
    ("dusk", theme(["2B1A7A", "D23770", "BF5600"], 2, grain=0.4)),
    ("paper", theme(["EFE6D2"], 2, grain=0.5)),
    ("old-v1", {"colour": "coral"}),
]

NEWER = [
    ("one-colour-sky", stored(colour="sky", mode="one", fixed="dark")),
    ("one-colour-cobalt", theme(["3139FB"], 0.6, mode="one", fixed="light")),
    ("both-follow-rose", stored(colour="rose", mode="both")),
    ("both-by-hand", stored(colour="peach", mode="both", dark=theme(["000354", "2404AA"], 1), light={"colour": "peach"})),
    ("both-one-side", stored(colour="sage", mode="both", dark={"colour": "custom", "custom": "FB3A4D", "intensity": 1}, grain=0.3)),
    ("unreadable-new-fields", stored(colour="sky", mode="sometimes", fixed=7, dark="blue", light={"colour": 3})),
]
if os.environ.get("LOOK_WORLD") == "newer":
    FIXTURES = NEWER


def world():
    spaces = [{"id": FIRST, "name": "Personal", "colour": 0, "look": FIXTURES[0][1]}]
    for name, look in FIXTURES[1:]:
        spaces.append({"id": str(uuid.uuid4()).upper(), "name": name, "colour": 0, "look": look})
    spaces[0]["name"] = FIXTURES[0][0]
    os.makedirs(sv.SUPPORT, exist_ok=True)
    Path(sv.SUPPORT, "spaces.json").write_text(json.dumps(spaces))
    (OUT / "spaces-written.json").write_text(json.dumps(spaces, indent=1))


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists():
        raise RuntimeError(out or "no still")


def card(pid, number, path):
    print(subprocess.run([str(POP), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip())


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    if not SHOT.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    if not POP.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/PopoverShot.swift"), "-o", str(POP)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    world()
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
        sv.cmd({"do": "resize", "width": 900, "height": 600, "steps": 1})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        state = sv.cmd({"do": "space", "action": "state"})
        names = [s["name"] for s in state["spaces"]]
        print("spaces", len(names))
        if "migrate" in parts:
            (OUT / "migrate").mkdir(exist_ok=True)
            for appearance in ["light", "dark"]:
                sv.cmd({"do": "ui", "look": appearance})
                only = [n for n in os.environ.get("LOOK_ONLY", "").split(",") if n]
                for index, name in enumerate(names):
                    if only and name not in only:
                        continue
                    sv.cmd({"do": "space", "action": "go", "index": index + 1})
                    time.sleep(float(os.environ.get("LOOK_WAIT", "0.9")))
                    shoot(pid, number, OUT / "migrate" / f"{appearance}-{name}.png")
        if "card" in parts:
            (OUT / "card").mkdir(exist_ok=True)
            for appearance in ["dark", "light"]:
                sv.cmd({"do": "ui", "look": appearance})
                for name in ["preset-gray", "theme-cobalt", "two-stops", "grain"]:
                    sv.cmd({"do": "space", "action": "go", "index": names.index(name) + 1})
                    time.sleep(0.6)
                    sv.cmd({"do": "ui", "editlook": True})
                    time.sleep(1.2)
                    card(pid, number, OUT / "card" / f"{appearance}-{name}.png")
                    sv.cmd({"do": "ui", "editlook": False})
                    time.sleep(0.6)
        if "modes" in parts:
            (OUT / "modes").mkdir(exist_ok=True)
            scenes = [
                ("one-colour", {"colour": "sky", "mode": "one"}, False),
                ("both-follow", {"colour": "sky", "mode": "both"}, False),
                ("each-by-hand", {"colour": "sky", "mode": "both", "dark": {"swatch": "midnight"}, "light": {"swatch": "peach"}}, False),
                ("more-open", {"colour": "sky", "mode": "both", "dark": {"swatch": "midnight"}, "light": {"swatch": "peach"}}, True),
            ]
            sv.cmd({"do": "space", "action": "go", "index": 1})
            for appearance in ["dark", "light"]:
                sv.cmd({"do": "ui", "look": appearance})
                for name, look, more in scenes:
                    sv.cmd({"do": "space", "action": "look", "shade": appearance, **look})
                    time.sleep(0.5)
                    sv.cmd({"do": "ui", "editlook": True, "lookMore": more})
                    time.sleep(1.2)
                    card(pid, number, OUT / "modes" / f"{appearance}-{name}.png")
                    shoot(pid, number, OUT / "modes" / f"{appearance}-{name}-window.png")
                    sv.cmd({"do": "ui", "editlook": False})
                    time.sleep(0.6)
        saved = Path(sv.SUPPORT, "spaces.json")
        if saved.exists():
            shutil.copy(saved, OUT / "spaces-after.json")
    finally:
        sv.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Pictures of text actions, light and dark, into .context/text-actions/.

Build first (`./build.sh`), then `python3 Tests/text_actions_shots.py`. A shown
test world with a fake plan: the right-click menu on selected words, the list
of commands and a finished Improve Writing, each taken of this probe's own
windows by number. Settings › Agents is the bench's own picture of that page,
drawn off the Settings window, which is never opened here.
"""
import os
import shutil
import subprocess
import tempfile
import sys
import threading
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import text_actions as words  # noqa: E402

OUT = ROOT / ".context" / "text-actions"
DRAWN = Path(tempfile.mkdtemp(prefix="text-actions-shots-"))
SHOT = DRAWN / "shot"


def keep(name):
    drawn = DRAWN / f"{name}.png"
    if drawn.exists():
        shutil.move(str(drawn), str(OUT / drawn.name))
        return True
    return False


def shoot(pid, number, name, menu=False):
    path = DRAWN / f"{name}.png"
    for _ in range(4):
        said = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
        parts = said.split()
        if said.startswith("shot") and (not menu or int(parts[parts.index("menus") + 1]) >= 1):
            print("   ", said)
            return keep(name)
        time.sleep(0.5)
    print("   ", said)
    return False


def run(theme):
    sv.use("text-shots-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
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
        sv.cmd({"do": "ai", "action": "fake", "plan": "claude", "answer": words.AFTER, "mac": False})
        tab = sv.sp("open", url=f"{words.BASE}/words")["resultID"]
        sv.sp("select", id=tab)
        sv.cmd({"do": "wait", "id": tab, "seconds": 20})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1.5)

        at = sv.ev(tab, words.pick_field("box"))
        held = threading.Thread(target=lambda: sv.cmd({"do": "linkmenu", "id": tab, "x": at[0], "y": at[1],
                                                        "pick": "(nothing)", "hold": 4}))
        held.start()
        time.sleep(1.2)
        shoot(pid, number, f"menu-{theme}", menu=True)
        held.join()
        time.sleep(0.8)

        state = sv.cmd({"do": "ai", "action": "select", "id": tab, "js": words.pick_field("box")})
        time.sleep(0.8)
        shoot(pid, number, f"list-{theme}")
        listed = state.get("commands", [])
        sv.cmd({"do": "ai", "action": "take", "index": listed.index("Improve Writing") if "Improve Writing" in listed else 0})
        words.finished()
        time.sleep(0.8)
        shoot(pid, number, f"result-{theme}")
    finally:
        sv.finish()


def settings():
    sv.use("text-shots-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False})
    sv.launch()
    try:
        sv.cmd({"do": "ai", "action": "fake", "plan": "claude", "answer": words.AFTER, "mac": False})
        for theme in ["light", "dark"]:
            said = sv.cmd({"do": "surface", "name": "settings-agents", "look": theme, "path": str(DRAWN / f"settings-{theme}.png")})
            print("    settings", keep(f"settings-{theme}"), said.get("size"))
            sv.cmd({"do": "surface", "action": "close"})
    finally:
        sv.finish()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/MenuShot.swift"), "-o", str(SHOT)], check=True)
    for theme in sys.argv[1:] or ["light", "dark"]:
        run(theme)
    settings()
    shutil.rmtree(DRAWN, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

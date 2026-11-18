#!/usr/bin/env python3
"""The hint line on a lit History row in the field, in pictures.

Build first (`./build.sh`), then `python3 Tests/field_split_hint.py`. Uses the
split suite's harness in a world of its own. The probe's own window is shown
without being brought forward, and pictures of it are taken by its id, at the
window's default width and at the narrowest it allows, light and dark. Keys
go through the app's own event queue. Pictures go to .context/field-split-hint/.
"""
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-split-hint")

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".context" / "field-split-hint"
LONG = "Garden club planning notes for the spring season"
TAB, ESCAPE, DOWN = (48, "\t"), (53, "\u001b"), (125, "")
CODES = {"h": 4, "i": 34, "s": 1, "t": 17}


def press(key, mods=()):
    code, chars = key if isinstance(key, tuple) else (CODES[key], key)
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})
    time.sleep(0.2)


def rows(*args):
    return sv.cmd({"do": "fieldrows", "args": list(args)})


def tool(work):
    source = work / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    built = subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(work / "shot")], cwd=str(work), capture_output=True)
    return work / "shot" if built.returncode == 0 else None


def shoot(shot, pid, number, name):
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    for _ in range(4):
        subprocess.run([str(shot), str(pid), str(number), str(path)], cwd=str(shot.parent), capture_output=True)
        if path.exists():
            return path
        time.sleep(0.8)
    return None


def main():
    t = sv.T()
    OUT.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="field-split-hint-"))
    pictures = []
    try:
        shot = tool(work)
        t.ok("the picture tool builds", shot is not None)
        sv.setup(splitView=True, **{"newtab.floating": True})
        sv.launch()
        sv.page("start")
        rows("visit", f"{sv.BASE}/garden", "40", LONG)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        pid = next(iter(sv.holding() & sv.running()))
        time.sleep(0.8)
        for width, label in [(1180, "default"), (640, "narrowest")]:
            sv.cmd({"do": "resize", "width": width, "height": 780, "steps": 1})
            time.sleep(0.6)
            for dark in (False, True):
                sv.cmd({"do": "ui", "glassDark": dark})
                time.sleep(0.4)
                press("t", ["cmd"])
                for ch in "hist":
                    press(ch)
                press(TAB)
                state = rows("places")
                picked = next((i for i, r in enumerate(state["rows"]) if r[0].startswith("Garden")), None)
                for _ in range(picked or 0):
                    press(DOWN)
                state = rows("places")
                look = "dark" if dark else "light"
                t.ok(f"{label} width, {look}: History is in the field with the long row lit",
                     state["place"] == "history" and picked is not None and state["picked"] == picked, state)
                time.sleep(0.6)
                if shot:
                    path = shoot(shot, pid, number, f"history-hint-{label}-{look}")
                    t.ok(f"{label} width, {look}: a picture of the window", path is not None)
                    if path:
                        pictures.append(path)
                press(ESCAPE)
                press(ESCAPE)
                time.sleep(0.3)
        sv.cmd({"do": "ui", "glassDark": False})
        sv.cmd({"do": "idle", "action": "hide"})
    finally:
        t.done()
        for path in pictures:
            print("picture", path)
        sv.finish()
        shutil.rmtree(work, ignore_errors=True)
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

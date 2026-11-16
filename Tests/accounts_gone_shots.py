#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("accounts-gone-shots")
ROOT = Path(__file__).resolve().parents[1]
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"accounts-gone-shots-{os.getpid()}"
SHOT = TMP / "shot"


def tool():
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(TMP), check=True)


def ui(**f): return sv.cmd({"do": "ui", **f})


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "accounts-gone").resolve()
    out.mkdir(parents=True, exist_ok=True)
    tool()
    sv.setup(spaces=True, **{"start.fresh": True, "live.on": True})
    sv.launch()
    pid = next(iter(sv.holding() & sv.running()))
    shots = []

    def shoot(name):
        path = out / f"{name}.png"
        got = None
        for _ in range(4):
            got = subprocess.run([str(SHOT), pid, str(number), str(path)], cwd=str(TMP), capture_output=True, text=True)
            if path.exists():
                shots.append(path.name)
                return
            time.sleep(0.8)
        print("no picture", name, got.stdout.strip(), got.stderr.strip()[-300:])

    try:
        sv.cmd({"do": "space", "action": "new", "name": "Work"}); time.sleep(0.8)
        sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.8)
        sv.cmd({"do": "space", "action": "rename", "name": "Personal"}); time.sleep(0.4)
        sv.cmd({"do": "resize", "width": 1040, "height": 1200, "steps": 1})
        ui(settings=True); time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(0.8)
        for address, times in [("https://www.youtube.com/@numberphile", 6), ("https://example.com/feed.xml", 3)]:
            for _ in range(times):
                sv.cmd({"do": "knowing", "action": "visit", "text": address})
        ui(look="dark"); time.sleep(0.8)

        ui(settingsPage="livefolders"); ui(settingsSpace=0); time.sleep(1.2)
        shoot("livefolders-none-dark")
        ui(settingsSpace=2); time.sleep(1.2)
        shoot("livefolders-work-picked-dark")
        ui(settingsSpace=0); time.sleep(1.0)
        for preset in ["github.pulls", "linear.mentions"]:
            ui(settingsPress=f"settings.live.add.{preset}"); time.sleep(1.0)
        shoot("livefolders-two-added-dark")

        ui(settingsPage="tabs"); time.sleep(1.2)
        shoot("tabs-dark")

        ui(settingsPage="field"); time.sleep(1.2)
        shoot("field-show-in-now-dark")

        ui(look="light"); time.sleep(0.8)
        ui(settingsPage="livefolders"); time.sleep(1.2)
        shoot("livefolders-two-added-light")
        ui(settingsSpace=2); time.sleep(1.2)
        shoot("livefolders-work-picked-light")
        print(f"{len(shots)} pictures in {out}")
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())

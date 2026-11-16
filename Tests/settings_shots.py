#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("set-shots")
ROOT = Path(__file__).resolve().parents[1]
SHOT = Path(os.environ.get("TMPDIR", "/tmp")) / f"settings-shot-{os.getpid()}"
DETAILS = ["linkrule"]


def windows(pid):
    out = subprocess.run([str(SHOT), str(pid), "list"], capture_output=True, text=True).stdout
    found = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            found.append((parts[0], parts[1], parts[2]))
    return found


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "shots")
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SettingsShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, ai=True, **{"start.fresh": True})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    shots = 0
    try:
        main_windows = {w[0] for w in windows(pid)}
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.5)
        settings = [w for w in windows(pid) if w[0] not in main_windows]
        if not settings:
            print("SKIP: no Settings window to shoot", windows(pid))
            return 0
        def area(found):
            wide, _, tall = found[1].partition("x")
            return int(wide or 0) * int(tall or 0)
        number = max(settings, key=area)[0]
        height = os.environ.get("SETTINGS_SHOTS_HEIGHT")
        if height:
            try:
                sv.cmd({"do": "ui", "settingsSize": [860, int(height)]})
            except RuntimeError as error:
                print("no settingsSize in this build:", error)
        for rule in (["pattern", "github.com/*/pull/*", "front"], ["add", "notion.so", "peek"], ["add", "figma.com", "window"],
                     ["pattern", "(broken", "ask"]):
            try:
                sv.cmd({"do": "route", "args": rule})
            except RuntimeError as error:
                print("no route command in this build:", error)
        pages = sv.cmd({"do": "settings"}).get("pages", [])
        only = os.environ.get("SETTINGS_SHOTS_ONLY")
        places = [("page", p) for p in pages] + [("detail", d) for d in DETAILS]
        if only:
            wanted = set(only.split(","))
            places = [p for p in places if p[1] in wanted]
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme})
            time.sleep(0.8)
            for kind, name in places:
                if kind == "page":
                    sv.cmd({"do": "ui", "settingsPage": name})
                else:
                    sv.cmd({"do": "ui", "settingsDetail": name})
                time.sleep(1.3)
                index = [p[1] for p in places].index(name)
                path = out / f"{index:02d}-{name}-{theme}.png"
                result = subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True).stdout
                print(result.strip())
                shots += path.exists()
        print(f"{shots} shots in {out}")
    finally:
        sv.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())

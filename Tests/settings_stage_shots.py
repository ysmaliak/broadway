#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("set-stage-shots")
ROOT = Path(__file__).resolve().parents[1]
SHOT = Path(os.environ.get("TMPDIR", "/tmp")) / f"settings-stage-shot-{os.getpid()}"
DETAILS = ["linkrule", "livefolder", "languages"]
SMALL = [("min", 720, 480, ["appearance", "agents", "general"]),
         ("short", 860, 480, ["appearance", "privacy"]),
         ("narrow", 720, 640, ["agents", "linkrule"])]


def windows(pid):
    out = subprocess.run([str(SHOT), str(pid), "list"], capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if line.count("\t") == 2]


def shoot(pid, number, path):
    result = subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True).stdout
    print(result.strip())
    return path.exists()


def go(kind, name):
    if kind == "find":
        sv.cmd({"do": "ui", "settingsFind": name})
    else:
        sv.cmd({"do": "ui", "settingsFind": ""})
        time.sleep(0.2)
        sv.cmd({"do": "ui", "settingsPage" if kind == "page" else "settingsDetail": name})
    time.sleep(1.2)


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
        first = windows(pid)
        main_windows = {w[0] for w in first}
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
        for rule in (["pattern", "github.com/*/pull/*", "front"], ["add", "notion.so", "peek"], ["add", "figma.com", "window"]):
            try:
                sv.cmd({"do": "route", "args": rule})
            except RuntimeError as error:
                print("no route command in this build:", error)
        for live in (["on"], ["add", "Pull Requests", "https://github.com/pulls"]):
            try:
                sv.cmd({"do": "live", "args": live})
            except RuntimeError as error:
                print("no live command in this build:", error)
        pages = sv.cmd({"do": "settings"}).get("pages", [])
        places = [("page", p) for p in pages] + [("detail", d) for d in DETAILS] + [("find", "dark"), ("find", "bagel")]
        only = os.environ.get("SETTINGS_STAGE_ONLY")
        if only:
            wanted = set(only.split(","))
            places = [p for p in places if p[1] in wanted]
        names = [p[1] for p in places]
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme})
            time.sleep(0.8)
            for kind, name in places:
                go(kind, name)
                label = ("find-" if kind == "find" else "") + name
                shots += shoot(pid, number, out / f"{names.index(name):02d}-{label}-{theme}.png")
            for size, wide, tall, which in SMALL:
                sv.cmd({"do": "ui", "settingsSize": [wide, tall]})
                time.sleep(0.6)
                for name in which:
                    if only and name not in names: continue
                    go("detail" if name in DETAILS else "page", name)
                    shots += shoot(pid, number, out / f"{size}-{name}-{theme}.png")
            sv.cmd({"do": "ui", "settingsSize": [860, 640]})
            time.sleep(0.6)
        sv.cmd({"do": "ui", "settingsFind": ""})
        sv.cmd({"do": "ui", "settingsClose": True})
        time.sleep(0.5)
        print(f"{shots} shots in {out}")
    finally:
        sv.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())

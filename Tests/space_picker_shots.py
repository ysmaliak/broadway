#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("picker-shots")
ROOT = Path(__file__).resolve().parents[1]
SHOT = Path(os.environ.get("TMPDIR", "/tmp")) / f"space-picker-shot-{os.getpid()}"
VISITS = [
    ("https://github.com/acme/web/pull/12", 9),
    ("https://github.com/acme/api/pulls", 5),
    ("https://www.youtube.com/@numberphile", 6),
    ("https://linear.app/acme/issue/ACM-12", 4),
    ("https://vercel.com/acme/web/deployments", 3),
]


def windows(pid):
    out = subprocess.run([str(SHOT), str(pid), "list"], capture_output=True, text=True).stdout
    return [tuple(line.split("\t")) for line in out.splitlines() if len(line.split("\t")) == 3]


def space(action, **more):
    sv.cmd({"do": "space", "action": action, **more})
    time.sleep(0.6)


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "space-picker" / "after")
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SettingsShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, ai=True, **{"start.fresh": True, "live.on": True})
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
        space("look", colour="sky")
        live("add-page", "Subscriptions", "subscriptions", "https://www.youtube.com/feed/subscriptions")
        space("new", name="Work")
        space("icon", icon="briefcase")
        space("look", colours=["FB3A4D"], intensity=1.0)
        live("add-page", "Pull Requests", "pullRequests",
             "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
        live("add", "Acme Blog", "https://acme.example.com/feed.xml")
        space("new", name="Studio")
        space("icon", icon="paintpalette")
        space("look", colours=["FF89B3", "FF8A1F"], intensity=0.75)
        space("new", name="Notes")
        space("icon", icon="book")
        space("new", name="Travel")
        space("icon", icon="🌴")
        space("new", name="Home")
        space("icon", icon="🏡")
        space("look", colour="peach")
        for address, times in VISITS:
            for _ in range(times):
                sv.cmd({"do": "knowing", "action": "visit", "text": address})
        space("go", index=1)
        time.sleep(1)
        for rule in (["add", "github.com", "space", "Work"], ["default", "space", "Studio"]):
            try:
                sv.cmd({"do": "route", "args": rule})
            except RuntimeError as error:
                print("no route command in this build:", error)
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
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "ui", "settingsPage": "general"})
            sv.cmd({"do": "ui", "settingsSize": [860, 760]})
            time.sleep(0.8)
            for page in ["livefolders", "links"]:
                sv.cmd({"do": "ui", "settingsPage": page})
                time.sleep(1.2)
                for picked, name in [(0, "current"), (2, "work"), (3, "studio")][:1 if page == "links" else 3]:
                    sv.cmd({"do": "ui", "settingsSpace": picked})
                    time.sleep(0.8)
                    path = out / f"{page}-{name}-{theme}.png"
                    print(subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True).stdout.strip())
                    shots += path.exists()
                if page == "livefolders":
                    for picked, name in [(4, "neutral"), (5, "emoji"), (6, "emoji-colour")]:
                        sv.cmd({"do": "ui", "settingsSpace": picked})
                        time.sleep(0.8)
                        path = out / f"picker-{name}-{theme}.png"
                        print(subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True).stdout.strip())
                        shots += path.exists()
                    sv.cmd({"do": "ui", "settingsSpace": 2})
                    sv.cmd({"do": "ui", "settingsDetail": "livefolder"})
                    time.sleep(1.2)
                    path = out / f"livefolder-work-{theme}.png"
                    print(subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True).stdout.strip())
                    shots += path.exists()
                    sv.cmd({"do": "ui", "settingsPage": page})
                    time.sleep(0.8)
                sv.cmd({"do": "ui", "settingsSpace": 0})
            sv.cmd({"do": "ui", "settingsDetail": "linkrule"})
            time.sleep(1.2)
            path = out / f"linkrule-{theme}.png"
            print(subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True).stdout.strip())
            shots += path.exists()
        print(f"{shots} shots in {out}")
        sv.cmd({"do": "ui", "look": "dark"})
        sv.cmd({"do": "ui", "settingsPage": "livefolders"})
        sv.cmd({"do": "ui", "settingsSize": [860, 760]})
        sv.cmd({"do": "ui", "settingsSpace": 2})
        time.sleep(1.2)
        sv.cmd({"do": "ui", "settingsPress": "settings.live.add.vercel"})
        time.sleep(1.2)
        path = out / "livefolders-work-added-dark.png"
        print(subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True).stdout.strip())
        homes = {f["name"]: f.get("space", "?") for f in live().get("folders", [])}
        print("folders by space", homes)
        here = [row["name"] for row in sv.cmd({"do": "folders"}).get("rows", [])]
        space("go", index=2)
        time.sleep(1)
        there = [row["name"] for row in sv.cmd({"do": "folders"}).get("rows", [])]
        print("sidebar in Personal", here, "in Work", there)
        if "space" in next(iter(live().get("folders", [{}])), {}):
            assert homes.get("Deployments") == "Work", homes
            assert "Deployments" in there and "Deployments" not in here, (here, there)
            print("OK: Add with Work picked put the folder in Work")
    finally:
        sv.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("live-history")
SHOTS = Path(sys.argv[1]) if len(sys.argv) > 1 else None
OLD = [("https://github.com/acme/web/pull/12", 50), ("https://github.com/acme/api/pulls", 32),
       ("https://www.youtube.com/@numberphile", 19), ("https://linear.app/acme/issue/ACM-12", 4),
       ("https://linear.app/studio/issue/STU-3", 3)]
PERSONAL = [("https://www.youtube.com/@numberphile", 6), ("https://www.youtube.com/@veritasium", 2),
            ("https://github.com/mine/dotfiles", 2)]
WORK = [("https://github.com/acme/web/pull/12", 9), ("https://github.com/acme/api/pulls", 5),
        ("https://linear.app/acme/issue/ACM-12", 4), ("https://linear.app/studio/issue/STU-3", 1)]


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def visits(pairs, space=None):
    for address, times in pairs:
        sv.cmd({"do": "knowing", "action": "visit", "text": address, "times": times, **({"space": space} if space else {})})


def suggested():
    return live()["suggested"]


def shoot(name):
    if not SHOTS: return
    with tempfile.TemporaryDirectory() as folder:
        sv.cmd({"do": "picture", "path": f"{folder}/shot.png"})
        SHOTS.mkdir(parents=True, exist_ok=True)
        shutil.move(f"{folder}/shot.png", SHOTS / f"{name}.png")
    print("  shot ", SHOTS / f"{name}.png")


def pick(index):
    sv.cmd({"do": "ui", "settingsSpace": index})
    time.sleep(0.8)


def main():
    t = sv.T()
    sv.setup(spaces=True, **{"live.on": True, "start.fresh": True})
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 1100, "height": 1000, "steps": 1})
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        time.sleep(0.6)
        sv.cmd({"do": "space", "action": "icon", "icon": "briefcase"})
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(0.8)
        here = live()["space"]
        t.ok("the window is in its first space", here and here != "Work", here)

        print("visits kept before a visit carried its space")
        visits(OLD, space="none")
        now = suggested()
        t.ok(f"count for no space: nothing in {here}", now[here] == [], now)
        t.ok("and nothing in Work", now["Work"] == [], now)
        sv.cmd({"do": "ui", "look": "dark"})
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.2)
        sv.cmd({"do": "ui", "settingsPage": "livefolders"})
        time.sleep(1.2)
        shoot("old-visits-personal-dark")
        pick(2)
        shoot("old-visits-work-dark")
        pick(0)

        print("visits made in each space")
        visits(PERSONAL)
        visits(WORK, space="Work")
        time.sleep(0.6)
        now = suggested()
        t.ok(f"{here} has what was opened in {here}",
             now[here] == [["YouTube Subscriptions", "8 visits · @numberphile · @veritasium"],
                           ["GitHub Pull Requests", "2 visits · mine/dotfiles"]], now[here])
        t.ok("Work has what was opened in Work",
             now["Work"] == [["GitHub Pull Requests", "14 visits · acme/web · acme/api"],
                             ["Linear My Issues", "5 visits · acme · studio"]], now["Work"])
        for theme in ("dark", "light"):
            sv.cmd({"do": "ui", "look": theme})
            time.sleep(0.8)
            pick(1)
            shoot(f"personal-{theme}")
            pick(2)
            shoot(f"work-{theme}")
            t.ok(f"picking Work in Settings leaves the window in {here} ({theme})", live()["space"] == here, live()["space"])
            pick(0)
        sv.cmd({"do": "ui", "look": "dark"})

        print("a folder added for Work leaves the suggestion standing elsewhere")
        pick(2)
        sv.cmd({"do": "ui", "settingsPress": "settings.live.add.github"})
        time.sleep(1)
        now = suggested()
        homes = {f["name"]: f.get("space", "") for f in live()["folders"]}
        t.ok("Work no longer suggests GitHub", [row[0] for row in now["Work"]] == ["Linear My Issues"], now["Work"])
        t.ok(f"{here} still does, with its own count", ["GitHub Pull Requests", "2 visits · mine/dotfiles"] in now[here], now[here])
        time.sleep(5)
        shoot("work-added-dark")
        pick(0)
        print("  folders", homes)

        print("after a relaunch")
        time.sleep(2.5)
        sv.quit(); time.sleep(0.5); sv.launch()
        now = suggested()
        t.ok(f"{here} reads the same from the file",
             now[here] == [["YouTube Subscriptions", "8 visits · @numberphile · @veritasium"],
                           ["GitHub Pull Requests", "2 visits · mine/dotfiles"]], now[here])
        t.ok("and Work", now["Work"] == [["Linear My Issues", "5 visits · acme · studio"]], now["Work"])
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

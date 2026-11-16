#!/usr/bin/env python3
import json
import shutil
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("live-history-seed")
SHOTS = Path(sys.argv[1]) if len(sys.argv) > 1 else None
REFERENCE = datetime(2001, 1, 1, tzinfo=timezone.utc).timestamp()
YESTERDAY = time.time() - 86_400 - REFERENCE
OLD = [("https://github.com/acme/web/pull/12", 50), ("https://github.com/acme/api/pulls", 32),
       ("https://www.youtube.com/@numberphile", 19), ("https://linear.app/acme/issue/ACM-12", 4)]
WORK_TABS = ["https://github.com/acme/web/pull/7", "https://linear.app/acme/issue/ACM-1"]
PERSONAL_TABS = ["https://www.youtube.com/@veritasium", "https://linear.app/studio/issue/STU-3"]


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


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


def row(addresses):
    return {"tabs": [{"url": a, "title": a.split("/")[2]} for a in addresses], "active": -1}


def write_old_world():
    support = Path(sv.SUPPORT)
    spaces = json.load(open(support / "spaces.json"))
    work = next(s["id"] for s in spaces if s["name"] == "Work")
    json.dump(row(PERSONAL_TABS), open(support / "session.json", "w"))
    json.dump(row(WORK_TABS), open(support / f"session-{work}.json", "w"))
    old = [{"url": a, "key": a, "title": "Page", "count": n, "last": YESTERDAY} for a, n in OLD]
    json.dump(old, open(support / "history.json", "w"))


def main():
    t = sv.T()
    sv.setup(spaces=True, **{"live.on": True})
    sv.launch()
    try:
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        time.sleep(0.6)
        sv.cmd({"do": "space", "action": "icon", "icon": "briefcase"})
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1)
        sv.quit(); time.sleep(0.5)

        print("a history.json from before visits carried a space, and two spaces")
        write_old_world()
        sv.launch()
        sv.cmd({"do": "resize", "width": 1100, "height": 1000, "steps": 1})
        here = live()["space"]
        t.ok("the window is in its first space", here and here != "Work", here)
        now = live()["suggested"]
        t.ok("GitHub, whose tabs are in Work, is Work's with its old count",
             now["Work"] == [["GitHub Pull Requests", "82 visits · acme/web · acme/api"]], now["Work"])
        t.ok(f"YouTube, whose tab is in {here}, is {here}'s",
             now[here] == [["YouTube Subscriptions", "19 visits · @numberphile"]], now[here])
        t.ok("Linear, in both spaces, is in neither",
             all("Linear" not in r[0] for r in now["Work"] + now[here]), now)
        time.sleep(2.5)
        saved = json.load(open(Path(sv.SUPPORT) / "history.json"))
        t.ok("the file says it was done", all(v.get("placed") is True for v in saved), saved)

        for theme in ("dark", "light"):
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "ui", "settings": True})
            time.sleep(1.2)
            sv.cmd({"do": "ui", "settingsPage": "livefolders"})
            time.sleep(1.2)
            pick(1)
            shoot(f"seed-personal-{theme}")
            pick(2)
            shoot(f"seed-work-{theme}")
            pick(0)

        print("after a relaunch, with Linear now only in Work")
        sv.quit(); time.sleep(0.5)
        support = Path(sv.SUPPORT)
        json.dump(row(["https://www.youtube.com/@veritasium"]), open(support / "session.json", "w"))
        sv.launch()
        again = live()["suggested"]
        t.ok("Work reads the same", again["Work"] == now["Work"], again["Work"])
        t.ok(f"{here} reads the same", again[here] == now[here], again[here])
        t.ok("Linear is not placed a second time", all("Linear" not in r[0] for r in again["Work"] + again[here]), again)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

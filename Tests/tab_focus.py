#!/usr/bin/env python3
"""Tab moves through the internal pages and Settings, in a test copy.

Build first (`./build.sh`), then `python3 Tests/tab_focus.py`. A test copy in
a world of its own, shown behind the app in front (SEARCH_SHOWN, so Settings
is its own window), never brought forward. Full Keyboard Access is turned on
for the copy alone (bench `keyloop fka`), never for the Mac. From each page's
first field, Tab is pressed through the window's own key view loop
(`selectNextKeyView`) and every stop is listed.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-focus")

PAGES = [("bookmarks", "KitSearchField"), ("history", "KitSearchField"), ("passwords", "KitSearchField"), ("import", None)]


def launch():
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, **{"start.fresh": True})
        launch()
        sv.page("a")
        for page, start in PAGES:
            sv.cmd({"do": "ui", "lead": page}); time.sleep(1.0)
            r = sv.cmd({"do": "keyloop", "fka": True, "start": start or "", "steps": 14})
            steps = r["steps"]
            print(f"  {page:10} {' → '.join(steps)}")
            if not start:
                t.ok(f"{page}: Tab reaches the page, not only the column's doors",
                     not set(steps) <= {"FetchDoorView", "ReloadDoorView", "", "NSWindow"}, steps)
            if start:
                moved = [s for s in steps[1:] if s and s != start]
                t.ok(f"{page}: Tab leaves the search field for the page's own controls",
                     any(s.startswith(("Kit", "NSOutline", "NSTable", "Bookmark", "Recall", "Password", "PagePill")) for s in moved), steps)
        sv.cmd({"do": "ui", "settings": True}); time.sleep(1.5)
        for page in ["general", "appearance", "privacy"]:
            sv.cmd({"do": "ui", "settingsPage": page}); time.sleep(0.8)
            r = sv.cmd({"do": "keyloop", "fka": True, "settings": True, "start": "NSSearchField", "steps": 24})
            print(f"  settings:{page:9} {' → '.join(r['steps'])}")
            t.ok(f"Settings {page}: Tab reaches its switches", "KitSwitch" in r["steps"], r["steps"])
        r = sv.cmd({"do": "keyloop", "fka": False, "settings": True, "start": "NSSearchField", "steps": 8})
        t.ok("Full Keyboard Access off: Tab skips the switches", "KitSwitch" not in r["steps"], r["steps"])
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

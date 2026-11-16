#!/usr/bin/env python3
"""Downloads opened with the sidebar folded, checked in a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/folded_downloads.py`. A folded window has two downloads
buttons: the sidebar's, and the one on the card that comes out over the
page. While the downloads were open each wrote its own place to the model
in layout, each write marked the other for layout, and the window never
settled, which is what AppKit ends an app for (13 November 2026). With the
downloads open the window has to settle in a few passes: folded or not,
the card out or in, opened from the card's own button, and folded or
unfolded while they are open.
"""

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as t

t.use("folded-downloads")


def main():
    failed = []

    def check(name, ok, detail=""):
        print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""))
        if not ok:
            failed.append(name)

    def watch():
        t.cmd({"do": "layoutwatch", "action": "clear"})

    def settled(state, open_=True):
        time.sleep(1.5)
        check(f"{state}: the app is still up", bool(t.pids()))
        reports = [r for r in t.cmd({"do": "layoutwatch"})["reports"] if r["looped"] or r["views"] >= 12]
        check(f"{state}: the window settles in a few passes", reports == [], "; ".join(r["text"][:700] for r in reports))
        check(f"{state}: the downloads are {'open' if open_ else 'shut'}", t.cmd({"do": "probe"}).get("downloadsOpen") is open_)

    def doors():
        return t.cmd({"do": "layoutwatch", "action": "doors"})["doors"]

    def shut():
        t.cmd({"do": "ui", "recentdownloads": False})
        time.sleep(0.6)

    def opened(state):
        watch()
        t.cmd({"do": "ui", "recentdownloads": True})
        settled(state)
        shut()

    t.setup()
    t.launch()
    try:
        t.page("long")
        t.cmd({"do": "ui", "downloadsbutton": True})
        time.sleep(0.5)
        opened("sidebar shown")
        t.cmd({"do": "ui", "toggleFold": True})
        time.sleep(0.8)
        check("a folded window has two downloads buttons", sorted(d["card"] for d in doors()) == [False, True], str(doors()))
        opened("sidebar folded")
        t.cmd({"do": "columnscroll", "peek": True})
        time.sleep(0.5)
        opened("sidebar folded, its card out")

        watch()
        t.cmd({"do": "layoutwatch", "action": "doors", "press": "card"})
        settled("the card's button pressed")
        check("the downloads hang from the card's button", [d["card"] for d in doors() if d["anchor"]] == [True], str(doors()))
        watch()
        t.cmd({"do": "ui", "toggleFold": True})
        settled("unfolded with the downloads open")
        shut()
        watch()
        t.cmd({"do": "ui", "recentdownloads": True})
        settled("opened again with the card gone")
        check("the sidebar's button is the one left, and has them", [(d["card"], d["anchor"]) for d in doors()] == [(False, True)], str(doors()))
        watch()
        t.cmd({"do": "ui", "toggleFold": True})
        settled("folded again with the downloads open")
        shut()
        t.cmd({"do": "columnscroll", "peek": False})
        time.sleep(0.5)
        opened("sidebar shown again")

        log = Path(t.SUPPORT, "crash.log")
        text = log.read_text() if log.exists() else ""
        check("crash.log has no layout loop", "LayoutLoop:" not in text, text[:900])
    finally:
        t.quit()
        t.wipe()
    if failed:
        sys.exit(f"{len(failed)} failed: {failed}")
    print("folded downloads: all passed")


if __name__ == "__main__":
    main()

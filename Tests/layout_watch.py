#!/usr/bin/env python3
"""The layout watch, checked in a hidden probe.

Build first (`./build.sh` or `./build.sh debug`), then run
`python3 Tests/layout_watch.py`. A window whose two views mark each other
as needing layout on every pass is what AppKit ends an app for since
macOS 14. With the watch on, AppKit cuts the loop instead, the app goes
on, the window still lays out afterwards, and crash.log names the views.
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as t

t.use("layout-watch")


def main():
    failed = []

    def check(name, ok, detail=""):
        print(("ok   " if ok else "FAIL ") + name + (f": {detail}" if detail and not ok else ""))
        if not ok:
            failed.append(name)

    t.setup()
    t.launch()
    try:
        for views in (0, 20):
            answer = t.cmd({"do": "layoutwatch", "action": "loop", "views": views})
            reports = [r for r in answer["reports"] if r["looped"]]
            check(f"a loop in a window of {views + 3} views is cut, not fatal", t.cmd({"do": "alive"}) is not None)
            check(f"the loop is reported ({views + 3} views)", len(reports) >= 1, str(answer["reports"]))
            if reports:
                report = reports[0]
                check("the report says AppKit's limit was reached", report["passes"] == report["views"] + 1, str(report))
                check("the report names the dirty views", any("Ping" in name or "Pong" in name for names in report["dirty"] for name in names), str(report["dirty"]))
                check("the report names who asked", any("Ping" in line and "Pong" in line for line in report["asked"]) or any("layout" in line for line in report["asked"]), str(report["asked"]))
                check("the report was written before the limit", report["written"], str(report))
            check("the window lays out again after the loop", answer["laidOutAfter"] >= 1, str(answer))
        log = Path(t.SUPPORT, "crash.log")
        text = log.read_text() if log.exists() else ""
        entries = text.split("LayoutLoop:")[1:]
        check("crash.log has the loops and nothing else", len(entries) >= 2 and all("asked" in e and "Ping" in e for e in entries), text[:900])
        kept = t.cmd({"do": "layoutwatch", "action": "fill", "count": 100})["kept"]
        answer = t.cmd({"do": "layoutwatch", "action": "loop", "views": 20})
        check("with its list of reports full, a loop is still reported", any(r["looped"] for r in answer["reports"]), f"kept {kept}: {answer['reports']}")
        check("and the window still lays out again", answer["laidOutAfter"] >= 1, str(answer))
        check("the list keeps the newest", len(t.cmd({"do": "layoutwatch"})["reports"]) == kept)
        t.cmd({"do": "layoutwatch", "action": "clear"})
        check("nothing else looped", t.cmd({"do": "layoutwatch"})["reports"] == [])
    finally:
        t.quit()
        t.wipe()
    if failed:
        sys.exit(f"{len(failed)} failed: {failed}")
    print("layout watch: all passed")


if __name__ == "__main__":
    main()

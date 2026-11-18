#!/usr/bin/env python3
"""The column's scroll bar: in the column's own inset, clear of the cards, and whole.

Build first (`./build.sh`), then `python3 Tests/column_scroller.py [OUT]`. A test
copy in a world of its own, its window put below the desktop where
`screencapture -l` still pictures it alone, with more rows than the column
holds. Twice: overlay scroll bars (flashed through the bench) and legacy
ones asked for (the test process started with -AppleShowScrollBars Always,
which reaches no other app), which the column answers with its own overlay
bar all the same. Each time, dark and light, cards on and off, the
sidebar on the right, and stacked spaces.

The column's scroll view spans the sidebar's whole width and its rows sit
in content margins, so the scroll bar's knob lies in the right-hand inset,
past every row's card, and inside the sidebar, not cut at its edge.
BROADWAY_APP picks another build, for before and after.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("column-scroller")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/scroller")
WIDTH, HEIGHT = 1000, 620
WINDOW = [0]
t = sv.T()


def launch(legacy):
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    extra = ["--args", "-AppleShowScrollBars", "Always"] if legacy else []
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", sv.APP, *extra])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})["window"]
    time.sleep(0.8)


def shoot(name):
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    return path.exists()


def col(**f): return sv.cmd({"do": "columnscroll", **f})


def check(label, legacy, stacked=False):
    col(wheel=120)
    time.sleep(0.3)
    c = col(flash=True) if not legacy else col()
    shoot(label)
    bar = c.get("scroller")
    if not bar:
        t.ok(f"{label}: the column has a scroll bar to look at", False, sorted(c))
        return
    t.ok(f"{label}: the column scrolls", c.get("scrolls") is True, c.get("measured"))
    knob, frame, view = bar["knob"], bar["frame"], bar["view"]
    t.ok(f"{label}: the scroll bar is overlay{', legacy ones asked for' if legacy else ''}", bar["legacy"] == 0, bar)
    rows = sv.cmd({"do": "rowframes"})["rows"].values()
    top, bottom = knob[1], knob[1] + knob[3]
    beside = [r for r in rows if r[1] < bottom and r[1] + r[3] > top and r[0] < view[1] and r[0] + r[2] > view[0]]
    cards = max((r[0] + r[2] for r in beside), default=None)
    t.ok(f"{label}: the knob lies past every row's card beside it", cards is not None and knob[0] >= cards - 0.5,
         (knob, cards, len(beside)))
    t.ok(f"{label}: the knob lies inside the sidebar, not cut at its edge", knob[0] + knob[2] <= view[1] + 0.5,
         (knob, view))
    if not stacked:
        t.ok(f"{label}: the scroll view spans the sidebar's whole width",
             abs((view[1] - view[0]) - sv.cmd({"do": "probe"}).get("columnWidth", 0)) <= 1, (view, frame))


def run(legacy):
    style = "legacy" if legacy else "overlay"
    sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False})
    launch(legacy)
    sv.cmd({"do": "window"})
    stage(True)
    for i in range(30):
        sv.page(f"Row {i:02d}") if i % 10 == 0 else sv.sp("open", url=f"{sv.BASE}/Row-{i:02d}")
    sv.sp("select", id=sv.sp("state")["tabs"][3]["id"])
    time.sleep(1)
    for dark in (True, False):
        stage(dark)
        check(f"{style}-cards-{'dark' if dark else 'light'}", legacy)
    stage(True)
    sv.cmd({"do": "ui", "cards": False})
    time.sleep(0.8)
    check(f"{style}-cards-off-dark", legacy)
    sv.cmd({"do": "ui", "cards": True})
    sv.cmd({"do": "ui", "side": "right"})
    time.sleep(1)
    check(f"{style}-right-dark", legacy)
    sv.cmd({"do": "ui", "side": "left"})
    sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
    time.sleep(1.2)
    check(f"{style}-stacked-dark", legacy, stacked=True)
    sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "side"})
    sv.quit()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        run(False)
        run(True)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

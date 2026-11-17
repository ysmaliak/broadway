#!/usr/bin/env python3
"""A tab dragged out of its window, in a hidden probe with two windows.

Build first (`./build.sh`), then `python3 Tests/tab_tear_off.py` from a
worktree. It uses the split suite's harness: started hidden, in a world of
its own, everything removed afterwards. The drag is the sidebar's own
gesture, driven by `bench tear`, so the real pointer never moves.

Checked here: a tab let go over nothing opens a new window, a tab let go over
the other window's sidebar lands where the line was shown and is in front
there, a tab brought back inside before letting go stays where it was, and no
page loads again. One picture of the probe's own window is taken by its id
while a tab is away, under .context/ in this checkout.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-tear-off")
SHOT = sv.ROOT / ".context" / "tab-tear-off-away.png"


def tear(action, **more):
    return sv.cmd({"do": "tear", "action": action, **more})


def windows():
    return sv.cmd({"do": "windows"})["windows"]


def tabs(n):
    return [x["id"] for x in sv.cmd({"do": "tabs", "window": n})["tabs"]]


def active(n):
    return [x["id"] for x in sv.cmd({"do": "tabs", "window": n})["tabs"] if x.get("active")]


def rows(n):
    return sv.cmd({"do": "rowframes", "window": n})["rows"]


def frame(n):
    return sv.cmd({"do": "windows", "action": "frame", "n": n, "frame": FRAMES[n - 1]})


FRAMES = [[40, 120, 820, 640], [960, 120, 820, 640]]


def screen_point(n, x, y):
    left, bottom, _, height = FRAMES[n - 1]
    return [left + x, bottom + height - y]


def ev(n, id, js):
    return sv.cmd({"do": "eval", "id": id, "js": js, "window": n}).get("value")


def mark(n, id):
    return ev(n, id, "window.keptMark = 7; 7")


def kept(n, id):
    return ev(n, id, "window.keptMark || 0") == 7


def open_in(n, name):
    a = sv.cmd({"do": "split", "action": "open", "url": f"{sv.BASE}/{name}", "window": n})["resultID"]
    time.sleep(0.7)
    return a


def shoot(t):
    number = next((w["number"] for w in sv.cmd({"do": "probe"})["windows"]
                   if w["kind"] != "NSPanel" and w["frame"][:2] == FRAMES[0][:2]), None)
    if number is None:
        t.ok("the probe's window was found for its picture", False)
        return
    SHOT.parent.mkdir(exist_ok=True)
    taken = subprocess.run(["screencapture", "-x", "-o", "-l", str(number), str(SHOT)], capture_output=True, text=True)
    if taken.returncode == 0 and SHOT.exists() and SHOT.stat().st_size > 0:
        print(f"  picture of window {number} while away: {SHOT}")
    else:
        print(f"  the capture of window {number} was refused: {taken.stderr.strip() or taken.returncode}")


def case_tear(t):
    """Two windows: out to a new window, into the other sidebar, and back inside"""
    sv.setup()
    sv.launch()
    a = [open_in(1, "a"), open_in(1, "b"), open_in(1, "c"), open_in(1, "d")]
    sv.cmd({"do": "windows", "action": "new"})
    time.sleep(1)
    b = [open_in(2, "e"), open_in(2, "f"), open_in(2, "g")]
    frame(1)
    frame(2)
    time.sleep(1)
    for id in a:
        mark(1, id)
    for id in b:
        mark(2, id)
    t.ok("two windows, each with its pages", len(windows()) == 2 and all(x in tabs(1) for x in a) and all(x in tabs(2) for x in b),
         (tabs(1), tabs(2)))

    tear("begin", id=a[1])
    said = tear("move", at=screen_point(1, 900, 300))
    t.ok("past the window's edge the tab is away", said["away"], said)
    t.ok("…its picture follows the pointer", said["picture"], said)
    t.ok("…and nothing of Broadway's would take it but a new window", said.get("takes") == "new", said)
    shoot(t)
    said = tear("letgo")
    time.sleep(1.2)
    now = windows()
    t.ok("let go over nothing, a new window holds the tab", len(now) == 3 and a[1] in tabs(3) and a[1] not in tabs(1), now)
    t.ok("…in front there", active(3) == [a[1]], active(3))
    t.ok("…and its page did not load again", kept(3, a[1]))
    frame(1)
    frame(2)

    tear("begin", id=a[2])
    second = rows(2)[b[1]]
    said = tear("move", at=screen_point(2, second[0] + 40, second[1] + second[3] * 0.2))
    t.ok("over the other window's sidebar it is away", said["away"], said)
    t.ok("…that window would take it", said.get("window") == 2, said)
    t.ok("…between its first two rows, where a line shows", said.get("index") == 1 and said.get("line"), said)
    said = tear("letgo")
    time.sleep(1.2)
    t.ok("let go there, it is the other window's second tab", tabs(2)[:4] == [b[0], a[2], b[1], b[2]], tabs(2))
    t.ok("…in front there", active(2) == [a[2]], active(2))
    t.ok("…gone from the window it left", a[2] not in tabs(1), tabs(1))
    t.ok("…and its page did not load again", kept(2, a[2]))

    before = len(windows())
    order = tabs(1)
    tear("begin", id=a[3])
    said = tear("move", at=screen_point(1, 900, 300))
    t.ok("out once more, the tab is away", said["away"] and said["picture"], said)
    said = tear("move", at=screen_point(1, 120, 200))
    t.ok("back inside, it is not away and the picture is gone", not said["away"] and not said["picture"], said)
    tear("letgo")
    time.sleep(1)
    t.ok("let go inside, it stays in its window", a[3] in tabs(1) and len(windows()) == before, (tabs(1), windows()))
    t.ok("…as the reorder it was", sorted(tabs(1)) == sorted(order), (order, tabs(1)))
    t.ok("no page loaded again", kept(1, a[0]) and kept(1, a[3]) and kept(3, a[1]) and all(kept(2, x) for x in b + [a[2]]))


def main():
    t = sv.T()
    for case in [case_tear]:
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

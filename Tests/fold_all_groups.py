#!/usr/bin/env python3
"""Shut All Folders and Open All Folders, in the View menu (⌥⌘[ and ⌥⌘])
and the space's menu, as in Arc.

Build first (`./build.sh`), then `python3 Tests/fold_all_groups.py`. A
hidden probe with two groups of two pages and a loose page; the menus'
own items are performed, as a click on them would be. Nothing here makes,
shows or brings forward a window, and no menu is popped up.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-va2-fold")


def group(**f): return sv.cmd({"do": "group", **f})


def folded(g): return [x["collapsed"] for x in g["groups"]]


def items(g, where): return {x["title"]: x for x in g[where]}


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True, "start.fresh": False, "spaces": True})
        sv.launch()
        g = group()
        t.ok("no groups: nothing in the space's menu", g["spaceItems"] == [], g["spaceItems"])
        a, b, c, d = (sv.page(n) for n in ("a", "b", "c", "d"))
        group(id=a, new=True, name="One"); group(id=b, name="One")
        group(id=c, new=True, name="Two"); group(id=d, name="Two")
        # Opened beside a page of a group, a page joins it: taken out.
        group(id=sv.page("loose"), name="none")
        g = group()
        t.ok("two open groups", folded(g) == [False, False], g)
        v = items(g, "viewItems")
        t.ok("View has both items", set(v) == {"Shut All Folders", "Open All Folders"}, v)
        # On the keys of ⌘[ and ⌘] (Back, Forward), whatever this keyboard
        # types there: ^ and $ on a French one.
        back, forward = g["brackets"]
        t.ok("Shut All Folders is ⌥ and Back's ⌘[", back and v.get("Shut All Folders", {}).get("key") == back
             and v["Shut All Folders"]["option"] and v["Shut All Folders"]["command"], (v, g["brackets"]))
        t.ok("Open All Folders is ⌥ and Forward's ⌘]", forward and v.get("Open All Folders", {}).get("key") == forward
             and v["Open All Folders"]["option"], (v, g["brackets"]))
        s = items(g, "spaceItems")
        t.ok("the space's menu offers Shut All Folders alone while all are open",
             s.get("Shut All Folders", {}).get("enabled") is True and "Open All Folders" not in s, s)

        g = group(all="fold", via="view"); time.sleep(0.3)
        t.ok("View › Shut All Folders folds both", folded(group()) == [True, True], g)
        s = items(group(), "spaceItems")
        t.ok("then Open All Folders alone", "Shut All Folders" not in s and s.get("Open All Folders", {}).get("enabled") is True, s)

        group(all="unfold", via="space"); time.sleep(0.3)
        t.ok("the space's Open All Folders opens both", folded(group()) == [False, False])

        group(name="One", fold=True)
        group(all="fold", via="space"); time.sleep(0.3)
        g = group()
        t.ok("one folded by hand, Fold All folds the other too", folded(g) == [True, True], g)
        t.ok("each keeps its two pages", [len(x["tabs"]) for x in g["groups"]] == [2, 2], g)
        group(all="unfold", via="view"); time.sleep(0.3)
        t.ok("View › Open All Folders opens both", folded(group()) == [False, False])

        # Kept: the file says so after a relaunch.
        group(all="fold"); time.sleep(0.5)
        sv.quit(); time.sleep(1); sv.launch(); time.sleep(1)
        t.ok("folded all, still folded after a relaunch", folded(group()) == [True, True], group())
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

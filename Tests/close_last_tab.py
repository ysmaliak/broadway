#!/usr/bin/env python3
"""Closing the last tab that isn't a pin (Browser.close, #537), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/close_last_tab.py` from a
worktree. The settings cut fixed "Leave a new tab when the last tab closes"
off: with only pins left beside it, a pin is picked. With another ordinary
tab left, the neighbour is picked.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

# Its own world, apart from the split suite's in this checkout (see use()).
sv.use("close-last-tab")


def name(st, id):
    return next((x["url"].rsplit("/", 1)[-1] for x in st["tabs"] if x["id"] == id), None)


def active(st):
    return next((x for x in st["tabs"] if x["id"] == st["activeID"]), None)


def loose(st):
    return [x["id"] for x in st["tabs"] if x["id"] not in st["pins"]]


def only(*keep):
    """Every tab that isn't a pin closed, except those kept."""
    for id in loose(sv.sp("state")):
        if id not in keep:
            sv.sp("close", id=id)


def main():
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        d = sv.page("d"); e = sv.page("e")
        only(d, e)
        sv.cmd({"do": "select", "id": d})
        st = sv.sp("close", id=d)
        t.ok("with another tab left, that one is picked", st["activeID"] == e, st)
        t.ok("and no new tab is made for it", loose(st) == [e], st["tabs"])

        a = sv.page("a"); sv.cmd({"do": "pin", "id": a})
        b = sv.page("b")
        only(b)
        st = sv.sp("close", id=b)
        t.ok("only pins left: the pin is picked", st["activeID"] == a, st)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

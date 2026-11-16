#!/usr/bin/env python3
"""Tab keys, picked tabs and link copies, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/tab_keys.py`. It uses the
split suite's harness in a world of its own: started hidden, no window made
or shown, everything removed afterwards. Keys are pressed through the app's
event queue (`press`), the column's ⌘-clicks are `split pick`, and the rest
goes through bench `ui` with `tabKeys`: the tab menu's actions, the copies,
and what a test run's own pasteboard holds, never the Mac's clipboard.
"""
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-keys")

t = sv.T()
UP, DOWN = "", ""


def state(): return sv.sp("state")
def pick(*ids): return sv.sp("pick", ids=list(ids))
def keys(**ask): return sv.cmd({"do": "ui", "tabKeys": ask})
def press(code, chars, mods): sv.cmd({"do": "press", "code": code, "chars": chars, "mods": mods}); time.sleep(0.5)
def names(st): return [x["url"].rsplit("/", 1)[-1] for x in st["tabs"]]


def tabs_menu():
    return sv.cmd({"do": "menus"})["menus"].get("Tabs", [])


def case_pick_all_and_send(t):
    """⇧⌘A picks the list, ⌃⇧2 sends the picked tabs to space 2"""
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": False}); sv.launch()
    first = state()["spaceID"]
    second = sv.sp("space", spaceAction="new", name="Two")["spaceID"]
    sv.sp("space", spaceAction="go", spaceID=first)
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d")
    blank = [x["id"] for x in state()["tabs"] if x["id"] not in (a, b, c, d)]
    for x in blank: sv.sp("close", id=x)
    sv.cmd({"do": "pin", "id": a}); time.sleep(0.3)
    sv.sp("select", id=b)

    press(0, "a", ["shift", "cmd"])
    st = state()
    t.ok("⇧⌘A: every tab in the list, not the pin", sorted(st["selected"]) == sorted([b, c, d]), (st["selected"], names(st)))
    menu = tabs_menu()
    t.ok("Tabs menu: Pick All Tabs", "Pick All Tabs" in menu, menu)
    t.ok("Tabs menu: the count on Pin, Duplicate and the copies",
         all(x in menu for x in ["Pin 3 Tabs", "Duplicate 3 Tabs", "Copy 3 Addresses", "Copy 3 as Markdown Links", "Copy 3 as Rich Links"]), menu)
    t.ok("Tabs menu: Move 3 Tabs to Space", "Move 3 Tabs to Space" in menu, menu)
    press(0, "a", ["shift", "cmd"])
    t.ok("⇧⌘A again: nothing picked", state()["selected"] == [], state()["selected"])

    sv.sp("select", id=b)
    pick(b, d)
    press(19, "2", ["ctrl", "shift"])
    said = keys()["announcement"]
    st = state()
    ids = sv.order(st)
    t.ok("⌃⇧2: b and d leave", b not in ids and d not in ids, names(st))
    t.ok("⌃⇧2: the pin and c stay, and the window stays here", a in ids and c in ids and st["spaceID"] == first, (names(st), st["spaceID"]))
    t.ok("⌃⇧2: on c now, not on a new tab", st["activeID"] == c, st["activeID"])
    report = keys()
    there = [u.rsplit("/", 1)[-1] for u in report["parked"].get(second, [])]
    t.ok("⌃⇧2: b and d are in space 2, in order", there[-2:] == ["b", "d"], there)
    t.ok("⌃⇧2: one line about it", said == "Moved 2 tabs to Two", said)

    press(18, "1", ["ctrl", "shift"])
    t.ok("⌃⇧1 in space 1: nothing moves", sorted(sv.order(state())) == sorted([a, c]), names(state()))
    sv.sp("space", spaceAction="go", spaceID=second)
    t.ok("space 2 opens with b and d", [n for n in names(state()) if n in ("b", "d")] == ["b", "d"], names(state()))


def case_move_keys(t):
    """⌥⇧⌘↑/↓ moves the front tab within its block, and the key can be moved"""
    sv.setup(sidebar=True, **{"tabs.groups": True})
    overrides = {"tabs.moveDown": {"key": {"key": "down", "command": False, "option": True, "control": True, "shift": False}}}
    subprocess.run(["defaults", "write", sv.SUITE, "shortcuts", "-data", json.dumps(overrides).encode().hex()], check=True)
    sv.launch()
    p = sv.page("p"); a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); f1 = sv.page("f1"); f2 = sv.page("f2")
    for x in [x["id"] for x in state()["tabs"] if x["id"] not in (p, a, b, c, f1, f2)]: sv.sp("close", id=x)
    sv.cmd({"do": "pin", "id": p}); time.sleep(0.3)
    sv.cmd({"do": "group", "id": f1, "new": True, "name": "Work"}); sv.cmd({"do": "group", "id": f2, "name": "Work"}); time.sleep(0.4)
    loose = lambda: [n for n in names(state()) if n in ("a", "b", "c")]
    folder = lambda: [n for n in names(state()) if n in ("f1", "f2")]

    sv.sp("select", id=c)
    press(126, UP, ["opt", "shift", "cmd"])
    t.ok("⌥⇧⌘↑: c goes above b", loose() == ["a", "c", "b"], names(state()))
    press(126, UP, ["opt", "shift", "cmd"]); press(126, UP, ["opt", "shift", "cmd"])
    t.ok("⌥⇧⌘↑ at the top of the list: stays, not into the pins", loose() == ["c", "a", "b"] and names(state())[0] == "p", names(state()))
    press(125, DOWN, ["opt", "shift", "cmd"])
    t.ok("⌥⇧⌘↓ given away: the old key does nothing", loose() == ["c", "a", "b"], names(state()))
    press(125, DOWN, ["opt", "ctrl"])
    t.ok("⌃⌥↓, its new key, moves it down", loose() == ["a", "c", "b"], names(state()))

    sv.sp("select", id=f1)
    press(125, DOWN, ["opt", "ctrl"])
    t.ok("in a folder: f1 goes below f2", folder() == ["f2", "f1"], names(state()))
    press(125, DOWN, ["opt", "ctrl"])
    st = state()
    t.ok("at the folder's end: it stays in the folder", folder() == ["f2", "f1"] and next(x for x in keys()["tabs"] if x["id"] == f1)["group"] == "Work", names(st))
    menu = tabs_menu()
    t.ok("Tabs menu: Move Tab Up and Move Tab Down", "Move Tab Up" in menu and "Move Tab Down" in menu, menu)


def case_copies(t):
    """copies of picked tabs, a folder and the page, on the test run's own pasteboard"""
    sv.setup(sidebar=True, **{"tabs.groups": True}); sv.launch()
    a = sv.page("a?utm_source=news&id=1"); b = sv.page("b"); c = sv.page("c?utm_medium=x&ref=keep")
    for x in [x["id"] for x in state()["tabs"] if x["id"] not in (a, b, c)]: sv.sp("close", id=x)
    sv.sp("select", id=a)
    pick(a, c)
    board = keys(clearBoard=True, copy="rich")["board"]
    t.ok("rich: HTML, RTF and plain text", all(k in board["types"] for k in ["public.html", "public.rtf", "public.utf8-plain-text"]), board["types"])
    t.ok("rich: plain is the cleaned addresses, in column order",
         board["string"] == f"{sv.BASE}/a?id=1\n{sv.BASE}/c?ref=keep", board["string"])
    t.ok("rich: one anchor per tab", board["html"].count("<a href=") == 2 and f'href="{sv.BASE}/a?id=1"' in board["html"], board["html"])
    board = keys(copy="markdown")["board"]
    lines = board["string"].splitlines()
    t.ok("markdown: one link per line, cleaned, in order",
         len(lines) == 2 and lines[0].startswith("[a?") and lines[0].endswith(f"]({sv.BASE}/a?id=1)") and lines[1].endswith(f"]({sv.BASE}/c?ref=keep)"), lines)
    board = keys(copy="address")["board"]
    t.ok("address: exactly as they are", board["string"] == f"{sv.BASE}/a?utm_source=news&id=1\n{sv.BASE}/c?utm_medium=x&ref=keep", board["string"])
    board = keys(copy="rich", page=True)["board"]
    t.ok("page menu: only the page", board["string"] == f"{sv.BASE}/a?id=1", board["string"])

    sv.cmd({"do": "group", "id": b, "new": True, "name": "Reading"}); sv.cmd({"do": "group", "id": c, "name": "Reading"}); time.sleep(0.4)
    board = keys(copy="markdown", folder="Reading")["board"]
    t.ok("folder: all its tabs", len(board["string"].splitlines()) == 2 and "/b)" in board["string"] and "/c?ref=keep)" in board["string"], board["string"])


def case_menu_actions(t):
    """the tab menu's Pin, Duplicate and Move to Folder on every picked tab"""
    sv.setup(sidebar=True, **{"tabs.groups": True}); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    for x in [x["id"] for x in state()["tabs"] if x["id"] not in (a, b, c)]: sv.sp("close", id=x)
    sv.sp("select", id=a)
    pick(a, c)
    r = keys(menu="duplicate", id=c)
    t.ok("Duplicate 2 Tabs: two more", sorted(names(state())) == ["a", "a", "b", "c", "c"], names(state()))
    t.ok("Duplicate: still on a", r["active"] == a, r["active"])
    sv.sp("select", id=a)
    pick(a, b)
    r = keys(menu="pin", id=b)
    pinned = [x["url"].rsplit("/", 1)[-1] for x in r["tabs"] if x["pinned"]]
    t.ok("Pin 2 Tabs: both pinned, in order", pinned == ["a", "b"], pinned)
    r = keys(menu="pin", id=a)
    t.ok("Unpin 2 Tabs: neither", not any(x["pinned"] for x in r["tabs"]), r["tabs"])
    sv.cmd({"do": "group", "id": c, "new": True, "name": "Box"}); time.sleep(0.3)
    sv.sp("select", id=a)
    pick(a, b)
    r = keys(menu="folder", id=a, folder="Box")
    inside = sorted(x["url"].rsplit("/", 1)[-1] for x in r["tabs"] if x["group"] == "Box")
    t.ok("Move 2 Tabs to Folder: both in Box", inside == ["a", "b", "c"], inside)


def main():
    for case in [case_pick_all_and_send, case_move_keys, case_copies, case_menu_actions]:
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

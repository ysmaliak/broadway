#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("menu-shapes-" + uuid.uuid4().hex[:6])


def opened(**ask):
    for _ in range(4):
        try:
            reply = sv.cmd({"do": "ctxmenu", "hold": 3, **ask})
        except RuntimeError:
            time.sleep(0.5)
            continue
        try:
            sv.cmd({"do": "ctxmenu", "action": "close"})
        except RuntimeError:
            pass
        time.sleep(0.4)
        return reply["items"]
    return []


def rows(items):
    return [i for i in items if not i.get("separator")]


def titles(items):
    return [i["title"] for i in rows(items)]


def find(items, title):
    return next((i for i in rows(items) if i["title"] == title), {})


def main():
    t = sv.T()
    sv.setup(spaces=True, **{"start.fresh": False})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 720, "steps": 1})
        sv.sp("space", spaceAction="new", name="Work")
        ids = {name: sv.page(name) for name in ["one", "two", "three"]}
        for x in [x["id"] for x in sv.sp("state")["tabs"] if x["id"] not in ids.values()]:
            sv.sp("close", id=x)
        sv.sp("select", id=ids["one"])
        time.sleep(1)
        sv.cmd({"do": "idle", "action": "unhide"})
        time.sleep(1)

        # Given a tab that isn't the one on screen
        # When its menu opens
        menu = opened(id=ids["two"][:8].lower())
        # Then
        top = titles(menu)
        t.ok("tab menu: at most 13 rows", 0 < len(top) <= 13, top)
        t.ok("tab menu: the main rows in order",
             top[:4] == ["Pin", "Rename", "Add Bookmark", "Mute Tab"] and top[-4:] == ["Close Tab", "Close Other Tabs", "Close Tabs Above", "Close Tabs Below"], top)
        t.ok("tab menu: Copy, Move and More are submenus",
             all("submenu" in find(menu, x) for x in ["Copy", "Move", "More"]), top)
        t.ok("tab menu: Copy keeps the user's four, Copy Address first",
             titles(find(menu, "Copy").get("submenu", [])) == ["Copy Address", "Copy Clean Link", "Copy as Markdown Link", "Copy as Rich Link"],
             find(menu, "Copy"))
        pictured = {i["title"] for i in rows(menu) if i.get("image")}
        t.ok("tab menu: symbols on the main rows only",
             pictured == {"Pin", "Rename", "Add Bookmark", "Mute Tab", "Open in Split View", "Copy", "Move", "Close Tab"}, pictured)
        more = titles(find(menu, "More").get("submenu", []))
        t.ok("tab menu: rare rows one level down",
             {"Duplicate", "Change Icon…", "Site Controls"} <= set(more) and not {"Duplicate", "Site Controls", "Put to Sleep"} & set(top), more)
        t.ok("tab menu: nothing greyed", all(i.get("enabled", True) for i in rows(menu)), menu)
        t.ok("tab menu: Reopen Closed Tab hidden with nothing to reopen", not any(x.startswith("Reopen") for x in top), top)
        moves = titles(find(menu, "Move").get("submenu", []))
        t.ok("tab menu: Move holds Folder, Space and New Window", {"Space", "New Window"} <= set(moves), moves)

        # Given the tab on screen
        # When its menu opens
        active = opened(id=ids["one"][:8].lower())
        here = titles(active)
        more = titles(find(active, "More").get("submenu", []))
        # Then
        t.ok("the tab on screen: Put to Sleep hidden, not greyed", "Put to Sleep" not in more and "Put to Sleep" not in here, more)
        shown = {i["title"] for i in rows(active) if i.get("shown") and i.get("image")}
        t.ok("the tab on screen: its symbols are drawn", {"Pin", "Rename", "Close Tab"} <= shown, [(i["title"], i.get("shown")) for i in rows(active)])

        # Given the space's own menu
        # When it opens
        space = opened(kind="space", at=[140, 140])
        # Then
        t.ok("space menu: New Space…, Rename and Delete keep their symbols",
             {i["title"] for i in rows(space) if i.get("image")} >= {"New Space…", "Rename “Work”…", "Delete “Work”…"},
             [(i["title"], i.get("image")) for i in rows(space)])
        t.ok("space menu: Space Settings… went with its page", "Space Settings…" not in titles(space), titles(space))

        # Given the column's own menu
        # When it opens
        column = titles(opened(kind="column", at=[140, 140]))
        # Then
        t.ok("column menu: five rows", column == ["New Tab", "New Folder", "Hide Sidebar", "Sidebar on Right", "Sidebar Settings"], column)

        # Given the plus menu
        # When it opens
        plus = opened(kind="plus", at=[140, 140])
        # Then
        t.ok("plus menu: a symbol on every row", rows(plus) and all(i.get("image") for i in rows(plus)), plus)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

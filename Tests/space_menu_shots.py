#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv

label = sys.argv[1] if len(sys.argv) > 1 else "now"
theme = sys.argv[2] if len(sys.argv) > 2 else "dark"
OUT = ROOT / ".context" / "shots" / label
SHOT = ROOT / ".context" / "menushot"
AT = [140, 140]
LONG = "Research and Reading for the Long Winter Evenings"
WORK = "00000000-0000-0000-0000-0000000000B2"
READ = "00000000-0000-0000-0000-0000000000B3"
t = sv.T()


def start(spaces):
    sv.use("space-menu-" + uuid.uuid4().hex[:6])
    sv.setup(spaces=True, **{"start.fresh": False, "tabs.groups": True})
    os.makedirs(sv.SUPPORT, exist_ok=True)
    Path(sv.SUPPORT, "spaces.json").write_text(json.dumps(spaces))
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    sv.cmd({"do": "resize", "width": 1000, "height": 720, "steps": 1})
    return pid


def still_open():
    try:
        sv.cmd({"do": "ctxmenu", "action": "read"})
        return True
    except RuntimeError:
        return False


def close():
    try:
        sv.cmd({"do": "ctxmenu", "action": "close"})
    except RuntimeError:
        pass


def picture(pid, number, name, keys=()):
    whole = OUT / f"{name}-{theme}-window.png"
    cut = OUT / f"{name}-{theme}.png"
    reply, took = None, False
    for _ in range(8):
        try:
            reply = sv.cmd({"do": "ctxmenu", "hold": 4, "kind": "space", "at": AT})
        except RuntimeError as error:
            print(f"  {name}: {error}")
            time.sleep(0.5)
            continue
        if keys:
            sv.cmd({"do": "ctxmenu", "action": "keys", "keys": list(keys)})
        time.sleep(0.6)
        said = subprocess.run([str(SHOT), str(pid), str(number), str(whole)], capture_output=True, text=True).stdout.strip()
        words = said.split()
        took = said.startswith("shot") and int(words[words.index("menus") + 1]) >= 1 and still_open()
        if took:
            break
        close()
        time.sleep(0.8)
    close()
    time.sleep(0.5)
    if took:
        x, y = (AT[0] - 14) * 2, (AT[1] - 14) * 2
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(whole), "-vf", f"crop=1040:960:{x}:{y}", str(cut)], check=True)
        whole.unlink()
    if reply:
        (OUT / f"{name}-{theme}.json").write_text(json.dumps(reply["items"], indent=1, ensure_ascii=False))
    t.ok(f"{name} ({theme}) pictured", took)
    return reply["items"] if reply else []


def rows(items):
    return [i for i in items if not i.get("separator")]


def one_space():
    folder = Path(os.path.expanduser("~/Downloads")) / "Invoices"
    pid = start([{"id": sv.FIRST_SPACE, "name": "Personal", "colour": 0, "downloads": str(folder)}])
    try:
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1)
        items = picture(pid, number, "one")
        t.ok("one space: both downloads rows are there",
             {"Downloads to “Invoices”…", "Downloads to the Folder in Settings"} <= {i["title"] for i in rows(items)},
             [i["title"] for i in rows(items)])
        return items
    finally:
        sv.finish()


def three_spaces():
    pid = start([
        {"id": sv.FIRST_SPACE, "name": "Personal", "colour": 0},
        {"id": WORK, "name": "Work", "colour": 0, "icon": "💼", "sharesSignIns": True},
        {"id": READ, "name": LONG, "colour": 0, "icon": "book", "sharesSignIns": True},
    ])
    try:
        sv.cmd({"do": "space", "action": "go", "index": 2})
        time.sleep(1)
        ids = [sv.sp("open", url=f"{sv.BASE}/{name}")["resultID"] for name in ["news", "mail", "docs"]]
        time.sleep(1)
        sv.cmd({"do": "group", "id": ids[0][:8].lower(), "new": True, "name": "Shut"})
        sv.cmd({"do": "group", "id": ids[1][:8].lower(), "new": True, "name": "Open"})
        sv.cmd({"do": "group", "name": "Shut", "fold": True})
        sv.sp("select", id=ids[2])
        time.sleep(1)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1)
        items = picture(pid, number, "three")
        picture(pid, number, "three-on-current", keys=["down", "down"])
        picture(pid, number, "three-on-other", keys=["down"])
        picture(pid, number, "three-on-action", keys=["down", "down", "down", "down", "down"])
        sv.cmd({"do": "space", "action": "go", "index": 3})
        time.sleep(1.2)
        picture(pid, number, "long")
        picture(pid, number, "long-on-current", keys=["down", "down", "down"])
        return items
    finally:
        sv.finish()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/MenuShot.swift"), "-o", str(SHOT)], check=True)
    one = one_space()
    three = three_spaces()
    for name, items in [("one", one), ("three", three)]:
        print(name)
        for item in items:
            print("   ---" if item.get("separator") else f"   {'✓' if item.get('on') else ' '} {'◆' if item.get('image') else ' '} {item['title']}")
    wanted = ["Move Left", "Move Right", "Shut All Folders", "Open All Folders", "Delete “Work”…", "Edit Look…", "New Space…"]
    t.ok("three spaces: every row the menu can hold is there", set(wanted) <= {i["title"] for i in rows(three)}, [i["title"] for i in rows(three)])
    for name, items, count in [("one", one, 1), ("three", three, 3)]:
        t.ok(f"{name}: every row has its picture", all(i.get("image") and i.get("shown") for i in rows(items)),
             [i["title"] for i in rows(items) if not i.get("image")])
        t.ok(f"{name}: only the space rows keep the check's place for a check",
             [bool(i.get("leading")) for i in rows(items)] == [False] * count + [True] * (len(rows(items)) - count),
             [(i["title"], i.get("leading")) for i in rows(items)])
    t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

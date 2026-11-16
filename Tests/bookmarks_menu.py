#!/usr/bin/env python3
"""The Bookmarks menu keeps its bookmarks while a tab's title keeps changing.

Build first (`./build.sh`), then `python3 Tests/bookmarks_menu.py`. SwiftUI
updates an open menu through its own delegate whenever anything it shows may
have changed, which took out the bookmarks Search adds after its items: a
download page counting its speed in its title emptied the menu under the
pointer. The menu bar is AppKit now and its update swaps only its own
items, so the bookmarks stay through it. The menu is only ever told it
opened and closed; nothing is drawn.
"""
import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bookmarks-menu")


def menu(**f):
    return sv.cmd({"do": "menu", "peek": True, **f})


def main():
    t = sv.T()
    try:
        sv.setup()
        os.makedirs(sv.SUPPORT, exist_ok=True)
        node = lambda **f: {"id": str(uuid.uuid4()).upper(), **f}
        kept = [node(title=f"Site {i}", url=f"https://example.com/{i}") for i in range(4)]
        kept.append(node(title="Folder", children=[node(title="In", url="https://example.org/")]))
        json.dump(kept, open(f"{sv.SUPPORT}/bookmarks.json", "w"))
        sv.launch()
        a = sv.page("a")
        m = sv.cmd({"do": "menu"})
        t.ok("the menu holds the bookmarks", m["ours"] >= 5, m)
        sv.ev(a, "window.__n = 0; setInterval(() => { document.title = 'dl ' + (++window.__n) + ' MB/s' }, 150); 1")
        time.sleep(1.5)
        t.ok("closed, the title changing: SwiftUI leaves it alone", menu()["ours"] >= 5)
        menu(shown=True)
        gone = menu(swiftui=True)
        t.ok("open: the menu's own update leaves them in", gone["ours"] >= 5, gone)
        time.sleep(0.5)
        back = menu()
        t.ok("open: they're back at once", back["ours"] >= 5, back)
        time.sleep(1.5)
        t.ok("open, the title changing: still there", menu()["ours"] >= 5)
        menu(hidden=True)
        m = sv.cmd({"do": "menu"})
        t.ok("opened again: all there", m["ours"] >= 5, m)
        sv.cmd({"do": "ui", "bookmarksBar": True})
        time.sleep(1.2)
        shown = sv.cmd({"do": "marks"}).get("shown", {})
        frame = shown.get("frame", [0, 0, 0, 0])
        items = shown.get("items", [])
        t.ok("the bar is up and opaque", not shown.get("hidden", True) and shown.get("opacity", 0) == 1 and frame[2] > 0, shown)
        t.ok("the bar holds a button for every top-level bookmark", len(items) == 5, len(items))
        inside = [i["inBar"] for i in items
                  if i["inBar"][2] > 0 and i["inBar"][1] >= 0 and i["inBar"][1] + i["inBar"][3] <= frame[3]]
        t.ok("every button is drawn inside the bar's band", len(inside) == len(items) and items, [i["inBar"] for i in items])
    finally:
        t.done(); sv.finish()
        os.system(f"defaults delete {sv.SUITE} >/dev/null 2>&1; rm -f ~/Library/Preferences/{sv.SUITE}.plist")
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

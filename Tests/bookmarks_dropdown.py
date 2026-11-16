#!/usr/bin/env python3
"""The bookmark button's list, as the native menu it pops, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/bookmarks_dropdown.py`. Trees
are taken in from a file and the menu is built and described (bench
`dropdown`), every folder's submenu filled; no menu is popped. Folders are
submenus, each bookmark an item with a ⌘ alternate that opens it in a new
tab, and a top level that is one folder alone, like one brought in from
Dia, lists its contents under its name instead of a lone submenu.
"""
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402


def netscape(tree):
    def items(nodes, depth):
        out = []
        pad = "    " * depth
        for n in nodes:
            if isinstance(n, tuple):
                out.append(f"{pad}<DT><H3>{n[0]}</H3>\n{pad}<DL><p>")
                out += items(n[1], depth + 1)
                out.append(f"{pad}</DL><p>")
            else:
                out.append(f'{pad}<DT><A HREF="{n}">{n.split("/")[-1]}</A>')
        return out
    return "\n".join(["<!DOCTYPE NETSCAPE-Bookmark-file-1>", "<TITLE>Bookmarks</TITLE>", "<H1>Bookmarks</H1>", "<DL><p>"]
                     + items(tree, 1) + ["</DL><p>"])


def take(tree):
    with tempfile.NamedTemporaryFile("w", suffix=".html", delete=False) as f:
        f.write(netscape(tree))
    try:
        return sv.cmd({"do": "import-file", "path": f.name})
    finally:
        os.remove(f.name)


def plain(items):
    return [i for i in items if not i.get("separator") and not i.get("alternate")]


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True); sv.launch()
        few = [f"https://example.com/few{i}" for i in range(3)]
        took = take(few)
        d = sv.cmd({"do": "dropdown"})
        shown = plain(d["items"])
        t.ok("three bookmarks: three items, then Add This Page and Manage Bookmarks",
             [i["title"] for i in shown] == ["few0", "few1", "few2", "Add This Page", "Manage Bookmarks"], (took.get("total"), d))
        t.ok("each bookmark wears an icon or its letter", all(i["image"] for i in shown[:3]), shown)
        alts = [i for i in d["items"] if i.get("alternate")]
        t.ok("each bookmark has a ⌘ alternate that opens it in a new tab",
             len(alts) == 3 and all(i["title"].endswith("in New Tab") for i in alts), alts)

        sv.setup(sidebar=True); sv.launch()
        personal = ("Personal", [f"https://example.org/personal{i}" for i in range(22)])
        dia = ("Dia", [f"https://example.com/dia{i}" for i in range(87)] + [personal])
        took = take([dia])
        t.ok("the Dia-like tree came in", took.get("total") == 109 and took.get("top") == ["Dia"], took)
        d = sv.cmd({"do": "dropdown"})
        shown = plain(d["items"])
        t.ok("a top level of one folder: its name heads its contents", d["lone"] == "Dia" and shown[0].get("header") and shown[0]["title"] == "Dia", shown[:2])
        inner = next((i for i in shown if i["title"] == "Personal"), {})
        t.ok("…its 87 bookmarks and the folder inside as a submenu", len(shown) == 1 + 88 + 2 and len(plain(inner.get("submenu", []))) == 22, len(shown))

        sv.setup(sidebar=True); sv.launch()
        take([("Work", [f"https://example.com/w{i}" for i in range(4)] + [("Empty one", [])])])
        d = sv.cmd({"do": "dropdown"})
        empty = next((i for i in plain(d["items"]) if i["title"] == "Empty one"), {})
        t.ok("an empty folder's submenu says so", [(i["title"], i["enabled"]) for i in empty.get("submenu", [])] == [("Empty", False)], empty)

        sv.setup(sidebar=True); sv.launch()
        take([("A", ["https://example.com/a1"]), ("B", ["https://example.com/b1"])])
        d = sv.cmd({"do": "dropdown"})
        shown = plain(d["items"])
        t.ok("two folders at the top: two submenus", d["lone"] == "" and [i["title"] for i in shown[:2]] == ["A", "B"]
             and all("submenu" in i for i in shown[:2]), shown)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

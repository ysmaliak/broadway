#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

sv.use("pages-shots")
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".context" / "pages-shots"
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
ALL_SIZES = {"narrow": (820, 640), "normal": (1280, 860), "wide": (1920, 1100)}
SIZES = [s for s in os.environ.get("SIZES", "narrow,normal,wide").split(",") if s in ALL_SIZES]
LOOKS = {
    "light": {"custom": "F2EEE6", "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0},
    "dark": {"colours": ["000000"], "intensity": 1, "glass": False, "transparency": 0.12, "grain": 0.45},
}
STATES = os.environ.get("STATES", "1") == "1"
THEMES = [x for x in os.environ.get("THEMES", "light,dark").split(",") if x in LOOKS]
t = sv.T()

MARKS = [
    {"title": "Reading", "children": [
        {"title": "A very long article title that keeps going well past the edge of the list it sits in",
         "url": "https://longreads.example/a-very-long-article"},
        {"title": "Swift Forums", "url": "https://forums.swift.org"},
        {"title": "Later", "children": []},
    ]},
    {"title": "Work", "children": [
        {"title": "Linear", "url": "https://linear.app"},
        {"title": "Figma", "url": "https://figma.com"},
        {"title": "Notion", "url": "https://notion.so"},
    ]},
    {"title": "GitHub", "url": "https://github.com"},
    {"title": "", "url": "https://news.ycombinator.com/news"},
    {"title": "Apple Developer", "url": "https://developer.apple.com"},
]
VISITS = [
    "https://developer.apple.com/documentation/appkit/nstableview",
    "https://github.com/apple/swift/pulls",
    "https://news.ycombinator.com/news",
    "https://en.wikipedia.org/wiki/Broadway_(Manhattan)",
    "https://longreads.example/a-very-long-article-title-that-keeps-going-well-past-the-edge-of-the-list-it-sits-in",
    "https://linear.app/acme/issue/PAY-212",
    "https://www.figma.com/file/abc/Checkout",
    "https://mail.example.org/inbox",
    "https://weather.example/warsaw",
    "https://forums.swift.org/latest",
    "https://www.notion.so/Design-notes",
    "https://maps.example/route/home",
    "https://shop.example/basket",
    "https://docs.example/guide/getting-started",
]


def wanted(scene):
    return not ONLY or any(word in scene for word in ONLY)


def numbered(nodes, counter):
    out = []
    for node in nodes:
        counter[0] += 1
        made = {"id": f"00000000-0000-0000-0000-{counter[0]:012d}", "title": node["title"]}
        if "url" in node:
            made["url"] = node["url"]
        if "children" in node:
            made["children"] = numbered(node["children"], counter)
        out.append(made)
    return out


def shoot(name):
    inside = Path(sv.SUPPORT) / f"{name}.png"
    got = sv.cmd({"do": "picture", "path": str(inside), "page": False})
    path = OUT / f"{name}.png"
    if inside.exists():
        shutil.move(str(inside), path)
    t.ok(f"pictured {name}", path.exists(), got)


def own(**ask):
    try:
        return sv.cmd({"do": "ownpage", **ask})
    except RuntimeError:
        return None


def views(scene, settle=0.9, before=None, hover="none", row=0):
    if not wanted(scene):
        return
    for theme in THEMES:
        sv.cmd({"do": "space", "action": "look", **LOOKS[theme]})
        sv.cmd({"do": "ui", "look": theme})
        for size in SIZES:
            width, height = ALL_SIZES[size]
            sv.cmd({"do": "resize", "width": width, "height": height, "steps": 1})
            if before:
                before()
            time.sleep(settle)
            seen = own(hover=hover, row=row)
            if seen:
                (OUT / f"{scene}-{size}.json").write_text(json.dumps(seen, indent=1))
                time.sleep(0.3)
            shoot(f"{scene}-{size}-{theme}")


def show(address, wait=0.8):
    sv.cmd({"do": "ui", "show": address})
    time.sleep(wait)


def start(filled):
    sv.setup(sidebar=True, **{"start.fresh": True, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "250"], check=True)
    os.makedirs(sv.SUPPORT, exist_ok=True)
    if filled:
        Path(sv.SUPPORT, "bookmarks.json").write_text(json.dumps(numbered(MARKS, [0])))
    sv.launch()
    sv.cmd({"do": "window"})
    time.sleep(0.5)


def empty_round():
    start(False)
    try:
        views("newtab")
        show("broadway://history")
        views("history-empty")
        show("broadway://downloads")
        views("downloads-empty")
        show("broadway://files")
        views("files-empty")
        show("broadway://bookmarks")
        views("bookmarks-empty")
        show("broadway://passwords")
        views("passwords-empty")
        show("broadway://import")
        views("import-empty")
        if wanted("trouble"):
            sv.sp("open", url="http://127.0.0.1:1/refused")
            time.sleep(2.5)
            views("trouble-refused")
    finally:
        sv.finish()


def filled_round():
    start(True)
    try:
        for address in VISITS:
            sv.cmd({"do": "history", "take": address})
        show("broadway://history")
        views("history-full")
        if STATES:
            views("history-hover", hover="HistoryLineView", row=2)
            own(find="zzzz")
            views("history-nomatch")
            own(find="")
            own(clearing=True)
            views("history-clearing")
            own(clearing=False)
        sv.cmd({"do": "ui", "downloadsStage": "many"})
        show("broadway://downloads")
        views("downloads-many")
        if STATES:
            views("downloads-hover", hover="KeptLineView", row=1)
        if wanted("downloads-mixed"):
            sv.cmd({"do": "ui", "downloadsStage": "running"})
            time.sleep(0.4)
            views("downloads-running")
            sv.cmd({"do": "ui", "downloadsStage": "failed"})
            time.sleep(0.4)
            views("downloads-failed")
            sv.cmd({"do": "ui", "downloadsStage": "many"})
        show("broadway://files")
        views("files-full")
        if STATES:
            views("files-hover", hover="FileRowView", row=1)
            own(find="zzzz")
            views("files-nomatch")
            own(find="")
        show("broadway://bookmarks")
        views("bookmarks-full")
        if STATES:
            own(find="e")
            views("bookmarks-found")
            own(find="zzzz")
            views("bookmarks-nomatch")
            own(find="")
        show("broadway://passwords")
        if any(wanted(f"passwords-{state}") for state in ("full", "nomatch", "adding", "open")):
            sv.cmd({"do": "surface", "name": "passwords-page"})
            sv.cmd({"do": "surface", "action": "close"})
            views("passwords-full")
            if STATES:
                own(find="zzzz")
                views("passwords-nomatch")
                own(find="")
                own(adding=True)
                views("passwords-adding")
                own(adding=False)
                own(open=0)
                views("passwords-open", hover="PasswordsAccountCell", row=0)
        if wanted("import-full"):
            sv.cmd({"do": "surface", "name": "import-page"})
            sv.cmd({"do": "surface", "action": "close"})
            show("broadway://import")
            views("import-full")
    finally:
        sv.finish()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    print(datetime.now().strftime("%H:%M"), OUT)
    try:
        empty_round()
        filled_round()
    finally:
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

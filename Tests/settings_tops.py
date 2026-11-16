#!/usr/bin/env python3
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("set-tops")
ROOT = Path(__file__).resolve().parents[1]
DETAILS = ["linkrule", "livefolder", "languages"]
PARENTS = {"linkrule": "links", "livefolder": "livefolders", "languages": "general"}
SIZE = [float(n) for n in os.environ.get("SETTINGS_TOPS_SIZE", "1130x700").split("x")]
SCROLL = float(os.environ.get("SETTINGS_TOPS_SCROLL", "0"))
NOIR = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45}


def go(kind, name):
    sv.cmd({"do": "ui", "settingsFind": ""})
    time.sleep(0.2)
    if kind == "detail":
        sv.cmd({"do": "ui", "settingsPage": PARENTS[name]})
        time.sleep(0.5)
    sv.cmd({"do": "ui", "settingsPage" if kind == "page" else "settingsDetail": name})
    time.sleep(0.9)
    if SCROLL:
        sv.cmd({"do": "settings", "find": "", "scroll": SCROLL})
        time.sleep(0.4)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "tops")
    themes = (sys.argv[2] if len(sys.argv) > 2 else "dark").split(",")
    only = set(os.environ.get("SETTINGS_TOPS_ONLY", "").split(",")) - {""}
    out = out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sv.setup(spaces=True, ai=True, **{"start.fresh": True})
    sv.launch()
    shots = 0
    try:
        sv.cmd({"do": "resize", "width": SIZE[0], "height": SIZE[1], "steps": 1})
        time.sleep(0.5)
        if os.environ.get("SETTINGS_TOPS_NOIR"):
            sv.cmd({"do": "space", "action": "rename", "name": "Personal"})
            sv.cmd({"do": "space", "action": "look", **NOIR})
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.5)
        for rule in (["pattern", "github.com/*/pull/*", "front"], ["add", "notion.so", "peek"]):
            sv.cmd({"do": "route", "args": rule})
        for live in (["on"], ["add", "Pull Requests", "https://github.com/pulls"]):
            sv.cmd({"do": "live", "args": live})
        pages = sv.cmd({"do": "settings"}).get("pages", [])
        places = [("page", p) for p in pages] + [("detail", d) for d in DETAILS]
        names = [p[1] for p in places]
        for theme in themes:
            sv.cmd({"do": "ui", "look": theme})
            time.sleep(0.8)
            for kind, name in places:
                if only and name not in only: continue
                go(kind, name)
                path = out / f"{names.index(name):02d}-{name}-{theme}.png"
                took = sv.cmd({"do": "picture", "path": str(path), "page": False})
                print(path.name, took.get("pixels"), took.get("error", ""))
                shots += path.exists()
        print(f"{shots} pictures in {out}")
    finally:
        sv.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())

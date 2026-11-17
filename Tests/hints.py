#!/usr/bin/env python3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("hints")

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/hints")
LINE = "⌘W closes the tab in front"
DAY = 24 * 60 * 60
t = sv.T()
made = [0]


def hints(action="state", **f): return sv.cmd({"do": "hints", "action": action, **f})


def close_three():
    names = []
    for _ in range(3):
        made[0] += 1
        names.append(sv.page(f"page-{made[0]}"))
    for id in names:
        hints("rowclose", id=id)
    time.sleep(0.4)
    return hints()


def shoot(name, dark):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    said = hints("picture", path=str(path), dark=dark)
    return path.exists() and said.get("saved") == str(path) and said.get("announcement") == LINE


try:
    sv.setup(); sv.launch()
    sv.page("home")

    st = hints()
    t.ok("on by default, nothing shown yet", st["on"] is True and st["shown"] == [], st)

    st = close_three()
    t.ok("the first two minutes: three closes show nothing", st["announcement"] == "" and st["shown"] == [], st)
    t.ok("the three closes were counted", st["pointerCloses"] == 3, st)

    hints("advance", seconds=11 * 60)
    st = close_three()
    t.ok("three closes with the pointer show the line", st["announcement"] == LINE, st)
    t.ok("the line is the hint and nothing else", st["showing"] == LINE and st["shown"] == ["close"], st)
    t.ok("light: a picture of the window", shoot("hint-light", False))
    time.sleep(2.2)
    t.ok("it stays longer than a plain line", hints()["announcement"] == LINE)

    st = hints("press")
    t.ok("a click on the line, where the window sends it, sends it away", st["announcement"] == "" and st["hit"] != "", st)

    hints("advance", seconds=DAY)
    st = close_three()
    t.ok("the next day the same three closes show nothing", st["announcement"] == "" and st["shown"] == ["close"], st)

    hints("forget"); hints("advance", seconds=DAY)
    st = close_three()
    t.ok("dark: shown again once forgotten", st["announcement"] == LINE, st)
    t.ok("dark: a picture of the window", shoot("hint-dark", True))
    hints("press")

    sv.cmd({"do": "settings", "find": "", "set": "general.hints", "value": False})
    hints("forget"); hints("advance", seconds=DAY)
    st = close_three()
    t.ok("switched off: nothing shown", st["on"] is False and st["announcement"] == "" and st["shown"] == [], st)
    t.ok("switched off: nothing counted", st["pointerCloses"] == 0 and st["used"] == [], st)
finally:
    sv.finish()
    t.done()
sys.exit(1 if t.failed else 0)

#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("set-bar")
ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "after"
THEMES = [a for a in sys.argv[2:] if a in ("dark", "light")] or ["dark", "light"]
RECORD = LABEL == "before"
OUT = ROOT / ".context" / "shots" / f"bar-{LABEL}"
TOOLS = ROOT / ".build" / "settings-bar"
SHOT = TOOLS / "settings-shot"
EDGE = TOOLS / "edge-pixels"
DETAILS = ["linkrule", "livefolder", "languages"]
RAIL = 210
OPENING = (860, 640)
WIDE = (1180, 640)
FOOT = 20
t = sv.T()
measures = {}
state = {"pid": None, "number": None, "main": None, "size": OPENING}


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    for source, out in ((ROOT / "Tests/SettingsShot.swift", SHOT), (ROOT / "Tests/EdgePixels.swift", EDGE)):
        if not out.exists() or out.stat().st_mtime < source.stat().st_mtime:
            subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(out)], check=True)


def edge(*args):
    return subprocess.run([str(EDGE), *map(str, args)], capture_output=True, text=True).stdout.strip()


def windows():
    out = subprocess.run([str(SHOT), str(state["pid"]), "list"], capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if line.count("\t") == 2]


def off_screen():
    listed = edge("onscreen", state["pid"]).splitlines()
    return bool(listed) and all("offscreen" in line for line in listed)


def ui(**f): return sv.cmd({"do": "ui", **f})
def settings(**f): return sv.cmd({"do": "settings", "find": "", **f})


def shoot(name, number=None):
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    subprocess.run([str(SHOT), str(state["pid"]), number or state["number"], str(path)], capture_output=True, text=True)
    return path


def go(kind, name):
    if kind == "find":
        ui(settingsFind=name)
    else:
        ui(settingsFind="")
        time.sleep(0.2)
        ui(**{"settingsPage" if kind == "page" else "settingsDetail": name})
    time.sleep(1.0)
    settings(scroll=0.0)
    time.sleep(0.3)


def chrome():
    return settings(chrome=True)["chrome"]


def paper(found):
    return next(s for s in found["scrolls"] if s.get("content"))


def bar_of(found):
    return next((m["frame"][3] for m in found["marks"] if m["class"] == "NSTitlebarView"), 52)


def mode(box):
    first = box.split(",")[0].split()
    return first[0], float(first[1])


def line_of(bar):
    found = settings(stage=True)["stage"]
    return found["line"][1] if found.get("line") else bar, not found["folded"]


def boxes(bar, line):
    wide = state["size"][0]
    middle = RAIL + (wide - RAIL) / 2
    left, right = RAIL + 110, wide - 130
    quiet = int(middle - (165 if wide >= OPENING[0] else 100))
    return {
        "bar": (left * 2, 8, (right - left) * 2, (bar - 6) * 2 - 8),
        "under": (left * 2, int(line * 2) + 2, (quiet - left) * 2, 8),
        "edge": (left * 2, int(line * 2), (quiet - left) * 2, 1),
        "above": (left * 2, int(line * 2) - 1, (quiet - left) * 2, 1),
        "column": (left * 2 + 20, int((line - 8) * 2), int((line + 8) * 2)),
    }


def read(path, bar, line=None):
    b = boxes(bar, bar if line is None else line)
    wide = state["size"][0]
    lines = edge("many", path, "box", *b["bar"], "box", *b["under"], "box", *b["edge"], "box", *b["above"],
                 "column", *b["column"], "foot", (RAIL + 30) * 2, (wide - 60) * 2).splitlines()
    if len(lines) != 6:
        return {"bar": "", "barShare": 0, "under": "?", "edge": "", "above": "", "column": "", "foot": -1}
    over, share = mode(lines[0])
    return {"bar": over, "barShare": share, "under": mode(lines[1])[0], "edge": mode(lines[2])[0], "above": mode(lines[3])[0],
            "column": lines[4], "foot": int(lines[5].split()[1]) / 2}


def end_of(found):
    p = paper(found)
    return max(0.0, float(p["document"] - p["frame"][3] + p["insetTop"]))


def look_at(place, kind, name, theme, pictures=True):
    go(kind, name)
    found = chrome()
    bar = bar_of(found)
    p = paper(found)
    end = end_of(found)
    line, pictured = line_of(bar)
    rest = shoot(f"{place}-rest")
    at_rest = read(rest, bar, line)
    entry = {"bar": bar, "line": line, "pictured": pictured, "document": p["document"], "room": p["frame"][3] - p["insetTop"], "end": end,
             "rest": at_rest}
    t.ok(f"{place}: pictured", rest.exists())
    if not RECORD:
        t.ok(f"{place}: at rest the bar is the page's colour", at_rest["bar"] == at_rest["under"] and at_rest["barShare"] > 0.995,
             at_rest)
        t.ok(f"{place}: no line at rest", at_rest["edge"] == at_rest["under"] and at_rest["above"] == at_rest["bar"], at_rest)
    if end > 1:
        settings(scroll=min(40.0, end))
        time.sleep(0.5)
        moved = shoot(f"{place}-scrolled")
        scrolled = read(moved, bar, line)
        entry["scrolled"] = scrolled
        settings(scroll=end)
        time.sleep(0.5)
        last = shoot(f"{place}-end")
        entry["ended"] = read(last, bar, line)
        entry["foot"] = entry["ended"]["foot"]
        entry["version"] = chrome().get("version", {})
        if not RECORD:
            t.ok(f"{place}: scrolled, the bar is still the page's colour and nothing shows in it",
                 scrolled["bar"] == at_rest["bar"] and scrolled["barShare"] > 0.995, scrolled)
            t.ok(f"{place}: scrolled, a line at {'the header' if pictured else 'the bar'}'s bottom edge",
                 scrolled["edge"] != scrolled["bar"] and scrolled["above"] == scrolled["bar"], scrolled)
            t.ok(f"{place}: the line is one pixel", f":{scrolled['edge']}x1 " in scrolled["column"] + " ", scrolled["column"])
            t.ok(f"{place}: the last thing ends {FOOT} pt over the bottom edge", FOOT <= entry["foot"] <= FOOT + 5, entry["foot"])
        settings(scroll=0.0)
        time.sleep(0.4)
        back = read(shoot(f"{place}-back"), bar, line)
        (OUT / f"{place}-back.png").unlink(missing_ok=True)
        if not RECORD:
            t.ok(f"{place}: back at the top the line is gone", back["edge"] == back["under"], back)
        if not pictures:
            for part in ("scrolled", "end"):
                (OUT / f"{place}-{part}.png").unlink(missing_ok=True)
    if not pictures:
        rest.unlink(missing_ok=True)
    measures[place] = entry
    return entry


def crop(source, name, x, y, wide, tall):
    out = OUT / f"{name}.png"
    edge("crop", source, int(x * 2), int(y * 2), int(wide * 2), int(tall * 2), 2, out)
    return out


def sidebars(theme):
    ui(settingsSize=[OPENING[0], 480])
    state["size"] = (OPENING[0], 480)
    time.sleep(0.6)
    go("page", "websites")
    bar = bar_of(chrome())
    line, _ = line_of(bar)
    crop(shoot(f"edges-{theme}-settings-rest"), f"edges-{theme}-page-rest-2x", RAIL, line - 20, 300, 40)
    settings(scroll=40.0)
    settings(wheel=[60.0, 100.0, 300.0])
    time.sleep(0.6)
    both = shoot(f"edges-{theme}-settings")
    page = read(both, bar, line)
    rail = edge("column", both, 16, (bar - 8) * 2, 220)
    crop(both, f"edges-{theme}-page-2x", RAIL, line - 20, 300, 40)
    crop(both, f"edges-{theme}-settings-sidebar-2x", 0, 60, RAIL, 70)
    settings(scroll=0.0)
    ui(settingsSize=list(OPENING))
    state["size"] = OPENING
    main = state["main"]
    entry = {"page": page, "settingsSidebar": rail}
    if main:
        column = sv.cmd({"do": "columnscroll", "wheel": 120.0})
        time.sleep(0.6)
        whole = shoot(f"edges-{theme}-browser", main)
        x, y, wide, tall = max(column["all"], key=lambda r: r[3])
        top = column["height"] - (y + tall)
        run = edge("column", whole, 16, int(top * 2) - 12, int(top * 2) + 12)
        crop(whole, f"edges-{theme}-browser-sidebar-2x", 0, top - 20, min(300, wide), 40)
        entry["browserSidebar"] = {"top": top, "column": run, "edges": column.get("edges", {}).get("top")}
        sv.cmd({"do": "columnscroll", "wheel": -400.0})
    measures[f"edges-{theme}"] = entry
    if not RECORD:
        t.ok(f"{theme}: the page's line beside the sidebars", page["edge"] != page["bar"], entry)
    print("  edges", theme, json.dumps(entry))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tools()
    sv.setup(spaces=True, ai=True, **{"start.fresh": True})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    state["pid"] = next(iter(sv.holding() & sv.running()))
    try:
        opened = windows()
        first = {w[0] for w in opened}
        state["main"] = max(opened, key=lambda w: int(w[1].split("x")[0]) * int(w[1].split("x")[1]))[0] if opened else None
        ui(look="dark")
        ui(settings=True)
        time.sleep(1.5)
        fresh = [w for w in windows() if w[0] not in first]
        if not fresh:
            print("SKIP: no Settings window to picture", windows())
            return 0
        state["number"] = fresh[0][0]
        t.ok("the probe's windows are off every screen", off_screen(), edge("onscreen", state["pid"]))
        for rule in (["pattern", "github.com/*/pull/*", "front"], ["add", "notion.so", "peek"]):
            sv.cmd({"do": "route", "args": rule})
        for live in (["on"], ["add", "Pull Requests", "https://github.com/pulls"]):
            sv.cmd({"do": "live", "args": live})
        for index in range(22):
            sv.page(f"Loose tab {index:02d}")
        pages = sv.cmd({"do": "settings"}).get("pages", [])
        places = [("page", p) for p in pages] + [("detail", d) for d in DETAILS] + [("find", "tab")]
        for theme in THEMES:
            ui(look=theme)
            time.sleep(0.8)
            print(f"{theme}: every page, sub-page and a search")
            for kind, name in places:
                label = ("find-" if kind == "find" else "") + name
                look_at(f"{theme}-{label}", kind, name, theme, pictures=name in ("general", "tabs", "websites", "agents", "tab"))
            print(f"{theme}: key and not key, opening and wider")
            for size_name, size in (("opening", OPENING), ("wide", WIDE)):
                ui(settingsSize=list(size))
                state["size"] = size
                time.sleep(0.6)
                for key in (False, True):
                    ui(settingsKey=key)
                    time.sleep(0.6)
                    look_at(f"{theme}-general-{size_name}-{'key' if key else 'notkey'}", "page", "general", theme)
                ui(settingsKey=False)
            ui(settingsSize=list(OPENING))
            state["size"] = OPENING
            time.sleep(0.6)
            print(f"{theme}: the smallest window")
            ui(settingsSize=[720, 480])
            state["size"] = (720, 480)
            time.sleep(0.6)
            for name in ("general", "tabs", "passwords"):
                look_at(f"{theme}-{name}-smallest", "page", name, theme, pictures=name == "general")
            ui(settingsSize=list(OPENING))
            state["size"] = OPENING
            time.sleep(0.6)
            sidebars(theme)
        for theme in THEMES:
            notkey, key = measures[f"{theme}-general-opening-notkey"], measures[f"{theme}-general-opening-key"]
            if not RECORD:
                t.ok(f"{theme}: key and not key have the same bar", notkey["rest"]["bar"] == key["rest"]["bar"],
                     (notkey["rest"], key["rest"]))
        earlier = ROOT / ".context" / "shots" / "bar-before" / "measures.json"
        if not RECORD and earlier.exists():
            was = json.loads(earlier.read_text())
            for place, entry in measures.items():
                if place not in was or "document" not in entry: continue
                fitted = was[place]["document"] <= was[place]["room"] + 0.5
                fits = entry["document"] <= entry["room"] + 0.5
                t.ok(f"{place}: {'fitted and still fits' if fitted else 'scrolled before too'}", fits or not fitted,
                     (was[place]["document"], was[place]["room"], entry["document"], entry["room"]))
        kept = OUT / "measures.json"
        whole = json.loads(kept.read_text()) if kept.exists() else {}
        whole.update(measures)
        kept.write_text(json.dumps(whole, indent=1))
        ui(settingsFind="")
        ui(settingsClose=True)
        time.sleep(0.4)
        print("pictures and measures.json in", OUT)
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

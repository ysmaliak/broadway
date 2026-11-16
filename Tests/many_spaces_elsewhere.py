#!/usr/bin/env python3
"""Every other list of spaces, with 12 spaces and with 30.

Build first (`./build.sh`), then `python3 Tests/many_spaces_elsewhere.py [folder]`.
In a probe's own world it checks the space menu, the keys, Move to Space,
the `broadway spaces` command, stacked spaces, the link chooser and what
loading every space's row costs after a relaunch.
"""
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("many-else")
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/many-spaces/elsewhere")
BROADWAY = str(Path(sv.APP) / "Contents/Helpers/broadway")
SIZE = (1100, 700)
TOOL = ROOT / ".build" / "side-chrome-shot"
WINDOW = [0]
PID = [0]
t = sv.T()
FACTS = {}


def name_of(index):
    return f"S{index:02d}"


def stage(dark=False):
    said = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": list(SIZE)})
    WINDOW[0], PID[0] = said["window"], said["pid"]
    time.sleep(0.8)


def shoot(name):
    path = OUT / f"{name}.png"
    for turn in range(4):
        subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
        if path.exists():
            return path
        if not TOOL.exists():
            TOOL.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(TOOL)], check=True)
        subprocess.run([str(TOOL), str(PID[0]), str(WINDOW[0]), str(path)], capture_output=True)
        if path.exists():
            return path
        time.sleep(1.0)
    raise RuntimeError(f"no picture of window {WINDOW[0]}")


def space(**request):
    return sv.cmd({"do": "space", **request})


def current():
    return space()["current"]


def cli(*words):
    try:
        return subprocess.run([BROADWAY, "--world", sv.W, *words], capture_output=True, text=True, timeout=20, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(words, 124, "", "timed out")


def check(count):
    names = [name_of(index) for index in range(1, count + 1)]
    space(action="go", index=1)
    time.sleep(0.5)

    items = space(action="menuitems")["items"]
    listed = items[:count]
    t.ok(f"{count}: the space menu lists every space in order", [item["title"] for item in listed] == names, len(items))
    t.ok(f"{count}: the first nine have ⌃1 to ⌃9 and the rest have no key",
         [item["key"] for item in listed] == [str(n) for n in range(1, 10)] + [""] * (count - 9), [item["key"] for item in listed])
    t.ok(f"{count}: one space is ticked", [item["title"] for item in listed if item["checked"]] == [name_of(1)])
    space(action="menu", index=count)
    time.sleep(0.6)
    t.ok(f"{count}: the last row of the menu goes to the last space", current() == name_of(count), current())

    space(action="key", index=9)
    time.sleep(0.6)
    t.ok(f"{count}: ⌃9 goes to the ninth space", current() == name_of(9), current())
    space(action="step", by=1)
    time.sleep(0.6)
    t.ok(f"{count}: Next Space goes past the ninth", current() == name_of(10), current())
    space(action="go", index=count)
    time.sleep(0.5)
    space(action="step", by=1)
    time.sleep(0.6)
    t.ok(f"{count}: Next Space from the last comes round to the first", current() == name_of(1), current())
    space(action="step", by=-1)
    time.sleep(0.6)
    t.ok(f"{count}: Previous Space from the first goes to the last", current() == name_of(count), current())

    space(action="go", index=1)
    time.sleep(0.5)
    tab = sv.page(f"moved-{count}")
    moved = sv.cmd({"do": "tospace", "id": tab, "index": count})
    time.sleep(0.8)
    t.ok(f"{count}: Move to Space reaches the last space", moved.get("space") == name_of(count), moved)

    said = cli("spaces", "list", "--json")
    try:
        rows = json.loads(said.stdout)["data"]["spaces"]
    except (ValueError, KeyError, TypeError):
        rows = []
    t.ok(f"{count}: broadway spaces --json lists every space", [row.get("name") for row in rows] == names, said.stdout[:200] + said.stderr[:200])
    plain = cli("spaces").stdout
    lines = [line for line in plain.splitlines() if line.strip()]
    (OUT / f"cli-spaces-{count}.txt").write_text(plain)
    t.ok(f"{count}: broadway spaces prints a line for each space", len(lines) == count and all(name in plain for name in names), len(lines))
    said = cli("spaces", "switch", name_of(count))
    time.sleep(0.6)
    t.ok(f"{count}: broadway spaces switch reaches the last space", current() == name_of(count), said.stdout + said.stderr)
    said = cli("spaces", "move", name_of(count), "2")
    time.sleep(0.5)
    order = [item["name"] for item in space()["spaces"]]
    t.ok(f"{count}: broadway spaces move puts the last space second", order[:3] == [name_of(1), name_of(count), name_of(2)], order[:4])
    cli("spaces", "move", name_of(count), str(count))
    time.sleep(0.5)
    order = [item["name"] for item in space()["spaces"]]
    t.ok(f"{count}: and back to the end", order == names, order[-3:])

    space(action="go", index=1)
    time.sleep(0.5)
    began = time.time()
    sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
    time.sleep(1.5)
    said = sv.cmd({"do": "stacked"})
    took = time.time() - began - 1.5
    sections = said.get("sections", [])
    t.ok(f"{count}: stacked spaces has a section for every space", [section["name"] for section in sections] == names, len(sections))
    FACTS[f"stacked-{count}"] = {"answerSeconds": round(took, 2), "inner": said.get("inner", {})}
    if count == 30:
        try:
            stage()
            shoot("stacked-30").rename(OUT / "stacked-30-window.png")
        except RuntimeError as error:
            FACTS["stacked-30-picture"] = str(error)
    sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "side"})
    time.sleep(1.0)

    space(action="go", index=count)
    time.sleep(0.5)
    sv.cmd({"do": "ui", "linkChooser": f"{sv.BASE}/chosen-{count}"})
    time.sleep(1.2)
    said = sv.cmd({"do": "route", "args": []})
    rows = said.get("chooser", [])
    t.ok(f"{count}: the link chooser has a row for every space", all(any(name in row for row in rows) for name in names), len(rows))
    seen = {said.get("chooserLit")}
    hidden = []
    for code in [125] * (len(rows) + 2) + [126] * (len(rows) + 2):
        sv.cmd({"do": "press", "code": code, "chars": ""})
        time.sleep(0.06)
        said = sv.cmd({"do": "route", "args": []})
        seen.add(said.get("chooserLit"))
        if not said.get("chooserLitShown", False):
            hidden.append(said.get("chooserLit"))
    t.ok(f"{count}: the arrow keys reach every row of the chooser", len(seen - {-1, None}) >= len(rows) > 0, (len(seen), len(rows)))
    t.ok(f"{count}: the lit row is always in view", not hidden, hidden[:8])
    FACTS[f"chooser-{count}"] = {"rows": len(rows), "lit": len(seen - {-1, None}), "hidden": len(hidden)}
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b"})
    time.sleep(0.6)
    FACTS[f"loads-{count}"] = space().get("loads")


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    sv.setup(spaces=True, **{"agents.on": True})
    sv.launch()
    try:
        stage()
        sv.cmd({"do": "ui", "spaces": True, "cards": True, "downloadsbutton": True, "sideWidth": 258})
        space(action="rename", name=name_of(1))
        made = 1
        for count in (12, 30):
            while made < count:
                made += 1
                space(action="new", name=name_of(made))
                time.sleep(0.45)
            check(count)
        for index in range(1, 31):
            space(action="go", index=index)
            time.sleep(0.3)
            for page in range(3):
                sv.sp("open", url=f"{sv.BASE}/s{index}-{page}")
                time.sleep(0.25)
        time.sleep(1.0)
        space(action="go", index=15)
        time.sleep(0.8)
        sv.sp("save")
        sv.quit()
        time.sleep(1.0)
        sv.launch()
        time.sleep(3.0)
        said = space()
        loads = said.get("loads") or {}
        FACTS["relaunch"] = {"loads": loads, "spaces": len(said["spaces"]), "current": said["current"]}
        t.ok("after a relaunch with 30 spaces of tabs the rows are loaded and timed", loads.get("rows", 0) > 0, loads)
        t.ok("loading them keeps the main thread for less than a tenth of a second", 0 < loads.get("longestMs", 0) < 100, loads)
    finally:
        sv.finish()
    (OUT / "facts.json").write_text(json.dumps(FACTS, indent=1))
    print(json.dumps(FACTS, indent=1))
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

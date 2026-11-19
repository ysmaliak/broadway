#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import visual_diff as vd  # noqa: E402

sv.use("sidebar-cards")
t = sv.T()
SIZE = [1100, 720]
SONG = {"title": "Born To Fly", "detail": "A Singer", "site": "music.example", "art": "warm", "playing": True,
        "pair": "tracks", "time": 71, "duration": 285, "rate": 1, "speed": False, "muted": False}
TINT = {"colours": ["FF89B3", "FF8A1F"], "intensity": 0.75}
GROUNDS = ("plain", "tinted")
STATES = [(ground, front, look) for ground in GROUNDS for front in (True, False) for look in ("light", "dark")]
INKED = [("mini-player", "playing", {"playing": True}), ("update-card", "shown", {})]


def name(ground, front, look):
    return f"{look}-{ground}-{'front' if front else 'behind'}"


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    return int(next(iter(sv.holding() & sv.running())))


def crop(source, dest, view):
    scale = view.get("scale", 2)
    column = view["column"]
    card = view["cardInWindow"]
    top = max(0, card[1] - 60)
    box = [int(column[0] * scale), int(top * scale), int(column[2] * scale), int((column[1] + column[3] - top) * scale)]
    done = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(source), "-vf", "crop={2}:{3}:{0}:{1}".format(*box), str(dest)],
                          capture_output=True, text=True)
    return done.returncode == 0 and dest.exists()


SCREEN = "import AppKit\nprint(Int(NSScreen.screens[0].frame.maxY))\n"


def tall():
    source = vd.TOOLS / "ScreenTall.swift"
    binary = vd.TOOLS / "screen-tall"
    vd.TOOLS.mkdir(parents=True, exist_ok=True)
    if not binary.exists():
        source.write_text(SCREEN)
        subprocess.run(["swiftc", str(source), "-o", str(binary)], check=True)
    return int(subprocess.run([str(binary)], capture_output=True, text=True, check=True).stdout.strip())


def luminance(hex):
    def line(v):
        s = v / 255
        return s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4
    r, g, b = (int(hex[i:i + 2], 16) for i in (0, 2, 4))
    return 0.2126 * line(r) + 0.7152 * line(g) + 0.0722 * line(b)


def ratio(a, b):
    one, two = luminance(a), luminance(b)
    return round((max(one, two) + 0.05) / (min(one, two) + 0.05), 2)


def area(path, box, size):
    x, y, w, h = box
    said = subprocess.run([str(vd.tool("ground", "GroundPixel.swift")), str(path), str(x / size[0]), str(y / size[1]),
                           str((x + w) / size[0]), str((y + h) / size[1])], capture_output=True, text=True).stdout.strip()
    return json.loads(said or "{}").get("mode")


def measured(out, label, called, pid, number, shot, top):
    import glass_ink as gi
    roots = ["MiniPlayerView", "UpdateCardView"]
    offset = (40, top - 40 - SIZE[1])
    found = {}

    def gather():
        marks = []
        for root in roots:
            try:
                inked = sv.cmd({"do": "inks", "under": root}).get("inks", [])
            except RuntimeError as error:
                if "no view named" not in str(error):
                    raise
                inked = []
            for mark in inked:
                box = mark["box"]
                mark["box"] = [box[0] - offset[0], box[1] - offset[1], box[2], box[3]]
                mark["card"] = root
                marks.append(mark)
        return marks

    def read(marks, tag):
        with_path = out / "ink" / f"{label}-{called}-{tag}.png"
        blank = out / "ink" / f"{label}-{called}-{tag}-blank.png"
        with_path.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(shot), str(pid), str(number), str(with_path)], capture_output=True, text=True)
        for root in {m["card"] for m in marks}:
            sv.cmd({"do": "inks", "under": root, "blank": True})
        time.sleep(0.4)
        subprocess.run([str(shot), str(pid), str(number), str(blank)], capture_output=True, text=True)
        for root in {m["card"] for m in marks}:
            sv.cmd({"do": "inks", "under": root, "shown": True})
        time.sleep(0.3)
        if with_path.exists() and blank.exists():
            for mark in gi.measure(with_path, blank, marks, SIZE[0]):
                found[f"{mark['card']}: {gi.named(mark)}{' while the line is hovered' if tag == 'line' else ''}"] = mark
            blank.unlink(missing_ok=True)
        return with_path

    try:
        marks = gather()
    except RuntimeError:
        return None
    still = read([m for m in marks], "rest")
    view = sv.cmd({"do": "mini", "action": "state"}).get("view") or {}
    card = view.get("cardInWindow")
    line = view.get("lineFrame")
    if still.exists() and card and line:
        fill = [card[0] + line[0] + 2, card[1] + line[1], max(2, line[2] * 0.15), line[3]]
        above = [fill[0], fill[1] - 4, fill[2], 2]
        ink, behind = area(still, fill, SIZE), area(still, above, SIZE)
        if ink and behind:
            found["MiniPlayerView: the progress line's played part"] = {"worst": ratio(ink, behind), "ink": ink, "behind": behind}
    sv.cmd({"do": "mini", "action": "linehover"})
    time.sleep(0.8)
    timed = [m for m in gather() if m["card"] == "MiniPlayerView"]
    read(timed, "line")
    sv.cmd({"do": "mini", "action": "linehover", "values": ["off"]})
    time.sleep(0.5)
    return found


def ground_of(path):
    said = subprocess.run([str(vd.tool("ground", "GroundPixel.swift")), str(path), "0.1", "0.02", "0.9", "0.12"],
                          capture_output=True, text=True).stdout.strip()
    return json.loads(said or "{}").get("mode")


def pictures(out, label):
    shot = vd.tool("shot", "WindowShot.swift")
    out.mkdir(parents=True, exist_ok=True)
    grounds = {}
    numbers = {}
    staged = [1000]
    fronts = []
    top = tall()
    for ground in GROUNDS:
        sv.setup(**{"sidebar": True, "start.fresh": False})
        pid = launch()
        try:
            for n in range(3):
                sv.cmd({"do": "open", "url": f"about:blank#{n}"})
            time.sleep(1)
            sv.cmd({"do": "mini", "action": "stage", "values": [json.dumps(SONG)]})
            sv.cmd({"do": "mini", "action": "hover", "values": ["off"]})
            sv.cmd({"do": "updates", "stage": "9.9", "build": "999"})
            if ground == "tinted":
                sv.cmd({"do": "space", "action": "look", **TINT})
            for front in (True, False):
                if not front:
                    sv.cmd({"do": "idle", "action": "give"})
                for look in ("light", "dark"):
                    staged[0] += 1
                    sv.cmd({"do": "updates", "stage": "9.9", "build": str(staged[0])})
                    number = sv.cmd({"do": "agents", "action": "stage", "dark": look == "dark", "shown": True, "size": SIZE})["window"]
                    if front:
                        sv.cmd({"do": "idle", "action": "front"})
                    time.sleep(1.2)
                    lights = sv.cmd({"do": "lights"})
                    window = next((b for b in lights.get("browsers", []) if b.get("number") == number), {})
                    called = name(ground, front, look)
                    placed = bool(lights.get("active")) == front and bool(window.get("key")) == front
                    t.ok(f"{label} {called}: the window is {'in front' if front else 'behind'}", placed,
                         f"active {lights.get('active')}, key {window.get('key')}")
                    if front and placed:
                        fronts.append(called)
                    shown = sv.cmd({"do": "updates"}).get("sidebar", {}).get("shown")
                    t.ok(f"{label} {called}: the update card is in the picture", bool(shown), str(shown))
                    whole = out / f".{label}-{called}-whole.png"
                    subprocess.run([str(shot), str(pid), str(number), str(whole)], capture_output=True, text=True)
                    view = sv.cmd({"do": "mini", "action": "state"}).get("view") or {}
                    path = out / f"{label}-{called}.png"
                    t.ok(f"{label} {called}: pictured", whole.exists() and bool(view) and crop(whole, path, view))
                    whole.unlink(missing_ok=True)
                    if path.exists():
                        grounds[called] = ground_of(path)
                    said = measured(out, label, called, pid, number, shot, top)
                    if said is not None:
                        numbers[called] = said
        finally:
            sv.quit()
            sv.finish()
    (out / f"grounds-{label}.json").write_text(json.dumps(grounds, indent=1, sort_keys=True))
    print("  grounds", json.dumps(grounds, sort_keys=True))
    (out / f"front-{label}.json").write_text(json.dumps(fronts))
    if numbers:
        import glass_ink as gi
        (out / f"sidebar-ink-{label}.json").write_text(json.dumps(numbers, indent=1, sort_keys=True))
        for called, marks in sorted(numbers.items()):
            for mark, said in sorted(marks.items()):
                print(f"  ink  {called}: {mark} {said.get('worst')} to 1 at its worst, {said.get('typical', said.get('worst'))} typical")
                if said.get("note") == "own":
                    continue
                need = gi.limit(said)
                t.ok(f"{label} {called}: {mark} reads at {need:g} to 1 or more", said.get("worst", 0) >= need,
                     f"{said.get('worst')} to 1, ink {said.get('ink')}, behind {said.get('behind')}")


def inks(out, label):
    import glass_ink as gi
    shot = vd.tool("shot", "WindowShot.swift")
    grounds = json.loads((out / f"grounds-{label}.json").read_text())
    numbers = {}
    sv.setup()
    sv.launch()
    try:
        pid = next(iter(sv.holding() & sv.running()))
        sv.cmd({"do": "windowbehind"})
        for called, hex in sorted(grounds.items()):
            if not hex or not called.endswith("-behind"):
                continue
            look, ground = called.split("-")[:2]
            colour = f"#{hex.lower()}"
            for surface, state, request in INKED:
                caption = f"{surface} {state}, {look} on the {ground} sidebar"
                made = sv.cmd({"do": "surface", "name": surface, "look": look, "ground": colour, "pad": 24, "inks": True, **request})
                time.sleep(0.6)
                path = out / "ink" / f"{label}-{surface}-{look}-{ground}.png"
                path.parent.mkdir(parents=True, exist_ok=True)
                subprocess.run([str(shot), str(pid), str(made["number"]), str(path)], capture_output=True, text=True)
                t.ok(f"{caption}: pictured", path.exists())
                if path.exists():
                    gi.judge(t, sv, shot, pid, made, caption, path, 24, colour, numbers)
                for mark in numbers.get(caption, []):
                    if mark.get("note") != "side":
                        continue
                    need = gi.limit(mark)
                    t.ok(f"{caption}: {gi.named(mark)} reads at {need:g} to 1 or more", mark["worst"] >= need,
                         f"{mark['worst']:g} to 1 at its worst, ink {mark.get('ink')}, behind {mark.get('behind')}")
                sv.cmd({"do": "surface", "action": "close"})
    finally:
        sv.quit()
        sv.finish()
    (out / f"ink-{label}.json").write_text(json.dumps(numbers, indent=1, sort_keys=True))
    for caption, marks in sorted(numbers.items()):
        for mark in marks:
            print(f"  ink  {caption}: {gi.named(mark)} {mark['worst']:g} to 1 at its worst, {mark.get('typical', 0):g} typical")


def sheet(out, labels):
    fronts = [set(json.loads((out / f"front-{label}.json").read_text())) if (out / f"front-{label}.json").exists() else set() for label in labels]
    shown = [state for state in STATES if not state[1] or all(name(*state) in each for each in fronts)]
    big = out / ".sheet"
    big.mkdir(exist_ok=True)
    cells = []
    for state in shown:
        for label in labels:
            source = out / f"{label}-{name(*state)}.png"
            grown = big / source.name
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(source), "-vf", "scale=iw*2:ih*2:flags=lanczos", str(grown)],
                           check=True)
            cells.append(f"{label} {name(*state)}={grown}")
    first = big / f"{labels[0]}-{name(*shown[0])}.png"
    sizes = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(first)], capture_output=True, text=True).stdout.split()
    made = out / "sheet.png"
    subprocess.run([str(vd.tool("sheet", "ContactSheet.swift")), str(made), str(len(labels)), sizes[-3], sizes[-1]] + cells, check=True)
    print(made)


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[0] == "sheet":
        sheet(Path(args[1]), args[2:])
        sys.exit(0)
    if args[0] == "ink":
        inks(Path(args[1]), args[2])
    else:
        pictures(Path(args[0]), args[1])
    t.done()
    sys.exit(1 if t.failed else 0)

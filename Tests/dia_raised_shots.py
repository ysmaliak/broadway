#!/usr/bin/env python3
"""Pins over a PR folder card, laid out like the user's picture, on every ground.

Build first (`./build.sh`), then `python3 Tests/dia_raised_shots.py [label]`.
Five pins in one row, then three, above a PRs live folder read from
pr_rows' fake GitHub (a signed-in page on ::1, never the real site) and three loose
tabs, one selected. Grounds: the default dark grey, near-black 171616, black,
pale F2EEE6, vivid 3139FB and orange FF8A1F, light and dark, with a pin
hovered on near-black and pale. Window-only stills of a test copy; crops land
in .context/dia-raised/<label>/, with a sheet per theme and pin count, and
measure.json holds the ground, the pin's fill top and bottom, its rim and
side edge, and the card's fill top and bottom.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
label = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("dia-raised-" + uuid.uuid4().hex[:6])
WORK = ROOT / ".context" / "dia-raised"
SHOT = WORK / "shot"
PIXEL = WORK / "pixel"
rl.SHOT, rl.PIXEL = SHOT, PIXEL

PINS = ["black", "orange", "blue", "grey", "red"]
LOOSE = [("violet", "Orbit Dashboard"), ("orange", "Fernwood"), ("green", "Promo Kit")]
GROUNDS = {"default": None, "near": "171616", "black": "000000", "pale": "F2EEE6", "vivid": "3139FB", "orange": "FF8A1F"}
HOVERED = {"near", "pale"}


def look(hex):
    if hex is None:
        sv.cmd({"do": "space", "action": "look", "colour": "gray", "intensity": 0.5,
                "glass": False, "transparency": 0, "grain": 0})
    else:
        sv.cmd({"do": "space", "action": "look", "custom": hex, "intensity": 1.0,
                "glass": False, "transparency": 0, "grain": 0})


SCALE = [2]


def scale_of(still):
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(still)], capture_output=True, text=True).stdout.split()[-1])
    SCALE[0] = max(1, round(width / 1000))
    return SCALE[0]


def column(still, x, top, bottom):
    k = SCALE[0]
    ys = list(range(round(top * k), round(bottom * k)))
    return list(zip(ys, rl.pixels(still, [(round(x * k), y) for y in ys])))


def measure(still, pin, rows):
    k = SCALE[0]
    x = pin[0] + pin[2] / 2
    line = column(still, x, pin[1] - 3, pin[1] + pin[3] + 3)
    top, height = round(pin[1] * k), round(pin[3] * k)
    at = dict(line)
    out = {"scale": k, "ground": at.get(top - 2 * k), "pin_rim": at.get(top), "pin_top": at.get(top + 3 * k),
           "pin_bottom": at.get(top + height - 3 * k), "pin_foot": at.get(top + height - 1),
           "pin_side": rl.pixels(still, [(round(pin[0] * k), top + height // 2)])[0],
           "pin_trace": [[y, p] for y, p in line]}
    if rows:
        first, last = rows[0], rows[-1]
        cx = first[0] + first[2] - 3
        card = column(still, cx, first[1] - 40, last[1] + last[3] + 10)
        out["card_trace"] = [[y, p] for y, p in card]
        out["card_side"] = rl.pixels(still, [(round((first[0] - 4) * k), round((first[1] + first[3] / 2) * k))])[0]
    return out


def cut(still, path, width, height):
    k = SCALE[0]
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                    f"crop={width * k}:{height * k}:0:0", str(path)], check=True)


def main():
    t = sv.T()
    folder = WORK / label
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    (WORK / "pixel.swift").write_text(rl.PIXEL_SOURCE)
    subprocess.run(["swiftc", "-O", str(WORK / "pixel.swift"), "-o", str(PIXEL)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False, "live.on": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "284"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    report = {}
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 860, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        pins = [rl.opened(icon, f"Pin {n}") for n, icon in enumerate(PINS)]
        loose = [rl.opened(icon, title) for icon, title in LOOSE]
        time.sleep(2)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
        pr.live("unfold", "PRs")
        got = pr.live("update", "PRs")
        time.sleep(1)
        sv.sp("select", id=loose[0])
        known = [i[:8].lower() for i in pins + loose]
        time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        cuts = {}
        for across in [5, 3]:
            if across == 3:
                for id in pins[3:]:
                    sv.cmd({"do": "pin", "id": id, "off": True})
                time.sleep(1.2)
            frames = sv.cmd({"do": "rowframes"})["rows"]
            pin_box = frames.get(pins[1][:8].lower())
            prs = sorted([v for k, v in frames.items() if k not in known], key=lambda r: r[1])
            t.ok(f"{across} across: a pin and the PR rows are laid out", pin_box is not None and len(prs) >= 3, (frames, got))
            for theme in ["dark", "light"]:
                for ground, hex in GROUNDS.items():
                    sv.cmd({"do": "ui", "look": theme})
                    look(hex)
                    sv.cmd({"do": "ui", "windowPointer": [700, 500], "pointerPhase": "move"})
                    time.sleep(1.2)
                    for state in ["rest", "hover"] if ground in HOVERED else ["rest"]:
                        name = f"{across}-{theme}-{ground}-{state}"
                        if state == "hover":
                            sv.cmd({"do": "rowhover", "id": pins[1][:8], "on": True})
                            time.sleep(0.8)
                        still = folder / f"{name}.png"
                        rl.shoot(pid, number, still)
                        scale_of(still)
                        cuts[name] = folder / f"cut-{name}.png"
                        cut(still, cuts[name], 300, 520)
                        if pin_box:
                            report[name] = measure(still, pin_box, prs)
                        if state == "hover":
                            sv.cmd({"do": "rowhover", "id": pins[1][:8], "on": False})
        (folder / "measure.json").write_text(json.dumps(report, indent=1))
        for across in [5, 3]:
            for theme in ["dark", "light"]:
                names = [f"{across}-{theme}-{g}-rest" for g in GROUNDS]
                inputs = sum([["-i", str(cuts[n])] for n in names], [])
                sheet = folder / f"sheet-{across}-{theme}.png"
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                                f"hstack=inputs={len(names)}", str(sheet)], check=True)
                print(sheet)
        for f in folder.glob("[35]-*.png"):
            f.unlink()
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Every folder state and every folder motion, light and dark, with corner crops.

Build first (`./build.sh`), then `python3 Tests/tab_group_shots.py LABEL [--only a,b] [--films] [--width 200]`.

One world: three pins, loose tabs, a five-tab folder, a one-tab folder, a shut
folder, a pinned folder and a live PR folder read from pr_rows' fake GitHub
(a signed-in page on ::1, never the real site) with a stack and bylines. Each state is
shot window-only, cropped around its card, and each card corner is cut out and
scaled 8x so a radius that bulges against its card shows. With --films every
list change is filmed at the display's rate and the probe's frame gaps are kept.
Out: .context/after/tab-groups/LABEL/.
"""
import argparse
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
parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="now")
parser.add_argument("--only", default="")
parser.add_argument("--films", action="store_true")
parser.add_argument("--width", type=float, default=258)
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("tab-groups-" + uuid.uuid4().hex[:6])
TMP = Path("/tmp") / f"broadway-tab-groups-{os.getpid()}"
OUT = ROOT / ".context" / "after" / "tab-groups" / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"
SHEET = TMP / "sheet"
FILM = TMP / "film"
ONLY = set(filter(None, args.only.split(",")))
M = 10
CORNER = 18
ZOOM = 8

LOOKS = {
    "near": {"custom": "000000", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
}
TWO = [("dark", "near"), ("light", "pale")]
FOUR = TWO + [("dark", "vivid"), ("light", "vivid")]
PINS = [("black", "GitHub"), ("green", "Sheets"), ("orange", "Meet")]
LOOSE = [("grey", "Weekend plans"), ("blue", "Mobile Sync"), ("black", "Wide Layout Pass"), ("violet", "My issues")]
MANY = [("red", "otterbase"), ("black", "Public preview"), ("green", "Release notes"), ("blue", "Changelog"),
        ("teal", "Roadmap")]
SINGLE = [("orange", "Standup notes")]
SHUT = [("violet", "Old reading"), ("grey", "Archive")]
PINNED = [("green", "Calendar"), ("blue", "Docs")]
EXTRA = [("teal", "Inbox zero"), ("red", "Weekly review"), ("blue", "Design crit")]
pid = number = None
report = {}
cells = {"dark": [], "light": []}
corners = {"dark": [], "light": []}


def look(theme, ground):
    sv.cmd({"do": "ui", "look": theme})
    sv.cmd({"do": "space", "action": "look", **LOOKS[ground]})


def srgb(still, out):
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(still), "--out", str(out)],
                   capture_output=True, check=True)


def still(name):
    raw = TMP / f"{name}-raw.png"
    out = TMP / f"{name}.png"
    global number
    for attempt in range(4):
        got = subprocess.run([str(rl.SHOT), str(pid), str(number), str(raw)], capture_output=True, text=True)
        if raw.exists():
            break
        print(f"  still {name}: {got.stdout.strip()} {got.stderr.strip()[-300:]}")
        if attempt == 3:
            raise RuntimeError("no still")
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(0.8)
    srgb(raw, out)
    return out


def crop(src, box, path, k, zoom=1):
    x, y, w, h = box
    scale = f",scale={int(w * k * zoom)}:{int(h * k * zoom)}:flags=neighbor" if zoom != 1 else ""
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int(w * k)}:{int(h * k)}:{int(x * k)}:{int(y * k)}{scale}", str(path)], check=True)


def card_of(member):
    sv.cmd({"do": "rowframes"})
    time.sleep(0.3)
    got = sv.cmd({"do": "rowframes"})
    row = got["rows"].get(member[:8].lower())
    blocks = [b for b in got.get("blocks", []) if b["kind"] == "folder"]
    if row:
        mid = row[1] + row[3] / 2
        for b in blocks:
            if b["y"] <= mid <= b["y"] + b["h"]:
                return [b["x"], b["y"], b["w"], b["h"]]
    return None


def card_named(name):
    got = sv.cmd({"do": "rowframes"})
    blocks = [b for b in got.get("blocks", []) if b["kind"] == "folder"]
    heads = got.get("headings", {})
    if name in heads:
        h = heads[name]
        for b in blocks:
            if b["y"] <= h[1] + 1 and h[1] + h[3] <= b["y"] + b["h"] + 1:
                return [b["x"], b["y"], b["w"], b["h"]]
    return None


def shoot_case(name, box, theme, ground, t):
    tag = f"{name}-{theme}-{ground}"
    if box is None:
        t.ok(f"{tag}: has a frame", False)
        return
    plain = still(tag)
    k = max(1, round(rl.scale_of(plain)))
    x, y, w, h = box
    area = [max(0, x - M), max(0, y - M), w + 2 * M, h + 2 * M]
    path = OUT / f"{tag}.png"
    crop(plain, area, path, k)
    cells[theme].append((tag, path))
    if ground != "vivid":
        for corner, (cx, cy) in {"tl": (x, y), "tr": (x + w - CORNER, y), "bl": (x, y + h - CORNER),
                                 "br": (x + w - CORNER, y + h - CORNER)}.items():
            cpath = OUT / "corners" / f"{tag}-{corner}.png"
            cpath.parent.mkdir(exist_ok=True)
            crop(plain, [cx, cy, CORNER, CORNER], cpath, k, ZOOM)
            corners[theme].append((f"{tag}-{corner}", cpath))
    report[tag] = {"card": box, "scale": k}
    print(f"  {tag}: card {box}")
    t.ok(f"pictured {tag}", path.exists())


def run(name, theme_grounds, prep, box, t, undo=None):
    if ONLY and name not in ONLY:
        return
    for theme, ground in theme_grounds:
        look(theme, ground)
        sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
        prep()
        time.sleep(1.0)
        shoot_case(name, box(), theme, ground, t)
        if undo:
            undo()
            time.sleep(0.4)


def film(name, act, seconds, t, height=940):
    if ONLY and name not in ONLY and "films" not in ONLY:
        return
    folder = TMP / "films" / name
    crop_ = f"0,0,{args.width + 12},{height}"
    sv.cmd({"do": "idle", "action": "unhide"})
    time.sleep(0.3)
    taker = subprocess.Popen([str(FILM), str(pid), str(number), str(folder), str(seconds), crop_],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        t.ok(f"{name}: filmed", False, line)
        return
    sv.cmd({"do": "idle", "action": "frames"})
    time.sleep(0.1)
    act()
    time.sleep(max(0.2, seconds - 0.4))
    gaps = sv.cmd({"do": "idle", "action": "gaps"})
    report["film-" + name] = {"longestMs": gaps.get("longestMs"), "hitches": gaps.get("hitches")}
    print(f"  film {name}: longest frame {gaps.get('longestMs')} ms, hitches {gaps.get('hitches')}")
    taker.communicate()
    if (folder / "sheet.png").exists():
        shutil.copy(folder / "sheet.png", OUT / f"film-{name}.png")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(OUT / f"film-{name}.mp4")], check=False)
    t.ok(f"{name}: filmed", (OUT / f"film-{name}.png").exists() or (OUT / f"film-{name}.mp4").exists())
    time.sleep(0.5)


def group(**r):
    return sv.cmd({"do": "group", **r})


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    for src, out, flags in [("Tests/WindowShot.swift", rl.SHOT, ["-parse-as-library"]),
                            ("Tests/ContactSheet.swift", SHEET, ["-parse-as-library"]), ("Tests/pin_film.swift", FILM, ["-O", "-parse-as-library"])]:
        copy = TMP / Path(src).name
        shutil.copy(ROOT / src, copy)
        subprocess.run(["swiftc", *flags, str(copy), "-o", str(out)], check=True, cwd=TMP)
    (TMP / "pixel.swift").write_text(rl.PIXEL_SOURCE)
    subprocess.run(["swiftc", "-O", str(TMP / "pixel.swift"), "-o", str(rl.PIXEL)], check=True, cwd=TMP)
    sv.setup(spaces=True, **{"start.fresh": False, "live.on": True, "welcome.show": False, "tabs.newAtBottom": True, "split": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(args.width)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 1000, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        pins = [rl.opened(icon, title) for icon, title in PINS]
        pinned = [rl.opened(icon, title) for icon, title in PINNED]
        many = [rl.opened(icon, title) for icon, title in MANY]
        single = [rl.opened(icon, title) for icon, title in SINGLE]
        shut = [rl.opened(icon, title) for icon, title in SHUT]
        loose = [rl.opened(icon, title) for icon, title in LOOSE]
        extra = [rl.opened(icon, title) for icon, title in EXTRA]
        time.sleep(2)
        made = {i[:8].lower() for i in pins + loose + many + single + shut + pinned + extra}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        for name, members in [("Pinned", pinned), ("Otterbase", many), ("Standup", single), ("Old", shut)]:
            group(id=members[0][:8].lower(), new=True, name=name)
            for id in members[1:]:
                group(id=id[:8].lower(), name=name)
        group(name="Pinned", pinned=True)
        group(name="Old", fold=True)
        pr.live("add-page", "Pull Requests", "pullRequests", f"{pr.BASE}{pr.PULLS}")
        pr.live("unfold", "Pull Requests")
        prs = pr.folder(pr.live("update", "Pull Requests"), "Pull Requests")
        ids = [tab["id"] for tab in prs["tabs"]]
        stacked = [s["id"] for s in prs.get("stacks", [])]
        t.ok("the PR folder has rows", len(ids) >= 3, prs)
        time.sleep(1.0)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]

        def select(id):
            return lambda: (sv.sp("select", id=id), time.sleep(0.6))

        def card(member):
            return lambda: card_of(member)

        run("open", FOUR, select(loose[0]), card(many[0]), t)
        run("first", TWO, select(many[0]), card(many[0]), t)
        run("middle", TWO, select(many[2]), card(many[0]), t)
        run("last", FOUR, select(many[-1]), card(many[0]), t)
        run("single", TWO, select(single[0]), card(single[0]), t)
        run("shut", TWO, select(loose[0]), lambda: card_named("Old"), t)
        run("shut-hover", TWO, lambda: (select(loose[0])(), group(name="Old", look="hover")), lambda: card_named("Old"), t,
            undo=lambda: group(name="Old", look="clear"))
        run("heading-hover", TWO, lambda: (select(loose[0])(), group(name="Otterbase", look="hover")), card(many[0]), t,
            undo=lambda: group(name="Otterbase", look="clear"))
        run("rename", TWO, lambda: (select(loose[0])(), group(name="Otterbase", look="edit")), card(many[0]), t,
            undo=lambda: group(name="Otterbase", look="clear"))
        run("drop", TWO, lambda: (select(loose[0])(), group(name="Otterbase", look="drop")), card(many[0]), t,
            undo=lambda: group(name="Otterbase", look="clear"))
        run("drop-heading", TWO, lambda: (select(loose[0])(), group(name="Otterbase", look="dropheading")), card(many[0]), t,
            undo=lambda: group(name="Otterbase", look="clear"))
        run("pinned", TWO, select(pinned[1]), card(pinned[0]), t)
        run("live", FOUR, select(ids[0]), card(ids[0]), t)
        inner = next((i for i in ids if stacked and i != stacked[0] and i in ids[ids.index(stacked[0]):]), ids[-1]) if stacked else ids[-1]
        run("live-stack", TWO, select(inner), card(ids[0]), t)

        if not ONLY or "whole" in ONLY:
            sv.sp("select", id=many[2])
            for theme, ground in FOUR:
                look(theme, ground)
                time.sleep(1.0)
                plain = still(f"whole-{theme}-{ground}")
                k = max(1, round(rl.scale_of(plain)))
                crop(plain, [0, 0, args.width + 12, 940], OUT / f"whole-{theme}-{ground}.png", k)

        if args.films:
            look("dark", "near")
            sv.sp("select", id=loose[1])
            time.sleep(0.6)
            film("fold", lambda: group(name="Otterbase", fold=True), 1.2, t)
            film("unfold", lambda: group(name="Otterbase", fold=True), 1.2, t)
            film("reversal", lambda: group(name="Otterbase", fold=True, again=[0.07]), 1.4, t)
            time.sleep(0.6)
            film("add", lambda: group(id=extra[0][:8].lower(), name="Otterbase"), 1.2, t)
            film("remove", lambda: group(id=extra[0][:8].lower(), name="none"), 1.2, t)
            b = sv.cmd({"do": "rowframes"})["rows"].get(extra[1][:8].lower())
            target = card_of(many[0])
            if b and target:
                down = [b[0] + 60, b[1] + b[3] / 2]
                into = target[1] + target[3] - 50
                steps = [[down[0], down[1] + (into - down[1]) * f] for f in (0, 0.1, 0.25, 0.45, 0.65, 0.8, 0.92, 1.0)]
                film("drag-into", lambda: sv.cmd({"do": "film", "action": "pindrag", "id": extra[1], "points": steps, "frames": 2,
                                                  "every": 0.06, "path": str(TMP / "unused.png")}), 1.8, t)
            b = sv.cmd({"do": "rowframes"})["rows"].get(many[1][:8].lower())
            if b:
                start = [b[0] + 60, b[1] + b[3] / 2]
                steps = [[start[0], start[1] + dy] for dy in (0, 10, 30, 60, 90, 110, 120)]
                film("drag-within", lambda: sv.cmd({"do": "film", "action": "pindrag", "id": many[1], "points": steps, "frames": 2,
                                                    "every": 0.06, "path": str(TMP / "unused.png")}), 1.8, t)
            film("create", lambda: group(id=extra[2][:8].lower(), new=True, name="Fresh"), 1.2, t)
            sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
            group(name="Fresh", look="clear")
            film("ungroup", lambda: group(name="Fresh", ungroup=True), 1.2, t)
            group(id=extra[2][:8].lower(), new=True, name="Doomed")
            group(name="Doomed", look="clear")
            time.sleep(0.8)
            film("delete", lambda: group(name="Doomed", close=True), 1.2, t)
            whole = pr.ROWS
            pr.ROWS = whole[:4]
            film("live-lose", lambda: pr.live("update", "Pull Requests"), 4.0, t)
            pr.ROWS = whole
            film("live-gain", lambda: pr.live("update", "Pull Requests"), 4.0, t)
            film("pin-folder", lambda: group(name="Standup", pinned=True), 1.4, t)
            sv.cmd({"do": "space", "action": "new", "name": "Other"})
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.8)
            film("space-switch", lambda: sv.cmd({"do": "space", "action": "go", "index": 2}), 1.2, t)
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.8)

        for theme in ["dark", "light"]:
            if cells[theme]:
                entries = [f"{name}={path}" for name, path in cells[theme]]
                subprocess.run([str(SHEET), str(OUT / f"sheet-{theme}.png"), "4", str((args.width + 2 * M) * 2), str(300 * 2), *entries],
                               check=False)
            if corners[theme]:
                entries = [f"{name}={path}" for name, path in corners[theme]]
                subprocess.run([str(SHEET), str(OUT / f"corners-{theme}.png"), "8", str(CORNER * 2 * ZOOM / 2), str(CORNER * 2 * ZOOM / 2),
                                *entries], check=False)
        (OUT / "measure.json").write_text(json.dumps(report, indent=1))
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

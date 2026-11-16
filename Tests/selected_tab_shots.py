#!/usr/bin/env python3
"""Every place a selected tab shows, light and dark, and every shadow a container cuts.

Build first (`./build.sh`), then `python3 Tests/selected_tab_shots.py LABEL [--only a,b] [--films]`.

One world: three pins, a three-tab folder card, loose tabs, a live PR folder
read from pr_rows' fake GitHub (a signed-in page on ::1, never the real site) with a
stack, a split pair, and twenty more loose tabs for the scroll edges. Each case
is shot window-only twice, as it is and with every clip in the column off (the
test-only `ui unclip`), and the two are diffed around the selected tab: any
difference is a shadow or glow some container cut. Crops, diffs, traces and a
sheet per theme go to .context/selected-tab/LABEL/. Capture and diff tools are
built in /tmp.
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

sv.use("selected-tab-" + uuid.uuid4().hex[:6])
TMP = Path("/tmp") / f"broadway-selected-{os.getpid()}"
OUT = ROOT / ".context" / "selected-tab" / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"
DIFF = TMP / "diff"
SHEET = TMP / "sheet"
FILM = TMP / "film"
ONLY = set(filter(None, args.only.split(",")))
M = 18

LOOKS = {
    "near": {"custom": "000000", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "glass": {"colour": "gray", "intensity": 0.5, "glass": True, "transparency": 0.5, "grain": 0},
}
ALL = [("dark", "near"), ("light", "pale"), ("dark", "vivid"), ("light", "vivid"), ("dark", "glass"), ("light", "glass")]
TWO = [("dark", "near"), ("light", "pale")]
PINS = [("black", "GitHub"), ("green", "Sheets"), ("orange", "Meet")]
LOOSE = [("grey", "Weekend plans"), ("blue", "Mobile Sync"), ("black", "Wide Layout Pass"), ("violet", "My issues"),
         ("teal", "Left pane"), ("red", "Right pane")]
FOLDER = [("red", "otterbase"), ("black", "Public preview"), ("green", "Release notes")]
pid = number = None
report = {}
cells = {"dark": [], "light": []}


def look(theme, ground):
    sv.cmd({"do": "ui", "look": theme})
    sv.cmd({"do": "space", "action": "look", **LOOKS[ground]})


def srgb(still, out):
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(still), "--out", str(out)],
                   capture_output=True, check=True)


def still(name):
    raw = TMP / f"{name}-raw.png"
    out = TMP / f"{name}.png"
    for attempt in range(4):
        try:
            rl.shoot(pid, number, raw)
            break
        except RuntimeError:
            if attempt == 3:
                raise
            sv.cmd({"do": "idle", "action": "unhide"})
            time.sleep(0.8)
    srgb(raw, out)
    return out


def tool(*a):
    return json.loads(subprocess.run([str(DIFF), *map(str, a)], capture_output=True, text=True).stdout)


def frames():
    return sv.cmd({"do": "rowframes"})["rows"]


def box_of(id):
    return frames().get(id[:8].lower())


def crop(src, box, path, k):
    x, y, w, h = box
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int(w * k)}:{int(h * k)}:{int(x * k)}:{int(y * k)}", str(path)], check=True)


def extent(values, ground, reverse=False):
    seq = list(reversed(values)) if reverse else values
    far = seq[0]
    n = 0
    for v in seq:
        if max(abs(a - b) for a, b in zip(v, far)) > 1:
            break
        n += 1
    return len(seq) - n


def shoot_case(name, box, theme, ground, t):
    tag = f"{name}-{theme}-{ground}"
    if box is None:
        t.ok(f"{tag}: has a frame", False)
        return
    plain = still(tag)
    k = max(1, round(rl.scale_of(plain)))
    sv.cmd({"do": "ui", "unclip": True})
    time.sleep(0.5)
    open_ = still(tag + "-open")
    sv.cmd({"do": "ui", "unclip": False})
    time.sleep(0.3)
    x, y, w, h = box
    area = [max(0, x - M), max(0, y - M), w + 2 * M, h + 2 * M]
    path = OUT / f"{tag}.png"
    crop(plain, area, path, k)
    crop(open_, area, OUT / f"{tag}-unclipped.png", k)
    got = tool("diff", plain, open_, int(area[0] * k), int(area[1] * k), int(area[2] * k), int(area[3] * k))
    mid = int((y + h / 2) * k)
    across = tool("row", plain, mid, int(area[0] * k), int((area[0] + area[2]) * k))
    cx = int((x + w * 0.7) * k)
    down = tool("column", plain, cx, int(area[1] * k), int((area[1] + area[3]) * k))
    down_open = tool("column", open_, cx, int(area[1] * k), int((area[1] + area[3]) * k))
    lead = int((x - area[0]) * k)
    top = int((y - area[1]) * k)
    m = {"box": box, "scale": k, "diff": got,
         "fill": plain and tool("row", plain, mid, int((x + w - 6) * k), int((x + w - 5) * k))[0],
         "reach": {"above": extent(down[:top], None) / k, "below": extent(down[top + int(h * k):], None, reverse=True) / k,
                   "left": extent(across[:lead], None) / k},
         "reach_unclipped": {"above": extent(down_open[:top], None) / k,
                             "below": extent(down_open[top + int(h * k):], None, reverse=True) / k},
         "trace_down": down[::max(1, k // 2)], "trace_across": across[:lead + 4 * k]}
    report[tag] = m
    cells[theme].append((tag, path))
    if got["count"] > 0:
        cells[theme].append((tag + " UNCLIPPED", OUT / f"{tag}-unclipped.png"))
    print(f"  {tag}: diff {got['max']}/{got['count']} reach {m['reach']}")
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


def film(name, act, seconds, t):
    if ONLY and name not in ONLY:
        return
    folder = TMP / "films" / name
    crop_ = f"0,0,{args.width + 12},1000"
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


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    for src, out, flags in [("Tests/WindowShot.swift", rl.SHOT, ["-parse-as-library"]), ("Tests/SelectedDiff.swift", DIFF, ["-O"]),
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
        loose = [rl.opened(icon, title) for icon, title in LOOSE]
        folder = [rl.opened(icon, title) for icon, title in FOLDER]
        time.sleep(2)
        made = {i[:8].lower() for i in pins + loose + folder}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": folder[0][:8].lower(), "new": True, "name": "Otterbase"})
        for id in folder[1:]:
            sv.cmd({"do": "group", "id": id[:8].lower(), "name": "Otterbase"})
        pr.live("add-page", "Pull Requests", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
        pr.live("unfold", "Pull Requests")
        prs = pr.folder(pr.live("update", "Pull Requests"), "Pull Requests")
        ids = [tab["id"] for tab in prs["tabs"]]
        stacked = [s["id"] for s in prs.get("stacks", [])]
        t.ok("the PR folder has rows", len(ids) >= 3, prs)
        sv.sp("pair", id=loose[5], **{"with": loose[4]}, side="right")
        time.sleep(1.0)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]

        def select(id):
            return lambda: (sv.sp("select", id=id), time.sleep(0.6))

        def at(id):
            return lambda: box_of(id)

        run("loose", ALL, select(loose[1]), at(loose[1]), t)
        run("card-first", TWO + [("dark", "vivid"), ("light", "vivid")], select(folder[0]), at(folder[0]), t)
        run("card-middle", ALL, select(folder[1]), at(folder[1]), t)
        run("card-last", TWO + [("dark", "vivid"), ("light", "glass")], select(folder[2]), at(folder[2]), t)
        run("pr-byline", TWO + [("dark", "vivid")], select(ids[0]), at(ids[0]), t)
        inner = next((i for i in ids if stacked and i != stacked[0] and i in ids[ids.index(stacked[0]):]), ids[2]) if stacked else ids[2]
        run("pr-in-stack", TWO, select(inner), at(inner), t)
        run("pin", TWO + [("dark", "vivid")], select(pins[1]), at(pins[1]), t)

        def split_box():
            got = frames()
            above, below = got.get(loose[3][:8].lower()), got.get(folder[0][:8].lower())
            rows = [f for f in got.values() if above and f[1] > above[1] + above[3] - 1 and f[0] < 40]
            under = min((f[1] for f in rows), default=above[1] + 2 * above[3] + 6) if above else 0
            return [above[0], above[1] + above[3] + 3, above[2], max(30, under - above[1] - above[3] - 6)] if above else None
        run("split", TWO, select(loose[5]), split_box, t)

        def press():
            sv.sp("select", id=loose[0])
            time.sleep(0.4)
            sv.cmd({"do": "rowpress", "id": loose[2][:8], "down": True})
            time.sleep(0.25)
        run("pressed", TWO, press, at(loose[2]), t, undo=lambda: sv.cmd({"do": "rowpress", "id": loose[2][:8], "down": False}))

        def hovered():
            sv.sp("select", id=loose[0])
            time.sleep(0.4)
            sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": True})
        run("hovered", TWO, hovered, at(loose[2]), t, undo=lambda: sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": False}))

        def hovered_then_selected():
            sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": True})
            time.sleep(0.3)
            sv.sp("select", id=loose[2])
        run("hovered-selected", TWO, hovered_then_selected, at(loose[2]), t,
            undo=lambda: sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": False}))

        if args.films:
            look("dark", "near")
            sv.sp("select", id=folder[1])
            time.sleep(0.6)
            group = next((g for x, g in zip(sv.sp("state")["tabs"], sv.sp("state")["groupIDs"]) if x["id"] == folder[0]), None)
            film("fold", lambda: sv.sp("collapse", group=group), 1.2, t)
            film("unfold", lambda: sv.sp("collapse", group=group), 1.2, t)
            sv.sp("select", id=loose[1])
            time.sleep(0.6)
            b = box_of(loose[1])
            if b:
                points = [[b[0] + 40, b[1] + b[3] / 2 + dy] for dy in (0, 6, 14, 26, 40, 56, 72)]
                film("drag", lambda: sv.cmd({"do": "film", "action": "pindrag", "id": loose[1], "points": points, "frames": 2,
                                             "every": 0.06, "path": str(TMP / "unused.png"), "cancel": True}), 1.4, t)
            film("pin-flight", lambda: sv.cmd({"do": "pin", "id": loose[1]}), 1.2, t)
            film("unpin-flight", lambda: sv.cmd({"do": "pin", "id": loose[1], "off": True}), 1.2, t)
            sv.cmd({"do": "space", "action": "new", "name": "Other"})
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.8)
            film("space-swipe", lambda: sv.cmd({"do": "space", "action": "swipe", "dx": -160}), 1.4, t)
            sv.cmd({"do": "space", "action": "go", "index": 1})
            time.sleep(0.8)

        extra = [rl.opened("grey", f"Filler {n}") for n in range(22)] if (not ONLY or ONLY & {"scroll-top", "scroll-bottom", "scroll-under"}) else []
        if extra:
            time.sleep(1.5)
            first = folder[0]

            def to_top():
                sv.cmd({"do": "columnscroll", "wheel": -3000})
                time.sleep(0.8)
                sv.sp("select", id=first)
            run("scroll-top", TWO, to_top, at(first), t)

            def to_bottom():
                sv.cmd({"do": "columnscroll", "wheel": 3000})
                time.sleep(0.8)
                sv.sp("select", id=extra[-1])
            run("scroll-bottom", TWO, to_bottom, at(extra[-1]), t)

            def under():
                sv.cmd({"do": "columnscroll", "wheel": -3000})
                time.sleep(0.6)
                sv.sp("select", id=extra[4])
                b = box_of(extra[4])
                top = sv.cmd({"do": "columnscroll"}).get("edges", {})
                sv.cmd({"do": "columnscroll", "wheel": (b[1] - 210) if b else 200})
            run("scroll-under", TWO, under, at(extra[4]), t)

        if not ONLY or "peek" in ONLY:
            sv.sp("select", id=loose[1])
            for theme, ground in TWO:
                look(theme, ground)
                sv.cmd({"do": "columnscroll", "peek": True})
                time.sleep(1.2)
                shoot_case("peek", [M, M, args.width + 12, 760], theme, ground, t)
                sv.cmd({"do": "columnscroll", "peek": False})
                time.sleep(0.8)

        for theme, made in cells.items():
            if not made:
                continue
            entries = [f"{name}={path}" for name, path in made]
            subprocess.run([str(SHEET), str(OUT / f"sheet-{theme}.png"), "4", str((args.width + 2 * M) * 2), str(90 * 2), *entries],
                           check=False)
        (OUT / "measure.json").write_text(json.dumps(report, indent=1))
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

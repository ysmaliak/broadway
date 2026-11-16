#!/usr/bin/env python3
"""Folder headings shut, open and mid-fold, at the screen's 2x, light and dark, pale and vivid.

Build first (`./build.sh`), then `python3 Tests/folder_glyph_shots.py LABEL [--films 1]`.

A test copy in a world of its own (SEARCH_PROBE), shown behind the front app.
Loose tabs, an open folder (Otterbase) and a shut one (Reading) between
them, so the glyph sits beside the loose rows' icons and the heading names.
Window-only stills are cut to the column's top into .context/folder-glyph/LABEL/
as THEME-GROUND.png. With --films 1 the open folder is filmed at 120 fps
folding, unfolding, reversed in flight at about 10, 50 and 90 percent of the
fold (the app folds again after 13, 43 and 99 ms, `group fold again`) and
reversed twice. Each film keeps its frames beside a contact sheet, and
tracks.json follows the row below the folder (its orange mark) and the
folder's first row (its red mark) frame by frame, in points. --takes picks
films by name, --stills 0 skips the stills, --sample DIR samples the app
through each film.

The copy runs behind the front app, and there the window server shows its
changes 80 to 200 ms late and plays them back in a bunch, so a reversal within
a fold's first 100 ms is filmed late and lands as a jump on any build. The
reversal itself is checked on the layers, in FoldReversalTests.
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
parser.add_argument("--films", default="1")
parser.add_argument("--width", type=float, default=260)
parser.add_argument("--takes", default="")
parser.add_argument("--stills", default="1")
parser.add_argument("--sample", default="")
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("folder-glyph-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
TMP = Path("/tmp") / f"broadway-folder-glyph-{os.getpid()}"
OUT = ROOT / ".context" / "folder-glyph" / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"
FILM = TMP / "film"

LOOKS = {
    "near": {"custom": "000000", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
}
SCENES = [("light", "pale"), ("light", "vivid"), ("dark", "near"), ("dark", "vivid")]


def size_of(still):
    said = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(still)], capture_output=True, text=True).stdout.split()
    return int(said[said.index("pixelWidth:") + 1]), int(said[said.index("pixelHeight:") + 1])


def srgb(still, out):
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(still), "--out", str(out)],
                   capture_output=True, check=True)


def decode(path):
    size = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], capture_output=True, text=True).stdout.split()
    w, h = int(size[size.index("pixelWidth:") + 1]), int(size[size.index("pixelHeight:") + 1])
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                         capture_output=True).stdout
    return raw, w, h


def marks(path):
    raw, w, h = decode(path)
    found = {"below": [], "row": []}
    for y in range(h):
        row = raw[y * w * 3:(y + 1) * w * 3]
        for x in range(0, w):
            r, g, b = row[x * 3], row[x * 3 + 1], row[x * 3 + 2]
            if r > 200 and 80 < g < 170 and b < 90:
                found["below"].append(y)
            elif r > 150 and g < 80 and b < 80:
                found["row"].append(y)
    out = {}
    for key, ys in found.items():
        if len(ys) > 20:
            out[key] = round(sum(ys) / len(ys) / 2, 2)
            out[key + "Ink"] = len(ys)
    return out


def track(name, times):
    folder = OUT / "films" / name
    if not folder.exists() or not times:
        return []
    files = sorted(folder.glob("*.png"))
    return [{"t": t, **marks(f)} for f, t in zip(files, times)]


def film(pid, name, seconds, act, crop):
    out = OUT / "films"
    out.mkdir(parents=True, exist_ok=True)
    frames = out / name
    shutil.rmtree(frames, ignore_errors=True)
    command = [str(FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(TMP / name), "--scale", "2",
               "--fps", "120", "--columns", "6", "--most", "36", "--frames", str(TMP / f"{name}-frames"),
               "--crop", ",".join(str(round(v)) for v in crop)]
    for _ in range(6):
        taker = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = taker.stdout.readline()
        if line.startswith("ready"):
            break
        taker.wait()
        why = line + taker.stderr.read()
        time.sleep(1.5)
    else:
        return {"error": "film did not start: " + why[-300:]}
    sampler = None
    if args.sample:
        sampler = subprocess.Popen(["sample", str(pid), "1", "1", "-mayDie", "-file", str(Path(args.sample) / f"{name}.txt")],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.05)
    act()
    taker.wait()
    if sampler:
        sampler.wait()
    shutil.copy(TMP / f"{name}.png", out / f"{name}.png")
    if (TMP / f"{name}-frames").exists():
        shutil.copytree(TMP / f"{name}-frames", frames)
    try:
        said = json.loads((TMP / f"{name}.json").read_text())
    except (OSError, ValueError):
        return {"error": taker.stderr.read()}
    picked = {k: said.get(k) for k in ("delivered", "deliveredFps", "motionMs", "worstGapMs", "motionGaps", "frames", "firstHost")}
    picked["track"] = track(name, said.get("times") or [])
    return picked


def main():
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    (TMP / "pixel.swift").write_text(rl.PIXEL_SOURCE)
    subprocess.run(["swiftc", "-O", str(TMP / "pixel.swift"), "-o", str(rl.PIXEL)], check=True, cwd=TMP)
    if args.films == "1":
        shutil.copy(ROOT / "Tests/motion_film.swift", TMP / "motion_film.swift")
        subprocess.run(["swiftc", "-O", str(TMP / "motion_film.swift"), "-o", str(FILM)], check=True, cwd=TMP)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(args.width)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP, "--args", "-NSAppSleepDisabled", "YES"],
                   check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    report = {}
    try:
        sv.cmd({"do": "resize", "width": 900, "height": 700, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        top = [rl.opened(i, n) for i, n in (("grey", "Weekend plans"), ("blue", "Mobile Sync"))]
        sup = [rl.opened(i, n) for i, n in (("red", "otterbase"), ("black", "Public preview is open"))]
        mid = [rl.opened("orange", "Google Meet")]
        rea = [rl.opened(i, n) for i, n in (("green", "Sheets"), ("violet", "My issues"))]
        end = [rl.opened("black", "Sign in to Octo Corp")]
        time.sleep(2)
        made = {i[:8].lower() for i in top + sup + mid + rea + end}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        sv.cmd({"do": "group", "id": sup[0][:8].lower(), "new": True, "name": "Otterbase"})
        sv.cmd({"do": "group", "id": sup[1][:8].lower(), "name": "Otterbase"})
        sv.cmd({"do": "group", "id": rea[0][:8].lower(), "new": True, "name": "Reading"})
        sv.cmd({"do": "group", "id": rea[1][:8].lower(), "name": "Reading"})
        sv.sp("select", id=end[0])
        time.sleep(0.6)
        sv.cmd({"do": "group", "name": "Reading", "fold": True})
        time.sleep(1.2)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        rows = sv.cmd({"do": "rowframes"})["rows"]
        bottom = max(f[1] + f[3] for f in rows.values() if f[3] > 0)
        report["rows"] = rows
        report["icons"] = sv.cmd({"do": "rowframes"})["icons"]
        height = min(690, bottom + 12)
        for theme, ground in SCENES if args.stills == "1" else []:
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "space", "action": "look", **LOOKS[ground]})
            sv.cmd({"do": "ui", "windowPointer": [800, 600], "pointerPhase": "move"})
            time.sleep(1.2)
            name = f"{theme}-{ground}"
            raw = TMP / f"{name}-raw.png"
            still = TMP / f"{name}.png"
            rl.shoot(pid, number, raw)
            srgb(raw, still)
            k = max(1, round(size_of(still)[0] / 900))
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                            f"crop={int(args.width * k)}:{int(height * k)}:0:0", str(OUT / f"{name}.png")], check=True)
            t.ok(f"pictured {name}", (OUT / f"{name}.png").exists())
        if args.films == "1":
            first = rows.get(sup[0][:8].lower())
            crop = [0, first[1] - 40, 150, 200] if first else [0, 0, 150, 300]

            def fold(*again):
                return lambda: sv.cmd({"do": "group", "name": "Otterbase", "fold": True, "again": list(again)})
            takes = [("shut", fold()), ("open", fold()), ("reverse-10", fold(0.013)), ("reverse-50", fold(0.043)),
                     ("reverse-90", fold(0.099)), ("double", fold(0.043, 0.043))]
            for theme, ground in (("dark", "near"), ("light", "pale")):
                sv.cmd({"do": "ui", "look": theme})
                sv.cmd({"do": "space", "action": "look", **LOOKS[ground]})
                time.sleep(1.0)
                for name, act in takes if theme == "dark" else takes[:2] + takes[3:4]:
                    if args.takes and name not in args.takes.split(","):
                        continue
                    report[f"{theme}-{name}"] = film(pid, f"{theme}-{name}", 1.4, act, crop)
                    time.sleep(0.6)
                    if name == "double":
                        fold()()
                        time.sleep(0.8)
        (OUT / "measure.json").write_text(json.dumps(report, indent=1))
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

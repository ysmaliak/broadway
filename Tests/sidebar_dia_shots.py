#!/usr/bin/env python3
"""Broadway's column beside the user's Dia crop, at the same scale.

Build first (`./build.sh`), then
`python3 Tests/sidebar_dia_shots.py LABEL [--grounds near,vivid] [--themes dark,light] [--width 289]`.

Five pins, a live PRs folder read from pr_rows' fake GitHub (a signed-in page on ::1,
never the real site) with a PR selected, loose tabs, a plain folder among
them and New Tab held at the bottom, like .context/dia.png. Window-only
stills of a test copy (capture tools built in /tmp); the column is cut out
and stacked beside the Dia crop (converted to sRGB) into
.context/sidebar-dia/LABEL/. measure.json holds Broadway's levels sampled where
the Dia levels were read: ground, tile fill and rim, card fill and rim,
selected well and ring, hover, the separator and the row geometry.
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
parser.add_argument("--width", type=float, default=289)
parser.add_argument("--grounds", default="near,vivid")
parser.add_argument("--themes", default="dark,light")
parser.add_argument("--near", default="000000")
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("side-dia-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
TMP = Path("/tmp") / f"broadway-side-dia-{os.getpid()}"
OUT = ROOT / ".context" / "sidebar-dia" / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"

LOOKS = {
    "near": {"custom": args.near, "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
}
PINS = [("black", "GitHub"), ("black", "GitHub two"), ("green", "Sheets"), ("orange", "Meet"), ("blue", "Calendar")]
LOOSE = [("grey", "Weekly review - November 6"), ("grey", "Weekly review - November 5"), ("blue", "Mobile Sync"),
         ("black", "Wide Layout Pass"), ("grey", "Weekly review - November 3"), ("violet", "My issues › Assigned")]
FOLDER = [("red", "otterbase"), ("black", "Public preview is open")]
AFTER = [("red", "team rocket"), ("orange", "Google Meet"), ("black", "Sign in to Octo Corp")]


def look(name):
    sv.cmd({"do": "space", "action": "look", **LOOKS[name]})


def size_of(still):
    said = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(still)], capture_output=True, text=True).stdout.split()
    return int(said[said.index("pixelWidth:") + 1]), int(said[said.index("pixelHeight:") + 1])


def srgb(still, out):
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(still), "--out", str(out)],
                   capture_output=True, check=True)


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
    dia = TMP / "dia.png"
    srgb(ROOT / ".context" / "dia.png", dia)
    sv.setup(spaces=True, **{"start.fresh": False, "live.on": True, "welcome.show": False, "tabs.newAtBottom": True})
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
    report = {}
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 1000, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        pins = [rl.opened(icon, title) for icon, title in PINS]
        loose = [rl.opened(icon, title) for icon, title in LOOSE]
        folder = [rl.opened(icon, title) for icon, title in FOLDER]
        after = [rl.opened(icon, title) for icon, title in AFTER]
        time.sleep(2)
        made = {i[:8].lower() for i in pins + loose + folder + after}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": folder[0][:8].lower(), "new": True, "name": "Otterbase"})
        sv.cmd({"do": "group", "id": folder[1][:8].lower(), "name": "Otterbase"})
        pr.live("add-page", "Pull Requests", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
        pr.live("unfold", "Pull Requests")
        prs = pr.folder(pr.live("update", "Pull Requests"), "Pull Requests")
        ids = [tab["id"] for tab in prs["tabs"]]
        t.ok("the PR folder has rows", len(ids) >= 2, prs)
        sv.sp("select", id=ids[0])
        time.sleep(0.8)
        pr.live("stack")
        time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        frames = sv.cmd({"do": "rowframes"})["rows"]
        bottom = max((f[1] + f[3] for f in frames.values()), default=900)
        width = args.width + 6
        height = min(990, bottom + 60)
        diaw, diah = size_of(dia)
        for theme in args.themes.split(","):
            for ground in args.grounds.split(","):
                if theme == "light" and ground == "near":
                    ground = "pale"
                sv.cmd({"do": "ui", "look": theme})
                look(ground)
                sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
                time.sleep(1.2)
                sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": True})
                time.sleep(0.7)
                name = f"{theme}-{ground}"
                raw = TMP / f"{name}-raw.png"
                still = TMP / f"{name}.png"
                rl.shoot(pid, number, raw)
                srgb(raw, still)
                k = max(1, round(size_of(still)[0] / 1000))
                got = sv.cmd({"do": "rowframes"})
                rows = got["rows"]
                column = OUT / f"{name}-broadway.png"
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                                f"crop={int(width * k)}:{int(height * k)}:0:0", str(column)], check=True)
                pair = OUT / f"{name}-beside-dia.png"
                cw, ch = size_of(column)
                tall = max(ch, diah)
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(column), "-i", str(dia), "-filter_complex",
                                f"[0]pad={cw + 24}:{tall}:0:0:color=0x808080[a];[1]pad={diaw}:{tall}:0:0:color=0x808080[b];[a][b]hstack=inputs=2",
                                str(pair)], check=True)
                tile = rows.get(pins[2][:8].lower())
                picked = rows.get(ids[0][:8].lower())
                plain = rows.get(loose[0][:8].lower())
                hovered = rows.get(loose[2][:8].lower())
                inner = rows.get(folder[0][:8].lower())

                def at(x, y):
                    return rl.pixels(still, [(round(x * k), round(y * k))])[0]

                def down(x, top, bottom):
                    return rl.trace(still, x, top, bottom)

                m = {"scale": k, "frames": {"tile": tile, "picked": picked, "plain": plain, "hovered": hovered, "inner": inner},
                     "icons": {n: got["icons"].get(i[:8].lower()) for n, i in (("picked", ids[0]), ("plain", loose[0]), ("inner", folder[0]))}}
                if tile:
                    m["ground"] = at(tile[0] - 1.5, tile[1] + tile[3] + 2)
                    m["tile"] = at(tile[0] + 4, tile[1] + tile[3] / 2)
                    m["tile_trace"] = down(tile[0] + tile[2] / 2 + 12, tile[1] - 2, tile[1] + tile[3] + 2)
                if picked:
                    m["well"] = at(picked[0] + picked[2] - 6, picked[1] + picked[3] / 2)
                    m["well_trace"] = down(picked[0] + picked[2] - 6, picked[1] - 14, picked[1] + picked[3] + 14)
                    m["card_beside"] = at(picked[0] - 2, picked[1] - 10)
                if plain:
                    m["row"] = at(plain[0] + 3, plain[1] + plain[3] / 2)
                if hovered:
                    m["hover"] = at(hovered[0] + 3, hovered[1] + hovered[3] / 2)
                if inner:
                    m["card_trace"] = down(inner[0] + inner[2] - 20, inner[1] - 50, inner[1] + inner[3] + 14)
                report[name] = m
                sv.cmd({"do": "rowhover", "id": loose[2][:8], "on": False})
                t.ok(f"pictured {name}", pair.exists())
        if "dark" in args.themes:
            sv.cmd({"do": "ui", "look": "dark"})
            look("near")
            sv.sp("select", id=loose[3])
            sv.cmd({"do": "group", "name": "Otterbase", "fold": True})
            time.sleep(1.5)
            raw = TMP / "loose-raw.png"
            still = TMP / "loose.png"
            rl.shoot(pid, number, raw)
            srgb(raw, still)
            k = max(1, round(size_of(still)[0] / 1000))
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                            f"crop={int(width * k)}:{int(height * k)}:0:0", str(OUT / "dark-near-loose-selected-folded.png")], check=True)
            got = sv.cmd({"do": "rowframes"})["rows"].get(loose[3][:8].lower())
            if got:
                report["loose_selected"] = {"frame": got, "well": rl.pixels(still, [(round((got[0] + got[2] - 6) * k), round((got[1] + got[3] / 2) * k))])[0],
                                            "trace": rl.trace(still, got[0] + got[2] - 6, got[1] - 14, got[1] + got[3] + 14)}
            t.ok("pictured a selected loose row and a folded folder", (OUT / "dark-near-loose-selected-folded.png").exists())
        (OUT / "measure.json").write_text(json.dumps(report, indent=1))
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The sidebar's three parts in one rich world, pictured on every ground.

Build first (`./build.sh`), then
`python3 Tests/sidebar_style_shots.py LABEL [--width 258] [--style name] [--grounds a,b] [--themes dark,light]`.
BROADWAY_PROBE_APP runs it against another build (a copy of an earlier ./build.sh).

Six pins (colour squares and a monochrome ring mark, one playing), a plain
folder of two, a live PRs folder read from pr_rows' fake GitHub (a stack,
bylines, checks), a folded folder and nine loose tabs: one selected, one
hovered, one loading (its page never finishes) and one playing. Grounds:
pale F2EEE6, vivid 3139FB, deep 171616 and glass, light and dark. With
--style the world launches with `sidebar.style` set (a test-only switch
between design directions). Window-only stills of the test copy are taken
by a capture tool built in /tmp and written to /tmp, then the column is
cropped into .context/sidebar-style/LABEL/, with a sheet per theme.
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="now")
parser.add_argument("--width", type=float, default=258)
parser.add_argument("--style", default="")
parser.add_argument("--grounds", default="pale,vivid,deep,glass")
parser.add_argument("--themes", default="dark,light")
parser.add_argument("--pinlive", action="store_true")
parser.add_argument("--pins", type=int, default=5)
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("side-style-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
TMP = Path("/tmp") / f"broadway-side-style-{os.getpid()}"
OUT = ROOT / ".context" / "sidebar-style" / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"

LOOKS = {
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "deep": {"custom": "171616", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "glass": {"colour": "gray", "intensity": 0.5, "glass": True, "transparency": 0.5, "grain": 0},
}
PINS = [("ring", "GitHub"), ("orange", "Hacker News"), ("blue", "Calendar"), ("red", "YouTube"), ("green", "Sheets"),
        ("black", "Notes"), ("violet", "Figma")][:args.pins]
DESIGN = [("violet", "Figma: Broadway sidebar"), ("teal", "Type scale notes")]
READING = [("grey", "Weekly review"), ("blue", "Long read")]
LOOSE = [("violet", "Orbit Dashboard"), ("orange", "Fernwood — weekly numbers"), ("black", "Promo Kit"),
         ("blue", "Browser - Wikipedia"), ("slow", "Loading a slow page"), ("red", "Lo-fi beats to code to"),
         ("teal", "Linear – My issues › Assigned"), ("green", "Apple"), ("grey", "A very long title that has to fade before the close button")]


class Slow(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        try:
            self.wfile.write(b"<!doctype html><meta charset=utf-8><title>Loading a slow page</title><p>")
            self.wfile.flush()
            time.sleep(600)
        except OSError:
            pass

    def log_message(self, *a):
        pass


slow = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
slow.daemon_threads = True
threading.Thread(target=slow.serve_forever, daemon=True).start()


def opened(icon, title):
    if icon == "slow":
        id = sv.sp("open", url=f"http://127.0.0.1:{slow.server_port}/slow")["resultID"]
    elif icon == "ring":
        id = sv.sp("open", url=f"{pr.BASE}/home?{title}")["resultID"]
    else:
        return rl.opened(icon, title)
    time.sleep(0.3)
    return id


def look(name):
    sv.cmd({"do": "space", "action": "look", **LOOKS[name]})


def size_of(still):
    said = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(still)], capture_output=True, text=True).stdout.split()
    return int(said[said.index("pixelWidth:") + 1]), int(said[said.index("pixelHeight:") + 1])


def cut(still, path, width, height):
    w, h = size_of(still)
    k = max(1, round(w / 1000))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                    f"crop={min(w, int(width * k))}:{min(h, int(height * k))}:0:0", str(path)], check=True)


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
    sv.setup(spaces=True, **{"start.fresh": False, "live.on": True, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(args.width)], check=True)
    if args.style:
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.style", "-string", args.style], check=True)
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
        sv.cmd({"do": "resize", "width": 1000, "height": 1080, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        pins = [opened(icon, title) for icon, title in PINS]
        design = [opened(icon, title) for icon, title in DESIGN]
        design_ids = design
        reading = [opened(icon, title) for icon, title in READING]
        loose = [opened(icon, title) for icon, title in LOOSE]
        time.sleep(2)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": design[0][:8].lower(), "new": True, "name": "Design"})
        sv.cmd({"do": "group", "id": design[1][:8].lower(), "name": "Design"})
        sv.cmd({"do": "group", "id": reading[0][:8].lower(), "new": True, "name": "Reading"})
        sv.cmd({"do": "group", "id": reading[1][:8].lower(), "name": "Reading"})
        sv.cmd({"do": "group", "name": "Reading", "fold": True})
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
        pr.live("unfold", "PRs")
        pr.live("update", "PRs")
        pr.live("add-page", "Reviews", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+review-requested%3A%40me")
        pr.live("update", "Reviews")
        for id in (pins[3], loose[5]):
            sv.sp("select", id=id)
            time.sleep(0.4)
            sv.cmd({"do": "ui", "noisy": True})
        sv.sp("select", id=pins[1] if args.pinlive else loose[3])
        for id in (loose[6], loose[0]):
            sv.cmd({"do": "ui", "unread": id[:8]})
        time.sleep(2)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        frames = sv.cmd({"do": "rowframes"})["rows"]
        t.ok("the rows are laid out", len(frames) >= len(PINS) + len(LOOSE), frames)
        bottom = max((f[1] + f[3] for f in frames.values()), default=900)
        height = min(1060, bottom + 60)
        crop = args.width + 14
        sheets = {}
        report = {}

        def sample(still, box, dx):
            x = box[0] + dx if dx >= 0 else box[0] + box[2] + dx
            return rl.pixels(still, [(x, box[1] + box[3] / 2)])[0]

        def measure(still):
            got = sv.cmd({"do": "rowframes"})["rows"]
            pin, hover, picked, plain = (got.get(i[:8].lower()) for i in (pins[0], loose[1], loose[3], loose[2]))
            out = {}
            if pin:
                out["ground"] = rl.pixels(still, [(3, pin[1] + pin[3] + 3)])[0]
                out["tile"] = sample(still, pin, 5)
                out["pinframe"] = pin
            if plain:
                out["row"] = sample(still, plain, 4)
            if hover:
                out["hover"] = sample(still, hover, 4)
            if picked:
                out["selected"] = sample(still, picked, 4)
                out["selectedframe"] = picked
            design = got.get(design_ids[0][:8].lower())
            if design:
                out["card"] = rl.pixels(still, [(design[0] - 2, design[1] + design[3] / 2)])[0]
            return out
        for theme in args.themes.split(","):
            for ground in args.grounds.split(","):
                sv.cmd({"do": "ui", "look": theme})
                look(ground)
                sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
                time.sleep(1.2)
                sv.cmd({"do": "rowhover", "id": loose[1][:8], "on": True})
                time.sleep(0.7)
                name = f"{theme}-{ground}"
                still = TMP / f"{name}.png"
                rl.shoot(pid, number, still)
                cutout = OUT / f"{name}.png"
                cut(still, cutout, crop, height)
                report[name] = measure(still)
                sheets.setdefault(theme, []).append(cutout)
                if (theme, ground) in (("dark", "deep"), ("light", "pale")):
                    sv.cmd({"do": "rowpress", "id": loose[1][:8], "down": True})
                    time.sleep(0.4)
                    rl.shoot(pid, number, TMP / "pressed.png")
                    cut(TMP / "pressed.png", OUT / f"{name}-pressed.png", crop, height)
                    sv.cmd({"do": "rowpress", "id": loose[1][:8], "down": False})
                sv.cmd({"do": "rowhover", "id": loose[1][:8], "on": False})
                t.ok(f"pictured {name}", cutout.exists())
        (OUT / "measure.json").write_text(json.dumps(report, indent=1))
        for theme, cuts in sheets.items():
            sheet = OUT / f"sheet-{theme}.png"
            inputs = sum([["-i", str(c)] for c in cuts], [])
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                            f"hstack=inputs={len(cuts)}" if len(cuts) > 1 else "null", str(sheet)], check=True)
            print(sheet)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        slow.shutdown()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

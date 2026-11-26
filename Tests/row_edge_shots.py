#!/usr/bin/env python3
"""How close a tab's title runs to the row's end, pictured and measured.

Build first (`./build.sh`), then
`python3 Tests/row_edge_shots.py LABEL [--width 258] [--themes dark,light] [--film] [--old] [--reduced] [--stacked] [--address] [--right]`.
BROADWAY_PROBE_APP runs it against another build.

A shown test copy in a world of its own: three pins, a folder of two, a live
PRs folder read from pr_rows' fake GitHub and eleven loose tabs with long
titles, one short, one unseen, one loading, one playing, one selected and a
Split View pair. The column is pictured at rest, with a row under the
pointer, with the selected row under it and with a live row under it, light
and dark, from the test copy's own window by its number. Each picture comes
with the numbers the rows report: where each title's ink stops being whole
and where it ends, from the row's end. With --film the pointer coming over a
row, leaving it and running down the column are filmed and laid out frame by
frame. Everything lands in .context/shots/LABEL/.

Without --old the numbers are held to the rule: at rest a long title is
whole to the fade's width before the close square's far edge and gone at that
edge, under the pointer it is gone two points before the close button, a
title that ends ten points before the row's end is whole, and in no filmed
frame does the close button come in over the title's ink.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="now")
parser.add_argument("--width", type=float, default=258)
parser.add_argument("--themes", default="dark,light")
parser.add_argument("--film", action="store_true")
parser.add_argument("--old", action="store_true")
parser.add_argument("--reduced", action="store_true")
parser.add_argument("--stacked", action="store_true")
parser.add_argument("--address", action="store_true")
parser.add_argument("--right", action="store_true")
parser.add_argument("--env", action="append", default=[])
args = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("row-edge-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
TMP = Path("/tmp") / f"broadway-row-edge-{os.getpid()}"
OUT = ROOT / ".context" / "shots" / args.label
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"
CAPTURE = TMP / "capture"
TOKENS = (ROOT / "Sources/Search/Kit/Tokens.swift").read_text()
ROW = float(re.search(r"static let sideRowHeight: CGFloat = (\d+)", TOKENS).group(1))
LINE = float(re.search(r"static let titleLine: CGFloat = (\d+)", TOKENS).group(1))
SQUARE = max(18, min(34, ROW - 8))
INSET = (ROW - SQUARE) / 2
WHOLE = 10

PINS = [("black", "Notes"), ("orange", "Hacker News"), ("blue", "Calendar")]
DESIGN = [("violet", "Figma: Broadway sidebar, rows and the things at their ends, with the notes from the review beside them"), ("teal", "Type scale notes for the column and the field")]
LOOSE = [("violet", "Orbit Dashboard: weekly numbers for the whole team, with last quarter beside them for comparison"), ("orange", "Fernwood quarterly planning notes and open questions, as they stood after the last review"),
         ("black", "Promo Kit"), ("blue", "Browser - Wikipedia, the free encyclopedia that anyone can edit, in its long form with every section open"), ("slow", "Loading a slow page that never ends"),
         ("red", "Lo-fi beats to code to, a stream that runs all night"), ("teal", "Linear: My issues, assigned to me this cycle"),
         ("green", "Apple Developer Documentation: AppKit views, layers and the responder chain, on one long page"), ("grey", "A very long title that has to fade before the close button"),
         ("blue", "Release notes draft for the autumn update"), ("orange", "Changelog and migration guide for teams")]
UNSEEN, HOVER, SHORT, SELECTED, LOADING, PLAYING, PLAIN = 0, 1, 2, 3, 4, 5, 7


class Slow(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        try:
            self.wfile.write(b"<!doctype html><meta charset=utf-8><title>Loading a slow page that never ends</title><p>")
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
        time.sleep(0.3)
        return id
    return rl.opened(icon, title)


def rows():
    return sv.cmd({"do": "ui", "endtrace": {"action": "now"}})["rows"]


def row(id):
    return next((r for r in rows() if r["id"] == id[:8].lower() and r["interactive"]), None)


def ends(r):
    if not r or len(r["model"]) != 2:
        return None
    ink = r["x"] + r["natural"]
    return {"width": r["width"], "titleFrom": r["x"], "titleRoomEnds": round(r["width"] - r["x"] - r["room"], 2),
            "inkEnds": round(r["width"] - ink, 2), "wholeTo": round(r["width"] - min(ink, r["model"][0]), 2),
            "goneAt": round(r["width"] - min(ink, r["model"][1]), 2), "fades": ink > r["model"][0] + 0.5,
            "cross": round(r["cross"], 2), "dot": round(r["dot"], 2), "talk": round(r["talk"], 2)}


def hover(id, on):
    sv.cmd({"do": "rowhover", "id": id[:8], "on": on})


def size_of(still):
    said = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(still)], capture_output=True, text=True).stdout.split()
    return int(said[said.index("pixelWidth:") + 1]), int(said[said.index("pixelHeight:") + 1])


def cut(still, path, box, zoom=1):
    w, h = size_of(still)
    k = max(1, round(w / 1000))
    x, y, wide, tall = (int(v * k) for v in box)
    wide, tall = min(wide, w - x), min(tall, h - y)
    scale = f",scale=iw*{zoom}:ih*{zoom}:flags=neighbor" if zoom != 1 else ""
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", f"crop={wide}:{tall}:{x}:{y}{scale}", str(path)],
                   check=True, stdin=subprocess.DEVNULL)
    return k


def side_by_side(paths, sheet):
    inputs = sum([["-i", str(p)] for p in paths], [])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                    f"hstack=inputs={len(paths)}" if len(paths) > 1 else "null", str(sheet)], check=True, stdin=subprocess.DEVNULL)


def film(name, pid, number, scale, act, box, seconds=0.7, span=0.34, columns=6, zoom=2):
    folder = TMP / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds + 0.5), str(number), str(scale), "60"],
                         stdout=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL)
    for _ in range(300):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.2)
    sv.cmd({"do": "ui", "endtrace": {"action": "start"}})
    act()
    time.sleep(seconds)
    samples = sv.cmd({"do": "ui", "endtrace": {"action": "stop"}})["samples"]
    print("  ", name, p.communicate()[0].strip(), flush=True)
    frames = sorted(folder.glob("0*.png"))
    if len(frames) < 4:
        return samples, 0
    times = json.loads((folder / "times.json").read_text())
    x, y, wide, tall = (int(v * scale) for v in box)
    crop = f"crop={wide}:{tall}:{x}:{y}"
    raw = lambda f: subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(f), "-vf", crop, "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                   capture_output=True, stdin=subprocess.DEVNULL).stdout
    first = raw(frames[1])
    start = next((i for i in range(2, len(frames)) if raw(frames[i]) != first), 2)
    start = max(0, start - 1)
    picked = [i for i in range(start, len(frames)) if times[i] - times[start] <= span]
    work = folder / "sheet"
    work.mkdir()
    for n, i in enumerate(picked):
        os.symlink(frames[i], work / f"{n:04d}.png")
    lines = (len(picked) + columns - 1) // columns
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"{crop},scale=iw*{zoom}:ih*{zoom}:flags=neighbor,tile={columns}x{lines}:padding=4:color=red",
                    "-frames:v", "1", str(OUT / f"{name}.png")], check=False, stdin=subprocess.DEVNULL)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", f"{crop},scale=iw*2:ih*2:flags=neighbor,pad=ceil(iw/2)*2:ceil(ih/2)*2", "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")],
                   check=False, stdin=subprocess.DEVNULL)
    shutil.rmtree(folder, ignore_errors=True)
    return samples, len(picked)


def swept(samples, id):
    places = []
    for sample in samples:
        for r in sample["rows"]:
            if r["id"] == id[:8].lower() and r["interactive"] and len(r["shown"]) == 2:
                places.append(round(r["shown"][1], 1))
    return places


def crossed(samples):
    over = 0
    for sample in samples:
        for r in sample["rows"]:
            if not r["interactive"] or not r["seen"] or not r["titled"] or len(r["shown"]) != 2 or r["cross"] < 0.02:
                continue
            if min(r["x"] + r["natural"], r["shown"][1]) > r["crossLeft"] + 0.5:
                over += 1
    return over


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
    if args.film:
        shutil.copy(ROOT / "Tests/WindowCapture.swift", TMP / "WindowCapture.swift")
        subprocess.run(["swiftc", "-parse-as-library", str(TMP / "WindowCapture.swift"), "-o", str(CAPTURE)], check=True, cwd=TMP)
    prefs = {"start.fresh": False, "live.on": True, "welcome.show": False, "sidebar": True}
    if args.reduced:
        prefs["motion.testReduced"] = True
    sv.setup(spaces=True, **prefs)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(args.width)], check=True)
    if args.right:
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.position", "right"], check=True)
    before = sv.running()
    extra = sum([["--env", e] for e in args.env], [])
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", *extra, sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    report = {"width": args.width, "states": {}, "films": {}}
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 1080, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        pins = [opened(icon, title) for icon, title in PINS]
        design = [opened(icon, title) for icon, title in DESIGN]
        loose = [opened(icon, title) for icon, title in LOOSE]
        time.sleep(2)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": design[0][:8].lower(), "new": True, "name": "Design"})
        sv.cmd({"do": "group", "id": design[1][:8].lower(), "name": "Design"})
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
        pr.live("unfold", "PRs")
        prs = pr.folder(pr.live("update", "PRs"), "PRs")
        live = [tab["id"] for tab in (prs or {}).get("tabs", [])]
        sv.sp("pair", id=loose[10], **{"with": loose[9]}, side="right")
        time.sleep(0.6)
        sv.sp("select", id=loose[PLAYING])
        time.sleep(0.4)
        sv.cmd({"do": "ui", "noisy": True})
        sv.sp("select", id=loose[SELECTED])
        sv.cmd({"do": "ui", "unread": loose[UNSEEN][:8]})
        if args.stacked:
            sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
        if args.address:
            sv.cmd({"do": "ui", "address": True})
        time.sleep(2)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(1)
        frames = sv.cmd({"do": "rowframes"})["rows"]
        t.ok("the rows are laid out", len(frames) >= len(LOOSE) - 2, frames)
        bottom = max((f[1] + f[3] for f in frames.values()), default=900)
        height = min(1060, bottom + 60)
        crop = args.width + 14
        first = frames.get(loose[0][:8].lower()) or [0, 300, crop, ROW]
        last = frames.get(loose[8][:8].lower()) or [0, 700, crop, ROW]
        shift = max(0, first[0] - 20) if args.right else 0
        band = [shift, first[1] - 6, crop, last[1] + last[3] - first[1] + 12]
        tail = [shift + args.width - 148, band[1], 150, band[3]]
        under = frames.get(loose[HOVER][:8].lower()) or first
        near = [shift + args.width - 188, under[1] - ROW - 4, 190, 3 * ROW + 12]
        states = [("rest", None), ("hover", loose[HOVER]), ("selected-hover", loose[SELECTED])] + ([("live-hover", live[0])] if live else [])
        scale = 1
        for theme in args.themes.split(","):
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
            time.sleep(1.2)
            cuts, zooms = [], []
            for state, target in states:
                if target:
                    hover(target, True)
                time.sleep(0.7)
                still = TMP / f"{theme}-{state}.png"
                rl.shoot(pid, number, still)
                scale = cut(still, OUT / f"{theme}-{state}.png", [shift, 0, crop, height])
                cut(still, OUT / f"{theme}-{state}-ends.png", tail, zoom=3)
                cuts.append(OUT / f"{theme}-{state}.png")
                zooms.append(OUT / f"{theme}-{state}-ends.png")
                picked = {"unseen": loose[UNSEEN], "hover": loose[HOVER], "short": loose[SHORT], "selected": loose[SELECTED],
                          "loading": loose[LOADING], "playing": loose[PLAYING], "plain": loose[PLAIN], "folder": design[0]}
                if live:
                    picked["live"] = live[0]
                report["states"][f"{theme}-{state}"] = {name: ends(row(id)) for name, id in picked.items()}
                if target:
                    hover(target, False)
                    time.sleep(0.4)
                t.ok(f"pictured {theme} {state}", (OUT / f"{theme}-{state}.png").exists())
            side_by_side(cuts, OUT / f"sheet-{theme}.png")
            side_by_side(zooms, OUT / f"sheet-{theme}-ends.png")
            if args.film:
                run = [loose[i] for i in (0, 1, 2, 3, 5, 6, 7, 8)]

                def down():
                    for a, b in zip([None] + run, run + [None]):
                        if a:
                            hover(a, False)
                        if b:
                            hover(b, True)
                        time.sleep(0.07)
                samples, n = film(f"film-{theme}-hover-in", pid, number, scale, lambda: hover(loose[HOVER], True), near)
                report["films"][f"{theme}-hover-in"] = {"frames": n, "goneAt": swept(samples, loose[HOVER]), "crossOverInk": crossed(samples)}
                samples, n = film(f"film-{theme}-hover-out", pid, number, scale, lambda: hover(loose[HOVER], False), near)
                report["films"][f"{theme}-hover-out"] = {"frames": n, "goneAt": swept(samples, loose[HOVER]), "crossOverInk": crossed(samples)}
                samples, n = film(f"film-{theme}-run-down", pid, number, scale, down, tail, seconds=1.1, span=0.9, columns=9, zoom=1)
                report["films"][f"{theme}-run-down"] = {"frames": n, "crossOverInk": crossed(samples)}
        (OUT / "measure.json").write_text(json.dumps(report, indent=1))
        said = report["states"]
        first_theme = args.themes.split(",")[0]
        rest, over = said[f"{first_theme}-rest"], said[f"{first_theme}-hover"]
        print("  at rest", json.dumps(rest["plain"]), flush=True)
        print("  hovered", json.dumps(over["hover"]), flush=True)
        print("  selected", json.dumps(rest["selected"]), flush=True)
        if not args.old:
            close = SQUARE + INSET
            t.ok("at rest a long title is gone at the close square's far edge", abs(rest["plain"]["goneAt"] - INSET) < 0.6, rest["plain"])
            t.ok("at rest it is whole to one line's height before that", abs(rest["plain"]["wholeTo"] - INSET - LINE) < 0.6, rest["plain"])
            t.ok("the selected row at rest ends the same way", abs(rest["selected"]["goneAt"] - (WHOLE if args.address else INSET)) < 0.6, rest["selected"])
            t.ok("a row in a folder ends the same way", abs(rest["folder"]["goneAt"] - INSET) < 0.6, rest["folder"])
            t.ok("a short title is whole and ends before the row's pad", not rest["short"]["fades"] and rest["short"]["inkEnds"] >= WHOLE, rest["short"])
            t.ok("under the pointer it is gone two points before the close button", abs(over["hover"]["goneAt"] - close - 2) < 0.6, over["hover"])
            t.ok("under the pointer it is whole to one line's height before that", abs(over["hover"]["wholeTo"] - close - 2 - LINE) < 0.6, over["hover"])
            t.ok("the unseen row rests where a row under the pointer rests", abs(rest["unseen"]["goneAt"] - close - 2) < 0.6, rest["unseen"])
            t.ok("the pointer over one row leaves the others at rest", abs(over["plain"]["goneAt"] - INSET) < 0.6, over["plain"])
            pointed = said[f"{first_theme}-selected-hover"]["selected"]
            t.ok("the selected row under the pointer gives way the same", abs(pointed["goneAt"] - close - 2) < 0.6, pointed)
            if args.film and not args.reduced:
                seen = report["films"][f"{first_theme}-hover-in"]["goneAt"]
                between = [v for v in seen if min(seen) + 0.5 < v < max(seen) - 0.5]
                t.ok("the fade is seen sliding, not jumping, as the pointer comes", len(between) >= 2, seen[:40])
                over = {name: f["crossOverInk"] for name, f in report["films"].items() if not name.endswith("hover-out")}
                t.ok("in no frame does the close button come over the title's ink", not any(over.values()), over)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        slow.shutdown()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

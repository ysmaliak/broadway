#!/usr/bin/env python3
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-mini-time")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/mini-time")
REDUCED = os.environ.get("MINI_REDUCED") == "1"
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"mini-time-{os.getpid()}"
WINDOW = [0]
SIZE = [1100, 720]
WIDTHS = (245, 182)
NOIR = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45, "glass": False}
SONG = {"title": "Did you know that there's a tunnel under Ocean Blvd", "detail": "Lana Del Rey", "site": "music.example",
        "art": "cool", "playing": True, "pair": "tracks", "time": 83, "duration": 285, "rate": 1, "speed": False, "muted": False}
BOOK = {"title": "Chapter 7: The Long Way Round", "detail": "A Reader", "site": "books.example", "art": "warm",
        "playing": True, "pair": "seconds", "time": 3725, "duration": 10800, "rate": 1, "speed": True, "muted": False}
FIXED = dict(SONG, seekable=False)
t = sv.T()


def mini(action="state", *values):
    return sv.cmd({"do": "mini", "action": action, "values": [str(v) for v in values]})


def view():
    return mini().get("view") or {}


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": SIZE})["window"]
    time.sleep(0.6)


def put(item):
    mini("stage", json.dumps(item))
    time.sleep(0.5)


def card_box(above=64, below=52):
    state = view()
    scale = state.get("scale", 2)
    column = state.get("column") or [0, 0, 300, 720]
    card = state.get("cardInWindow") or [0, 0, 300, 120]
    top = max(0, card[1] - above)
    bottom = min(column[1] + column[3], card[1] + card[3] + below)
    return [int(column[0] * scale), int(top * scale), int(column[2] * scale), int((bottom - top) * scale)], column, card, scale


def shoot(name):
    whole = TMP / f"{name}-whole.png"
    for _ in range(5):
        took = subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(whole)], capture_output=True, text=True)
        if whole.exists():
            break
        time.sleep(1)
    if not whole.exists():
        t.ok(f"{name} pictured", False, took.stderr.strip())
        return
    (x, y, w, h), _, _, _ = card_box()
    path = OUT / f"{name}.png"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(whole), "-vf", f"crop={w}:{h}:{x}:{y}", str(path)], capture_output=True)
    whole.unlink()
    t.ok(f"{name} pictured", path.exists())


def film(name, act, seconds=0.9):
    folder = TMP / name
    shutil.rmtree(folder, ignore_errors=True)
    _, column, card, scale = card_box()
    mini("film", "on")
    act()
    time.sleep(seconds)
    saved = mini("film", str(folder)).get("saved", 0)
    times = json.loads((folder / "times.json").read_text()) if (folder / "times.json").exists() else []
    if saved < 2:
        t.ok(f"[{name}] filmed", False, saved)
        return
    x, y = int((card[0] - column[0] - 2) * scale), int((card[1] - column[1] - 4) * scale)
    w, h = int((card[2] + 4) * scale), int((card[3] + 8) * scale)
    crop = f"crop={w}:{h}:{max(0, x)}:{max(0, y)}"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "60", "-i", str(folder / "%03d.png"),
                    "-vf", f"{crop},scale=iw*2:-2:flags=lanczos,format=yuv420p", str(OUT / f"{name}.mp4")], check=False)
    picks = list(range(min(saved, 16)))
    across = 2
    wide, high = w, h
    chain = "".join(f"[{k}]{crop}[v{k}];" for k in range(len(picks)))
    inputs = []
    for i in picks:
        inputs += ["-i", str(folder / f"{i:03d}.png")]
    layout = "|".join(f"{(k % across) * (wide + 8)}_{(k // across) * (high + 8)}" for k in range(len(picks)))
    made = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex",
                           chain + "".join(f"[v{k}]" for k in range(len(picks))) + f"xstack=inputs={len(picks)}:layout={layout}:fill=gray",
                           str(OUT / f"{name}.png")], capture_output=True, text=True)
    (OUT / f"{name}.txt").write_text("".join(f"{k + 1}: {round(times[i] * 1000)} ms\n" for k, i in enumerate(picks) if i < len(times)))
    t.ok(f"[{name}] filmed", (OUT / f"{name}.png").exists(), made.stderr.strip()[-200:])


def over(on=True):
    mini("linehover", *([] if on else ["off"]))


def settled(share, within=1.5):
    end = time.time() + within
    while time.time() < end:
        if view().get("timeShare", -1) == share:
            return True
        time.sleep(0.05)
    return False


def turns(values):
    signs = [1 if b > a + 1e-9 else -1 for a, b in zip(values, values[1:]) if abs(b - a) > 1e-9]
    return sum(1 for a, b in zip(signs, signs[1:]) if a != b)


def checks(tag):
    over(False)
    settled(0)
    over()
    t.ok(f"[{tag} in] the time has the line", settled(1), view().get("timeShare"))
    state = view()
    trace = state.get("swap") or []
    shares = [row[1] for row in trace]
    t.ok(f"[{tag} in] every frame traced", len(trace) >= (3 if REDUCED else 8), len(trace))
    t.ok(f"[{tag} in] it moves one way and ends whole", turns(shares) == 0 and shares and shares[-1] == 1, shares)
    gaps = [b[0] - a[0] for a, b in zip(trace, trace[1:])]
    t.ok(f"[{tag} in] no frame missed (gap under 34 ms)", gaps and max(gaps) < 0.034, [round(g * 1000) for g in gaps])
    lifts = [abs(row[2]) + abs(row[3]) for row in trace]
    if REDUCED:
        t.ok(f"[{tag} in] nothing travels with Reduce Motion", max(lifts) == 0, lifts)
        t.ok(f"[{tag} in] and one line fades into the other", all(abs(row[4] + row[5] - 1) < 1e-6 for row in trace), [(row[4], row[5]) for row in trace])
    else:
        t.ok(f"[{tag} in] the two lines are never over each other", all(min(row[4], row[5]) == 0 for row in trace), [(row[4], row[5]) for row in trace])
        t.ok(f"[{tag} in] the old line goes up and the new comes from below, a few points",
             all(row[2] <= 0 and row[3] >= 0 for row in trace) and 2 <= max(abs(row[3]) for row in trace) <= 6, [(row[2], row[3]) for row in trace])
    t.ok(f"[{tag} in] it says position and total", re.fullmatch(r"\d+:\d\d(:\d\d)? / \d+:\d\d(:\d\d)?", state.get("detail", "")), state.get("detail"))
    thick = [row[6] for row in trace]
    t.ok(f"[{tag} in] the line thickens over the same frames", turns(thick) == 0 and thick[-1] == 4 and (REDUCED or 2 < thick[len(thick) // 3] < 4), thick)

    before = (len(trace), state.get("detail"))
    time.sleep(2.2)
    later = view()
    t.ok(f"[{tag} tick] the seconds tick with no move", later.get("detail") != before[1] and len(later.get("swap") or []) == before[0]
         and later.get("timeShare") == 1, (before, later.get("detail"), len(later.get("swap") or [])))

    over(False)
    t.ok(f"[{tag} out] the second line is back", settled(0), view().get("timeShare"))
    state = view()
    trace = state.get("swap") or []
    shares = [row[1] for row in trace]
    t.ok(f"[{tag} out] it moves one way and ends gone", turns(shares) == 0 and shares and shares[-1] == 0, shares)
    if not REDUCED:
        t.ok(f"[{tag} out] the time goes up and the second line comes from below",
             all(row[3] <= 0 and row[2] >= 0 for row in trace), [(row[2], row[3]) for row in trace])
    t.ok(f"[{tag} out] the time is cleared and the line is whole", state.get("time") == "" and trace[-1][4] == 1 and trace[-1][5] == 0, (state.get("time"), trace[-1]))
    t.ok(f"[{tag} out] the second line says the artist", state.get("detail") in ("Lana Del Rey", "A Reader"), state.get("detail"))

    if not REDUCED:
        over()
        time.sleep(0.07)
        over(False)
        t.ok(f"[{tag} quick] in and out ends at rest", settled(0), view().get("timeShare"))
        trace = view().get("swap") or []
        shares = [row[1] for row in trace]
        steps = [abs(b - a) for a, b in zip(shares, shares[1:])]
        t.ok(f"[{tag} quick] it turns once, part of the way", turns(shares) == 1 and 0 < max(shares) < 1, shares)
        t.ok(f"[{tag} quick] no jump between frames", steps and max(steps) < 0.3, [round(s, 3) for s in steps])
        t.ok(f"[{tag} quick] the two lines are never over each other", all(min(row[4], row[5]) == 0 for row in trace),
             [(round(row[4], 2), round(row[5], 2)) for row in trace])
        jumps = [abs(b[2] - a[2]) + abs(b[3] - a[3]) for a, b in zip(trace, trace[1:])]
        t.ok(f"[{tag} quick] neither line jumps", max(jumps) < 2.5, [round(j, 2) for j in jumps])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    prefs = {}
    if REDUCED:
        prefs["motion.testReduced"] = True
    sv.setup(**prefs)
    sv.launch()
    suffix = "-reduced" if REDUCED else ""
    try:
        stage(True)
        for n in range(4):
            sv.cmd({"do": "open", "url": f"about:blank#{n}"})
        time.sleep(1)
        put(SONG)
        new = "swap" in view()

        def scene(look, width, dark, checked):
            stage(dark)
            tone = f"{look}-{width}-{'dark' if dark else 'light'}"
            for name, item in (("song", SONG), ("book", BOOK)):
                put(item)
                over(False)
                time.sleep(0.5)
                if name == "song" and not REDUCED:
                    shoot(f"{name}-{tone}-rest")
                put(item)
                over()
                time.sleep(0.6)
                shoot(f"{name}-{tone}-time{suffix}")
                over(False)
                time.sleep(0.5)
            if not new:
                return
            put(SONG)
            if checked:
                checks(tone)
            over(False)
            time.sleep(0.5)
            film(f"film-{tone}-in{suffix}", lambda: over())
            film(f"film-{tone}-out{suffix}", lambda: over(False))
            if not REDUCED:
                film(f"film-{tone}-quick{suffix}", lambda: (over(), time.sleep(0.07), over(False)))

        for width in WIDTHS:
            sv.cmd({"do": "ui", "sideWidth": width})
            time.sleep(0.6)
            scene("plain", width, False, width == 245)
        sv.cmd({"do": "space", "action": "look", **NOIR})
        time.sleep(0.8)
        for width in WIDTHS:
            sv.cmd({"do": "ui", "sideWidth": width})
            time.sleep(0.6)
            for dark in (True, False):
                scene("noir", width, dark, dark)
        if new:
            sv.cmd({"do": "ui", "sideWidth": 245})
            time.sleep(0.6)
            stage(True)
            put(FIXED)
            over(False)
            settled(0)
            over()
            t.ok("[fixed] a track that cannot be seeked shows its time too", settled(1) and re.fullmatch(r"\d+:\d\d / 4:45", view().get("detail", "")), view().get("detail"))
            t.ok("[fixed] and its line stays thin", view().get("lineThick") == 2, view().get("lineThick"))
            shoot(f"fixed-noir-245-dark-time{suffix}")
            over(False)
            sv.cmd({"do": "ui", "sideWidth": 200})
            time.sleep(0.6)
            put(SONG)
            over()
            t.ok("[200] where both numbers do not fit beside the artwork, the position stands alone", settled(1) and re.fullmatch(r"\d+:\d\d", view().get("detail", "")),
                 view().get("detail"))
            shoot(f"song-noir-200-dark-time{suffix}")
            over(False)
        mini("stage", "off")
    finally:
        sv.quit()
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


main()

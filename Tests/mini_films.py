#!/usr/bin/env python3
"""The mini player arriving, leaving and hidden from its menu, in a hidden probe
window (below the desktop), traced on every display frame by the card and
filmed by the app itself: while filming, each display frame the card draws
its column from its own layers (a window below the desktop gives the
screen recorder no frames). The checks run on a pass without filming.

Build first (`./build.sh`), then `python3 Tests/mini_films.py [OUT]`
(default .context/mini-better/films). The card is staged through the
bench, so no page plays. The trace holds, per frame, the time, the card's
room in the column, its opacity and the list's bottom edge: each has to
move one way only, every frame has to come, and the list's bottom has to
give up exactly the room the card takes. With MINI_REDUCED=1 the same runs
with Reduce Motion, where nothing travels.
"""
import json
import shutil
import math
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-mini-films")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/mini-better/films")
REDUCED = os.environ.get("MINI_REDUCED") == "1"
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"mini-films-{os.getpid()}"
HEIGHT = 720
CROP = 330
t = sv.T()

SONG = {"title": "Born To Fly", "detail": "A Singer", "site": "music.example", "art": "warm", "playing": True,
        "pair": "tracks", "time": 71, "duration": 285, "rate": 1, "speed": False, "muted": False}


def mini(action="state", *values):
    return sv.cmd({"do": "mini", "action": action, "values": [str(v) for v in values]})


def view():
    return mini().get("view") or {}


def film(name, act, seconds=1.2):
    folder = TMP / name
    shutil.rmtree(folder, ignore_errors=True)
    mini("film", "on")
    act()
    time.sleep(seconds)
    saved = mini("film", str(folder)).get("saved", 0)
    times = json.loads((folder / "times.json").read_text()) if (folder / "times.json").exists() else []
    if saved < 2:
        return {"error": f"{saved} pictures"}
    crop = f"crop=iw:min(ih\\,{CROP}*ih/{HEIGHT}):0:ih-min(ih\\,{CROP}*ih/{HEIGHT})"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "60", "-i", str(folder / "%03d.png"),
                    "-vf", f"{crop},format=yuv420p", str(OUT / f"{name}.mp4")], check=False)
    step = max(1, -(-saved // 24))
    picks = list(range(0, saved, step))
    rows = -(-len(picks) // 8)
    chain = "".join(f"[{k}]{crop},scale=260:-2,pad=260:340:0:0:color=gray[v{k}];" for k in range(len(picks)))
    inputs = []
    for i in picks:
        inputs += ["-i", str(folder / f"{i:03d}.png")]
    layout = "|".join(f"{(k % 8) * 260}_{(k // 8) * 340}" for k in range(len(picks)))
    sheet = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex",
                            chain + "".join(f"[v{k}]" for k in range(len(picks))) + f"xstack=inputs={len(picks)}:layout={layout}:fill=gray",
                            str(OUT / f"{name}.png")], capture_output=True, text=True)
    (OUT / f"{name}.txt").write_text("".join(f"{k + 1}: {round(times[i] * 1000)} ms\n" for k, i in enumerate(picks) if i < len(times)))
    print(f"  film {name}: {saved} pictures, a sheet of {len(picks)} in {rows} rows", sheet.stderr.strip()[-200:])
    return {"frames": saved}


def one_way(values):
    ups = sum(1 for a, b in zip(values, values[1:]) if b > a + 1e-6)
    downs = sum(1 for a, b in zip(values, values[1:]) if b < a - 1e-6)
    return ups == 0 or downs == 0


def fastest(response):
    return 2 * math.pi / response / math.e


SPRING = {"arrive": fastest(0.3), "leave": fastest(0.16), "close": fastest(0.16)}


def check(name, trace, room_goes_up):
    t.ok(f"[{name}] traced", len(trace) >= (2 if REDUCED else 8), len(trace))
    if len(trace) < 2:
        return
    times = [r[0] for r in trace]
    rooms = [r[1] for r in trace]
    shares = [r[2] for r in trace]
    bottoms = [r[3] for r in trace]
    t.ok(f"[{name}] the card's room moves one way", one_way(rooms), rooms)
    t.ok(f"[{name}] its opacity moves one way", one_way(shares), shares)
    t.ok(f"[{name}] the list's bottom moves one way", one_way(bottoms), bottoms)
    edge = [abs((b - bottoms[0]) + (r - rooms[0])) for r, b in zip(rooms, bottoms)]
    t.ok(f"[{name}] the list gives up exactly the card's room, frame by frame", max(edge) < 1.01, edge)
    gaps = [b - a for a, b in zip(times, times[1:])]
    t.ok(f"[{name}] no frame missed (gap under 34 ms)", max(gaps) < 0.034, [round(g * 1000) for g in gaps])
    if not REDUCED:
        whole = abs(rooms[-1] - rooms[0])
        over = [(round(abs(b - a), 1), round(SPRING[name] * whole * gap + 0.5, 1))
                for a, b, gap in zip(rooms, rooms[1:], gaps) if abs(b - a) > SPRING[name] * whole * gap * 1.05 + 0.5]
        t.ok(f"[{name}] no step larger than the spring allows for its frame", not over, over)
    if REDUCED:
        t.ok(f"[{name}] the room is set at once, only the card fades", len(set(rooms)) == 1 and (rooms[0] > 0) == room_goes_up, rooms)
    else:
        t.ok(f"[{name}] the room ends where it should", (rooms[-1] > rooms[0]) == room_goes_up, (rooms[0], rooms[-1]))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    sv.setup(**({"motion.testReduced": True} if REDUCED else {}))
    sv.launch()
    try:
        sv.cmd({"do": "agents", "action": "stage", "dark": True, "size": [1100, HEIGHT]})
        sv.cmd({"do": "agents", "action": "stage", "dark": True, "size": [1100, HEIGHT]})
        for n in range(8):
            sv.cmd({"do": "open", "url": f"about:blank#{n}"})
        time.sleep(1)
        suffix = "-reduced" if REDUCED else ""

        mini("stage", json.dumps(SONG))
        time.sleep(1)
        mini("stage", "off")
        time.sleep(1)
        mini("stage", json.dumps(SONG))
        time.sleep(1.2)
        check("arrive", view().get("trace") or [], True)
        t.ok("[arrive] the artwork is there in the first frame the card shows", view().get("artInFirstFrame") is True, view().get("artInFirstFrame"))
        mini("stage", "off")
        time.sleep(1.2)
        check("leave", view().get("trace") or [], False)
        mini("stage", json.dumps(SONG))
        time.sleep(1.2)
        mini("hover")
        time.sleep(0.4)
        mini("dismiss")
        time.sleep(1.2)
        trace = view().get("trace") or []
        check("close", trace, False)
        if trace:
            t.ok("[close] the card goes at once", trace[0][2] < 1 or trace[0][0] < 0.02, trace[:2])
        mini("hover", "off")

        made = film(f"arrive{suffix}", lambda: mini("stage", json.dumps(SONG)))
        t.ok("[arrive] filmed", "error" not in made, made)
        made = film(f"leave{suffix}", lambda: mini("stage", "off"))
        t.ok("[leave] filmed", "error" not in made, made)
        mini("stage", json.dumps(SONG))
        time.sleep(1.2)
        mini("hover")
        time.sleep(0.4)
        made = film(f"close{suffix}", lambda: mini("dismiss"))
        t.ok("[close] filmed", "error" not in made, made)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

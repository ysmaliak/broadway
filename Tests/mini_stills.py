#!/usr/bin/env python3
"""Stills of the mini player card in every state, with fixed data, in the
real sidebar of a hidden probe window (below the desktop, pictured by its
own window id).

Build first (`./build.sh`), then `python3 Tests/mini_stills.py [OUT]`
(default .context/mini-better/stills). The card is staged through the
bench (`mini stage`), so no page plays. Each picture is the sidebar's
bottom part, cropped from the window's own capture. With a film of the
real player in .context/film, one sheet sets the song beside its first frame.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-mini-stills")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/mini-better/stills")
WINDOW = [0]
SIZE = [1100, 720]
SHORT = [1100, 420]
FILM = ROOT / ".context/film/mini-player.mov"
t = sv.T()

SONG = {"title": "Born To Fly", "detail": "A Singer", "site": "music.example", "art": "warm", "playing": True,
        "pair": "tracks", "time": 71, "duration": 285, "rate": 1, "speed": False, "muted": False}
BOOK = {"title": "Chapter 7: The Long Way Round", "detail": "A Reader", "site": "books.example", "art": "cool",
        "playing": True, "pair": "seconds", "time": 3725, "duration": 10800, "rate": 1.5, "speed": True, "muted": False}
LIVE = {"title": "Groove Salad", "detail": "SomaFM", "site": "somafm.com", "art": "green", "playing": True,
        "pair": "none", "live": True, "speed": False}
BARE = {"title": "Plain page", "detail": "127.0.0.1", "site": "127.0.0.1", "art": "icon", "playing": True,
        "pair": "seconds", "time": 12, "duration": 150, "speed": False}
LONG = dict(SONG, title="Bohemian Rhapsody (Remastered 2011, the long version with the opera section)", detail="A Band")


def mini(action="state", *values):
    return sv.cmd({"do": "mini", "action": action, "values": [str(v) for v in values]})


def stage(dark, size=SIZE):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": size})["window"]
    time.sleep(0.6)


def put(item):
    mini("stage", json.dumps(item))
    time.sleep(0.5)


def crop(source, dest, box):
    x, y, w, h = box
    done = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(source), "-vf", f"crop={w}:{h}:{x}:{y}", str(dest)],
                          capture_output=True, text=True)
    if done.returncode:
        print("  crop", box, done.stderr.strip()[-300:])


def foot():
    view = mini().get("view") or {}
    scale = view.get("scale", 2)
    column = view.get("column") or [0, 0, 300, 720]
    card = view.get("cardInWindow") or [0, 0, 300, 120]
    x0 = max(0, int((column[0]) * scale))
    width = int(column[2] * scale)
    top = max(0, int((card[1] - 150) * scale))
    bottom = int(min(column[1] + column[3], card[1] + card[3] + 60) * scale)
    return (x0, top, width, bottom - top)


def shoot(name):
    whole = Path(os.environ.get("TMPDIR", "/tmp")) / f"mini-stills-{os.getpid()}-{name}.png"
    took = subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(whole)], capture_output=True, text=True)
    if not whole.exists():
        print("  capture", WINDOW[0], took.stderr.strip())
        t.ok(f"{name} pictured", False)
        return None
    path = OUT / f"{name}.png"
    crop(whole, path, foot())
    whole.unlink()
    t.ok(f"{name} pictured", path.exists())
    return path


def both(name, setup):
    for dark in (True, False):
        stage(dark)
        setup()
        time.sleep(0.5)
        shoot(f"{name}-{'dark' if dark else 'light'}")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for old in OUT.glob("*.png"):
        old.unlink()
    sv.setup()
    sv.launch()
    try:
        stage(True)
        for n in range(6):
            sv.cmd({"do": "open", "url": f"about:blank#{n}"})
        time.sleep(1)
        mini("hover", "off")

        both("01-song", lambda: (put(SONG), mini("hover", "off")))
        both("02-long-audio-speed", lambda: (put(BOOK), mini("hover", "off")))
        both("03-live", lambda: (put(LIVE), mini("hover", "off")))
        both("04-no-artwork", lambda: (put(BARE), mini("hover", "off")))
        both("05-long-title-rest", lambda: (put(LONG), mini("hover", "off")))
        stage(True)
        put(LONG)
        mini("hover")
        time.sleep(0.6 + 1.6)
        shoot("06-long-title-sliding-dark")
        mini("hover", "off")
        both("07-paused", lambda: (put(dict(SONG, playing=False)), mini("hover", "off")))
        both("08-hover", lambda: (put(SONG), mini("hover"), time.sleep(0.4)))
        both("09-over-the-line", lambda: (put(SONG), mini("hover", "off"), mini("linehover"), time.sleep(0.4)))
        mini("linehover", "off")
        sv.cmd({"do": "ui", "sideWidth": 200})
        both("10-narrowest", lambda: (put(BOOK), mini("hover")))
        sv.cmd({"do": "ui", "sideWidth": 258})
        mini("hover", "off")
        for dark in (True, False):
            stage(dark, SHORT)
            put(SONG)
            mini("hover")
            time.sleep(0.4)
            shoot(f"11-short-window-{'dark' if dark else 'light'}")
            mini("hover", "off")
        stage(True)
        sv.cmd({"do": "ui", "side": "right"})
        both("12-right-side", lambda: (put(SONG), mini("hover")))
        sv.cmd({"do": "ui", "side": "left"})
        mini("hover", "off")
        mini("ground", "plain")
        both("13-plain-ground", lambda: (put(SONG), mini("hover", "off")))
        mini("ground", "glass")
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        time.sleep(1)
        mini("stacked", "on")
        both("14-stacked-spaces", lambda: (put(SONG), mini("hover", "off")))
        mini("stacked", "off")
        sv.cmd({"do": "updates", "stage": "9.9", "build": "999"})
        both("16-over-update-card", lambda: (put(SONG), mini("hover")))
        for dark in (True, False):
            stage(dark, [1100, 460])
            put(SONG)
            mini("hover")
            time.sleep(0.4)
            shoot(f"17-short-over-update-card-{'dark' if dark else 'light'}")
        sv.cmd({"do": "updates", "unstage": True})
        mini("hover", "off")

        if FILM.exists() and (OUT / "01-song-dark.png").exists():
            frame = OUT / ".film-frame1.png"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", "0", "-i", str(FILM), "-frames:v", "1", str(frame)])
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(frame), "-i", str(OUT / "01-song-dark.png"),
                            "-filter_complex", "[0]scale=-2:520[a];[1]scale=-2:520[b];[a][b]hstack=inputs=2",
                            str(OUT / "15-beside-film-frame-1.png")])
            frame.unlink(missing_ok=True)
            t.ok("the sheet beside the film's frame 1", (OUT / "15-beside-film-frame-1.png").exists())
        mini("stage", "off")
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

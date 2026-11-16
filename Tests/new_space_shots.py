#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

parser = argparse.ArgumentParser(description="Pictures and films of the New Space card, taken of a probe window by its id, into .context/shots/LABEL/.")
parser.add_argument("label")
parser.add_argument("--only", default="", help="any of open,folded,small,stacked,film,reduced")
parser.add_argument("--old", action="store_true", help="drive the card as it was in the column, with keys and its sheet")
parser.add_argument("--fps", type=int, default=60)
options = parser.parse_args()
OUT = ROOT / ".context" / "shots" / options.label
TOOLS = ROOT / ".context" / "visual-tools"
only = set(filter(None, options.only.split(",")))
LONG = "Travel plans for the long summer abroad"
pid = None
number = None


def tool(name, source):
    TOOLS.mkdir(parents=True, exist_ok=True)
    out = TOOLS / name
    src = ROOT / "Tests" / source
    if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(src), "-o", str(out)], check=True)
    return out


def cmd(**request):
    return sv.cmd(request)


def space(action="state", **more):
    return cmd(do="space", action=action, **more)


def press(code, chars, *mods):
    cmd(do="press", code=code, chars=chars, mods=list(mods))


def typed(text):
    if options.old:
        cmd(do="press", code=0, chars=text[0], mods=[], type=text[1:])
    else:
        space("card", name=text)


def shot(name):
    path = OUT / f"{name}.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    print(f"  {name}: {said}", flush=True)


def sheet(name):
    windows = cmd(do="probe").get("windows", [])
    print(f"  {name}: windows {json.dumps(windows)[:300]}", flush=True)
    shot(name)


def launch(**prefs):
    global pid, number
    sv.use("new-space-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False, "spaces": True, **prefs})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    cmd(do="windows", action="frame", n=1, frame=[80, 80, 1180, 760])
    number = cmd(do="idle", action="unhide")["number"]
    sv.page("first")
    sv.page("second")
    space("new", name="Work")
    time.sleep(0.8)
    space("go", index=1)
    time.sleep(0.8)


def leave():
    space("leave")
    time.sleep(0.9)


def open_column(look):
    cmd(do="ui", look=look)
    time.sleep(0.5)
    shot(f"window-{look}")
    space("ask")
    time.sleep(1.2)
    shot(f"open-{look}")
    typed("Reading")
    time.sleep(0.4)
    shot(f"open-named-{look}")
    if options.old:
        press(48, "\t")
        press(124, "")
    else:
        space("card", shared=False)
    time.sleep(0.5)
    shot(f"open-separate-{look}")
    if not options.old:
        space("card", look=space("card")["looks"][4])
        time.sleep(0.6)
        shot(f"open-look-{look}")
        space("card", name=LONG)
    else:
        typed(" " + LONG)
    time.sleep(0.4)
    shot(f"open-long-{look}")
    leave()


def folded(look):
    cmd(do="ui", look=look)
    cmd(do="ui", folded=True)
    time.sleep(0.8)
    space("ask")
    time.sleep(1.2)
    sheet(f"folded-{look}")
    if options.old:
        cmd(do="press", code=53, chars="\x1b", mods=[], sheet=True)
    else:
        space("leave")
    time.sleep(0.9)
    cmd(do="ui", folded=False)
    time.sleep(0.8)


def small(look):
    cmd(do="ui", look=look)
    cmd(do="windows", action="frame", n=1, frame=[80, 80, 700, 520])
    time.sleep(0.8)
    space("ask")
    time.sleep(1.2)
    space("card", name="Reading")
    time.sleep(0.4)
    shot(f"small-{look}")
    space("leave")
    time.sleep(0.9)
    cmd(do="windows", action="frame", n=1, frame=[80, 80, 1180, 760])
    time.sleep(0.8)


def stacked(look):
    cmd(do="ui", look=look)
    time.sleep(0.5)
    space("ask")
    time.sleep(1.2)
    sheet(f"stacked-{look}")
    if options.old:
        cmd(do="press", code=53, chars="\x1b", mods=[], sheet=True)
    else:
        space("leave")
    time.sleep(0.9)


def film(name, seconds, act):
    taker = subprocess.Popen([str(FILM), "window", str(pid), str(number), str(OUT / f"{name}.mp4"), str(seconds), str(options.fps), "1"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        print(f"  {name}: not filmed: {line} {taker.stderr.read()}", flush=True)
        return
    time.sleep(0.3)
    act()
    taker.communicate()
    every = 1 / 30
    count = int(seconds / every)
    columns = 6
    rows = (count + columns - 1) // columns
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(OUT / f"{name}.mp4"), "-vf",
                    f"fps={1 / every},scale=420:-1:flags=lanczos,tile={columns}x{rows}:padding=4:color=0x808080",
                    "-frames:v", "1", str(OUT / f"{name}-sheet.png")], check=False)
    print(f"  {name}: filmed", flush=True)


def films(tag, look="dark"):
    cmd(do="ui", look=look)
    time.sleep(0.5)
    film(f"arrive-{tag}", 1.6, lambda: space("ask"))
    time.sleep(0.3)
    film(f"leave-{tag}", 1.6, lambda: space("leave"))
    time.sleep(0.5)
    if not options.old:
        space("ask")
        time.sleep(1.0)
        space("card", name="Reading")
        film(f"create-{tag}", 1.8, lambda: space("card", create=True))
        time.sleep(0.5)
        space("delete")
        time.sleep(0.8)


def wanted(name):
    return not only or name in only


def main():
    global SHOT, FILM
    OUT.mkdir(parents=True, exist_ok=True)
    SHOT = tool("shot", "WindowShot.swift")
    FILM = tool("film", "onboarding_film.swift")
    if wanted("open") or wanted("folded") or wanted("small") or wanted("film"):
        launch()
        try:
            for look in ["dark", "light"]:
                if wanted("open"):
                    open_column(look)
                if wanted("folded"):
                    folded(look)
                if wanted("small") and not options.old:
                    small(look)
            if wanted("film"):
                films("open")
                if not options.old:
                    cmd(do="ui", folded=True)
                    time.sleep(0.8)
                    films("folded")
                    cmd(do="ui", folded=False)
        finally:
            sv.finish()
    if wanted("reduced") and not options.old:
        launch(**{"motion.testReduced": True})
        try:
            films("reduced")
        finally:
            sv.finish()
    if wanted("stacked"):
        launch(**{"spaces.stacked": True})
        try:
            for look in ["dark", "light"]:
                stacked(look)
            if wanted("film") and not options.old:
                films("stacked")
        finally:
            sv.finish()


if __name__ == "__main__":
    main()

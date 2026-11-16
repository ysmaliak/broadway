#!/usr/bin/env python3
"""The column's small moving details, filmed window-only, for one build beside another.

Build first (`./build.sh`), then `python3 Tests/details_film.py LABEL [--theme light|dark] [--only a,b]`.
`FILM_UNIT=1` on a Retina display (the default 0.5 is for a 1x one, where the
recorder's double-size buffer holds the window at half). `BROADWAY_PROBE_APP=/path/Broadway.app` films another build (the SwiftUI reference, say)
with the same steps. A world of its own, shown behind the app in front
(SEARCH_SHOWN). Each step is filmed with Tests/pin_film.swift (the test copy's
own window, never the screen) into .context/details/LABEL-THEME/STEP/, every
frame kept, with a contact sheet of the frames that changed.

Steps: a slow page loading (the ring), a folder shut and opened (the glyph's
morph, the chevron, the rows), the same for a pinned folder and a nested one, a row hovered
and left (the fill, the close cross), a press on a row, the selection
gliding to another row, and a tab closed (the list change).
"""
import argparse
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("label")
parser.add_argument("--theme", default="light")
parser.add_argument("--only", default="")
options = parser.parse_args()
only = set(filter(None, options.only.split(",")))
OUT = ROOT / ".context" / "details" / f"{options.label}-{options.theme}"
FILM = ROOT / ".context" / "details" / "pin-film"
WIDTH, HEIGHT, COLUMN = 900, 640, 260


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("/")[0] or "Page"
        if name.startswith("Slow"):
            time.sleep(6)
        body = f"<!doctype html><meta charset=utf-8><title>{name}</title><body style='font:16px -apple-system;margin:40px'><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("details-" + uuid.uuid4().hex[:6])
pid = None
number = None


def cmd(**r): return sv.cmd(r)


def opened(name, wait=True):
    id = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
    if wait:
        cmd(do="wait", id=id, seconds=10)
    return id


def film(name, act, seconds=1.2):
    if only and name not in only:
        return
    folder = OUT / name
    unit = float(os.environ.get("FILM_UNIT", "0.5"))
    crop = f"0,0,{(COLUMN + 8) * unit},{HEIGHT * unit}"
    cmd(do="idle", action="unhide")
    time.sleep(0.4)
    taker = subprocess.Popen([str(FILM), str(pid), str(number), str(folder), str(seconds), crop],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        print(f"  !! {name}: not filmed: {line} {taker.stderr.read()}", flush=True)
        return
    time.sleep(0.1)
    act()
    out, err = taker.communicate()
    if (folder / "sheet.png").exists():
        shutil.copy(folder / "sheet.png", OUT / f"{name}.png")
    print(f"  ok {name}: {out.strip()}", flush=True)


def main():
    global pid, number
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Tests/pin_film.swift"
    if not FILM.exists() or FILM.stat().st_mtime < source.stat().st_mtime:
        FILM.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(FILM)], check=True)
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                                           "tabs.cards": True, "start.fresh": False, "split": False, "tabs.newAtBottom": True})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", options.theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(COLUMN)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        number = cmd(do="idle", action="unhide")["number"]
        pins = [opened(f"Pin-{n}") for n in range(3)]
        reading = [opened(f"Reading-{n}") for n in range(3)]
        kept = [opened(f"Kept-{n}") for n in range(2)]
        loose = [opened(f"Loose-{n}") for n in range(5)]
        for x in sv.sp("state")["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        for id in pins: cmd(do="pin", id=id)
        cmd(do="group", id=reading[0], new=True, name="Reading")
        for id in reading[1:]: cmd(do="group", id=id, name="Reading")
        cmd(do="group", id=kept[0], new=True, name="Kept")
        cmd(do="group", id=kept[1], name="Kept")
        cmd(do="group", name="Kept", pinned=True)
        sv.sp("select", id=loose[0])
        time.sleep(1.5)
        film("at-rest", lambda: None, seconds=0.3)

        film("loading", lambda: opened("Slow-page", wait=False), seconds=1.6)
        time.sleep(5)
        film("fold-shut", lambda: cmd(do="group", name="Reading", fold=True))
        film("fold-open", lambda: cmd(do="group", name="Reading", fold=True))
        film("pinned-shut", lambda: cmd(do="group", name="Kept", fold=True))
        film("pinned-open", lambda: cmd(do="group", name="Kept", fold=True))
        film("hover-in", lambda: cmd(do="rowhover", id=loose[2], on=True), seconds=0.8)
        film("hover-out", lambda: cmd(do="rowhover", id=loose[2], on=False), seconds=0.8)

        def press():
            cmd(do="rowpress", id=loose[3], down=True)
            time.sleep(0.25)
            cmd(do="rowpress", id=loose[3], down=False)
        film("press", press)
        film("select-glide", lambda: sv.sp("select", id=loose[1]))
        film("pin-select", lambda: sv.sp("select", id=pins[1]))
        film("close", lambda: sv.sp("close", id=loose[4]))
    finally:
        try: cmd(do="quit")
        except Exception: subprocess.run(["kill", str(pid)])
        sv.wipe()
    return 0


if __name__ == "__main__":
    sys.exit(main())

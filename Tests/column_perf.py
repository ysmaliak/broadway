#!/usr/bin/env python3
"""The column on a long list: scrolling, hover across rows, a drag reorder.

Build first (`./build.sh`), then `python3 Tests/column_perf.py [--app APP]
[--runs N] [--json PATH]`. A test copy in a world of its own, shown behind
the app in front (SEARCH_SHOWN) and put on the fastest screen (bench `idle
place`). A long column: six pins, three folders of eight and ninety loose
tabs, all local pages.

- scroll: 1200 points down the column and back in 10-point wheel notches,
  one every 16 ms (bench `columnscroll wheel`, handed to whatever is under
  the column's middle).
- hover: the rows' own hover answers, down twenty rows and back, one row
  every 1/120 s (bench `hoversweep`).
- drag: a loose row picked up and carried eight rows down and let go, as
  mouse events sent to the window (bench `film drag`, no real pointer).

For each: the main thread's busy time, its longest span and the spans over
8.3 ms (one 120 Hz frame), from FrameGaps (bench `idle frames` / `gaps`).
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "page"
        body = f"<!doctype html><title>{name}</title><h1>{name}</h1>".encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
FRAME = 1000 / 120


def c(**r):
    return sv.cmd(r)


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", "SEARCH_SHOWN=1", "--env", f"SEARCH_PROBE={sv.W}", sv.APP], check=True)
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def world(count=90):
    def open_(name):
        return sv.sp("open", url=f"{BASE}/{name}")["resultID"]

    c(do="ui", sidebar=True)
    c(do="resize", width=1100, height=820, steps=1)
    loose = [open_(f"loose-{i}") for i in range(count)]
    pins = [open_(f"pin-{i}") for i in range(6)]
    for p in pins:
        c(do="pin", id=p)
    for f in range(3):
        ids = [open_(f"f{f}-{i}") for i in range(8)]
        c(do="group", id=ids[0], new=True, name=f"Folder {f}")
        for i in ids[1:]:
            c(do="group", id=i, name=f"Folder {f}")
    sv.sp("select", id=loose[0])
    time.sleep(4)
    return {"loose": loose, "count": len(c(do="tabs")["tabs"])}


def spans(gaps):
    return {"busyMs": gaps.get("busyMs"), "longestMs": gaps.get("longestMs"),
            "over8": sum(1 for s in gaps.get("spansAt", []) if s[1] > FRAME), "hitches": gaps.get("hitches"),
            "frames": gaps.get("frames")}


def scroll():
    c(do="idle", action="frames")
    c(do="columnscroll", wheel=1200)
    c(do="columnscroll", wheel=-1200)
    return spans(c(do="idle", action="gaps"))


def hover():
    c(do="idle", action="frames")
    got = c(do="hoversweep", rows=20, interval=1 / 120)
    out = spans(c(do="idle", action="gaps"))
    out["crossingMs"] = got.get("crossingMs")
    return out


def drag(made):
    rows = c(do="rowframes")["rows"]
    tabs = {t["id"]: t for t in c(do="tabs")["tabs"]}
    ids = [i for i in made["loose"][1:12]]
    frames = [rows.get(i) for i in ids if rows.get(i)]
    if len(frames) < 10:
        return {"error": "rows not measured", "found": len(frames)}
    x = frames[1][0] + frames[1][2] / 2
    y0 = frames[1][1] + frames[1][3] / 2
    y1 = frames[9][1] + frames[9][3] / 2
    steps = 40
    points = [[x, y0]] + [[x, y0 + (y1 - y0) * k / steps] for k in range(1, steps + 1)] + [[x, y1]]
    c(do="idle", action="frames")
    c(do="film", action="drag", points=points, step=1 / 120, frames=1, every=0.5, region="0,0,2,2", path=str(Path(__file__).resolve().parents[1] / ".context" / "column-perf-film"))
    time.sleep(len(points) / 120 + 1.2)
    return spans(c(do="idle", action="gaps"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--json")
    ap.add_argument("--app")
    ap.add_argument("--loose", type=int, default=90)
    ap.add_argument("--only", default="scroll,hover,drag")
    a = ap.parse_args()
    if a.app:
        sv.APP = str(Path(a.app).resolve())
    sv.use("column-perf")
    result = {}
    try:
        sv.setup()
        launch()
        placed = c(do="idle", action="place")
        result["screenHz"] = placed.get("screenHz")
        made = world(a.loose)
        result["tabs"] = made["count"]
        print(f"world: {made['count']} tabs on {placed.get('screen')} {placed.get('screenHz')} Hz", flush=True)
        for name, run in (("scroll", scroll), ("hover", hover), ("drag", lambda: drag(made))):
            if name not in a.only.split(","):
                continue
            runs = [run() for _ in range(a.runs)]
            good = [r for r in runs if "error" not in r]
            if not good:
                result[name] = runs[0]
                continue
            result[name] = {k: statistics.median(r[k] for r in good if r.get(k) is not None)
                            for k in ("busyMs", "longestMs", "over8", "hitches", "frames")}
            if name == "hover":
                result[name]["crossingMs"] = good[-1].get("crossingMs")
            print(name, json.dumps(result[name]), flush=True)
    finally:
        sv.finish()
    if a.json:
        Path(a.json).write_text(json.dumps(result, indent=1))
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()

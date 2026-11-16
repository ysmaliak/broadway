#!/usr/bin/env python3
"""Sidebar rows under everyday changes: how many row bodies each one builds.

Build first (`./build.sh`), then `python3 Tests/perf_rows.py [--runs N]
[--only a,b] [--shown] [--json PATH] [--check]`. A world of its own with
sixty tabs: six pins, four folders of eight (one of them pinned) and
twenty-two loose tabs, all local pages. Each event is driven through the
bench while SwiftUI bodies are counted (bench `idle start` / `report`) and
the main run loop's busy time is summed (bench `idle frames` / `gaps`).

Events: `load` (the tab you're on goes to a new page), `bgload` (a tab in a
folder that isn't shown loads), `title` (a background tab retitles itself),
`type` (eight characters typed into the address field, then Esc), `select`
(another tab is picked), `hover` (the pointer crosses ten rows, through the
rows' own hover answers).

`pin` (a loose tab is pinned) and `unpin` (it goes back).

`--check` fails when an event that changes one or two rows builds more than
`--most` row bodies (default 12).
"""
import argparse
import json
import statistics
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("perf-rows")

ROWS = ("SideRow", "PinSquare", "SplitTabItem")
FIELD = ("Omnibox", "FieldBar", "FieldList", "FieldRow", "ContentView", "SideBar")


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "page"
        body = f"<!doctype html><title>{name}</title><h1>{name}</h1><p>{'words ' * 200}</p>".encode()
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


def c(**r):
    return sv.cmd(r)


def launch(shown):
    import os
    import subprocess
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    mode = ["--env", "SEARCH_SHOWN=1"] if shown else ["-j"]
    subprocess.run(["open", "-n", "-g", *mode, "--env", f"SEARCH_PROBE={sv.W}",
                    "--env", "SEARCH_MEASURE=1", sv.APP], check=True)
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")
    return sv.pids()


def world():
    def open_(name):
        return sv.sp("open", url=f"{BASE}/{name}")["resultID"]

    pins = [open_(f"pin-{i}") for i in range(6)]
    for p in pins:
        c(do="pin", id=p)
    folders = {}
    for f in range(4):
        ids = [open_(f"f{f}-{i}") for i in range(8)]
        name = f"Folder {f}"
        c(do="group", id=ids[0], new=True, name=name)
        for i in ids[1:]:
            c(do="group", id=i, name=name)
        folders[name] = ids
    c(do="group", name="Folder 0", pinned=True)
    loose = [open_(f"loose-{i}") for i in range(22)]
    sv.sp("select", id=loose[0])
    time.sleep(4)
    tabs = c(do="tabs")["tabs"]
    return {"pins": pins, "folders": folders, "loose": loose, "count": len(tabs)}


def events(made):
    n = {"i": 0}

    def tick():
        n["i"] += 1
        return n["i"]

    loose = made["loose"]
    f1 = made["folders"]["Folder 1"]
    f2 = made["folders"]["Folder 2"]

    def load():
        c(do="go", id=loose[0], url=f"{BASE}/next-{tick()}")

    def bgload():
        c(do="go", id=f1[3], url=f"{BASE}/back-{tick()}")

    def title():
        sv.ev(loose[5], f"document.title = 'retitled {tick()}'; true")

    def type_():
        c(do="field", text="swiftrow", type=True)
        c(do="press", code=53, chars="\u001b", mods=[])

    def select():
        sv.sp("select", id=f2[2] if tick() % 2 else loose[0])

    flown = {"pin": 0, "unpin": 0}

    def pin():
        flown["pin"] += 1
        c(do="pin", id=loose[9 + flown["pin"]])

    def unpin():
        flown["unpin"] += 1
        c(do="pin", id=loose[9 + flown["unpin"]], off=True)

    return {"load": load, "bgload": bgload, "title": title, "type": type_, "select": select, "pin": pin, "unpin": unpin}


def measure(action, settle):
    c(do="idle", action="start")
    c(do="idle", action="frames")
    action()
    time.sleep(settle)
    gaps = c(do="idle", action="gaps")
    bodies = c(do="idle", action="report")["bodies"]
    return {"rows": {k: bodies.get(k, 0) for k in ROWS}, "bodies": sum(bodies.values()),
            "all": bodies, "busyMs": gaps["busyMs"], "longestMs": gaps["longestMs"]}


def hover():
    got = c(do="hoversweep", rows=10, interval=1 / 30)
    return {"rows": {"SideRow": got["bodies"].get("row", 0)}, "bodies": sum(got["bodies"].values()),
            "crossings": got["crossings"], "crossingMs": got["crossingMs"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--only", default="")
    ap.add_argument("--shown", action="store_true", help="draw the window on screen behind the app in front")
    ap.add_argument("--settle", type=float, default=1.5)
    ap.add_argument("--json")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--most", type=int, default=12)
    a = ap.parse_args()
    results = {}
    try:
        sv.setup(sidebar=True)
        pids = launch(a.shown)
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        made = world()
        print(f"world: {made['count']} tabs", flush=True)
        table = events(made)
        c(do="idle", action="start")
        time.sleep(2)
        for name in [*table, "hover"]:
            if a.only and name not in a.only.split(","):
                continue
            runs = [hover() if name == "hover" else measure(table[name], a.settle) for _ in range(a.runs)]
            row = {
                "rows": {k: statistics.median(r["rows"].get(k, 0) for r in runs) for k in ROWS},
                "bodies": statistics.median(r["bodies"] for r in runs),
            }
            if name == "hover":
                row["crossings"] = runs[0]["crossings"]
                row["crossingMs"] = runs[-1]["crossingMs"]
            else:
                row["busyMs"] = statistics.median(r["busyMs"] for r in runs)
                row["longestMs"] = statistics.median(r["longestMs"] for r in runs)
                row["top"] = dict(sorted(runs[-1]["all"].items(), key=lambda kv: -kv[1])[:8])
                row["field"] = {k: statistics.median(r["all"].get(k, 0) for r in runs) for k in FIELD}
            results[name] = row
            print(f"{name:7} {json.dumps(row)}", flush=True)
    finally:
        sv.finish()
    if a.json:
        Path(a.json).write_text(json.dumps(results, indent=2))
    if a.check:
        bad = {k: sum(v["rows"].values()) for k, v in results.items()
               if k in ("bgload", "title", "type") and sum(v["rows"].values()) > a.most}
        if bad:
            sys.exit(f"rows rebuilt beyond the ones that changed: {bad}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Sidebar rows keep their site icon on every frame of a space switch.

Build first (`./build.sh`), then `python3 Tests/space_icon_blink.py [--label before|after] [--film]`.

A shown test copy in a world of its own with three spaces. Home (dark) and
Work (light) each hold two pins, a folder and a list long enough to scroll, of
local pages served from this machine that each wear an icon of their own, and
a few local files that have no icon and show a letter, so rows taken from the
pool cross between a letter and a picture. Nothing reaches the network.

Each case switches spaces (slow and fast swipes both ways, the space keys both
ways, quick swipes back and forth before each slide settles, five swipes and
five keys in a row) while `icontrace` reads, on the window's display link and
at the swipe's own flush, every row that is on screen: whether its tab knows
an icon, and whether the row's mark shows that picture now, set, unhidden,
placed and opaque, with nothing fading in. A row whose tab knows its icon and
whose mark does not show it at once is a blink. With --film each case is also
filmed from the test copy's own window by its number (Tests/motion_film.swift)
into .context/icon-blink/LABEL/. With --relaunch the test copy is quit and
started again once the world is made, so the spaces come back from the session
and their icons from disk.
"""
import argparse
import json
import struct
import subprocess
import tempfile
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_audit as ma  # noqa: E402
import perf_idle as pi  # noqa: E402

sv = pi.sv
sv.use("space-icon-blink")
c = ma.c
ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 1280, 800
COLOURS = [(230, 33, 23), (24, 23, 28), (40, 110, 230), (40, 170, 80), (240, 150, 20), (150, 60, 200),
           (20, 170, 180), (230, 60, 150), (120, 120, 40), (90, 60, 30), (230, 33, 23), (240, 240, 240),
           (60, 60, 200), (200, 120, 40), (20, 120, 90), (110, 40, 40), (40, 40, 40), (180, 30, 90)]


def shape(kind, rgb):
    def at(x, y):
        u, v = (x + 0.5) / 32, (y + 0.5) / 32
        if kind == "play":
            corner = 0.22
            dx, dy = max(0, abs(u - 0.5) - (0.5 - corner)), max(0, abs(v - 0.5) * 1.4 - (0.5 - corner))
            if dx * dx + dy * dy > corner * corner or abs(v - 0.5) > 0.36:
                return (0, 0, 0, 0)
            inside = u > 0.4 and abs(v - 0.5) < (0.66 - u) * 0.9
            return (255, 255, 255, 255) if inside else (*rgb, 255)
        if kind == "glyph":
            r = ((u - 0.5) ** 2 + (v - 0.5) ** 2) ** 0.5
            return (*rgb, 255) if r < 0.46 and not (0.18 < r < 0.26) else (0, 0, 0, 0)
        if kind == "ring":
            r = ((u - 0.5) ** 2 + (v - 0.5) ** 2) ** 0.5
            return (*rgb, 255) if 0.3 < r < 0.48 else (0, 0, 0, 0)
        if kind == "pale":
            return (250, 250, 248, 255) if not (0.3 < u < 0.7 and 0.3 < v < 0.7) else (*rgb, 255)
        return (*rgb, 255)
    return at


def png(kind, rgb):
    size = 32
    paint = shape(kind, rgb)
    rows = b"".join(b"\x00" + b"".join(bytes(paint(x, y)) for x in range(size)) for y in range(size))

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


KINDS = ["play", "glyph", "square", "ring", "pale"]


def serve(index):
    icon = png(KINDS[index % len(KINDS)], COLOURS[index])

    class Page(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.startswith("/icon.png"):
                data, kind = icon, "image/png"
            else:
                words = "The ferry timetable changes in spring and the late boat stops at the island twice. " * 30
                data = (f"<!doctype html><title>Site {index}</title><link rel=icon href=/icon.png>"
                        f"<h1>Site {index}</h1><p>{words}</p>").encode()
                kind = "text/html"
            self.send_response(200)
            self.send_header("content-type", kind)
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *a):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_port}"


SITES = [serve(i) for i in range(len(COLOURS))]
PLAIN = Path(tempfile.mkdtemp(prefix="icon-blink-"))
for _k in range(6):
    (PLAIN / f"plain-{_k}.html").write_text(f"<!doctype html><title>Plain {_k}</title><h1>Plain {_k}</h1>")
SPACES = {}


def space(**f):
    return c(do="space", **f)


def opened(url, front=False):
    return sv.sp("open", url=url, foreground=front, atEnd=True)["resultID"]


def trace(action):
    return sv.cmd({"do": "ui", "icontrace": {"action": action}})


def stroke(stops, speed, at=None):
    made = {"stops": stops, "speed": speed, "momentum": True, "cancel": False}
    if at is not None:
        made["at"] = at
    return made


def quick(gap):
    return lambda: space(action="trackpad", gestures=[stroke([-140 if k % 2 == 0 else 140], 1100, at=k * gap) for k in range(6)])


def go(name, wait=1.6):
    space(action="go", index=SPACES[name])
    time.sleep(wait)


def fill(name, sites):
    pins = [opened(f"{sites[k]}/{name}-pin-{k}") for k in range(2)]
    for pin in pins:
        c(do="pin", id=pin)
    folder = [opened(f"{sites[2 + k]}/{name}-folder-{k}") for k in range(3)]
    c(do="group", id=folder[0], new=True, name="Reading")
    for tab in folder[1:]:
        c(do="group", id=tab, name="Reading")
    for k in range(4):
        opened(f"{sites[5 + k]}/{name}-tab-{k}", front=k == 0)
        time.sleep(0.3)
    for k in range(8):
        opened(f"{sites[(k * 3) % len(sites)]}/{name}-more-{k}")
        if k % 3 == 0:
            opened((PLAIN / f"plain-{(k // 3) + (3 if name == 'work' else 0)}.html").as_uri())
    time.sleep(1.5)


def world(look):
    c(do="ui", look=look)
    space(action="rename", name="Home")
    space(action="look", colours=["3A3F4B"], intensity=0.4)
    fill("home", SITES[:9])
    space(action="new", name="Work")
    time.sleep(0.8)
    space(action="look", colours=["F4EFE6"], intensity=0.6)
    fill("work", SITES[9:])
    space(action="new", name="Side")
    time.sleep(0.8)
    opened(f"{SITES[0]}/side-0", front=True)
    names = [s["name"] for s in space(action="state")["spaces"]]
    for name in ("Home", "Work"):
        SPACES[name] = names.index(name) + 1
    for name in ("Home", "Work", "Home", "Work", "Home"):
        go(name, wait=1.4)


def known_everywhere():
    seen = {}
    for name in ("Work", "Home"):
        go(name, wait=1.2)
        rows = trace("now").get("rows", [])
        seen[name] = sorted((r["label"], r["known"], r.get("dress")) for r in rows)
    return seen


def five(keys):
    def act():
        order = ["Work", "Home", "Work", "Home", "Work"]
        for name in order:
            if keys:
                space(action="key", index=SPACES[name])
            else:
                space(action="trackpad", gestures=[stroke([-140 if name == "Work" else 140], 1100)])
            time.sleep(1.8)
    return act


CASES = [
    ("swipe-to-work-slow", "Home", lambda: space(action="trackpad", gestures=[stroke([-230], 350)]), 2.2),
    ("swipe-to-home-slow", "Work", lambda: space(action="trackpad", gestures=[stroke([230], 350)]), 2.2),
    ("swipe-to-work-fast", "Home", lambda: space(action="trackpad", gestures=[stroke([-90], 2600)]), 1.6),
    ("swipe-to-home-fast", "Work", lambda: space(action="trackpad", gestures=[stroke([90], 2600)]), 1.6),
    ("key-to-work", "Home", lambda: space(action="key", index=SPACES["Work"]), 1.6),
    ("key-to-home", "Work", lambda: space(action="key", index=SPACES["Home"]), 1.6),
    ("quick-back-and-forth", "Home", quick(0.32), 3.4),
    ("quicker-back-and-forth", "Home", quick(0.2), 2.6),
    ("five-swipes", "Home", five(False), 9.5),
    ("five-keys", "Home", five(True), 9.5),
]


def film(pid, name, out, seconds):
    args = [str(ma.FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(out / name),
            "--scale", "1", "--fps", "60", "--columns", "10", "--frames", str(out / f"{name}-frames"),
            "--crop", "0,0,300,420"]
    subprocess.run(["rm", "-rf", str(out / f"{name}-frames")])
    taker = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        print(f"  {name}: film did not start: {line} {taker.stderr.read()}", flush=True)
        return None
    return taker


def blinks(samples):
    bad = []
    for sample in samples:
        missing = [r for r in sample["rows"] if r.get("known") and not r.get("drawn")]
        if missing:
            bad.append({"t": round(sample["t"], 1), "flush": sample.get("flush"), "rows": [{k: r.get(k) for k in (
                "label", "fresh", "fading", "contents", "pictureHidden", "shownContents", "shownHidden", "rendered", "placed", "shown",
                "chainHidden", "markHidden", "keys", "pooled", "frame", "bounds", "at")} for r in missing]})
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--label", default="run")
    ap.add_argument("--only", default="")
    ap.add_argument("--film", action="store_true")
    ap.add_argument("--app")
    ap.add_argument("--look", default="dark", choices=["dark", "light"])
    ap.add_argument("--relaunch", action="store_true", help="quit and start again after making the world, so icons come back from disk")
    a = ap.parse_args()
    if a.app:
        sv.APP = str(Path(a.app).resolve())
    out = ROOT / ".context" / "icon-blink" / a.label
    out.mkdir(parents=True, exist_ok=True)
    if a.film:
        ma.build_film()
    t = sv.T()
    summary = {}
    try:
        sv.setup(sidebar=True, spaces=True, **{"tabs.groups": False, "tabs.aiGroups": False, "ai": False,
                                               "start.fresh": False, "tabs.newAtBottom": True, "split": False})
        pids = pi.launch_shown()
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        c(do="window")
        c(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        world(a.look)
        if a.relaunch:
            sv.quit()
            time.sleep(1)
            pids = pi.launch_shown()
            if len(pids) != 1:
                sys.exit(f"expected one probe after the relaunch, got {pids}")
            c(do="window")
            c(do="resize", width=WIDTH, height=HEIGHT, steps=1)
            time.sleep(2)
            names = [s["name"] for s in space(action="state")["spaces"]]
            for name in ("Home", "Work"):
                SPACES[name] = names.index(name) + 1
        seen = known_everywhere()
        print("icons known:", json.dumps(seen), flush=True)
        known = sum(1 for rows in seen.values() for _, k, _ in rows if k)
        t.ok("every row's tab but the plain files knows its icon before the switches", known >= 14, seen)
        wanted = set(a.only.split(",")) if a.only else None
        total = 0
        for name, begin, act, seconds in CASES:
            if wanted and name not in wanted:
                continue
            go(begin)
            taker = film(pids[0], name, out, seconds) if a.film else None
            trace("start")
            act()
            time.sleep(seconds if taker is None else max(0.2, seconds - 0.5))
            samples = trace("stop").get("samples", [])
            if taker is not None:
                taker.wait()
            bad = blinks(samples)
            flushes = sum(1 for s in samples if s.get("flush"))
            frames = len(samples) - flushes
            rows = sum(len(s["rows"]) for s in samples)
            missing = sum(len(b["rows"]) for b in bad)
            total += len(bad)
            summary[name] = {"frames": frames, "rowSamples": rows, "framesWithBlink": len(bad),
                             "rowsWithoutIcon": missing, "first": bad[:6]}
            print(f"{name}: {frames} frames and {flushes} flushes, {len(bad)} with a row missing its icon ({missing} row samples)",
                  flush=True)
            for b in bad[:4]:
                print("   ", json.dumps(b)[:600], flush=True)
        (out / "summary.json").write_text(json.dumps(summary, indent=1))
        t.ok("no frame shows a row without the icon its tab knows", total == 0, total)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

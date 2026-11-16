#!/usr/bin/env python3
"""The column's loading ring and folder glyph, filmed at 120 fps.

A test copy in a world of its own, shown behind the app in front. Light and
dark, it films: a tab starting to load and finishing (load), a load held
open (slow), the same row after switching spaces and back (reuse), hover on
and off a loading row (hover), a pinned tab loading (pin), and folder
headings shutting and opening: unpinned, nested, pinned and live.

Each film keeps its frames (column crop, 2x) and an mp4, and frames.json
with the times. `--app` films another build, such as the SwiftUI reference.

Run: python3 Tests/ring_film.py LABEL [--app OTHER.app] [--out DIR] [--only a,b] [--looks light,dark]
"""
import argparse
import json
import os
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("label")
parser.add_argument("--app", default="")
parser.add_argument("--out", default="")
parser.add_argument("--only", default="")
parser.add_argument("--looks", default="light,dark")
options = parser.parse_args()
if options.app:
    sv.APP = options.app
OUT = Path(options.out or ROOT / ".context" / "ring-film") / options.label
FILM = ROOT / ".context" / "pin-motion" / "pin-film"
only = set(filter(None, options.only.split(",")))
WIDTH, HEIGHT, COLUMN = 1000, 720, 260
ICONS = {"magenta": (1.0, 0.0, 1.0), "grey": (0.5, 0.5, 0.52), "blue": (0.2, 0.45, 0.95)}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            inside = 2 <= x < side - 2 and 2 <= y < side - 2
            r, g, b = colour
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 if inside else 0])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


ROWS = [(700 + n, f"Change {700 + n}", "octo-sam", "open", "Approved", "passing") for n in range(3)]


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body, kind, status=200):
        try:
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path.startswith("/github/page/pulls"):
            return self.reply(pr.page(ROWS, BASE, late=False), "text/html; charset=utf-8")
        parts = self.path.split("?")[0].strip("/").split("/")
        if parts[0] == "icon":
            return self.reply(png(ICONS.get(parts[-1].removesuffix(".png"), ICONS["grey"])), "image/png")
        if parts[0] == "hang":
            time.sleep(float(parts[1]))
            return self.reply(b"GIF89a", "image/gif")
        icon = parts[1] if len(parts) > 1 else "grey"
        hold = parts[2] if len(parts) > 2 else ""
        img = f"<img src='/hang/{hold}?{time.time()}' width=1 height=1>" if hold else ""
        self.reply((f"<!doctype html><meta charset=utf-8><title>{parts[0]}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#33373d'>{img}").encode(), "text/html; charset=utf-8")


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("ring-film-" + uuid.uuid4().hex[:6])
pid = None
number = None
summary = {}
COUNT = [0]


def cmd(**r): return sv.cmd(r)
def state(): return sv.sp("state")


def opened(name, icon="grey"):
    id = sv.sp("open", url=f"{BASE}/{name}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    return id


def load(id, name, icon, hold):
    COUNT[0] += 1
    cmd(do="go", id=id, url=f"{BASE}/{name}/{icon}/{hold}?n={COUNT[0]}")


def rowframes():
    try:
        return cmd(do="rowframes").get("rows", {})
    except RuntimeError:
        return {}


def film(name, act, seconds=1.6):
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("0*.png"):
        old.unlink()
    crop = f"0,0,{COLUMN + 10},{HEIGHT}"
    cmd(do="idle", action="unhide")
    time.sleep(0.35)
    taker = subprocess.Popen([str(FILM), str(pid), str(number), str(folder), str(seconds), crop],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: not filmed: {line} {taker.stderr.read()}")
    time.sleep(0.12)
    started = time.time()
    act()
    taker.communicate()
    (folder / "rows.json").write_text(json.dumps({"rows": rowframes(), "actAfter": time.time() - started}))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "120", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(OUT / f"{name}.mp4")], check=False)
    print(f"  ok   {name}", flush=True)


def scene(name, act, seconds=1.6):
    if only and not any(name.startswith(o) for o in only):
        return
    try:
        film(name, act, seconds)
    except Exception as e:
        print(f"  FAIL {name}: {e}", flush=True)
    time.sleep(0.4)


def after(delay, fn):
    threading.Timer(delay, fn).start()


def main():
    global pid, number
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Tests/pin_film.swift"
    FILM.parent.mkdir(parents=True, exist_ok=True)
    if not FILM.exists() or FILM.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(FILM)], check=True)
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                                           "tabs.cards": True, "layout.cards": True, "start.fresh": False, "split": False,
                                           "tabs.newAtBottom": True, "live.on": True})
    looks = options.looks.split(",")
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", looks[0]], check=True)
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
        pinned = opened("Pinned", "blue")
        top = [opened(f"Top-{n}", "grey") for n in range(2)]
        loader = opened("Loader", "magenta")
        outer = [opened(f"Outer-{n}", "blue") for n in range(2)]
        inner = [opened(f"Inner-{n}", "grey") for n in range(2)]
        shelf = [opened(f"Shelf-{n}", "blue") for n in range(2)]
        for x in state()["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        cmd(do="pin", id=pinned)
        cmd(do="folders", args=["with", "Outer", *outer])
        cmd(do="folders", args=["with", "Inner", *inner])
        cmd(do="folders", args=["nest", "Inner", "Outer"])
        cmd(do="folders", args=["with", "Shelf", *shelf])
        cmd(do="group", name="Shelf", pinned=True)
        try:
            cmd(do="live", args=["add-page", "Pull Requests", "pullRequests", f"{BASE}/github/page/pulls?q=is%3Aopen+is%3Apr+author%3A%40me"])
            cmd(do="live", args=["unfold", "Pull Requests"])
            cmd(do="live", args=["update", "Pull Requests"])
        except RuntimeError as e:
            print(f"  ..   no live folder: {e}")
        sv.sp("select", id=top[0])
        cmd(do="space", action="new", name="Two")
        time.sleep(0.6)
        cmd(do="space", action="go", index=1)
        time.sleep(1.5)
        summary["tabs"] = {"pinned": pinned, "loader": loader, "top": top}
        for look in looks:
            if look != looks[0]:
                cmd(do="ui", look=look)
                time.sleep(1.2)

            def scenes(prefix):
                scene(f"{prefix}load", lambda: after(0.15, lambda: load(loader, "Loader", "magenta", 0.9)), 1.8)
                time.sleep(1.2)
                load(loader, "Loader", "magenta", 30)
                time.sleep(0.8)
                scene(f"{prefix}slow", lambda: None, 1.2)
                scene(f"{prefix}hover", lambda: (after(0.2, lambda: cmd(do="rowhover", id=loader, on=True)),
                                                  after(0.8, lambda: cmd(do="rowhover", id=loader, on=False))), 1.5)

                def away_and_back():
                    cmd(do="space", action="go", index=2)
                    after(0.35, lambda: cmd(do="space", action="go", index=1))
                scene(f"{prefix}reuse", away_and_back, 1.8)
                scene(f"{prefix}end", lambda: after(0.15, lambda: load(loader, "Loader", "magenta", "0.01")), 1.0)
                time.sleep(0.6)
                scene(f"{prefix}pin", lambda: after(0.15, lambda: load(pinned, "Pinned", "blue", 0.9)), 1.8)
                time.sleep(0.6)
                for folder in ("Outer", "Inner", "Shelf", "Pull Requests"):
                    key = folder.split()[0].lower()
                    scene(f"{prefix}fold-{key}-shut", lambda f=folder: after(0.1, lambda: cmd(do="group", name=f, fold=True)), 1.0)
                    scene(f"{prefix}fold-{key}-open", lambda f=folder: after(0.1, lambda: cmd(do="group", name=f, fold=True)), 1.0)
            scenes(f"{look}-")
        (OUT / "summary.json").write_text(json.dumps(summary, indent=1))
    finally:
        try:
            cmd(do="quit")
        except Exception:
            pass
        time.sleep(1)
        for p in sv.pids():
            subprocess.run(["kill", str(p)], check=False)
        sv.finish()


main()

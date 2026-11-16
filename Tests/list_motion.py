#!/usr/bin/env python3
"""Column list changes, filmed and checked frame by frame.

Build first (`./build.sh`), then `python3 Tests/list_motion.py [LABEL] [--only a,b]`.
A world of its own, shown behind the app in front (SEARCH_SHOWN), filmed
window-only with Tests/pin_film.swift into .context/list-motion/LABEL/
(LIST_MOTION_OUT and LIST_MOTION_FILM move both, e.g. to /tmp). One
loose tab has a magenta favicon; every change happens above it, so the
magenta mark is what moves: a tab opened above it (its slot opens), closed
(the slot collapses), the magenta tab moved up and back, a folder above it
shut and opened, a folder made around a tab above it and emptied again,
and a live folder above it refreshed by a fake GitHub to
more pull requests and back to fewer. Checked: the mark is on screen
exactly once in every frame, it never steps further in one frame than a
settle spring travels in that frame's time (no one-frame jump), and it never
turns back. The bench's display link gives the longest main-thread span.
"""
import argparse
import json
import os
import shutil
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
parser.add_argument("label", nargs="?", default="now")
parser.add_argument("--only", default="")
options = parser.parse_args()
OUT = Path(os.environ.get("LIST_MOTION_OUT") or ROOT / ".context" / "list-motion") / options.label
FILM = Path(os.environ.get("LIST_MOTION_FILM") or ROOT / ".context" / "pin-motion" / "pin-film")
only = set(filter(None, options.only.split(",")))
WIDTH, HEIGHT, COLUMN = 1000, 720, 260
COUNT = [3]
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


def rows():
    return [(700 + n, f"Change {700 + n}", "octo-sam", "open", "Approved", "passing") for n in range(COUNT[0])]


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body, kind, status=200):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/github/page/pulls"):
            return self.reply(pr.page(rows(), BASE, late=False), "text/html; charset=utf-8")
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon":
            return self.reply(png(ICONS[parts[-1].removesuffix(".png")]), "image/png")
        icon = parts[1] if len(parts) > 1 else "grey"
        self.reply((f"<!doctype html><meta charset=utf-8><title>{parts[0]}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#33373d'>").encode(), "text/html; charset=utf-8")


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("list-motion-" + uuid.uuid4().hex[:6])
t = sv.T()
pid = None
number = None
summary = {}


def cmd(**r): return sv.cmd(r)
def state(): return sv.sp("state")
def live(*args): return sv.cmd({"do": "live", "args": list(args)})


def opened(name, icon="grey"):
    id = sv.sp("open", url=f"{BASE}/{name}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    return id


def film(name, act, seconds=1.0):
    folder = OUT / name
    crop = f"0,0,{COLUMN + 10},{HEIGHT}"
    cmd(do="idle", action="unhide")
    time.sleep(0.35)
    taker = subprocess.Popen([str(FILM), str(pid), str(number), str(folder), str(seconds), crop],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: not filmed: {line} {taker.stderr.read()}")
    cmd(do="idle", action="frames")
    time.sleep(0.12)
    act()
    time.sleep(max(0.2, seconds - 0.6))
    gaps = cmd(do="idle", action="gaps")
    taker.communicate()
    frames = json.loads((folder / "frames.json").read_text())["frames"]
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(OUT / f"{name}.mp4")], check=False)
    if (folder / "sheet.png").exists():
        shutil.copy(folder / "sheet.png", OUT / f"{name}.png")
    for picture in folder.glob("0*.png"):
        picture.unlink()
    return frames, gaps


OMEGA = 2 * 3.14159 / 0.16


def reach(seconds):
    return min(1.0, OMEGA / 2.71828 * seconds)


def marks(frame):
    return [b for b in frame["blobs"] if b["w"] <= 22 and b["h"] <= 22]


def check(name, frames, gaps):
    seen = [(f["t"], marks(f)) for f in frames]
    counts = [len(b) for _, b in seen]
    longest = gaps.get("longestMs") or 0
    report = {"frames": len(frames), "longestMs": longest, "hitches": gaps.get("hitches")}
    single = [(round(tm), len(b)) for tm, b in seen if len(b) != 1]
    path = [(tm, b[0]) for tm, b in seen if len(b) == 1]
    if len(path) >= 2:
        start, end = path[0][1], path[-1][1]
        travel = ((end["x"] - start["x"]) ** 2 + (end["y"] - start["y"]) ** 2) ** 0.5
        jumps, back, steps = [], [], []
        began = False
        for (ta, a), (tb, b) in zip(path, path[1:]):
            d = ((b["x"] - a["x"]) ** 2 + (b["y"] - a["y"]) ** 2) ** 0.5
            dt = (tb - ta) / 1000
            if d > 1.5:
                slack = longest / 1000 if not began else 0.009
                allowed = travel * reach(dt + slack) * 1.15 + 3
                if d > allowed:
                    jumps.append((round(tb), round(d, 1), round(allowed, 1), round(tb - ta)))
                began = True
                if travel > 4:
                    along = ((b["x"] - a["x"]) * (end["x"] - start["x"]) + (b["y"] - a["y"]) * (end["y"] - start["y"])) / travel
                    if along < -2:
                        back.append((round(tb), round(along, 1)))
            steps.append(d)
        moving = sum(1 for s in steps if s > 0.5)
        report.update(travel=round(travel, 1), start=[round(start["x"]), round(start["y"])], end=[round(end["x"]), round(end["y"])],
                      biggestStep=round(max(steps, default=0), 1), movingFrames=moving, jumps=jumps, backwards=back)
    summary[name] = report
    (OUT / f"{name}.json").write_text(json.dumps({"report": report, "frames": frames, "gaps": gaps}, indent=1))
    print(f"  ..   {name}: {json.dumps(report)}", flush=True)
    t.ok(f"{name}: the magenta row is on screen exactly once in every frame", not single, single[:12])
    t.ok(f"{name}: it moved", report.get("travel", 0) > 4, report.get("travel"))
    t.ok(f"{name}: over more than one frame", report.get("movingFrames", 0) > 2, report.get("movingFrames"))
    t.ok(f"{name}: no one-frame jumps", not report.get("jumps"), report.get("jumps"))
    t.ok(f"{name}: never turns back", not report.get("backwards"), report.get("backwards"))


def motion(name, act, seconds=1.0):
    if only and name not in only:
        act()
        time.sleep(0.6)
        return
    try:
        frames, gaps = film(name, act, seconds)
        check(name, frames, gaps)
    except Exception as e:
        t.ok(f"{name}: filmed", False, str(e))
    time.sleep(0.4)


def main():
    global pid, number
    OUT.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Tests/pin_film.swift"
    FILM.parent.mkdir(parents=True, exist_ok=True)
    if not FILM.exists() or FILM.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(FILM)], check=True)
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                                           "tabs.cards": True, "layout.cards": True, "start.fresh": False, "split": False,
                                           "tabs.newAtBottom": False, "live.on": True})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"], check=True)
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
        m = opened("Magenta", "magenta")
        reading = [opened(f"Reading-{n}", "blue") for n in range(3)]
        top = [opened(f"Top-{n}", "grey") for n in range(2)]
        for x in state()["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        cmd(do="group", id=reading[0], new=True, name="Reading")
        for id in reading[1:]: cmd(do="group", id=id, name="Reading")
        sv.sp("move", id=m, to=len(state()["tabs"]) - 1)
        sv.sp("select", id=top[0])
        time.sleep(1.0)
        st = state()
        folder = {"id": next(g for x, g in zip(st["tabs"], st["groupIDs"]) if x["id"] == reading[0])}

        holder = {}
        motion("insert-above", lambda: holder.update(id=opened("Fresh", "grey")))
        sv.sp("select", id=top[0])
        time.sleep(0.4)
        motion("close-above", lambda: sv.sp("close", id=holder["id"]))
        motion("move-up", lambda: sv.sp("move", id=m, to=0))
        motion("move-back", lambda: sv.sp("move", id=m, to=len(state()["tabs"]) - 1))
        motion("fold-shut", lambda: sv.sp("collapse", group=folder["id"]))
        motion("fold-open", lambda: sv.sp("collapse", group=folder["id"]))
        motion("folder-new", lambda: cmd(do="group", id=top[1], new=True, name="Fresh"))
        motion("folder-emptied", lambda: cmd(do="group", id=top[1], name="none"))

        live("add-page", "Pull Requests", "pullRequests", f"{BASE}/github/page/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")
        live("unfold", "Pull Requests")
        COUNT[0] = 3
        live("update", "Pull Requests")
        time.sleep(2.0)
        COUNT[0] = 6
        motion("refresh-more", lambda: live("update", "Pull Requests"), seconds=4.0)
        COUNT[0] = 2
        motion("refresh-fewer", lambda: live("update", "Pull Requests"), seconds=4.0)
        (OUT / "summary.json").write_text(json.dumps(summary, indent=1))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

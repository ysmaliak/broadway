#!/usr/bin/env python3
import json
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

label = sys.argv[1] if len(sys.argv) > 1 else "film"
theme = sys.argv[2] if len(sys.argv) > 2 else "light"
sv.use("split-drop-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "split-drop" / label
CAPTURE = ROOT / ".context" / "split-drop" / "capture"
SIZE = (1280, 800)
COLOURS = {"front": "#f4efe4", "carried": "#dfeee6", "other": "#e6e8f4", "pair-left": "#f3e3e3", "pair-right": "#e5eef7",
           "third": "#f6f1d8"}


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0] or "page"
        colour = COLOURS.get(name, "#ffffff")
        words = " ".join([f"The {name} page, its words reflowing as its width changes."] * 60)
        body = (f"<!doctype html><meta charset=utf-8><title>{name}</title>"
                f"<body style='background:{colour};color:#222;font:17px -apple-system;margin:36px'>"
                f"<h1 style='font-size:44px'>{name}</h1><p>{words}</p></body>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
pid = window = None
record = {}


def opened(name):
    id = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
    time.sleep(0.8)
    return id


def rows():
    return sv.cmd({"do": "rowframes"}).get("rows", {})


def row_point(id):
    for key, (x, y, w, h) in rows().items():
        if key.lower()[:8] == id.lower()[:8]:
            return [x + min(60, w / 2), y + h / 2]
    raise RuntimeError(f"no row for {id}")


def stage_frame():
    cards = sv.sp("state")["stage"].get("cards", [])
    xs = [c[0] for c in cards] + [c[2] for c in cards]
    ys = [c[1] for c in cards] + [c[3] for c in cards]
    return min(xs), min(ys), max(xs), max(ys)


def path(start, end, steps=14):
    return [[start[0] + (end[0] - start[0]) * k / steps, start[1] + (end[1] - start[1]) * k / steps] for k in range(steps + 1)]


def mouse(points, **extra):
    sv.sp("mouse", points=points, to="view", **extra)


def film(name, act, seconds):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(window)], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    if p.poll() is not None:
        raise RuntimeError(p.communicate()[0])
    began = time.time()
    time.sleep(0.15)
    marks = act() or {}
    print(name, p.communicate()[0].strip(), flush=True)
    frames = sorted(folder.glob("0*.png"))
    if not frames:
        return
    times = json.loads((folder / "times.json").read_text())
    marks = {k: v - began for k, v in marks.items()}
    record[name] = {"frames": len(frames), "marks": marks}
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(OUT / f"{name}.mp4")], check=True)
    sheet(name, folder, frames, times, marks)


def at(times, t):
    return min(range(len(times)), key=lambda i: abs(times[i] - t))


def tile(out, files, columns, scale):
    work = OUT / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    for n, f in enumerate(files):
        os.symlink(f, work / f"{n:04d}.png")
    rows_ = (len(files) + columns - 1) // columns
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"scale=iw*{scale}:-1,tile={columns}x{rows_}:padding=6:color=gray", "-frames:v", "1", str(out)], check=True)
    shutil.rmtree(work, ignore_errors=True)


def sheet(name, folder, frames, times, marks):
    for mark, t in marks.items():
        start = at(times, t - 0.05)
        picked = [i for i in range(start, len(frames)) if times[i] - times[start] <= 0.6][::3]
        tile(OUT / f"{name}-{mark}.png", [frames[i] for i in picked], 5, 0.3)
    if "drop" in marks:
        before = at(times, marks["drop"] - 0.03)
        settled = at(times, marks["drop"] + 0.7)
        tile(OUT / f"{name}-drop.png", [frames[before], frames[settled]], 2, 0.5)
        shutil.copy(frames[before], OUT / f"{name}-before-drop.png")
        shutil.copy(frames[settled], OUT / f"{name}-after-drop.png")


def carry_and_drop(source, end, hold=0.9):
    start = row_point(source)
    marks = {}
    mouse(path(start, [start[0] + 30, start[1]], 3), hold=True)
    mouse(path([start[0] + 30, start[1]], end), hold=True, resume=True)
    marks["show"] = time.time() - 0.3
    time.sleep(hold)
    cards["held"] = sv.sp("state")["stage"].get("cards", [])
    marks["drop"] = time.time()
    mouse([end, end], resume=True)
    time.sleep(0.6)
    cards["dropped"] = sv.sp("state")["stage"].get("cards", [])
    return marks


cards = {}


def same_cards(t, name):
    held, dropped = cards.get("held", []), cards.get("dropped", [])
    t.ok(f"{name}: two cards while held, the same two after the drop", len(held) == 2 and held == dropped, cards)


def main():
    global pid, window
    t = sv.T()
    OUT.mkdir(parents=True, exist_ok=True)
    CAPTURE.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False, "tabs.groups": False,
                "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "240"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": SIZE[0], "height": SIZE[1], "steps": 1})
        sv.sp("enabled", on=True)
        front = opened("front")
        carried = opened("carried")
        other = opened("other")
        sv.sp("select", id=carried)
        time.sleep(0.6)
        sv.sp("select", id=front)
        time.sleep(0.8)
        window = sv.cmd({"do": "idle", "action": "front"})["number"]
        time.sleep(0.8)
        x0, y0, x1, y1 = stage_frame()
        mid = (y0 + y1) / 2

        film("right", lambda: carry_and_drop(carried, [x1 - 40, mid]), 2.6)
        same_cards(t, "right")
        time.sleep(1)
        st = sv.sp("state")
        made = [s for s in st["splits"] if set(s["tabs"]) == {front[:8], carried[:8]} or set(s["tabs"]) == {front, carried}]
        t.ok("dropped on the right edge: a pair, the carried tab on the right", bool(st["splits"]) and st["splits"][-1]["right"].lower()[:8] == carried.lower()[:8], st["splits"])
        for s in st["splits"]:
            sv.sp("detach", id=s["left"])
        sv.sp("select", id=front)
        time.sleep(1)

        film("left", lambda: carry_and_drop(other, [x0 + 40, mid]), 2.6)
        same_cards(t, "left")
        time.sleep(1)
        st = sv.sp("state")
        t.ok("dropped on the left edge: a pair, the carried tab on the left", bool(st["splits"]) and st["splits"][-1]["left"].lower()[:8] == other.lower()[:8], st["splits"])
        for s in st["splits"]:
            sv.sp("detach", id=s["left"])
        sv.sp("select", id=front)
        time.sleep(1)

        def waver():
            start = row_point(carried)
            marks = {}
            band = [x1 - 40, mid]
            away = [start[0] + 60, mid]
            mouse(path(start, [start[0] + 30, start[1]], 3), hold=True)
            mouse(path([start[0] + 30, start[1]], band), hold=True, resume=True)
            marks["in1"] = time.time() - 0.3
            time.sleep(0.8)
            marks["out1"] = time.time()
            mouse(path(band, away, 10), hold=True, resume=True)
            time.sleep(0.8)
            marks["in2"] = time.time()
            mouse(path(away, band, 10), hold=True, resume=True)
            time.sleep(0.8)
            marks["out2"] = time.time()
            mouse(path(band, away, 10), hold=True, resume=True)
            time.sleep(0.7)
            mouse([away, away], resume=True)
            return marks

        film("waver", waver, 5.4)
        time.sleep(1)
        st = sv.sp("state")
        t.ok("carried in and out of the band and let go: no pair", not st["splits"], st["splits"])
        sv.sp("select", id=front)
        time.sleep(0.6)

        left = opened("pair-left")
        right = opened("pair-right")
        sv.sp("select", id=left)
        sv.sp("pair", id=right, **{"with": left}, side="right")
        time.sleep(1.2)
        frames = {f["id"]: f for f in sv.sp("state")["paneFrames"]}
        rf = frames.get(right) or next(f for k, f in frames.items() if k[:8] == right[:8])
        target = [rf["x"] + rf["width"] / 2, rf["y"] + rf["height"] / 2]
        film("pair", lambda: carry_and_drop(other, target), 2.6)
        same_cards(t, "pair")
        time.sleep(1)
        st = sv.sp("state")
        t.ok("dropped on a page of a pair: it takes that page's place",
             any(other.lower()[:8] in [x.lower()[:8] for x in s["tabs"]] and left.lower()[:8] in [x.lower()[:8] for x in s["tabs"]]
                 for s in st["splits"]), st["splits"])
        (OUT / "record.json").write_text(json.dumps(record, indent=1))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

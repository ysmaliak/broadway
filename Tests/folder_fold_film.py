#!/usr/bin/env python3
"""A folder's fold and unfold on film: a test copy's own window, nothing else.

Build first (`./build.sh`), then `python3 Tests/folder_fold_film.py dark LABEL`
(or light). A folder of six tabs above four loose rows, in a world of its
own, shown so ScreenCaptureKit can take that one window. Scenes: fold and
unfold with a loose tab in front, fold and unfold with a tab of the folder
in front, a fold reversed halfway. Contact sheets (every frame of the first
half second, cropped to the sidebar) land in .context/folder-fold/LABEL/.
"""
import hashlib
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

theme = sys.argv[1] if len(sys.argv) > 1 else "dark"
label = sys.argv[2] if len(sys.argv) > 2 else "now"
sv.use("folder-fold-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "folder-fold" / label
FRAMES = ROOT / ".context" / "folder-fold" / "frames"
CAPTURE = FRAMES / "capture"
SIDEBAR = 260


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        title = self.path.strip("/").replace("%20", " ") or "Page"
        body = f"<!doctype html><title>{title}</title><p>{title}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def film(pid, number, name, act, seconds=1.0):
    folder = FRAMES / f"{name}-{theme}"
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number)], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None: break
        time.sleep(0.025)
    time.sleep(0.15)
    act()
    print(name, p.communicate()[0].strip(), flush=True)
    return folder


def sheet(name, folder, span=0.5, columns=10, height=420):
    frames = sorted(folder.glob("0*.png"))
    if not frames: return
    times = json.loads((folder / "times.json").read_text())
    settled = min(3, len(frames) - 1)
    first = hashlib.sha1(frames[settled].read_bytes()).hexdigest()
    start = next((i for i in range(settled, len(frames)) if hashlib.sha1(frames[i].read_bytes()).hexdigest() != first), settled + 1)
    start = max(0, start - 1)
    picked = [i for i in range(start, len(frames)) if times[i] - times[start] <= span]
    work = FRAMES / f"sheet-{name}"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    for n, i in enumerate(picked):
        os.symlink(frames[i], work / f"{n:04d}.png")
    rows = (len(picked) + columns - 1) // columns
    scale = 2 if subprocess.run(["sips", "-g", "pixelWidth", str(frames[0])], capture_output=True, text=True).stdout.split()[-1] > "1500" else 1
    OUT.mkdir(parents=True, exist_ok=True)
    out = OUT / f"{name}-{theme}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"crop={SIDEBAR * scale}:{height * scale}:0:0,tile={columns}x{rows}:padding=4:color=gray",
                    "-frames:v", "1", str(out)], check=True)
    print("  sheet", out.relative_to(ROOT), f"frames {start}..{picked[-1]} of {len(frames)}",
          [round((times[i] - times[start]) * 1000) for i in picked], flush=True)


def main():
    t = sv.T()
    FRAMES.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.setup(spaces=True, **{"tabs.groups": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(SIDEBAR)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        members = [sv.sp("open", url=f"{BASE}/Member {n}")["resultID"] for n in range(6)]
        loose = [sv.sp("open", url=f"{BASE}/Loose {n}")["resultID"] for n in range(4)]
        time.sleep(1.5)
        sv.cmd({"do": "group", "id": members[0], "new": True, "name": "Fold"})
        for id in members[1:]:
            sv.cmd({"do": "group", "id": id, "name": "Fold"})
        sv.sp("select", id=loose[0])
        known = [i[:8].lower() for i in members + loose]
        for blank in [k for k in sv.cmd({"do": "rowframes"})["rows"] if k not in known]:
            try:
                sv.sp("close", id=blank)
            except RuntimeError:
                pass
        time.sleep(1.2)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(0.6)

        def fold(value):
            return lambda: sv.cmd({"do": "group", "name": "Fold", "fold": True})

        for name, value in [("fold", True), ("unfold", False)]:
            sheet(name, film(pid, number, name, fold(value)))
            time.sleep(1.5)
        sv.sp("select", id=members[2])
        time.sleep(0.8)
        for name, value in [("front-fold", True), ("front-unfold", False)]:
            sheet(name, film(pid, number, name, fold(value)))
            time.sleep(1.5)
        sv.sp("select", id=loose[0])
        time.sleep(0.8)

        def turn():
            sv.cmd({"do": "group", "name": "Fold", "fold": True, "again": [0.09]})

        sheet("turn", film(pid, number, "turn", turn))
        t.ok("filmed", True)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

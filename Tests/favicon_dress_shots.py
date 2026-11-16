#!/usr/bin/env python3
import math
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
label = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("marks-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
TMP = Path("/tmp") / f"broadway-marks-{os.getpid()}"
OUT = ROOT / ".context" / "favicon-dress" / label
rl.SHOT = TMP / "shot"
S = 32
K = (0.05, 0.05, 0.06)
W = (1.0, 1.0, 1.0)


def disc(x, y, r, cx=15.5, cy=15.5):
    return math.hypot(x - cx, y - cy) <= r


def rounded(x, y, r=7):
    cx = min(max(x, r), S - 1 - r)
    cy = min(max(y, r), S - 1 - r)
    return math.hypot(x - cx, y - cy) <= r


def glyph_dark(x, y):
    return (K, 1) if disc(x, y, 13) and not disc(x, y, 7) else (K, 0)


def glyph_light(x, y):
    return (W, 1) if disc(x, y, 13) and not disc(x, y, 7) else (W, 0)


def tile_dark(x, y):
    if not rounded(x, y):
        return (K, 0)
    return (W, 1) if abs(x - 15.5) < (y - 9) * 0.6 and 9 <= y <= 22 else (K, 1)


def tile_light(x, y):
    if not rounded(x, y):
        return (W, 0)
    return ((0.3, 0.3, 0.3), 1) if abs(x - 15.5) < 2 and 8 <= y <= 23 else (W, 1)


def disc_dark(x, y):
    if not disc(x, y, 15.5):
        return (K, 0)
    return (W, 1) if disc(x, y, 5) else (K, 1)


def mixed_dark(x, y):
    if disc(x, y, 3, 11, 13) or disc(x, y, 3, 20, 13):
        return (W, 1)
    return (K, 1) if disc(x, y, 11) and not (12 < y < 15 and 4 < x < 28) else (K, 0)


def mixed_light(x, y):
    if disc(x, y, 3, 11, 13) or disc(x, y, 3, 20, 13):
        return ((0.2, 0.2, 0.2), 1)
    return (W, 1) if disc(x, y, 11) and not (12 < y < 15 and 4 < x < 28) else (W, 0)


def square_dark(x, y):
    return (K, 1)


ICONS = {"glyph-dark": glyph_dark, "glyph-light": glyph_light, "tile-dark": tile_dark, "tile-light": tile_light,
         "disc-dark": disc_dark, "mixed-dark": mixed_dark, "mixed-light": mixed_light, "square-dark": square_dark}


def png(make):
    rows = b""
    for y in range(S):
        rows += b"\0"
        for x in range(S):
            (r, g, b), a = make(x, y)
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 * a])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", S, S, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon":
            body, kind = png(ICONS[parts[1].removesuffix(".png")]), "image/png"
        else:
            body = (f"<!doctype html><meta charset=utf-8><title>{parts[1]}</title>"
                    f"<link rel=icon href='/icon/{parts[1]}.png'><p>{parts[1]}").encode()
            kind = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False})
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
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        names = list(ICONS)
        pins, loose = [], []
        for i, name in enumerate(names[:5]):
            pins.append(sv.sp("open", url=f"{BASE}/pin{i}/{name}")["resultID"])
            time.sleep(0.3)
        for i, name in enumerate(names):
            loose.append(sv.sp("open", url=f"{BASE}/row{i}/{name}")["resultID"])
            time.sleep(0.3)
        time.sleep(2)
        made = {i[:8].lower() for i in pins + loose}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError:
                    pass
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        time.sleep(1)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        for theme, ground in [("dark", "171616"), ("light", "F2EEE6"), ("dark", "3139FB")]:
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "space", "action": "look", "custom": ground, "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0})
            sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
            sv.sp("select", id=loose[2])
            time.sleep(1.5)
            still = TMP / f"{theme}-{ground}.png"
            rl.shoot(pid, number, still)
            k = rl.scale_of(still)
            out = OUT / f"{theme}-{ground}.png"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                            f"crop={272 * k}:{480 * k}:0:{60 * k}", str(out)], check=True)
            print(out)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        server.shutdown()


if __name__ == "__main__":
    main()

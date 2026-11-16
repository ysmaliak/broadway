#!/usr/bin/env python3
import os
import shutil
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "now"
theme = sys.argv[2] if len(sys.argv) > 2 else "dark"
sv.use("pin-mesh-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
WORK = CONTEXT / "pin-mesh-shots"
SHOT = WORK / "shot"

ICONS = {
    "teal": [(0.08, 0.68, 0.7)],
    "red": [(0.9, 0.16, 0.14)],
    "blue": [(0.15, 0.42, 0.95)],
    "grey": [(0.52, 0.52, 0.52)],
    "white": [(1, 1, 1)],
    "black": [(0.06, 0.06, 0.07)],
    "duo": [(0.98, 0.55, 0.1), (0.1, 0.62, 0.72)],
}


def png(colours, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = dx * dx + dy * dy <= (side / 2 - 1) ** 2
            hole = abs(dx) < 3 and abs(dy) < 8 and len(colours) == 1 and colours[0] not in [(1, 1, 1), (0.06, 0.06, 0.07)]
            r, g, b = colours[0] if len(colours) == 1 or x < side / 2 else colours[1]
            if hole:
                r = g = b = 1
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 if inside else 0])
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("/")[-1].removesuffix(".png")
        if self.path.startswith("/icon/") and name in ICONS:
            body, kind = png(ICONS[name]), "image/png"
        else:
            body = (f"<!doctype html><title>{name}</title><link rel=icon href='/icon/{name}.png'>"
                    f"<p>{name}").encode()
            kind = "text/html"
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists():
        raise RuntimeError(out or "no still")


def main():
    t = sv.T()
    shutil.rmtree(WORK / f"{label}-{theme}", ignore_errors=True)
    folder = WORK / f"{label}-{theme}"
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 640, "steps": 1})
        ids = {}
        for name in ICONS:
            ids[name] = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
            time.sleep(0.6)
        sv.page("loose")
        time.sleep(3)
        for name in ICONS:
            sv.cmd({"do": "pin", "id": ids[name]})
        time.sleep(1)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        shots = 0
        rows = []
        for glass in [False, True]:
            sv.cmd({"do": "space", "action": "look", "glass": glass, "transparency": 0.5 if glass else 0})
            time.sleep(1)
            cuts = []
            for name in ICONS:
                sv.sp("select", id=ids[name])
                time.sleep(1.2)
                frames = sv.cmd({"do": "rowframes"})["rows"]
                tiles = [frames[i[:8].lower()] for i in ids.values() if i[:8].lower() in frames]
                still = folder / f"{'glass' if glass else 'flat'}-{name}.png"
                shoot(pid, number, still)
                shots += 1
                left = min(f[0] for f in tiles) - 8
                top = min(f[1] for f in tiles) - 8
                right = max(f[0] + f[2] for f in tiles) + 8
                bottom = max(f[1] + f[3] for f in tiles) + 8
                cut = folder / f"cut-{'glass' if glass else 'flat'}-{name}.png"
                crop = f"crop={int((right - left) * 2)}:{int((bottom - top) * 2)}:{int(left * 2)}:{int(top * 2)}"
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", crop, str(cut)], check=True)
                cuts.append(cut)
            row = folder / f"row-{'glass' if glass else 'flat'}.png"
            inputs = sum([["-i", str(c)] for c in cuts], [])
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                            f"hstack=inputs={len(cuts)}", str(row)], check=True)
            rows.append(row)
        sheet = CONTEXT / f"pins-{label}-{theme}.png"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(rows[0]), "-i", str(rows[1]),
                        "-filter_complex", "vstack=inputs=2", str(sheet)], check=True)
        shutil.copy(folder / "flat-teal.png", CONTEXT / f"pins-{label}-{theme}-window.png")
        t.ok(f"{shots} stills in {theme}", shots == 2 * len(ICONS))
        print(sheet)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

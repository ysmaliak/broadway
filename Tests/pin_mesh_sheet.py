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
sv.use("pin-sheet-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
CONTEXT = ROOT / ".context"
OUT = CONTEXT / "pin-mesh"
WORK = OUT / f"work-{label}-{theme}"
SHOT = WORK / "shot"
COLUMNS = 6

REAL = ["https://github.com", "https://linear.app", "https://www.youtube.com", "https://www.figma.com",
        "https://www.notion.com", "https://news.ycombinator.com"]

ICONS = {
    "teal": [(0.08, 0.68, 0.7)],
    "teal2": [(0.08, 0.68, 0.7)],
    "red": [(0.9, 0.16, 0.14)],
    "blue": [(0.15, 0.42, 0.95)],
    "green": [(0.2, 0.75, 0.3)],
    "purple": [(0.55, 0.25, 0.9)],
    "yellow": [(0.98, 0.8, 0.1)],
    "pink": [(0.95, 0.3, 0.6)],
    "duo": [(0.98, 0.55, 0.1), (0.1, 0.62, 0.72)],
    "bluegold": [(0.15, 0.35, 0.9), (0.98, 0.78, 0.1)],
    "greenpink": [(0.15, 0.7, 0.35), (0.92, 0.25, 0.55)],
    "rgb": [(0.9, 0.15, 0.15), (0.15, 0.75, 0.25), (0.15, 0.35, 0.95)],
    "trio": [(0.98, 0.5, 0.1), (0.6, 0.2, 0.85), (0.1, 0.75, 0.85)],
    "grey": [(0.52, 0.52, 0.52)],
    "white": [(1, 1, 1)],
    "black": [(0.06, 0.06, 0.07)],
    "black2": [(0.06, 0.06, 0.07)],
    "navy": [(0.1, 0.15, 0.35)],
}


def png(colours, side=32):
    rows = b""
    plain = [(1, 1, 1), (0.06, 0.06, 0.07)]
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = dx * dx + dy * dy <= (side / 2 - 1) ** 2
            hole = abs(dx) < 3 and abs(dy) < 8 and len(colours) == 1 and colours[0] not in plain
            r, g, b = colours[min(len(colours) - 1, int(x * len(colours) / side))]
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
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
    shutil.rmtree(WORK, ignore_errors=True)
    WORK.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "300"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    names = []
    try:
        sv.cmd({"do": "resize", "width": 1100, "height": 900, "steps": 1})
        ids = {}
        for url in REAL:
            name = url.split("//")[1].removeprefix("www.").split(".")[0]
            ids[name] = sv.sp("open", url=url)["resultID"]
            time.sleep(0.4)
        for name in ICONS:
            ids[name] = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
            time.sleep(0.4)
        sv.page("loose")
        time.sleep(8)
        for id in ids.values():
            sv.cmd({"do": "pin", "id": id})
        time.sleep(2)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        for glass in [False, True]:
            sv.cmd({"do": "space", "action": "look", "glass": glass, "transparency": 0.5 if glass else 0})
            time.sleep(1)
            cuts = []
            for name, id in ids.items():
                sv.sp("select", id=id)
                time.sleep(1.0)
                frames = sv.cmd({"do": "rowframes"})["rows"]
                frame = frames.get(id[:8].lower())
                if not frame:
                    continue
                still = WORK / "still.png"
                if still.exists():
                    still.unlink()
                shoot(pid, number, still)
                pad = 6
                x, y, w, h = frame
                info = subprocess.run(["sips", "-g", "pixelWidth", str(still)], capture_output=True, text=True).stdout.split()
                k = max(1, round(int(info[-1]) / 1100))
                cut = WORK / f"{'glass' if glass else 'flat'}-{len(cuts):02d}-{name}.png"
                crop = (f"crop={int((w + 2 * pad) * k)}:{int((h + 2 * pad) * k)}:{int((x - pad) * k)}:{int((y - pad) * k)},"
                        f"scale=iw*{2 // k}:ih*{2 // k}:flags=neighbor")
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", crop, str(cut)], check=True)
                cuts.append(cut)
                if not glass:
                    names.append(name)
            count = len(cuts)
            rows = (count + COLUMNS - 1) // COLUMNS
            def place(i):
                across = "+".join(f"w{k}" for k in range(i % COLUMNS)) or "0"
                down = "+".join(f"h{k * COLUMNS}" for k in range(i // COLUMNS)) or "0"
                return f"{across}_{down}"
            layout = "|".join(place(i) for i in range(count))
            inputs = sum([["-i", str(c)] for c in cuts], [])
            sheet = OUT / f"{label}-{theme}-{'glass' if glass else 'flat'}.png"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                            f"xstack=inputs={count}:layout={layout}:fill=gray", str(sheet)], check=True)
            t.ok(f"{count} tiles {'glass' if glass else 'flat'} {theme}", count == len(ids) and rows * COLUMNS >= count)
            print(sheet)
        (OUT / "order.txt").write_text(" ".join(names) + "\n")
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

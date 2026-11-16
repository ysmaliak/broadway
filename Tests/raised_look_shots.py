#!/usr/bin/env python3
"""Pin squares and folder cards side by side, pictured: one raised material.

Build first (`./build.sh`), then `python3 Tests/raised_look_shots.py [label]`.
Seven pins, three loose rows, a folder of two and a live folder on four
grounds (pale F2EEE6, vivid 3139FB, black 000000, the user's near-black
171616 and an orange FF8A1F whose ink is lifted), light and dark, at rest and with a pin and the folder's heading
hovered. Window-only stills of a test copy; crops of the column land in
.context/raised-look/<label>/ with a sheet per theme, and the pixels the
report quotes (ground, fill, edge, a shadow's trace) in measure.json.
"""
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
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "now"
sv.use("raised-look-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
WORK = CONTEXT / "raised-look"
SHOT = WORK / "shot"
PIXEL = WORK / "pixel"

ICONS = {
    "red": (0.9, 0.12, 0.1), "violet": (0.45, 0.3, 0.85), "black": (0.06, 0.06, 0.07), "teal": (0.08, 0.68, 0.7),
    "blue": (0.15, 0.42, 0.95), "grey": (0.52, 0.52, 0.52), "orange": (0.98, 0.45, 0.1), "green": (0.2, 0.7, 0.3),
}
PINS = ["black", "orange", "black", "blue", "grey", "orange", "red"]
LOOSE = [("violet", "Orbit Dashboard"), ("orange", "Fernwood"), ("black", "Promo Kit")]
FOLDER = ("YouTube", [("red", "YouTube"), ("red", "I bought a used hatchback and")])
GROUNDS = {"pale": "F2EEE6", "vivid": "3139FB", "black": "000000", "near": "171616", "orange": "FF8A1F"}

PIXEL_SOURCE = r"""
import AppKit
let a = CommandLine.arguments
let rep = NSBitmapImageRep(data: FileManager.default.contents(atPath: a[1])!)!
var p = [Int](repeating: 0, count: 4)
var out: [String] = []
var i = 2
while i + 1 < a.count {
    rep.getPixel(&p, atX: Int(a[i])!, y: Int(a[i + 1])!)
    out.append("[\(p[0]),\(p[1]),\(p[2])]")
    i += 2
}
print("[" + out.joined(separator: ",") + "]")
"""


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = abs(dx) <= side / 2 - 3 and abs(dy) <= side / 2 - 3
            r, g, b = colour
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 if inside else 0])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon" and parts[-1].removesuffix(".png") in ICONS:
            body, kind = png(ICONS[parts[-1].removesuffix(".png")]), "image/png"
        else:
            icon = parts[1] if len(parts) > 1 else "red"
            title = bytes.fromhex(parts[-1]).decode() if len(parts) > 2 else parts[0]
            body = (f"<!doctype html><meta charset=utf-8><title>{title}</title>"
                    f"<link rel=icon href='/icon/{icon}.png'><p>{title}").encode()
            kind = "text/html; charset=utf-8"
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
counter = [0]


def opened(icon, title):
    counter[0] += 1
    id = sv.sp("open", url=f"{BASE}/p{counter[0]}/{icon}/{title.encode().hex()}")["resultID"]
    time.sleep(0.3)
    return id


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists():
        raise RuntimeError(out or "no still")


def cut(still, path, width, height):
    k = scale_of(still)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                    f"crop={width * k}:{height * k}:0:0", str(path)], check=True)

def scale_of(still, width=1000):
    out = subprocess.run(["sips", "-g", "pixelWidth", str(still)], capture_output=True, text=True).stdout.split()
    return max(1, round(int(out[-1]) / width)) if out and out[-1].isdigit() else 2



def pixels(still, points):
    args = [str(PIXEL), str(still)] + [str(int(v)) for p in points for v in p]
    return json.loads(subprocess.run(args, capture_output=True, text=True).stdout)


def trace(still, x, top, bottom):
    """Each change of colour down one column of device pixels, from top to bottom (points)."""
    k = scale_of(still)
    ys = list(range(round(top * k), round(bottom * k)))
    got = pixels(still, [(round(x * k), y) for y in ys])
    out, last = [], None
    for y, p in zip(ys, got):
        if p != last:
            out.append([y, p])
            last = p
    return out


def main():
    t = sv.T()
    folder = WORK / label
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    (WORK / "pixel.swift").write_text(PIXEL_SOURCE)
    subprocess.run(["swiftc", "-O", str(WORK / "pixel.swift"), "-o", str(PIXEL)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "284"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    report = {}
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 860, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        pins = [opened(icon, f"Pin {n}") for n, icon in enumerate(PINS)]
        loose = [opened(icon, title) for icon, title in LOOSE]
        kept = [opened(icon, title) for icon, title in FOLDER[1]]
        time.sleep(2)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": kept[0], "new": True, "name": FOLDER[0]})
        for id in kept[1:]:
            sv.cmd({"do": "group", "id": id, "name": FOLDER[0]})
        sv.cmd({"do": "live", "args": ["on"]})
        sv.cmd({"do": "live", "args": ["add", "PRs", "https://github.com/pulls"]})
        time.sleep(0.6)
        sv.sp("select", id=loose[0])
        for blank in [k for k, v in sv.cmd({"do": "rowframes"})["rows"].items()
                      if k not in [i[:8].lower() for i in pins + loose + kept]]:
            try:
                sv.sp("close", id=blank)
            except RuntimeError:
                pass
        time.sleep(1.5)
        frames = sv.cmd({"do": "rowframes"})
        rows = frames["rows"]
        pin_box = rows.get(pins[1][:8].lower())
        member = rows.get(kept[0][:8].lower())
        t.ok("a pin and a folder row are laid out", pin_box is not None and member is not None, rows)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        cuts = {}
        for theme in ["dark", "light"]:
            for ground, hex in GROUNDS.items():
                sv.cmd({"do": "ui", "look": theme})
                sv.cmd({"do": "space", "action": "look", "custom": hex, "intensity": 1.0,
                        "glass": False, "transparency": 0, "grain": 0})
                sv.cmd({"do": "ui", "windowPointer": [700, 500], "pointerPhase": "move"})
                time.sleep(1.2)
                for state in ["rest", "hover"]:
                    name = f"{theme}-{ground}-{state}"
                    if state == "hover":
                        sv.cmd({"do": "rowhover", "id": pins[1][:8], "on": True})
                        time.sleep(0.8)
                    still = folder / f"{name}.png"
                    shoot(pid, number, still)
                    cuts[name] = folder / f"cut-{name}.png"
                    cut(still, cuts[name], 300, 470)
                    report[name] = {"pin": trace(still, pin_box[0] + pin_box[2] / 2, pin_box[1] - 6, pin_box[1] + pin_box[3] + 6),
                                    "card": trace(still, member[0] + member[2] / 2, member[1] - 60, member[1] - 30)}
                sv.cmd({"do": "rowhover", "id": pins[1][:8], "on": False})
        sv.cmd({"do": "space", "action": "look", "custom": GROUNDS["near"], "intensity": 1.0,
                "glass": False, "transparency": 0, "grain": 0})
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme, "cards": False})
            time.sleep(1.4)
            name = f"{theme}-nocards"
            still = folder / f"{name}.png"
            shoot(pid, number, still)
            cut(still, folder / f"cut-{name}.png", 300, 470)
            frames = sv.cmd({"do": "rowframes"})["rows"]
            box, row = frames.get(pins[1][:8].lower()), frames.get(kept[0][:8].lower())
            if box and row:
                report[name] = {"pin": trace(still, box[0] + box[2] / 2, box[1] - 6, box[1] + box[3] + 6),
                                "card": trace(still, row[0] + row[2] / 2, row[1] - 60, row[1] - 30)}
        sv.cmd({"do": "ui", "cards": True})
        (folder / "measure.json").write_text(json.dumps(report, indent=1))
        t.ok(f"{len(cuts)} stills", len(cuts) == 4 * len(GROUNDS))
        for theme in ["dark", "light"]:
            for state in ["rest", "hover"]:
                names = [f"{theme}-{g}-{state}" for g in GROUNDS]
                inputs = sum([["-i", str(cuts[n])] for n in names], [])
                sheet = folder / f"sheet-{theme}-{state}.png"
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                                f"hstack=inputs={len(names)}", str(sheet)], check=True)
                print(sheet)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

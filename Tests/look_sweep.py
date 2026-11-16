#!/usr/bin/env python3
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
gradients = "--gradients" in sys.argv
quick = "--quick" in sys.argv
QUICK = {("black", m) for m in ["flat", "grain", "clear", "glass"]} | {(n, "flat") for n in ["navy", "arc-blue", "hot-red", "white"]}
STRENGTH = 0.8
sv.use("look-sweep-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
OUT = CONTEXT / f"sweep-{label}"
WORK = CONTEXT / "look-sweep-tools"
SHOT = WORK / "shot"
SHEET = WORK / "sheet"
POP = WORK / "popover"
PIXEL = WORK / "pixel"
FULL = 2.0

SWATCHES = [
    ("white", "FFFFFF"), ("off-white", "FFFCEC"), ("pale-pink", "FFD3E0"), ("pastel-yellow", "FFF0A6"),
    ("neon-yellow", "E8FF1A"), ("lime", "8BE33A"), ("teal", "0F9D94"), ("sky", "7CC4F2"),
    ("arc-blue", "3139FB"), ("navy", "000354"), ("purple", "7B3FE4"), ("hot-red", "FB3A4D"),
    ("orange", "FF8A1F"), ("brown", "7A4B2C"), ("mid-grey", "808080"), ("black", "000000"),
]
GLASS = ["pastel-yellow", "sky", "arc-blue", "black"]
EXTREMES = [
    ("black", "000000"), ("near-black", "0A0A0A"), ("navy", "000354"), ("deep-blue", "2404AA"),
    ("arc-blue", "3139FB"), ("hot-red", "FB3A4D"), ("neon-green", "39FF14"), ("white", "FFFFFF"),
]
MATERIALS = [
    ("flat", {"glass": False, "transparency": 0, "grain": 0}),
    ("grain", {"glass": False, "transparency": 0, "grain": 0.5}),
    ("clear", {"glass": False, "transparency": 0.5, "grain": 0}),
    ("glass", {"glass": True, "transparency": 0.5, "grain": 0}),
]
BLENDS = [
    ("sunset", ["FF89B3", "FF8A1F"]), ("ocean", ["0F9D94", "3139FB"]),
    ("aurora", ["8BE33A", "7CC4F2", "7B3FE4"]), ("dusk", ["000354", "FB3A4D", "F0B4FF"]),
]

ICONS = {
    "red": (0.9, 0.12, 0.1), "violet": (0.45, 0.3, 0.85), "black": (0.06, 0.06, 0.07), "teal": (0.08, 0.68, 0.7),
    "blue": (0.15, 0.42, 0.95), "grey": (0.52, 0.52, 0.52), "white": (0.98, 0.98, 0.98), "yellow": (0.98, 0.8, 0.1),
}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = dx * dx + dy * dy <= (side / 2 - 1) ** 2
            r, g, b = colour
            if abs(dx) < 5 and abs(dy) < 5:
                r, g, b = (1, 1, 1) if sum(colour) < 2.4 else (0.1, 0.1, 0.1)
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
                    f"<link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='font:15px -apple-system;margin:40px;color:#222;background:#fff'>"
                    f"<h1>{title}</h1><p>A page in the card.</p>").encode()
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


def page(n, icon, title):
    return f"{BASE}/p{n}/{icon}/{title.encode().hex()}"


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists():
        raise RuntimeError(out or "no still")


def sheet(path, cells, columns=4):
    subprocess.run([str(SHEET), str(path), str(columns), "1240", "1520", *[f"{n}={p}" for n, p in cells]], check=True)


def main():
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    (OUT / "shots").mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/ContactSheet.swift"), "-o", str(SHEET)], check=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/PopoverShot.swift"), "-o", str(POP)], check=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/GroundPixel.swift"), "-o", str(PIXEL)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
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
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        sv.cmd({"do": "space", "action": "new", "name": "Play"})
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1)

        def opened(n, icon, title):
            id = sv.sp("open", url=page(n, icon, title))["resultID"]
            time.sleep(0.25)
            return id
        pins = [opened(n, icon, f"Fav {n}") for n, icon in enumerate(["red", "blue", "black", "teal", "violet", "yellow"])]
        pinned = [opened(20 + n, icon, title) for n, (icon, title) in
                  enumerate([("blue", "Team calendar"), ("grey", "Design review notes")])]
        kept = [opened(40 + n, icon, title) for n, (icon, title) in
                enumerate([("red", "Recipes to try"), ("teal", "Trip to Lisbon"), ("white", "Reading list")])]
        today = [opened(60 + n, icon, title) for n, (icon, title) in enumerate([
            ("blue", "Inbox (3) — Mail"), ("black", "GitHub · Pull requests"), ("yellow", "Weekend plans"),
            ("violet", "Music for focus"), ("teal", "Weather in Lisbon"), ("grey", "Docs — Quarterly plan"),
            ("red", "Hacker News"), ("white", "A very long article title that runs past the column's edge")])]
        time.sleep(2.5)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": pinned[0], "new": True, "name": "Pinned"})
        sv.cmd({"do": "group", "id": pinned[1], "name": "Pinned"})
        sv.cmd({"do": "group", "name": "Pinned", "pinned": True})
        sv.cmd({"do": "group", "id": kept[0], "new": True, "name": "Someday"})
        for id in kept[1:]:
            sv.cmd({"do": "group", "id": id, "name": "Someday"})
        sv.sp("select", id=today[2])
        time.sleep(1.5)
        sv.cmd({"do": "ui", "glassBars": []})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        rows = sv.cmd({"do": "rowframes"})["rows"]
        over = rows.get(today[4][:8].lower())
        t.ok("a row to hover", over is not None, rows)

        def hover():
            if over:
                sv.cmd({"do": "ui", "windowPointer": [over[0] + over[2] / 2, over[1] + over[3] / 2], "pointerPhase": "move"})

        cells = {"light": [], "dark": [], "glass": [], "blend": [], "extreme-light": [], "extreme-dark": []}
        pixels = {}

        def take(group, name, look, theme):
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "space", "action": "look", **look})
            time.sleep(0.5)
            hover()
            time.sleep(0.9)
            still = OUT / "shots" / f"{theme}-{name}.png"
            shoot(pid, number, still)
            cells[group].append((f"{theme} {name}", still))
            if group.startswith("extreme"):
                read = subprocess.run([str(PIXEL), str(still), "0.03", "0.76", "0.23", "0.95"], capture_output=True, text=True).stdout
                pixels[f"{theme} {name}"] = json.loads(read or "{}")

        flat = {"glass": False, "transparency": 0, "grain": 0, "intensity": STRENGTH}
        for theme in ([] if quick else ["light", "dark"]):
            for name, hex in SWATCHES:
                take(theme, name, {"custom": hex, **flat}, theme)
        for theme in ([] if quick else ["light", "dark"]):
            for name, hex in SWATCHES:
                if name in GLASS:
                    take("glass", name + " glass", {"custom": hex, "glass": True, "transparency": 0.5, "grain": 0, "intensity": STRENGTH}, theme)
            take("glass", "sky grain", {"custom": dict(SWATCHES)["sky"], **flat, "grain": 0.5}, theme)
            take("glass", "navy grain", {"custom": dict(SWATCHES)["navy"], **flat, "grain": 0.5}, theme)
        for theme in ["light", "dark"]:
            for name, hex in EXTREMES:
                for material, settings in MATERIALS:
                    if quick and (name, material) not in QUICK:
                        continue
                    take(f"extreme-{theme}", f"{name} {material}", {"custom": hex, **settings, "intensity": FULL}, theme)
        if gradients:
            for theme in ["light", "dark"]:
                for name, colours in BLENDS:
                    take("blend", name, {"colours": colours, **flat, "grain": 0.25}, theme)
        if gradients:
            for theme in ["light", "dark"]:
                sv.cmd({"do": "ui", "look": theme})
                sv.cmd({"do": "space", "action": "look", "colours": ["FF89B3", "FF8A1F"], "intensity": 0.75, **{k: v for k, v in flat.items() if k != "intensity"}, "grain": 0.25})
                time.sleep(0.6)
                sv.cmd({"do": "ui", "editlook": True})
                time.sleep(1.2)
                print(subprocess.run([str(POP), str(pid), str(number), str(OUT / f"picker-{theme}.png")], capture_output=True, text=True).stdout.strip())
                shoot(pid, number, OUT / f"picker-window-{theme}.png")
                sv.cmd({"do": "ui", "editlook": False})
                time.sleep(0.6)
        sv.cmd({"do": "ui", "look": "light"})
        for group, items in cells.items():
            if items:
                sheet(OUT / f"{group}.png", items)
        t.ok("every still taken", all(p.exists() for items in cells.values() for _, p in items))
        (OUT / "index.json").write_text(json.dumps({g: [n for n, _ in i] for g, i in cells.items()}, indent=1))
        (OUT / "pixels.json").write_text(json.dumps(pixels, indent=1))
        for name, read in pixels.items():
            print(f"{name:28} {read.get('mode')} share {read.get('modeShare')} mean {read.get('mean')}")
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Stacked spaces, pictured: window-only stills of a test copy in three looks.

Build first (`./build.sh`), then `python3 Tests/stacked_look_shots.py [label]`.
Four spaces (Personal, Work, Reading, Travel) with pins, a live folder, a
normal folder and 5 to 12 tabs each, Travel folded, stacked mode on. The
active space wears a dark navy, a pale and a glass look in turn, light and
dark; the others keep their own colours. Each look is taken at the top and
scrolled so a header is held at the top. Sheets land in
.context/stacked-look/<label>/.
"""
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
sv.use("stacked-look-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
WORK = CONTEXT / "stacked-look"
SHOT = WORK / "shot"

ICONS = {
    "red": (0.9, 0.12, 0.1), "violet": (0.45, 0.3, 0.85), "black": (0.06, 0.06, 0.07), "teal": (0.08, 0.68, 0.7),
    "blue": (0.15, 0.42, 0.95), "grey": (0.52, 0.52, 0.52), "yellow": (0.98, 0.8, 0.1), "green": (0.2, 0.7, 0.3),
}
SPACES = {
    "Personal": {
        "icon": "🏠",
        "pins": [("red", "YouTube")],
        "folder": ("Recipes", [("green", "Pasta e ceci"), ("yellow", "Lemon tart"), ("red", "Shakshuka")]),
        "tabs": [("yellow", "Reading list"), ("red", "YouTube"), ("black", "A farewell to Arc"),
                 ("teal", "Weather in Lisbon"), ("violet", "Music for focus"), ("grey", "Hacker News")],
    },
    "Work": {
        "icon": "💼",
        "pins": [("blue", "Meet"), ("teal", "Calendar")],
        "live": True,
        "folder": ("Sprint 42", [("blue", "Roadmap"), ("grey", "Retro notes"), ("violet", "Design review")]),
        "tabs": [("black", ":8766 Wide Layout Pass"), ("blue", "Inbox (3) — Mail"), ("black", "GitHub · Pull requests"),
                 ("grey", "Docs — Quarterly plan"), ("violet", "Figma — Sidebar"), ("teal", "Linear — Cycle 12"),
                 ("red", "Incident review"), ("yellow", "Standup notes"), ("blue", "Status page"),
                 ("grey", "A very long article title that runs past the column's edge")],
    },
    "Reading": {
        "icon": "📚",
        "pins": [],
        "folder": ("Someday", [("grey", "Essays"), ("teal", "Long reads")]),
        "tabs": [("black", "The Atlantic"), ("grey", "Paul Graham — Essays"), ("teal", "Aeon"),
                 ("violet", "Quanta Magazine"), ("yellow", "Stratechery")],
    },
    "Travel": {
        "icon": "✈️",
        "pins": [],
        "folder": None,
        "tabs": [("blue", "Flights to Lisbon"), ("teal", "Hotels in Alfama"), ("yellow", "Tram 28"),
                 ("green", "Sintra day trip"), ("red", "Pastéis de Belém")],
    },
}
OTHERS = {"Work": "3139FB", "Reading": "2E9E6A", "Travel": "FF8A1F"}
LOOKS = {
    "navy": {"custom": "000354", "intensity": 0.9, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "FFF1C9", "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0},
    "glass": {"custom": "FF8A1F", "intensity": 0.8, "glass": True, "transparency": 0.5, "grain": 0},
}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = dx * dx + dy * dy <= (side / 2 - 2) ** 2
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
    time.sleep(0.25)
    return id


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists():
        raise RuntimeError(out or "no still")


def cut(still, path, width, height=None):
    k = scale_of(still)
    crop = f"crop={width * k}:{height * k if height else 'ih'}:0:0"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", crop, str(path)], check=True)


def scale_of(still, width=1000):
    out = subprocess.run(["sips", "-g", "pixelWidth", str(still)], capture_output=True, text=True).stdout.split()
    return max(1, round(int(out[-1]) / width)) if out and out[-1].isdigit() else 2


def fill(name, spec):
    pins = [opened(icon, title) for icon, title in spec["pins"]]
    loose = [opened(icon, title) for icon, title in spec["tabs"]]
    kept = [opened(icon, title) for icon, title in spec["folder"][1]] if spec["folder"] else []
    time.sleep(1.5)
    for id in pins:
        sv.cmd({"do": "pin", "id": id})
    if kept:
        folder = spec["folder"][0]
        sv.cmd({"do": "group", "id": kept[0], "new": True, "name": folder})
        for id in kept[1:]:
            sv.cmd({"do": "group", "id": id, "name": folder})
    if spec.get("live"):
        sv.cmd({"do": "live", "args": ["on"]})
        sv.cmd({"do": "live", "args": ["add", "PRs", "https://github.com/pulls"]})
        time.sleep(0.6)
    for blank in [k for k, v in sv.cmd({"do": "rowframes"})["rows"].items()
                  if k not in [i[:8].lower() for i in pins + loose + kept]]:
        try:
            sv.sp("close", id=blank)
        except RuntimeError:
            pass
    return loose


def main():
    t = sv.T()
    folder = WORK / label
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 860, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        ids = {}
        firsts = {}
        for index, (name, spec) in enumerate(SPACES.items()):
            if index:
                ids[name] = sv.sp("space", spaceAction="new", name=name)["spaceID"]
            else:
                ids[name] = sv.sp("state")["spaceID"]
            sv.cmd({"do": "space", "action": "rename", "name": name, "icon": spec["icon"]})
            firsts[name] = fill(name, spec)
            if name in OTHERS:
                sv.cmd({"do": "space", "action": "look", "custom": OTHERS[name], "intensity": 0.8,
                        "glass": False, "transparency": 0, "grain": 0})
        sv.sp("space", spaceAction="go", spaceID=ids["Personal"])
        sv.sp("select", id=firsts["Personal"][1])
        sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
        time.sleep(1.2)
        sv.cmd({"do": "stacked", "action": "fold", "space": 4, "on": True})
        time.sleep(1)
        r = sv.cmd({"do": "stacked"})
        t.ok("stacked, four sections", r["stacked"] and len(r["sections"]) == 4, [s["name"] for s in r["sections"]])
        t.ok("Travel folded", r["sections"][3]["folded"] is True)
        sv.cmd({"do": "ui", "glassBars": []})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        cuts = {}

        def take(name, height=None):
            still = folder / f"{name}.png"
            shoot(pid, number, still)
            cuts[name] = folder / f"cut-{name}.png"
            cut(still, cuts[name], 300, height)

        variants = [("", None)]
        for suffix, _ in variants:
            for theme in ["dark", "light"]:
                for look, settings in LOOKS.items():
                    sv.cmd({"do": "ui", "look": theme})
                    sv.cmd({"do": "space", "action": "look", **settings})
                    time.sleep(0.8)
                    for _ in range(4):
                        sv.cmd({"do": "columnscroll", "wheel": -800})
                        time.sleep(0.3)
                    time.sleep(1.0)
                    take(f"{theme}-{look}{suffix}")
                    sv.cmd({"do": "columnscroll", "wheel": 420})
                    time.sleep(1.0)
                    take(f"{theme}-{look}-scrolled{suffix}")
        t.ok(f"{len(cuts)} stills", len(cuts) == 12 * len(variants))
        for suffix, _ in variants:
            for kind in ["", "-scrolled"]:
                names = [f"{theme}-{look}{kind}{suffix}" for theme in ["dark", "light"] for look in LOOKS]
                inputs = sum([["-i", str(cuts[n])] for n in names], [])
                sheet = folder / f"sheet{kind}{suffix}.png"
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                                f"hstack=inputs={len(names)}", str(sheet)], check=True)
                print(sheet)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

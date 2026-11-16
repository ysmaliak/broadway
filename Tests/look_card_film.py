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
parts = set(sys.argv[2:]) or {"switch", "fold", "mode"}
sv.use("look-film-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "look-card" / f"film-{label}"
WORK = ROOT / ".context" / "look-card-tools"
STRIP = WORK / "film-strip"
COLOURS = {"red": (0.9, 0.12, 0.1), "blue": (0.15, 0.42, 0.95), "teal": (0.08, 0.68, 0.7), "violet": (0.45, 0.3, 0.85),
           "yellow": (0.98, 0.8, 0.1), "grey": (0.52, 0.52, 0.52)}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = dx * dx + dy * dy <= (side / 2 - 1) ** 2
            r, g, b = colour
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 if inside else 0])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon":
            body, kind = png(COLOURS.get(parts[-1].removesuffix(".png"), (0.5, 0.5, 0.5))), "image/png"
        else:
            icon = parts[1] if len(parts) > 1 else "red"
            title = bytes.fromhex(parts[-1]).decode() if len(parts) > 2 else parts[0]
            body = (f"<!doctype html><meta charset=utf-8><title>{title}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='font:15px -apple-system;margin:40px;color:#222;background:#fff'><h1>{title}</h1>").encode()
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
count = [0]


def opened(icon, title):
    count[0] += 1
    id = sv.sp("open", url=f"{BASE}/p{count[0]}/{icon}/{title.encode().hex()}")["resultID"]
    time.sleep(0.3)
    return id


def fill():
    pins = [opened(i, f"Pin {n}") for n, i in enumerate(["red", "blue", "teal", "violet"])]
    kept = [opened(i, t) for i, t in [("yellow", "Trip notes"), ("grey", "Reading list")]]
    loose = [opened(i, t) for i, t in [("blue", "Inbox"), ("teal", "Calendar"), ("violet", "Design review")]]
    time.sleep(1.5)
    for id in pins:
        sv.cmd({"do": "pin", "id": id})
    sv.cmd({"do": "group", "id": kept[0], "new": True, "name": "Someday"})
    sv.cmd({"do": "group", "id": kept[1], "name": "Someday"})
    for blank in [k for k in sv.cmd({"do": "rowframes"})["rows"] if k not in [i[:8].lower() for i in pins + kept + loose]]:
        try:
            sv.sp("close", id=blank)
        except RuntimeError:
            pass
    return loose


def film(name, action, frames=40, every=0.03, target=None):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    ask = {"do": "film", "action": action, "path": str(folder / "f"), "frames": frames, "every": every, "region": "full"}
    if target:
        ask["target"] = target
    said = sv.cmd(ask)
    shots = said.get("frames", [])
    for index, shot in enumerate(shots):
        drawn = Path(shot.get("file", ""))
        if drawn.is_file():
            drawn.rename(folder / f"{index:04d}.png")
            shot["file"] = str(folder / f"{index:04d}.png")
    (folder / "frames.json").write_text(json.dumps([{k: v for k, v in f.items() if k in ("t", "size", "file")} for f in shots], indent=1))
    sizes = [f.get("size", [0, 0])[1] for f in shots]
    print(f"  {name}: {len(shots)} frames over {shots[-1]['t'] if shots else 0} ms, heights {sizes[:3]} .. {sizes[-3:]}")
    return shots


def heights():
    return sv.cmd({"do": "ui", "lookHeights": True}).get("heights", [])


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    report = {}
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False, "split": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "250"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 860, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        home = sv.sp("state")["spaceID"]
        sv.cmd({"do": "space", "action": "rename", "name": "Home"})
        loose = fill()
        sv.sp("pair", id=loose[1], **{"with": loose[0]}, side="right")
        sv.cmd({"do": "space", "action": "look", "colour": "sky", "mode": "both", "shade": "dark",
                "dark": {"swatch": "midnight"}, "light": {"swatch": "peach"}})
        work = sv.sp("space", spaceAction="new", name="Work")["spaceID"]
        fill()
        sv.cmd({"do": "space", "action": "look", "colour": "sage", "mode": "one", "shade": "dark"})
        sv.sp("space", spaceAction="new", name="Play")
        fill()
        sv.cmd({"do": "space", "action": "look", "colour": "rose"})
        sv.sp("space", spaceAction="go", spaceID=home)
        time.sleep(1)
        sv.cmd({"do": "ui", "glassBars": []})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        pid = next(iter(sv.holding() & sv.running()))

        def stills(name):
            (OUT / "stills").mkdir(exist_ok=True)
            for appearance in ["light", "dark"]:
                sv.cmd({"do": "ui", "look": appearance})
                time.sleep(2)
                sv.cmd({"do": "ui", "hovercard": "off"})
                time.sleep(0.4)
                path = OUT / "stills" / f"{name}-{appearance}.png"
                subprocess.run([str(WORK / "shot"), str(pid), str(number), str(path)], capture_output=True)

        if "stills" in parts:
            stills("light-and-dark-split")
            sv.sp("space", spaceAction="go", spaceID=work)
            stills("one-colour")
            sv.sp("space", spaceAction="go", spaceID=home)
            sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
            stills("stacked")
            sv.sp("space", spaceAction="go", spaceID=work)
            stills("one-colour-stacked")
            sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "side"})
            sv.sp("space", spaceAction="go", spaceID=home)
            time.sleep(1)

        def switching(name):
            sv.cmd({"do": "ui", "look": "light"})
            time.sleep(1.2)
            film(f"{name}-to-dark", "dark", 36, 0.03)
            time.sleep(1.2)
            film(f"{name}-to-light", "light", 36, 0.03)

        if "switch" in parts:
            switching("switch-light-and-dark-split")
            sv.sp("space", spaceAction="go", spaceID=work)
            time.sleep(1)
            switching("switch-one-colour")
            sv.sp("space", spaceAction="go", spaceID=home)
            sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
            time.sleep(1.5)
            switching("switch-stacked")
            sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "side"})
            time.sleep(1)

        sv.sp("space", spaceAction="go", spaceID=home)
        for reduced in [False, True]:
            tag = "-reduced" if reduced else ""
            subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true" if reduced else "false"], check=True)
            time.sleep(0.5)
            for appearance in ["dark", "light"]:
                sv.cmd({"do": "ui", "look": appearance})
                time.sleep(0.6)
                if "fold" in parts:
                    sv.cmd({"do": "ui", "editlook": True, "lookMore": False})
                    time.sleep(1.2)
                    heights()
                    shots = film(f"more-open-{appearance}{tag}", "lookmore", 40, 0.02, "card")
                    report[f"more-open-{appearance}{tag}"] = {"app": heights(), "filmed": [f.get("size", [0, 0])[1] for f in shots]}
                    time.sleep(0.6)
                    shots = film(f"more-close-{appearance}{tag}", "lookless", 40, 0.02, "card")
                    report[f"more-close-{appearance}{tag}"] = {"app": heights(), "filmed": [f.get("size", [0, 0])[1] for f in shots]}
                    sv.cmd({"do": "ui", "editlook": False})
                    time.sleep(0.8)
                if "mode" in parts:
                    sv.cmd({"do": "ui", "editlook": True, "lookMore": False})
                    time.sleep(1.2)
                    film(f"mode-to-one-{appearance}{tag}", "lookone", 24, 0.02, "card")
                    time.sleep(0.5)
                    film(f"mode-to-both-{appearance}{tag}", "lookboth", 24, 0.02, "card")
                    sv.cmd({"do": "ui", "editlook": False})
                    sv.cmd({"do": "space", "action": "look", "colour": "sky", "mode": "both", "shade": "dark",
                            "dark": {"swatch": "midnight"}, "light": {"swatch": "peach"}})
                    time.sleep(0.8)
        subprocess.run(["defaults", "delete", sv.SUITE, "motion.testReduced"], capture_output=True)
        (OUT / "heights.json").write_text(json.dumps(report, indent=1))
        for name, values in report.items():
            app = values["app"]
            steps = [round(b - a, 1) for a, b in zip(app, app[1:])]
            print(f"  {name}: {len(app)} app frames, {app[:1]} .. {app[-1:]}, steps {steps}")
    finally:
        sv.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())

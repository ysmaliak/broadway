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
sv.use("quiet-fills-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
WORK = CONTEXT / "quiet-fills-shots"
SHOT = WORK / "shot"

ICONS = {
    "red": [(0.9, 0.12, 0.1)],
    "violet": [(0.45, 0.3, 0.85)],
    "black": [(0.06, 0.06, 0.07)],
    "teal": [(0.08, 0.68, 0.7)],
    "blue": [(0.15, 0.42, 0.95)],
    "grey": [(0.52, 0.52, 0.52)],
}
PINS = ["red", "violet", "red", "red", "red", "red", "black", "red", "grey", "red"]
FOLDER = ["Бабушкин сад, урожай", "Почему все строят бани", "She Asked One Small Favour", "The Lake of Echoes",
          "new island fishing spots", "How To Find THE BAKER", "how to get the gold tractor", "Загородная недвижимость",
          "Конец лета на даче"]
LOOKS = [(theme, colour, glass) for theme in ["dark", "light"] for colour in ["graphite", "sky", "coral"]
         for glass in [False, True]]


def png(colours, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = abs(dx) <= side / 2 - 2 and abs(dy) <= side / 2 - 6
            r, g, b = colours[0]
            if abs(dx) < 4 and abs(dy) < 4:
                r = g = b = 1
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


def page(n, icon, title):
    return f"{BASE}/p{n}/{icon}/{title.encode().hex()}"


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists():
        raise RuntimeError(out or "no still")


def cut(still, path, width):
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", f"crop={width * 2}:ih:0:0",
                    str(path)], check=True)


def main():
    t = sv.T()
    folder = WORK / label
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "270"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 980, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True})
        def opened(n, icon, title):
            id = sv.sp("open", url=page(n, icon, title))["resultID"]
            time.sleep(0.3)
            return id
        pins = [opened(n, icon, f"Pin {n}") for n, icon in enumerate(PINS)]
        login = [opened(20 + n, "blue", f"Login {n}") for n in range(2)]
        opened(30, "teal", "Tempo - Chrome Web Store")
        kept = [opened(40 + n, "grey" if n == 7 else "red", title) for n, title in enumerate(FOLDER)]
        opened(60, "black", "Смотреть фильм Курьер онлайн")
        time.sleep(3)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": login[0], "new": True, "name": "Login"})
        sv.cmd({"do": "group", "id": login[1], "name": "Login"})
        sv.cmd({"do": "group", "name": "Login", "pinned": True})
        time.sleep(0.6)
        sv.cmd({"do": "group", "name": "Login", "fold": True})
        sv.cmd({"do": "group", "id": kept[0], "new": True, "name": "Киану Ривз"})
        for id in kept[1:]:
            sv.cmd({"do": "group", "id": id, "name": "Киану Ривз"})
        sv.sp("select", id=kept[-1])
        time.sleep(1.5)
        groups = sv.cmd({"do": "group"})["groups"]
        t.ok("two folders, the pinned one folded", sorted(g["name"] for g in groups) == ["Login", "Киану Ривз"]
             and next(g for g in groups if g["name"] == "Login")["collapsed"], groups)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        cuts = {}
        for theme, colour, glass in LOOKS:
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "space", "action": "look", "colour": colour, "glass": glass,
                    "transparency": 0.5 if glass else 0})
            time.sleep(1.4)
            name = f"{theme}-{colour}-{'glass' if glass else 'flat'}"
            still = folder / f"{name}.png"
            shoot(pid, number, still)
            cuts[name] = folder / f"cut-{name}.png"
            cut(still, cuts[name], 300)
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme, "cards": False})
            sv.cmd({"do": "space", "action": "look", "colour": "graphite", "glass": False, "transparency": 0})
            time.sleep(1.4)
            name = f"{theme}-graphite-nocards"
            still = folder / f"{name}.png"
            shoot(pid, number, still)
            cuts[name] = folder / f"cut-{name}.png"
            cut(still, cuts[name], 300)
        sv.cmd({"do": "ui", "cards": True})
        rows = sv.cmd({"do": "rowframes"})["rows"]
        over = rows.get(kept[3][:8].lower())
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "space", "action": "look", "colour": "graphite", "glass": False, "transparency": 0})
            time.sleep(1.2)
            if over:
                sv.cmd({"do": "ui", "windowPointer": [over[0] + over[2] / 2, over[1] + over[3] / 2], "pointerPhase": "move"})
                time.sleep(0.8)
            name = f"{theme}-graphite-hover"
            still = folder / f"{name}.png"
            shoot(pid, number, still)
            cuts[name] = folder / f"cut-{name}.png"
            cut(still, cuts[name], 300)
            sv.cmd({"do": "ui", "windowPointer": [700, 500], "pointerPhase": "move"})
        t.ok("a row to hover", over is not None, rows)
        t.ok(f"{len(cuts)} stills", len(cuts) == len(LOOKS) + 4)
        shutil.copy(folder / "dark-graphite-flat.png", CONTEXT / f"quiet-{label}-window.png")
        for theme in ["dark", "light"]:
            names = [n for n in cuts if n.startswith(theme + "-")]
            inputs = sum([["-i", str(cuts[n])] for n in names], [])
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                            f"hstack=inputs={len(names)}", str(CONTEXT / f"quiet-{label}-{theme}.png")], check=True)
            print(CONTEXT / f"quiet-{label}-{theme}.png", names)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

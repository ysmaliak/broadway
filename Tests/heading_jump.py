#!/usr/bin/env python3
"""Folder headings filmed through folds and unfolds, the title tracked frame by frame.

A test copy in a world of its own, laid out as ring_film.py lays it out
(a live folder, a pinned folder, Outer with Inner nested), plus loose tabs
below so the list scrolls. With the list at the top, scrolled to its end, and
scrolled part of the way (a fractional wheel), each heading is folded and
unfolded through the bench (`group fold`), and the window is filmed at 120 fps.
Each title is found in every frame by matching its picture from a still frame
(to a tenth of a point), so the track follows it when the list moves. The
scene reports where the title started and ended and every step between
frames: a title that stays put has no steps, a fold that gives the scroll
back shows one smooth run of steps, and a jump shows as a lone step.

Run: python3 Tests/heading_jump.py LABEL [--app OTHER.app] [--out DIR] [--looks light,dark]
"""
import argparse
import json
import os
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
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("label")
parser.add_argument("--app", default="")
parser.add_argument("--out", default="")
parser.add_argument("--looks", default="light,dark")
options = parser.parse_args()
if options.app:
    sv.APP = options.app
OUT = Path(options.out or ROOT / ".context" / "heading-jump") / options.label
FILM = ROOT / ".context" / "pin-motion" / "pin-film"
WIDTH, HEIGHT, COLUMN = 1000, 720, 260
HEADS = {"Pull Requests": (46, 186), "Shelf": (46, 330), "Outer": (46, 551), "Inner": (62, 585)}


def read_png(path, last=None):
    data = Path(path).read_bytes()
    pos, idat = 8, b""
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, _, colour = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        pos += 12 + length
    ch = {6: 4, 2: 3}[colour]
    raw = zlib.decompress(idat)
    stride = width * ch
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(min(height, last or height)):
        f, line = raw[i], bytearray(raw[i + 1:i + 1 + stride])
        i += 1 + stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 1:
                line[x] = (line[x] + a) & 255
            elif f == 2:
                line[x] = (line[x] + b) & 255
            elif f == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append([0.3 * line[k * ch] + 0.59 * line[k * ch + 1] + 0.11 * line[k * ch + 2] for k in range(0, COLUMN)])
        prev = line
    return rows


def patch(luma, x, y, w=44, h=16):
    return [row[x:x + w] for row in luma[y:y + h]]


def cost(luma, template, x, y):
    total = 0.0
    for dy, trow in enumerate(template):
        row = luma[y + dy]
        for dx, v in enumerate(trow):
            d = row[x + dx] - v
            total += d * d
    return total


def locate(luma, template, x, around, reach):
    h = len(template)
    best = None
    for y in range(max(0, around - reach), min(len(luma) - h, around + reach) + 1):
        c = cost(luma, template, x, y)
        if best is None or c < best[1]:
            best = (y, c)
    y, c0 = best
    if 0 < y < len(luma) - h:
        cm, cp = cost(luma, template, x, y - 1), cost(luma, template, x, y + 1)
        bend = cm - 2 * c0 + cp
        if bend > 0:
            return y + 0.5 * (cm - cp) / bend, c0
    return float(y), c0


ICONS = {"magenta": (1.0, 0.0, 1.0), "grey": (0.5, 0.5, 0.52), "blue": (0.2, 0.45, 0.95)}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            inside = 2 <= x < side - 2 and 2 <= y < side - 2
            r, g, b = colour
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 if inside else 0])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


ROWS = [(700 + n, f"Change {700 + n}", "octo-sam", "open", "Approved", "passing") for n in range(3)]


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body, kind, status=200):
        try:
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path.startswith("/github/page/pulls"):
            return self.reply(pr.page(ROWS, f"http://127.0.0.1:{self.server.server_port}", late=False), "text/html; charset=utf-8")
        parts = self.path.split("?")[0].strip("/").split("/")
        if parts[0] == "icon":
            return self.reply(png(ICONS.get(parts[-1].removesuffix(".png"), ICONS["grey"])), "image/png")
        icon = parts[1] if len(parts) > 1 else "grey"
        self.reply((f"<!doctype html><meta charset=utf-8><title>{parts[0]}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#33373d'>").encode(), "text/html; charset=utf-8")


def cmd(**r): return sv.cmd(r)


TEMPLATES = {}


def film(name, act, seconds, track):
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("0*.png"):
        old.unlink()
    cmd(do="idle", action="unhide")
    time.sleep(0.3)
    taker = subprocess.Popen([str(FILM), str(pid), str(number), str(folder), str(seconds), f"0,0,{COLUMN + 10},{HEIGHT}"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: not filmed: {line} {taker.stderr.read()}")
    time.sleep(0.1)
    act()
    taker.communicate()
    key, guess = track
    x, _ = HEADS[key]
    template = TEMPLATES[key]
    frames = sorted(folder.glob("0*.png"))
    ys, at = [], guess
    for index, f in enumerate(frames):
        luma = read_png(f, last=HEIGHT)
        y, _ = locate(luma, template, x, int(round(at)), 260 if index == 0 else 24)
        ys.append(round(y, 2))
        at = y
    first = ys[0] if ys else 0
    steps = [round(b - a, 2) for a, b in zip(ys, ys[1:]) if abs(b - a) > 0.05]
    result = {"frames": len(frames), "start": first, "end": ys[-1] if ys else 0, "steps": steps, "ys": ys}
    (folder / "track.json").write_text(json.dumps(result))
    summary[name] = {k: result[k] for k in ("frames", "start", "end", "steps")}
    print(f"  {name}: {len(frames)} frames, title {first:.2f} -> {result['end']:.2f}, steps {steps[:14]}", flush=True)


def grab(folder):
    for old in folder.glob("0*.png"):
        old.unlink()
    cmd(do="idle", action="unhide")
    time.sleep(0.3)
    subprocess.run([str(FILM), str(pid), str(number), str(folder), "0.25", f"0,0,{COLUMN + 10},{HEIGHT}"],
                   capture_output=True, text=True)


def offset():
    try:
        return float(cmd(do="columnscroll").get("positions", {}).get("nativeList", 0))
    except RuntimeError:
        return 0.0


def opened(base, name, icon="grey"):
    id = sv.sp("open", url=f"{base}/{name}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    return id


summary = {}
pid = None
number = None


def main():
    global pid, number
    server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("heading-jump-" + uuid.uuid4().hex[:6])
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                                           "tabs.cards": True, "layout.cards": True, "start.fresh": False, "split": False,
                                           "tabs.newAtBottom": True, "live.on": True})
    looks = options.looks.split(",")
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", looks[0]], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(COLUMN)], check=True)
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
        cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        number = cmd(do="idle", action="unhide")["number"]
        pinned = opened(base, "Pinned", "blue")
        top = [opened(base, f"Top-{n}") for n in range(2)]
        opened(base, "Loader", "magenta")
        outer = [opened(base, f"Outer-{n}", "blue") for n in range(2)]
        inner = [opened(base, f"Inner-{n}") for n in range(2)]
        shelf = [opened(base, f"Shelf-{n}", "blue") for n in range(2)]
        for n in range(8):
            opened(base, f"Below-{n}")
        for x in sv.sp("state")["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        cmd(do="pin", id=pinned)
        cmd(do="folders", args=["with", "Outer", *outer])
        cmd(do="folders", args=["with", "Inner", *inner])
        cmd(do="folders", args=["nest", "Inner", "Outer"])
        cmd(do="folders", args=["with", "Shelf", *shelf])
        cmd(do="group", name="Shelf", pinned=True)
        try:
            cmd(do="live", args=["add-page", "Pull Requests", "pullRequests", f"{base}/github/page/pulls?q=is%3Aopen+is%3Apr+author%3A%40me"])
            cmd(do="live", args=["unfold", "Pull Requests"])
            cmd(do="live", args=["update", "Pull Requests"])
        except RuntimeError as e:
            print(f"  ..   no live folder: {e}")
        sv.sp("select", id=top[0])
        time.sleep(1.5)
        for look in looks:
            if look != looks[0]:
                cmd(do="ui", look=look)
                time.sleep(1.2)
            cmd(do="columnscroll", wheel=-2000)
            time.sleep(0.8)
            reference = OUT / f"{look}-reference"
            reference.mkdir(parents=True, exist_ok=True)
            grab(reference)
            luma = read_png(sorted(reference.glob("0*.png"))[0], last=HEIGHT)
            for key, (x, y) in HEADS.items():
                TEMPLATES[key] = patch(luma, x, y - 8)
            for state, wheel in (("top", 0), ("end", 2000), ("partway", 57.3)):
                cmd(do="columnscroll", wheel=-2000)
                time.sleep(0.6)
                if wheel:
                    cmd(do="columnscroll", wheel=wheel)
                    time.sleep(0.8)
                moved = offset()
                print(f"  {look} {state}: offset {moved}", flush=True)
                for key, (x, y) in HEADS.items():
                    short = key.split()[0].lower()
                    for kind in ("shut", "open"):
                        film(f"{look}-{state}-{short}-{kind}",
                             lambda k=key: threading.Timer(0.1, lambda: cmd(do="group", name=k, fold=True)).start(),
                             1.0, (key, y - 8 - moved))
                        time.sleep(0.4)
        (OUT / "summary.json").write_text(json.dumps(summary, indent=1))
    finally:
        try:
            cmd(do="quit")
        except Exception:
            pass
        time.sleep(1)
        for p in sv.pids():
            subprocess.run(["kill", str(p)], check=False)
        sv.finish()
        server.shutdown()


main()

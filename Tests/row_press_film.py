#!/usr/bin/env python3
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
import split_view as sv

parser = argparse.ArgumentParser()
parser.add_argument("label")
parser.add_argument("--app", default="")
parser.add_argument("--out", default="")
parser.add_argument("--only", default="")
parser.add_argument("--looks", default="light,dark")
options = parser.parse_args()
if options.app:
    sv.APP = options.app
OUT = Path(options.out or ROOT / ".context" / "film") / options.label
FILM = ROOT / ".context" / "pin-motion" / "pin-film"
MEASURE = ROOT / ".context" / "pin-motion" / "row-press-measure"
only = set(filter(None, options.only.split(",")))
WIDTH, HEIGHT, COLUMN = 1000, 720, 260
ICONS = {"magenta": (1.0, 0.0, 1.0), "grey": (0.5, 0.5, 0.52)}


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


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body, kind):
        try:
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        parts = self.path.split("?")[0].strip("/").split("/")
        if parts[0] == "icon":
            return self.reply(png(ICONS.get(parts[-1].removesuffix(".png"), ICONS["grey"])), "image/png")
        icon = parts[1] if len(parts) > 1 else "grey"
        self.reply((f"<!doctype html><meta charset=utf-8><title>{parts[0]}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#33373d'>").encode(), "text/html; charset=utf-8")


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("row-press-" + uuid.uuid4().hex[:6])
pid = None
number = None
results = {}


def cmd(**r): return sv.cmd(r)


def opened(name, icon="grey"):
    id = sv.sp("open", url=f"{BASE}/{name}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    return id


def rowframes():
    try:
        return cmd(do="rowframes").get("rows", {})
    except RuntimeError:
        return {}


def frame_of(id):
    rows = rowframes()
    for key, value in rows.items():
        if key.lower().startswith(id.lower()[:8]) or id.lower().startswith(key.lower()[:8]):
            return value
    raise RuntimeError(f"no row frame for {id}: {list(rows)}")


def after(delay, fn):
    threading.Timer(delay, fn).start()


def mouse(points, **extra):
    try:
        sv.sp("mouse", points=points, to="view", **extra)
    except Exception as e:
        print(f"  ..   mouse: {e}", flush=True)


def press(id, hold, mods=None, at=0.12):
    x, y, w, h = frame_of(id)
    point = [x + w * (0.5 if w < 80 else 0.42), y + h / 2]
    extra = {"modifiers": mods} if mods else {}
    after(at, lambda: mouse([point], hold=True, **extra))
    after(at + hold, lambda: mouse([point], resume=True, **extra))


def sample(folder, target, pin):
    try:
        frames = cmd(do="presssample", id=target, seconds=0.75)["frames"]
    except Exception as e:
        print(f"  ..   no layer samples: {e}", flush=True)
        return
    worst, odd = 0.0, []
    for f in frames:
        live, content, face = f.get("live"), f.get("content"), f.get("face")
        if not live or not content or not face:
            continue
        outer = 1.0 if pin else face["scale"]
        slab = outer * live["scale"]
        row = (face["scale"] if pin else outer * content["scale"])
        if live["hidden"] or live["opacity"] < 0.05:
            continue
        gap = abs(slab - row)
        worst = max(worst, gap)
        if gap > 0.002:
            odd.append(round(f["t"]))
    (folder / "layers.json").write_text(json.dumps({"frames": frames, "worst": worst, "apart": odd}))
    print(f"  layers: {len(frames)} samples, slab and row at most {worst:.4f} apart"
          + (f", apart at {odd[:6]} ms" if odd else ""), flush=True)


def film(name, target, act, seconds=1.1):
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    for old in folder.glob("0*.png"):
        old.unlink()
    rect = frame_of(target)
    crop = f"0,0,{COLUMN + 10},{HEIGHT}"
    cmd(do="idle", action="unhide")
    time.sleep(0.35)
    taker = subprocess.Popen([str(FILM), str(pid), str(number), str(folder), str(seconds), crop],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: not filmed: {line} {taker.stderr.read()}")
    time.sleep(0.1)
    sampler = threading.Thread(target=sample, args=(folder, target, name.endswith("pin")))
    sampler.start()
    act()
    taker.communicate()
    sampler.join()
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "120", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(OUT / f"{name}.mp4")], check=False)
    (folder / "rect.txt").write_text(",".join(str(v) for v in rect))
    measured = subprocess.run([str(MEASURE), str(folder), ",".join(str(v) for v in rect), name],
                              capture_output=True, text=True)
    print(measured.stdout.rstrip(), flush=True)
    try:
        results[name] = json.loads((folder / "measure.json").read_text())["glitches"]
    except Exception:
        results[name] = ["not measured"]


def scene(name, target, act, seconds=1.1, hover=True):
    if only and not any(name.split("-", 1)[-1].startswith(o) for o in only):
        return
    try:
        if hover:
            cmd(do="rowhover", id=target, on=True)
            time.sleep(0.3)
        film(name, target, act, seconds)
    except Exception as e:
        print(f"  FAIL {name}: {e}", flush=True)
    finally:
        try:
            cmd(do="rowhover", id=target, on=False)
        except Exception:
            pass
    time.sleep(0.5)


def main():
    global pid, number
    OUT.mkdir(parents=True, exist_ok=True)
    FILM.parent.mkdir(parents=True, exist_ok=True)
    for source, binary in ((ROOT / "Tests/pin_film.swift", FILM), (ROOT / "Tests/row_press_measure.swift", MEASURE)):
        if not binary.exists() or binary.stat().st_mtime < source.stat().st_mtime:
            subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(binary)], check=True)
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                                           "tabs.cards": True, "layout.cards": True, "start.fresh": False, "split": False,
                                           "tabs.newAtBottom": True, "live.on": False})
    looks = options.looks.split(",")
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", looks[0]], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(COLUMN)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        number = cmd(do="idle", action="unhide")["number"]
        pinned = opened("Pinned", "grey")
        other = opened("Other", "grey")
        target = opened("Target", "magenta")
        second = opened("Second", "magenta")
        third = opened("Third", "magenta")
        inner = [opened(f"Inner-{n}", "magenta" if n == 0 else "grey") for n in range(2)]
        for x in sv.sp("state")["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        cmd(do="pin", id=pinned)
        cmd(do="folders", args=["with", "Box", *inner])
        time.sleep(1.0)

        def home():
            sv.sp("select", id=other)
            time.sleep(0.6)

        for look in looks:
            if look != looks[0]:
                cmd(do="ui", look=look)
                time.sleep(1.2)
            p = f"{look}-"
            home()
            scene(p + "press", target, lambda: press(target, 0.15))
            home()
            scene(p + "quick", target, lambda: press(target, 0.07))
            sv.sp("select", id=target)
            time.sleep(0.6)
            scene(p + "selected", target, lambda: press(target, 0.15))
            home()
            scene(p + "command", second, lambda: press(second, 0.15, ["command"]))
            home()
            scene(p + "shift", third, lambda: press(third, 0.15, ["shift"]))
            home()
            scene(p + "pin", pinned, lambda: press(pinned, 0.15))
            home()
            scene(p + "folder", inner[0], lambda: press(inner[0], 0.15))
            home()
            scene(p + "keyboard", target, lambda: after(0.12, lambda: sv.sp("select", id=target)), hover=False)
        (OUT / "glitches.json").write_text(json.dumps(results, indent=1))
    finally:
        try:
            cmd(do="quit")
        except Exception:
            pass
        time.sleep(1)
        for p in sv.pids():
            subprocess.run(["kill", str(p)], check=False)
        sv.finish()


main()

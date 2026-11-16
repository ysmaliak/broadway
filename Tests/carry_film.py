#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="carry-after")
parser.add_argument("--only", default="")
parser.add_argument("--look", default="dark")
parser.add_argument("--reduce", action="store_true")
parser.add_argument("--film", action="store_true")
parser.add_argument("--tall", type=int, default=0)
parser.add_argument("--flick", action="store_true")
options = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv

OUT = ROOT / ".context" / options.label
WIDTH, HEIGHT, COLUMN = 1000, 1100, 270
NOIR = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45, "glass": False}
PAPER = {"colours": ["f3f2ee"], "intensity": 1.0, "transparency": 0.12, "grain": 0.0, "glass": False}
ICONS = {"grey": (0.5, 0.5, 0.52), "red": (0.9, 0.15, 0.15), "blue": (0.2, 0.45, 0.95), "orange": (0.95, 0.5, 0.1),
         "green": (0.55, 0.85, 0.1)}
only = set(filter(None, options.only.split(",")))
JUMP = 18
STEP = 0.02


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
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon":
            return self.reply(png(ICONS.get(parts[-1].removesuffix(".png"), ICONS["grey"])), "image/png")
        icon = parts[1] if len(parts) > 1 else "grey"
        title = urllib.parse.unquote(parts[0])
        self.reply((f"<!doctype html><meta charset=utf-8><title>{title}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#202124'>").encode(), "text/html; charset=utf-8")


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("carry-film-" + uuid.uuid4().hex[:6])
t = sv.T()
IDS, NAMES, SHORT = {}, {}, {}
STATE = {"pid": None, "number": None}
REPORT = {}
ACT = "Activity | OpenRouter"
BK = "Самоделкин – покупка дома"


def cmd(**r): return sv.cmd(r)
def grid(**more): return sv.cmd({"do": "foldergrid", **more})
def folders(*args): return sv.cmd({"do": "folders", "args": list(args)})


def opened(name, icon="grey"):
    id = sv.sp("open", url=f"{BASE}/{urllib.parse.quote(name)}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    IDS[name] = id
    NAMES[id] = name
    SHORT[id[:8].lower()] = name
    return id


def rows(g):
    return {NAMES.get(r["id"], r["label"]): r for r in g["rows"]}


def heads(g):
    return {h["name"]: h for h in g["headings"]}


def items(g=None):
    g = g or grid()
    return [NAMES.get(i, i) for i in g["items"]]


def closed(g, source):
    src = rows(g)[source]["frame"]
    below = sorted(f["frame"][1] for f in list(g["rows"]) + list(g["headings"]) if f["frame"][1] > src[1] + 1)
    step = src[3] + 3 if below else 0
    out = json.loads(json.dumps(g))
    for f in out["rows"] + out["headings"]:
        if f["frame"][1] > src[1] + 1:
            f["frame"][1] -= step
    return out


def centre(f, where=0.5, x=0.42):
    return (f[0] + f[2] * x, f[1] + f[3] * where)


def between(g, a, b):
    ra, rb = rows(g)[a]["frame"], rows(g)[b]["frame"]
    return (ra[0] + ra[2] * 0.42, (ra[1] + ra[3] + rb[1]) / 2)


def path(points, speed=6.0):
    out = []
    for a, b in zip(points, points[1:]):
        steps = max(2, int(max(abs(b[0] - a[0]), abs(b[1] - a[1])) / speed))
        out += [(a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps) for i in range(1, steps + 1)]
    return out


def world():
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.newAtBottom": True, "ai": False, "ai.groups": False,
                                           "tabs.aiGroups": False, "live.on": False, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(COLUMN - 12)], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true" if options.reduce else "false"], check=True)
    before = sv.running()
    env = ["--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1"]
    subprocess.run(["open", "-n", "-g", *env, sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    STATE["pid"] = next(iter(sv.holding() & sv.running()))
    STATE["tall"] = int(cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)["size"][1]) - 4
    STATE["number"] = cmd(do="idle", action="unhide")["number"]
    sv.cmd({"do": "space", "action": "rename", "name": "Personal", "icon": "house"})
    sv.cmd({"do": "space", "action": "look", **(PAPER if options.look == "light" else NOIR)})
    pins = [opened("X", "grey"), opened("Cloudflare", "orange")]
    names = [("Morning Brief", "grey"), (BK, "red"), ("Otter Workshop - YouTube", "red")]
    names += [(n, "blue") for n in ["Lantern Popup Options", "Lantern Landing Page", "Lantern, a notes app", "App name",
                                    "Lantern Settings Options", "Lantern, the Mac"]]
    names += [(ACT, "green"), ("Claude Status", "orange"), ("Account - Apple Developer", "grey"), ("Namecheap", "orange"),
              ("Suggested Folder Options", "grey"), ("Suggested Folder Options 2", "grey"), ("lamp shades - Google Search", "blue")]
    for n, icon in names:
        opened(n, icon)
    for x in sv.sp("state")["tabs"]:
        if not x.get("url") or x["id"] not in NAMES:
            try:
                sv.sp("close", id=x["id"])
            except RuntimeError:
                pass
    for p in pins:
        cmd(do="pin", id=p)
    folders("with", "test", IDS["Morning Brief"], IDS[BK])
    folders("with", "Lantern Vibes", *[IDS[n] for n, icon in names[3:9]])
    folders("with", "Folder Options", IDS["Suggested Folder Options"], IDS["Suggested Folder Options 2"])
    sv.sp("select", id=IDS[ACT])
    cmd(do="ui", look=options.look)
    time.sleep(1.5)
    if options.tall:
        STATE["tall"] = int(cmd(do="resize", width=WIDTH, height=options.tall, steps=1)["size"][1]) - 4
        time.sleep(1.0)
        sv.cmd({"do": "columnscroll", "wheel": 120})
        time.sleep(0.8)


SHOT = ROOT / ".context" / "carry-shots" / "window-shot"


def still(out):
    if not SHOT.exists():
        SHOT.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    subprocess.run([str(SHOT), str(STATE["pid"]), str(STATE["number"]), str(out)], capture_output=True, timeout=30)


def scene(name, source, points, seconds=None, start=None, after=None):
    if only and name not in only:
        return None
    g0 = grid(undoMark=True)
    before = items(g0)
    if start is None:
        pin = cmd(do="rowframes")["rows"].get(IDS["X"][:8].lower())
        top = pin[1] + pin[3] + 10 if pin else 0
        if rows(g0)[source]["frame"][1] < top:
            print(f"   {name}: skipped, {source} is scrolled out of view", flush=True)
            return None
    if "base" in STATE and name not in ("folded",):
        t.ok(f"{name}: starts from the same list", before == STATE["base"], before)
    start = start or centre(rows(g0)[source]["frame"])
    if options.flick:
        route = [start, (start[0], start[1] + 3)] + [points[0]] + path(points)
    else:
        route = [start, (start[0], start[1] + 3), (start[0], start[1] + 7)] + path([(start[0], start[1] + 7)] + points)
    seconds = seconds or STEP * len(route) + 1.4
    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    taken = {}

    def sample():
        taken["start"] = time.time()
        try:
            more = {"frames": str(folder / "frames"), "width": COLUMN} if options.film else {}
            taken["samples"] = grid(sample=seconds, **more)["samples"]
        except Exception as e:
            taken["error"] = str(e)
    sampler = threading.Thread(target=sample)
    sampler.start()
    time.sleep(0.15)
    to = {"to": "view"}
    sv.sp("mouse", points=[[round(x, 1), round(y, 1)] for x, y in route], hold=True, **to)
    still(folder / "held.png")
    if after:
        after()
    sv.sp("mouse", points=[[round(route[-1][0], 1), round(route[-1][1], 1)]], resume=True, **to)
    sampler.join()
    frames = sorted((folder / "frames").glob("*.png"))
    if frames:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "30", "-i", str(folder / "frames" / "%04d.png"),
                        "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(OUT / f"{name}.mp4")], check=False)
    samples = taken.get("samples", [])
    (folder / "samples.json").write_text(json.dumps({"route": route, "samples": samples, "names": SHORT, "start": taken.get("start")}, ensure_ascii=False))
    time.sleep(0.6)
    g = grid()
    found = judge(name, source, route, samples)
    found["before"] = before
    found["after"] = items(g)
    REPORT[name] = found
    (OUT / "report.json").write_text(json.dumps(REPORT, indent=1, ensure_ascii=False))
    return g


def judge(name, source, route, samples):
    sid = IDS.get(source, source)[:8].lower()
    faults = {"still": [], "twice": [], "jump": [], "moved": [], "folderStates": [], "lineOverTiles": [], "stub": [], "lineAndJoin": []}
    carrying = [s for s in samples if s.get("carried")]
    began = carrying[0]["t"] if carrying else None
    ended = carrying[-1]["t"] if carrying else None
    last = None
    for s in samples:
        t_ms = s.get("t", 0)
        copies = s.get("copies", [])
        carried = bool(s.get("carried"))
        if carried and len(copies) > 1:
            a = copies[0]
            if any(abs(c[0] - a[0]) > 1 or abs(c[1] - a[1]) > 1 or abs(c[2] - a[2]) > 1 for c in copies[1:]):
                faults["twice"].append(t_ms)
        if carried and t_ms - began > 250 and s.get("hand") and copies:
            hand = s["hand"]
            near = [c for c in copies if c[1] - 30 <= hand[1] <= c[1] + c[3] + 30]
            if not near:
                faults["still"].append(t_ms)
        grid_rect = s.get("grid")
        line = s.get("line")
        if line and grid_rect and line[1] < grid_rect[1] + grid_rect[3] + 2:
            faults["lineOverTiles"].append(t_ms)
        if line and s.get("tile") and carried:
            faults["lineOverTiles"].append(t_ms)
        morph = s.get("morph")
        if carried and morph and morph[4] > 0.05:
            if s.get("tile") and grid_rect and morph[2] < 120 and morph[1] > grid_rect[1] + grid_rect[3] + 24:
                faults["stub"].append(t_ms)
            if morph[2] < 60 or morph[3] < 20:
                faults["stub"].append(t_ms)
        if carried and s.get("lit"):
            faults["folderStates"].append((t_ms, s["lit"]))
        if carried and s.get("filled"):
            faults["folderStates"].append((t_ms, s["filled"]))
        if last:
            dt = max(1, t_ms - last.get("t", 0))
            for rid, frame in s.get("rows", {}).items():
                if rid == sid:
                    continue
                was = last.get("rows", {}).get(rid)
                if not was:
                    continue
                dy = abs(frame[1] - was[1])
                if not options.reduce and dy / (dt / 16.7) > JUMP:
                    faults["jump"].append((t_ms, SHORT.get(rid, rid), round(frame[1] - was[1], 1)))
                if began is not None and began + 350 < t_ms <= ended and last.get("carried") and dy > 1 and name not in MOVING:
                    faults["moved"].append((t_ms, SHORT.get(rid, rid), round(frame[1] - was[1], 1)))
        last = s
    clean = {k: v for k, v in faults.items() if v}
    print(f"   {name}: " + (", ".join(f"{k} {v[:4]}" for k, v in clean.items()) or "clean"), flush=True)
    return {"faults": faults}


MOVING = {"folded"}


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        world()
        g = grid()
        STATE["base"] = items(g)
        print("   list:", items(g), flush=True)
        g = closed(g, ACT)
        r = rows(g)
        down = [centre(r["Account - Apple Developer"]["frame"]), centre(r["Namecheap"]["frame"]),
                centre(heads(g)["Folder Options"]["frame"]), centre(r["Suggested Folder Options 2"]["frame"]),
                centre(r["lamp shades - Google Search"]["frame"], 0.9), centre(r["Account - Apple Developer"]["frame"]),
                between(g, "Account - Apple Developer", "Namecheap")]
        g = scene("list", ACT, down)
        if g:
            t.ok("list: the tab lands between Account and Namecheap", items(g).index(ACT) == items(g).index("Account - Apple Developer") + 1, items(g))
            grid(undo=True)
            time.sleep(0.8)
        g = grid()
        frames = cmd(do="rowframes")["rows"]
        cf = frames[IDS["Cloudflare"][:8].lower()]
        up = [centre(rows(g)["Lantern, the Mac"]["frame"]), centre(rows(g)["App name"]["frame"]),
              (cf[0] + cf[2] - 14, cf[1] + cf[3] / 2), (cf[0] + cf[2] - 10, cf[1] + cf[3] / 2 + 2)]
        g = scene("pins", ACT, up)
        if g:
            st = sv.sp("state")
            t.ok("pins: the tab is the third tile", NAMES.get(st["pins"][-1]) == ACT if st["pins"] else False, [NAMES.get(p) for p in st["pins"]])
            grid(undo=True)
            time.sleep(0.8)
        g = closed(grid(), ACT)
        page = [centre(rows(g)["Claude Status"]["frame"]), (COLUMN + 300, rows(g)["Namecheap"]["frame"][1])]
        g = scene("nowhere", ACT, page)
        if g:
            t.ok("nowhere: the tab stays where it was", items(g) == REPORT["nowhere"]["before"], items(g))
        g = closed(grid(), BK)
        g = scene("folder-out", BK, [centre(rows(g)["Claude Status"]["frame"]), between(g, "Account - Apple Developer", "Namecheap")])
        if g:
            t.ok("folder-out: the tab lands between Account and Namecheap", items(g).index(BK) == items(g).index("Account - Apple Developer") + 1, items(g))
            grid(undo=True)
            time.sleep(0.8)
        g = closed(grid(), ACT)
        g = scene("into-folder", ACT, [centre(rows(g)["Namecheap"]["frame"]), centre(heads(g)["Folder Options"]["frame"])], seconds=2.4)
        if g:
            t.ok("into-folder: the tab is in Folder Options", rows(g)[ACT]["folder"] == "Folder Options", rows(g)[ACT]["folder"])
            grid(undo=True)
            time.sleep(0.8)
        g = grid()
        frames = cmd(do="rowframes")["rows"]
        x = frames[IDS["X"][:8].lower()]
        g = scene("pin-down", "X", [centre(rows(g)["App name"]["frame"]), between(g, "Claude Status", "Account - Apple Developer")],
                  start=(x[0] + x[2] / 2, x[1] + x[3] / 2))
        if g:
            t.ok("pin-down: X is a tab in the list", "X" in items(g), items(g))
            grid(undo=True)
            time.sleep(0.8)
        cmd(do="group", name="Lantern Vibes", fold=True)
        time.sleep(1.0)
        g = grid()
        bv = heads(g)["Lantern Vibes"]["frame"]
        g = scene("folded", ACT, [centre(bv, 0.5), centre(bv, 0.1), centre(rows(g)["Otter Workshop - YouTube"]["frame"], 0.6)])
        if g:
            grid(undo=True)
            time.sleep(0.8)
        for name, found in REPORT.items():
            for kind in ("twice", "jump", "moved", "lineOverTiles", "folderStates", "still", "stub"):
                t.ok(f"{name}: no {kind}", not found["faults"][kind], found["faults"][kind][:6])
    finally:
        (OUT / "report.json").write_text(json.dumps(REPORT, indent=1, ensure_ascii=False))
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Pin and unpin from the menu's path, filmed and checked frame by frame.

Build first (`./build.sh`), then `python3 Tests/pin_motion.py [LABEL] [--only a,b] [--no-check]`.
A world of its own, shown behind the app in front (SEARCH_SHOWN). One tab
has a magenta favicon and every other a grey or blue one; each motion pins
or unpins that tab through the bench's `pin`, which is Browser.pin and
Browser.unpin, the path the tab menu, the shortcut, the command bar and
`broadway` take. Each motion is filmed window-only (Tests/pin_film.swift, the
test copy's own window, never the screen) into .context/pin-motion/LABEL/,
with a contact sheet and an mp4, and the magenta mark is found in every
frame. Checked: the mark is on screen exactly once in every frame, it
starts where the tab was and ends where it lands, and no frame step is a
jump (more than a spring of its travel allows in that frame's time). The
bench's display link reports the longest main-thread span for each, and
the last motions run in a big column.
"""
import argparse
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="now")
parser.add_argument("--only", default="")
parser.add_argument("--no-check", action="store_true")
parser.add_argument("--sample", action="store_true")
parser.add_argument("--recheck", action="store_true")
parser.add_argument("--now", action="store_true")
options = parser.parse_args()
label = options.label
only = set(filter(None, options.only.split(",")))
checking = not options.no_check
OUT = ROOT / ".context" / "pin-motion" / label
FILM = ROOT / ".context" / "pin-motion" / "pin-film"
WIDTH, HEIGHT, COLUMN = 1000, 720, 260

ICONS = {"magenta": (1.0, 0.0, 1.0), "grey": (0.5, 0.5, 0.52), "blue": (0.2, 0.45, 0.95), "teal": (0.1, 0.65, 0.66)}


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
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon":
            body, kind = png(ICONS[parts[-1].removesuffix(".png")]), "image/png"
        else:
            icon = parts[1] if len(parts) > 1 else "grey"
            body = (f"<!doctype html><meta charset=utf-8><title>{parts[0]}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#33373d;color:#ddd;font:30px system-ui'><p>{parts[0]}").encode()
            kind = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("pin-motion-" + uuid.uuid4().hex[:6])
t = sv.T()
pid = None
number = None
summary = {}


def cmd(**r): return sv.cmd(r)
def state(): return sv.sp("state")


def opened(name, icon="grey"):
    id = sv.sp("open", url=f"{BASE}/{name}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    return id


def pins():
    return state()["pins"]


def film(name, act, seconds=1.1):
    folder = OUT / name
    side = SIDE[0]
    x = 0 if side == "left" else WIDTH - COLUMN - 10
    crop = f"{x},0,{COLUMN + 10},{HEIGHT}"
    cmd(do="idle", action="unhide")
    time.sleep(0.35)
    taker = subprocess.Popen([str(FILM), str(pid), str(number), str(folder), str(seconds), crop],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: not filmed: {line} {taker.stderr.read()}")
    cmd(do="idle", action="frames")
    try:
        cmd(do="pintrace", action="start")
    except RuntimeError:
        pass
    time.sleep(0.12)
    act()
    time.sleep(max(0.2, seconds - 0.75))
    gaps = cmd(do="idle", action="gaps")
    try:
        traced = cmd(do="pintrace")
        (folder.parent / f"{name}-trace.json").write_text(json.dumps(traced, indent=1))
    except RuntimeError:
        pass
    out, err = taker.communicate()
    frames = json.loads((folder / "frames.json").read_text())["frames"]
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(OUT / f"{name}.mp4")], check=False)
    if (folder / "sheet.png").exists():
        shutil.copy(folder / "sheet.png", OUT / f"{name}.png")
    for png_file in folder.glob("0*.png"):
        png_file.unlink()
    return frames, gaps


OMEGA = 2 * 3.14159 / 0.16


def reach(seconds):
    return min(1.0, OMEGA / 2.71828 * seconds)


def marks(frame):
    return [b for b in frame["blobs"] if b["w"] <= 22 and b["h"] <= 22]


def check(name, frames, gaps):
    seen = [(f["t"], marks(f)) for f in frames]
    counts = [len(b) for _, b in seen]
    moving = [i for i, f in enumerate(frames) if f["change"] > 0.15]
    longest = gaps.get("longestMs") or 0
    report = {"frames": len(frames), "changing": len(moving), "longestMs": longest, "worstMs": gaps.get("worstMs"),
              "hitches": gaps.get("hitches"), "counts": {}}
    for c in counts:
        report["counts"][str(c)] = report["counts"].get(str(c), 0) + 1
    if moving:
        report["motionMs"] = round(frames[moving[-1]]["t"] - frames[moving[0]]["t"])
    single = [(round(tm), len(b)) for tm, b in seen if len(b) != 1]
    path = [(tm, b[0]) for tm, b in seen if len(b) == 1]
    report["missing"] = counts.count(0)
    report["doubled"] = sum(1 for c in counts if c > 1)
    if len(path) >= 2:
        start, end = path[0][1], path[-1][1]
        travel = ((end["x"] - start["x"]) ** 2 + (end["y"] - start["y"]) ** 2) ** 0.5
        steps, jumps, drops, back = [], [], [], []
        began = False
        intervals = sorted(tb - ta for (ta, _), (tb, _) in zip(path, path[1:]))
        usual = intervals[len(intervals) // 2] if intervals else 8.3
        for (ta, a), (tb, b) in zip(path, path[1:]):
            d = ((b["x"] - a["x"]) ** 2 + (b["y"] - a["y"]) ** 2) ** 0.5
            dt = (tb - ta) / 1000
            if d > 1.5:
                slack = longest / 1000 if not began else 0.009
                allowed = travel * reach(dt + slack) * 1.15 + 3
                if d > allowed:
                    late = (tb - ta) > 1.6 * usual
                    (drops if late else jumps).append((round(tb), round(d, 1), round(allowed, 1), round(tb - ta)))
                if not began:
                    report["firstStep"] = round(d / max(travel, 1), 2)
                began = True
                if travel > 4:
                    along = ((b["x"] - a["x"]) * (end["x"] - start["x"]) + (b["y"] - a["y"]) * (end["y"] - start["y"])) / travel
                    if along < -2:
                        back.append((round(tb), round(along, 1)))
            steps.append(d)
        report.update(travel=round(travel, 1), start=[round(start["x"]), round(start["y"])], end=[round(end["x"]), round(end["y"])],
                      biggestStep=round(max(steps, default=0), 1), jumps=jumps, drops=drops, backwards=back)
    summary[name] = report
    (OUT / f"{name}.json").write_text(json.dumps({"report": report, "frames": frames, "gaps": gaps}, indent=1))
    print(f"  ..   {name}: {json.dumps(report)}", flush=True)
    if not checking:
        return
    t.ok(f"{name}: the tab is on screen exactly once in every frame", not single, single[:12])
    if not name.startswith("reduced"):
        t.ok(f"{name}: no jumps", not report.get("jumps"), report.get("jumps"))
    t.ok(f"{name}: never goes back", not report.get("backwards"), report.get("backwards"))


SIDE = ["left"]


def column():
    st = state()
    title = {x["id"]: (x.get("url") or "blank").split("/")[3 if (x.get("url") or "").count("/") >= 3 else 0] for x in st["tabs"]}
    return {"pins": [title.get(i, i) for i in st["pins"]],
            "tabs": [title.get(x["id"], x["id"]) for x in st["tabs"] if x["id"] not in st["pins"]],
            "active": title.get(st.get("activeID", ""), st.get("activeID"))}


def load():
    return float(subprocess.run(["sysctl", "-n", "vm.loadavg"], capture_output=True, text=True).stdout.split()[1])


def compiling():
    return subprocess.run(["pgrep", "-x", "swift-frontend"], capture_output=True).returncode == 0


def quiet(limit=15, wait=600):
    start = time.time()
    while time.time() - start < wait and (compiling() or load() > limit):
        time.sleep(5)
    return load()


def stalled(name):
    trace = OUT / f"{name}-trace.json"
    if not trace.exists():
        return None
    frames = json.loads(trace.read_text()).get("frames", [])
    for a, b in zip(frames, frames[1:]):
        if b["t"] - a["t"] > 50 and a["landed"] < 0.95 and b["landed"] > 0.05:
            return [round(a["t"]), round(b["t"]), round(a["landed"], 2), round(b["landed"], 2)]
    return None


def motion(name, act, seconds=1.1, undo=None):
    if only and name not in only and name.split("-")[0] not in only:
        act()
        time.sleep(0.5)
        return
    try:
        stalls = []
        while True:
            busy = load()
            frames, gaps = film(name, act, seconds)
            stall = stalled(name)
            if not stall or undo is None or len(stalls) == 2:
                break
            stalls.append(dict(load=busy, stall=stall))
            print(f"  ..   {name}: the app stalled mid-flight {stall} at load {busy}, again", flush=True)
            undo()
            time.sleep(0.8)
        check(name, frames, gaps)
        summary[name]["load"] = busy
        summary[name]["stalls"] = stalls
        summary[name]["after"] = column()
        trace = OUT / f"{name}-trace.json"
        if trace.exists():
            events = json.loads(trace.read_text()).get("events", [])
            summary[name]["events"] = events
            summary[name]["flew"] = any(" fly " in e for e in events)
    except Exception as e:
        t.ok(f"{name}: filmed", False, str(e))
    time.sleep(0.4)


def pinning(name, m, **extra):
    motion(name, lambda: cmd(do="pin", id=m, **extra), undo=lambda: cmd(do="pin", id=m, off=True))


def unpinning(name, m, **extra):
    motion(name, lambda: cmd(do="pin", id=m, off=True), undo=lambda: cmd(do="pin", id=m, **extra))


def recheck():
    for path in sorted(OUT.glob("*.json")):
        if path.name == "summary.json" or path.name.endswith("-trace.json"):
            continue
        saved = json.loads(path.read_text())
        check(path.stem, saved["frames"], saved.get("gaps") or {"longestMs": saved["report"].get("longestMs")})
    (OUT / "summary.json").write_text(json.dumps(summary, indent=1))
    t.done()
    return int(t.failed != 0)


def main():
    global pid, number
    if options.recheck:
        return recheck()
    OUT.mkdir(parents=True, exist_ok=True)
    FILM.parent.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Tests/pin_film.swift"
    if not FILM.exists() or FILM.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(FILM)], check=True)
    summary["startLoad"] = load() if options.now else quiet()
    print(f"  ..   load {summary['startLoad']}", flush=True)
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                                           "tabs.cards": True, "start.fresh": False, "split": False, "tabs.newAtBottom": True})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"], check=True)
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
        grey = [opened(f"Pin-{n}", "blue" if n % 2 else "grey") for n in range(6)]
        loose = [opened(f"Loose-{n}", "teal" if n % 2 else "grey") for n in range(4)]
        m = opened("Magenta", "magenta")
        tail = [opened(f"Below-{n}", "grey") for n in range(3)]
        reading = [opened(f"Reading-{n}", "blue") for n in range(3)]
        for x in state()["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        cmd(do="group", id=reading[0], new=True, name="Reading")
        for id in reading[1:]: cmd(do="group", id=id, name="Reading")
        for id in grey[:3]: cmd(do="pin", id=id)
        for id in grey[3:]: cmd(do="group", id=id, name="none")
        sv.sp("select", id=m)
        time.sleep(1.2)
        t.ok("three pins to start", len(pins()) == 3, pins())

        if options.sample:
            sampler = subprocess.Popen(["sample", str(pid), "6", "-file", str(OUT / "sample.txt")], stdout=subprocess.DEVNULL)
            time.sleep(0.5)
            for _ in range(8):
                cmd(do="pin", id=m)
                time.sleep(0.35)
                cmd(do="pin", id=m, off=True)
                time.sleep(0.35)
            sampler.wait()
            return 0
        pinning("loose-pin", m)
        t.ok("loose-pin: pinned", m in pins(), pins())
        unpinning("loose-unpin", m)
        t.ok("loose-unpin: unpinned", m not in pins(), pins())

        sv.sp("select", id=tail[0])
        cmd(do="pin", id=m, off=True)
        time.sleep(0.5)
        pinning("quiet-pin", m)
        unpinning("quiet-unpin", m)

        cmd(do="group", id=m, name="Reading")
        sv.sp("select", id=m)
        time.sleep(0.6)
        motion("folder-pin", lambda: cmd(do="pin", id=m))
        unpinning("folder-unpin", m)

        cmd(do="pin", id=grey[3])
        time.sleep(0.5)
        pinning("fill-pin", m)
        unpinning("fill-unpin", m)
        cmd(do="pin", id=grey[4])
        time.sleep(0.5)
        pinning("newrow-pin", m)
        unpinning("newrow-unpin", m)

        for id in grey[:5]: cmd(do="pin", id=id, off=True)
        time.sleep(0.6)
        t.ok("no pins left", pins() == [], pins())
        pinning("first-pin", m)
        unpinning("last-unpin", m)

        for id in grey[:3]: cmd(do="pin", id=id)
        cmd(do="pin", id=grey[0], everywhere=True)
        time.sleep(0.4)
        pinning("shared-pin", m)
        cmd(do="pin", id=m, everywhere=True)
        time.sleep(0.5)
        t.ok("magenta shared to every space", m in state()["everywhere"], state()["everywhere"])
        motion("shared-unpin", lambda: cmd(do="pin", id=m, off=True),
               undo=lambda: (cmd(do="pin", id=m), cmd(do="pin", id=m, everywhere=True)))
        cmd(do="pin", id=grey[0], everywhere=False)

        SIDE[0] = "right"
        cmd(do="ui", side="right")
        time.sleep(0.8)
        pinning("right-pin", m)
        unpinning("right-unpin", m)
        SIDE[0] = "left"
        cmd(do="ui", side="left")

        cmd(do="ui", look="light")
        time.sleep(0.8)
        pinning("light-pin", m)
        unpinning("light-unpin", m)
        cmd(do="ui", look="dark")
        time.sleep(0.5)

        def reduced(on):
            subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true" if on else "false"], check=True)
            time.sleep(0.6)

        sv.sp("select", id=m)
        reduced(True)
        pinning("reduced-pin", m)
        unpinning("reduced-unpin", m)
        reduced(False)
        for name in ["reduced-pin", "reduced-unpin"]:
            r = summary.get(name)
            if r and checking:
                t.ok(f"{name}: no flight under Reduce Motion", not r.get("flew"), r.get("events"))
                t.ok(f"{name}: lands in one step", r.get("motionMs", 0) <= 40 or r.get("travel", 0) < 2, r.get("motionMs"))

        bigs = []
        if not only or "big" in only or "deep" in only or any(o.startswith("big") for o in only):
            for n in range(4):
                cmd(do="pin", id=opened(f"Big-pin-{n}", "blue"))
            for n in range(50):
                bigs.append(opened(f"Big-{n}", "grey" if n % 3 else "teal"))
            sv.sp("select", id=m)
            time.sleep(1.5)
        for n in range(3):
            motion(f"big-pin-{n}", lambda: cmd(do="pin", id=m))
            motion(f"big-unpin-{n}", lambda: cmd(do="pin", id=m, off=True))
        spans = {kind: sorted(summary[k]["longestMs"] for k in summary if k.startswith(f"big-{kind}-")) for kind in ["pin", "unpin"]}
        summary["big"] = {kind: {"runs": v, "median": v[len(v) // 2] if v else None} for kind, v in spans.items()}
        print("  ..   big column, longest main-thread span (ms):", json.dumps(summary["big"]), flush=True)

        if bigs:
            def deep():
                cmd(do="pin", id=m)
                time.sleep(0.5)
                sv.sp("select", id=bigs[-1])
                time.sleep(0.8)
            deep()
            motion("deep-unpin", lambda: cmd(do="pin", id=m, off=True), undo=deep)
    finally:
        try: cmd(do="quit")
        except Exception: subprocess.run(["kill", str(pid)])
        sv.wipe()
        (OUT / "summary.json").write_text(json.dumps(summary, indent=1))
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

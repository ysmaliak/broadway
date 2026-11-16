#!/usr/bin/env python3
"""Space swipes with no blank, sparse, stale or re-laid-out frames.

Build first (`./build.sh`), then `python3 Tests/swipe_blink.py [--out DIR]
[--only a,b] [--app OTHER.app] [--label before|after] [--keep] [--emoji]`.

A test copy in a world of its own (SEARCH_SHOWN, so it draws as on screen),
with four spaces: Home (a local page), Personal (another local page in front,
with rows under it), Work (a local pull request page,
pins, a folder and a dozen rows) and Live (a local page whose words, title and
colour change every second while it is hidden, and hold still on screen).
Nothing reaches the network or a real account. --emoji gives the spaces emoji
icons through the bench.

Each case is filmed with Tests/motion_film.swift, the test copy's own window
only, at 60 fps, and each frame is measured by Tests/film_marks.swift: blank
when the page is one flat colour; sparse when the column holds much less ink
than the two resting columns, shifted to where the slide has them, would;
re-laid out or stale when, in the first 25 frames after the slide comes to
rest, the page or column is more than 6 grey levels from where it settles.
Marked frames are framed in red on the case's strip (DIR/LABEL/NAME.png),
beside a strip of the foot (NAME-foot.png).
"""
import argparse
import json
import shutil
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_audit as ma  # noqa: E402
import perf_idle as pi  # noqa: E402

sv = pi.sv
sv.use("swipe-blink")
c = ma.c
ROOT = Path(__file__).resolve().parents[1]
HERE = Path(__file__).resolve().parent
STRIP = HERE.parent / ".build" / "film-strip"
WIDTH, HEIGHT = 1280, 800


def pull():
    rows = "".join(f"<li><b>octo-{i}</b> commented <i>{i + 2} hours ago</i><p>Looks good, one nit on the cache key.</p></li>"
                   for i in range(14))
    return ("<!doctype html><title>Defer optional library setup by octo · Pull Request #24907</title>"
            "<style>body{margin:0;font:14px system-ui;background:#0d1117;color:#e6edf3}header{background:#010409;padding:16px 24px;"
            "border-bottom:1px solid #30363d}h1{font-size:26px;font-weight:400;margin:24px}.state{display:inline-block;background:#238636;"
            "border-radius:20px;padding:4px 12px;margin:0 24px}ul{list-style:none;margin:24px;padding:0}li{border:1px solid #30363d;"
            "border-radius:6px;margin:10px 0;padding:10px 14px}i{color:#7d8590}</style>"
            "<header>octo / app · Code · Issues · Pull requests · Actions</header>"
            "<h1>[OCT-1459] Startup - Defer optional library setup until after the first frame #24907</h1>"
            f"<span class=state>Open</span><ul>{rows}</ul>")


def live():
    return ("<!doctype html><title>Inbox (0)</title><style>body{margin:0;font:600 90px system-ui;background:#f6f3ea;color:#222;"
            "display:grid;place-items:center;height:100vh}</style><div id=n>Inbox 0</div>"
            "<script>let n=0;const show=()=>{document.getElementById('n').textContent='Inbox '+n;document.title='Inbox ('+n+')';"
            "document.body.style.background=n%2?'#e4efe6':'#f6f3ea'};"
            "setInterval(()=>{if(document.hidden){n++;show()}},1000)</script>")


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0].strip("/")
        if path.startswith("pull"):
            body = pull()
        elif path.startswith("live"):
            body = live()
        else:
            words = ("The river crossing would move two kilometres upstream and spare the old market. " * 40)
            body = f"<!doctype html><title>{path.replace('-', ' ').title()}</title><h1>{path}</h1><p>{words}</p>"
        data = body.encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def space(**f):
    return c(do="space", **f)


def opened(url, front=False):
    return sv.sp("open", url=url, foreground=front, atEnd=True)["resultID"]


def stroke(stops, speed, at=None, momentum=True, cancel=False):
    g = {"stops": stops, "speed": speed, "momentum": momentum, "cancel": cancel}
    if at is not None:
        g["at"] = at
    return g


SPACES = {}
ICONS = {}
EMOJI = {"Home": "🏠", "Personal": "🌿", "Work": "🤝", "Live": "📬"}


def mark(name):
    if name in ICONS:
        try:
            space(action="icon", icon=ICONS[name])
        except Exception as error:
            print(f"  no icon for {name}: {error}")


def index(name):
    return SPACES[name]


def world():
    space(action="rename", name="Home")
    space(action="look", colours=["3A3F4B"], intensity=0.4)
    mark("Home")
    opened(f"{BASE}/home-front", front=True)
    for k in range(4):
        opened(f"{BASE}/home-{k}")
    space(action="new", name="Personal")
    time.sleep(0.8)
    mark("Personal")
    opened(f"{BASE}/personal-front", front=True)
    for k in range(4):
        opened(f"{BASE}/personal-{k}")
    space(action="new", name="Work")
    time.sleep(0.8)
    mark("Work")
    pins = [opened(f"{BASE}/work-pin-{k}") for k in range(2)]
    for pin in pins:
        c(do="pin", id=pin)
    folder = [opened(f"{BASE}/work-folder-{k}") for k in range(3)]
    c(do="group", id=folder[0], new=True, name="Reading")
    for tab in folder[1:]:
        c(do="group", id=tab, name="Reading")
    for k in range(10):
        opened(f"{BASE}/work-tab-{k:02d}")
    front = opened(f"{BASE}/pull/24907", front=True)
    c(do="wait", id=front, seconds=15)
    sv.sp("select", id=front)
    space(action="new", name="Live")
    time.sleep(0.8)
    mark("Live")
    for k in range(3):
        opened(f"{BASE}/live-{k}")
    front = opened(f"{BASE}/live", front=True)
    c(do="wait", id=front, seconds=15)
    sv.sp("select", id=front)
    names = [s["name"] for s in space(action="state")["spaces"]]
    for name in ("Home", "Personal", "Work", "Live"):
        SPACES[name] = names.index(name) + 1
    for name in ("Home", "Personal", "Work", "Live", "Personal"):
        space(action="go", index=index(name))
        time.sleep(1.4)


def go(name, wait=1.6):
    space(action="go", index=index(name))
    time.sleep(wait)


CASES = [
    ("to-work-slow", "Personal", lambda: space(action="trackpad", gestures=[stroke([-230], 350)]), 2.2),
    ("to-personal-slow", "Work", lambda: space(action="trackpad", gestures=[stroke([230], 350)]), 2.2),
    ("to-work-fast", "Personal", lambda: space(action="trackpad", gestures=[stroke([-90], 2600)]), 1.4),
    ("to-personal-fast", "Work", lambda: space(action="trackpad", gestures=[stroke([90], 2600)]), 1.4),
    ("to-personal-flick", "Work", lambda: space(action="trackpad", gestures=[stroke([140], 1100)]), 1.6),
    ("three-in-a-row", "Live", lambda: space(action="trackpad", gestures=[
        stroke([140], 1100), stroke([140], 1100, at=0.36), stroke([140], 1100, at=0.72)]), 2.6),
    ("web-both", "Work", lambda: space(action="trackpad", gestures=[stroke([-140], 1100)]), 1.6),
    ("parked-changed", "Work", lambda: space(action="trackpad", gestures=[stroke([-140], 1100)]), 1.6),
    ("ctrl-to-personal", "Work", lambda: space(action="key", index=index("Personal")), 1.4),
    ("ctrl-to-work", "Personal", lambda: space(action="key", index=index("Work")), 1.4),
    ("to-new", "Live", lambda: space(action="ask"), 1.6),
    ("cancelled", "Work", lambda: space(action="trackpad", gestures=[stroke([-120, -40], 300, momentum=False)]), 1.6),
]


def film(pid, name, out, seconds, act, tracks, crop=None):
    args = [str(ma.FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(out / name),
            "--scale", "1", "--fps", "60", "--columns", "8", "--frames", str(out / f"{name}-frames")]
    args += ["--crop", crop] if crop else ["--track", tracks]
    subprocess.run(["rm", "-rf", str(out / f"{name}-frames")])
    for _ in range(3):
        taker = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = taker.stdout.readline()
        if line.startswith("ready"):
            break
        taker.wait()
        time.sleep(0.5)
    else:
        raise RuntimeError(f"{name}: film did not start: {line} {taker.stderr.read()}")
    c(do="idle", action="frames")
    act()
    time.sleep(max(0.2, seconds - 0.5))
    gaps = c(do="idle", action="gaps")
    taker.wait()
    return json.loads((out / f"{name}.json").read_text()), gaps


MARKS = HERE.parent / ".build" / "film-marks"


SETTLED = 25
APART = 6
QUIET = 6
FOOT = "0,0.955,0.21,0.045"
BAND = 2


def measure(folder, reference=None):
    if not MARKS.exists() or MARKS.stat().st_mtime < (HERE / "film_marks.swift").stat().st_mtime:
        MARKS.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(HERE / "film_marks.swift"), "-o", str(MARKS)], check=True)
    made = subprocess.run([str(MARKS), str(folder), "0.005,0.05,0.19,0.75", "0.23,0.1,0.74,0.8"]
                          + ([str(reference)] if reference is not None else []),
                          capture_output=True, text=True, check=True)
    return {int(k): v for k, v in json.loads(made.stdout).items()}


def mixed(out_bands, in_bands, moved, leftward):
    count = len(out_bands)
    moved = min(count, int(round(moved)))
    if leftward:
        return sum(out_bands[moved:]) + sum(in_bands[:moved])
    return sum(out_bands[:count - moved]) + sum(in_bands[count - moved:])


def marked(shot, folder, column, legs, moves=True):
    shifts = [r[0] for r in shot["tracks"]["column"]]
    if not shifts:
        return {}
    final = shifts[-1]
    rest_from = len(shifts)
    for i in range(len(shifts) - 1, -1, -1):
        if abs(shifts[i] - final) > 1:
            break
        rest_from = i
    moved_from = next((i for i, x in enumerate(shifts) if abs(x) > 1), len(shifts))
    seen = measure(folder, min(len(shifts) - 1, rest_from + SETTLED))
    if not seen:
        return {}
    first, last = min(seen), max(seen)
    out_bands, in_bands = seen[first][4:], seen[last][4:]
    bad = {}
    for i, row in sorted(seen.items()):
        spread, ink, page_apart, column_apart = row[:4]
        if spread < 3 and i >= moved_from - QUIET:
            bad[i] = "blank"
            continue
        if legs == 1 and moves and i < rest_from:
            share = min(1, abs(shifts[i]) / column) if column else 0
            expected = mixed(out_bands, in_bands, abs(shifts[i]) / 2 / BAND, shifts[i] < 0)
            if 0.1 < share < 0.98 and sum(row[4:]) < 0.6 * expected:
                bad[i] = "sparse"
                continue
        if legs == 1 and rest_from <= i < rest_from + SETTLED and (page_apart > APART or column_apart > APART):
            bad[i] = "relayout"
    return bad


def strip(out, name, bad, foot=False):
    folder = out / f"{name}-frames"
    if not folder.exists():
        return
    if not STRIP.exists() or STRIP.stat().st_mtime < (HERE / "film_strip.swift").stat().st_mtime:
        STRIP.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-O", str(HERE / "film_strip.swift"), "-o", str(STRIP)], check=True)
    marks = ",".join(f"{i}:{why}" for i, why in sorted(bad.items()))
    subprocess.run([str(STRIP), str(folder), str(out / f"{name}.png"), marks, "8", "300"], check=True)
    if foot:
        subprocess.run([str(STRIP), str(folder), str(out / f"{name}-foot.png"), "", "6", "260", FOOT], check=True)


def remark(out, only):
    wanted = set(only.split(",")) if only else None
    column = 258
    for name, *_ in CASES:
        if wanted and name not in wanted or not (out / f"{name}.json").exists() or not (out / f"{name}-frames").exists():
            continue
        shot = json.loads((out / f"{name}.json").read_text())
        shown = marked(shot, out / f"{name}-frames", column, 3 if name == "three-in-a-row" else 1, moves=name != "cancelled")
        strip(out, name, shown)
        print(f"{name}: bad {sorted(shown.items())}")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / ".context" / "film"))
    ap.add_argument("--label", default="run")
    ap.add_argument("--only", default="")
    ap.add_argument("--app")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--emoji", action="store_true")
    ap.add_argument("--look", default="dark", choices=["dark", "light"])
    ap.add_argument("--reduced", action="store_true", help="the test copy runs with Reduce Motion")
    ap.add_argument("--remark", action="store_true", help="mark the kept frames of an earlier run again, without the app")
    a = ap.parse_args()
    if a.emoji:
        ICONS.update(EMOJI)
    if a.app:
        sv.APP = str(Path(a.app).resolve())
    out = Path(a.out) / a.label
    out.mkdir(parents=True, exist_ok=True)
    if a.remark:
        return remark(out, a.only)
    ma.build_film()
    t = sv.T()
    summary = {}
    try:
        sv.setup(sidebar=True, spaces=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "layout.cards": True,
                                               "start.fresh": False, "tabs.newAtBottom": True, "split": False})
        if a.reduced:
            subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        pids = pi.launch_shown()
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        c(do="window")
        c(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        c(do="ui", look=a.look)
        world()
        probe, _ = film(pids[0], "window", out, 0.4, lambda: None, "x:0,0,10,10,10,0")
        size = probe.get("window", [WIDTH, HEIGHT])
        column = c(do="probe").get("columnWidth", 258)
        stage = size[0] - column - 8
        tracks = (f"column:0,96,{column},{size[1] - 200},{column},1;"
                  f"page:{column + 4},60,{stage - 4},{size[1] - 120},{stage},1")
        wanted = set(a.only.split(",")) if a.only else None
        for name, begin, act, seconds in CASES:
            if wanted and name not in wanted:
                continue
            go(begin)
            if name == "parked-changed":
                go("Live")
                go("Work", wait=3.5)
            if a.reduced:
                film(pids[0], name, out, seconds, act, tracks, crop=f"0,{size[1] - 36},{column},36")
                frames = sorted((out / f"{name}-frames").glob("*.png"))
                if frames:
                    shutil.copy(out / f"{name}-last.png", out / f"{name}-frames" / f"{int(frames[-1].stem) + 60:03d}.png")
                subprocess.run([str(STRIP), str(out / f"{name}-frames"), str(out / f"{name}-foot.png"), "", "6", "260"], check=True)
                print(f"{name}: foot only, under Reduce Motion", flush=True)
                continue
            shot, gaps = film(pids[0], name, out, seconds, act, tracks)
            legs = 3 if name == "three-in-a-row" else 1
            shown = marked(shot, out / f"{name}-frames", column, legs, moves=name != "cancelled")
            strip(out, name, shown, foot=True)
            landed = space(action="state")["current"]
            if name == "to-new":
                space(action="leave")
                time.sleep(1)
            spans = [s for s in gaps.get("spansAt", []) if s[1] > 8]
            summary[name] = {"bad": {str(k): v for k, v in sorted(shown.items())}, "landedOn": landed,
                             "pageResidual": [r[1] for r in shot["tracks"]["page"]],
                             "columnResidual": [r[1] for r in shot["tracks"]["column"]],
                             "deliveredFps": shot.get("deliveredFps"), "longestMs": gaps.get("longestMs"),
                             "spansOver8": len(spans), "load": round(os.getloadavg()[0], 1)}
            print(f"{name}: bad {sorted(shown.items())} fps {shot.get('deliveredFps')} longest {gaps.get('longestMs')}",
                  flush=True)
            t.ok(f"{name}: no blank, sparse, stale or re-laid-out frame", not shown, sorted(shown.items()))
            if not a.keep:
                subprocess.run(["rm", "-rf", str(out / f"{name}-frames")])
        (out / "summary.json").write_text(json.dumps(summary, indent=1))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

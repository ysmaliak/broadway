#!/usr/bin/env python3
"""Two-finger swipes between spaces on the 120 Hz screen, in a heavy world.

Build first (`./build.sh`), then `python3 Tests/swipe_120.py --out DIR
[--only a,b] [--runs N] [--app OTHER.app] [--frames]`.

A test copy in a world of its own, shown behind the app in front
(SEARCH_SHOWN) and placed on the fastest screen (bench `idle place`); the run
stops if that screen isn't 120 Hz. Five spaces, each in its own look (glass,
a flat colour, a deep colour, a pale one, a warm one with grain), with page
cards on, three pins, a folder, a live folder fed from a local feed and about
twenty tabs. In front of each space is a real-looking local page: a long
article, a busy script-driven dashboard, a playing video, a split pair.

Each case is a bench trackpad stroke sequence (`space trackpad`, the same
handler the event monitor feeds), filmed with Tests/motion_film.swift at
120 fps, the test copy's own windows only, while the bench traces every
stroke and every display frame (`space trace`) and FrameGaps logs the main
thread's spans.

The film tool fits each frame of the column and of the page as the resting
pictures before and after, moved sideways (`--track`). From that, per case:

- deliveredFps over the motion, and slowFrames: film gaps over 1.5 periods
  while the model was moving;
- longestMs, the main thread's longest span, and the spans over 8 ms;
- firstMs: from the first taken stroke to the first frame that moved, and
  lagMs, the steady delay between a stroke and the frame that shows it;
- trackErr: the column's filmed offset against the fingers' offset, lagMs
  later (mean and worst, points); pageErr: the page against the column;
- release: the filmed speed over the four frames before and after the
  fingers let go (points per second);
- landing: the most a frame fails to be the resting pictures moved (the
  fit's residual) from the landing on, and any frame-to-frame step of the
  column larger than the motion around it.

DIR gets a summary.json and each film's contact sheet; `--frames` also
keeps every frame of every film.
"""
import argparse
import json
import os
import statistics
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
sv.use("swipe-120")
c = ma.c

PERIOD = 1000 / 120
WIDTH, HEIGHT = 1280, 800

WORDS = ("The committee met again on Thursday to weigh the proposal, which would move the river crossing two "
         "kilometres upstream and spare the old market from another decade of lorries. ").split()


def article(name):
    paragraphs = []
    for i in range(60):
        words = " ".join(WORDS[(i * 7 + k) % len(WORDS)] for k in range(90))
        paragraphs.append(f"<p>{words}</p>")
        if i % 6 == 2:
            paragraphs.append(f"<figure style='height:220px;border-radius:10px;background:linear-gradient({i * 23}deg,#d88,#88d,#8d8)'>"
                              f"</figure><figcaption>Figure {i // 6 + 1}</figcaption>")
        if i % 9 == 4:
            paragraphs.append(f"<h2>Part {i // 9 + 2}: what came after</h2>")
    return (f"<!doctype html><title>{name} — The Long Read</title><style>body{{margin:0;font:18px/1.6 Georgia,serif;"
            f"color:#222;background:#fbfaf7}}header{{position:sticky;top:0;background:#fff;border-bottom:1px solid #ddd;"
            f"padding:14px 40px;font:600 15px system-ui}}main{{max-width:720px;margin:40px auto;padding:0 20px}}"
            f"h1{{font-size:44px;line-height:1.1}}aside{{position:fixed;right:20px;top:90px;width:180px;font:13px system-ui;color:#666}}"
            f"</style><header>The Long Read · Cities · Rivers · Opinion</header><aside>Most read<ol><li>Bridges</li>"
            f"<li>Markets</li><li>Lorries</li></ol></aside><main><h1>{name}: the crossing that never came</h1>"
            f"{''.join(paragraphs)}</main>")


def dashboard(name):
    rows = "".join(f"<tr><td>#{i:04d}</td><td>job-{i}</td><td class=s>running</td><td class=v>0</td></tr>" for i in range(80))
    cards = "".join(f"<div class=card><b>Metric {i}</b><span class=n>0</span><div class=bar><i></i></div></div>" for i in range(24))
    return (f"<!doctype html><title>{name} — Console</title><style>body{{margin:0;font:13px system-ui;background:#0f1420;color:#cfd8e6}}"
            f"nav{{height:48px;background:#151c2c;display:flex;align-items:center;padding:0 16px;gap:18px}}"
            f".grid{{display:grid;grid-template-columns:repeat(6,1fr);gap:10px;padding:14px}}.card{{background:#1a2236;border-radius:8px;padding:10px}}"
            f".n{{display:block;font-size:22px}}.bar{{height:4px;background:#263150}}.bar i{{display:block;height:4px;background:#5b8cff;width:10%}}"
            f"canvas{{display:block;margin:0 14px;width:calc(100% - 28px);height:180px;background:#141b2b;border-radius:8px}}"
            f"table{{width:calc(100% - 28px);margin:14px;border-collapse:collapse}}td{{padding:4px 8px;border-bottom:1px solid #223}}</style>"
            f"<nav><b>Console</b><span>Overview</span><span>Jobs</span><span>Logs</span><span id=clock></span></nav>"
            f"<div class=grid>{cards}</div><canvas width=1600 height=360></canvas><table>{rows}</table>"
            "<script>const cv=document.querySelector('canvas'),g=cv.getContext('2d');let t=0;"
            "const ns=[...document.querySelectorAll('.n')],bs=[...document.querySelectorAll('.bar i')],vs=[...document.querySelectorAll('.v')];"
            "function frame(){t++;g.clearRect(0,0,1600,360);g.strokeStyle='#5b8cff';g.lineWidth=3;g.beginPath();"
            "for(let x=0;x<1600;x+=8){g.lineTo(x,180+120*Math.sin((x+t*4)/90)*Math.cos(t/60))}g.stroke();"
            "if(t%6==0){ns.forEach((n,i)=>n.textContent=((t*7+i*13)%997));bs.forEach((b,i)=>b.style.width=((t+i*9)%100)+'%');"
            "vs.forEach((v,i)=>v.textContent=(t*i)%100);document.getElementById('clock').textContent=new Date().toLocaleTimeString()}"
            "requestAnimationFrame(frame)}frame();</script>")


def feed():
    items = "".join(f"<item><title>Story {i}: the river, the market and the bridge</title>"
                    f"<link>http://127.0.0.1:{FEED_PORT[0]}/story-{i}</link><author>desk</author></item>" for i in range(8))
    return f"<?xml version='1.0'?><rss version='2.0'><channel><title>Desk</title>{items}</channel></rss>"


FEED_PORT = [0]


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0].strip("/")
        kind, _, name = path.partition("/")
        content = "text/html"
        if kind == "article":
            body = article(name.title())
        elif kind == "app":
            body = dashboard(name.title())
        elif kind == "feed.xml":
            body, content = feed(), "application/rss+xml"
        else:
            words = " ".join(WORDS[(len(path) + k) % len(WORDS)] for k in range(300))
            body = f"<!doctype html><title>{path.replace('-', ' ').title()}</title><h1>{path}</h1><p>{words}</p>"
        data = body.encode()
        self.send_response(200)
        self.send_header("content-type", content)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
FEED_PORT[0] = server.server_port
BASE = f"http://127.0.0.1:{server.server_port}"

LOOKS = [
    ("Glass", {"colours": ["7CC4F2"], "intensity": 0.6, "glass": True, "transparency": 0.35}),
    ("Flat", {"colours": ["3139FB"], "intensity": 0.55}),
    ("Deep", {"colours": ["000354", "2404AA"], "intensity": 1.0}),
    ("Pale", {"colours": ["F0B4FF", "8CACFF"], "intensity": 0.3}),
    ("Warm", {"colours": ["FB3A4D"], "intensity": 0.8, "grain": 0.25}),
]


def space(**f):
    return c(do="space", **f)


def opened(url, front=False):
    return sv.sp("open", url=url, foreground=front, atEnd=True)["resultID"]


def world():
    c(do="live", args=["on"])
    for index, (name, look) in enumerate(LOOKS):
        if index > 0:
            space(action="new", name=name)
        space(action="go", index=index + 1)
        space(action="look", **look)
        slug = name.lower()
        pins = [opened(f"{BASE}/{slug}-pin-{k}") for k in range(3)]
        for pin in pins:
            c(do="pin", id=pin)
        folder = [opened(f"{BASE}/{slug}-folder-{k}") for k in range(5)]
        c(do="group", id=folder[0], new=True, name=f"{name} reading")
        for tab in folder[1:]:
            c(do="group", id=tab, name=f"{name} reading")
        if index < 3:
            c(do="live", args=["add", f"{name} desk", f"{BASE}/feed.xml"])
        for k in range(18):
            opened(f"{BASE}/{slug}-tab-{k:02d}")
        if name in ("Glass", "Warm"):
            front = opened(f"{BASE}/article/{slug}", front=True)
        elif name == "Flat":
            front = opened(f"{BASE}/app/{slug}", front=True)
        elif name == "Deep":
            front = opened(f"http://127.0.0.1:{pi.srv.server_port}/video", front=True)
        else:
            left = opened(f"{BASE}/article/{slug}-left", front=True)
            right = opened(f"{BASE}/app/{slug}-right")
            sv.sp("pair", id=right, **{"with": left}, side="right")
            front = left
        c(do="wait", id=front, seconds=20)
        sv.sp("select", id=front)
        time.sleep(1.0)
    space(action="go", index=1)
    time.sleep(1.5)


def stroke(stops, speed, at=None, momentum=True, cancel=False):
    g = {"stops": stops, "speed": speed, "momentum": momentum, "cancel": cancel}
    if at is not None:
        g["at"] = at
    return g


CASES = [
    ("slow-drag", 2, 3, [stroke([-230], 350)], 2.2),
    ("normal-flick", 2, 3, [stroke([-140], 1100)], 1.6),
    ("fast-flick", 2, 3, [stroke([-90], 2600)], 1.4),
    ("reverse", 2, 2, [stroke([-180, -40], 700)], 2.0),
    ("interrupted", 2, 2, [stroke([-140], 1100), stroke([150], 1100, at=0.30)], 2.0),
    ("three-in-a-row", 1, 4, [stroke([-140], 1100), stroke([-140], 1100, at=0.36), stroke([-140], 1100, at=0.72)], 2.6),
    ("band-first", 1, 1, [stroke([160], 700)], 1.6),
    ("band-last", 5, 5, [stroke([-160], 700)], 1.6),
    ("back-flick", 3, 2, [stroke([140], 1100)], 1.6),
]


def film(pid, name, out, seconds, act, tracks, keep):
    args = [str(ma.FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(out / name),
            "--scale", "1", "--fps", "120", "--track", tracks, "--columns", "6"]
    if keep:
        args += ["--frames", str(out / f"{name}-frames")]
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
    space(action="trace")
    load = os.getloadavg()[0]
    act()
    time.sleep(max(0.2, seconds - 0.5))
    gaps = c(do="idle", action="gaps")
    trace = space(action="trace", report=True)
    taker.wait()
    shot = json.loads((out / f"{name}.json").read_text())
    return shot, trace, gaps, load


def at_or_before(rows, t):
    lo, hi = 0, len(rows) - 1
    if not rows or rows[0][0] > t:
        return None
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if rows[mid][0] <= t:
            lo = mid
        else:
            hi = mid - 1
    return rows[lo]


def analyse(shot, trace, gaps, column, stage, lands_elsewhere):
    hosts = shot["hosts"]
    col = [r[0] for r in shot["tracks"]["column"]]
    page = [r[0] for r in shot["tracks"]["page"]]
    res = [r[1] for r in shot["tracks"]["column"]]
    pres = [r[1] for r in shot["tracks"]["page"]]
    strokes = trace["strokes"]
    ticks = trace["frames"]
    taken = [s for s in strokes if s[3] == 1 and s[2] in (1, 2, 3, 4)]
    if not taken or len(hosts) < 3:
        return {"error": "nothing taken or filmed", "strokes": len(strokes), "frames": len(hosts)}
    first_stroke = next((s[0] for s in taken if abs(s[4]) > 0), taken[0][0])
    moved = [i for i in range(len(hosts)) if abs(col[i] - col[0]) > 0.75]
    if not moved:
        return {"error": "the column never moved on film"}
    start = moved[0]
    final = col[-1]
    settled = len(hosts) - 1
    while settled > start and abs(col[settled - 1] - final) < 0.75:
        settled -= 1
    span = range(start, settled + 1)
    motion_ms = (hosts[settled] - hosts[start]) * 1000
    model = [(t[0], t[3]) for t in ticks]

    def model_moving(a, b):
        inside = [m for m in model if a - PERIOD / 1000 <= m[0] <= b]
        return len(inside) >= 2 and max(m[1] for m in inside) - min(m[1] for m in inside) > 0.6

    slow = []
    for i in range(start + 1, settled + 1):
        gap = (hosts[i] - hosts[i - 1]) * 1000
        if gap > 1.5 * PERIOD and model_moving(hosts[i - 1], hosts[i]):
            slow.append(round(gap, 1))
    held = 0
    for i in range(start + 1, settled + 1):
        if abs(col[i] - col[i - 1]) < 0.3 and model_moving(hosts[i - 1], hosts[i]) and (hosts[i] - hosts[i - 1]) * 1000 < 1.5 * PERIOD:
            held += 1
    fingers = [(s[0], s[4]) for s in strokes if s[2] in (1, 2, 3, 4) and s[3] == 1]
    ended = [s[0] for s in strokes if s[2] in (3, 4) and s[3] == 1]
    held_until = ended[0] if ended else fingers[-1][0]
    best = None
    for lag in range(0, 61):
        errs = []
        for i in range(start, len(hosts)):
            t = hosts[i] - lag / 1000
            if t > held_until or t < first_stroke:
                continue
            f = at_or_before(fingers, t)
            if f:
                errs.append(abs(col[i] - f[1]))
        if len(errs) >= 3 and (best is None or statistics.mean(errs) < best[1]):
            best = (lag, statistics.mean(errs), max(errs), len(errs))
    page_err = [abs(page[i] * column / stage - col[i]) for i in span]
    release = None
    if ended:
        r = ended[0] + (best[0] / 1000 if best else 0.0)
        before = [i for i in range(len(hosts)) if r - 0.045 <= hosts[i] <= r]
        after = [i for i in range(len(hosts)) if r < hosts[i] <= r + 0.045]

        def speed(ix):
            if len(ix) < 2:
                return None
            return round((col[ix[-1]] - col[ix[0]]) / (hosts[ix[-1]] - hosts[ix[0]]))
        trail = [f for f in fingers if ended[0] - 0.08 <= f[0] <= ended[0]]
        finger_speed = round((trail[-1][1] - trail[0][1]) / (trail[-1][0] - trail[0][0])) if len(trail) >= 2 and trail[-1][0] > trail[0][0] else None
        release = {"fingers": finger_speed, "before": speed(before), "after": speed(after)}
    landed = next((t[0] for t, u in zip(ticks, ticks[1:]) if u[5] != t[5]), None)
    landing = None
    if landed:
        after = [i for i in range(len(hosts)) if hosts[i] >= landed - 0.004]
        before = [i for i in span if hosts[i] < landed - 0.004]
        steps = [abs(col[i] - col[i - 1]) for i in range(max(1, start), len(hosts))]
        typical = statistics.median([s for s in steps if s > 0.3] or [0])
        landing = {
            "atMs": round((landed - hosts[start]) * 1000),
            "residualBefore": round(max([res[i] for i in before[-6:]] or [0]), 2),
            "residualAfter": round(max([res[i] for i in after[:8]] or [0]), 2),
            "pageResidualBefore": round(max([pres[i] for i in before[-6:]] or [0]), 2),
            "pageResidualAfter": round(max([pres[i] for i in after[:8]] or [0]), 2),
            "restResidual": round(statistics.median([res[i] for i in range(settled, len(hosts))] or [0]), 2),
            "jumps": [round(col[i] - col[i - 1], 1) for i in after[:8] if i > 0 and abs(col[i] - col[i - 1]) > max(4, 3 * typical)
                      and abs(col[i - 1] - final) > 0.75],
        }
    origin = gaps.get("startHost", first_stroke)
    spans = [[round((origin + s[0] / 1000 - first_stroke) * 1000), s[1]] for s in gaps.get("spansAt", []) if s[1] > 8]
    bodies = {}
    for b in trace.get("bodies", []):
        at = round((b["t"] - first_stroke) * 1000)
        if sum(b["n"].values()) > 6:
            bodies[at] = sum(b["n"].values())
    return {
        "deliveredFps": round((settled - start) / ((hosts[settled] - hosts[start]) or 1), 1),
        "frames": settled - start + 1,
        "expected": round(motion_ms / PERIOD) + 1,
        "slowFrames": len(slow),
        "heldFrames": held,
        "tickHz": gaps.get("tickHz"),
        "linkHz": gaps.get("hz"),
        "slowMs": slow,
        "motionMs": round(motion_ms),
        "firstMs": round((hosts[start] - first_stroke) * 1000, 1),
        "lagMs": best[0] if best else None,
        "trackErr": [round(best[1], 2), round(best[2], 2)] if best else None,
        "pageErr": [round(statistics.mean(page_err), 2), round(max(page_err), 2)] if page_err else None,
        "release": release,
        "landing": landing,
        "longestMs": gaps.get("longestMs"),
        "hitches": gaps.get("hitches"),
        "spans": spans,
        "bodies": bodies,
        "landedMs": round((landed - first_stroke) * 1000) if landed else None,
        "taken": sum(1 for s in strokes if s[3] == 1),
        "strokes": len(strokes),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--app")
    ap.add_argument("--frames", action="store_true")
    ap.add_argument("--any-screen", action="store_true")
    ap.add_argument("--sample", type=int, default=0, help="seconds of `sample` over back-and-forth flicks, instead of the cases")
    ap.add_argument("--profile", type=int, default=0, help="seconds of xctrace Time Profiler over back-and-forth flicks, instead of the cases")
    a = ap.parse_args()
    if a.app:
        sv.APP = str(Path(a.app).resolve())
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    ma.build_film()
    pi.make_clip()
    giver = pi.front_pid()
    summary = {}
    try:
        sv.setup(sidebar=True, spaces=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False,
                                               "start.fresh": False, "tabs.newAtBottom": True})
        pids = pi.launch_shown()
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        c(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        placed = c(do="idle", action="place")
        print("placed:", json.dumps(placed), flush=True)
        if placed.get("screenHz") != 120 and not a.any_screen:
            sys.exit(f"the window is not on a 120 Hz screen: {placed}")
        world()
        if giver:
            c(do="idle", action="give", pid=giver)
        time.sleep(2)
        for attempt in range(4):
            try:
                probe = ma.film(pids[0], "window", out, 0.4, lambda: None)
                break
            except RuntimeError:
                if attempt == 3:
                    raise
                time.sleep(3)
        size = probe.get("window", [WIDTH, HEIGHT])
        column = c(do="probe").get("columnWidth", 258)
        stage = size[0] - column - 8
        tracks = (f"column:0,44,{column},{size[1] - 160},{column},{{in}};"
                  f"page:{column},60,{stage},{size[1] - 120},{stage},{{in}}")
        summary["world"] = {"window": size, "column": column, "stage": stage, "placed": placed,
                            "spaces": [s["name"] for s in space(action="state").get("spaces", [])]}
        if a.profile:
            space(action="go", index=2)
            time.sleep(1.5)
            trace = out / "profile.trace"
            subprocess.run(["rm", "-rf", str(trace)])
            taker = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Time Profiler", "--attach", str(pids[0]),
                                      "--time-limit", f"{a.profile}s", "--output", str(trace)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(3)
            marks = []
            end = time.time() + a.profile - 4
            way = -1
            while time.time() < end:
                marks.append(time.time())
                space(action="trackpad", gestures=[stroke([140 * way], 1100)])
                way = -way
                time.sleep(1.6)
            taker.wait()
            (out / "marks.json").write_text(json.dumps(marks))
            return
        if a.sample:
            space(action="go", index=2)
            time.sleep(1.2)
            taker = subprocess.Popen(["sample", str(pids[0]), str(a.sample), "-file", str(out / "sample.txt")],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            end = time.time() + a.sample
            way = -1
            while time.time() < end:
                space(action="trackpad", gestures=[stroke([140 * way], 1100)])
                way = -way
                time.sleep(0.9)
            taker.wait()
            return
        wanted = set(a.only.split(",")) if a.only else None
        for name, begin, end, gestures, seconds in CASES:
            if wanted and name not in wanted:
                continue
            runs = []
            for run in range(a.runs):
                space(action="go", index=begin)
                time.sleep(1.4)
                act = lambda: space(action="trackpad", gestures=gestures)
                try:
                    shot, trace, gaps, load = film(pids[0], f"{name}-{run}", out, seconds, act,
                                                   tracks.replace("{in}", "1" if end != begin else "0"), a.frames)
                    result = analyse(shot, trace, gaps, column, stage, end != begin)
                    result["load"] = round(load, 1)
                    result["landedOn"] = space(action="state")["current"]
                    (out / f"{name}-{run}.trace.json").write_text(json.dumps(trace))
                    (out / f"{name}-{run}.gaps.json").write_text(json.dumps(gaps))
                except Exception as e:
                    result = {"error": str(e)}
                runs.append(result)
                print(f"{name}-{run}: {json.dumps(result)}", flush=True)
            summary[name] = runs
    finally:
        if giver:
            try:
                c(do="idle", action="give", pid=giver)
            except Exception:
                pass
        sv.finish()
        pi.CLIP.unlink(missing_ok=True)
        (out / "summary.json").write_text(json.dumps(summary, indent=1))


if __name__ == "__main__":
    main()

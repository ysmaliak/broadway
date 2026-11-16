#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORDS = [a for a in sys.argv[1:] if not a.startswith("-")]
LABEL = WORDS[0] if WORDS else "gesture-discs"
REDUCED = "reduced" in WORDS[1:]
FILMS = "nofilm" not in WORDS[1:]
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

OUT = ROOT / ".context" / "shots" / LABEL
CAPTURE = ROOT / ".context" / "shots" / "capture"
FPS = 120
SCALE = 2
GLYPHS = ["back", "forward", "refresh"]
EDGES = {"back": "left", "forward": "right", "refresh": "top"}
ARM = {"back": 70, "forward": 70, "refresh": 110}
RATE = 0.6
STAGES = [("entering", 0.25), ("half", 0.5), ("armed", 1.15)]
LOOKS = {
    "noir": {"colours": ["000000"], "grain": 0.3},
    "gray": {"colour": "gray", "glass": False},
    "glass": {"colour": "gray", "glass": True},
    "dusk": {"colours": ["2B1A7A", "D23770", "BF5600"], "grain": 0.4},
    "paper": {"colours": ["EFE6D2"], "grain": 0.5},
    "borealis": {"colours": ["0B1D51", "00846F", "7B3FE4"], "grain": 0.4},
}
GROUNDS = {"light": ("#fbfaf7", "#1d1d1f"), "dark": ("#15161a", "#e8e8ea")}
t = sv.T()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        ground, ink = GROUNDS.get(parts[0], GROUNDS["light"])
        name = parts[-1] or "page"
        body = (f"<!doctype html><meta charset=utf-8><title>{name}</title>"
                f"<style>body{{margin:0;background:{ground};color:{ink};font:17px/1.55 -apple-system,system-ui}}"
                f"main{{max-width:640px;margin:0 auto;padding:56px 24px}}</style><main><h1>{name}</h1>"
                + "".join(f"<p>{n}. The quick brown fox jumps over the lazy dog.</p>" for n in range(60)) + "</main>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://localhost:{srv.server_port}"


def where(tab):
    return next((x["url"] for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == tab), "")


def settle_at(tab, name, within=6):
    until = time.time() + within
    while time.time() < until:
        if where(tab).endswith("/" + name):
            sv.cmd({"do": "wait", "id": tab, "seconds": 5})
            time.sleep(0.5)
            return True
        time.sleep(0.1)
    return False


def middle_tab(ground):
    tab = sv.cmd({"do": "open", "url": f"{BASE}/{ground}/a"})["id"]
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})
    for name in ("b", "c"):
        sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/{ground}/{name}"})
        sv.cmd({"do": "wait", "id": tab, "seconds": 5})
        time.sleep(0.3)
    sv.ev(tab, "history.back()")
    settle_at(tab, "b")
    return tab


def home(tab):
    if where(tab).endswith("/a"):
        sv.ev(tab, "history.forward()")
    elif where(tab).endswith("/c"):
        sv.ev(tab, "history.back()")
    settle_at(tab, "b")


def stroke(glyph, tab, peak, hold=150, cancel=False):
    steps = max(4, round(peak * ARM[glyph] / 2))
    travel = steps * 2
    ms = travel / ARM[glyph] * RATE * 1000
    move = {"back": {"dx": travel, "dy": 0}, "forward": {"dx": -travel, "dy": 0}, "refresh": {"dx": 0, "dy": travel}}[glyph]
    return {"do": "wheel", "id": tab, "exact": True, "steps": steps, "ms": ms, "hold": hold, "cancel": cancel, **move}, ms


def mine(glyph, discs):
    return next((d for d in discs if d["edge"] == EDGES[glyph]), None)


def progress(glyph, d):
    if "progress" in d:
        return d["progress"]
    return d["ring"] * 110 / ARM[glyph] if d["ring"] < 0.999 else None


def run(glyph, tab, peak=1.3):
    request, ms = stroke(glyph, tab, peak, hold=1000, cancel=True)
    got = {}
    count = int((ms + 600) / 1000 / 0.008)
    sampler = threading.Thread(target=lambda: got.update(sv.cmd({"do": "discs", "id": tab, "sample": count, "every": 0.008})))
    sampler.start()
    time.sleep(0.05)
    sv.cmd(request)
    sampler.join()
    time.sleep(0.4)
    home(tab)
    release = 0.05 + ms / 1000 + 1.0
    return [d for d in (mine(glyph, f["discs"]) for f in got.get("frames", []) if f["t"] < release - 0.1) if d]


def at(glyph, samples, p, key):
    rising = [(progress(glyph, d), d[key]) for d in samples if progress(glyph, d) is not None]
    for (pa, va), (pb, vb) in zip(rising, rising[1:]):
        if pa <= p <= pb and pb > pa:
            return va + (vb - va) * (p - pa) / (pb - pa)
    return None


EXACT = ["size", "ringWidth", "ringInset", "glyphSize", "glyphWeight", "corner"]
MOVING = {"gap": 1.0, "diameter": 0.8, "opacity": 0.05, "ring": 0.03, "glyphOpacity": 0.05}
HELD = {"diameter": 0.6, "opacity": 0.05, "ring": 0.03, "glyphOpacity": 0.05}
COLOURS = ["ink", "ringInk", "tint"]


def close(scene, stage, values, room, key):
    known = {g: (round(v, 2) if v is not None else None) for g, v in values.items()}
    numbers = [v for v in known.values() if v is not None]
    t.ok(f"{scene}, {stage}: one {key} (within {room})", len(numbers) == 3 and max(numbers) - min(numbers) <= room, known)


def same(scene, runs, stages):
    seen = {g: (r[-1] if r else None) for g, r in runs.items()}
    t.ok(f"{scene}: all three discs are on the page", all(seen.values()), {g: bool(d) for g, d in seen.items()})
    if not all(seen.values()):
        return
    for stage, p in stages:
        keys = dict(MOVING) if stage != "armed" else {"gap": MOVING["gap"]}
        for key, room in keys.items():
            field = "target" if key == "gap" and all("target" in d for r in runs.values() for d in r) else key
            close(scene, f"{stage} ({p:g} of the way to armed)", {g: at(g, runs[g], p, field) for g in GLYPHS}, room, key)
    for key, room in HELD.items():
        close(scene, "armed and held", {g: seen[g][key] for g in GLYPHS}, room, key)
    for g in GLYPHS:
        t.ok(f"{scene}: {g} is clipped by its page, so outside its edge it is hidden", all(d.get("clipped") for d in runs[g]),
             sorted({str(d.get("clipped")) for d in runs[g]}))
        if "target" in seen[g]:
            t.ok(f"{scene}, armed and held: {g} is drawn where it aims (within 0.5 pt)", abs(seen[g]["gap"] - seen[g]["target"]) < 0.5,
                 (round(seen[g]["gap"], 2), round(seen[g]["target"], 2)))
            late = [abs(d["gap"] - d["target"]) for d in runs[g][len(runs[g]) // 3:]]
            t.ok(f"{scene}: {g} is drawn no more than a frame behind its aim once it has caught up (2.5 pt)", late and max(late) <= 2.5,
                 round(max(late or [0]), 2))
    for key in EXACT:
        values = {g: seen[g][key] for g in GLYPHS}
        t.ok(f"{scene}: one {key}", max(values.values()) - min(values.values()) < 0.01, values)
    for key in COLOURS:
        values = {g: [round(v, 3) for v in seen[g][key]] for g in GLYPHS}
        flat = list(values.values())
        alike = all(len(v) == len(flat[0]) and all(abs(a - b) <= 0.02 for a, b in zip(v, flat[0])) for v in flat)
        t.ok(f"{scene}: one {key}", alike, values)


def spec(scene, seen):
    for g, d in seen.items():
        if not d:
            continue
        t.ok(f"{scene}: {g} is the family's disc (44 pt, 14 pt semibold glyph, 1.5 pt ring)",
             abs(d["size"] - 44) < 0.01 and abs(d["glyphSize"] - 14) < 0.01 and abs(d["glyphWeight"] - 0.3) < 0.01 and abs(d["ringWidth"] - 1.5) < 0.01,
             (d["size"], d["glyphSize"], d["glyphWeight"], d["ringWidth"]))
        t.ok(f"{scene}, armed and held: {g}'s ring is whole and its glyph at full ink",
             d["ring"] > 0.99 and d["glyphOpacity"] > 0.97, (round(d["ring"], 3), round(d["glyphOpacity"], 3)))


def readings(scene, tab, stages=STAGES):
    runs = {g: run(g, tab) for g in GLYPHS}
    same(scene, runs, stages)
    held = {g: (r[-1] if r else None) for g, r in runs.items()}
    spec(scene, held)
    return {"armed": held, "runs": runs}


def film_start(pid, number, folder, seconds):
    shutil.rmtree(folder, ignore_errors=True)
    if not FILMS:
        return None, time.time()
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number), str(SCALE), str(FPS)], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.02)
    return p, time.time()


def timeline(glyph, tab, kind, pid, number, folder):
    peak = 0.6 if kind == "short" else 1.4
    request, ms = stroke(glyph, tab, peak, hold=150)
    seconds = ms / 1000 + 1.7
    p, ready = film_start(pid, number, folder, seconds)
    got = {}
    began = time.time()
    sampler = threading.Thread(target=lambda: got.update(sv.cmd({"do": "discs", "id": tab, "sample": int((seconds - 0.3) / 0.008), "every": 0.008})))
    sampler.start()
    time.sleep(0.15)
    sent = time.time()
    sv.cmd(request)
    sampler.join()
    if p:
        said = p.communicate()[0].strip()
        if said:
            print("   ", folder.name, said, flush=True)
    release = sent - began + ms / 1000 + 0.15
    frames = [{"t": f["t"] - release, "disc": mine(glyph, f["discs"])} for f in got.get("frames", [])]
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "samples.json").write_text(json.dumps({"release": release, "ready": sent - ready, "ms": ms, "frames": frames}))
    time.sleep(0.6)
    if kind == "armed":
        home(tab)
    return frames, sent - ready + ms / 1000 + 0.15


def life(scene, kind, lines):
    rest = 12
    gone = {}
    for g, frames in lines.items():
        seen = [f for f in frames if f["disc"] and f["disc"]["opacity"] > 0.02]
        before = [f for f in seen if f["t"] < 0]
        after = [f for f in seen if f["t"] >= 0]
        gone[g] = round(after[-1]["t"], 3) if after else (0.0 if before else None)
        if not before:
            t.ok(f"{scene}, {kind}: {g} showed", False)
            continue
        first = before[0]["disc"]
        if REDUCED:
            t.ok(f"{scene}, {kind}: {g} sits at its rest from the start under Reduce Motion", abs(first["gap"] - rest) < 1, round(first["gap"], 2))
            t.ok(f"{scene}, {kind}: {g} never scales under Reduce Motion", all(abs(f["disc"]["scale"] - 1) < 0.01 for f in seen),
                 sorted({round(f["disc"]["scale"], 3) for f in seen})[:5])
        else:
            t.ok(f"{scene}, {kind}: {g} enters from outside its edge, small", first["gap"] < -20 and first["scale"] < 0.92, (round(first["gap"], 1), round(first["scale"], 3)))
            gaps = [f["disc"]["gap"] for f in before]
            t.ok(f"{scene}, {kind}: {g} follows the fingers, never stepping back", all(b >= a - 0.5 for a, b in zip(gaps, gaps[1:])), gaps[:8])
            if kind == "armed":
                pops = [f["disc"]["scale"] for f in before if f["disc"]["ring"] > 0.99]
                t.ok(f"{scene}, armed: {g} gives one small pop", pops and max(pops) > 1.03 and max(pops) < 1.12, [round(s, 3) for s in pops[:12]])
            if kind == "short" and after:
                last = after[-1]["disc"]
                t.ok(f"{scene}, short: {g} goes back the way it came", last["gap"] < before[-1]["disc"]["gap"] - 8, (round(before[-1]["disc"]["gap"], 1), round(last["gap"], 1)))
            if kind == "armed" and after:
                near = min(abs(f["disc"]["gap"] - rest) for f in after)
                t.ok(f"{scene}, armed: {g} commits to its rest {rest} pt from the edge", near < 1.5, round(near, 2))
    if kind == "armed":
        for g, frames in lines.items():
            after = [f["disc"] for f in frames if f["disc"] and f["t"] >= 0.05]
            angles = [d.get("turned", 0) for d in after]
            span = sum(abs(b - a) if abs(b - a) < 3 else abs(abs(b - a) - 6.283) for a, b in zip(angles, angles[1:]))
            if g == "refresh" and not REDUCED:
                t.ok(f"{scene}, armed: refresh turns its arrow while the page loads", span > 1.0, round(span, 2))
                drift = max((d.get("glyphDrift", 0) for d in after), default=0)
                t.ok(f"{scene}, armed: the turning arrow stays centred (0.3 pt)", drift < 0.3, round(drift, 3))
            else:
                t.ok(f"{scene}, armed: {g}'s arrow never turns", all(abs(a) < 0.01 for a in angles), sorted({round(a, 2) for a in angles})[:5])
    times = [v for v in gone.values() if v is not None]
    room = 0.09 if kind == "armed" else 0.05
    t.ok(f"{scene}, {kind}: the three leave together (within {int(room * 1000)} ms)", len(times) == 3 and max(times) - min(times) <= room, gone)
    return gone


def crop_box(disc):
    size = 120
    hx, hy, hw, hh = disc["hostX"], disc["hostY"], disc["hostWidth"], disc["hostHeight"]
    if disc["edge"] == "left":
        x, y = hx - 4, hy + hh / 2 - size / 2
    elif disc["edge"] == "right":
        x, y = hx + hw - size + 4, hy + hh / 2 - size / 2
    else:
        x, y = hx + hw / 2 - size / 2, hy - 4
    return [int(v * SCALE) for v in (x, y, size, size)]


def frame_at(folder, at):
    frames = sorted(folder.glob("0*.png"))
    times = json.loads((folder / "times.json").read_text()) if (folder / "times.json").exists() else []
    if not frames or not times:
        return None
    index = min(range(min(len(frames), len(times))), key=lambda i: abs(times[i] - at))
    return frames[index]


def strip(name, picks, rows):
    work = OUT / f"{name}-work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    n = 0
    for row in rows:
        for path, box in row:
            target = work / f"{n:04d}.png"
            if path:
                x, y, w, h = box
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(path), "-vf", f"crop={w}:{h}:{x}:{y}", str(target)], check=False)
            if not target.exists():
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", f"color=c=red:s={box[2]}x{box[3]}", "-frames:v", "1", str(target)], check=False)
            n += 1
    columns = len(rows[0])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "1", "-i", str(work / "%04d.png"),
                    "-vf", f"tile={columns}x{len(rows)}:padding=4:color=gray", "-frames:v", "1", str(OUT / f"{name}.png")], check=False)
    shutil.rmtree(work, ignore_errors=True)
    print("    strip", (OUT / f"{name}.png").relative_to(ROOT), picks, flush=True)


def films(scene, tab, pid, number, box):
    lines = {}
    for kind in ("short", "armed"):
        folders, releases, frames = {}, {}, {}
        for g in GLYPHS:
            folder = OUT / scene / f"{g}-{kind}"
            frames[g], releases[g] = timeline(g, tab, kind, pid, number, folder)
            folders[g] = folder
        lines[kind] = life(scene, kind, frames)
        if FILMS and len(box) == 3:
            picks = [-0.45, -0.3, -0.2, -0.1, -0.05, 0, 0.04, 0.08, 0.12, 0.16, 0.24, 0.32, 0.4, 0.5]
            rows = [[(frame_at(folders[g], releases[g] + p), box[g]) for p in picks] for g in GLYPHS]
            strip(f"{scene}-{kind}", picks, rows)
            for g in GLYPHS:
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(folders[g] / "%04d.png"),
                                "-pix_fmt", "yuv420p", str(OUT / scene / f"{g}-{kind}.mp4")], check=False)
            stages = [("entering", -(1.4 - 0.25) * RATE - 0.15), ("half", -(1.4 - 0.5) * RATE - 0.15), ("armed", -0.1)]
            if kind == "armed":
                lines["stills-armed"] = {g: [(frame_at(folders[g], releases[g] + at), box[g]) for _, at in stages] + [(frame_at(folders[g], releases[g] + 0.08), box[g])] for g in GLYPHS}
            else:
                lines["stills-short"] = {g: [(frame_at(folders[g], releases[g] + 0.08), box[g])] for g in GLYPHS}
    if FILMS and "stills-armed" in lines:
        rows = [lines["stills-armed"][g][:3] + lines["stills-short"][g] + lines["stills-armed"][g][3:] for g in GLYPHS]
        strip(f"{scene}-stages", ["entering", "half", "armed", "released before arming +80 ms", "released armed +80 ms"], rows)
    return {k: v for k, v in lines.items() if not k.startswith("stills")}


def still(scene, tab, box, pid, number):
    if not FILMS:
        return
    rows = []
    for g in GLYPHS:
        folder = OUT / scene / f"{g}-still"
        request, ms = stroke(g, tab, 1.15, hold=900, cancel=True)
        p, ready = film_start(pid, number, folder, ms / 1000 + 0.9)
        sent = time.time()
        sv.cmd(request)
        p and p.communicate()
        rows.append([(frame_at(folder, sent - ready + ms / 1000 + 0.5), box[g])])
        time.sleep(0.6)
        home(tab)
    strip(f"{scene}-armed", ["armed"], [[r[0] for r in rows]])


def boxes(scene_read):
    return {g: crop_box(d) for g, d in scene_read["armed"].items() if d and "hostX" in d}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if FILMS and not CAPTURE.exists():
        CAPTURE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.use("gesture-discs-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"motion.testReduced": REDUCED})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    report = {"reduced": REDUCED, "scenes": {}}
    try:
        sv.cmd({"do": "resize", "width": 1100, "height": 760, "steps": 1})
        sv.cmd({"do": "ui", "swipepages": True, "look": "light"})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1)
        light = middle_tab("light")
        dark = middle_tab("dark")

        def want(name):
            return not ONLY or name in ONLY

        scenes = [("light-ui-light-page", "light", light), ("dark-ui-dark-page", "dark", dark)]
        if not REDUCED:
            scenes += [("light-ui-dark-page", "light", dark), ("dark-ui-light-page", "dark", light)]
        for scene, look, tab in scenes:
            if not want(scene):
                continue
            print(scene, flush=True)
            sv.cmd({"do": "ui", "look": look})
            sv.cmd({"do": "select", "id": tab})
            time.sleep(0.8)
            read = readings(scene, tab)
            report["scenes"][scene] = {"readings": read}
            box = boxes(read)
            if scene in ("light-ui-light-page", "dark-ui-dark-page"):
                report["scenes"][scene]["leaves"] = films(scene, tab, pid, number, box)
            elif len(box) == 3:
                still(scene, tab, box, pid, number)

        if not REDUCED and want("looks"):
            sv.cmd({"do": "ui", "look": "dark"})
            sv.cmd({"do": "select", "id": light})
            for name, look in LOOKS.items():
                print("look", name, flush=True)
                sv.cmd({"do": "space", "action": "look", **look})
                time.sleep(0.8)
                read = readings(f"look {name}", light, [("armed", 1.15)])
                report["scenes"][f"look-{name}"] = {"readings": read}
                box = boxes(read)
                if len(box) == 3:
                    still(f"look-{name}", light, box, pid, number)
            sv.cmd({"do": "space", "action": "look", "colour": "gray", "glass": False})

        if not REDUCED and want("split"):
            print("split", flush=True)
            sv.cmd({"do": "ui", "look": "light"})
            other = middle_tab("light")
            sv.sp("pair", id=other, **{"with": light}, side="right")
            time.sleep(0.8)
            sv.sp("focus", id=other)
            time.sleep(0.3)
            read = readings("split view, right pane", other, [("half", 0.5), ("armed", 1.15)])
            report["scenes"]["split"] = {"readings": read}
            frames = sv.frames(sv.sp("state"))
            for g, d in read["armed"].items():
                if d:
                    t.ok(f"split view: {g} sits on its own pane's edge",
                         abs(d["hostWidth"] - frames[other]["width"]) < 1.5, (d["hostWidth"], frames[other]["width"]))
            box = boxes(read)
            if len(box) == 3:
                still("split", other, box, pid, number)
            sv.sp("close", id=other)
            time.sleep(0.5)

        if not REDUCED and want("fast"):
            print("fast", flush=True)
            sv.cmd({"do": "ui", "pages120": "always", "look": "light"})
            sv.cmd({"do": "select", "id": light})
            time.sleep(0.8)
            read = readings("120 Hz pages", light, [("armed", 1.15)])
            box = boxes(read)
            report["scenes"]["fast"] = {"readings": read, "leaves": films("fast", light, pid, number, box)}
            sv.cmd({"do": "ui", "pages120": "onPower"})
    finally:
        (OUT / "report.json").write_text(json.dumps(report, indent=1, default=str))
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

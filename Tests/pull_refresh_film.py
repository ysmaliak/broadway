#!/usr/bin/env python3
"""Films of pull to refresh, of the probe's own window only, with the disc's place sampled beside them.

Build first (`./build.sh`), then `python3 Tests/pull_refresh_film.py [label] [reduced] [slow]`.
With `slow` the reload answers after three seconds and only one pull is filmed,
so the arrow turns for several whole turns.
A probe shown on screen in a world of its own (never brought to the front),
filmed by its window id with Tests/WindowCapture.swift, never a region of the
display. Each scene leaves frames, a contact sheet of the page's top middle
and `samples.json` (where the disc was drawn, its opacity and its ring, every
few milliseconds) in `.context/shots/<label>/`, and the run checks from the
samples that the disc never jumps: at the start, at the point, at release.
"""
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
label = sys.argv[1] if len(sys.argv) > 1 else "pull"
reduced = "reduced" in sys.argv[2:]
slow = "slow" in sys.argv[2:]
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

OUT = ROOT / ".context" / "shots" / label
CAPTURE = ROOT / ".context" / "shots" / "capture"
FPS = 120
t = sv.T()

PAGE = """<!doctype html><meta charset=utf-8><title>Field notes</title>
<style>body{margin:0;font:17px/1.55 -apple-system,system-ui;color:#1d1d1f;background:#fbfaf7}
main{max-width:640px;margin:0 auto;padding:56px 24px}h1{font-size:34px;margin:0 0 6px}
p{margin:0 0 18px}.by{color:#86868b;margin-bottom:28px}</style>
<main><h1>Field notes</h1><p class=by>Asked for <span id=n></span> times</p>
""" + "".join(f"<p>{n}. The quick brown fox jumps over the lazy dog, and the page goes on for a long while so there is somewhere to scroll to.</p>" for n in range(1, 80)) + "</main>"
hits = {"n": 0}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        hits["n"] += 1
        if slow and hits["n"] > 1:
            time.sleep(3)
        body = PAGE.replace("<span id=n></span>", f"<span id=n>{hits['n']}</span>").encode()
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://localhost:{srv.server_port}"


def film(pid, number, tab, name, wheel, seconds=2.2):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number), "2", str(FPS)], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None: break
        time.sleep(0.025)
    time.sleep(0.2)
    got = {}
    sampler = threading.Thread(target=lambda: got.update(sv.cmd({"do": "refresh", "id": tab, "sample": int((seconds - 0.4) / 0.008), "every": 0.008})))
    sampler.start()
    time.sleep(0.05)
    sv.cmd({"do": "refresh", "id": tab, "clear": True})
    sv.cmd({"do": "wheel", "id": tab, "dx": 0, "exact": True, **wheel})
    sampler.join()
    print(" ", name, p.communicate()[0].strip(), flush=True)
    state = sv.cmd({"do": "refresh", "id": tab})
    samples = got.get("frames", [])
    (folder / "samples.json").write_text(json.dumps({"samples": samples, "steps": state["steps"], "end": state["end"], "why": state["why"]}))
    return folder, samples, state


def sheet(name, folder, width, span=1.6, columns=10):
    frames = sorted(folder.glob("0*.png"))
    if len(frames) < 4: return
    times = json.loads((folder / "times.json").read_text())
    picked = [i for i in range(len(frames)) if times[i] <= span][::2]
    work = folder / "sheet"
    shutil.rmtree(work, ignore_errors=True); work.mkdir()
    for n, i in enumerate(picked): os.symlink(frames[i], work / f"{n:04d}.png")
    rows = (len(picked) + columns - 1) // columns
    crop = f"crop=360:300:{int(width) - 180}:0"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"{crop},tile={columns}x{rows}:padding=3:color=red", "-frames:v", "1", str(OUT / f"{name}.png")], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")], check=False)
    print("    sheet", (OUT / f"{name}.png").relative_to(ROOT), f"{len(picked)} frames", flush=True)


def steps_of(samples):
    seen = [s for s in samples if s.get("disc")]
    return [(round(s["t"], 3), round(s["top"], 2), round(s["opacity"], 2), round(s["ring"], 2), s["phase"]) for s in seen]


def smooth(name, samples, most):
    """No jump: between two looks 8 ms apart the disc never moves more than
    MOST points, from the first look that has it to the last."""
    seen = [s for s in samples if s.get("disc")]
    jumps = [(round(a["t"], 3), round(a["top"], 1), round(b["top"], 1)) for a, b in zip(seen, seen[1:])
             if abs(b["top"] - a["top"]) > most * max(1, (b["t"] - a["t"]) / 0.008)]
    t.ok(f"{name}: the disc never jumps ({len(seen)} looks, at most {most} pt in 8 ms)", len(seen) > 5 and not jumps, jumps[:6])
    return seen


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if not CAPTURE.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.use("pull-film-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"motion.testReduced": reduced})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1100, "height": 760, "steps": 1})
        tab = sv.sp("open", url=f"{BASE}/notes")["resultID"]; time.sleep(0.7)
        sv.cmd({"do": "select", "id": tab}); sv.cmd({"do": "wait", "id": tab, "seconds": 5}); time.sleep(1)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1)
        frame = sv.frames(sv.sp("state"))[tab]
        middle = (frame["x"] + frame["width"] / 2) * 2

        scenes = [
            ("reload", {"dy": 190, "steps": 60, "ms": 650, "hold": 250}, True),
            ("short", {"dy": 85, "steps": 40, "ms": 450, "hold": 150}, False),
            ("back", {"dy": 170, "steps": 50, "ms": 550, "legs": [[0, -110]], "hold": 120}, False),
            ("deep", {"dy": 420, "steps": 80, "ms": 800, "hold": 200}, True),
        ]
        if slow:
            scenes = [("spin", {"dy": 190, "steps": 60, "ms": 650, "hold": 250}, True)]
        for name, wheel, reloads in scenes:
            was = hits["n"]
            folder, samples, state = film(pid, number, tab, name, wheel, seconds=3.2 if slow else 2.2)
            sheet(name, folder, middle, span=3.0 if slow else 1.6)
            seen = smooth(name, samples, 14)
            print("   ", steps_of(samples)[::6], flush=True)
            t.ok(f"{name}: {'reloads' if reloads else 'no reload'}", (hits["n"] > was) == reloads, (was, hits["n"], state["end"], state["why"]))
            if seen and not reduced:
                t.ok(f"{name}: it starts hidden above the page's top edge", seen[0]["top"] <= -30, seen[0]["top"])
            time.sleep(1.2)

        if not slow:
            sv.ev(tab, "scrollTo(0, 220)"); time.sleep(0.4)
            was = hits["n"]
            folder, samples, state = film(pid, number, tab, "coast", {"dy": 160, "steps": 6, "ms": 80, "glide": 60})
            sheet("coast", folder, middle)
            t.ok("coast: a flick that glides to the top shows no disc and reloads nothing",
                 hits["n"] == was and not [s for s in samples if s.get("disc")] and sv.ev(tab, "scrollY") == 0, (state["why"], sv.ev(tab, "scrollY")))
    finally:
        sv.finish()
        t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

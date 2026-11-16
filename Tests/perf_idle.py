#!/usr/bin/env python3
"""Broadway at rest: what its own process spends while nothing moves.

Build first (`./build.sh`), then `python3 Tests/perf_idle.py [--seconds N]
[--states a,b] [--local]`. A world of its own, started with SEARCH_SHOWN and
SEARCH_MEASURE so the window is drawn on screen and App Nap is left to macOS,
behind whatever app is in front. It holds real pages (a few sites, a pin, a
folder, a split pair) and a local page playing a looping muted video in a tab
that is not on screen.

Each state is measured for N seconds after a settle: CPU time of Broadway's own
process (from ps), its idle wakeups (top's IDLEW, summed), main-thread
wakeups and SwiftUI bodies (bench `idle`). WebKit's processes are left out:
what they spend is the pages', not Broadway's. The front app is given focus back
after the foreground state.

`--json PATH` writes the numbers; `--check` fails if Broadway's process is above
1% CPU or any counted body ran while the window was still.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("perf")

CLIP = Path(tempfile.mkdtemp(prefix="broadway-perf-")) / "clip.mp4"


def make_clip():
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
                    "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100", "-t", "20", "-pix_fmt", "yuv420p",
                    "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", "-shortest", str(CLIP)], check=True)


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/clip.mp4"):
            return self.clip()
        if self.path.startswith("/video"):
            body = b"<!doctype html><title>video</title><body style='margin:0;background:#000'>" \
                   b"<video src='/clip.mp4' autoplay muted loop playsinline style='width:100%'></video>" \
                   b"<button id='loud' style='position:fixed;top:0;left:0;width:240px;height:90px' " \
                   b"onclick=\"const v=document.querySelector('video');v.muted=false;v.play()\">sound</button>"
        else:
            name = self.path.strip("/") or "page"
            body = f"<!doctype html><title>{name}</title><h1>{name}</h1><p>{'words ' * 400}</p>".encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def clip(self):
        data = CLIP.read_bytes()
        start, end = 0, len(data) - 1
        asked = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("range") or "")
        if asked:
            start = int(asked.group(1) or 0)
            end = int(asked.group(2)) if asked.group(2) else end
        part = data[start:end + 1]
        self.send_response(206 if asked else 200)
        self.send_header("content-type", "video/mp4")
        self.send_header("accept-ranges", "bytes")
        self.send_header("content-length", str(len(part)))
        if asked:
            self.send_header("content-range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        try:
            self.wfile.write(part)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


def front_pid():
    out = subprocess.run(["lsappinfo", "info", "-only", "pid", subprocess.run(["lsappinfo", "front"], capture_output=True, text=True).stdout.strip()],
                         capture_output=True, text=True).stdout
    found = re.search(r"pid\s*=\s*(\d+)", out)
    return int(found.group(1)) if found else None


def launch_shown(hidden=False):
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    mode = ["-j"] if hidden else ["--env", "SEARCH_SHOWN=1"]
    subprocess.run(["open", "-n", "-g", *mode, "--env", f"SEARCH_PROBE={sv.W}",
                    "--env", "SEARCH_MEASURE=1", sv.APP], check=True)
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())
    return sv.pids()


def cputime(pid):
    text = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not text:
        return 0.0
    parts = [float(x) for x in text.replace("-", ":").split(":")]
    total = 0.0
    for x in parts:
        total = total * 60 + x
    return total


def idle(action, **f):
    return sv.cmd({"do": "idle", "action": action, **f})


def ours(pid, seconds):
    path = Path(tempfile.mkdtemp(prefix="broadway-sample-")) / "s.txt"
    subprocess.run(["sample", str(pid), str(int(seconds)), "-file", str(path)], capture_output=True)
    frames = {}
    graph = path.read_text(errors="replace").split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
    for line in graph.splitlines():
        found = re.match(r"^[\s+!:|]*(\d+) (.+?)  \(in Broadway\)", line)
        if found and not found.group(2).startswith("main"):
            name = re.sub(r"\s+\+ \d+.*", "", found.group(2))
            frames[name] = max(frames.get(name, 0), int(found.group(1)))
    path.unlink(missing_ok=True)
    return dict(sorted(frames.items(), key=lambda kv: -kv[1])[:8])


def measure(pid, seconds, sampled=False):
    idle("start")
    first = cputime(pid)
    began = time.time()
    top = subprocess.Popen(["top", "-l", str(int(seconds) + 1), "-s", "1", "-stats", "pid,cpu,idlew", "-pid", str(pid)],
                           stdout=subprocess.PIPE, text=True)
    frames = ours(pid, min(10, seconds)) if sampled else None
    out, _ = top.communicate()
    spent = cputime(pid) - first
    wall = time.time() - began
    report = idle("report")
    rows = [line.split() for line in out.splitlines() if line.strip().startswith(str(pid))]
    wakes = [int(r[2]) for r in rows[1:] if len(r) >= 3 and r[2].isdigit()]
    return {
        "cpu": round(100 * spent / wall, 2),
        "idlew_per_s": round(sum(wakes) / max(1, len(wakes)), 1),
        "main_wakeups_per_s": round(report["wakeups"] / report["seconds"], 1),
        "bodies": report["bodies"],
        "active": report["active"], "hidden": report["hidden"], "visible": report["visible"],
        "occluded": report["occluded"], "miniaturized": report["miniaturized"],
        **({"broadway_frames": frames} if sampled else {}),
    }


def world(local):
    base = f"http://127.0.0.1:{srv.server_port}"
    sites = [f"{base}/one", f"{base}/two", f"{base}/three", f"{base}/four"] if local else \
        ["https://en.wikipedia.org/wiki/Swift_(programming_language)", "https://news.ycombinator.com/",
         "https://www.apple.com/macos/", "https://github.com/swiftlang/swift"]
    ids = [sv.sp("open", url=u)["resultID"] for u in sites]
    for i in ids:
        sv.cmd({"do": "wait", "id": i, "seconds": 20})
    video = sv.sp("open", url=f"{base}/video")["resultID"]
    sv.cmd({"do": "wait", "id": video, "seconds": 20})
    pinned = sv.sp("open", url=f"{base}/pinned")["resultID"]
    sv.cmd({"do": "pin", "id": pinned})
    a = sv.sp("open", url=f"{base}/folder-a")["resultID"]
    b = sv.sp("open", url=f"{base}/folder-b")["resultID"]
    sv.sp("group", id=a)
    group = sv.sp("state")
    left = sv.sp("open", url=f"{base}/left")["resultID"]
    right = sv.sp("open", url=f"{base}/right")["resultID"]
    sv.sp("pair", id=right, **{"with": left}, side="right")
    sv.sp("select", id=video)
    time.sleep(1.5)
    sv.cmd({"do": "tap", "id": video, "selector": "#loud"})
    time.sleep(1.5)
    sv.sp("select", id=ids[0])
    time.sleep(1.5)
    playing = sv.ev(video, "(() => { const v = document.querySelector('video'); return !v.paused && !v.muted })()")
    floating = sv.cmd({"do": "float", "action": "chrome"})
    return {"float": floating,"sites": ids, "video": video, "pin": pinned, "folder": [a, b], "pair": [left, right], "playing": playing, "groups": len(group.get("groups", []))}


def signal_wait():
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=float, default=20)
    ap.add_argument("--settle", type=float, default=6)
    ap.add_argument("--states", default="background,foreground,hidden,minimised,newtab,still")
    ap.add_argument("--local", action="store_true")
    ap.add_argument("--hidden", action="store_true", help="measure without showing or activating windows")
    ap.add_argument("--json")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--sample", action="store_true")
    ap.add_argument("--finish", action="store_true")
    ap.add_argument("--fast-screen", action="store_true", help="move the window onto the screen with the highest refresh rate")
    ap.add_argument("--app", help="another build of Broadway.app to measure")
    a = ap.parse_args()
    if a.app:
        sv.APP = a.app
    if a.finish:
        sv.started.update(sv.holding() & sv.running())
        return sv.finish()
    states = [s for s in a.states.split(",") if s and (not a.hidden or s in ("hidden", "newtab", "still"))]
    make_clip()
    giver = None if a.hidden else front_pid()
    results = {}
    try:
        sv.setup(sidebar=True)
        pids = launch_shown(hidden=a.hidden)
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        pid = int(pids[0])
        if a.fast_screen:
            print("placed:", json.dumps(idle("place")), flush=True)
        made = world(a.local)
        print("world:", json.dumps(made), flush=True)
        for state in states:
            if state == "foreground":
                idle("front")
            elif state == "hidden":
                idle("hide")
            elif state == "minimised":
                idle("unhide")
                time.sleep(1)
                idle("mini")
            elif state == "newtab":
                if not a.hidden:
                    idle("unmini")
                    time.sleep(1)
                sv.cmd({"do": "press", "code": 17, "chars": "t", "mods": ["cmd"]})
            elif state == "video":
                sv.sp("select", id=made["video"])
                sv.ev(made["video"], "document.querySelector('video').play(); true")
            elif state == "glass":
                sv.sp("select", id=made["sites"][1])
                sv.cmd({"do": "space", "action": "look", "glass": True, "transparency": 0.6})
            elif state == "still":
                sv.cmd({"do": "space", "action": "look", "glass": False, "transparency": 0.0})
                sv.ev(made["video"], "document.querySelector('video').pause(); true")
                sv.sp("select", id=made["sites"][1])
            if state != "foreground" and giver:
                idle("give", pid=giver)
            time.sleep(a.settle)
            results[state] = measure(pid, a.seconds, a.sample)
            print(f"{state:11} {json.dumps(results[state])}", flush=True)
            if state == "foreground" and giver:
                idle("give", pid=giver)
    finally:
        if giver:
            try:
                idle("give", pid=giver)
            except Exception:
                pass
        if a.keep:
            print("kept:", sv.pids(), f"http://127.0.0.1:{srv.server_port}")
            signal_wait()
        sv.finish()
        CLIP.unlink(missing_ok=True)
    if a.json:
        Path(a.json).write_text(json.dumps(results, indent=2))
    if a.check:
        bad = [s for s, r in results.items() if r["cpu"] > 1 or sum(r["bodies"].values()) > 0]
        if bad:
            sys.exit(f"busy at rest: {bad}")


srv = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=srv.serve_forever, daemon=True).start()

if __name__ == "__main__":
    main()

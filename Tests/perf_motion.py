#!/usr/bin/env python3
"""Broadway in motion: frames the main thread missed while things move.

Build first (`./build.sh`), then `python3 Tests/perf_motion.py [--runs N]
[--only a,b] [--local]`. The same world as perf_idle.py, drawn on screen
behind the app in front. Each motion is driven through the bench while a
display link on the window logs its frames (bench `idle frames` / `gaps`):
a frame later than 1.5 periods is a hitch. This sees the main thread only;
what the render server does with the frames it gets is not measured here.
"""
import argparse
import json
import statistics
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_idle as pi  # noqa: E402

sv = pi.sv


def c(**r):
    return sv.cmd(r)


def press(code, chars, *mods):
    return c(do="press", code=code, chars=chars, mods=list(mods))


def ui(**f):
    return c(do="ui", **f)


def motions(made):
    sites = made["sites"]
    flip = {"n": 0}

    def tab():
        flip["n"] += 1
        sv.sp("select", id=sites[1 + flip["n"] % 2])

    def space_go():
        c(do="space", action="goto", index=2)
        time.sleep(0.9)
        c(do="space", action="goto", index=1)

    def swipe():
        c(do="space", action="trackpad", stops=[-420], speed=900)
        time.sleep(1.2)
        c(do="space", action="goto", index=1)

    def new_tab():
        press(17, "t", "cmd")
        time.sleep(1.0)
        press(53, "\u001b")

    def reload():
        press(15, "r", "cmd")

    def plus():
        ui(plus=True)
        time.sleep(0.6)
        ui(plus=False)

    def find():
        ui(finding=True)
        time.sleep(0.6)
        ui(finding=False)

    def link():
        ui(link="https://example.com/a/long/path")
        time.sleep(0.6)
        ui(link="off")

    def toast():
        ui(announce="Copied")

    def downloads():
        ui(downloadsbutton=True, recentdownloads=True)
        time.sleep(0.6)
        ui(recentdownloads=False)

    def float_video():
        c(do="float", action="toggle")
        time.sleep(1.2)
        c(do="float", action="toggle")

    def settings():
        ui(settings=True)
        time.sleep(0.8)
        ui(settingsPage="general")
        time.sleep(0.5)
        ui(settingsDetail="routes")
        time.sleep(0.7)
        ui(settingsDetail="back")
        time.sleep(0.5)
        ui(settings=False)

    return {"tab": tab, "space": space_go, "swipe": swipe, "newtab": new_tab, "reload": reload, "plus": plus,
            "find": find, "link": link, "toast": toast, "downloads": downloads, "float": float_video, "settings": settings}


def run(action, settle):
    c(do="idle", action="frames")
    action()
    time.sleep(settle)
    return c(do="idle", action="gaps")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--only", default="")
    ap.add_argument("--local", action="store_true")
    ap.add_argument("--hidden", action="store_true", help="measure main-thread spans without showing windows")
    ap.add_argument("--json")
    ap.add_argument("--loop", help="repeat one motion for --seconds while `sample` records Broadway → the sample's path")
    ap.add_argument("--seconds", type=int, default=10)
    ap.add_argument("--bodies", action="store_true", help="the bodies one run of each motion re-evaluates")
    a = ap.parse_args()
    pi.make_clip()
    giver = None if a.hidden else pi.front_pid()
    results = {}
    try:
        sv.setup(sidebar=True, spaces=True)
        pids = pi.launch_shown(hidden=a.hidden)
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        made = pi.world(a.local)
        c(do="space", action="new", name="Two")
        c(do="space", action="go", index=2)
        sv.sp("open", url=f"http://127.0.0.1:{pi.srv.server_port}/two-a")
        c(do="space", action="go", index=1)
        if giver:
            c(do="idle", action="give", pid=giver)
        time.sleep(2)
        table = motions(made)
        if a.loop:
            import subprocess
            import tempfile
            out = Path(tempfile.mkdtemp(prefix="broadway-motion-")) / f"{a.loop}.sample"
            taker = subprocess.Popen(["sample", str(pids[0]), str(a.seconds), "-file", str(out)],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            until = time.time() + a.seconds
            while time.time() < until:
                table[a.loop]()
                time.sleep(0.5)
            taker.wait()
            print("sample:", out)
            return
        for name, action in table.items():
            if a.only and name not in a.only.split(","):
                continue
            if a.bodies:
                c(do="idle", action="start")
                action()
                time.sleep(1.0)
                got = c(do="idle", action="report")["bodies"]
                print(f"{name:10} {sum(got.values()):5} {json.dumps(dict(sorted(got.items(), key=lambda kv: -kv[1])))}", flush=True)
                continue
            runs = [run(action, 1.0) for _ in range(a.runs)]
            results[name] = {
                "longestMs": max(r["longestMs"] for r in runs),
                "longSpans": [r["longSpans"] for r in runs],
                "busyMs": statistics.median(r["busyMs"] for r in runs),
                "longMs": [r["longMs"] for r in runs],
                "hz": runs[0]["hz"],
                "hitches": [r["hitches"] for r in runs],
                "worstMs": max(r["worstMs"] for r in runs),
                "hitchMsPerS": statistics.median(r["hitchMsPerS"] for r in runs),
                "gapsMs": [r["gapsMs"] for r in runs],
            }
            print(f"{name:10} {json.dumps(results[name])}", flush=True)
    finally:
        if giver:
            try:
                c(do="idle", action="give", pid=giver)
            except Exception:
                pass
        sv.finish()
        pi.CLIP.unlink(missing_ok=True)
    if a.json:
        Path(a.json).write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()

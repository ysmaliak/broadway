#!/usr/bin/env python3
"""The folded column's peek, filmed and timed, with a big column.

Build first (`./build.sh`), then `python3 Tests/peek_slide.py --out DIR
[--runs N] [--side left,right] [--look dark] [--policy normal] [--plain]
[--fast-screen] [--fps 120] [--no-link] [--app PATH]`. A world of
its own (perf_idle's, local pages only, drawn behind the app in front with
SEARCH_SHOWN): eight pins, a loose tab, a folder of fifteen tabs open and a
few tabs under it, in a glass space, with the column folded for good
(Settings' Keep the sidebar folded), so the edge's dwell is what brings it
out. Each run calls the peek the way the dwell does (`ui peek`) and films the
column's side of the test copy's window only (Tests/motion_film.swift) while
the bench logs the main thread.

The real pointer is left out (bench `pointerless`): the edge is watched
everywhere, so a person's own pointer moving would put the column back.

Two measures. The bench's `peektrace` calls the peek and reads, on every
display frame, where the column's scroll view is: the time to the first
frame it moved, frames missed while it moved, and when it settled. The
films (time to the first captured frame that changed, gaps between captured
frames, the main thread's longest span) are the pictures, and noisier: they
go through the window server and the capture.
"""
import argparse
import json
import select
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_audit as ma  # noqa: E402

pi = ma.pi
sv = ma.sv


def c(**r):
    return sv.cmd(r)


def state():
    return c(do="probe")


def column_world():
    base = f"http://127.0.0.1:{pi.srv.server_port}"
    pins = []
    for n in range(8):
        tab = sv.sp("open", url=f"{base}/pin-{n}")["resultID"]
        c(do="pin", id=tab)
        pins.append(tab)
    loose = sv.sp("open", url=f"{base}/loose")["resultID"]
    folder = [sv.sp("open", url=f"{base}/member-{n}")["resultID"] for n in range(15)]
    sv.sp("group", id=folder[0])
    groups = sv.sp("state").get("groups", [])
    group = next((g["id"] for g in groups), None)
    for tab in folder[1:]:
        sv.sp("group", id=tab, group=group)
    after = [sv.sp("open", url=f"{base}/after-{n}")["resultID"] for n in range(3)]
    sv.sp("select", id=folder[-2])
    time.sleep(2)
    return {"pins": pins, "loose": loose, "folder": folder, "group": group, "after": after,
            "groups": len(sv.sp("state").get("groups", []))}


FILM = {"fps": 60, "link": True}


def film(pid, name, out, seconds, act, crop):
    args = [str(ma.FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(out / name), "--scale", "1",
            "--crop", ",".join(str(round(x)) for x in crop), "--columns", "6", "--most", "18", "--fps", str(FILM["fps"])]
    taker = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    ready, _, _ = select.select([taker.stdout], [], [], 10)
    line = taker.stdout.readline() if ready else ""
    if not line.startswith("ready"):
        taker.kill()
        taker.wait()
        raise RuntimeError(f"{name}: film did not start: {line}")
    c(do="idle", action="start")
    if FILM["link"]:
        c(do="idle", action="frames")
    time.sleep(0.1)
    called = time.monotonic()
    act()
    time.sleep(max(0.2, seconds - 0.55))
    gaps = c(do="idle", action="gaps") if FILM["link"] else {}
    bodies = c(do="idle", action="report").get("bodies", {})
    try:
        taker.wait(timeout=seconds + 10)
    except subprocess.TimeoutExpired:
        taker.kill()
        raise RuntimeError(f"{name}: film did not finish")
    shot = json.loads((out / f"{name}.json").read_text())
    shot["calledHost"] = called
    shot["firstMs"] = round((shot["firstHost"] - called) * 1000) if shot.get("firstHost") else None
    shot["main"] = {k: gaps.get(k) for k in ("busyMs", "longestMs", "longSpans", "longMs", "hitches", "worstMs", "hz", "gapsMs")}
    shot["bodies"] = dict(sorted(bodies.items(), key=lambda kv: -kv[1]))
    (out / f"{name}.json").write_text(json.dumps(shot, indent=1))
    return shot


def trace_summary(runs):
    ok = [r for r in runs if r.get("firstMoveMs") is not None]
    if not ok:
        return {"runs": 0}
    pick = lambda k: [r.get(k) for r in ok]
    return {
        "runs": len(ok),
        "hz": ok[0].get("hz"),
        "firstMoveMs": pick("firstMoveMs"),
        "firstMoveMedian": statistics.median(pick("firstMoveMs")),
        "settleMedian": statistics.median(pick("settleMs")),
        "missedFrames": pick("missedFrames"),
        "missedTotal": sum(pick("missedFrames")),
        "worstGapMs": max(pick("worstGapMs")),
    }


def summarise(shots):
    gaps = [g for s in shots for g in s.get("motionGaps", [])[1:]]
    return {
        "runs": len(shots),
        "firstMs": [s.get("firstMs") for s in shots],
        "firstMsMedian": statistics.median([s.get("firstMs") or 0 for s in shots]),
        "motionMs": [s.get("motionMs") for s in shots],
        "motionMsMedian": statistics.median([s.get("motionMs") or 0 for s in shots]),
        "framesMoving": [s.get("changing") for s in shots],
        "gapsOver20": sum(1 for g in gaps if g > 20),
        "worstMotionGapMs": max(gaps or [0]),
        "mainLongestMs": [s["main"].get("longestMs") for s in shots],
        "mainLongestMedian": statistics.median([s["main"].get("longestMs") or 0 for s in shots]),
        "displayHitches": [s["main"].get("hitches") for s in shots],
        "hz": shots[0]["main"].get("hz") if shots else None,
        "bodies": shots[-1].get("bodies") if shots else {},
    }


def run_side(side, out, runs, look, policy, tag, glass=True, place=False):
    prefs = {"sidebar": True, "tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
             "tabs.cards": False, "start.fresh": False, "split": False, "spaces": True}
    if policy == "reduced":
        prefs["motion.testReduced"] = True
    sv.setup(**prefs)
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", look], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "252"], check=True)
    pids = pi.launch_shown()
    if len(pids) != 1:
        sys.exit(f"expected one probe, got {pids}")
    pid = pids[0]
    result = {"side": side, "look": look, "policy": policy}
    try:
        made = column_world()
        result["world"] = {"pins": len(made["pins"]), "folder": len(made["folder"]), "groups": made["groups"]}
        if place:
            result["placed"] = c(do="idle", action="place")
            print(side, "placed", json.dumps(result["placed"]), flush=True)
        c(do="space", action="look", glass=glass, colour="sky")
        if side == "right":
            c(do="ui", side="right")
        giver = pi.front_pid()
        if giver and giver != pid:
            c(do="idle", action="give", pid=giver)
        c(do="ui", folded=True, pointerless=True)
        time.sleep(1.5)
        traces = {"in": [], "out": []}
        for n in range(runs * 2):
            time.sleep(0.4)
            traces["in"].append(c(do="ui", peektrace={"out": True, "seconds": 0.6}))
            time.sleep(0.4)
            traces["out"].append(c(do="ui", peektrace={"out": False, "seconds": 0.6}))
        result["trace"] = {k: trace_summary(v) for k, v in traces.items()}
        (out / f"{tag}-{side}-traces.json").write_text(json.dumps(traces, indent=1))
        print(side, "trace", json.dumps(result["trace"]), flush=True)
        probe = state()
        result["folded"] = probe.get("folded")
        size = ma.film(pid, f"{tag}-{side}-window", out, 0.4, lambda: None).get("window", ma.SIZE)
        width, height = size
        crop = (0, 0, 330, height) if side == "left" else (width - 330, 0, 330, height)
        ins, outs, retried = [], [], 0
        n = 0
        while n < runs and retried < runs * 3:
            try:
                shot = film(pid, f"{tag}-{side}-in-{n}", out, 1.0, lambda: c(do="ui", peek=True), crop)
            except RuntimeError as error:
                print(error, flush=True)
                retried += 1
                c(do="ui", peek=False)
                time.sleep(1)
                continue
            if not state().get("peeking"):
                retried += 1
                time.sleep(0.6)
                continue
            time.sleep(0.3)
            try:
                back = film(pid, f"{tag}-{side}-out-{n}", out, 0.9, lambda: c(do="ui", peek=False), crop)
            except RuntimeError as error:
                print(error, flush=True)
                retried += 1
                c(do="ui", peek=False)
                time.sleep(1)
                continue
            ins.append(shot)
            outs.append(back)
            n += 1
            time.sleep(0.6)
        result["retried"] = retried
        result["in"] = summarise(ins)
        result["out"] = summarise(outs)
        c(do="ui", peek=True)
        time.sleep(0.1)
        c(do="ui", peek=False)
        time.sleep(0.04)
        c(do="ui", peek=True)
        time.sleep(0.8)
        turned = state()
        result["turnedBack"] = {"peeking": turned.get("peeking"), "folded": turned.get("folded")}
        print(side, json.dumps({k: result[k] for k in ("in", "out")}, indent=1), flush=True)
    finally:
        sv.finish()
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--side", default="left")
    ap.add_argument("--look", default="dark")
    ap.add_argument("--policy", default="normal")
    ap.add_argument("--tag", default="peek")
    ap.add_argument("--app")
    ap.add_argument("--plain", action="store_true", help="the sky colour without glass, so the window is opaque")
    ap.add_argument("--fast-screen", action="store_true", help="move the window onto the fastest screen first")
    ap.add_argument("--fps", type=int, default=60, help="the film's frame rate; 120 on a 120 Hz screen")
    ap.add_argument("--no-link", action="store_true", help="film without the bench's display link on the window")
    a = ap.parse_args()
    FILM["fps"] = a.fps
    FILM["link"] = not a.no_link
    if a.app:
        sv.APP = a.app
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    ma.build_film()
    summary = {}
    for side in a.side.split(","):
        summary[side] = run_side(side, out, a.runs, a.look, a.policy, a.tag, glass=not a.plain, place=a.fast_screen)
    (out / f"{a.tag}-summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))
    t = sv.T()
    for side, s in summary.items():
        t.ok(f"{side}: every peek filmed", s["in"]["runs"] == a.runs, str(s["in"]["runs"]))
        t.ok(f"{side}: a peek turned back mid-slide comes out again", bool(s["turnedBack"]["peeking"]), str(s["turnedBack"]))
        t.ok(f"{side}: the bench traced the column moving", bool(s["trace"]["in"].get("runs")), str(s["trace"]))
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

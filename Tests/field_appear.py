#!/usr/bin/env python3
"""The floating field's appear and close, filmed and timed, and its first keys.

Build first (`./build.sh`), then `python3 Tests/field_appear.py --out DIR
[--runs N] [--modes normal]`. A world of its own (perf_idle's, local
pages only, drawn behind the app in front with SEARCH_SHOWN), with New tabs
show: Floating field. The field is opened with ⌘T over a playing video and
over a still page, with a full resting list (recent tabs, frequent, quick
actions). Each open and close is filmed with Tests/motion_film.swift (the test
copy's windows only) while the bench logs the main thread. Then ⌘T and three
letters are posted together, so the letters reach the app before the field's
first frame, and the field must hold all three.
"""
import argparse
import json
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_audit as ma  # noqa: E402

pi = ma.pi
sv = ma.sv

film_once = ma.film


def film_retry(*args, **kwargs):
    try:
        return film_once(*args, **kwargs)
    except RuntimeError:
        time.sleep(1.5)
        return film_once(*args, **kwargs)


ma.film = film_retry


def press(code, chars, *mods, **extra):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods), **extra})


def rows():
    return sv.cmd({"do": "fieldrows", "args": ["state"]})


def panel(w, h):
    return (w / 2 - 370, h * 0.177 - 24, 740, 560)


REGIONS = "glass:0.64,0.065,0.25,0.06;glass2:0.17,0.81,0.40,0.03;text:0.12,0.20,0.30,0.20"


def plain_pages():
    plain = pi.Pages.do_GET

    def do_get(self):
        if not self.path.startswith("/plain"):
            return plain(self)
        body = b"<!doctype html><title>plain</title><body style='margin:0;background:#fff'></body>"
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.end_headers()
        self.wfile.write(body)

    pi.Pages.do_GET = do_get


def film_regions(pid, name, out, seconds, act):
    try:
        return film_regions_once(pid, name, out, seconds, act)
    except RuntimeError:
        time.sleep(1)
        return film_regions_once(pid, name, out, seconds, act)


def film_regions_once(pid, name, out, seconds, act):
    w, h = ma.SIZE
    crop = ",".join(str(round(x)) for x in panel(w, h))
    args = [str(ma.FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(out / name), "--scale", "1",
            "--crop", crop, "--columns", "4", "--regions", REGIONS]
    taker = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: film did not start: {line}")
    act()
    taker.wait()
    return json.loads((out / f"{name}.json").read_text())


def visibility(shot, opening):
    regions = shot.get("regions", {})
    if not regions:
        return None
    def series(key, use):
        rows = regions[key]
        times = [r[0] for r in rows]
        values = [use(r) for r in rows]
        closed, shown = (values[0], values[-1]) if opening else (values[-1], values[0])
        span = abs(shown - closed) or 1
        return times, [max(0.0, min(1.0, abs(v - closed) / span)) for v in values]
    colour = lambda r: (r[3] ** 2 + r[4] ** 2 + r[5] ** 2) ** 0.5
    times, glass = series("glass", colour)
    _, glass2 = series("glass2", colour)
    _, text = series("text", lambda r: r[2])
    plate = [(a + b) / 2 for a, b in zip(glass, glass2)]
    def first(values, above):
        return next((i for i, v in enumerate(values) if v > above), None)
    def last(values, above):
        return max((i for i, v in enumerate(values) if v > above), default=None)
    if opening:
        starts = (first(plate, 0.05), first(text, 0.05))
        ends = (first(plate, 0.95), first(text, 0.95))
    else:
        starts = (first([1 - v for v in plate], 0.05), first([1 - v for v in text], 0.05))
        ends = (last(plate, 0.05), last(text, 0.05))
    lonely = [round(times[i]) for i in range(len(times)) if (plate[i] > 0.3 and text[i] < 0.05) or (text[i] > 0.3 and plate[i] < 0.05)]
    together = None not in starts and None not in ends and abs(starts[0] - starts[1]) <= 1 and abs(ends[0] - ends[1]) <= 1 and not lonely
    span = [round(times[i]) if i is not None else None for i in ends]
    return {"together": together, "startFrames": starts, "endFrames": ends, "endMs": span, "lonelyMs": lonely,
            "plate": [round(v, 2) for v in plate], "text": [round(v, 2) for v in text], "t": [round(t) for t in times]}


def stalled_across(v):
    if not v or None in v["startFrames"] or None in v["endFrames"]:
        return False
    t = v["t"]
    lo = max(0, min(v["startFrames"]) - 1)
    hi = max(v["endFrames"])
    return any(t[i + 1] - t[i] > 60 for i in range(lo, min(hi, len(t) - 1)))


def summarise(shots):
    ok = [s for s in shots if "error" not in s]
    if not ok:
        return {"error": [s.get("error") for s in shots]}
    gaps = [g for s in ok for g in s.get("motionGaps", [])]
    return {
        "runs": len(ok),
        "motionMs": [s.get("motionMs") for s in ok],
        "motionMsMedian": statistics.median([s.get("motionMs") or 0 for s in ok]),
        "worstGapMs": max(s.get("worstGapMs") or 0 for s in ok),
        "longGaps": sum(s.get("longGaps") or 0 for s in ok),
        "motionGapsOver20": sum(1 for g in gaps if g > 20),
        "mainLongestMs": [s["main"].get("longestMs") for s in ok],
        "mainHitches": sum(s["main"].get("hitches") or 0 for s in ok),
        "mainWorstMs": max(s["main"].get("worstMs") or 0 for s in ok),
    }


def run_mode(mode, out, runs, tints=False):
    prefs = {"sidebar": True, "newtab.floating": True}
    sv.setup(**prefs)
    pids = pi.launch_shown()
    if len(pids) != 1:
        sys.exit(f"expected one probe, got {pids}")
    pid = pids[0]
    result = {}
    try:
        made = pi.world(True)
        sv.cmd({"do": "ui", "glassBars": []})
        giver = pi.front_pid()
        if giver:
            sv.cmd({"do": "idle", "action": "give", "pid": giver})
        time.sleep(1.5)
        ma.SIZE[:] = ma.film(pid, f"{mode}-window", out, 0.4, lambda: None).get("window", ma.SIZE)
        for ground, tab in (("video", made["video"]), ("still", made["sites"][0])):
            sv.sp("select", id=tab)
            time.sleep(1.2)
            opens, closes = [], []
            for n in range(runs):
                opens.append(ma.film(pid, f"{mode}-{ground}-open-{n}", out, 1.0, lambda: press(17, "t", "cmd"), panel))
                time.sleep(0.5)
                closes.append(ma.film(pid, f"{mode}-{ground}-close-{n}", out, 0.8, lambda: press(53, "\u001b"), panel))
                time.sleep(0.5)
            result[f"{ground}-open"] = summarise(opens)
            result[f"{ground}-close"] = summarise(closes)
            print(mode, ground, json.dumps({k: result[k] for k in (f"{ground}-open", f"{ground}-close")}), flush=True)
        sv.sp("select", id=made["video"])
        time.sleep(1)
        sv.cmd({"do": "idle", "action": "start"})
        press(17, "t", "cmd")
        time.sleep(0.5)
        bodies = sv.cmd({"do": "idle", "action": "report"}).get("bodies", {})
        result["openBodies"] = dict(sorted(bodies.items(), key=lambda kv: -kv[1]))
        state = rows()
        result["restingRows"] = len(state.get("rows", []))
        result["sections"] = [s["title"] for s in state.get("sections", [])]
        result["timing"] = {k: state.get(k) for k in ("focusedMs", "drawnMs")}
        result["movedAfterFirstFrame"] = state.get("movedAfterDrawn")
        result["laidOutBeforeFirstFrame"] = state.get("drawnMs", -1) >= 0 and not state.get("movedAfterDrawn")
        panels = {"open": state.get("layout", {}).get("field.panel")}
        bars = {"open": state.get("layout", {}).get("field.bar")}
        counts = {}
        for query in ("o", "zzqxqv", "one", "127", ""):
            after = sv.cmd({"do": "fieldrows", "args": ["type", query] if query else ["type"]})
            time.sleep(0.3)
            seen = rows()
            panels[query or "cleared"] = seen.get("layout", {}).get("field.panel")
            bars[query or "cleared"] = seen.get("layout", {}).get("field.bar")
            counts[query or "cleared"] = len(seen.get("rows", []))
        press(53, "\u001b")
        time.sleep(0.6)
        closed = rows().get("layout", {})
        panels["closed"] = closed.get("field.panel")
        bars["closed"] = closed.get("field.bar")
        result["panelFrames"] = panels
        result["rowCounts"] = counts
        result["panelConstant"] = panels["open"] is not None and all(v == panels["open"] for v in panels.values()) \
            and all(v == bars["open"] for v in bars.values())
        still = [statistics.median([m for m in result[k].get("motionMs", []) if m] or [0]) for k in ("still-open", "still-close")]
        result["fadeMs"] = still
        result["opensWhole"] = still[0] == 0
        result["fadeOutAbout200"] = 120 <= still[1] <= 260 if mode == "normal" else True
        sv.sp("select", id=made["sites"][0])
        sv.cmd({"do": "ui", "go": f"http://127.0.0.1:{pi.srv.server_port}/plain"})
        time.sleep(1.2)
        steps = []
        stalls = []
        for n in range(runs):
            for attempt in range(3):
                sv.sp("select", id=made["sites"][0])
                time.sleep(1.0)
                opened = film_regions(pid, f"{mode}-plain-open-{n}", out, 0.9, lambda: press(17, "t", "cmd"))
                time.sleep(0.4)
                closed = film_regions(pid, f"{mode}-plain-close-{n}", out, 0.9, lambda: press(53, "\u001b"))
                time.sleep(0.4)
                step = {"open": visibility(opened, True), "close": visibility(closed, False)}
                stalled = [k for k, v in step.items() if stalled_across(v)]
                if not stalled:
                    break
                stalls.append({"run": n, "attempt": attempt, "stalled": stalled})
            steps.append(step)
        result["oneStepStalls"] = stalls
        result["oneStep"] = [{k: {x: v[x] for x in ("together", "startFrames", "endFrames", "endMs", "lonelyMs")} if v else None
                              for k, v in run.items()} for run in steps]
        result["oneStepCurves"] = steps
        result["oneStepOk"] = all(v and v["together"] for run in steps for v in run.values())
        if tints:
            sv.sp("select", id=made["video"])
            time.sleep(1)
            shots = []
            for look in ("light", "dark"):
                sv.cmd({"do": "ui", "look": look})
                for colour in ("sky", "coral"):
                    sv.cmd({"do": "space", "action": "look", "colour": colour})
                    time.sleep(0.6)
                    name = f"{mode}-tint-{look}-{colour}"
                    ma.film(pid, name, out, 0.9, lambda: press(17, "t", "cmd"), panel)
                    shots.append(f"{name}-last.png")
                    press(53, "\u001b")
                    time.sleep(0.6)
            sv.cmd({"do": "ui", "look": "system"})
            result["tintShots"] = shots
        typed = []
        for n in range(5):
            press(17, "t", "cmd", type="abc")
            time.sleep(0.3)
            state = rows()
            typed.append(state.get("typed"))
            result.setdefault("timings", []).append({k: state.get(k) for k in ("focusedMs", "drawnMs")})
            press(53, "\u001b")
            time.sleep(0.3)
            press(53, "\u001b")
            time.sleep(0.5)
        result["firstKeys"] = typed
        result["firstKeysKept"] = all(t == "abc" for t in typed)
        print(mode, "first keys", typed, flush=True)
    finally:
        sv.finish()
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--runs", type=int, default=4)
    ap.add_argument("--modes", default="normal")
    ap.add_argument("--tints", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    ma.build_film()
    pi.make_clip()
    plain_pages()
    summary = {}
    try:
        for mode in a.modes.split(","):
            summary[mode] = run_mode(mode, out, a.runs, tints=a.tints and mode == "normal")
    finally:
        pi.CLIP.unlink(missing_ok=True)
        (out / "summary.json").write_text(json.dumps(summary, indent=1))
    print(json.dumps(summary, indent=1))
    checks = ("firstKeysKept", "laidOutBeforeFirstFrame", "panelConstant", "opensWhole", "fadeOutAbout200", "oneStepOk")
    bad = [m for m, r in summary.items() if not all(r.get(k) for k in checks)]
    for m, r in summary.items():
        print(m, {k: r.get(k) for k in checks})
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()

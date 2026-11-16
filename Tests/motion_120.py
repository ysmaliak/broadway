#!/usr/bin/env python3
"""Every motion on the 120 Hz screen: frames delivered, hitches, first frame.

Build first (`./build.sh`), then `python3 Tests/motion_120.py --out DIR
[--only a,b] [--runs N] [--list]`. perf_idle's world with local pages, a
second space and a folder, shown behind the app in front (SEARCH_SHOWN). The
test copy's window is moved onto the screen with the highest refresh rate
(bench `idle place`); the run stops if that screen isn't 120 Hz.

Each motion is filmed with Tests/motion_film.swift at 120 fps, the test
copy's own windows only. ScreenCaptureKit hands over a frame only when the
window's picture changed, so the frames from the first change to the last
are the frames the motion delivered. Beside the film the bench's display link
logs hitches (a frame later than 1.5 periods) and the run loop's longest
span, and ps gives the CPU time Broadway and WindowServer spent in the window.

For each motion: deliveredFps (frames delivered over the motion's length),
expected (frames a 120 Hz motion of that length has), slowFrames (gaps in the
delivered frames over 1.5 periods), hitches and longestMs (main thread),
firstMs (from the bench call to the first changed frame), motionMs, and the
CPU milliseconds per second of Broadway and WindowServer. DIR gets each film's
contact sheet and a summary.json.
"""
import argparse
import json
import os
import select
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import motion_audit as ma  # noqa: E402
import perf_idle as pi  # noqa: E402

sv = pi.sv
c = ma.c
ui = ma.ui
press = ma.press


REFERENCE = Path(ma.FILM).with_name(f"broadway-motion-reference-{sv.W}")


def reference(out, fps):
    source = Path(__file__).resolve().parent / "motion_reference.swift"
    if not REFERENCE.exists() or REFERENCE.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", str(source), "-o", str(REFERENCE)], check=True)
    rows = {}
    for mode in ("ca", "swiftui"):
        got = []
        for run in range(3):
            shown = subprocess.Popen([str(REFERENCE), mode, "--wait"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            shown.stdout.readline()
            name = f"reference-{mode}-{run}"
            taker = subprocess.Popen([str(ma.FILM), "--pid", str(shown.pid), "--seconds", "1.8", "--out", str(out / name),
                                      "--scale", "0.5", "--fps", str(fps)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            ready, _, _ = select.select([taker.stdout], [], [], 10)
            if ready:
                taker.stdout.readline()
            time.sleep(0.2)
            shown.stdin.write("go\n")
            shown.stdin.flush()
            taker.wait()
            shown.wait()
            try:
                shot = json.loads((out / f"{name}.json").read_text())
                got.append((shot["deliveredFps"], shot["motionMs"]))
            except (OSError, ValueError, KeyError):
                pass
        rows[mode] = {"deliveredFps": [g[0] for g in got], "motionMs": [g[1] for g in got]}
    return rows


def window_server():
    out = subprocess.run(["pgrep", "-x", "WindowServer"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def film(pid, name, out, seconds, act, crop, fps):
    scale = 0.5 if crop is None else 1 if callable(crop) else 0.5
    args = [str(ma.FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(out / name),
            "--scale", str(scale), "--fps", str(fps)]
    if crop == ma.SETTINGS:
        args += ["--center", "940,860", "--columns", "4"]
    elif callable(crop):
        args += ["--crop", ",".join(str(round(x)) for x in crop(*ma.SIZE)), "--columns", "4"]
    for attempt in range(3):
        taker = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = taker.stdout.readline()
        if line.startswith("ready"):
            break
        taker.wait()
        time.sleep(0.5)
    else:
        raise RuntimeError(f"{name}: film did not start: {line} {taker.stderr.read()}")
    ws = window_server()
    c(do="idle", action="frames")
    cpu0 = pi.cputime(pid), pi.cputime(ws) if ws else 0, time.time()
    load = os.getloadavg()[0]
    sent = time.monotonic()
    act()
    time.sleep(max(0.2, seconds - 0.6))
    cpu1 = pi.cputime(pid), pi.cputime(ws) if ws else 0, time.time()
    gaps = c(do="idle", action="gaps")
    taker.wait()
    try:
        shot = json.loads((out / f"{name}.json").read_text())
    except (OSError, ValueError):
        return {"error": taker.stderr.read()}
    wall = cpu1[2] - cpu0[2]
    period = 1000 / fps
    times = shot.get("times") or []
    lead = 2 if len(times) > 4 else 0
    inner = times[lead:len(times) - lead] if lead else times
    steps = [b - a for a, b in zip(inner, inner[1:])]
    motion = shot.get("motionMs") or 0
    return {
        "screenHz": gaps.get("screenHz"),
        "load": round(load, 1),
        "tickHz": gaps.get("tickHz"),
        "linkHz": gaps.get("hz"),
        "delivered": shot.get("delivered"),
        "expected": round(motion / period) + 1 if motion else 0,
        "deliveredFps": shot.get("deliveredFps"),
        "slowFrames": len([s for s in steps if s > 1.5 * period]),
        "slowestMs": round(max(steps), 1) if steps else 0,
        "motionMs": motion,
        "firstMs": round((shot["firstHost"] - sent) * 1000) if shot.get("firstHost") else None,
        "hitches": gaps.get("hitches"),
        "worstMs": gaps.get("worstMs"),
        "longestMs": gaps.get("longestMs"),
        "busyMs": gaps.get("busyMs"),
        "broadwayCpuMsPerS": round((cpu1[0] - cpu0[0]) * 1000 / wall),
        "systemWsCpuMsPerS": round((cpu1[1] - cpu0[1]) * 1000 / wall) if ws else None,
        "biggestShare": shot.get("biggestShare"),
    }


def motions(made):
    sites = made["sites"]
    base = f"http://127.0.0.1:{pi.srv.server_port}"
    group = made["group"]
    flip = {"n": 0}

    def tab():
        flip["n"] += 1
        sv.sp("select", id=sites[1 + flip["n"] % 2])

    side = lambda w, h: (0, 0, 300, h)
    find = lambda w, h: (w - 540, 0, 540, 110)
    foot = lambda w, h: (0, h - 430, 560, 430)
    link = lambda w, h: (0, h - 110, w, 110)
    toast = lambda w, h: (w * 0.2, h - 170, w * 0.6, 170)
    top = lambda w, h: (0, 0, w, 64)
    whole = None
    return [
        ("tab-switch", tab, 1.2, side),
        ("tab-open", lambda: ui(show=f"{base}/opened?{time.time()}"), 1.4, whole),
        ("tab-close", lambda: press(13, "w", "cmd"), 1.2, whole),
        ("space-go", lambda: c(do="space", action="goto", index=2), 1.4, whole),
        ("space-back", lambda: c(do="space", action="goto", index=1), 1.4, whole),
        ("swipe", lambda: c(do="space", action="trackpad", stops=[-420], speed=900), 1.6, whole),
        ("swipe-back", lambda: c(do="space", action="goto", index=1), 1.4, whole),
        ("folder-fold", lambda: c(do="group", name=group, fold=True), 1.2, side),
        ("folder-unfold", lambda: c(do="group", name=group, fold=True), 1.2, side),
        ("card-in", lambda: ui(hovercard={"id": sites[1], "frame": [12, 160, 200, 32]}), 1.4, whole),
        ("card-out", lambda: ui(hovercard="off"), 1.0, whole),
        ("field-in", lambda: press(17, "t", "cmd"), 1.2, whole),
        ("field-out", lambda: press(53, "\u001b"), 1.0, whole),
        ("load", lambda: c(do="ui", go=f"{base}/slow?{time.time()}"), 2.6, top),
        ("find-in", lambda: ui(finding=True), 1.2, find),
        ("find-out", lambda: ui(finding=False), 1.0, find),
        ("downloads-in", lambda: ui(downloadsbutton=True, recentdownloads=True), 1.2, foot),
        ("downloads-out", lambda: ui(recentdownloads=False), 1.0, foot),
        ("plus-in", lambda: ui(plus=True), 1.2, foot),
        ("plus-out", lambda: ui(plus=False), 1.0, foot),
        ("link-in", lambda: ui(link="https://example.com/a/long/path"), 1.2, link),
        ("link-out", lambda: ui(link="off"), 1.4, link),
        ("toast", lambda: ui(announce="Copied"), 3.6, toast),
        ("peek-in", lambda: c(do="peek", url=f"{base}/peeked"), 1.6, whole),
        ("peek-out", lambda: c(do="peek", url="close"), 1.2, whole),
        ("bars-in", lambda: ui(glassBars=["shield", "done", "agent"]), 1.4, toast),
        ("bars-out", lambda: ui(glassBars=[]), 1.2, toast),
        ("mini-out", lambda: sv.sp("select", id=made["video"]), 1.4, foot),
        ("mini-in", lambda: sv.sp("select", id=sites[0]), 1.6, foot),
        ("split-open", lambda: sv.sp("pair", id=sites[2], **{"with": sites[1]}, side="right"), 1.4, whole),
        ("split-close", lambda: sv.sp("detach", id=sites[2]), 1.4, whole),
        ("settings-open", lambda: ui(settings=True), 2.0, ma.SETTINGS),
        ("settings-drill", lambda: (ui(settingsPage="general"), time.sleep(0.6), ui(settingsDetail="routes")), 1.8, ma.SETTINGS),
        ("settings-back", lambda: ui(settingsDetail="back"), 1.2, ma.SETTINGS),
        ("settings-close", lambda: ui(settings=False), 1.2, ma.SETTINGS),
    ]


PAIRS = [("tab-open", "tab-close"), ("space-go", "space-back"), ("swipe", "swipe-back"),
         ("folder-fold", "folder-unfold"), ("mini-out", "mini-in"), ("split-open", "split-close")]
PARTNERS = {**dict(PAIRS), **{b: a for a, b in PAIRS}}


def partner_name(name):
    for a, b in (("-in", "-out"), ("-out", "-in")):
        if name.endswith(a):
            return name[: -len(a)] + b
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--runs", type=int, default=2)
    ap.add_argument("--fps", type=int, default=120)
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--any-screen", action="store_true")
    ap.add_argument("--no-reference", action="store_true")
    ap.add_argument("--app", help="another build of Broadway to film, for before and after runs side by side")
    a = ap.parse_args()
    if a.app:
        sv.APP = str(Path(a.app).resolve())
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    ma.build_film()
    ma.slow_pages()
    pi.make_clip()
    giver = pi.front_pid()
    summary = {}
    try:
        sv.setup(sidebar=True, spaces=True)
        pids = pi.launch_shown()
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        placed = c(do="idle", action="place")
        print("placed:", json.dumps(placed), flush=True)
        if placed.get("screenHz") != 120 and not a.any_screen:
            sys.exit(f"the window is not on a 120 Hz screen: {placed}")
        made = pi.world(True)
        groups = c(do="group").get("groups", [])
        made["group"] = groups[0]["name"] if groups else ""
        c(do="space", action="new", name="Two")
        c(do="space", action="go", index=2)
        sv.sp("open", url=f"http://127.0.0.1:{pi.srv.server_port}/two-a")
        sv.sp("open", url=f"http://127.0.0.1:{pi.srv.server_port}/two-b")
        time.sleep(1)
        c(do="space", action="go", index=1)
        sv.sp("select", id=made["sites"][0])
        time.sleep(1)
        ui(glassBars=[])
        if giver:
            c(do="idle", action="give", pid=giver)
        time.sleep(2)
        table = motions(made)
        if a.list:
            print(" ".join(name for name, *_ in table))
            return
        if not a.no_reference:
            summary["reference"] = {"load": round(os.getloadavg()[0], 1), **reference(out, a.fps)}
            print("reference      ", json.dumps(summary["reference"]), flush=True)
        probe = ma.film(pids[0], "window", out, 0.4, lambda: None)
        ma.SIZE[:] = probe.get("window", ma.SIZE)
        wanted = set(a.only.split(",")) if a.only else None
        for name, act, seconds, crop in table:
            if wanted and name not in wanted and name.split("-")[0] not in wanted:
                continue
            runs = []
            for run in range(a.runs):
                try:
                    runs.append(film(pids[0], f"{name}-{run}", out, seconds, act, crop, a.fps))
                except Exception as e:
                    runs.append({"error": str(e)})
                time.sleep(0.6)
                partner = next((x for x in table if x[0] == (PARTNERS.get(name) or partner_name(name))), None)
                if partner and (run + 1 < a.runs or (wanted and partner[0] not in wanted)):
                    partner[1]()
                    time.sleep(partner[2])
            good = [r for r in runs if "error" not in r]
            if not good:
                summary[name] = runs[0]
            else:
                pick = lambda k, f=statistics.median: f([r[k] for r in good if r.get(k) is not None]) if any(r.get(k) is not None for r in good) else None
                summary[name] = {
                    "screenHz": good[0]["screenHz"], "linkHz": good[0]["linkHz"],
                    "deliveredFps": pick("deliveredFps"), "delivered": [r["delivered"] for r in good],
                    "expected": [r["expected"] for r in good], "slowFrames": [r["slowFrames"] for r in good],
                    "slowestMs": pick("slowestMs", max), "motionMs": pick("motionMs"), "firstMs": pick("firstMs"),
                    "hitches": [r["hitches"] for r in good], "worstMs": pick("worstMs", max),
                    "longestMs": pick("longestMs", max), "broadwayCpuMsPerS": pick("broadwayCpuMsPerS"), "systemWsCpuMsPerS": pick("systemWsCpuMsPerS"),
                    "load": pick("load"), "tickHz": good[0].get("tickHz"),
                    "biggestShare": pick("biggestShare"),
                }
            print(f"{name:15} {json.dumps(summary[name])}", flush=True)
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

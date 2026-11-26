#!/usr/bin/env python3
"""Broadway's transitions outside the sidebar, filmed and timed.

Build first (`./build.sh`), then `python3 Tests/motion_audit.py --out DIR
[--only a,b] [--list]`. The world is perf_idle's, local pages only, drawn on
screen behind the app in front (SEARCH_SHOWN). Each motion is filmed with
Tests/motion_film.swift, a ScreenCaptureKit recorder of the test copy's own
windows only (never the screen, never another app), while the bench's display
link and run-loop observer log the main thread (bench `idle frames` / `gaps`).

For each motion DIR gets NAME.png (a contact sheet of the frames that
changed, each labelled with its time from the first change and how much of
the picture changed from the frame before), NAME.json (the change curve,
how many frames changed, the biggest single frame's share of all change, and
the bench's busy spans) and a summary.json beside them. A transition that is
one frame carrying most of the change (biggestShare near 1) is a pop.
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import perf_idle as pi  # noqa: E402

sv = pi.sv
HERE = Path(__file__).resolve().parent
FILM = Path(tempfile.gettempdir()) / f"broadway-motion-film-{sv.W}"


def slow_pages():
    plain = pi.Pages.do_GET

    def do_get(self):
        if not self.path.startswith("/slow"):
            return plain(self)
        head = b"<!doctype html><title>slow</title><h1>slow</h1>"
        tail = f"<p>{'words ' * 400}</p>".encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.end_headers()
        self.wfile.write(head)
        self.wfile.flush()
        time.sleep(1.2)
        self.wfile.write(tail)

    pi.Pages.do_GET = do_get


def c(**r):
    return sv.cmd(r)


def ui(**f):
    return c(do="ui", **f)


def press(code, chars, *mods):
    return c(do="press", code=code, chars=chars, mods=list(mods))


def build_film():
    source = HERE / "motion_film.swift"
    if not FILM.exists() or FILM.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", str(source), "-o", str(FILM)], check=True)


SIZE = [1180, 780]


DISPLAY = "display"
SETTINGS = "settings"


def film(pid, name, out, seconds, act, crop=None):
    scale = 1 if crop and crop not in (DISPLAY, SETTINGS) else 0.4 if crop == DISPLAY else 0.6 if crop == SETTINGS else 0.5
    args = [str(FILM), "--pid", str(pid), "--seconds", str(seconds), "--out", str(out / name), "--scale", str(scale)]
    if crop == SETTINGS:
        args += ["--center", "940,860", "--columns", "4"]
    elif crop == DISPLAY:
        args += ["--display", "1"]
    elif crop:
        args += ["--crop", ",".join(str(round(x)) for x in crop(*SIZE))]
        args += ["--columns", "4"]
    taker = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        raise RuntimeError(f"{name}: film did not start: {line} {taker.stderr.read()}")
    c(do="idle", action="frames")
    act()
    left = seconds - 0.3
    time.sleep(max(0.2, left - 0.15))
    gaps = c(do="idle", action="gaps")
    taker.wait()
    try:
        shot = json.loads((out / f"{name}.json").read_text())
    except (OSError, ValueError):
        shot = {"error": taker.stderr.read()}
    shot["main"] = {k: gaps.get(k) for k in ("busyMs", "longestMs", "longSpans", "longMs", "hitches", "worstMs")}
    (out / f"{name}.json").write_text(json.dumps(shot, indent=1))
    return shot


def motions(made):
    sites = made["sites"]
    base = f"http://127.0.0.1:{pi.srv.server_port}"

    def newtab_in():
        press(17, "t", "cmd")

    def newtab_out():
        press(53, "\u001b")

    def tab_open():
        ui(show=f"{base}/opened")

    def tab_close():
        press(13, "w", "cmd")

    def load():
        c(do="ui", go=f"{base}/slow?{time.time()}")

    def settings_open():
        ui(settings=True)

    def settings_drill():
        ui(settingsPage="general")
        time.sleep(0.6)
        ui(settingsDetail="routes")

    def settings_back():
        ui(settingsDetail="back")

    def settings_close():
        ui(settings=False)

    def split_open():
        sv.sp("pair", id=sites[2], **{"with": sites[1]}, side="right")

    def split_close():
        sv.sp("detach", id=sites[2])

    whole = None
    video = made["video"]

    def mini_out():
        sv.sp("select", id=video)

    def mini_in():
        sv.sp("select", id=sites[0])

    def card_in():
        ui(hovercard={"id": sites[1], "frame": [12, 160, 200, 32]})

    side = lambda w, h: (0, 60, 640, 420)
    find = lambda w, h: (w - 540, 0, 540, 110)
    foot = lambda w, h: (0, h - 430, 560, 430)
    link = lambda w, h: (0, h - 110, w, 110)
    toast = lambda w, h: (w * 0.2, h - 170, w * 0.6, 170)
    top = lambda w, h: (0, 0, w, 64)
    return [
        ("newtab-in", newtab_in, 1.4, whole),
        ("newtab-out", newtab_out, 1.2, whole),
        ("tab-switch", lambda: sv.sp("select", id=sites[1]), 1.2, whole),
        ("tab-open", tab_open, 1.4, whole),
        ("tab-close", tab_close, 1.2, whole),
        ("load", load, 2.6, top),
        ("find-in", lambda: ui(finding=True), 1.2, find),
        ("find-out", lambda: ui(finding=False), 1.0, find),
        ("downloads-in", lambda: ui(recentdownloads=True), 1.2, foot),
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
        ("shield-in", lambda: ui(glassBars=["shield"]), 1.2, toast),
        ("shield-out", lambda: ui(glassBars=[]), 1.0, toast),
        ("done-in", lambda: ui(glassBars=["done"]), 1.2, toast),
        ("done-out", lambda: ui(glassBars=[]), 1.0, toast),
        ("agent-in", lambda: ui(glassBars=["agent"]), 1.2, toast),
        ("agent-out", lambda: ui(glassBars=[]), 1.0, toast),
        ("card-in", card_in, 1.6, side),
        ("card-out", lambda: ui(hovercard="off"), 1.0, side),
        ("mini-out", mini_out, 1.4, foot),
        ("mini-in", mini_in, 1.6, foot),
        ("split-open", split_open, 1.4, whole),
        ("split-close", split_close, 1.4, whole),
        ("settings-open", settings_open, 2.0, SETTINGS),
        ("settings-drill", settings_drill, 1.8, SETTINGS),
        ("settings-back", settings_back, 1.2, SETTINGS),
        ("settings-close", settings_close, 1.2, SETTINGS),
        ("fullscreen-in", lambda: ui(fullscreen=True), 2.4, DISPLAY),
        ("fullscreen-out", lambda: ui(fullscreen=False), 2.4, DISPLAY),
    ]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--windows", action="store_true")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    build_film()
    slow_pages()
    pi.make_clip()
    giver = pi.front_pid()
    summary = {}
    try:
        sv.setup(sidebar=True)
        pids = pi.launch_shown()
        if len(pids) != 1:
            sys.exit(f"expected one probe, got {pids}")
        made = pi.world(True)
        c(do="space", action="new", name="Two")
        sv.sp("open", url=f"http://127.0.0.1:{pi.srv.server_port}/two-a")
        c(do="space", action="go", index=1)
        sv.sp("select", id=made["sites"][0])
        time.sleep(1)
        ui(glassBars=[])
        if giver:
            c(do="idle", action="give", pid=giver)
        time.sleep(2)
        table = motions(made)
        probe = film(pids[0], "window", out, 0.4, lambda: None)
        SIZE[:] = probe.get("window", SIZE)
        if a.list:
            print(" ".join(name for name, *_ in table))
            return
        wanted = set(a.only.split(",")) if a.only else None
        for name, act, seconds, crop in table:
            if wanted and name not in wanted and name.split("-")[0] not in wanted:
                continue
            try:
                shot = film(pids[0], name, out, seconds, act, crop)
            except Exception as e:
                shot = {"error": str(e)}
            summary[name] = {k: shot.get(k) for k in ("frames", "changing", "motionMs", "biggestShare", "worstGapMs", "main", "error")}
            print(f"{name:16} {json.dumps(summary[name])}", flush=True)
            if a.windows:
                print("   windows:", [(w.get("n"), len(w.get("tabs", [])), w.get("frame")) for w in c(do="windows", action="list").get("windows", [])], flush=True)
            time.sleep(0.6)
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

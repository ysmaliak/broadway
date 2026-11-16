#!/usr/bin/env python3
"""A large folder folded while the column is scrolled.

Build first (`./build.sh`), then `python3 Tests/fold_scroll.py [cards|plain|stacked] [film]`.
A world of its own. A pinned folder, a loose tab, then a folder of sixteen
tabs, scrolled down by several amounts and folded through the bench. Every
display frame of its own shown window is sampled in the app (the list's offset, its content height
and the folder heading's place). The heading must move one way only, with
no frame step larger than the fold's own spring allows, in proportion to the
content shrinking, and at rest the offset must be clamped. With `film`, each
fold is also filmed window-only into .context/fold-scroll/.
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

mode = sys.argv[1] if len(sys.argv) > 1 else "cards"
filming = "film" in sys.argv[2:]
OUT = ROOT / ".context" / "fold-scroll"
CAPTURE = OUT / "capture"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        body = f'<html style="background:#2b3a4a;color:white;font:40px system-ui"><title>{name}</title><h1>{name}</h1></html>'.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use(f"fold-scroll-{mode}-" + uuid.uuid4().hex[:6])
t = sv.T()
pid = None


def cmd(**r): return sv.cmd(r)
def trace(action): return cmd(do="ui", foldtrace={"action": action})


def film(name, act, seconds=1.0):
    if not filming:
        return act()
    folder = OUT / f"{mode}-{name}"
    shutil.rmtree(folder, ignore_errors=True)
    posture = cmd(do="idle", action="unhide")
    p = subprocess.Popen([str(CAPTURE), pid, str(folder), str(seconds), str(posture["number"])],
                         stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None: break
        time.sleep(0.025)
    if p.poll() is not None:
        print("  ..  ", name, "not filmed:", p.communicate()[0].strip(), flush=True)
        return act()
    time.sleep(0.12)
    result = act()
    print("  ..  ", name, p.communicate()[0].strip(), flush=True)
    if list(folder.glob("0*.png")):
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                        "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                        str(OUT / f"{mode}-{name}.mp4")], check=False)
    return result


def fold(name, group="Keanu"):
    if not filming:
        cmd(do="idle", action="unhide")
    trace("start")
    time.sleep(0.05)
    cmd(do="group", name=group, fold=True)
    time.sleep(0.75)
    return trace("stop")["samples"]


def column():
    return cmd(do="columnscroll")


def scroll_to(offset):
    c = column()
    y = c["height"] - 60 if mode == "stacked" else c["height"] - 33 - c["measured"]["room"] / 2
    if c.get("offset", 0) > 0:
        cmd(do="columnscroll", wheel=-(c["offset"] + 30), y=y)
    if offset > 0:
        cmd(do="columnscroll", wheel=offset, y=y)
    time.sleep(0.3)
    return column()


def check(name, samples, folding, group="Keanu"):
    rows = [s for s in samples if "offset" in s and group in s.get("heads", {})]
    t.ok(f"{name}: sampled every frame", len(rows) > 20, len(rows))
    if len(rows) < 3: return
    first, last = rows[0], rows[-1]
    heads = [r["heads"][group] for r in rows]
    cards = [r.get("cards", {}).get(group, 0) for r in rows]
    travel = heads[-1] - heads[0]
    shrink = cards[0] - cards[-1]
    expected = min(first["offset"], last["max"]) if folding else first["offset"]
    t.ok(f"{name}: at rest the offset is clamped ({last['offset']:.1f} of at most {last['max']:.1f})",
         last["offset"] <= last["max"] + 0.5 and abs(last["offset"] - expected) < 1.0,
         {"offset": last["offset"], "expected": expected, "max": last["max"]})
    t.ok(f"{name}: the heading moves by what the offset gave back ({travel:.1f})",
         abs(travel - (first["offset"] - last["offset"])) < 1.5, (travel, first["offset"], last["offset"]))
    steps = [b - a for a, b in zip(heads, heads[1:])]
    gaps = [(b["t"] - a["t"]) / 1000 for a, b in zip(rows, rows[1:])]
    if abs(travel) > 0.5:
        backwards = [s for s in steps if s * travel < -0.6]
        t.ok(f"{name}: the heading moves one way", not backwards, backwards[:6])
        over = [(round(s, 1), round(1.3 * 14.4 * abs(travel) * dt + 2, 1)) for s, dt in zip(steps, gaps)
                if abs(s) > 1.3 * 14.4 * abs(travel) * dt + 2]
        t.ok(f"{name}: no frame step past what the spring allows in its time", not over, over)
        if abs(shrink) > 1:
            lag = max(abs((h - heads[0]) / travel - (cards[0] - c) / shrink) for h, c in zip(heads, cards))
            t.ok(f"{name}: the heading follows the fold's own curve (off by {lag:.2f})", lag < 0.12, lag)
    else:
        t.ok(f"{name}: the heading stays put", max(abs(h - heads[0]) for h in heads) < 0.6,
             [round(h - heads[0], 1) for h in heads][:40])
    (OUT / f"{mode}-{name}.json").write_text(json.dumps(rows, indent=1))
    print(f"  ..   {name}: offset {first['offset']:.0f} -> {last['offset']:.0f}, max {last['max']:.0f}, card {cards[0]:.0f} -> "
          f"{cards[-1]:.0f}, heading {heads[0]:.0f} -> {heads[-1]:.0f}")


def main():
    global pid
    OUT.mkdir(parents=True, exist_ok=True)
    if filming:
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    prefs = {"bench": True, "spaces": True, "tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
             "tabs.cards": mode != "plain", "sidebar": True, "start.fresh": False, "tabs.newAtBottom": True,
             "split": False, "spaces.stacked": mode == "stacked"}
    for key, value in prefs.items():
        subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", str(value).lower()], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        cmd(do="resize", width=1120, height=640, steps=1)
        cmd(do="idle", action="front")
        pinned = sv.sp("open", url=BASE + "/Pull Requests")["resultID"]
        cmd(do="wait", id=pinned, seconds=10)
        cmd(do="group", id=pinned, new=True, name="Pinned")
        cmd(do="group", name="Pinned", pinned=True)
        tempo = sv.sp("open", url=BASE + "/Tempo")["resultID"]
        members = [sv.sp("open", url=BASE + f"/Keanu {n}")["resultID"] for n in range(16)]
        for id in members: cmd(do="wait", id=id, seconds=10)
        cmd(do="group", id=members[0], new=True, name="Keanu")
        for id in members[1:]: cmd(do="group", id=id, name="Keanu")
        cmd(do="group", name="Keanu", pinned=False)
        sv.sp("select", id=tempo)
        if mode == "stacked":
            cmd(do="space", action="new", name="Work")
            sv.sp("open", url=BASE + "/Work")
            cmd(do="space", action="go", index=1)
        time.sleep(1)
        c = column()
        t.ok("the list scrolls with the folder open", c["content"] > c["visible"] + 100, c)
        full = c["content"] - c["visible"]
        for amount in [40, 160, int(full)]:
            scrolled = scroll_to(amount)
            t.ok(f"scrolled {amount}", scrolled["offset"] > 0, scrolled.get("offset"))
            check(f"fits-{amount}", film(f"fits-{amount}", lambda: fold("fits")), True)
            check(f"fits-{amount}-unfold", film(f"fits-{amount}-unfold", lambda: fold("unfold")), False)
        loose = [sv.sp("open", url=BASE + f"/Below {n}")["resultID"] for n in range(14)]
        for id in loose:
            cmd(do="wait", id=id, seconds=10)
            cmd(do="group", id=id, name="none")
        sv.sp("select", id=tempo)
        time.sleep(0.8)
        c = column()
        for amount in [120, int(c["content"] - c["visible"])]:
            scroll_to(amount)
            check(f"partial-{amount}", film(f"partial-{amount}", lambda: fold("partial")), True)
            check(f"partial-{amount}-unfold", film(f"partial-{amount}-unfold", lambda: fold("unfold")), False)
        c = column()
        scroll_to(int(c["content"] - c["visible"]))
        cmd(do="group", name="Keanu", fold=True)
        time.sleep(0.6)
        c = column()
        c = scroll_to(int(c["content"] - c["visible"]))
        check("bottom-unfold", film("bottom-unfold", lambda: fold("unfold")), False)
    finally:
        try: cmd(do="quit")
        except Exception: subprocess.run(["kill", pid])
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

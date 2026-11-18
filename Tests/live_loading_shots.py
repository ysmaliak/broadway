#!/usr/bin/env python3
"""The loading ring on a live folder's heading, pictured and filmed.

Build first (`./build.sh`), then `python3 Tests/live_loading_shots.py [OUT]`.

A hidden test copy in a world of its own reads four folders from a fake on
::1 that answers a signed-in list of pull requests after as long as the
probe says: PRs (three rows, folded, so its count shows), a folder with a
long name (folded), Reviews (two rows, open) and Inbox (open, never read, so
its heading carries the ring and nothing stands under it). A loose tab is held loading beside them, so a tab
row's ring stands in the same picture. A read a person asked for (`live ask`) is held open
and the copy draws its own window (`picture`, at twice the points), cut to
the sidebar: light and dark, on the plain ground and in a tinted space, with
the pointer over the heading, with the open tab inside the folded folder, in
the narrowest sidebar and under Reduce Motion. Nothing is taken from a
screen. A drawn picture shows the ring where it stands before it turns, so
the turning is in the strips. Each picture comes with what the heading says
of itself, and the name and the chevron must stand where they stood before
the ring came.

Then the copy draws the PRs heading frame by frame as it is shown at that
moment (`live strip`). A read through the folder's own hidden page takes
more than a second however fast the site answers, so three strips use a
stand-in read of an exact length: 1.5 s (the ring comes after its wait,
turns and leaves), 0.15 s (nothing may show) and 0.5 s (it stays for one
turn). A fourth strip is a real read from the fake. The frames are kept
beside a contact sheet in OUT/films with the ring's opacity and angle at
each frame. The last picture is the ring under Reduce Motion.
"""
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

sv.use("live-loading")
sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".context" / "live-loading-shots"
SCALE = 2
LONG = "Rocket Pull Requests Waiting for Review"
MODE = {"loads": 0.0}
ROWS = {
    "prs": [(36, "Add the field recorder", "sam"), (37, "Teach the rocket to count", "sam"), (41, "Cache the build graph", "dana")],
    "long": [(52, "Retry uploads on 502", "lee"), (57, "Trim the launch log", "dana"), (58, "Name the stages", "sam")],
    "reviews": [(61, "Fold the solar panels", "lee"), (63, "Paint the nose cone", "dana")],
    "inbox": [(70, "Count down from ten", "sam")],
}
LOOKS = {
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
}
t = sv.T()
report = {"scenes": {}, "films": {}}


def page(name):
    rows = "".join(f'<li class="js-issue-row"><a href="/acme/rocket/pull/{n}">{title}</a>'
                   f'<span>#{n} opened today by <a data-testid="author-filter-link" href="/{who}">{who}</a></span></li>'
                   for n, title, who in ROWS.get(name, []))
    return ('<!doctype html><meta name="user-login" content="sam"><title>Pull requests</title><ul>' + rows + "</ul>").encode()


class Site(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        parts = self.path.split("/")
        body = b"<!doctype html><title>Launch notes</title><body style='font:15px -apple-system;padding:40px'><h2>Launch notes</h2>"
        if self.path.startswith("/hold"):
            time.sleep(900)
        if self.path.startswith("/slow"):
            body = b"<!doctype html><title>Flight plan</title><body style='font:15px -apple-system;padding:40px'><h2>Flight plan</h2><img src=/hold>"
        if len(parts) > 2 and parts[1] == "work":
            if MODE["loads"] > 0:
                time.sleep(MODE["loads"])
            body = page(parts[2])
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True


site = Loopback6(("::1", 0), Site)
threading.Thread(target=site.serve_forever, daemon=True).start()
BASE = f"http://[::1]:{site.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder(name):
    return next((f for f in live()["folders"] if f["name"] == name), None)


def heading(name):
    return live("heading", name)


def settled(name, seconds=40):
    until = time.time() + seconds
    while time.time() < until and folder(name)["reading"]:
        time.sleep(0.1)
    return not folder(name)["reading"]


def shoot(name, width, height):
    drawn = Path(tempfile.mkdtemp()) / f"{name}.png"
    got = sv.cmd({"do": "picture", "path": str(drawn), "page": False, "scale": SCALE})
    if drawn.exists():
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(drawn), "-vf",
                        f"crop={int(width * SCALE)}:{int(height * SCALE)}:0:0", str(OUT / f"{name}.png")], check=True)
    shutil.rmtree(drawn.parent, ignore_errors=True)
    t.ok(f"pictured {name}", (OUT / f"{name}.png").exists(), got)


def strip(name, seconds, how):
    out = OUT / "films"
    out.mkdir(parents=True, exist_ok=True)
    drawn = Path(tempfile.mkdtemp())
    got = live("strip", "PRs", str(drawn), str(seconds), "20", "3", how)
    frames = got.get("frames") or []
    kept = out / name
    shutil.rmtree(kept, ignore_errors=True)
    kept.mkdir()
    for file in sorted(drawn.glob("*.png")):
        shutil.move(str(file), kept / file.name)
    shutil.rmtree(drawn, ignore_errors=True)
    count = len(list(kept.glob("*.png")))
    if count:
        rows = -(-count // 4)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(kept / "%03d.png"), "-vf",
                        f"tile=4x{rows}:padding=6:margin=6:color=0x808080", "-frames:v", "1", str(out / f"{name}.png")], check=True)
    return {"error": got.get("error"), "frames": frames, "count": count}


def spans(frames):
    on = [f["t"] for f in frames if f.get("ring") and f.get("opacity", 0) > 0.05]
    return (on[0], on[-1]) if on else None


def scene(name, width, names, turning=True, before=None):
    time.sleep(0.9)
    said = {}
    for folder_name in names:
        h = heading(folder_name)
        said[folder_name] = h
        t.ok(f"{name}: {folder_name[:12]} shows the ring" + (", turning" if turning else ", still"),
             h.get("ring") is True and h.get("turning") is turning and h.get("spoken") == f"Loading {folder_name}"
             and h.get("ringFrame", [0, 0, 0, 0])[2:] == [11, 11], h)
        x, _, w, _ = h.get("ringFrame", [0, 0, 0, 0])
        t.ok(f"{name}: {folder_name[:12]} keeps the ring right of its name and inside the row",
             x >= h.get("nameEnd", 1e9) and x + w <= h.get("width", 0), h)
        if before and folder_name in before:
            was = before[folder_name]
            t.ok(f"{name}: {folder_name[:12]} name and chevron stand where they stood",
                 (was.get("nameEnd"), was.get("chevron"), was.get("nameCut")) == (h.get("nameEnd"), h.get("chevron"), h.get("nameCut")),
                 (was.get("nameEnd"), was.get("chevron"), h.get("nameEnd"), h.get("chevron")))
    notes = live("notes")["notes"]
    line = next((n for n in notes if n.get("folder") == "Inbox"), None)
    t.ok(f"{name}: the open empty folder has no line under it while it loads", line is None or line.get("text") == "", line)
    inbox = heading("Inbox")
    t.ok(f"{name}: and its heading carries the ring", inbox.get("ring") is True and inbox.get("spoken") == "Loading Inbox", inbox)
    bottom = max(h["frame"][1] + h["frame"][3] for h in list(said.values()) + [inbox]) + 34 * 6
    shoot(name, width, min(690, bottom))
    report["scenes"][name] = {"headings": said, "line": line}


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "240"], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "false"], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 900, "height": 700, "steps": 1})
        sv.cmd({"do": "window"})
        sv.cmd({"do": "open", "url": f"{BASE}/home"})
        for name, slug in (("PRs", "prs"), (LONG, "long"), ("Reviews", "reviews")):
            live("add-page", name, "pullRequests", f"{BASE}/work/{slug}/pulls?q=is%3Aopen+is%3Apr")
            read = next(f for f in live("update", name)["folders"] if f["name"] == name)
            t.ok(f"{name[:12]} reads its rows", read["state"] == "fine" and len(read["items"]) == len(ROWS[slug]), (read["state"], len(read["items"])))
        sv.cmd({"do": "open", "url": f"{BASE}/slow"})
        MODE["loads"] = 600.0
        live("add-page", "Inbox", "pullRequests", f"{BASE}/work/inbox/pulls?q=is%3Aopen+is%3Apr")
        live("unfold", "Inbox")
        live("unfold", "Reviews")
        live("fold", "PRs")
        live("fold", LONG)
        sv.cmd({"do": "ui", "look": "light"})
        time.sleep(1.5)
        names = ["PRs", LONG, "Reviews"]
        rest = {name: heading(name) for name in names}
        report["rest"] = rest
        for name in names:
            h = rest[name]
            t.ok(f"at rest {name[:12]} shows no ring and says nothing of loading", not h.get("ring") and not h.get("loading")
                 and h.get("spoken") != f"Loading {name}", h)
        shoot("rest-light", 240, 420)

        MODE["loads"] = 600.0
        for name in names:
            live("ask", name)
        scene("ring-light", 240, names, before=rest)
        live("heading", "PRs", "hover")
        scene("ring-light-hover", 240, names, before=rest)
        live("heading", "PRs", "rest")
        sv.cmd({"do": "ui", "look": "dark"})
        scene("ring-dark", 240, names, before=rest)
        live("heading", "PRs", "hover")
        scene("ring-dark-hover", 240, names, before=rest)
        live("heading", "PRs", "rest")
        for theme, ground in (("dark", "vivid"), ("light", "vivid"), ("light", "pale")):
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "space", "action": "look", **LOOKS[ground]})
            scene(f"ring-{theme}-{ground}", 240, names, before=rest)
        live("heading", "PRs", "hover")
        scene("ring-light-pale-hover", 240, names, before=rest)
        live("heading", "PRs", "rest")

        inside = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if "/pull/36" in x["url"]), None)
        if inside:
            sv.sp("select", id=inside["id"])
            scene("ring-light-pale-selected-inside", 240, ["PRs", LONG, "Reviews"])
        live("fold", "PRs")

        sv.cmd({"do": "ui", "sideWidth": 200})
        time.sleep(0.6)
        narrow = {name: heading(name) for name in names}
        scene("ring-light-pale-narrowest", 200, names)
        report["narrowest"] = narrow
        sv.cmd({"do": "ui", "look": "dark"})
        scene("ring-dark-pale-narrowest", 200, names)
        sv.cmd({"do": "ui", "sideWidth": 240})
        sv.cmd({"do": "ui", "look": "light"})

    finally:
        sv.finish()

    print("— filmed")
    MODE["loads"] = 0.0
    sv.use("live-loading-film")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "240"], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 900, "height": 700, "steps": 1})
        sv.cmd({"do": "window"})
        sv.cmd({"do": "open", "url": f"{BASE}/home"})
        live("add-page", "PRs", "pullRequests", f"{BASE}/work/prs/pulls?q=is%3Aopen+is%3Apr")
        live("update", "PRs")
        live("fold", "PRs")
        sv.cmd({"do": "ui", "look": "light"})
        time.sleep(1.5)
        rest = heading("PRs")
        takes = (("arrive-turn-leave", "1.5", 2.6, "a read of 1.5 s"), ("blink", "0.15", 1.2, "a read of 0.15 s"),
                 ("one-turn", "0.5", 2.0, "a read of 0.5 s"), ("real-read", "ask", 5.0, "a real read"))
        for name, how, seconds, said in takes:
            got = strip(name, seconds, how)
            frames = got["frames"]
            span = spans(frames)
            report["films"][name] = {"ring": span, "frames": frames}
            t.ok(f"drew {name} ({got['count']} frames)", not got["error"] and got["count"] >= 10 and (OUT / "films" / f"{name}.png").exists(),
                 got["error"])
            if name == "blink":
                t.ok(f"{said}: nothing shows", span is None, span)
            elif name == "one-turn":
                t.ok(f"{said}: the ring comes after its wait and stays for a turn ({span})",
                     span is not None and 0.35 <= span[0] <= 0.7 and span[1] - span[0] >= 0.7 and span[1] <= 1.6, span)
            elif name == "real-read":
                t.ok(f"{said}: the ring comes after its wait, stays at least a turn and leaves ({span})",
                     span is not None and 0.35 <= span[0] <= 0.7 and span[1] - span[0] >= 0.7 and span[1] < seconds - 0.2, span)
            else:
                t.ok(f"{said}: the ring comes after its wait and leaves with the read ({span})",
                     span is not None and 0.35 <= span[0] <= 0.7 and 1.3 <= span[1] <= 2.0, span)
            turns = [f["turn"] for f in frames if f.get("ring") and f.get("opacity", 0) > 0.9]
            if name != "blink":
                t.ok(f"{said}: the ring turns while it shows", len(set(round(v, 2) for v in turns)) >= 4, turns[:8])
            moved = {(f["nameEnd"], f["chevron"]) for f in frames}
            t.ok(f"{said}: the name and the chevron never moved", moved == {(rest.get("nameEnd"), rest.get("chevron"))}, moved)
            settled("PRs")
            time.sleep(1.2)

        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(0.5)
        MODE["loads"] = 8.0
        live("ask", "PRs")
        time.sleep(1.0)
        h = heading("PRs")
        t.ok("under Reduce Motion the ring shows and stands still", h.get("ring") is True and h.get("turning") is False
             and h.get("spoken") == "Loading PRs", h)
        shoot("ring-reduce-motion", 240, 300)
        got = strip("reduce-motion", 1.0, "look")
        still = {round(f["turn"], 3) for f in got["frames"]}
        t.ok("and its frames show one angle", still == {0.0} and all(f["ring"] for f in got["frames"]), still)
        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "false"], check=True)
    finally:
        sv.finish()
    (OUT / "report.json").write_text(json.dumps(report, indent=1))
    t.done()
    sys.exit(1 if t.failed else 0)


main()

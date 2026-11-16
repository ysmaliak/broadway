#!/usr/bin/env python3
"""The column scrolled to its very end under an open GitHub live folder.

Build first (`./build.sh`), then `python3 Tests/side_scroll_bottom.py [OUT]`.
A test copy in a world of its own, started hidden, its window put below the
desktop and pictured alone (`screencapture -l`). A server on 127.0.0.1 is
the signed-in GitHub list page for `integrations.api`: twelve open pull
requests, no token. The
space has the live folder open with its twelve PR rows and loose tabs below
it, in a window short enough that the column scrolls.

Scrolled to the end, then again after the folder reads (its rows arrive
while the list is already at its end), and once more after a refresh that
drops rows: the last row is whole above the column's floor (the held New
Tab row's line, or 6 points over the foot), the list reaches no further than
its content, a further wheel moves nothing, and the folder card's bottom is
drawn. Dark, New Tab at the bottom and at the top. BROADWAY_APP picks another
build, for before and after.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

sv.use("side-scroll-bottom")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/scroll-bottom")
HEIGHT = int(os.environ.get("HEIGHT", "520"))
WIDTH = 1000
COUNT = [12]
t = sv.T()
WINDOW = [0]
LOOSE = set()


def rows():
    return [(600 + n, f"[IOS-{14590 + n}] Performance - Deferred work {n}", "octo-sam", "open",
             "Approved" if (600 + n) % 2 else "Review required", "passing" if (600 + n) % 3 else "failing") for n in range(COUNT[0])]


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        body = (pr.page(rows(), BASE) if self.path.startswith("/github/page/pulls")
                else f"<!doctype html><title>{self.path.strip('/')}</title>".encode())
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


srv = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def col(**f):
    return sv.cmd({"do": "columnscroll", **f})


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})["window"]
    time.sleep(0.8)


def shoot(name):
    path = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    return path if path.exists() else None


def foot(c):
    return c["height"] - 36


def floor_of(c):
    e = c["edges"]
    y = e.get("newTabY", -1)
    held = y > 0 and e.get("newTabH", 0) > 0 and y < foot(c)
    return (y - 2, "held New Tab") if held else (foot(c) - 6, "foot")


def wheel(dy, where):
    c = col()
    y = foot(c) - 70
    if where == "raised":
        rows = frames()
        shown = [r for k, r in rows.items() if k not in LOOSE and r[3] > 0 and 60 < r[1] < c["height"] / 2]
        if not shown:
            return c
        y = min(r[1] for r in shown) + 10
    try:
        return col(wheel=dy, y=y)
    except RuntimeError as e:
        print(f"  ..   wheel {where} {dy}: {e}", flush=True)
        return col()


def frames():
    return sv.cmd({"do": "rowframes"})["rows"]


def check(label, loose):
    c = col()
    rows = frames()
    shown = [rows[k] for k in loose if k in rows]
    drawn = [rows[k] for k in loose if k in rows]
    last = max(drawn, key=lambda r: r[1]) if drawn else None
    floor, under = floor_of(c)
    report = {"offset": c.get("offset"), "visible": c.get("visible"), "content": c.get("content"),
              "measured": c.get("measured"), "all": c.get("all"), "edges": c.get("edges"), "last": last,
              "rows": {k: rows[k] for k in loose if k in rows}, "floor": floor, "under": under}
    print(f"  ..   {label}: {json.dumps(report)}", flush=True)
    shoot(label)
    t.ok(f"{label}: the column scrolls", c.get("scrolls"), c.get("measured"))
    t.ok(f"{label}: the last row is drawn", last is not None, sorted(rows))
    if last:
        t.ok(f"{label}: the last row is whole above the {under}", last[1] + last[3] <= floor + 0.5,
             (last[1] + last[3], floor))
        t.ok(f"{label}: and not far above it (the list ends at its content)", last[1] + last[3] >= floor - 6,
             (last[1] + last[3], floor))
    wheel(400, "list")
    later = [r for k, r in frames().items() if k in loose]
    after = max(later, key=lambda r: r[1]) if later else None
    t.ok(f"{label}: a further wheel on the list moves nothing", after == last, (last, after))
    return report


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    summary = {}
    try:
        for bottom in (True, False)[:int(os.environ.get("RUNS", "2"))]:
            sv.setup(**{"sidebar": True, "layout.cards": True, "live.on": True, "start.fresh": False,
                        "tabs.newAtBottom": bottom, "sidebar.address": bool(os.environ.get("ADDRESS")),
                        "agents.on": bool(os.environ.get("AGENTS"))})
            subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", BASE], check=True)
            sv.launch()
            sv.cmd({"do": "window"})
            stage(True)
            names = ["CEIA Dev Content Width", "Release notes", "Design review", "Roadmap", "Inbox"]
            loose = [sv.page(n) for n in names]
            for other in [k for k in frames() if k not in loose]:
                sv.sp("close", id=other)
            time.sleep(0.6)
            loose = [k for k in frames() if k in loose]
            LOOSE.clear()
            LOOSE.update(loose)
            COUNT[0] = 12
            live("add", "Pull Requests", "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
            live("unfold", "Pull Requests")
            time.sleep(0.6)
            order = sorted(loose, key=lambda k: frames()[k][1])
            tag = "held" if bottom else "top"
            wheel(4000, "list")
            time.sleep(0.6)
            live("update", "Pull Requests")
            time.sleep(2.0)
            wheel(4000, "raised")
            wheel(4000, "list")
            time.sleep(0.6)
            summary[f"{tag}-loaded"] = check(f"{tag}-loaded-at-end", order)
            wheel(-4000, "list")
            time.sleep(0.5)
            wheel(4000, "list")
            time.sleep(0.8)
            summary[f"{tag}-end"] = check(f"{tag}-end", order)
            COUNT[0] = 4
            live("update", "Pull Requests")
            time.sleep(2.0)
            summary[f"{tag}-shrunk"] = check(f"{tag}-after-shrink", order)
            COUNT[0] = 12
            live("update", "Pull Requests")
            time.sleep(2.0)
            wheel(4000, "list")
            time.sleep(0.8)
            summary[f"{tag}-grown"] = check(f"{tag}-after-grow", order)
            sv.finish()
        (OUT / "summary.json").write_text(json.dumps(summary, indent=1))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

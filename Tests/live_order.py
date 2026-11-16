#!/usr/bin/env python3
"""A row dragged inside a Live Folder stays where it was dropped.

Build first (`./build.sh`), then `python3 Tests/live_order.py`.
A hidden test copy in a world of its own follows an RSS feed served on
127.0.0.1 (no code host is asked anything). The probe drags the last row of
the folder above the first with mouse events sent to the row itself, so the
sidebar's own carry runs, and reads the order from the rows' frames on
screen. Then the feed changes (a new item, one gone, the rest shuffled) and
the folder reads it again: the moved row keeps its place, the new item
arrives at the top and the gone one leaves. The app quits and comes back,
and the order is the same.

Last, a PRs folder reads Tests/pr_rows.py's fake on ::1, whose three stacked
pull requests show as one stack. The middle row of the stack is carried
below another row, held there while the probe reads the line the sidebar
offers, then let go: the whole stack lands there in its own order and still
draws one stack chevron.
"""
import glob
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

sys.argv = sys.argv[:1]
import pr_rows as pr  # noqa: E402

sv.use("live-order")
sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
t = sv.T()
FEED = {"items": ["Amber", "Birch", "Cedar", "Dune", "Ember"]}


class Feed(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        port = self.server.server_port
        if self.path.startswith("/feed.xml"):
            items = "".join(f"<item><title>{name} lamp</title><link>http://127.0.0.1:{port}/lamp/{name.lower()}</link>"
                            f"<guid>{name.lower()}</guid></item>" for name in FEED["items"])
            body = (f"<?xml version='1.0'?><rss version='2.0'><channel><title>Lamps</title>"
                    f"<link>http://127.0.0.1:{port}/</link>{items}</channel></rss>").encode()
            kind = "application/rss+xml"
        else:
            name = self.path.rsplit("/", 1)[-1].capitalize()
            body = f"<!doctype html><title>{name} lamp</title><p>{name}".encode()
            kind = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


srv = ThreadingHTTPServer(("127.0.0.1", 0), Feed)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def lamps(state=None):
    state = state or live()
    return next((f for f in state["folders"] if f["name"] == "Lamps"), None)


def shown():
    folder = lamps()
    if not folder:
        return [], {}
    names = {x["id"]: x["key"].rsplit("/", 1)[-1].capitalize() for x in folder["tabs"] if x.get("key")}
    frames = sv.cmd({"do": "rowframes"})["rows"]
    placed = sorted((frames[id][1], names[id]) for id in names if id in frames)
    return [name for _, name in placed], {names[id]: frames[id] for id in names if id in frames}


def settle(wanted, within=20):
    until = time.time() + within
    got = shown()[0]
    while time.time() < until and got != wanted:
        time.sleep(0.4)
        got = shown()[0]
    return got


def wait_rows(count, within=40):
    until = time.time() + within
    while time.time() < until:
        order, frames = shown()
        if len(order) == count and all(n in frames for n in order):
            return order
        time.sleep(0.5)
    return shown()[0]


def route(a, b, fraction):
    start = (a[0] + a[2] * 0.4, a[1] + a[3] / 2)
    end = (b[0] + b[2] * 0.4, b[1] + b[3] * fraction)
    way = [start, (start[0], start[1] + (3 if end[1] > start[1] else -3)), (start[0], start[1] + (7 if end[1] > start[1] else -7))]
    steps = 24
    way += [(way[-1][0] + (end[0] - way[-1][0]) * k / steps, way[-1][1] + (end[1] - way[-1][1]) * k / steps) for k in range(1, steps + 1)]
    return [[round(x, 1), round(y, 1)] for x, y in way + [end]]


def drag(name, above):
    _, frames = shown()
    sv.sp("mouse", points=route(frames[name], frames[above], 0.25) + [route(frames[name], frames[above], 0.25)[-1]], to="view")
    time.sleep(1.0)


def prs():
    state = live()
    folder = next((f for f in state["folders"] if f["name"] == "PRs"), None)
    if not folder:
        return [], {}, folder
    names = {x["id"]: int(x["key"].rsplit("/", 1)[-1]) for x in folder["tabs"] if x.get("key")}
    frames = sv.cmd({"do": "rowframes"})["rows"]
    placed = sorted((frames[id][1], names[id]) for id in names if id in frames)
    return [n for _, n in placed], {names[id]: frames[id] for id in names if id in frames}, folder


def stacks():
    print("— a stack carried in a PRs folder")
    live("remove", "Lamps")
    live("add-page", "PRs", "pullRequests", f"{pr.BASE}{pr.PULLS}")
    live("unfold", "PRs")
    order, frames, folder = prs()
    until = time.time() + 60
    while time.time() < until and not (folder and folder.get("stacks") and len(frames) == len(pr.ROWS)):
        live("update", "PRs")
        time.sleep(1)
        order, frames, folder = prs()
    t.ok("the PRs folder shows its stack top first", order[1:4] == [38, 37, 36], order)
    if order[1:4] != [38, 37, 36]:
        return
    below = order[5]
    points = route(frames[37], frames[below], 0.75)
    sv.sp("mouse", points=points, hold=True, to="view")
    time.sleep(0.6)
    offered = sv.cmd({"do": "foldergrid"})["drop"]
    print("  offered while held:", json.dumps(offered))
    t.ok("held over a row, the carry offers a place inside the PRs folder", offered.get("group") == "PRs" and offered.get("line"), offered)
    sv.sp("mouse", points=[points[-1]], resume=True, to="view")
    time.sleep(1.2)
    after, _, folder = prs()
    numbered = {x["id"]: int(x["key"].rsplit("/", 1)[-1]) for x in folder["tabs"] if x.get("key")}
    anchor = numbered.get(offered.get("member"))
    rest = [n for n in order if n not in (36, 37, 38)]
    at = rest.index(anchor) + (1 if offered.get("after") else 0) if anchor in rest else len(rest)
    wanted = rest[:at] + [38, 37, 36] + rest[at:]
    t.ok("the line was offered outside the stack", anchor not in (36, 37, 38), offered)
    t.ok("let go, the whole stack lands where the line was, in its own order", after == wanted and after != order, [order, after, wanted])
    t.ok("and it still draws one stack", len(folder["stacks"]) == 1, folder["stacks"])


def saved_order():
    for path in glob.glob(os.path.join(sv.SUPPORT, "**", "live-folders.json"), recursive=True):
        for folder in json.load(open(path)):
            if folder.get("name") == "Lamps":
                return folder.get("order")
    return None


def main():
    sv.setup(sidebar=True, **{"tabs.groups": True, "live.on": True, "start.fresh": False, "ai.groups": False, "tabs.aiGroups": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", pr.BASE], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        live("on")
        live("add", "Lamps", f"{BASE}/feed.xml")
        live("update", "Lamps")
        live("unfold", "Lamps")
        first = wait_rows(5)
        t.ok("the folder shows the feed in its own order", first == ["Amber", "Birch", "Cedar", "Dune", "Ember"], first)
        t.ok("a folder never moved has no order of its own", lamps()["order"] == [], lamps()["order"])

        drag("Ember", "Amber")
        moved = settle(["Ember", "Amber", "Birch", "Cedar", "Dune"])
        t.ok("the last row dragged above the first stays there", moved == ["Ember", "Amber", "Birch", "Cedar", "Dune"], moved)
        folder = lamps()
        t.ok("still five rows in the folder and nothing dismissed", len(folder["tabs"]) == 5 and folder["hidden"] == 0, folder)
        t.ok("the folder now keeps an order", len(folder["order"]) == 5, folder["order"])

        drag("Cedar", "Amber")
        again = settle(["Ember", "Cedar", "Amber", "Birch", "Dune"])
        t.ok("a second drag lands between two rows", again == ["Ember", "Cedar", "Amber", "Birch", "Dune"], again)

        folder = lamps()
        ids = {x["key"].rsplit("/", 1)[-1].capitalize(): x["id"] for x in folder["tabs"] if x.get("key")}
        active = next((name for name, id in ids.items() if id == sv.cmd({"do": "rowframes"})["active"]), "")
        print("  the row in front after the drags:", active or "none in the folder")
        sv.cmd({"do": "select", "id": ids["Amber"]})
        time.sleep(0.5)
        FEED["items"] = ["Dune", "Fern", "Birch", "Ember", "Amber"]
        live("update", "Lamps")
        after = settle(["Fern", "Ember", "Amber", "Birch", "Dune"])
        t.ok("after the feed changes the new item is on top, the gone one left, the rest kept their places",
             after == ["Fern", "Ember", "Amber", "Birch", "Dune"], after)

        until = time.time() + 10
        while time.time() < until and len(saved_order() or []) < 5:
            time.sleep(0.3)
        t.ok("the order is in the saved folder", (saved_order() or [])[:1] == [f"{BASE}/lamp/fern"], saved_order())

        sv.quit()
        time.sleep(1)
        sv.launch()
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        live("unfold", "Lamps")
        back = wait_rows(5)
        back = settle(["Fern", "Ember", "Amber", "Birch", "Dune"]) if back != ["Fern", "Ember", "Amber", "Birch", "Dune"] else back
        t.ok("after a relaunch the order is the same", back == ["Fern", "Ember", "Amber", "Birch", "Dune"], back)
        live("update", "Lamps")
        read = settle(["Fern", "Ember", "Amber", "Birch", "Dune"])
        t.ok("and a read after the relaunch keeps it", read == ["Fern", "Ember", "Amber", "Birch", "Dune"], read)
        stacks()
    finally:
        sv.quit()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

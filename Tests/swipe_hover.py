#!/usr/bin/env python3
"""A row's hover card and a space switch: the card goes when the switch begins and never shows in another space.

Build first (`./build.sh`), then `python3 Tests/swipe_hover.py`. A test copy
in a world of its own, two spaces side by side. The pointer is put over a
row with the bench (`ui hovercard`), as a row under a resting pointer does it.

- A card that is up goes as a swipe begins, as ⌃-number begins and as a
  pull past the last space begins, and is not up after the landing.
- A hover whose wait has not run out when the switch begins brings no card,
  during the slide or after it.
- A swipe that carries on past the last space, where the window has not
  yet changed space, brings no card for the space left behind.
- A row that comes under the pointer while the spaces slide brings no card.
- At rest a row still brings its card, before and after each of these.
BROADWAY_PROBE_APP picks another build, for before and after.
"""
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("swipe-hover")
t = sv.T()
ROW = [10, 120, 220, 34]


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = f'<html style="background:#345;color:white"><title>{self.path.strip("/")}</title><h1>{self.path}</h1></html>'.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def space(**f): return sv.cmd({"do": "space", **f})


def card(): return sv.cmd({"do": "card", "args": []})


def hover(id): sv.cmd({"do": "ui", "hovercard": {"id": id, "frame": ROW}})


def up(seen): return seen.get("kind", "") != "" or seen.get("popup") is True


def go(index):
    space(action="go", index=index)
    time.sleep(1.3)


def rows():
    state = sv.sp("state")
    front = state["activeID"]
    other = next(tab["id"] for tab in state["tabs"] if tab["id"] != front)
    hover(other)
    return front


def case(label, begin, first, last, wait):
    go(first)
    front = rows()
    hover(front)
    time.sleep(wait)
    before = card()
    if wait > 1:
        t.ok(f"{label}: at rest the row brings its card", up(before), before.get("kind"))
    begin()
    time.sleep(0.05)
    during = card()
    t.ok(f"{label}: no card once the switch has begun", not up(during), (during.get("kind"), during.get("popup")))
    time.sleep(1.6)
    after = card()
    t.ok(f"{label}: no card after it", not up(after), (after.get("kind"), after.get("popup"), space()["current"]))
    again(label)


def again(label):
    time.sleep(0.6)
    front = rows()
    hover(front)
    time.sleep(1.3)
    seen = card()
    t.ok(f"{label}: at rest again, a row brings its card", up(seen), (seen.get("kind"), seen.get("popup"), space().get("swipe")))
    sv.cmd({"do": "ui", "hovercard": "off"})
    time.sleep(0.3)


def main():
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "spaces": True, "start.fresh": False, "tabs.groups": False})
        launch()
        sv.cmd({"do": "window"})
        sv.cmd({"do": "agents", "action": "stage", "dark": True, "size": [1100, 700]})
        time.sleep(0.8)
        for name in ("One-a", "One"):
            sv.sp("open", url=f"{BASE}/{name}")
            time.sleep(0.6)
        space(action="new", name="Two")
        time.sleep(1)
        for name in ("Two-a", "Two"):
            sv.sp("open", url=f"{BASE}/{name}")
            time.sleep(0.6)
        names = [s["name"] for s in space()["spaces"]]
        last = len(names)
        first = last - 1
        slide = lambda: space(action="key", index=last)
        swipe = lambda: space(action="trackpad", stops=[-180], speed=700, momentum=True)
        past = lambda: space(action="trackpad", stops=[-240], speed=500, momentum=False)

        case("a card that is up, ⌃-number", slide, first, last, 1.2)
        case("a card that is up, a swipe", swipe, first, last, 1.2)
        case("a hover still waiting, ⌃-number", slide, first, last, 0.1)
        case("a hover still waiting, a swipe", swipe, first, last, 0.1)
        case("a card that is up, a pull past the last space", past, last, last, 1.2)

        on = [{"stops": [-180], "speed": 700, "momentum": False}, {"at": 0.42, "stops": [-320], "speed": 300, "momentum": False}]
        for label, wait in (("a card that is up", 1.2), ("a hover still waiting", 0.1)):
            go(first)
            front = rows()
            hover(front)
            time.sleep(wait)
            space(action="trackpad", gestures=on)
            seen = []
            for _ in range(14):
                now = card()
                seen.append((now.get("kind"), now.get("popup")))
                time.sleep(0.15)
            t.ok(f"{label}, a swipe that carries on past the last space: no card for the space left behind",
                 not any(kind or popup for kind, popup in seen), seen)
            again(f"{label}, a swipe that carries on past the last space")

        go(first)
        front = rows()
        sv.cmd({"do": "ui", "hovercard": "off"})
        slide()
        time.sleep(0.12)
        hover(front)
        time.sleep(1.8)
        seen = card()
        t.ok("a row that comes under the pointer mid-slide brings no card", not up(seen), (seen.get("kind"), seen.get("popup")))
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

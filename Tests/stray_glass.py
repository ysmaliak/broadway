#!/usr/bin/env python3
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("stray-glass")

LINKS = "".join(f'<a id="l{n}" href="/page-{n}" style="display:block;font-size:22px;line-height:44px;padding:0 20px">link {n}</a>' for n in range(1, 9))


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        body = (f"<title>{page}</title><style>body{{background:#202124;color:#e8eaed;font:17px system-ui}}</style>"
                f"<h1>Tempo – Video Speed Controller</h1><p>5.0 ★</p>{LINKS}<p>{'words ' * 400}</p>")
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def small(within=None):
    p = sv.cmd({"do": "probe"})
    px, py, pw, ph = within or p.get("activePageFrame", [0, 0, 0, 0])
    out = []
    shown = [g for g in p.get("glass", []) + p.get("childGlass", []) if not g["hidden"] and g["alpha"] >= 0.02]
    def on_ground(f):
        x, y, w, h = f
        return any(gw * gh > w * h and gw <= 700 and gh <= 160 and gx <= x and gy <= y and x + w <= gx + gw and y + h <= gy + gh
                   for gx, gy, gw, gh in (g["frame"] for g in shown))
    for g in shown:
        x, y, w, h = g["frame"]
        if w <= 0 or h <= 0 or w > 300 or h > 300 or on_ground(g["frame"]):
            continue
        if x + w <= px or x >= px + pw or y + h <= py or y >= py + ph:
            continue
        out.append(g["frame"])
    return out, (px, py, pw, ph)


def over(tab, n):
    sv.ev(tab, f"document.getElementById('l{n}').dispatchEvent(new MouseEvent('mouseover', {{bubbles: true, composed: true}})); 0")


def out(tab):
    sv.ev(tab, "document.body.dispatchEvent(new MouseEvent('mouseout', {bubbles: true, composed: true, relatedTarget: null})); 0")


def cornered(label, pill, frame):
    x, y, w, h = pill
    fx, fy, fw, fh = frame
    right = sv.sp("state")["linkOnRight"]
    side = "right" if right else "left"
    edge = abs((x + w) - (fx + fw - 10)) <= 2 if right else abs(x - (fx + 10)) <= 2
    t.ok(f"{label}: at the {side} corner, away from the pointer", edge, (pill, frame, side))


def go(tab, name):
    sv.cmd({"do": "go", "id": tab, "url": f"{sv.BASE}/{name}"})
    sv.cmd({"do": "wait", "id": tab, "seconds": 5})


t = sv.T()
try:
    sv.setup(**{"links.show": True})
    sv.launch()
    sv.cmd({"do": "ui", "swipepages": True})
    a = sv.page("a")
    sv.cmd({"do": "select", "id": a})
    sv.cmd({"do": "wait", "id": a, "seconds": 5})
    go(a, "b")
    time.sleep(0.6)

    left, _ = small()
    t.ok("nothing over a page at rest", not left, left)

    for n in [2, 5]:
        over(a, n)
        time.sleep(0.4)
        shown, (px, py, pw, ph) = small()
        pill = [f for f in shown if f[3] == 26]
        t.ok(f"link {n}: its address is up", len(pill) == 1, shown)
        if pill:
            x, y, w, h = pill[0]
            t.ok(f"link {n}: the address has its words, not just its margins", w > 60, pill[0])
            t.ok(f"link {n}: at the page's bottom edge, not in its middle", abs((y + h) - (py + ph - 10)) <= 2, (pill[0], (px, py, pw, ph)))
            cornered(f"link {n}", pill[0], (px, py, pw, ph))
        out(a)
        time.sleep(0.6)
        left, _ = small()
        t.ok(f"link {n}: off it, nothing is left", not left, left)

    b = sv.page("c")
    sv.cmd({"do": "wait", "id": b, "seconds": 5})
    sv.cmd({"do": "select", "id": a})
    time.sleep(0.6)
    over(a, 3)
    time.sleep(0.4)
    shown, (px, py, pw, ph) = small()
    pill = [f for f in shown if f[3] == 26]
    t.ok("back from another tab: the address has its words", len(pill) == 1 and pill[0][2] > 60, shown)
    out(a)
    time.sleep(0.6)

    d = sv.page("d")
    sv.cmd({"do": "wait", "id": d, "seconds": 5})
    sv.sp("pair", id=d, **{"with": a}, side="right")
    time.sleep(1.0)
    sv.sp("focus", id=a)
    time.sleep(0.4)
    frames = sv.frames(sv.sp("state"))
    for tab, name in [(a, "left"), (d, "right")]:
        fx, fy, fw, fh = frames[tab]["x"], frames[tab]["y"], frames[tab]["width"], frames[tab]["height"]
        over(tab, 4)
        time.sleep(0.4)
        shown, _ = small((fx, fy, fw, fh))
        pill = [f for f in shown if f[3] == 26]
        t.ok(f"paired, {name} page: the address has its words", len(pill) == 1 and pill[0][2] > 60, (shown, frames[tab]))
        if pill:
            t.ok(f"paired, {name} page: at its own bottom edge", abs(pill[0][1] + 26 - (fy + fh - 10)) <= 2, (pill[0], frames[tab]))
            cornered(f"paired, {name} page", pill[0], (fx, fy, fw, fh))
        out(tab)
        time.sleep(0.6)
    sv.sp("select", id=b)
    time.sleep(0.6)
    sv.sp("select", id=a)
    time.sleep(0.6)

    for dx, steps, ms, cancel in [(8, 2, 20, True), (40, 4, 60, True), (120, 6, 80, True), (-40, 4, 60, True)]:
        sv.cmd({"do": "pull", "dx": dx, "steps": steps, "ms": ms, "cancel": cancel})
        time.sleep(0.4)
        left, _ = small()
        t.ok(f"a swipe of {dx} points, cancelled, leaves nothing", not left, left)

    for gap in [0.0, 0.05, 0.12]:
        sv.cmd({"do": "find", "text": "words"})
        time.sleep(gap)
        sv.cmd({"do": "find", "close": True})
        time.sleep(0.9)
        left, _ = small()
        t.ok(f"Find opened and closed after {int(gap * 1000)} ms leaves nothing", not left, left)
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)

#!/usr/bin/env python3
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-click")

PAGE = b"""<!doctype html><title>button</title>
<style>html,body{margin:0;height:100%} button{position:fixed;inset:0;width:100%;height:100%;font:20px system-ui}</style>
<script>
window.downs = 0; window.clicks = 0;
addEventListener('mousedown', () => downs++, true);
addEventListener('click', () => clicks++, true);
</script>
<button id=all>the whole page is a button</button>"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"

ROWS = []


WEBKIT = "webkit" in sys.argv[1:]


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


def started():
    launch()
    if WEBKIT:
        pc("firstmouse", webkit=True)


def pc(action, **f): return sv.cmd({"do": "pageclick", "action": action, **f})


def check(t, name, tab, settle=0.0, at=None):
    time.sleep(settle)
    h = pc("hits")
    missed = sum(p["missed"] for p in h["pages"])
    first = next((p["firstMiss"] for p in h["pages"] if p["missed"]), "")
    before = sv.ev(tab, "clicks")
    c = pc("click", **({"x": at[0], "y": at[1]} if at else {}))
    after = sv.ev(tab, "clicks")
    heard = (after or 0) - (before or 0)
    t.ok(f"{name}: every point of the page hits the page", missed == 0 and h["pages"], (first, h["misses"][:3]))
    t.ok(f"{name}: a click through the window reaches the page", heard == 1, (before, after, c["hit"], c["before"], c["after"]))
    t.ok(f"{name}: the page holds the keys after the click", c["after"]["responderInPage"], c["after"]["responder"])
    p0 = h["pages"][0] if h["pages"] else {}
    ROWS.append({"state": name, "missed": missed, "points": sum(p["points"] for p in h["pages"]), "firstMiss": first,
                 "centre": p0.get("centre", ""), "firstMouseAt": p0.get("firstMouseAt"), "webKitFirstMouseAt": p0.get("webKitFirstMouseAt"),
                 "heard": heard, "appActive": c["before"]["appActive"], "key": c["before"]["key"], "keyWindow": c["before"]["keyWindow"],
                 "responderBefore": c["before"]["responder"], "responderAfter": c["after"]["responder"]})
    return h


def youtube(t):
    sv.setup(sidebar=True)
    started()
    sv.cmd({"do": "resize", "width": 1280, "height": 860, "steps": 1})
    tab = sv.sp("open", url="https://www.youtube.com/watch?v=aqz-KE-bpKQ")["resultID"]
    for _ in range(40):
        if sv.ev(tab, "!!document.querySelector('video')"): break
        time.sleep(0.5)
    time.sleep(5)
    rect = sv.ev(tab, "(()=>{const r=document.querySelector('#movie_player').getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()")
    under = f"(()=>{{const e=document.elementFromPoint({rect[0] + rect[2] / 2},{rect[1] + rect[3] / 2});return !!e&&!!e.closest('#movie_player')}})()"
    for _ in range(10):
        if sv.ev(tab, under): break
        sv.ev(tab, "void [...document.querySelectorAll('ytd-consent-bump-v2-lightbox, tp-yt-iron-overlay-backdrop')].forEach(e=>e.remove())")
        time.sleep(1)
    t.ok("youtube: the player is what lies under its centre", sv.ev(tab, under))
    h = pc("hits")
    page = h["pages"][0]["rect"]
    x = page[0] + rect[0] + rect[2] / 2
    y = page[1] + rect[1] + rect[3] / 2
    plan = [("app in the back", "deactivate")] * 4 + [("another Broadway window key", "otherkey")] * 2
    for i, (state, how) in enumerate(plan):
        pc(how)
        before = sv.ev(tab, "document.querySelector('video').paused")
        c = pc("click", x=x, y=y, wait=1.5)
        after = sv.ev(tab, "document.querySelector('video').paused")
        h = pc("hits")
        t.ok(f"youtube, {state}, click {i + 1}: the video flips between playing and paused", before != after,
             (before, after, c["hit"], h["state"]["pageSubviews"], h["misses"][:2]))
        ROWS.append({"state": f"youtube, {state}, click {i + 1}", "pausedBefore": before, "pausedAfter": after, "hit": c["hit"],
                     "key": c["before"]["key"], "appActive": c["before"]["appActive"], "subviews": h["state"]["pageSubviews"],
                     "missed": sum(p["missed"] for p in h["pages"])})
        time.sleep(3.5 if after else 2)
    pc("otherkey", close=True)
    sv.quit()


def states(t, how):
    pc(how)
    a = sv.sp("open", url=f"{BASE}/a")["resultID"]
    time.sleep(1.5)
    check(t, f"{how}: sidebar docked", a)

    pc(how); pc("resign")
    check(t, f"{how}: first responder taken away", a)

    pc(how); e = pc("edit"); q = pc("quitfield")
    t.ok(f"{how}: the address field took the keys while open", e["responder"] not in ("PageView", "NSWindow"), e["responder"])
    check(t, f"{how}: address field opened and quit", a)

    pc(how); sv.cmd({"do": "ui", "sidebar": False}); time.sleep(0.6)
    check(t, f"{how}: sidebar hidden", a)
    sv.cmd({"do": "ui", "sidebar": True}); time.sleep(0.6)

    pc(how); sv.cmd({"do": "ui", "folded": True}); time.sleep(0.6)
    check(t, f"{how}: column folded", a)
    pc(how); sv.cmd({"do": "ui", "peek": True}); time.sleep(0.8)
    sv.cmd({"do": "ui", "peek": False}); time.sleep(0.1)
    check(t, f"{how}: column just back in", a)
    pc(how); check(t, f"{how}: column back in, settled", a, settle=1.0)
    sv.cmd({"do": "ui", "folded": False}); time.sleep(0.6)

    b = sv.sp("open", url=f"{BASE}/b")["resultID"]
    time.sleep(1.2)
    pc(how); sv.cmd({"do": "select", "id": a})
    check(t, f"{how}: tab switch, at once", a)
    pc(how); sv.cmd({"do": "select", "id": b}); time.sleep(0.8)
    sv.cmd({"do": "select", "id": a})
    check(t, f"{how}: tab switch, settled", a, settle=0.8)

    pc(how); sv.cmd({"do": "peek", "url": f"{BASE}/peeked"}); time.sleep(1.5)
    sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.1)
    check(t, f"{how}: peek just closed", a)
    pc(how); check(t, f"{how}: peek closed, settled", a, settle=1.0)

    sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(1.2)
    h = pc("hits")
    rects = {p["page"].rsplit("/", 1)[-1]: p["rect"] for p in h["pages"]}
    for name, tab in (("a", a), ("b", b)):
        r = rects.get(name)
        if not r:
            t.ok(f"{how}: split, page {name} is on show", False, list(rects))
            continue
        pc(how); check(t, f"{how}: split, page {name}", tab, at=(r[0] + r[2] / 2, r[1] + r[3] / 2))
    pc("otherkey", close=True)


def main():
    t = sv.T()
    try:
        if "youtube" in sys.argv[1:]:
            youtube(t)
            return 1 if t.failed else 0
        for how in [a for a in sys.argv[1:] if a in ("deactivate", "otherkey")] or ["deactivate", "otherkey"]:
            sv.setup(sidebar=True, splitView=True)
            started()
            sv.cmd({"do": "resize", "width": 1200, "height": 800, "steps": 1})
            states(t, how)
            sv.quit()
    finally:
        t.done()
        sv.finish()
        import json
        print("ROWS " + json.dumps(ROWS))
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

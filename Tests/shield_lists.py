#!/usr/bin/env python3
"""Filter lists reach pages, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/shield_lists.py`. A local
server stands in for the list's publisher and for two sites, so nothing leaves
the Mac: `shield fetch` downloads, converts, compiles and swaps the lists in
as a weekly refresh does, and a relaunch has to find them again without asking.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-shield")
t = sv.T()
hits = {"list": 0, "fresh": 0}
LIST = """[Adblock Plus 2.0]
! Title: Fixture
||localhost^$image,third-party
/banner/ad^
@@/banner/ad-allowed.png
##.ad-box
"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/list.txt":
            hits["list"] += 1
            if self.headers.get("If-None-Match") == '"one"':
                hits["fresh"] += 1
                self.send_response(304)
                self.end_headers()
                return
            body = LIST.encode()
            self.send_response(200)
            self.send_header("ETag", '"one"')
        elif path == "/page":
            port = self.server.server_port
            body = f"""<!doctype html><title>page</title>
<div class=ad-box id=box>ad</div>
<img id=third src="http://localhost:{port}/third.png">
<img id=path src="/banner/ad">
<img id=allowed src="/banner/ad-allowed.png">
<img id=own src="/own.png">""".encode()
            self.send_response(200)
        elif path.endswith(".png") or path == "/banner/ad":
            body = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000"
                                 "1f15c4890000000d49444154789c6360000002000001e221bc330000000049454e44ae426082")
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        else:
            body = b"<!doctype html><title>other</title>hello"
            self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def shield(action, *values): return sv.cmd({"do": "shield", "action": action, "values": list(values)})


def loaded(id):
    time.sleep(0.8)
    return sv.cmd({"do": "eval", "id": id, "js": """JSON.stringify({
      third: document.getElementById('third').naturalWidth,
      path: document.getElementById('path').naturalWidth,
      allowed: document.getElementById('allowed').naturalWidth,
      own: document.getElementById('own').naturalWidth,
      box: getComputedStyle(document.getElementById('box')).display})"""})


def page_state(id):
    answer = loaded(id)
    value = answer.get("value")
    return json.loads(value) if isinstance(value, str) else value


def open_page():
    id = sv.cmd({"do": "open", "url": f"{BASE}/page"})["id"]
    sv.cmd({"do": "wait", "id": id, "seconds": 10})
    return id


try:
    sv.setup(splitView=True)
    sv.launch()

    before = shield("state")
    t.ok("Broadway's own short list is there before any download", before["fallback"] and before["downloaded"] == 0, before)
    id = open_page()
    state = page_state(id)
    t.ok("the fixture is not blocked by the short list", state["third"] == 1 and state["path"] == 1, state)

    fetched = shield("fetch", f"{BASE}/list.txt")
    t.ok("the list was fetched and compiled", fetched["downloaded"] >= 1 and fetched["rules"] >= 3, fetched)

    sv.cmd({"do": "go", "id": id, "url": f"{BASE}/page?again"})
    sv.cmd({"do": "wait", "id": id, "seconds": 10})
    state = page_state(id)
    t.ok("a third-party image is blocked", state["third"] == 0, state)
    t.ok("a path rule blocks", state["path"] == 0, state)
    t.ok("an exception in the same list lets one through", state["allowed"] == 1, state)
    t.ok("first-party images load", state["own"] == 1, state)
    t.ok("a cosmetic rule hides the box", state["box"] == "none", state)

    other = sv.cmd({"do": "open", "url": f"http://localhost:{srv.server_port}/landing"})["id"]
    sv.cmd({"do": "wait", "id": other, "seconds": 10})
    text = sv.cmd({"do": "text", "id": other}).get("text", "")
    t.ok("a page you open on a blocked host still opens", "hello" in text, text)
    sv.cmd({"do": "close", "id": other})

    shield("pause", "127.0.0.1")
    sv.cmd({"do": "go", "id": id, "url": f"{BASE}/page?paused"})
    sv.cmd({"do": "wait", "id": id, "seconds": 10})
    state = page_state(id)
    t.ok("off for this site lets everything through", state["third"] == 1 and state["path"] == 1 and state["box"] != "none", state)
    shield("pause", "127.0.0.1", "off")
    sv.cmd({"do": "go", "id": id, "url": f"{BASE}/page?back"})
    sv.cmd({"do": "wait", "id": id, "seconds": 10})
    state = page_state(id)
    t.ok("back on, it blocks again", state["third"] == 0, state)

    again = shield("fetch", f"{BASE}/list.txt")
    t.ok("an unchanged list comes back 304 and is kept", hits["fresh"] == 1 and again["downloaded"] == fetched["downloaded"], (hits, again))

    for _ in range(3):
        shield("reloaded", "offer.example")
    t.ok("three reloads offer to allow ads", shield("state")["offer"] == "offer.example")

    sv.quit()
    count = hits["list"]
    sv.launch()
    time.sleep(1)
    restored = shield("state")
    t.ok("a relaunch finds the compiled lists", restored["downloaded"] == fetched["downloaded"], restored)
    t.ok("a relaunch in a test run downloads nothing", hits["list"] == count, hits)
    id = open_page()
    state = page_state(id)
    t.ok("the restored lists block", state["third"] == 0 and state["box"] == "none", state)
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)

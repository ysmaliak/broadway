#!/usr/bin/env python3
"""Device Mode, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/device_mode.py`. A local page
reports its width and the user agent the server was sent.
"""
import os
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-device")
t = sv.T()
seen = []


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/page"):
            seen.append(self.headers.get("User-Agent", ""))
        body = b"<!doctype html><title>device</title><p>device</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def device(action="state", *values):
    return sv.cmd({"do": "device", "action": action, "values": list(values)})


def until(check, within=6):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def main():
    sv.setup()
    sv.launch()
    try:
        tab = sv.page("page")
        sv.cmd({"do": "select", "id": tab})
        time.sleep(0.5)
        wide = sv.ev(tab, "innerWidth")
        t.ok("not in device mode to begin with", not device()["on"], device())

        device("toggle")
        t.ok("the page narrows to a phone", until(lambda: sv.ev(tab, "innerWidth") == 393), sv.ev(tab, "innerWidth"))
        t.ok("the page reads a phone's agent", until(lambda: "iPhone" in sv.ev(tab, "navigator.userAgent")))
        t.ok("the server was told too", until(lambda: "iPhone" in seen[-1]), seen[-1:])
        shot = os.environ.get("DEVICE_PNG")
        if shot:
            time.sleep(0.6)
            sv.cmd({"do": "picture", "path": shot})

        device("rotate")
        t.ok("rotated", until(lambda: sv.ev(tab, "innerWidth") > 393), device())
        before = len(seen)
        device("rotate")
        time.sleep(0.5)
        t.ok("rotating keeps the page: same agent, no reload", len(seen) == before, seen[before:])

        device("set", "Pixel 8")
        t.ok("another device", until(lambda: sv.ev(tab, "innerWidth") == 412), device())
        t.ok("with its agent", until(lambda: "Android" in sv.ev(tab, "navigator.userAgent")))

        state = device("size", "300", "400")
        t.ok("a size of your own", state["name"] == "Custom", state)
        t.ok("the page follows", until(lambda: sv.ev(tab, "innerWidth") == 300), sv.ev(tab, "innerWidth"))

        device("toggle")
        t.ok("off, the page fills the stage", until(lambda: sv.ev(tab, "innerWidth") == wide), sv.ev(tab, "innerWidth"))
        t.ok("off, the Mac's agent again", until(lambda: "Macintosh" in sv.ev(tab, "navigator.userAgent")))

        other = sv.page("other")
        sv.cmd({"do": "select", "id": other})
        time.sleep(0.5)
        t.ok("another tab is not touched", sv.ev(other, "innerWidth") == wide and not device()["on"], device())
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

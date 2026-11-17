#!/usr/bin/env python3
"""The Dock bar while a download is under way, checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/dock_progress.py`. The app
starts hidden in a world of its own. A small server in this script sends a
file slowly, with its size known. The bench lets the bar set the probe's
own Dock tile, reads the bar going up, cancels the download, and reads the
bar gone and the tile handed back to the Dock.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("dock-progress")

HOME = f"http://127.0.0.1:{sv.srv.server_port}"
NAME = "slow-dock.bin"
SIZE = 6 * 1024 * 1024
CHUNK = 64 * 1024


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/file"):
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(SIZE))
            self.send_header("Content-Disposition", f'attachment; filename="{NAME}"')
            self.end_headers()
            sent = 0
            try:
                while sent < SIZE:
                    self.wfile.write(b"d" * CHUNK)
                    self.wfile.flush()
                    sent += CHUNK
                    time.sleep(0.12)
            except OSError:
                pass
            return
        html = (f'<!doctype html><meta charset=utf-8><title>dock</title>'
                f'<a id="go" href="/file" style="display:block;font-size:40px;line-height:80px">Download</a>').encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def dock(action="state"):
    return sv.cmd({"do": "dock", "action": action})


def trace(**more):
    return sv.cmd({"do": "downloadtrace", **more})


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        first = dock()
        t.ok("a test world leaves the Dock tile alone", not first["drivesTile"] and not first["tileSet"], first)
        t.ok("no bar before a download", not first["shown"], first)
        dock("tile")
        tab = sv.sp("open", url=f"{HOME}/page")["resultID"]
        time.sleep(1.2)
        sv.cmd({"do": "tap", "id": tab, "selector": "#go"})
        seen = []
        tiles = []
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and len(set(p for p in seen if p is not None)) < 4:
            got = dock()
            if got["shown"]:
                seen.append(got["percent"])
                tiles.append(got["tileSet"])
            time.sleep(0.3)
        percents = [p for p in seen if p is not None]
        t.ok("the bar shows while the download is under way", bool(percents), seen)
        t.ok("the bar goes up", len(set(percents)) >= 3 and percents == sorted(percents), percents)
        t.ok("the bar is short of full before the file is in", bool(percents) and percents[-1] < 100, percents)
        t.ok("the bench's tile carries the bar", bool(tiles) and all(tiles), tiles)
        entries = trace()["entries"]
        t.ok("the download is in the list", any(e["name"] == NAME for e in entries), entries)
        trace(cancel=NAME)
        gone = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            got = dock()
            if not got["shown"]:
                gone = got
                break
            time.sleep(0.1)
        t.ok("cancelling it takes the bar away", gone is not None, dock())
        t.ok("and hands the tile back to the Dock", gone is not None and not gone["tileSet"], gone)
        t.ok("nothing is left under way", gone is not None and gone["running"] == 0, gone)
        dock("leave")
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

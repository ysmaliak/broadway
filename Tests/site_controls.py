#!/usr/bin/env python3
"""Site Controls, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/site_controls.py`. The card
opens and closes by command, leaves when the tab changes, and every step has rows.
"""
import shutil
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-controls")
t = sv.T()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>page</title><p>page</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def controls(action="state", *values):
    return sv.cmd({"do": "controls", "action": action, "values": list(values)})


def shown(on, within=3):
    end = time.monotonic() + within
    while time.monotonic() < end:
        if controls()["shown"] is on:
            return True
        time.sleep(0.05)
    return controls()["shown"] is on


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    out = Path(tempfile.mkdtemp())
    sv.setup()
    sv.launch()
    try:
        a = sv.cmd({"do": "open", "url": f"{base}/a"})
        b = sv.cmd({"do": "open", "url": f"{base}/b"})
        sv.cmd({"do": "select", "id": b.get("id")})
        time.sleep(1)
        t.ok("closed to begin with", not controls()["shown"])
        controls("toggle")
        t.ok("toggle opens it", shown(True))
        controls("toggle")
        t.ok("toggle closes it", shown(False))
        controls("toggle")
        t.ok("opens again before switching tabs", shown(True))
        sv.cmd({"do": "select", "id": a.get("id")})
        time.sleep(0.3)
        t.ok("a change of tab closes it", not controls()["shown"])
        for step in ("front", "security", "permissions", "hidden", "translate", "more", "developer"):
            path = out / f"{step}.json"
            answer = sv.cmd({"do": "site", "path": str(path), "step": step})
            t.ok(f"{step} has rows", path.exists() and bool(answer.get("items")), answer)
    finally:
        sv.quit()
        sv.finish()
        server.shutdown()
        server.server_close()
        shutil.rmtree(out, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


main()

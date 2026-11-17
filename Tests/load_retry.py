#!/usr/bin/env python3
"""A page that failed because nothing answered loads by itself once the
network comes back, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/load_retry.py`. It runs in
split_view.py's harness, in a world of its own, started hidden and removed
afterwards. The bench's word stands in for the network: nothing here turns
a network off.
"""
import socket
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("load-retry")


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Back again</title><p>Here</p>"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def until(check, within=20):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def network(action="state"):
    return sv.cmd({"do": "network", "action": action})


def row(tid):
    return next((x for x in sv.sp("state")["tabs"] if x["id"] == tid), {})


def main():
    t = sv.T()
    server = None
    try:
        sv.setup()
        sv.launch()
        port = free_port()
        tid = sv.sp("open", url=f"http://127.0.0.1:{port}/page")["resultID"]
        waited = until(lambda: tid in network()["waiting"])
        t.ok("a page nothing answered is waiting for the network", waited, network())

        server = ThreadingHTTPServer(("127.0.0.1", port), H)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        time.sleep(1.0)
        t.ok("nothing loads before the network's word", sv.ev(tid, "document.title") != "Back again")

        network("away")
        network("back")
        loaded = until(lambda: sv.ev(tid, "document.title") == "Back again")
        t.ok("the network's return loads it without Try Again", loaded, row(tid))
        t.ok("and it is no longer waiting", tid not in network()["waiting"], network())
    finally:
        if server:
            server.shutdown()
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

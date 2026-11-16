#!/usr/bin/env python3
"""Developer Mode, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/developer_mode.py`. A local
server stands in for your dev server: its first load offers Developer Mode,
and with it on, errors and requests are read from a page that makes both.
"""
import os
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-dev")
t = sv.T()

PAGE = b"""<!doctype html><title>dev</title><script>
console.error('from the console');
setTimeout(function () { nothing.here(); }, 50);
fetch('/api/fine').then(r => r.text());
fetch('/api/broken', {method: 'POST', headers: {'Authorization': 'Bearer zzz', 'Content-Type': 'text/plain'}, body: 'hello'});
var x = new XMLHttpRequest(); x.open('GET', '/api/x'); x.send();
</script><img src="/missing.png"><p>dev</p>"""


class H(BaseHTTPRequestHandler):
    def respond(self):
        path = self.path.split("?")[0]
        status = 200
        body = PAGE if path.endswith("page") else b"{}"
        if path in ("/api/broken", "/missing.png"):
            status = 500 if path == "/api/broken" else 404
        self.send_response(status)
        self.send_header("Content-Type", "text/html" if body is PAGE else "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = respond

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.respond()

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def dev(action="state", *values):
    return sv.cmd({"do": "dev", "action": action, "values": list(values)})


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
        key = sv.BASE.replace("http://", "")
        t.ok("a local page offers Developer Mode", until(lambda: dev()["offer"] == key), dev())
        t.ok("off until asked", not dev()["on"], dev())
        t.ok("no script in the page until then", sv.ev(tab, "window.__broadwayDeveloper === undefined") is True)

        dev("accept")
        t.ok("on for the server", until(lambda: dev()["on"]), dev())
        t.ok("the offer goes", dev()["offer"] == "", dev())
        t.ok("reloaded with its script", until(lambda: sv.ev(tab, "window.__broadwayDeveloper") is True))
        t.ok("the page's errors arrive", until(lambda: dev()["errors"] >= 3), dev())
        state = dev()
        messages = " | ".join(state["messages"])
        t.ok("console.error", "from the console" in messages, messages)
        t.ok("an uncaught error", "nothing" in messages, messages)
        t.ok("a resource that failed", "missing.png" in messages, messages)
        t.ok("requests arrive", until(lambda: dev()["requests"] >= 3), dev())
        urls = " | ".join(dev()["urls"])
        t.ok("fetch", "/api/fine" in urls, urls)
        t.ok("xhr", "/api/x" in urls, urls)
        t.ok("the count is live and counts failures", dev()["count"] >= 4, dev())

        agent = dev("copy", "/api/broken")["copied"]
        t.ok("copied for an agent: status", "returned 500" in agent, agent)
        t.ok("copied for an agent: no token", "zzz" not in agent and "Authorization" not in agent, agent)
        curl = dev("curl", "/api/broken")["copied"]
        t.ok("cURL has method and body", "-X POST" in curl and "--data-raw 'hello'" in curl, curl)
        t.ok("cURL has the header", "Bearer zzz" in curl, curl)

        t.ok("the panel opens", dev("panel")["panel"] is True, dev())
        shot = os.environ.get("DEV_PNG")
        if shot:
            time.sleep(0.6)
            sv.cmd({"do": "picture", "path": shot})
        t.ok("and closes", dev("panel")["panel"] is False, dev())

        sv.cmd({"do": "go", "id": tab, "url": f"{sv.BASE}/other"})
        t.ok("a new page starts a new list", until(lambda: dev()["errors"] == 0), dev())
        dev("off")
        t.ok("off stays off", until(lambda: not dev()["on"]), dev())
        t.ok("the script is gone after the reload", until(lambda: sv.ev(tab, "window.__broadwayDeveloper === undefined") is True))
        t.ok("the server stays listed", key in dev()["servers"], dev())
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

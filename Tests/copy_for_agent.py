#!/usr/bin/env python3
"""Copy for Agent, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/copy_for_agent.py`. On a test
run the text is kept in the app, never on the clipboard of whoever is working
beside it.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-agent")
t = sv.T()
PAGE = b"""<!doctype html><title>A guide</title><main><h1>Heading</h1><p id=p>First paragraph of words.</p>
<p>Second paragraph.</p><input id=f value="typed secret"></main>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def agent(action="state"):
    return sv.cmd({"do": "agent", "action": action})["copied"]


def until(check, within=5):
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
        tab = sv.page("guide")
        sv.cmd({"do": "select", "id": tab})
        time.sleep(0.5)
        agent("copy")
        t.ok("the page is copied", until(lambda: "First paragraph" in agent()), agent())
        text = agent()
        t.ok("with its title", text.startswith("Page: A guide"), text)
        t.ok("with its address", f"URL: {sv.BASE}/guide" in text, text)
        t.ok("no form values", "typed secret" not in text, text)

        sv.ev(tab, "getSelection().selectAllChildren(document.getElementById('p')), 1")
        agent("copy")
        t.ok("a selection is copied alone", until(lambda: "Selected text:" in agent()), agent())
        t.ok("not the rest of the page", "Second paragraph" not in agent(), agent())
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

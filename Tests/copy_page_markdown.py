#!/usr/bin/env python3
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-markdown")
t = sv.T()
requests = []
PAGES = {
    "/story": b"""<!doctype html><title>Rivers in Spring</title><nav><a href="/">Home</a></nav>
<article><h1>Rivers in Spring</h1>
<p id=p>Snow melts in <strong>April</strong>, and the rivers rise fast. Read the <a href="/data">flow data</a> for each year.</p>
<p>Banks move a little every year, and the water carries silt for many miles downstream to the sea.</p>
<img src="/river.png" alt="River">
<pre><code class="language-sh">broadway tabs list</code></pre>
<table><tr><th>Month</th><th>Flow</th></tr><tr><td>April</td><td>High</td></tr></table>
</article><footer>Footer words</footer>""",
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        body = PAGES.get(self.path.split("?")[0], b"\x89PNG")
        self.send_response(200)
        self.send_header("Content-Type", "text/html" if self.path in PAGES else "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def markdown(action="state", window=None):
    return sv.cmd({"do": "agent", "action": action, **({"window": window} if window else {})})


def until(check, within=5):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def main():
    before = clipboard()
    sv.setup()
    sv.launch()
    try:
        for pid in sv.pids():
            state = subprocess.run(["ps", "eww", "-p", pid, "-o", "command="], capture_output=True, text=True).stdout
            t.ok("test process has its own SEARCH_PROBE world", f"SEARCH_PROBE={sv.W}" in state)
        tab = sv.page("story")
        sv.cmd({"do": "select", "id": tab})
        time.sleep(0.5)
        markdown("markdown")
        t.ok("the page is copied", until(lambda: "Snow melts" in markdown()["markdown"]), markdown())
        text = markdown()["markdown"]
        t.ok("with its title as a heading", text.startswith("# Rivers in Spring\n\n"), text)
        t.ok("with its source", f"Source: {sv.BASE}/story" in text, text)
        t.ok("bold and links", "**April**" in text and f"[flow data]({sv.BASE}/data)" in text, text)
        t.ok("an image with its full address", f"![River]({sv.BASE}/river.png)" in text, text)
        t.ok("code fenced", "```sh\nave tabs list\n```" in text, text)
        t.ok("a table", "| Month | Flow |\n| --- | --- |\n| April | High |" in text, text)
        t.ok("no navigation or footer", "Home" not in text and "Footer words" not in text, text)
        t.ok("says Copied as Markdown", markdown()["announced"] == "Copied as Markdown", markdown())

        sv.ev(tab, "getSelection().selectAllChildren(document.getElementById('p')), 1")
        markdown("markdown")
        t.ok("a selection is copied alone", until(lambda: not markdown()["markdown"].startswith("#")), markdown())
        text = markdown()["markdown"]
        t.ok("as Markdown", text.startswith("Snow melts in **April**") and "Banks move" not in text, text)

        private = sv.cmd({"do": "open", "url": f"{sv.BASE}/story?private", "private": True})["id"]
        sv.cmd({"do": "wait", "id": private})
        time.sleep(0.8)
        sv.cmd({"do": "select", "id": private})
        time.sleep(0.3)
        count = len(requests)
        n = next(w["n"] for w in sv.cmd({"do": "windows"})["windows"] if w["private"])
        markdown("markdown", window=n)
        t.ok("a private tab copies too", until(lambda: f"Source: {sv.BASE}/story?private" in markdown(window=n)["markdown"]), markdown(window=n))
        t.ok("without asking the network", len(requests) == count, requests[count:])
        t.ok("the real clipboard is untouched", clipboard() == before)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

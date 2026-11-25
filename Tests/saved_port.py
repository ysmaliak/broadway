#!/usr/bin/env python3
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("saved-port")

HOST = "dev.localhost"

LOGIN = """<!doctype html><title>sign in</title>
<form id="f" action="/done" method="post"><input id="u" name="email" autocomplete="username">
<input id="p" name="password" type="password" autocomplete="current-password">
<button type="submit">Sign in</button></form>"""

DONE = "<!doctype html><title>home</title><h1>Signed in</h1>"


class H(BaseHTTPRequestHandler):
    def send(self, body):
        body = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        self.send(LOGIN if self.path.split("?")[0] == "/login" else DONE)

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send(DONE)

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    port = srv.server_port
    base = f"http://{HOST}:{port}"
    try:
        sv.setup(); sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)
        tab = sv.sp("open", url=f"{base}/login")["resultID"]
        sv.sp("select", id=tab); time.sleep(1.2)
        sv.ev(tab, "var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;"
                   "var u = document.getElementById('u'); u.focus(); set.call(u, 'pat@example.com'); u.dispatchEvent(new Event('input', {bubbles: true}));"
                   "var p = document.getElementById('p'); p.focus(); set.call(p, 'sp-made-up-1'); p.dispatchEvent(new Event('input', {bubbles: true})); true")
        sv.ev(tab, "document.activeElement.blur(); document.querySelector('button').click(); true")
        time.sleep(4)
        t.ok("the page moved on", sv.ev(tab, "location.pathname") == "/done")
        r = acc()
        t.ok("the save question is up for pat", r.get("offer", {}).get("user") == "pat@example.com", r)
        r = acc(keep=True); time.sleep(1.5)
        r = acc()
        kept = [x for x in r.get("used", []) if x.get("user") == "pat@example.com"]
        t.ok("pat is kept", len(kept) == 1, r)
        t.ok(f"the kept sign-in records the page's port {port}", kept and kept[0].get("port") == port, kept)
    finally:
        try:
            r = acc(forget=True)
            t.ok("this world's logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's logins forgotten", False, e)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import os
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("saved-already")

HOST = "id.localhost"
KEPT = "sa-made-up-1"

LOGIN = """<!doctype html><title>password</title>
<form id="f" action="/done" method="post"><label for="p">Password</label>
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


def used(r, user):
    return next((x.get("used", 0) for x in r.get("used", []) if x.get("user") == user and x.get("host") == HOST), None)


def open_login(base):
    tab = sv.sp("open", url=f"{base}/login")["resultID"]
    sv.sp("select", id=tab); time.sleep(1.2)
    return tab


def send(tab, password, wait=4.0):
    sv.ev(tab, "var b = document.getElementById('p'); b.focus();"
               "Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(b, '%s');"
               "b.dispatchEvent(new Event('input', {bubbles: true})); true" % password)
    sv.ev(tab, "document.activeElement.blur(); document.querySelector('button').click(); true")
    time.sleep(wait)


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://{HOST}:{srv.server_port}"
    csv = f"{sv.SUPPORT}-saved-already.csv"
    try:
        sv.setup(); sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)
        with open(csv, "w") as f:
            f.write(f"url,username,password\n{base}/,pat,{KEPT}\n")
        r = sv.cmd({"do": "import-file", "path": csv})
        t.ok("a made-up login for pat in this world's keychain items", r.get("kept") == 1, r)
        before = used(acc(), "pat")
        t.ok("pat is kept for the page's host", before is not None, acc())

        a = open_login(base)
        send(a, KEPT)
        t.ok("the page moved on", sv.ev(a, "location.pathname") == "/done")
        r = acc()
        t.ok("the kept password sent with no name brings no save question", not r.get("offer"), r)
        after = used(r, "pat")
        t.ok("pat's last-used time moved", after is not None and after > (before or 0), [before, after])
        t.ok("nothing new kept", r.get("kept") == 1, r)

        c = open_login(base)
        sv.ev(c, "document.getElementById('p').focus(); true"); time.sleep(1.0)
        r = acc()
        rows = [x.get("login") for x in r.get("rows", [])]
        t.ok("the list under the box offers pat", r.get("shown") and "pat" in rows, r)
        time.sleep(0.6)
        acc(pick=rows.index("pat") if "pat" in rows else 0); time.sleep(0.8)
        t.ok("a pick fills the box", sv.ev(c, "document.getElementById('p').value") == KEPT)
        picked = used(acc(), "pat")
        sv.ev(c, "document.activeElement.blur(); document.querySelector('button').click(); true"); time.sleep(4)
        t.ok("the page moved on", sv.ev(c, "location.pathname") == "/done")
        r = acc()
        t.ok("signing in with the pick brings no save question", not r.get("offer") and r.get("kept") == 1, r)
        t.ok("the submit after a pick reads nothing back: pat is not touched again",
             picked is not None and used(r, "pat") == picked, [picked, used(r, "pat")])

        b = open_login(base)
        send(b, "sa-another")
        r = acc()
        t.ok("another password with no name brings the Save question",
             r.get("offer", {}).get("user") == "" and r["offer"].get("host") == HOST
             and r["offer"].get("changed") is False, r)
    finally:
        try:
            r = acc(forget=True)
            t.ok("this world's logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's logins forgotten", False, e)
        if os.path.exists(csv): os.remove(csv)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Use Strong Password under a new password box, in a hidden test world.

Build first (`./build.sh`), then `python3 Tests/strong_password.py`. A local
sign-up page on an invented host: the caret in its new password box brings
the row, taking it fills both boxes with one value and keeps the login in
this world's own keeping, and sending the form brings no save bar and gives
the login the name from the form. A sign-in page, a private window and an
agent's tab bring no row, and an agent's snapshot never carries the value.
With a folder argument, stills of the card in light and dark go there.
"""
import os
import re
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("spw")
ROOT = Path(__file__).resolve().parents[1]
BROADWAY = str(ROOT / "build" / "Broadway.app" / "Contents" / "Helpers" / "broadway")
HOST = "join.localhost"
NAME = "pat@example.test"
SHAPE = re.compile(r"^[A-Za-z2-9]{6}-[A-Za-z2-9]{6}-[A-Za-z2-9]{6}$")

JOIN = """<!doctype html><title>Make an account</title>
<form id="f" action="/welcome" method="post">
<label for="e">Email</label> <input id="e" name="email" type="email" autocomplete="username">
<label for="p">Password</label> <input id="p" name="password" type="password" autocomplete="new-password">
<label for="c">Password again</label> <input id="c" name="again" type="password" autocomplete="new-password">
<button type="submit">Make Account</button></form>
<script>window.heard = 0; document.getElementById('p').addEventListener('input', function () { window.heard++; });</script>"""

PAIR = """<!doctype html><title>Join</title>
<form action="/welcome" method="post">
<input id="e" name="email" type="email">
<input id="p" name="password" type="password">
<input id="c" name="again" type="password">
<button type="submit">Join</button></form>"""

SHORT = """<!doctype html><title>Join</title>
<form action="/welcome" method="post">
<input id="e" name="email" type="email">
<input id="p" name="password" type="password" autocomplete="new-password" maxlength="12">
<button type="submit">Join</button></form>"""

TINY = """<!doctype html><title>Join</title>
<form action="/welcome" method="post">
<input id="e" name="email" type="email">
<input id="p" name="pin" type="password" autocomplete="new-password" maxlength="6">
<button type="submit">Join</button></form>"""

LOGIN = """<!doctype html><title>Sign in</title>
<form action="/welcome" method="post">
<input id="e" name="email" type="email" autocomplete="username">
<input id="p" name="password" type="password" autocomplete="current-password">
<button type="submit">Sign In</button></form>"""

DONE = "<!doctype html><title>Welcome</title><h1>Welcome</h1>"
PAGES = {"/join": JOIN, "/pair": PAIR, "/short": SHORT, "/tiny": TINY, "/login": LOGIN}


class H(BaseHTTPRequestHandler):
    def send(self, body):
        body = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        self.send(PAGES.get(self.path.split("?")[0], DONE))

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send(DONE)

    def log_message(self, *a): pass


def acc(**f): return sv.cmd({"do": "accounts", **f})


def strong_rows(r): return [x for x in r.get("rows", []) if x.get("strong")]


def open_page(url):
    tab = sv.sp("open", url=url)["resultID"]
    sv.sp("select", id=tab); time.sleep(1.2)
    return tab


def focus(tab, box):
    sv.ev(tab, "document.getElementById('%s').focus(); true" % box); time.sleep(1.0)


def broadway(*words, agent=None):
    env = dict(os.environ)
    env.pop("BROADWAY_AGENT", None)
    if agent: env["BROADWAY_AGENT"] = agent
    return subprocess.run([BROADWAY, "--socket", f"{sv.SUPPORT}/broadway.sock", *words], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=60, env=env)


def stills(base, out, t):
    out.mkdir(parents=True, exist_ok=True)
    for look in ["light", "dark"]:
        sv.cmd({"do": "ui", "look": look}); time.sleep(0.8)
        tab = open_page(f"{base}/join")
        focus(tab, "e"); focus(tab, "p")
        path = out / f"card-{look}.png"
        r = acc(picture=str(path))
        t.ok(f"a still of the card in {look}, from window {r.get('window')}", bool(strong_rows(r)) and path.exists(), r)
        sv.sp("close", id=tab)
    sv.cmd({"do": "ui", "look": "system"})


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://{HOST}:{srv.server_port}"
    out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
    try:
        sv.setup(**{"agents.on": True}); sv.launch()
        r = acc(forget=True)
        t.ok("this world keeps nothing to begin with", r.get("kept") == 0, r)

        a = open_page(f"{base}/join")
        focus(a, "e")
        t.ok("the email box brings no row", not strong_rows(acc()), acc())
        focus(a, "p")
        r = acc()
        t.ok("the new password box brings one row, Use Strong Password", r.get("shown") and r.get("rows") == [{"strong": True}], r)
        time.sleep(0.6)
        acc(pick=0); time.sleep(1.5)
        one = sv.ev(a, "document.getElementById('p').value")
        two = sv.ev(a, "document.getElementById('c').value")
        t.ok("taking it fills the box with a strong password", bool(one) and SHAPE.match(one or "") is not None, one)
        t.ok("and the second box with the same value", one == two, (one, two))
        t.ok("the page's own script heard it", (sv.ev(a, "window.heard") or 0) >= 1)
        r = acc()
        t.ok("the login is kept at once, under no name yet", r.get("kept") == 1 and r.get("users") == [""], r)
        t.ok("the row does not come back for the filled box", not strong_rows(r), r)

        snap = broadway("snapshot", "--tab", a)
        t.ok("an agent's snapshot of that tab never carries the password",
             bool(one) and one not in snap.stdout and one not in snap.stderr, snap.returncode)
        if snap.returncode == 0:
            t.ok("and shows the filled boxes as hidden", snap.stdout.count("value hidden") >= 2, snap.stdout[-600:])
        read = broadway("read", "--tab", a)
        print("  agent snapshot of the person's tab:", snap.returncode, (snap.stdout + snap.stderr).strip()[:160].replace("\n", " | "))
        t.ok("an agent's read of that tab never carries the password", bool(one) and one not in read.stdout + read.stderr, read.returncode)

        sv.ev(a, """var e = document.getElementById('e');
          Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(e, '%s');
          e.dispatchEvent(new Event('input', {bubbles: true}));
          document.activeElement.blur(); document.querySelector('button').click(); true""" % NAME)
        time.sleep(4)
        t.ok("the page moved on", sv.ev(a, "location.pathname") == "/welcome")
        r = acc()
        t.ok("sending the form brings no save bar", not r.get("offer"), r)
        t.ok("the kept login has the name from the form", r.get("kept") == 1 and r.get("users") == [NAME], r)
        sv.sp("close", id=a)

        b = open_page(f"{base}/pair")
        focus(b, "p")
        t.ok("two password boxes and no current one bring the row", bool(strong_rows(acc())), acc())
        sv.ev(b, "document.getElementById('p').value = 'typed'; true")
        focus(b, "e"); focus(b, "p")
        t.ok("a box that is not empty brings no row", not strong_rows(acc()), acc())
        sv.sp("close", id=b)

        c = open_page(f"{base}/short")
        focus(c, "p")
        r = acc()
        t.ok("a box that takes twelve brings the row", bool(strong_rows(r)), r)
        time.sleep(0.6)
        acc(pick=0); time.sleep(1.5)
        short = sv.ev(c, "document.getElementById('p').value") or ""
        t.ok("and gets twelve characters with no dashes", len(short) == 12 and "-" not in short, short)
        sv.sp("close", id=c)

        d = open_page(f"{base}/tiny")
        focus(d, "p")
        t.ok("a box that takes fewer than eight brings no row", not strong_rows(acc()), acc())
        sv.sp("close", id=d)

        e = open_page(f"{base}/login")
        focus(e, "p")
        r = acc()
        t.ok("a sign-in's password box brings no row", not strong_rows(r), r)
        sv.sp("close", id=e)

        f = sv.cmd({"do": "open", "url": f"{base}/join", "private": True})["id"]
        sv.cmd({"do": "select", "id": f}); time.sleep(1.2)
        focus(f, "p")
        r = acc(id=f)
        t.ok("a private window brings no row", not strong_rows(r), r)
        sv.sp("close", id=f)

        before = acc().get("kept")
        opened = broadway("open", f"{base}/join", "--json", agent=f"{sv.W}-agent")
        g = next(iter(re.findall(r'"id"\s*:\s*"([0-9A-Fa-f-]{8,})"', opened.stdout)), None)
        t.ok("an agent opened its own tab", bool(g), opened.stdout + opened.stderr)
        if g:
            sv.sp("select", id=g); time.sleep(1.2)
            focus(g, "p")
            r = acc(id=g)
            t.ok("an agent's tab brings no row", not strong_rows(r), r)
            sv.ev(g, """var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
              ['p', 'c'].forEach(function (id) { var b = document.getElementById(id); set.call(b, 'Abcdef-ghjk23-Mnpqr4');
              b.dispatchEvent(new Event('input', {bubbles: true})); }); true""")
            snap = broadway("snapshot", agent=f"{sv.W}-agent")
            t.ok("its own snapshot of a filled new password box hides the value",
                 snap.returncode == 0 and "Abcdef-ghjk23-Mnpqr4" not in snap.stdout and snap.stdout.count("value hidden") >= 2,
                 snap.stdout[-600:] + snap.stderr[-300:])
            t.ok("taking nothing in the agent's tab kept nothing", acc().get("kept") == before, (before, acc()))

        if out:
            stills(base, out, t)
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

#!/usr/bin/env python3
"""A public page reaching this Mac asks first; local pages never do.

Build first (`./build.sh`), then `python3 Tests/local_network.py`. It runs
hidden in a world of its own (local-network-tests), with split_view.py's
harness, and removes everything afterwards.

No hosts file: SEARCH_PUBLIC_HOSTS=127.0.0.1, read only on a test run, makes
Broadway count pages on 127.0.0.1 as public websites. They reach a second server
at localhost, a loopback address Broadway never counts as public.
"""
import base64
import socket
import hashlib
import os
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("local-network-tests")
if "--app" in sys.argv:
    sv.APP = str(Path(sys.argv[sys.argv.index("--app") + 1]).resolve())

hits = []
lock = threading.Lock()


def hit(what):
    with lock:
        hits.append(what)


def seen(what):
    with lock:
        return what in hits


class Local(BaseHTTPRequestHandler):
    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path == "/ws" and self.headers.get("Upgrade", "").lower() == "websocket":
            hit("ws")
            key = self.headers.get("Sec-WebSocket-Key", "")
            accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
            self.send_response(101)
            self.send_header("Upgrade", "websocket"); self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", accept); self.end_headers()
            time.sleep(1)
            return
        if path == "/local":
            hit("local page")
            body = f"""<!doctype html><title>local</title><script>
window.r = 'pending';
fetch('http://localhost:{SECOND}/hit?k=local-to-local').then(x => x.text()).then(t => r = t, e => r = 'error:' + e);
</script>"""
        elif path in ("/landed", "/typed", "/redirected"):
            hit(path[1:])
            body = f"<!doctype html><title>{path[1:]}</title>landed"
        else:
            hit(query or path)
            body = "reached"
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html" if body.startswith("<!") else "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a): pass


class Public(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.partition("?")[0]
        to = f"http://localhost:{LOCAL}"
        if path == "/redir":
            self.send_response(302); self.send_header("Location", f"{to}/redirected"); self.send_header("Content-Length", "0"); self.end_headers()
            return
        if path == "/pic.svg":
            data = b'<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>'
            self.send_response(200); self.send_header("Content-Type", "image/svg+xml")
            self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            return
        scripts = {
            "/fetch": f"fetch('{to}/hit?k=fetch').then(x => x.text()).then(t => r.fetch = t, e => r.fetch = 'error');",
            "/xhr": f"var x = new XMLHttpRequest(); x.onload = () => r.xhr = x.responseText; x.onerror = () => r.xhr = 'error'; x.open('GET', '{to}/hit?k=xhr'); x.send();",
            "/img": f"var i = new Image(); i.onload = () => r.img = 'ok'; i.onerror = () => r.img = 'error'; i.src = '{to}/hit?k=img';",
            "/frame": f"var f = document.createElement('iframe'); f.src = '{to}/hit?k=frame'; document.body.appendChild(f); r.frame = 'added';",
            "/ws": f"var w = new WebSocket('ws://localhost:{LOCAL}/ws'); w.onopen = () => r.ws = 'open'; w.onerror = () => r.ws = 'error';",
            "/nav": f"setTimeout(() => location.href = '{to}/landed', 300);",
            "/zero": f"fetch('http://0.0.0.0:{LOCAL}/hit?k=zero').then(x => x.text()).then(t => r.zero = t, e => r.zero = 'error');",
            "/six": f"fetch('http://[::1]:{SIX}/hit?k=six').then(x => x.text()).then(t => r.six = t, e => r.six = 'error');",
            "/still": "",
            "/hop": "setTimeout(() => location.href = '/redir', 300);",
        }
        body = f"""<!doctype html><title>public</title><body>
<img id=own src=/pic.svg onload="r.own = 'ok'" onerror="r.own = 'error'">
<script>window.r = {{}}; {scripts.get(path, '')}</script>"""
        data = body.encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def log_message(self, *a): pass


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Six(ThreadingHTTPServer):
    address_family = socket.AF_INET6


six_server = Six(("::1", 0), Local)
threading.Thread(target=six_server.serve_forever, daemon=True).start()
SIX = six_server.server_address[1]
local_server = serve(Local)
LOCAL = local_server.server_port
second_server = serve(Local)
SECOND = second_server.server_port
publics = [serve(Public) for _ in range(6)]
SITE = [f"http://127.0.0.1:{s.server_port}" for s in publics]
DEVELOPER = 5


def launch(public=True):
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    env = ["--env", f"SEARCH_PROBE={sv.W}"] + (["--env", "SEARCH_PUBLIC_HOSTS=127.0.0.1"] if public else [])
    subprocess.run(["open", "-n", "-g", "-j", *env, sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def state(id=None, window=None):
    return sv.cmd({"do": "localnetwork", **({"id": id} if id else {}), **({"window": window} if window else {})})


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        got = check()
        if got: return got
        time.sleep(0.2)
    return check()


def opened(url):
    id = sv.cmd({"do": "open", "url": url})["id"]
    sv.cmd({"do": "select", "id": id})
    until(lambda: sv.ev(id, "document.readyState") == "complete")
    return id


def answer(how, window=None):
    time.sleep(0.7)
    sv.cmd({"do": "answer", "with": how, **({"window": window} if window else {})})


def result(id, key, within=5):
    return until(lambda: (sv.ev(id, f"window.r && window.r.{key}") or None), within)


t = sv.T()
try:
    sv.setup()
    subprocess.run(["defaults", "write", sv.SUITE, "dev.servers", "-dict", f"127.0.0.1:{publics[DEVELOPER].server_port}", "-bool", "true"])
    launch()
    t.ok("the list compiles", until(lambda: state()["compiled"]), state())

    a = opened(f"{SITE[0]}/fetch")
    t.ok("public page: its own image loads", result(a, "own") == "ok", sv.ev(a, "JSON.stringify(window.r)"))
    t.ok("public page: the guard is on", state(a)["attached"], state(a))
    t.ok("public page: fetch to localhost fails", result(a, "fetch") == "error", sv.ev(a, "JSON.stringify(window.r)"))
    t.ok("public page: localhost never reached", not seen("k=fetch"), hits)
    asking = until(lambda: state()["asking"])
    t.ok("public page: asked, naming where it goes", asking == f"127.0.0.1 localnetwork localhost:{LOCAL}", state())

    answer("no"); time.sleep(0.3)
    st = state()
    t.ok("don't allow: the card goes", st["asking"] == "", st)
    t.ok("don't allow: remembered for the site", {"site": SITE[0], "allowed": False} in st["sites"], st["sites"])
    sv.cmd({"do": "close", "id": a})
    a = opened(f"{SITE[0]}/fetch")
    result(a, "fetch"); time.sleep(1)
    t.ok("refused site: not asked again", state()["asking"] == "", state())
    t.ok("refused site: still blocked", not seen("k=fetch") and state(a)["attached"], hits)

    st = sv.cmd({"do": "localnetwork", "id": a, "forget": SITE[0]})
    t.ok("forgotten: no longer listed", all(s["site"] != SITE[0] for s in st["sites"]), st)
    sv.cmd({"do": "close", "id": a})
    a = opened(f"{SITE[0]}/fetch")
    t.ok("forgotten: asked again", until(lambda: state()["asking"]).startswith("127.0.0.1 localnetwork"), state())
    answer("always")
    t.ok("allow: the page reloads and reaches localhost", until(lambda: seen("k=fetch")), hits)
    t.ok("allow: the fetch succeeds", until(lambda: sv.ev(a, "window.r && window.r.fetch") == "reached"), sv.ev(a, "JSON.stringify(window.r)"))
    st = state(a)
    t.ok("allow: remembered, guard off for the site", {"site": SITE[0], "allowed": True} in st["sites"] and not st["attached"], st)
    sv.cmd({"do": "close", "id": a})

    for path in ["xhr", "img", "frame", "ws", "zero", "six"]:
        b = opened(f"{SITE[1]}/{path}")
        time.sleep(1.5)
        st = state(b)
        reached = seen(f"k={path}") or (path == "ws" and seen("ws"))
        t.ok(f"{path}: blocked before it leaves", not reached and st["attached"], hits)
        reported = any((f"k={path}" in u or (path == "ws" and u.startswith("ws") and f"localhost:{LOCAL}" in u)) for u in st["blocked"])
        if path == "ws":
            print(f"  info  ws: WebKit {'reports' if reported else 'does not report'} the blocked WebSocket (see docs/local-network.md)")
        elif path == "zero":
            print(f"  info  0.0.0.0: {'reported by the list' if reported else 'refused by WebKit itself before the list'}")
        else:
            t.ok(f"{path}: WebKit reports it", reported, st["blocked"][-3:])
        sv.cmd({"do": "close", "id": b})
    if state()["asking"]: answer("no"); time.sleep(0.3)

    c = opened(f"{SITE[2]}/nav")
    asking = until(lambda: state()["asking"])
    t.ok("script navigation: asked before it goes", asking == f"127.0.0.1 localnetwork localhost:{LOCAL}", state())
    t.ok("script navigation: held on the public page", not seen("landed") and sv.ev(c, "location.href").startswith(SITE[2]), hits)
    answer("always")
    t.ok("script navigation: allowed, it goes on", until(lambda: seen("landed")), hits)

    d = opened(f"{SITE[3]}/still")
    sv.cmd({"do": "go", "id": d, "url": f"http://localhost:{LOCAL}/typed"})
    t.ok("an address Broadway opens: never asked", until(lambda: seen("typed")) and state()["asking"] == "", state())

    sv.cmd({"do": "close", "id": d})
    d = opened(f"{SITE[3]}/hop")
    t.ok("server redirect to localhost: goes, unasked", until(lambda: seen("redirected")) and state()["asking"] == "", state())

    p = sv.cmd({"do": "open", "url": f"{SITE[4]}/fetch", "private": True})["id"]
    sv.cmd({"do": "select", "id": p})
    n = next(w["n"] for w in sv.cmd({"do": "windows"})["windows"] if w["private"])
    t.ok("private tab: asked too", until(lambda: state(window=n)["asking"]).startswith("127.0.0.1 localnetwork"), state(window=n))
    answer("always", window=n)
    t.ok("private tab: allowed, it reaches localhost", until(lambda: sv.ev(p, "window.r && window.r.fetch") == "reached"), sv.ev(p, "JSON.stringify(window.r)"))
    t.ok("private tab: the answer is never written down", all(x["site"] != SITE[4] for x in state()["sites"]), state()["sites"])
    q = opened(f"{SITE[4]}/still")
    t.ok("private tab: another tab on the site is still guarded", state(q)["attached"], state(q))
    sv.cmd({"do": "close", "id": p}); sv.cmd({"do": "close", "id": q})

    e = opened(f"http://localhost:{LOCAL}/local")
    t.ok("local page: reaches another local server", until(lambda: sv.ev(e, "window.r") == "reached"), sv.ev(e, "window.r"))
    st = state(e)
    t.ok("local page: never guarded, never asked", not st["attached"] and st["asking"] == "", st)

    f = opened(f"{SITE[DEVELOPER]}/fetch")
    t.ok("Developer Mode site: reaches localhost, unasked",
         result(f, "fetch") == "reached" and not state(f)["attached"] and state()["asking"] == "", state(f))

    print("  skip  switch off: localnetwork.ask is fixed on since the Settings cut, so there is no off case")
finally:
    t.done(); sv.finish()
    for s in [local_server, second_server, six_server, *publics]: s.shutdown()
sys.exit(1 if t.failed else 0)

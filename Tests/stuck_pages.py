#!/usr/bin/env python3
import os
import subprocess
import sys
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("stuck-pages")

LOOP = (b"<!doctype html><title>Pond loop</title>"
        b"<button id=loop style='display:block;width:420px;height:220px;font-size:30px'"
        b" onclick='while (true) {}'>Stir the pond</button><p>Pond loop</p>")
CALM = b"<!doctype html><title>Reed list</title><p>Reed list</p>"
asked = Counter()


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        asked[path] += 1
        body = LOOP if path == "/loop" else CALM
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
ended = []
words = {}


def row(id):
    rows = sv.cmd({"do": "stuck"})["tabs"]
    return next((r for r in rows if r["id"] == id), None)


def wait(what, check, within=10.0, every=0.1):
    deadline = time.time() + within
    while time.time() < deadline:
        found = check()
        if found:
            return found
        time.sleep(every)
    return None


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def load(pid):
    out = subprocess.run(["ps", "-o", "%cpu=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    try:
        return float(out)
    except ValueError:
        return 0.0


def opened(path):
    id = sv.sp("open", url=f"{BASE}{path}")["resultID"]
    r = wait("loaded", lambda: (lambda r: r if r and r["pid"] > 0 and not r["loading"] and r["committed"].endswith(path) else None)(row(id)))
    if not r:
        raise RuntimeError(f"{path} did not load: {row(id)}")
    return id, r["pid"]


def stir(t, id, round):
    sv.cmd({"do": "tap", "id": id, "selector": "#loop"})
    heard = wait("WebKit's word", lambda: (row(id) or {}).get("stuck"), within=10)
    words[round] = bool(heard)
    t.ok(f"{round}: WebKit said the page stopped answering after the click", bool(heard), row(id))
    if not heard:
        sv.cmd({"do": "stuck", "action": "said", "id": id, "value": "stuck"})
    return bool(row(id)["stuck"])


def gone(pid):
    return wait("ended", lambda: not alive(pid), within=5) is not None or not alive(pid)


def round_reload(t):
    id, old = opened("/loop")
    t.ok("reload: the page is on a process of its own", old > 0, old)
    t.ok("reload: the tab is stuck before Reload", stir(t, id, "reload"), row(id))
    before = asked["/loop"]
    sv.cmd({"do": "stuck", "action": "do", "id": id, "value": "reload"})
    back = wait("new process", lambda: (lambda r: r if r and r["pid"] not in (0, old) and not r["loading"] else None)(row(id)))
    time.sleep(1)
    ended.append(old)
    t.ok("reload: the tab comes back on a new process id", bool(back), row(id))
    t.ok("reload: the old process is gone", gone(old), old)
    t.ok("reload: the page loaded once", asked["/loop"] == before + 1, (before, asked["/loop"]))
    t.ok("reload: the tab is no longer stuck", not row(id)["stuck"], row(id))
    sv.sp("close", id=id)


def round_asked(t):
    id, old = opened("/loop")
    before = asked["/loop"]
    sv.cmd({"do": "tap", "id": id, "selector": "#loop"})
    time.sleep(0.3)
    sv.cmd({"do": "stuck", "action": "do", "id": id, "value": "reload"})
    t.ok("asked: Reload went in before WebKit's word", not row(id)["stuck"], row(id))
    back = wait("new process", lambda: (lambda r: r if r and r["pid"] not in (0, old) and not r["loading"] else None)(row(id)), within=12)
    words["asked"] = bool(back)
    time.sleep(1)
    ended.append(old)
    t.ok("asked: WebKit's word ends the process and the Reload is done again on a new one", bool(back), row(id))
    t.ok("asked: the old process is gone", gone(old), old)
    t.ok("asked: the page loaded once", asked["/loop"] == before + 1, (before, asked["/loop"]))
    t.ok("asked: no card was asked", not row(id)["card"], row(id))
    sv.sp("close", id=id)


def round_close(t):
    keep, _ = opened("/calm")
    id, old = opened("/loop")
    t.ok("close: the tab is stuck before Close", stir(t, id, "close"), row(id))
    before = sum(asked.values())
    sv.cmd({"do": "stuck", "action": "do", "id": id, "value": "close"})
    ended.append(old)
    t.ok("close: the old process is gone", gone(old), old)
    time.sleep(1)
    t.ok("close: the tab is closed", row(id) is None, row(id))
    t.ok("close: nothing loaded again", sum(asked.values()) == before, dict(asked))
    sv.sp("close", id=keep)


def round_card(t):
    sv.cmd({"do": "stuck", "action": "waits", "times": [2, 4, 6]})
    id, old = opened("/loop")
    t.ok("card: the tab is stuck", stir(t, id, "card"), row(id))
    t.ok("card: no card before the wait is up", not row(id)["card"], row(id))
    up = wait("card", lambda: (lambda r: r if r and r["card"] and r["cardDrawn"] else None)(row(id)), within=8)
    t.ok("card: the card comes on the page in front and is drawn", bool(up), row(id))
    before = asked["/loop"]
    sv.cmd({"do": "stuck", "action": "answer", "id": id, "value": "reload"})
    back = wait("new process", lambda: (lambda r: r if r and r["pid"] not in (0, old) and not r["loading"] else None)(row(id)))
    ended.append(old)
    t.ok("card: Reload brings the page back on a new process id", bool(back), row(id))
    t.ok("card: the card is gone", not row(id)["card"] and not row(id)["cardDrawn"], row(id))
    t.ok("card: the old process is gone", gone(old), old)
    t.ok("card: the page loaded once", asked["/loop"] == before + 1, (before, asked["/loop"]))
    sv.cmd({"do": "stuck", "action": "waits"})
    sv.sp("close", id=id)


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        round_reload(t)
        round_asked(t)
        round_close(t)
        round_card(t)
        t.ok("every process the loop ran in is gone", all(not alive(p) for p in ended), [(p, alive(p)) for p in ended])
        left = [r["pid"] for r in sv.cmd({"do": "stuck"})["tabs"] if r["pid"] > 0]
        busy = [(p, load(p)) for p in set(left + ended) if alive(p) and load(p) > 80]
        t.ok("no page process of the probe is left at full load", not busy, busy)
        print("WebKit's own word arrived:", ", ".join(f"{k} {'yes' if v else 'no'}" for k, v in words.items()))
    finally:
        t.done()
        for p in ended:
            name = subprocess.run(["ps", "-o", "comm=", "-p", str(p)], capture_output=True, text=True).stdout
            if alive(p) and "WebContent" in name:
                subprocess.run(["kill", "-9", str(p)])
        sv.finish()
        server.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

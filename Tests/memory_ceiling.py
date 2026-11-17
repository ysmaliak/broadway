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

sv.use("memory-ceiling")

CEILING = 600
GROW = (b"<!doctype html><title>Heron count</title>"
        b"<button id=go style='display:block;width:420px;height:220px;font-size:30px' onclick='grow()'>Count the herons</button>"
        b"<p>Heron count</p><script>var kept = [];"
        b"function grow() { if (kept.length >= 10) return;"
        b" var block = new Uint8Array(128 * 1024 * 1024);"
        b" for (var i = 0; i < block.length; i += 4096) block[i] = 1;"
        b" kept.push(block); setTimeout(grow, 20); }</script>")
asked = Counter()


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        asked[path] += 1
        body = GROW
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


def state():
    return sv.cmd({"do": "memory"})


def row(id):
    return next((r for r in state()["tabs"] if r["id"] == id), None)


def wait(check, within=10.0, every=0.2):
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


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        said = sv.cmd({"do": "memory", "action": "ceiling", "megabytes": CEILING})
        t.ok("the ceiling is lowered for the probe", abs(said["ceiling"] - CEILING) < 1, said)
        id = sv.sp("open", url=f"{BASE}/grow")["resultID"]
        r = wait(lambda: (lambda r: r if r and r["pid"] > 0 and not r["loading"] and r["committed"].endswith("/grow") else None)(row(id)))
        t.ok("the page is on a process of its own", bool(r), row(id))
        pid = r["pid"]
        ended.append(pid)
        watched = wait(lambda: any(w["pid"] == pid for w in state()["watched"]), within=12)
        t.ok("the watch is told of the page's process", bool(watched), state()["watched"])
        before = asked["/grow"]
        readings = state()["readings"]
        sv.cmd({"do": "tap", "id": id, "selector": "#go"})
        stopped = wait(lambda: (row(id) or {}).get("failure") == "This page used too much memory and was stopped", within=25)
        took = state()["readings"] - readings
        t.ok("the page is stopped and its tab shows the message", bool(stopped), row(id))
        t.ok("it took three readings or fewer", took <= 3, took)
        t.ok("its process is gone", wait(lambda: not alive(pid), within=5) is not None, pid)
        time.sleep(4)
        t.ok("it stays stopped and nothing loads again by itself", row(id)["failure"] and asked["/grow"] == before, (row(id), asked["/grow"], before))
        t.ok("it is not marked to reload when it comes back", not row(id)["stale"], row(id))
        pressed = sv.cmd({"do": "memory", "action": "retry", "id": id})
        t.ok("the button on the page is the one pressed", pressed.get("pressed") is True, pressed)
        back = wait(lambda: (lambda r: r if r and r["pid"] not in (0, pid) and not r["loading"] and not r["failure"] else None)(row(id)), within=12)
        t.ok("pressing it loads the page again on a new process", bool(back), row(id))
        t.ok("the page loaded once", asked["/grow"] == before + 1, (before, asked["/grow"]))
        if back:
            ended.append(back["pid"])
        now = state()["readings"]
        wait(lambda: state()["readings"] >= now + 1, within=12)
        last = state()["last"]
        over = [r for r in last if r["megabytes"] > CEILING]
        t.ok("no page process of the probe is over the ceiling", not over, last)
        t.ok("every process the growing page ran in before is gone", not alive(pid), pid)
    finally:
        t.done()
        try:
            sv.cmd({"do": "memory", "action": "ceiling"})
        except Exception:
            pass
        for p in ended:
            name = subprocess.run(["ps", "-o", "comm=", "-p", str(p)], capture_output=True, text=True).stdout
            if alive(p) and "WebContent" in name:
                subprocess.run(["kill", "-9", str(p)])
        sv.finish()
        server.shutdown()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

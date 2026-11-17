#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("leave-page")
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".context" / "leave"
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"leave-page-{os.getpid()}"
SHOT = TMP / "shot"

FIELD = b"<input id=f autofocus style='display:block;width:420px;height:60px;font-size:28px'>"
ASKS = (b"<!doctype html><title>Marsh log</title>" + FIELD
        + b"<p>Marsh log</p><script>addEventListener('beforeunload', function (e) {"
        + b" if (document.getElementById('f').value) { e.preventDefault(); e.returnValue = ''; } });</script>")
asked = Counter()


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        asked[path] += 1
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(ASKS)))
        self.end_headers()
        self.wfile.write(ASKS)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def leave(action="state", **f):
    return sv.cmd({"do": "leave", "action": action, **f})


def row(id):
    return next((r for r in leave()["tabs"] if r["id"] == id), None)


def wait(check, within=10.0, every=0.1):
    deadline = time.time() + within
    while time.time() < deadline:
        found = check()
        if found:
            return found
        time.sleep(every)
    return None


def value(id):
    return sv.ev(id, "document.getElementById('f').value")


def opened(path):
    id = sv.sp("open", url=f"{BASE}{path}")["resultID"]
    r = wait(lambda: (lambda r: r if r and r["pid"] > 0 and not r["loading"] and r["url"].endswith(path) else None)(row(id)))
    if not r:
        raise RuntimeError(f"{path} did not load: {row(id)}")
    return id


def typed(t, id, round):
    sv.cmd({"do": "tap", "id": id, "selector": "#f"})
    time.sleep(0.3)
    for code, chars in ((4, "h"), (34, "i")):
        sv.cmd({"do": "press", "code": code, "chars": chars, "mods": []})
        time.sleep(0.1)
    got = wait(lambda: value(id) == "hi", within=5)
    t.ok(f"{round}: the field holds what was typed with real keys", bool(got), value(id))


def question(id):
    return wait(lambda: (lambda r: r if r and r["asked"] and r["card"] else None)(row(id)), within=10)


class Stills:
    def __init__(self, on):
        self.on = on
        self.pid = None
        self.number = None
        self.taken = []

    def tool(self):
        TMP.mkdir(parents=True, exist_ok=True)
        source = TMP / "WindowShot.swift"
        shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
        subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(TMP), check=True)

    def launch(self):
        if not self.on:
            return sv.launch()
        self.tool()
        OUT.mkdir(parents=True, exist_ok=True)
        before = sv.running()
        subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
        for _ in range(200):
            if os.path.exists(sv.SOCK):
                break
            time.sleep(0.1)
        time.sleep(2)
        sv.started.update(sv.running() - before)
        self.pid = next(iter(sv.holding() & sv.running()))
        sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})
        self.number = sv.cmd({"do": "idle", "action": "unhide"})["number"]

    def take(self, name):
        if not self.on:
            return
        time.sleep(0.8)
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(1.2)
            path = OUT / f"{name}-{look}.png"
            said = subprocess.run([str(SHOT), str(self.pid), str(self.number), str(path)], capture_output=True, text=True).stdout.strip()
            if path.exists():
                self.taken.append(str(path))
            else:
                print("no still:", said)
        sv.cmd({"do": "ui", "look": "system"})


def round_reload(t, stills):
    id = opened("/reload")
    typed(t, id, "reload")
    before = asked["/reload"]
    pid = row(id)["pid"]
    leave("do", id=id, value="reload")
    t.ok("reload: the page asks on the tab before it is left", bool(question(id)), row(id))
    stills.take("reload")
    leave("answer", id=id, value="stay")
    time.sleep(1)
    t.ok("reload: Stay keeps the page without loading it", asked["/reload"] == before, (before, asked["/reload"]))
    t.ok("reload: Stay keeps what was typed", value(id) == "hi", value(id))
    t.ok("reload: Stay keeps the process", row(id)["pid"] == pid and not row(id)["asked"], row(id))
    leave("do", id=id, value="reload")
    t.ok("reload: Reload asks again", bool(question(id)), row(id))
    leave("answer", id=id, value="leave")
    back = wait(lambda: asked["/reload"] == before + 1 and not row(id)["loading"] and value(id) == "")
    t.ok("reload: Leave reloads the page once", bool(back), (before, asked["/reload"], value(id)))
    sv.sp("close", id=id)


def round_close(t, stills):
    keep = opened("/keep")
    id = opened("/close")
    typed(t, id, "close")
    leave("do", id=id, value="close")
    t.ok("close: the page asks before its tab closes", bool(question(id)), row(id))
    stills.take("close")
    leave("answer", id=id, value="stay")
    time.sleep(1.5)
    t.ok("close: Stay keeps the tab and what was typed", row(id) is not None and value(id) == "hi", row(id))
    leave("do", id=id, value="close")
    t.ok("close: Close asks again", bool(question(id)), row(id))
    leave("answer", id=id, value="leave")
    t.ok("close: Leave closes the tab", wait(lambda: row(id) is None) is not None or row(id) is None, row(id))
    sv.sp("close", id=keep)


def round_window(t):
    first = opened("/first")
    typed(t, first, "window")
    second = opened("/second")
    typed(t, second, "window")
    before = (leave()["windows"], leave()["shown"])
    leave("do", id=second, value="window")
    one = wait(lambda: next((r for r in leave()["tabs"] if r["asked"] and r["card"] and r["id"] in (first, second)), None))
    t.ok("window: the window asks one page first", bool(one), leave()["tabs"])
    if not one:
        return
    other = first if one["id"] == second else second
    leave("answer", id=one["id"], value="leave")
    t.ok("window: then it asks the other page", bool(question(other)), row(other))
    leave("answer", id=other, value="stay")
    time.sleep(1.5)
    now = leave()
    awake = all(row(id) and not row(id)["asleep"] and row(id)["pid"] > 0 for id in (first, second))
    t.ok("window: one Stay keeps the window and both pages awake", (now["windows"], now["shown"]) == before and awake, now)
    t.ok("window: the page that was left keeps its text too", value(one["id"]) == "hi", value(one["id"]))
    t.ok("window: the page kept by Stay keeps its text", value(other) == "hi", value(other))
    sv.sp("close", id=first)
    sv.sp("close", id=second)


def running():
    return bool(sv.pids())


def round_quit(t):
    id = opened("/quit")
    typed(t, id, "quit")
    sv.cmd({"do": "quit"})
    t.ok("quit: the page asks before Broadway quits", bool(question(id)), row(id))
    leave("answer", id=id, value="stay")
    time.sleep(2)
    alive = running()
    t.ok("quit: Stay calls the quit off", alive, sv.pids())
    t.ok("quit: Stay keeps what was typed", alive and value(id) == "hi", value(id) if alive else None)
    sv.cmd({"do": "quit"})
    t.ok("quit: quitting again asks again", bool(question(id)), row(id))
    leave("answer", id=id, value="leave")
    gone = wait(lambda: not running(), within=15)
    t.ok("quit: Leave lets Broadway quit", gone is not None, sv.pids())


def main():
    stills = Stills("--stills" in sys.argv[1:])
    t = sv.T()
    try:
        sv.setup()
        stills.launch()
        leave("hold", value="on")
        round_reload(t, stills)
        round_close(t, stills)
        round_window(t)
        round_quit(t)
        if stills.on:
            print("stills:", *stills.taken, sep="\n  ")
    finally:
        t.done()
        sv.finish()
        server.shutdown()
        shutil.rmtree(TMP, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("kept-sign-ins")
KEPT = Path(sv.SUPPORT, "Sign-ins", f"{sv.FIRST_SPACE.upper()}.json")
SETS = {"/set": "kept_one", "/set2": "kept_two", "/update": "kept_three"}
lock = threading.Lock()
seen = []


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        with lock:
            seen.append((path, self.headers.get("Cookie") or ""))
        body = f"<!doctype html><title>{path.strip('/')}</title><p>{path}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        if path in SETS:
            self.send_header("Set-Cookie", f"{SETS[path]}=yes; Path=/")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def mark():
    with lock:
        return len(seen)


def first(since, paths=None, within=20):
    until = time.monotonic() + within
    while time.monotonic() < until:
        with lock:
            for path, cookie in seen[since:]:
                if paths is None or path in paths:
                    return path, cookie
        time.sleep(0.05)
    return None, None


def kept():
    try:
        return sorted(c["name"] for c in json.loads(KEPT.read_text())["crumbs"])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def wait(check, within=15):
    until = time.monotonic() + within
    while time.monotonic() < until:
        if check():
            return True
        time.sleep(0.05)
    return check()


def ended(within=15):
    started = time.monotonic()
    wait(lambda: not sv.pids(), within)
    return time.monotonic() - started, not sv.pids()


def open_tab(path):
    since = mark()
    sv.sp("open", url=f"{BASE}{path}")
    first(since, {path}, 10)
    time.sleep(0.5)


def relaunch():
    since = mark()
    sv.launch()
    return since


t = sv.T()
numbers = {}
try:
    sv.setup()
    sv.launch()
    open_tab("/set")
    t.ok("before quitting: nothing is written inside the settling time", kept() is None, kept())

    sv.cmd({"do": "signins", "quit": "menu"})
    took, gone = ended()
    numbers["menu quit seconds"] = round(took, 2)
    t.ok("Quit from the menu: the app ends", gone, took)
    t.ok("Quit from the menu: within 3 seconds of the press", took < 3.3, took)
    t.ok("Quit from the menu: the kept file has the cookie", kept() == ["kept_one"], kept())

    since = relaunch()
    path, cookie = first(since)
    numbers["first request after menu quit"] = [path, cookie]
    t.ok("launch: the tab comes back by itself and asks for its page", path == "/set", path)
    t.ok("launch: its first request carries the kept cookie", "kept_one=yes" in (cookie or ""), cookie)

    sv.cmd({"do": "signins", "settle": 1.0})
    started = time.monotonic()
    open_tab("/set2")
    written = wait(lambda: kept() == ["kept_one", "kept_two"], 10)
    numbers["crash write seconds after the page"] = round(time.monotonic() - started, 2)
    t.ok("settling shortened: the new cookie is written while the app runs", written, kept())
    time.sleep(1.5)
    for pid in sv.pids():
        os.kill(int(pid), signal.SIGKILL)
    took, gone = ended(5)
    t.ok("SIGKILL: the app is gone", gone, took)
    t.ok("SIGKILL: the kept file still has both cookies", kept() == ["kept_one", "kept_two"], kept())

    since = relaunch()
    path, cookie = first(since)
    numbers["first request after SIGKILL"] = [path, cookie]
    t.ok("launch after SIGKILL: a tab asks for its page", path in ("/set", "/set2"), path)
    t.ok("launch after SIGKILL: its first request carries the cookie written before the kill",
         "kept_two=yes" in (cookie or ""), cookie)

    open_tab("/update")
    t.ok("normal settling: the cookie is not written yet", "kept_three" not in (kept() or []), kept())
    sv.cmd({"do": "updates", "stage": "99.0", "quits": True})
    asked = time.monotonic()
    sv.cmd({"do": "updates", "restart": True})
    took, gone = ended()
    numbers["update restart quit seconds"] = round(time.monotonic() - asked, 2)
    t.ok("restart for an update: the app ends", gone, took)
    t.ok("restart for an update: the kept file has the cookie set just before",
         "kept_three" in (kept() or []), kept())

    since = relaunch()
    path, cookie = first(since)
    numbers["first request after update restart"] = [path, cookie]
    t.ok("launch after the update restart: the first request carries the cookie",
         "kept_three=yes" in (cookie or ""), cookie)

    asked = time.monotonic()
    sv.quit()
    numbers["bench quit seconds"] = round(time.monotonic() - asked, 2)
    t.ok("a quit from a block on the main queue: the kept file has every cookie",
         kept() == ["kept_one", "kept_three", "kept_two"], kept())

    subprocess.run(["defaults", "write", sv.SUITE, "start.fresh", "-bool", "true"])
    since = relaunch()
    t.ok("fresh window: the kept file is removed", wait(lambda: not KEPT.exists(), 5), kept())
    path, cookie = first(since, within=3)
    numbers["first request after fresh start"] = [path, cookie]
    since = mark()
    sv.sp("open", url=f"{BASE}/plain")
    path, cookie = first(since, {"/plain"}, 10)
    numbers["fresh start page cookie"] = cookie
    t.ok("fresh window: a page loads", path == "/plain", path)
    t.ok("fresh window: nothing kept is put back", "kept_" not in (cookie or ""), cookie)
finally:
    print(json.dumps(numbers, indent=1))
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)

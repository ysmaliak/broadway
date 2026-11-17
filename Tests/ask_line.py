#!/usr/bin/env python3
"""Ask the page in front: the line at its foot, the answer card above it, Escape.

Build first (`./build.sh`), then `python3 Tests/ask_line.py [LABEL]`. A test copy in
a world of its own, started hidden behind every window, with a stand-in agent (the
bench's `ai fake`) and a page served from this Mac. Pictures are of the probe window
by its id only. Out: .context/ask-line/LABEL.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP", ROOT / "build/Broadway.app"))
BROADWAY = str(APP / "Contents/Helpers/broadway")
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
WORLD = f"askline-{os.getpid()}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = ROOT / ".context/ask-line" / LABEL
SIZE = (1180, 760)
WINDOW = [0]

PAGE = b"""<!doctype html><title>Leaf and Cup</title><body style="margin:0;background:#f4f1ea;font:17px Georgia,serif;color:#222">
<div style="max-width:640px;margin:60px auto"><h1>Leaf and Cup</h1>
<p>Green tea from Uji, picked in May and sold in 100 gram tins.</p>
<p>The shop opens at nine and closes at six, every day but Monday.</p>
<p>Each tin keeps for a year unopened. Once opened, drink it within two months.</p></div>"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *_):
        pass


class T:
    def __init__(self):
        self.passed, self.failed, self.lines = 0, 0, []

    def ok(self, name, cond, extra=""):
        line = f"{'ok  ' if cond else 'FAIL'} {name}" + ("" if cond else f"  {str(extra)[:400]}")
        print(" ", line, flush=True)
        self.lines.append(line)
        if cond:
            self.passed += 1
        else:
            self.failed += 1


t = T()


def bench(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(30)
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")


def ai(action, **more):
    return bench(dict({"do": "ai", "action": action}, **more))


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def stage(dark):
    said = bench({"do": "agents", "action": "stage", "dark": dark, "size": list(SIZE)})
    WINDOW[0] = said["window"]
    time.sleep(0.8)


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    for _ in range(6):
        subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
        if path.exists():
            return path
        time.sleep(0.5)
    print(f"  no picture of window {WINDOW[0]} for {name}", flush=True)
    return None


def command_j():
    return bench({"do": "keyeq", "chars": "j", "code": 38})


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "bench.sock")], capture_output=True, text=True).stdout.split()


def answered():
    state = ai("state")
    turns = state.get("turns") or []
    return state if len(turns) >= 2 and turns[-1].get("done") and not state.get("running") else None


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    address = f"http://127.0.0.1:{server.server_port}/tea"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    pid = None
    try:
        for key in ("bench", "ai"):
            subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        wait_for(lambda: (FOLDER / "bench.sock").exists(), 30)
        time.sleep(2)
        bench({"do": "window"})
        stage(False)
        pid = (held() or [None])[0]
        said = ai("fake", plan="claude")
        t.ok("the stand-in agent is the one picked", said.get("plan") == "claude", said)
        tab = bench({"do": "split", "action": "open", "url": address, "foreground": True}).get("resultID")
        wait_for(lambda: not (bench({"do": "wait", "id": tab, "seconds": 1}) or {}).get("loading", True), 20)
        time.sleep(1)

        command_j()
        opened = wait_for(lambda: ai("state").get("open"), 5)
        t.ok("⌘J opens the line on the page in front", bool(opened), ai("state"))
        frames = wait_for(lambda: ai("frames").get("frames", {}).get("ask.line.field"), 5)
        t.ok("the line sits at the page's foot", bool(frames) and frames[1] + frames[3] > SIZE[1] - 120, frames)
        state = ai("state")
        t.ok("the page is the line's source", state.get("onPage") is True and state.get("sources") == ["Leaf and Cup"], state)
        for dark in (False, True):
            stage(dark)
            shoot(f"line-{'dark' if dark else 'light'}")
        stage(False)

        ai("question", id=tab, text="When does the shop open?")
        state = wait_for(answered, 10)
        t.ok("a question gets an answer from the stand-in", bool(state) and state["turns"][-1]["text"].startswith("Fake answer: "), ai("state"))
        frames = ai("frames").get("frames", {})
        card, field = frames.get("ask.line.answer"), frames.get("ask.line.field")
        t.ok("the answer card sits above the line", bool(card) and bool(field) and card[1] + card[3] < field[1], frames)
        t.ok("the card names the agent", "ask.line.footer" in frames, frames)
        time.sleep(0.5)
        for dark in (False, True):
            stage(dark)
            shoot(f"card-{'dark' if dark else 'light'}")
        stage(False)

        used = ai("escape").get("used")
        time.sleep(0.4)
        t.ok("Escape after an answer closes the line", used and not ai("state").get("open"), ai("state"))

        ai("fake", plan="claude", hang=True)
        command_j()
        wait_for(lambda: ai("state").get("open"), 5)
        ai("question", id=tab, text="Is it open on Monday?")
        running = wait_for(lambda: ai("state").get("running"), 5)
        t.ok("a second question is running", bool(running), ai("state"))
        time.sleep(0.4)
        stage(False)
        shoot("running-light")
        ai("escape")
        stopped = wait_for(lambda: not ai("state").get("running"), 5)
        state = ai("state")
        t.ok("the first Escape stops the answer and keeps the line", bool(stopped) and state.get("open"), state)
        shoot("stopped-light")
        ai("escape")
        time.sleep(0.4)
        t.ok("the second Escape closes the line", not ai("state").get("open"), ai("state"))
    finally:
        subprocess.run([BROADWAY, "--world", WORLD, "quit", "--force"], capture_output=True)
        time.sleep(1)
        if pid:
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        shutil.rmtree(FOLDER, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
        server.shutdown()
    (OUT / "result.txt").write_text("\n".join(t.lines) + f"\n{t.passed} passed, {t.failed} failed\n")
    print(f"{t.passed} passed, {t.failed} failed")
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

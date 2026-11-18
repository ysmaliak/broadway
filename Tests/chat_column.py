#!/usr/bin/env python3
"""The chat column and the list of chats, on a test copy's own window.

Build first (`./build.sh`), then `python3 Tests/chat_column.py [LABEL]`. A test copy in a
world of its own, started hidden behind every window, with a stand-in for the agent
(FakeProvider through Plans.standIn), never a real model. Checks:

1. open: View › Show Chat puts the column in the side panel's slot.
2. ask: a question gets the stand-in's answer, read back through the bench, and every
   request the stand-in saw has no tools.
3. steer: Return while an answer is coming steers it, and the steer is asked next.
4. list: View › Chats lists the chats, and a row opens a chat again where it was.

Pictures are real stills of the probe's own window by its id, kept behind every window, cropped to the column, light and dark: the empty column, a
chat with two turns and folded steps, a long answer at the narrowest width, a trouble
row and the list. Out: .context/chat-column/LABEL.
"""
import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP", ROOT / "build/Broadway.app"))
BROADWAY = str(APP / "Contents/Helpers/broadway")
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
WORLD = f"chatcolumn-{os.getpid()}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = ROOT / ".context/chat-column" / LABEL
SIZE = (1180, 760)
NARROW = (820, 560)
WINDOW = [0]
PID = [0]
WORK = Path(os.environ.get("TMPDIR", "/tmp")) / f"chat-column-{os.getpid()}"
SHOT = WORK / "shot"
DRAWN = []

PAGE = b"""<!doctype html><title>The Old Bridge</title><body style="margin:0;background:#f4f4f2;font:17px Georgia,serif">
<article style="max-width:640px;margin:48px auto;line-height:1.55"><h1>The Old Bridge</h1>
<p>The old bridge took eleven years to build, from the first stone in the river to the day it opened.</p>
<p>Its seven arches were raised on timber frames, one span a year, while the footings went down in dry summers.</p>
<p>It closed to carts long ago, and only people on foot cross it now.</p></article>"""


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

    def ok(self, point, name, cond, extra=""):
        line = f"{'ok  ' if cond else 'FAIL'} [{point}] {name}" + ("" if cond else f"  {str(extra)[:600]}")
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


def column(action, **more):
    return bench(dict({"do": "chatcolumn", "action": action}, **more))


def chat(what, **more):
    return bench(dict({"do": "ai", "action": "chat", "what": what}, **more))


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "bench.sock")], capture_output=True, text=True).stdout.split()


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.15)
    return None


STAGED = [SIZE]


def stage(dark, size=SIZE):
    STAGED[0] = size
    said = bench({"do": "agents", "action": "stage", "dark": dark, "size": list(size), "shown": False})
    PID[0] = said["pid"]
    placed = bench({"do": "windowbehind"})
    WINDOW[0] = placed["number"]
    BEHIND.append(not placed["key"] and not placed["active"])
    time.sleep(0.9)


BEHIND = []


def crop(src, box, path):
    wide = int(subprocess.run(["sips", "-g", "pixelWidth", str(src)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(wide / STAGED[0][0]))
    x, y, w, h = box
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int(w * k)}:{int(h * k)}:{int(max(0, x) * k)}:{int(max(0, y) * k)}", str(path)], check=True)


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    whole = OUT / f"{name}-window.png"
    raw = WORK / f"{name}-raw.png"
    for old in (path, whole, raw):
        old.unlink(missing_ok=True)
    said = subprocess.run([str(SHOT), str(PID[0]), str(WINDOW[0]), str(raw)], capture_output=True, text=True, timeout=60).stdout.strip()
    if not raw.exists():
        print(f"  capture of {name} failed ({said}), drawn offscreen instead", flush=True)
        DRAWN.append(name)
        made = column("picture", path=str(path)).get("made")
        return path if made else None
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(raw), "--out", str(whole)],
                   capture_output=True, check=True)
    box = column("state").get("column")
    if box:
        crop(whole, box, path)
    return path


def both(name, size=SIZE):
    for dark in (False, True):
        stage(dark, size)
        shoot(f"{name}-{'dark' if dark else 'light'}")
    stage(False, size)


def settled(seconds=10):
    return wait_for(lambda: (lambda s: s if s.get("running") is False and not s.get("queued") else None)(column("state")), seconds)


def users(state):
    return [turn["text"] for turn in state.get("turns", []) if turn["role"] == "user"]


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    pid = None
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "motion.testReduced", "-bool", "false"], check=True)
        subprocess.run(["defaults", "write", SUITE, "motion.testLowPower", "-bool", "false"], check=True)
        subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={WORLD}", "--env", "SEARCH_SHOWN=1", str(APP)], check=True)
        wait_for(lambda: (FOLDER / "bench.sock").exists(), 30)
        time.sleep(2)
        bench({"do": "windowbehind"})
        bench({"do": "window"})
        stage(False)
        pid = (held() or [None])[0]
        column("fake", mode="echo")
        page = bench({"do": "split", "action": "open", "url": base + "bridge", "foreground": True}).get("resultID")
        if page:
            bench({"do": "wait", "id": page, "seconds": 20})
        time.sleep(1)

        opened = chat("toggle")
        t.ok("open", "Show Chat puts the column in the side panel's slot", opened.get("chat") is True, opened)
        state = wait_for(lambda: (lambda s: s if s.get("column") else None)(column("state")), 6) or {}
        t.ok("open", "the column is drawn beside the page", bool(state.get("column")) and state.get("sidePanel") == "chat", state)
        t.ok("open", "the composer has the caret", state.get("focused") is True, state)
        t.ok("open", "until a question the chat follows the page in front", state.get("page") == "The Old Bridge" and state.get("pageKept") is False, state)
        t.ok("open", "the head names the agent", state.get("agent") == "Claude Code", state)
        both("pic-1-empty")

        chat("send", text="What is this page about?")
        state = settled() or {}
        turns = state.get("turns", [])
        t.ok("ask", "the answer comes back through the bench", len(turns) == 2 and turns[1]["text"] == "Fake answer: What is this page about?", turns)
        t.ok("ask", "after the first question the chat keeps its page", state.get("pageKept") is True, state)
        requests = column("requests")
        t.ok("ask", "every request the stand-in saw has no tools",
             bool(requests.get("claude")) and all(r["tools"] == "none" for r in requests["claude"]), requests)
        t.ok("ask", "the page's words went inside the fence", any("The Old Bridge" in r["prompt"] for r in requests.get("claude", [])), requests)

        column("fake", mode="hang")
        chat("send", text="Tell me more")
        wait_for(lambda: column("state").get("running"), 6)
        chat("send", text="Shorter please")
        time.sleep(0.8)
        state = column("state")
        t.ok("steer", "Return while it answers steers it", users(state)[-2:] == ["Tell me more", "Shorter please"], users(state))
        t.ok("steer", "the steer is asked next", len(column("requests").get("claude", [])) == 2 and state.get("running") is True,
             column("requests"))
        column("stop")
        settled()

        column("fake", mode="slow")
        chat("new")
        chat("send", text="First of two")
        wait_for(lambda: column("state").get("running"), 6)
        queued = column("queue", text="Second of two")
        t.ok("queue", "Command-Return waits its turn", queued.get("queued") == ["Second of two"], queued)
        state = settled(12) or {}
        t.ok("queue", "the waiting question is asked after the answer", users(state) == ["First of two", "Second of two"], users(state))

        column("fake", mode="steps")
        chat("new")
        chat("send", text="Sum the page up")
        settled()
        chat("send", text="And when did it close?")
        state = settled() or {}
        t.ok("steps", "two turns, each with its steps folded", [turn["steps"] for turn in state.get("turns", []) if turn["role"] == "assistant"] == [2, 2], state.get("turns"))
        both("pic-2-two-turns-folded-steps")
        column("steps")
        time.sleep(0.5)
        both("pic-2b-steps-opened")

        column("fake", mode="long")
        column("width", width=300)
        chat("new")
        stage(False, NARROW)
        chat("send", text="How was the bridge built?")
        state = settled() or {}
        t.ok("long", "a long answer stays inside the column", state.get("widest", 9999) <= state.get("documentWidth", 0), state)
        t.ok("long", "the answer is followed to its end", state.get("following") is True, state)
        both("pic-3-long-narrow", NARROW)
        column("top")
        time.sleep(0.4)
        state = column("state")
        t.ok("long", "scrolled up, it stops following", state.get("following") is False, state)
        both("pic-3b-long-scrolled-up", NARROW)
        stage(False, SIZE)
        column("width", width=380)

        column("fake", mode="signedOut")
        chat("new")
        chat("send", text="Will this work?")
        state = settled() or {}
        last = (state.get("turns") or [{}])[-1]
        t.ok("trouble", "a signed-out agent shows as a trouble row", last.get("trouble") == "signedOut", last)
        both("pic-4-trouble")

        column("fake", mode="echo")
        listed = chat("list")
        state = column("state")
        t.ok("list", "View › Chats shows the list in the column", listed.get("listing") is True and state.get("listRows", 0) >= 4, state)
        t.ok("list", "the chats kept are there, newest first", (state.get("list") or [None])[0] == "Will this work?", state.get("list"))
        both("pic-5-list")
        column("open", title="What is this page about?")
        state = column("state")
        t.ok("list", "a row opens the chat where it was", state.get("listing") is False and users(state)[:3] == ["What is this page about?", "Tell me more", "Shorter please"],
             users(state))
        chat("send", text="And one more")
        state = settled() or {}
        t.ok("list", "the chat carries on", users(state)[-1:] == ["And one more"] and state["turns"][-1]["text"] == "Fake answer: And one more", state.get("turns"))

        column("fake", mode="act", agents=True)
        chat("new")
        chat("send", text="Open the part about the arches")
        state = wait_for(lambda: (lambda s: s if s.get("running") and (s.get("turns") or [{}])[-1].get("steps", 0) >= 2 else None)(column("state")), 10) or {}
        requests = column("requests").get("claude", [])
        t.ok("act", "with agents let in, the chat acts with Broadway's tools", state.get("acts") is True and bool(requests) and requests[-1]["tools"] == "mcp",
             (state.get("acts"), requests[-1:] if requests else None))
        t.ok("act", "the step in progress shows in the transcript", (state.get("turns") or [{}])[-1].get("steps", 0) >= 2, state.get("turns"))
        both("pic-6-acting")
        column("stop")
        state = settled(6) or {}
        t.ok("act", "Stop stops the acting at once", state.get("running") is False, state)
        column("fake", mode="echo", agents=False)
        chat("new")
        state = column("state")
        t.ok("act", "with agents off the chat only answers and says how to let it act", state.get("acts") is False, state)
        both("pic-7-agents-off")
        t.ok("look", "the probe's window stays behind every window and never takes the keys", all(BEHIND), BEHIND)
        subprocess.run(["defaults", "write", SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(0.5)
        chat("toggle")
        time.sleep(0.3)
        chat("toggle")
        state = wait_for(lambda: (lambda s: s if s.get("column") else None)(column("state")), 6) or {}
        t.ok("motion", "with Reduce Motion on the column still opens and closes", state.get("chat") is True and bool(state.get("column")), state)
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
        shutil.rmtree(WORK, ignore_errors=True)
    (OUT / "result.txt").write_text("\n".join(t.lines) + f"\n{t.passed} passed, {t.failed} failed\n")
    print("real window pictures" if not DRAWN else f"drawn offscreen: {DRAWN}")
    print(f"{t.passed} passed, {t.failed} failed")
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

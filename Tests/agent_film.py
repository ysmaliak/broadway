#!/usr/bin/env python3
"""Window-only frames of the Agents area through a whole session, on a test copy.

Build first (`./build.sh`), then `python3 Tests/agent_film.py [OUT]`. A test
copy in a world of its own, started hidden, driven by the real `broadway` as two
agents: connect, work, needs you, a second agent with a long name and many
tabs, unfold and fold, done with a long summary, close. Each step is filmed through
the bench's own window drawing (never the screen), in light and dark, and
bursts of frames catch the motion of the row arriving, unfolding and leaving.
BROADWAY_APP picks another build, for before and after.
"""
import json
import os
import re
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
WORLD = "agentfilm"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/film")

PAGE = b"""<!doctype html><title>%s</title><h1>%s</h1>
<input id="q" placeholder="Search" style="font-size:20px;width:300px">
<button id="go" type="button">Go</button><p>Some words to read.</p>"""

CLAUDE = {"BROADWAY_AGENT": "claude-film", "BROADWAY_AGENT_NAME": "Claude Code"}
CODEX = {"BROADWAY_AGENT": "codex-film", "BROADWAY_AGENT_NAME": "Codex Nightly Release Checker For The Whole Team"}
SCRIPT = {"BROADWAY_AGENT": "script-film", "BROADWAY_AGENT_NAME": "Nightly check"}
LOG = []
HEIGHT = 760
SIDE = 300
WINDOW = [0]


CLIP = OUT / "clip.mp4"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/clip.mp4"):
            return self.clip()
        name = self.path.strip("/") or "home"
        body = PAGE % (name.encode(), name.encode())
        if name == "video":
            body = b"<!doctype html><title>Video</title><video src='/clip.mp4' autoplay muted loop playsinline style='width:100%'></video>" \
                   b"<button id='loud' style='position:fixed;top:0;left:0;width:240px;height:90px' " \
                   b"onclick=\"const v=document.querySelector('video');v.muted=false;v.play()\">sound</button>"
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def clip(self):
        data = CLIP.read_bytes()
        start, end = 0, len(data) - 1
        asked = re.match(r"bytes=(\d*)-(\d*)", self.headers.get("range") or "")
        if asked:
            start = int(asked.group(1) or 0)
            end = int(asked.group(2)) if asked.group(2) else end
        part = data[start:end + 1]
        self.send_response(206 if asked else 200)
        self.send_header("content-type", "video/mp4")
        self.send_header("accept-ranges", "bytes")
        self.send_header("content-length", str(len(part)))
        if asked:
            self.send_header("content-range", f"bytes {start}-{end}/{len(data)}")
        self.end_headers()
        try:
            self.wfile.write(part)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


def broadway(*words, env=None, timeout=60):
    environment = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_")}
    environment.update(env or {})
    result = subprocess.run([BROADWAY, "--world", WORLD, *words, "--json"], capture_output=True, text=True,
                            stdin=subprocess.DEVNULL, env=environment, timeout=timeout)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "raw": result.stdout + result.stderr}


def bench(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")


def agents(action, **more):
    return bench(dict({"do": "agents", "action": action}, **more))


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def area():
    return agents("state").get("area", [])


def card(named):
    return next((row for row in area() if named.startswith(row["name"])), None)


def shoot(path):
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    if path.exists() and os.environ.get("AGENT_FILM_CROP"):
        subprocess.run([os.environ["AGENT_FILM_CROP"], str(path), str(path.with_name(path.stem + "-side.png")),
                        "0", "0", str(SIDE * 2), str(HEIGHT * 2)], capture_output=True)
    return path.exists()


def still(name):
    for dark in (False, True):
        WINDOW[0] = agents("stage", dark=dark)["window"]
        time.sleep(0.5)
        path = OUT / f"{name}-{'dark' if dark else 'light'}.png"
        LOG.append((name, dark, [str(path) if shoot(path) else "no frame"]))
    agents("stage", dark=False)


def burst(name, act, frames=10):
    time.sleep(0.3)
    thread = threading.Thread(target=act)
    started = time.time()
    thread.start()
    taken = []
    for index in range(frames):
        path = OUT / f"{name}-burst-{index:02d}.png"
        if shoot(path):
            taken.append(f"{int((time.time() - started) * 1000)}ms")
    thread.join()
    LOG.append((name, None, taken))


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    pid = None
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30)
        bench({"do": "window"})
        WINDOW[0] = agents("stage", size=[1100, HEIGHT])["window"]
        pid = (held() or [None])[0]
        if shutil.which("ffmpeg"):
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                            "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=44100", "-t", "10", "-pix_fmt", "yuv420p",
                            "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", "-shortest", str(CLIP)], check=True)
            video = bench({"do": "split", "action": "open", "url": base + "video", "foreground": True}).get("resultID")
            bench({"do": "wait", "id": video, "seconds": 20})
            bench({"do": "tap", "id": video, "selector": "#loud"})
            time.sleep(1)
        for index in range(6):
            bench({"do": "split", "action": "open", "url": base + f"mine-{index}", "foreground": True})
        time.sleep(1)
        still("00-rest")

        burst("01-connect", lambda: broadway("agents", "connect", env=CLAUDE))
        still("01-connected")

        one = broadway("open", base + "pulls", env=CLAUDE)["data"]["id"]
        broadway("open", base + "issue-42", env=CLAUDE)
        broadway("wait", "--tab", one, env=CLAUDE)
        snap = broadway("snapshot", "--tab", one, env=CLAUDE)
        refs = [item for item in snap.get("data", {}).get("elements", []) if isinstance(item, dict)]
        box = next((item["ref"] for item in refs if item.get("role") in ("textbox", "searchbox")), "@e1")
        broadway("type", box, "sign-in loop", "--tab", one, env=CLAUDE)
        still("02-working")
        agents("row", link=card("Claude Code")["id"][:8], index=0)
        broadway("type", box, " again", "--tab", one, env=CLAUDE)
        still("03-watching")

        agents("mode", mode="ask")
        asking = subprocess.Popen([BROADWAY, "--world", WORLD, "scroll", "--tab", one, "--json"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL,
                                  env=dict({k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_")}, **CLAUDE))
        wait_for(lambda: (card("Claude Code") or {}).get("attention"), 15)
        still("04-needs-you")
        agents("answer", **{"with": "yes"})
        asking.communicate(timeout=20)
        agents("mode", mode="auto")

        burst("05-second", lambda: broadway("open", base + "release-notes-for-the-whole-team-with-a-very-long-title", env=CODEX))
        for index in range(7):
            broadway("open", base + f"check-{index}", env=CODEX)
        broadway("open", base + "status", env=SCRIPT)
        time.sleep(0.6)
        still("05-three-agents")

        burst("06-unfold", lambda: agents("fold"))
        still("06-unfolded")
        burst("07-fold", lambda: agents("fold"))
        still("07-folded")
        agents("fold")

        broadway("agents", "done", "--summary", "Read the pull requests, typed a search for the sign-in loop and left notes on ENG-42 "
                                           "for the team to look at in the morning", env=CLAUDE)
        broadway("agents", "done", "--failed", "--summary", "Status page timed out", env=SCRIPT)
        time.sleep(0.4)
        still("09-done")

        claude = card("Claude Code")
        burst("10-close", lambda: agents("closelink", link=claude["id"][:8]))
        still("10-closed")
        script = card("Nightly check")
        agents("closelink", link=script["id"][:8])
        broadway("agents", "done", env=CODEX)
        codex = card("Codex Nightly Release Checker For The Whole Team")
        burst("11-leave", lambda: agents("closelink", link=codex["id"][:8]), frames=16)
        still("11-empty")
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
    for name, dark, files in LOG:
        print(name, "" if dark is None else ("dark" if dark else "light"), " ".join(str(f) for f in files))


main()

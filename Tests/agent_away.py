#!/usr/bin/env python3
import json
import os
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP", ROOT / "build/Broadway.app"))
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentaway-{os.getpid()}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = ROOT / ".context/agent-away"
HOST = ROOT / ".build/agent-away/claude"
SCRATCH = Path(tempfile.mkdtemp(prefix="broadway-away-"))
GARDEN = SCRATCH / "garden"
SIZE = (1180, 760)
WINDOW = [0]

PAGES = {
    "message": "<!doctype html><title>Message</title><h1>Message</h1><button onclick='window.sentIt=true'>Send</button>",
    "login": "<!doctype html><title>Sign in</title><form action='/home'><input name=user><input type=password name=pass></form>",
    "home": "<!doctype html><title>Home</title><h1>Signed in</h1>",
    "mine": "<!doctype html><title>Mine</title><h1>Mine</h1>",
    "build": "<!doctype html><title>Build</title><h1>Build</h1>",
}


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0] or "home"
        body = PAGES.get(name.rstrip("0123456789"), PAGES["home"]).encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class T:
    def __init__(self):
        self.passed, self.failed = 0, 0

    def ok(self, point, name, cond, extra=""):
        print(f"  {'ok  ' if cond else 'FAIL'} [{point}] {name}" + ("" if cond else f"  {str(extra)[:500]}"), flush=True)
        if cond:
            self.passed += 1
        else:
            self.failed += 1


t = T()


def bench(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(60)
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")


def environment(session):
    kept = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_") and k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")}
    kept["CLAUDE_CODE_SESSION_ID"] = f"away-{os.getpid()}-{session}"
    return kept


def line(*words):
    return " ".join(shlex.quote(w) for w in [BROADWAY, "--world", WORLD, *words, "--json"])


def parsed(text):
    try:
        return json.loads(text)
    except ValueError:
        return {"ok": False, "raw": text}


class Agent:
    def __init__(self, session):
        self.session, self.count = session, 0
        self.process = subprocess.Popen([str(HOST), "/bin/sh", "-c", 'while IFS= read -r line; do eval "$line"; done'], cwd=GARDEN,
                                        env=environment(session), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, text=True, start_new_session=True)

    def start(self, *words):
        self.count += 1
        out = SCRATCH / f"{self.session}-{self.count}.json"
        done = SCRATCH / f"{self.session}-{self.count}.done"
        self.process.stdin.write(f"{line(*words)} > {shlex.quote(str(out))} 2>&1 < /dev/null; echo $? > {shlex.quote(str(done))}\n")
        self.process.stdin.flush()
        return out, done, time.time()

    def finish(self, handle, timeout=240):
        out, done, started = handle
        wait_for(lambda: done.exists() and done.read_text().strip(), timeout)
        took = time.time() - started
        code = int(done.read_text().strip()) if done.exists() and done.read_text().strip() else None
        return parsed(out.read_text() if out.exists() else ""), took, code

    def __call__(self, *words):
        return self.finish(self.start(*words))

    def kill(self):
        try:
            os.killpg(self.process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass


def desk(text=None):
    return bench({"do": "knowing", "action": "desk", "text": text} if text else {"do": "knowing", "action": "desk"})


def notices(title):
    return [n for n in bench({"do": "notifications"}).get("recorded", []) if n.get("kind") == "agent" and n.get("title") == title]


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def stage(shown=False):
    said = bench({"do": "agents", "action": "stage", "dark": False, "size": list(SIZE), "shown": shown})
    WINDOW[0] = said.get("window", 0)
    time.sleep(0.8)


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    for _ in range(4):
        subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
        if path.exists() and path.stat().st_size > 2000:
            print(f"  picture {path}", flush=True)
            return path
        time.sleep(0.5)
    print(f"  no picture of window {WINDOW[0]} for {name} (no screen recording grant over ssh)", flush=True)
    return None


def error(said):
    return said.get("error") or {}


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    HOST.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["cc", "-O2", "-o", str(HOST), str(ROOT / "Tests/agent_host.c")], check=True)
    GARDEN.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    everyone = []
    try:
        for key in ("bench", "agents.on"):
            subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.mode", "-string", "auto"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        wait_for(lambda: (FOLDER / "bench.sock").exists(), 40)
        time.sleep(2)
        bench({"do": "window"})
        stage(False)

        agent = Agent("one")
        other = Agent("two")
        everyone.extend([agent, other])
        opened, _, _ = agent("open", base + "message")
        one = (opened.get("data") or {}).get("id", "")
        t.ok("names", "the agent opens a tab", opened.get("ok") and one, opened)
        other("open", base + "home2")
        listed, _, _ = agent("agents", "list")
        names = [row.get("name") for row in (listed.get("data") or {}).get("agents", [])]
        t.ok("names", "a session is headed by its agent and its folder", "Claude Code · garden" in names, names)
        t.ok("names", "a second session in the same folder takes the number after the folder", "Claude Code · garden 2" in names, names)

        bench({"do": "select", "id": one})
        agent("go", base + "build", "--tab", one)
        time.sleep(1.5)
        offer_agent = bench({"do": "dev", "action": "state"}).get("offer")
        t.ok("developer", "an agent's local page offers no Developer Mode", not offer_agent, offer_agent)
        bench({"do": "split", "action": "open", "url": base + "mine", "foreground": True})
        offer_mine = wait_for(lambda: bench({"do": "dev", "action": "state"}).get("offer"), 8)
        t.ok("developer", "the person's own local page still offers it", bool(offer_mine), offer_mine)
        agent("go", base + "message", "--tab", one)

        bench({"do": "dock", "action": "tile"})
        before = len(notices("Claude Code in garden needs you"))
        said, took, code = agent("click", "Send", "--tab", one)
        print("  click, away:", json.dumps(said)[:600], f"{took:.1f} s", flush=True)
        t.ok("yes", "a click that needs a yes answers needs_you while nobody looks", error(said).get("code") == "needs_you" and code not in (0, None), said)
        t.ok("yes", "it answers after about 20 seconds, not after the 100 s wait", 17 <= took <= 40, took)
        t.ok("yes", "it says the person is away and the question stays up",
             "They are away from Broadway" in error(said).get("message", "") and ((said.get("data") or {}).get("question") or {}).get("away") is True, said)
        t.ok("yes", "it names the command that goes on waiting", "same command again" in (error(said).get("message", "") + error(said).get("hint", "")), said)
        up = desk()
        cards = up.get("pending", [])
        t.ok("yes", "the card stays up", len(cards) == 1 and cards[0]["title"].startswith("Send on"), up)
        t.ok("yes", "the card names the agent and its folder", cards and cards[0]["card"]["who"] == "Claude Code · garden", cards)
        t.ok("badge", "the Dock badge reads 1", up.get("badge") == "1", up)
        tile = bench({"do": "dock"})
        t.ok("badge", "the Dock tile itself carries the 1", tile.get("badgeLabel") == "1", tile)
        sent = notices("Claude Code in garden needs you")
        t.ok("notice", "one notification names the agent and the folder", len(sent) == before + 1, sent)
        t.ok("notice", "it carries the question", sent and sent[-1]["body"].startswith("Send on"), sent)
        shoot("card-away")
        waiting = agent.start("click", "Send", "--tab", one)
        time.sleep(3)
        still = desk().get("pending", [])
        t.ok("yes", "the same click again waits on the same question", not waiting[1].exists() and len(still) == 1, still)
        desk("yes")
        again = agent.finish(waiting, 60)[0]
        t.ok("yes", "the yes lets the click through", again.get("ok") is True, again)
        t.ok("badge", "the badge clears once answered", desk().get("badge") == "" and bench({"do": "dock"}).get("badgeLabel") == "", desk())
        bench({"do": "dock", "action": "leave"})
        t.ok("notice", "no second notification for the same question", len(notices("Claude Code in garden needs you")) == before + 1)

        two_tab = ((other("open", base + "message2")[0]).get("data") or {}).get("id", "")
        said, took, code = other("click", "Send", "--tab", two_tab)
        t.ok("kept", "another session's click answers needs_you while nobody looks", error(said).get("code") == "needs_you" and 17 <= took <= 40, (said, took))
        t.ok("kept", "its hint says the same command again waits", "same command again" in error(said).get("hint", ""), said)
        desk("yes")
        time.sleep(0.5)
        said, took, code = other("click", "Send", "--tab", two_tab)
        t.ok("kept", "a yes given while no command waited lets the next try through at once", said.get("ok") is True and took < 8, (said, took))
        t.ok("kept", "and nothing is asked again", not desk().get("pending"), desk())

        said, took, code = agent("handoff", "Solve the puzzle", "--tab", one)
        t.ok("handoff", "a hand-over answers needs_you early while nobody looks", error(said).get("code") == "needs_you" and 17 <= took <= 40, (said, took))
        t.ok("handoff", "it says the hand-over stays up and the same command again waits",
             "stays up" in error(said).get("message", "") and "same command again" in (error(said).get("message", "") + error(said).get("hint", "")), said)
        t.ok("handoff", "the hand-over stays up", [c["title"] for c in desk().get("pending", [])] == ["Solve the puzzle"], desk())
        waiting = agent.start("handoff", "Solve the puzzle", "--tab", one)
        time.sleep(3)
        t.ok("handoff", "the same handoff again waits for it", not waiting[1].exists() and len(desk().get("pending", [])) == 1, desk())
        desk("pick 1")
        back = agent.finish(waiting, 60)[0]
        t.ok("handoff", "Done gives the tab back to that command", back.get("ok") is True and "gave the tab back" in json.dumps(back), back)

        wall, _, _ = agent("open", base + "login")
        door = (wall.get("data") or {}).get("id", "")
        said, took, code = agent("handoff", "Sign in, please", "--tab", door)
        t.ok("signin", "a sign-in hand-over answers early too", error(said).get("code") == "needs_you", said)
        bench({"do": "go", "id": door, "url": base + "home3"})
        down = wait_for(lambda: not desk().get("pending"), 10)
        t.ok("signin", "past the wall for 3 s, the hand-over ends by itself", bool(down), desk())
        said, took, code = agent("handoff", "Sign in, please", "--tab", door)
        t.ok("signin", "the next try hears the tab was given back", said.get("ok") is True and took < 8, (said, took))

        gone = Agent("three")
        everyone.append(gone)
        gone.start("open", base + "message3")
        gone.start("click", "Send")
        asked = wait_for(lambda: desk().get("pending"), 20)
        t.ok("gone", "a third session asks", bool(asked), asked)
        gone.kill()
        killed = time.time()
        cleared = wait_for(lambda: not desk().get("pending"), 10)
        took = time.time() - killed
        t.ok("gone", "its question comes down at once when the agent ends", bool(cleared) and took < 3, took)

        waiting = agent.start("handoff", "Look at this", "--tab", one)
        wait_for(lambda: desk().get("pending"), 10)
        clicked = desk("notice")
        t.ok("notice", "a click on the notification brings the question's tab to the front",
             clicked.get("active") == one[:8] and clicked.get("tabs") == [one[:8]], clicked)
        stage(False)
        desk("pick 1")
        agent.finish(waiting, 60)
    finally:
        for each in everyone:
            each.kill()
        for pid in subprocess.run(["lsof", "-t", "--", str(FOLDER / "bench.sock")], capture_output=True, text=True).stdout.split():
            subprocess.run(["kill", pid], capture_output=True)
        time.sleep(1)
        shutil.rmtree(FOLDER, ignore_errors=True)
        shutil.rmtree(SCRATCH, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        server.shutdown()
    print(f"agent_away: {t.passed} passed, {t.failed} failed", flush=True)
    sys.exit(1 if t.failed else 0)


main()

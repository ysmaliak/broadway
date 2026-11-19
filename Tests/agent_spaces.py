#!/usr/bin/env python3
"""The agents card in each space, and the asking dot on a space's icon, on a test copy's own window.

Build first (`./build.sh`), then `python3 Tests/agent_spaces.py [LABEL]`. A test copy in a
world of its own, started hidden behind every window, driven by the real `broadway` as two
stand-in agents. Two spaces, Work and Home:

1. card: in Home the card lists only the agents' Home tabs, in Work only the Work tab.
2. press: a row on a space's own card brings its tab and stays in that space.
3. mark: an agent asking on its Home tab while Work is shown puts the asking dot on Home's
   icon at the foot and leaves Work's card quiet. Answered, the dot goes. Asked again and
   Home entered, the dot goes and Home's card asks.

Pictures are of the probe window by its number (screencapture -l), in light and dark. Where
that has no grant (over ssh on the mini) the app draws the window itself instead (bench
picture, pages left out), into its world folder. BROADWAY_APP picks another build. Out: .context/agent-spaces/LABEL.
"""
import json
import os
import shutil
import signal
import socket
import struct
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
WORLD = f"agentspaces-{os.getpid()}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = ROOT / ".context/agent-spaces" / LABEL
SIZE = (1180, 760)
SIDE = 260

CLAUDE = {"BROADWAY_AGENT": "claude-spaces", "BROADWAY_AGENT_NAME": "Claude Code"}
MAILER = {"BROADWAY_AGENT": "mailer-spaces", "BROADWAY_AGENT_NAME": "Mail sorter"}

PAGE = b"""<!doctype html><title>%s</title><body style="margin:0;background:#f4f4f2;font:16px system-ui">
<h1 style="margin:40px">%s</h1><div style="height:3000px"></div>"""


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = PAGE % (name.capitalize().encode(), name.capitalize().encode())
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class T:
    def __init__(self):
        self.passed, self.failed, self.lines = 0, 0, []

    def ok(self, point, name, cond, extra=""):
        line = f"{'ok  ' if cond else 'FAIL'} [{point}] {name}" + ("" if cond else f"  {str(extra)[:400]}")
        print(" ", line, flush=True)
        self.lines.append(line)
        if cond:
            self.passed += 1
        else:
            self.failed += 1


t = T()


def environment(env):
    made = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_")}
    made.update(env or {})
    return made


def broadway(*words, env=None, timeout=60):
    result = subprocess.run([BROADWAY, "--world", WORLD, *words, "--json"], capture_output=True, text=True,
                            stdin=subprocess.DEVNULL, env=environment(env), timeout=timeout)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "raw": result.stdout + result.stderr}


def bench(request, timeout=30):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
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


def spaces(action="state", **more):
    return bench(dict({"do": "space", "action": action}, **more))


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def short(tab):
    return tab.lower()[:8]


def listed():
    return {row["name"]: [short(tab) for tab in row["tabs"]] for row in agents("state").get("area", [])}


def marks():
    return {mark["name"]: mark.get("asking", False) for mark in (spaces().get("foot") or {}).get("marks", [])}


def go(index):
    spaces("go", index=index)
    time.sleep(0.6)


def picture(name, dark):
    window = agents("stage", dark=dark, size=list(SIZE), shown=False).get("window")
    time.sleep(0.8)
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}-{'dark' if dark else 'light'}.png"
    path.unlink(missing_ok=True)
    if window:
        subprocess.run(["screencapture", "-x", "-o", "-l", str(window), str(path)], capture_output=True, stdin=subprocess.DEVNULL)
    if not path.exists():
        print(f"  no window picture for {path.name}, the app draws it instead", flush=True)
        drawn = FOLDER / path.name
        try:
            said = bench({"do": "picture", "path": str(drawn), "page": False, "webs": False}, timeout=60)
        except (TimeoutError, OSError) as error:
            said = str(error)
        if drawn.exists():
            shutil.move(str(drawn), str(path))
        if not path.exists():
            print(f"  no picture for {path.name}: {said}", flush=True)
            return None
    with open(path, "rb") as file:
        width, height = struct.unpack(">II", file.read(24)[16:24])
    scale = width / SIZE[0]
    tall = int(300 * scale)
    foot = OUT / f"{path.stem}-sidebar.png"
    crop = f"crop={int(SIDE * scale)}:{tall}:0:{height - tall},scale=iw*3:ih*3:flags=neighbor"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(path), "-vf", crop, str(foot)], capture_output=True,
                   stdin=subprocess.DEVNULL)
    return path


def pictures(name):
    for dark in (False, True):
        picture(name, dark)
    agents("stage", dark=False, size=list(SIZE), shown=False)


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "bench.sock")], capture_output=True, text=True).stdout.split()


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
    asking = None
    try:
        for key in ("bench", "agents.on", "spaces"):
            subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "sidebar.width", "-float", str(SIDE)], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        wait_for(lambda: (FOLDER / "bench.sock").exists(), 30)
        time.sleep(2)
        bench({"do": "window"})
        agents("stage", dark=False, size=list(SIZE), shown=False)
        pid = (held() or [None])[0]
        spaces("rename", name="Work", icon="briefcase")
        spaces("new", name="Home")
        time.sleep(0.8)
        spaces("rename", name="Home", icon="house")
        names = [space["name"] for space in spaces()["spaces"]]
        ids = {space["name"]: space["id"] for space in spaces()["spaces"]}
        t.ok("setup", "two spaces, Work then Home", names == ["Work", "Home"], names)

        go(1)
        report = broadway("open", base + "report", env=CLAUDE)["data"]["id"]
        go(2)
        mail = broadway("open", base + "mail", env=CLAUDE)["data"]["id"]
        inbox = broadway("open", base + "inbox", env=MAILER)["data"]["id"]
        for tab, env in ((report, CLAUDE), (mail, CLAUDE), (inbox, MAILER)):
            broadway("wait", "--tab", tab, env=env)
        time.sleep(0.8)
        listed_tabs = agents("state").get("listed", [])

        home = wait_for(lambda: (lambda shown: shown if len(shown) == 2 else None)(listed()), 10) or listed()
        t.ok("card", "Home's card lists Claude Code's Home tab only",
             home.get("Claude Code") == [short(mail)], (home, mail))
        t.ok("card", "Home's card lists the mail sorter's Home tab", home.get("Mail sorter") == [short(inbox)], home)
        t.ok("card", "the sidebar list keeps the card's tabs out", not any(short(tab) in (short(mail), short(inbox)) for tab in listed_tabs), listed_tabs)
        pictures("card-home")

        claude = next(row for row in agents("state")["area"] if row["name"] == "Claude Code")
        agents("row", link=claude["id"][:8], index=0)
        time.sleep(0.5)
        here = spaces()
        front = [short(tab["id"]) for tab in agents("state").get("agentTabs", []) if tab.get("active")]
        t.ok("press", "a row on Home's card brings its tab and stays in Home", here["current"] == "Home" and front == [short(mail)], (here["current"], front, mail))

        go(1)
        work = listed()
        t.ok("card", "Work's card lists only Claude Code's Work tab",
             list(work) == ["Claude Code"] and work["Claude Code"] == [short(report)], work)
        line = agents("state").get("row", {})
        t.ok("card", "Work's card speaks of one agent", line.get("title") == "Agents" and line.get("line", "").startswith("Claude Code"), line)
        pictures("card-work")

        agents("mode", mode="ask")
        asking = subprocess.Popen([BROADWAY, "--world", WORLD, "scroll", "600", "--tab", mail, "--json"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL, env=environment(CLAUDE))
        lit = wait_for(lambda: ids["Home"] in agents("state").get("askingSpaces", []), 15)
        t.ok("mark", "an ask on a Home tab while Work is shown marks Home", bool(lit), agents("state").get("askingSpaces"))
        t.ok("mark", "the foot's Home icon carries the dot and Work's does not", marks() == {"Work": False, "Home": True}, marks())
        quiet = next((row for row in agents("state")["area"] if row["name"] == "Claude Code"), {})
        t.ok("mark", "Work's card stays quiet", quiet.get("attention") is False, quiet)
        pictures("mark")
        agents("answer", **{"with": "no"})
        out, err = asking.communicate(timeout=30)
        asking = None
        gone = wait_for(lambda: not agents("state").get("askingSpaces"), 10)
        t.ok("mark", "answered, the dot goes", bool(gone) and not any(marks().values()), marks())
        pictures("mark-answered")

        asking = subprocess.Popen([BROADWAY, "--world", WORLD, "ask", "Which account?", "--choice", "Work", "--choice", "Personal",
                                   "--tab", mail, "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  stdin=subprocess.DEVNULL, env=environment(CLAUDE))
        lit = wait_for(lambda: ids["Home"] in agents("state").get("askingSpaces", []), 15)
        if not lit and asking.poll() is not None:
            print("  the second ask ended:", asking.communicate()[0][:400], flush=True)
        go(2)
        entered = agents("state")
        own = next((row for row in entered.get("area", []) if row["name"] == "Claude Code"), {})
        t.ok("mark", "asked again while Work is shown, Home is marked again", bool(lit), agents("state").get("askingSpaces"))
        t.ok("mark", "Home entered, the dot goes and Home's card asks", not entered.get("askingSpaces") and own.get("attention") is True and not any(marks().values()), (entered.get("askingSpaces"), own))
        pictures("card-home-asking")
        agents("answer", **{"with": "1"})
        asking.communicate(timeout=30)
        asking = None
        agents("mode", mode="auto")
    finally:
        if asking:
            asking.kill()
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

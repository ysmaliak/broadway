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
4. lead: Home has two agents, so each has a heading that is the tab it is on in Home, with
   its other Home tabs folded under it. Work has one, so its tab sits under the row with no
   heading. The agent that asks in Home has the asking tab as its heading, still shut.
5. switch: a switch of space draws the other space's card at once, with no travel or fade.
6. place: with Work on screen, an agent working in a folder under .../personal/... opens its first
   tab in a third space, Personal, and the answer says so. Its tabs follow its session, a move
   teaches the folder, --space teaches it too, and BROADWAY_SPACE names a space for a session.

Every agent runs in a folder of the probe's own, so the checkout's path never matches a space.

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
NEUTRAL = FOLDER / "agents" / "plain"
PERSONAL = FOLDER / "agents" / "personal" / "site"

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


def broadway(*words, env=None, timeout=60, cwd=None):
    result = subprocess.run([BROADWAY, "--world", WORLD, *words, "--json"], capture_output=True, text=True,
                            stdin=subprocess.DEVNULL, env=environment(env), timeout=timeout, cwd=str(cwd or NEUTRAL))
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "raw": result.stdout + result.stderr}


def said(*words, env=None, cwd=None):
    result = subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True,
                            stdin=subprocess.DEVNULL, env=environment(env), timeout=60, cwd=str(cwd or NEUTRAL))
    return result.stdout.strip().split("\n")[0], result.stderr


def space_of(tab):
    rows = broadway("tabs", "list", "--all").get("data", {}).get("tabs", [])
    return next((row.get("space") for row in rows if short(row.get("id", "")) == short(tab)), None)


def placed(env, url, *more, cwd=None):
    data = broadway("open", url, *more, env=env, cwd=cwd).get("data", {})
    return data.get("id", ""), data.get("space") or {}


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


def lead():
    return bench({"do": "agentcard"})


def switched(index):
    spaces("go", index=index)
    seen = []
    until = time.time() + 0.9
    while time.time() < until:
        card = lead().get("card") or {}
        seen.append((bool(card.get("moving")), bool(card.get("fading")), round(card.get("room", 0), 2)))
        time.sleep(0.03)
    return seen


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
        for folder in (NEUTRAL, PERSONAL):
            (folder / ".git").mkdir(parents=True, exist_ok=True)
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
        mail = broadway("open", base + "mail", "--space", "Home", env=CLAUDE)["data"]["id"]
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

        calendar = broadway("open", base + "calendar", env=CLAUDE)["data"]["id"]
        broadway("wait", "--tab", calendar, env=CLAUDE)
        if agents("state").get("folded"):
            agents("fold")
        time.sleep(1.2)
        at_home = lead()
        rows = {row["title"]: row for row in at_home.get("agents", [])}
        seen = {head["title"]: head for head in (at_home.get("card") or {}).get("heads", [])}
        ours, theirs = seen.get("Claude Code", {}), seen.get("Mail sorter", {})
        t.ok("lead", "Home has two agents, so each has a heading with its fold shut",
             len(seen) == 2 and len(rows) == 2 and all(row["headed"] and not row["open"] and row["rows"] == 0 for row in rows.values()), at_home.get("agents"))
        t.ok("lead", "Claude Code's heading counts its one other Home tab and the mail sorter's has no count",
             ours.get("countText") == "1" and ours.get("countShown") is True and theirs.get("countShown") is False, (ours, theirs))
        t.ok("lead", "the heading is one of the agent's Home tabs, not its Work tab",
             short(rows.get("Claude Code", {}).get("lead", "")) in (short(mail), short(calendar)), rows.get("Claude Code"))
        home_room = (at_home.get("card") or {}).get("room", 0)
        t.ok("lead", "Home's card is its row and two headings tall", abs(home_room - (34 + 2 * 37 + 18)) < 0.01, home_room)
        pictures("card-home-open")

        frames = switched(1)
        at_work = lead()
        alone = at_work.get("agents", [])
        work_room = (at_work.get("card") or {}).get("room", 0)
        t.ok("switch", "Home to Work: the card neither travels nor fades", bool(frames) and not any(moving or fading for moving, fading, _ in frames), frames)
        t.ok("switch", "it is Home's height and then Work's, with nothing between", {room for _, _, room in frames} <= {round(home_room, 2), round(work_room, 2)}
             and frames[-1][2] == round(work_room, 2), (home_room, work_room, frames))
        t.ok("lead", "Work has one agent, so its tab sits under the row with no heading",
             len(alone) == 1 and not alone[0]["headed"] and alone[0]["rows"] == 1 and not (at_work.get("card") or {}).get("heads")
             and abs(work_room - (34 + 37 + 18)) < 0.01, (alone, work_room))
        work = listed()
        t.ok("card", "Work's card lists only Claude Code's Work tab",
             list(work) == ["Claude Code"] and work["Claude Code"] == [short(report)], work)
        line = agents("state").get("row", {})
        t.ok("card", "Work's card speaks of one agent", line.get("title") == "Agents" and line.get("line", "").startswith("Claude Code"), line)
        pictures("card-work")

        agents("mode", mode="ask")
        asking = subprocess.Popen([BROADWAY, "--world", WORLD, "scroll", "600", "--tab", mail, "--json"], stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL, env=environment(CLAUDE), cwd=str(NEUTRAL))
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
                                  stdin=subprocess.DEVNULL, env=environment(CLAUDE), cwd=str(NEUTRAL))
        lit = wait_for(lambda: ids["Home"] in agents("state").get("askingSpaces", []), 15)
        if not lit and asking.poll() is not None:
            print("  the second ask ended:", asking.communicate()[0][:400], flush=True)
        go(2)
        entered = agents("state")
        own = next((row for row in entered.get("area", []) if row["name"] == "Claude Code"), {})
        t.ok("mark", "asked again while Work is shown, Home is marked again", bool(lit), agents("state").get("askingSpaces"))
        t.ok("mark", "Home entered, the dot goes and Home's card asks", not entered.get("askingSpaces") and own.get("attention") is True and not any(marks().values()), (entered.get("askingSpaces"), own))
        asked = lead()
        row = next((each for each in asked.get("agents", []) if each["title"] == "Claude Code"), {})
        head = next((each for each in (asked.get("card") or {}).get("heads", []) if each["title"] == "Claude Code"), {})
        t.ok("lead", "the asking agent's heading is the tab that asks, with the question, and its fold stays shut",
             short(row.get("lead", "")) == short(mail) and row.get("open") is False and head.get("attention") is True
             and "Which account?" in head.get("line", ""), (row, head))
        pictures("card-home-asking")
        agents("answer", **{"with": "1"})
        asking.communicate(timeout=30)
        asking = None
        agents("mode", mode="auto")

        spaces("new", name="Personal")
        time.sleep(0.8)
        go(1)
        site = {"BROADWAY_AGENT": "site-spaces", "BROADWAY_AGENT_NAME": "Site builder"}
        first, words = said("open", base + "landing", env=site, cwd=PERSONAL)
        t.ok("place", "Work on screen, an agent in .../personal/... opens its first tab in Personal",
             space_of(first) == "Personal" and spaces()["current"] == "Work", (first, space_of(first), spaces()["current"]))
        t.ok("place", "the answer says where and why, and how to pick another",
             "In Personal, matching ~/" in words and "/personal." in words and "broadway open URL --space NAME" in words, words)
        second, where = placed(site, base + "pricing", cwd=PERSONAL)
        t.ok("place", "its next tab follows the session there, and the words are not said again",
             space_of(second) == "Personal" and where.get("name") == "Personal" and where.get("first") is False
             and where.get("why", "").startswith("matching ~/"), (space_of(second), where))
        go(3)
        moved = broadway("tabs", "move", second, "--space", "Work", env=site, cwd=PERSONAL)
        go(1)
        third, where = placed(site, base + "contact", cwd=PERSONAL)
        t.ok("place", "a tab moved to Work takes the session with it",
             moved.get("ok") and space_of(third) == "Work" and where.get("why") == "where the person moved your tab"
             and where.get("first") is True, (moved, space_of(third), where))
        again = {"BROADWAY_AGENT": "site-spaces-2", "BROADWAY_AGENT_NAME": "Site builder"}
        fourth, where = placed(again, base + "about", cwd=PERSONAL)
        t.ok("place", "the folder learned it: the next session there opens in Work",
             space_of(fourth) == "Work" and where.get("why") == "where this folder's sessions go", (space_of(fourth), where))
        fifth, where = placed(again, base + "blog", "--space", "Home", cwd=PERSONAL)
        t.ok("place", "--space opens in that space and says the folder keeps it",
             space_of(fifth) == "Home" and where.get("why") == "as asked" and where.get("kept") is True, (space_of(fifth), where))
        later = {"BROADWAY_AGENT": "site-spaces-3", "BROADWAY_AGENT_NAME": "Site builder"}
        sixth, where = placed(later, base + "faq", cwd=PERSONAL)
        t.ok("place", "and the session after that opens in Home", space_of(sixth) == "Home" and where.get("why") == "where this folder's sessions go",
             (space_of(sixth), where))
        told = dict(later, BROADWAY_SPACE="personal", BROADWAY_AGENT="site-spaces-4")
        seventh, where = placed(told, base + "terms")
        t.ok("place", "BROADWAY_SPACE names the session's space", space_of(seventh) == "Personal" and where.get("why") == "from BROADWAY_SPACE",
             (space_of(seventh), where))
        plain = {"BROADWAY_AGENT": "plain-spaces", "BROADWAY_AGENT_NAME": "Plain"}
        eighth, where = placed(plain, base + "plain")
        t.ok("place", "a folder that matches nothing opens in the space on screen", space_of(eighth) == "Work" and where.get("why") == "the space on screen",
             (space_of(eighth), where))
        wrong = broadway("open", base + "nowhere", "--space", "Garden", env=plain)
        t.ok("place", "a space that doesn't exist is refused with the names", not wrong.get("ok")
             and "Garden" in (wrong.get("error") or {}).get("message", "") and "Personal" in (wrong.get("error") or {}).get("hint", ""), wrong)
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

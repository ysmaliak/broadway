#!/usr/bin/env python3
"""The agent card, its tab's colour and its messages, on a test copy's own window.

Build first (`./build.sh`), then `python3 Tests/agent_card.py [LABEL]`. A test copy
in a world of its own, started hidden behind every window, driven by the real
`broadway` as three agents. Four checks, each failing on the build before:

1. card: the Agents area sits in the player's glass card, with the player's inset,
   radius and gap, over the player and the update card.
2. fold: a press folds and unfolds the card by easing its height, the list above
   following it, with no jump on the first or last frame, a reversal carried on
   from where it is, and a short crossfade with Reduce Motion.
   enter, leave: the first agent's card makes room over many frames and the last
   one's closes it the same way.
   lead: with several agents each heading is the tab its agent is on, its other
   tabs fold under it and start shut, the count is a folder's count, on hover it
   gives way to the sidebar's close button, and needs you opens nothing.
3. rim: the agent's tab wears the agent's colour round its page, another tab does
   not, and in Split View only the agent's pane does.
4. pills: what the agent is doing and "You're driving" show at the bottom of the
   page, nearest the edge, under another bar, and with the sidebar hidden.

Pictures are of the probe window by its id only. The fold's motion is read from the
height the card laid out on each display frame, which the bench keeps. BROADWAY_APP picks
another build (the one before, for its failures). Out: .context/agent-card/LABEL.
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
WORLD = f"agentcard-{os.getpid()}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = ROOT / ".context/agent-card" / LABEL
SIZE = (1180, 760)
SHOT = ROOT / ".build/agent-card-shot"
SIDE = 260
WINDOW = [0]
PID = [0]

CLAUDE = {"BROADWAY_AGENT": "claude-card", "BROADWAY_AGENT_NAME": "Claude Code"}
CODEX = {"BROADWAY_AGENT": "codex-card", "BROADWAY_AGENT_NAME": "Codex"}
SCRIPT = {"BROADWAY_AGENT": "script-card", "BROADWAY_AGENT_NAME": "Nightly check"}
MAIL = {"BROADWAY_AGENT": "mail-card", "BROADWAY_AGENT_NAME": "Mail sorter"}
WARM = {"BROADWAY_AGENT": "warm-card", "BROADWAY_AGENT_NAME": "Warm up"}

LOOKS = {
    "noir": {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45, "glass": False},
    "pale": {"custom": "FFF1C9", "intensity": 0.8, "transparency": 0.0, "grain": 0.0, "glass": False},
    "navy": {"custom": "000354", "intensity": 0.9, "transparency": 0.0, "grain": 0.0, "glass": False},
    "blue": {"custom": "3139FB", "intensity": 0.8, "transparency": 0.0, "grain": 0.0, "glass": False},
}

PAGE = b"""<!doctype html><title>%s</title><body style="margin:0;background:#f4f4f2;font:16px system-ui">
<h1 style="margin:40px">%s</h1><input id="q" placeholder="Search" style="font-size:20px;width:300px;margin:0 40px">
<div style="height:3000px"></div>"""
CLIP = OUT / "clip.mp4"


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/clip.mp4"):
            data = CLIP.read_bytes()
            self.send_response(200)
            self.send_header("content-type", "video/mp4")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            try:
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        name = self.path.strip("/") or "home"
        body = PAGE % (name.encode(), name.encode())
        if name == "music":
            body = b"<!doctype html><title>Music</title><p>music</p><audio id=t src='/clip.mp4' loop></audio><script>" \
                   b"navigator.mediaSession.metadata = new MediaMetadata({title: 'A Long Song', artist: 'A Band'});</script>"
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


def agents(action, **more):
    return bench(dict({"do": "agents", "action": action}, **more))


def sp(action, **more):
    return bench(dict({"do": "split", "action": action}, **more))


def chrome():
    return agents("state").get("chrome") or {}


def area():
    return agents("state").get("area", [])


def card(named):
    return next((row for row in area() if named == row["name"] or named.startswith(row["title"])), None)


def lead():
    return bench({"do": "agentcard"})


def lead_do(action, link=""):
    return bench({"do": "agentcard", "action": action, "link": link})


def heads():
    return {head["title"]: head for head in (lead().get("card") or {}).get("heads", [])}


def agent(title):
    return next((row for row in lead().get("agents", []) if row["title"] == title), {})


def looks_shots(name):
    for dark in (False, True):
        stage(dark)
        for each in LOOKS:
            look(each)
            foot_shot(f"{name}-{each}-{'dark' if dark else 'light'}")
    stage(False)
    look("pale")


def beside(name, boxes):
    path = shoot(name)
    if not path:
        return
    pic = Picture(path)
    parts = []
    for index, box in enumerate(boxes):
        x, y, w, h = [int(v * pic.k) for v in box]
        part = OUT / f"{name}-{index}.png"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(path), "-vf", f"crop={w}:{h}:{x}:{y},scale=iw*3:ih*3:flags=neighbor",
                        str(part)], capture_output=True, stdin=subprocess.DEVNULL)
        parts.append(part)
    if len(parts) == 2 and all(part.exists() for part in parts):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(parts[0]), "-i", str(parts[1]), "-filter_complex",
                        "[0:v][1:v]scale2ref=iw:ow/mdar[a][b];[b][a]vstack", str(OUT / f"{name}-beside.png")],
                       capture_output=True, stdin=subprocess.DEVNULL)


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def stage(dark, shown=False):
    said = agents("stage", dark=dark, size=list(SIZE), shown=shown)
    WINDOW[0] = said["window"]
    PID[0] = said["pid"]
    time.sleep(0.8)


def look(name):
    bench({"do": "space", "action": "look", **LOOKS[name]})
    time.sleep(0.6)


class Picture:
    def __init__(self, path, across=None, origin=(0, 0)):
        self.path = path
        with open(path, "rb") as file:
            head = file.read(24)
        self.w, self.h = struct.unpack(">II", head[16:24])
        self.k = self.w / (across or SIZE[0])
        self.ox, self.oy = origin
        self.raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
                                  capture_output=True).stdout

    def at(self, x, y):
        px, py = int((x - self.ox) * self.k), int((y - self.oy) * self.k)
        px, py = min(max(px, 0), self.w - 1), min(max(py, 0), self.h - 1)
        i = (py * self.w + px) * 3
        return tuple(self.raw[i:i + 3])

    def at_px(self, px, py):
        i = (py * self.w + px) * 3
        return tuple(self.raw[i:i + 3])


def far(a, b):
    return max(abs(x - y) for x, y in zip(a, b))


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    said = ""
    for attempt in range(8):
        said = subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True, text=True).stderr
        if path.exists():
            return path
        if attempt % 3 == 2:
            WINDOW[0] = agents("stage")["window"]
            subprocess.run([str(SHOT), str(PID[0]), str(WINDOW[0]), str(path)], capture_output=True, timeout=60)
            if path.exists():
                return path
        time.sleep(0.5)
    print(f"  no picture of window {WINDOW[0]} for {name}: {said.strip()}", flush=True)
    return None


def crop(path, name, box):
    if not path:
        return
    pic = Picture(path)
    x, y, w, h = [int(v * pic.k) for v in box]
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(path), "-vf", f"crop={w}:{h}:{x}:{y}", str(OUT / name)],
                   capture_output=True)


def foot_shot(name):
    path = shoot(name)
    crop(path, f"{name}-foot.png", (0, SIZE[1] - 420, SIDE + 10, 420))
    return path


def moved(name, act=None, wait=1.0):
    (act or (lambda: agents("press")))()
    time.sleep(wait)
    card = chrome().get("card") or {}
    (OUT / "films").mkdir(parents=True, exist_ok=True)
    (OUT / "films" / f"{name}.json").write_text(json.dumps(card, indent=1))
    return card.get("trace") or [], card


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "bench.sock")], capture_output=True, text=True).stdout.split()


def accent_of(name):
    found = card(name)
    hues = [(0.13, 0.66, 0.80), (0.42, 0.50, 0.92), (0.56, 0.38, 0.88), (0.84, 0.30, 0.64), (0.93, 0.42, 0.34), (0.24, 0.62, 0.42)]
    hue = hues[found["accent"] % 6]
    return tuple(round(v * 255) for v in hue)


def pane(id8):
    frames = sp("state").get("paneFrames", [])
    return next((f for f in frames if f["id"] == id8), None)


def edge_colour(pic, frame):
    y = frame["y"] + frame["height"] / 2
    return pic.at(frame["x"] + 0.75, y)


def card_checks(where):
    said = chrome()
    box = (said.get("card") or {}).get("box")
    mini = said.get("mini")
    foot = said.get("foot")
    update = said.get("update")
    t.ok("card", f"{where}: the Agents area has a glass card", bool(box) and (said.get("card") or {}).get("glass") is True, said.get("card"))
    if not box:
        return said
    if mini:
        t.ok("card", f"{where}: the card has the player's side insets", abs(box[0] - mini[0]) < 0.6 and abs(box[2] - mini[2]) < 0.6, (box, mini))
        t.ok("card", f"{where}: the card is the player's gap above it", abs(mini[1] - (box[1] + box[3]) - 8) < 0.6, (box, mini))
    nxt = mini or update or foot
    if nxt and update and mini:
        t.ok("card", f"{where}: the player and the update card share the gap", abs(update[1] - (mini[1] + mini[3]) - 8) < 0.6, (mini, update))
    t.ok("card", f"{where}: the card's radius is the player's", (said.get("card") or {}).get("radius") == 14, said.get("card"))
    return said


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "Tests/WindowShot.swift").read_text().replace("        let args = CommandLine.arguments\n",
                                                                   "        _ = NSApplication.shared\n        let args = CommandLine.arguments\n", 1)
    (SHOT.parent / "agent-card-shot.swift").write_text(source)
    subprocess.run(["swiftc", "-O", "-parse-as-library", str(SHOT.parent / "agent-card-shot.swift"), "-o", str(SHOT)], check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    pid = None
    try:
        for key in ("bench", "agents.on"):
            subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "motion.testReduced", "-bool", "false"], check=True)
        subprocess.run(["defaults", "write", SUITE, "motion.testLowPower", "-bool", "false"], check=True)
        subprocess.run(["defaults", "write", SUITE, "sidebar.width", "-float", str(SIDE)], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        wait_for(lambda: (FOLDER / "bench.sock").exists(), 30)
        time.sleep(2)
        bench({"do": "window"})
        stage(False)
        pid = (held() or [None])[0]
        loose = [sp("open", url=base + f"loose-{n}", foreground=True).get("resultID") for n in range(5)]
        time.sleep(1)

        before = chrome().get("card") or {}
        broadway("open", base + "warm", env=WARM)
        time.sleep(1.5)
        entered = chrome().get("card") or {}
        rooms = [r for _, r in entered.get("trace") or []]
        t.ok("enter", "with no agent there is no card", not before.get("room"), before)
        t.ok("enter", "the first agent's card makes room over many frames", len(rooms) >= 8 and rooms[0] < rooms[-1] / 2, rooms)
        t.ok("enter", "the room only grows, to the folded card's height", bool(rooms) and all(b >= a - 0.01 for a, b in zip(rooms, rooms[1:]))
             and abs(rooms[-1] - 52) < 0.01, rooms)
        t.ok("enter", "entered, the card is drawn in full and at rest",
             entered.get("presence") == 1 and not entered.get("fading") and not entered.get("moving"), entered)
        warm = card("Warm up") or {}
        agents("closelink", link=warm.get("id", "")[:8])
        broadway("agents", "done", env=WARM)
        gone = wait_for(lambda: (lambda c: c if not c.get("room") and not c.get("moving") else None)(chrome().get("card") or {}), 6) or {}
        rooms = [r for _, r in gone.get("trace") or []]
        t.ok("leave", "the last agent gone, the room closes over many frames", len(rooms) >= 8 and rooms[0] > 26, rooms)
        t.ok("leave", "the room only shrinks, to nothing", bool(rooms) and all(b <= a + 0.01 for a, b in zip(rooms, rooms[1:]))
             and abs(rooms[-1]) < 0.01, rooms)
        time.sleep(0.5)

        one = broadway("open", base + "pulls", env=CLAUDE)["data"]["id"]
        broadway("open", base + "issue-42", env=CLAUDE)
        broadway("wait", "--tab", one, env=CLAUDE)
        time.sleep(0.8)
        claude = card("Claude Code")
        t.ok("rule", "a fresh world starts folded, and an agent connecting and opening tabs leaves it folded",
             agents("state").get("folded") is True, agents("state").get("folded"))
        t.ok("faces", "a newly connected agent wears its hello or working face", claude and claude.get("face") in ("hello", "reading", "typing", "idle"), claude)
        agents("row", link=claude["id"][:8], index=0)
        time.sleep(0.6)
        faces = (chrome().get("card") or {}).get("faces") or []
        t.ok("faces", "with the window hidden no face runs a loop", bool(faces) and all(not f["looping"] and f["loops"] == 0 for f in faces), faces)
        stage(False, shown=True)
        time.sleep(1.0)
        faces = (chrome().get("card") or {}).get("faces") or []
        if faces and all(f.get("visible") for f in faces):
            t.ok("faces", "shown, the face's idle loop runs on Core Animation", all(f["looping"] and f["loops"] > 0 for f in faces), faces)
        else:
            print("  skip [faces] shown: macOS reports the window covered on this Mac, so the face rightly stays still", faces, flush=True)
        stage(False)
        time.sleep(0.5)
        faces = (chrome().get("card") or {}).get("faces") or []
        t.ok("faces", "hidden again, the loop stops", bool(faces) and all(not f["looping"] and f["loops"] == 0 for f in faces), faces)
        for dark in (False, True):
            stage(dark)
            for name in LOOKS:
                look(name)
                foot_shot(f"pic-1-one-folded-{name}-{'dark' if dark else 'light'}")
        stage(False)
        look("pale")
        card_checks("one agent, folded")

        if agents("state").get("folded"):
            agents("press")
            time.sleep(1.0)
        for dark in (False, True):
            stage(dark)
            for name in LOOKS:
                look(name)
                foot_shot(f"pic-2-one-open-{name}-{'dark' if dark else 'light'}")
        stage(False)
        look("pale")
        listed = (chrome().get("card") or {}).get("listed") or []
        gaps = [round(b[1] - (a[1] + a[3]), 2) for a, b in zip(listed, listed[1:])]
        t.ok("rows", "unfolded, an agent's tab rows are the regular row's height", bool(listed) and all(abs(f[3] - 34) < 0.01 for f in listed), listed)
        t.ok("rows", "the rows keep the regular gap above and between them", bool(listed) and abs(listed[0][1] - 3) < 0.01 and all(abs(g - 3) < 0.01 for g in gaps), listed)

        codex_tab = broadway("open", base + "release-notes", env=CODEX)["data"]["id"]
        checks = [broadway("open", base + f"check-{n}", env=CODEX)["data"]["id"] for n in range(2)]
        for tab in [codex_tab] + checks:
            broadway("wait", "--tab", tab, env=CODEX)
        agents("row", link=claude["id"][:8], index=0)
        time.sleep(1.0)
        two = lead()
        both = {row["title"]: row for row in two.get("agents", [])}
        seen = heads()
        codex = both.get("Codex", {})
        t.ok("lead", "two agents: each has a heading and every fold starts shut",
             len(seen) == 2 and len(both) == 2 and all(row["headed"] and not row["open"] and row["rows"] == 0 for row in both.values()), two.get("agents"))
        t.ok("lead", "the count is the number of tabs in the fold, with no plus",
             (seen.get("Claude Code", {}).get("countText"), seen.get("Codex", {}).get("countText")) == ("1", "2")
             and all(head["countShown"] for head in seen.values()), seen)
        t.ok("lead", "shut, the card is its row and two headings tall", abs((two.get("card") or {}).get("room", 0) - (34 + 2 * 37 + 18)) < 0.01,
             (two.get("card") or {}).get("room"))
        broadway("scroll", "--tab", codex_tab, env=CODEX)
        first = wait_for(lambda: (lambda row: row if row.get("lead", "")[:8].lower() == codex_tab[:8].lower() else None)(agent("Codex")), 5) or agent("Codex")
        t.ok("lead", "the heading names the tab the agent is on", "release-notes" in first.get("line", ""), first)
        broadway("scroll", "--tab", checks[1], env=CODEX)
        moved_on = wait_for(lambda: (lambda row: row if row.get("lead", "")[:8].lower() == checks[1][:8].lower() else None)(agent("Codex")), 5) or agent("Codex")
        t.ok("lead", "and follows it to another tab", "check-1" in moved_on.get("line", ""), moved_on)
        time.sleep(2.5)
        rested = agent("Codex")
        t.ok("lead", "and stays there once the agent rests", rested.get("lead", "")[:8].lower() == checks[1][:8].lower(), rested)

        folder_tabs = loose[3:5]
        bench({"do": "group", "id": folder_tabs[0], "new": True, "name": "Reading"})
        bench({"do": "group", "id": folder_tabs[1], "name": "Reading"})
        bench({"do": "group", "name": "Reading", "fold": True})
        time.sleep(1.0)
        for dark in (False, True):
            stage(dark)
            look("pale")
            said = lead()
            folder = next((row for row in said.get("folders", []) if row["name"] == "Reading"), {})
            head = next((row for row in (said.get("card") or {}).get("heads", []) if row["title"] == "Codex"), {})
            mode = "dark" if dark else "light"
            if folder and head:
                beside(f"count-match-{mode}", [folder["box"], head["box"]])
            fbox, cbox = folder.get("countBox") or [0, 0, 0, 0], head.get("countBox") or [0, 0, 0, 1]
            hbox, abox = folder.get("box") or [0, 0, 0, 0], head.get("box") or [0, 0, 0, 0]
            t.ok("lead", f"{mode}: a folded folder of two tabs and the agent's heading both show 2",
                 folder.get("countText") == "2" and head.get("countText") == "2" and folder.get("countShown") and head.get("countShown"), (folder, head))
            t.ok("lead", f"{mode}: the two counts are the same size", abs(fbox[2] - cbox[2]) < 0.01 and abs(fbox[3] - cbox[3]) < 0.01 and cbox[3] == 17, (fbox, cbox))
            t.ok("lead", f"{mode}: each sits ten points from its row's end, in the row's middle",
                 abs((hbox[0] + hbox[2]) - (fbox[0] + fbox[2]) - 10) < 0.01 and abs((abox[0] + abox[2]) - (cbox[0] + cbox[2]) - 10) < 0.01
                 and abs((fbox[1] + fbox[3] / 2) - (hbox[1] + hbox[3] / 2)) < 0.51 and abs((cbox[1] + cbox[3] / 2) - (abox[1] + abox[3] / 2)) < 0.51,
                 (hbox, fbox, abox, cbox))
        stage(False)
        look("pale")
        looks_shots("pic-3-two-shut")

        shut_room = (lead().get("card") or {}).get("room", 0)
        trace, rest = moved("agent-unfold", lambda: lead_do("open", codex.get("id", "")[:8]))
        rooms = [r for _, r in trace]
        opened, row = heads().get("Codex", {}), agent("Codex")
        listed = (rest or {}).get("listed") or []
        t.ok("lead", "opened, the fold lists the agent's other tabs and the count goes, as a folder's does",
             row.get("open") and row.get("rows") == 2 and opened.get("open") and not opened.get("countShown"), (row, opened))
        t.ok("lead", "headings sit at the card's edge and the fold's rows are set in", sorted({round(f[0]) for f in listed}) == [0, 12] and len(listed) == 4, listed)
        t.ok("lead", "opening an agent eases the card's height over many frames", len(rooms) >= 8 and abs(rooms[-1] - shut_room - 74) < 0.01
             and all(b >= a - 0.01 for a, b in zip(rooms, rooms[1:])), (shut_room, rooms))
        looks_shots("pic-3-two-open")
        trace, rest = moved("agent-fold", lambda: lead_do("open", codex.get("id", "")[:8]))
        rooms = [r for _, r in trace]
        t.ok("lead", "folding it eases the height back", len(rooms) >= 8 and abs(rooms[-1] - shut_room) < 0.01, (shut_room, rooms))

        for n in range(3):
            broadway("open", base + f"mail-{n}", env=MAIL)
        broadway("open", base + "status", env=SCRIPT)
        for n in range(2):
            broadway("open", base + f"night-{n}", env=SCRIPT)
        agents("row", link=claude["id"][:8], index=0)
        time.sleep(1.2)
        four = lead()
        rows = four.get("agents", [])
        t.ok("lead", "four agents, all shut: four headings and no rows", len(rows) == 4 and all(row["headed"] and row["rows"] == 0 for row in rows), rows)
        t.ok("lead", "four shut agents fit: the card is its row and four headings tall",
             abs((four.get("card") or {}).get("room", 0) - (34 + 4 * 37 + 18)) < 0.01, (four.get("card") or {}).get("room"))
        looks_shots("pic-4-four-shut")
        for row in rows:
            lead_do("open", row["id"][:8])
        time.sleep(1.0)
        wide = lead()
        full = 34 + 37 * (4 + sum(row["fold"] for row in wide.get("agents", []))) + 18
        room = (wide.get("card") or {}).get("room", 0)
        t.ok("lead", "all four open: the card stops at its share of the column and the list scrolls", 200 < room < full - 1, (room, full))
        looks_shots("pic-4-four-open")
        lead_do("shut")
        time.sleep(1.0)

        rest_head = heads().get("Codex", {})
        box = rest_head.get("box") or [0, 0, 0, 0]
        agents("hover", at=[box[0] + box[2] / 2, box[1] + box[3] - 6])
        time.sleep(0.4)
        over = heads().get("Codex", {})
        t.ok("lead", "at rest a heading shows its count and no close button", rest_head.get("countShown") and not rest_head.get("close"), rest_head)
        t.ok("lead", "on hover the count gives way to the sidebar's close button", over.get("close") and not over.get("countShown") and over.get("hovering"), over)
        cbox = over.get("closeBox") or [0, 0, 0, 0]
        t.ok("lead", "the close button is the tab row's own square at the row's end", cbox[2] == 26 and cbox[3] == 26
             and abs((box[0] + box[2]) - (cbox[0] + cbox[2]) - 4) < 0.01, (box, cbox))
        looks_shots("pic-5-hover")
        agents("hover")
        time.sleep(0.3)

        plain = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_")}
        asking = subprocess.Popen([BROADWAY, "--world", WORLD, "ask", "Which account?", "--choice", "Work", "--choice", "Personal",
                                   "--tab", checks[0], "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                  stdin=subprocess.DEVNULL, env=dict(plain, **CODEX))
        asked = wait_for(lambda: (lambda head: head if head.get("attention") else None)(heads().get("Codex", {})), 15) or {}
        if not asked and asking.poll() is not None:
            print("  the ask ended:", asking.communicate()[0][:400], flush=True)
        row = agent("Codex")
        t.ok("lead", "needs you: the heading shows the question", "Which account?" in asked.get("line", "") and asked.get("line", "").startswith("Needs you"), asked)
        t.ok("lead", "needs you: the heading is the tab that asks", row.get("lead", "")[:8].lower() == checks[0][:8].lower(), row)
        t.ok("lead", "needs you opens nothing", not any(each["open"] for each in lead().get("agents", [])) and lead().get("folded") is False, lead().get("agents"))
        looks_shots("pic-6-needs-you")
        pressed = lead_do("lead", codex.get("id", "")[:8])
        t.ok("lead", "a press on the heading goes to the tab that asks", pressed.get("active", "")[:8].lower() == checks[0][:8].lower(), pressed.get("active"))
        time.sleep(0.6)
        chosen = heads().get("Codex", {})
        t.ok("lead", "there, the heading wears the selected row's look", chosen.get("selected") is True, chosen)
        agents("answer", **{"with": "1"})
        try:
            asking.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            asking.kill()
        mail = card("Mail sorter") or {}
        agents("closelink", link=mail.get("id", "")[:8])
        broadway("agents", "done", env=MAIL)
        for n in range(2, 6):
            broadway("open", base + f"check-{n}", env=CODEX)
        agents("row", link=claude["id"][:8], index=0)
        wait_for(lambda: len(lead().get("agents", [])) == 3, 6)
        if not agent("Codex").get("open"):
            lead_do("open", codex.get("id", "")[:8])
        time.sleep(1.0)
        looks_shots("pic-7-three-open")
        open_state = card_checks("three agents, open")
        open_box = (open_state.get("card") or {}).get("box")

        listed = (chrome().get("card") or {}).get("listed") or []
        gaps = [round(b[1] - (a[1] + a[3]), 2) for a, b in zip(listed, listed[1:])]
        t.ok("rows", "three agents: headings and rows sit the regular gap apart", len(listed) > 3 and all(abs(g - 3) < 0.01 for g in gaps), listed)
        agents("press")
        time.sleep(1.0)
        for dark in (False, True):
            stage(dark)
            for name in LOOKS:
                look(name)
                foot_shot(f"pic-8-three-folded-{name}-{'dark' if dark else 'light'}")
        stage(False)
        look("pale")
        closed_box = (card_checks("three agents, folded").get("card") or {}).get("box")

        if shutil.which("ffmpeg"):
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-af", "volume=0.0005", "-t", "90", "-pix_fmt", "yuv420p",
                            "-c:v", "libx264", "-preset", "veryfast", "-c:a", "aac", "-shortest", str(CLIP)], check=True)
            music = sp("open", url=base + "music", foreground=True).get("resultID")
            bench({"do": "wait", "id": music, "seconds": 20})
            bench({"do": "eval", "id": music, "js": "document.getElementById('t').play(), 1"})
            wait_for(lambda: bench({"do": "eval", "id": music, "js": "document.getElementById('t').paused"}).get("value") is False, 8)
            agents("row", link=claude["id"][:8], index=0)
            wait_for(lambda: chrome().get("mini"), 8)
        bench({"do": "updates", "stage": "0.2", "build": "900"})
        time.sleep(1.5)
        for dark in (False, True):
            stage(dark)
            for name in LOOKS:
                look(name)
                foot_shot(f"pic-9-player-update-{name}-{'dark' if dark else 'light'}")
        stage(False)
        look("pale")
        family = card_checks("with the player and the update card")
        t.ok("card", "the player and the update card are both showing", bool(family.get("mini")) and bool(family.get("update")),
             {k: family.get(k) for k in ("mini", "update")})
        if shutil.which("ffmpeg"):
            bench({"do": "eval", "id": music, "js": "document.getElementById('t').pause(), 1"})

        stage(True)
        look("noir")
        time.sleep(0.5)
        closed_room = (chrome().get("card") or {}).get("room", 0)

        trace, rest = moved("unfold")
        rooms = [r for _, r in trace]
        steps = [b - a for a, b in zip([closed_room] + rooms, rooms)]
        travel = rooms[-1] - closed_room if rooms else 0
        gaps = [round((b[0] - a[0]) * 1000, 1) for a, b in zip(trace, trace[1:])]
        t.ok("fold", "unfold: the card's height moves over many frames", len(rooms) >= 8, trace)
        t.ok("fold", "unfold: the card grows by the rows it shows", travel > 60 and abs(rest.get("room", 0) - rooms[-1]) < 0.01, (travel, rest.get("room")))
        t.ok("fold", "unfold: the height only grows", all(s >= -0.01 for s in steps), steps)
        if travel > 0:
            t.ok("fold", "unfold: the first frame moves less than a fifth of the way", steps[0] < travel / 5, (steps[0], travel))
            t.ok("fold", "unfold: the last frame moves less than two points", abs(steps[-1]) < 2, (steps[-1], rooms[-4:]))
            t.ok("fold", "unfold: no frame jumps more than a quarter of the way", max(steps) < travel / 4, (max(steps), travel))
        t.ok("fold", "unfold: the column laid out the card's height on each display frame", bool(gaps) and sorted(gaps)[len(gaps) // 2] < 20, gaps)
        t.ok("fold", "unfold: at rest the card is the height it was given", abs((rest.get("card") or [0, 0, 0, 0])[3] - (rest.get("room", 0) - 8)) < 0.6, rest)
        open_room = rest.get("room", 0)
        time.sleep(0.4)

        trace, rest = moved("fold")
        rooms = [r for _, r in trace]
        steps = [a - b for a, b in zip([open_room] + rooms, rooms)]
        travel = open_room - rooms[-1] if rooms else 0
        t.ok("fold", "fold: the card's height moves over many frames", len(rooms) >= 8, trace)
        t.ok("fold", "fold: it lands on the folded height", rooms and abs(rooms[-1] - closed_room) < 0.01, (rooms[-1:], closed_room))
        t.ok("fold", "fold: the height only shrinks", all(s >= -0.01 for s in steps), steps)
        if travel > 0:
            t.ok("fold", "fold: the first frame moves less than a fifth of the way", steps[0] < travel / 5, (steps[0], travel))
            t.ok("fold", "fold: the last frame moves less than two points", abs(steps[-1]) < 2, (steps[-1], rooms[-4:]))
            t.ok("fold", "fold: no frame jumps more than a quarter of the way", max(steps) < travel / 4, (max(steps), travel))
        own_steps = [abs(v) for v in steps]
        t.ok("fold", "fold: the rows are gone once it has folded", rest.get("rows", 99) == 0 and not rest.get("moving"), rest)
        time.sleep(0.4)

        def turn():
            agents("press")
            time.sleep(0.09)
            agents("press")

        trace, rest = moved("turn", turn, wait=1.2)
        rooms = [r for _, r in trace]
        peak = max(rooms) if rooms else 0
        top = rooms.index(peak) if rooms else 0
        steps = [b - a for a, b in zip([closed_room] + rooms, rooms)]
        after = [abs(v) for v in steps[top + 1:]]
        t.ok("fold", "reversed: the card turns back short of open", closed_room + 4 < peak < open_room - 4, (closed_room, peak, open_room))
        t.ok("fold", "reversed: it carries on upward a little before it turns, as a thing with speed does",
             0 < top < len(rooms) - 1 and rooms[top - 1] < peak, rooms)
        t.ok("fold", "reversed: no frame after the turn moves further than a plain fold's fastest frame",
             bool(after) and max(after) <= max(own_steps or [0]) + 0.5, (max(after) if after else None, max(own_steps or [0]), steps))
        t.ok("fold", "reversed: it settles folded again", bool(rooms) and abs(rooms[-1] - closed_room) < 0.01 and rest.get("rows") == 0, (rooms[-3:], rest))
        time.sleep(0.4)

        subprocess.run(["defaults", "write", SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(0.5)
        for name, goal in (("reduced-unfold", open_room), ("reduced-fold", closed_room)):
            agents("press")
            now = chrome().get("card") or {}
            (OUT / "films" / f"{name}.json").write_text(json.dumps(now, indent=1))
            t.ok("fold", f"Reduce Motion, {name[8:]}: the height changes at once",
                 not now.get("moving") and abs(now.get("room", 0) - goal) < 0.01, now)
            t.ok("fold", f"Reduce Motion, {name[8:]}: the card cross-fades instead", now.get("crossfading") is True, now)
            time.sleep(0.6)
        subprocess.run(["defaults", "write", SUITE, "motion.testReduced", "-bool", "false"], check=True)
        time.sleep(0.5)

        bench({"do": "updates", "stage": "", "build": ""})
        accent = accent_of("Claude Code")
        for dark in (False, True):
            mode = "dark" if dark else "light"
            stage(dark)
            for name in LOOKS:
                look(name)
                if not dark and name == "noir":
                    sp("select", id=loose[0])
                    time.sleep(0.8)
                agents("row", link=claude["id"][:8], index=0)
                if not dark and name == "noir":
                    arriving = chrome().get("rims") or []
                    t.ok("rim", "the colour fades in", any(r.get("on") and r.get("fading") for r in arriving), arriving)
                time.sleep(0.8)
                if not dark and name == "noir":
                    worn = chrome().get("rims") or []
                    t.ok("rim", "and is still once it is in", bool(worn) and not any(r.get("fading") for r in worn), worn)
                frame = pane(one[:8].lower())
                pic_path = shoot(f"rim-agent-tab-{name}-{mode}")
                colour = edge_colour(Picture(pic_path), frame) if frame and pic_path else None
                t.ok("rim", f"{name} {mode}: the agent's tab wears its colour at the page's edge",
                     colour is not None and far(colour, accent) < 40, (colour, accent, frame))
            sp("select", id=loose[0])
            if not dark:
                leaving = chrome().get("rims") or []
                t.ok("rim", "the colour fades out on another tab", any(not r.get("on") and r.get("fading") for r in leaving), leaving)
            time.sleep(0.8)
            frame = pane(loose[0][:8].lower())
            pic_path = shoot(f"rim-other-tab-{mode}")
            colour = edge_colour(Picture(pic_path), frame) if frame and pic_path else None
            t.ok("rim", f"{mode}: another tab wears no agent colour",
                 colour is not None and far(colour, accent) > 60 and not chrome().get("rims"), (colour, accent, frame))
        stage(False)
        look("pale")
        ids = {tab["id"][:8].lower(): tab["id"] for tab in agents("state").get("agentTabs", [])}
        mine, theirs = ids.get(one[:8].lower(), one), ids.get(codex_tab[:8].lower(), codex_tab)
        codex_accent = accent_of("Codex")
        for tab in (mine, theirs):
            bench({"do": "adopt", "id": tab})
        paired = sp("pair", id=theirs, **{"with": mine}, side="right")
        time.sleep(1.0)
        for dark in (False, True):
            mode = "dark" if dark else "light"
            stage(dark)
            for name in LOOKS:
                look(name)
                sp("focus", id=mine)
                time.sleep(0.8)
                left, right_pane = pane(one[:8].lower()), pane(codex_tab[:8].lower())
                pic_path = shoot(f"rim-split-two-agents-{name}-{mode}")
                pic = Picture(pic_path) if pic_path else None
                on = edge_colour(pic, left) if pic and left else None
                other = edge_colour(pic, right_pane) if pic and right_pane else None
                t.ok("rim", f"Split View {name} {mode}: Claude's pane wears Claude's colour",
                     on is not None and far(on, accent) < 40, (on, accent, left, paired.get("splits")))
                t.ok("rim", f"Split View {name} {mode}: Codex's pane wears Codex's colour, not Claude's",
                     other is not None and far(other, codex_accent) < 40 and far(other, accent) > 60, (other, codex_accent, right_pane))
        stage(False)
        look("pale")
        sp("focus", id=mine)
        time.sleep(0.6)
        broadway("scroll", "--tab", one, env=CLAUDE)
        broadway("scroll", "--tab", one, env=CLAUDE)
        pills = wait_for(lambda: [p for p in chrome().get("pills", []) if p["kind"] == "acting"], 2) or []
        left = pane(one[:8].lower())
        shoot("pill-acting-split")
        box = pills[0]["box"] if pills else None
        t.ok("pills", "Split View: the acting pill sits at the bottom of the agent's pane, in its middle",
             bool(box) and bool(left) and abs(box[0] + box[2] / 2 - (left["x"] + left["width"] / 2)) < 2
             and 0 < left["y"] + left["height"] - (box[1] + box[3]) < 40, (box, left))
        broadway("agents", "done", env=CODEX)
        time.sleep(1.0)
        for dark in (False, True):
            stage(dark)
            look("noir" if dark else "pale")
            time.sleep(0.6)
            left, right_pane = pane(one[:8].lower()), pane(codex_tab[:8].lower())
            pic_path = shoot(f"rim-split-{'dark' if dark else 'light'}")
            pic = Picture(pic_path) if pic_path else None
            on = edge_colour(pic, left) if pic and left else None
            off = edge_colour(pic, right_pane) if pic and right_pane else None
            t.ok("rim", f"Split View {'dark' if dark else 'light'}: only the pane an agent works in wears a colour",
                 on is not None and far(on, accent) < 40 and off is not None and far(off, accent) > 60 and far(off, codex_accent) > 60,
                 (on, off, left, right_pane))
        sp("select", id=loose[2])
        time.sleep(0.6)
        stage(False)
        look("pale")

        agents("row", link=claude["id"][:8], index=1)
        time.sleep(0.8)
        two = agents("state")
        second = next((tab for tab in two.get("agentTabs", []) if tab["active"]), {}).get("id", "")[:8].lower()

        def acting_pill():
            broadway("scroll", "--tab", second, env=CLAUDE)
            broadway("scroll", "--tab", second, env=CLAUDE)
            return wait_for(lambda: [p for p in chrome().get("pills", []) if p["kind"] == "acting"], 2)

        for dark in (False, True):
            stage(dark)
            look("noir" if dark else "pale")
            pills = acting_pill() or []
            said = chrome()
            shoot(f"pill-acting-{'dark' if dark else 'light'}")
            height = said.get("height", SIZE[1])
            box = pills[0]["box"] if pills else None
            t.ok("pills", f"{'dark' if dark else 'light'}: the acting pill sits at the bottom of the page",
                 box is not None and box[1] + box[3] > height - 60, (box, height))
        stage(False)
        look("pale")
        bench({"do": "ui", "linkNotice": True})
        pills = acting_pill() or []
        said = chrome()
        shoot("pill-acting-with-bar")
        bars = said.get("bars", [])
        box = pills[0]["box"] if pills else None
        t.ok("pills", "with another bar: the acting pill is nearest the bottom, the bar above it",
             box is not None and bars and all(bar[1] + bar[3] <= box[1] + 0.5 for bar in bars), (box, bars))
        agents("takeover")
        time.sleep(0.8)
        said = chrome()
        shoot("pill-driving-with-bar")
        drive = [p["box"] for p in said.get("pills", []) if p["kind"] == "driving"]
        t.ok("pills", "driving: \"You're driving\" sits at the bottom, under the bar",
             bool(drive) and drive[0][1] + drive[0][3] > said.get("height", SIZE[1]) - 60 and
             all(bar[1] + bar[3] <= drive[0][1] + 0.5 for bar in said.get("bars", [])), (drive, said.get("bars")))
        rims = said.get("rims", [])
        t.ok("rim", "the agent's tab keeps its colour while the person drives", any(r.get("on") for r in rims), rims)
        bench({"do": "ui", "linkNotice": False})
        time.sleep(0.6)
        for dark in (False, True):
            stage(dark)
            look("noir" if dark else "pale")
            shoot(f"pill-driving-{'dark' if dark else 'light'}")
        stage(False)
        look("pale")
        bench({"do": "ui", "toggleFold": True})
        time.sleep(1.0)
        said = chrome()
        shoot("pill-driving-sidebar-hidden")
        drive = [p["box"] for p in said.get("pills", []) if p["kind"] == "driving"]
        width = said.get("width", SIZE[0])
        t.ok("pills", "sidebar hidden: \"You're driving\" sits at the bottom, in the middle of the page",
             bool(drive) and drive[0][1] + drive[0][3] > said.get("height", SIZE[1]) - 60 and abs(drive[0][0] + drive[0][2] / 2 - width / 2) < 30,
             (drive, width))
        agents("handback")
        time.sleep(0.4)
        pills = acting_pill() or []
        shoot("pill-acting-sidebar-hidden")
        box = pills[0]["box"] if pills else None
        t.ok("pills", "sidebar hidden: the acting pill sits at the bottom", box is not None and box[1] + box[3] > said.get("height", SIZE[1]) - 60, box)
        bench({"do": "ui", "toggleFold": True})
        time.sleep(0.6)
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

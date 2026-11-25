#!/usr/bin/env python3
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
LABEL = next((word for word in sys.argv[1:] if not word.startswith("--")), "now")
WORLD = f"cardscroll-{os.getpid()}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = ROOT / ".context/agent-card-scroll" / LABEL
SIZE = (1180, 760)
SIDE = 260
SHOT = ROOT / ".build/agent-card-scroll-shot"
WINDOW = [0]
PID = [0]
DARK = [False]
CLAUDE = {"BROADWAY_AGENT": "claude-scroll", "BROADWAY_AGENT_NAME": "Claude Code"}
LOOKS = {
    "pale": {"custom": "FFF1C9", "intensity": 0.8, "transparency": 0.0, "grain": 0.0, "glass": False},
    "noir": {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45, "glass": False},
    "blue": {"custom": "3139FB", "intensity": 0.8, "transparency": 0.0, "grain": 0.0, "glass": False},
}


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = (f"<!doctype html><title>{name}</title><body style='margin:0;font:16px system-ui'><h1>{name}</h1>").encode()
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
        line = f"{'ok  ' if cond else 'FAIL'} [{point}] {name}" + ("" if cond else f"  {str(extra)[:600]}")
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


def card_do(action="", **more):
    return bench(dict({"do": "agentcard", "action": action}, **more))


def state():
    return card_do()


def scroll(said=None):
    return ((said or state()).get("card") or {}).get("scroll") or {}


def wheel(**more):
    return card_do("wheel", **more)


def pointer(at=None):
    return card_do("pointer", at=at) if at else card_do("pointer")


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.05)
    return None


def still(seconds=4):
    last = [None]

    def settled():
        s = scroll()
        offset = s.get("offset")
        steady = last[0] is not None and abs(offset - last[0]) < 0.01
        last[0] = offset
        return s if steady and not s.get("live") and not s.get("steering") else None

    def calm():
        time.sleep(0.1)
        return settled()

    return wait_for(calm, seconds) or scroll()


def stage(dark):
    DARK[0] = dark
    said = agents("stage", dark=dark, size=list(SIZE), shown=False)
    WINDOW[0] = said["window"]
    PID[0] = said["pid"]
    time.sleep(0.8)


def look(name):
    bench({"do": "space", "action": "look", **LOOKS[name]})
    time.sleep(0.6)


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    said = ""
    for attempt in range(6):
        said = subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True, text=True).stderr
        if path.exists():
            break
        restaged = agents("stage", dark=DARK[0], size=list(SIZE), shown=False)
        WINDOW[0] = restaged.get("window", WINDOW[0])
        time.sleep(0.6)
        said += f" | restaged as {WINDOW[0]}"
        if SHOT.exists():
            helped = subprocess.run([str(SHOT), str(PID[0]), str(WINDOW[0]), str(path)], capture_output=True, text=True, timeout=60)
            said += " | " + helped.stdout[-200:] + helped.stderr[-200:]
            if path.exists():
                break
        else:
            said += " | no helper"
    if not path.exists():
        print(f"  no picture of window {WINDOW[0]} for {name}: {said.strip()}", flush=True)
        return None
    s = scroll()
    box = s.get("card")
    if box:
        with open(path, "rb") as file:
            head = file.read(24)
        k = int.from_bytes(head[16:20], "big") / SIZE[0]
        x, y, w, h = [int(v * k) for v in (box[0] - 6, box[1] - 30, box[2] + 12, box[3] + 36)]
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(path), "-vf", f"crop={w}:{h}:{max(0, x)}:{max(0, y)},scale=iw*2:ih*2:flags=neighbor",
                        str(OUT / f"{name}-card.png")], capture_output=True, stdin=subprocess.DEVNULL)
    return path


def centre(box):
    return [box[0] + box[2] / 2, box[1] + box[3] / 2]


def inside(box, at):
    return box[0] <= at[0] < box[0] + box[2] and box[1] <= at[1] < box[1] + box[3]


def rows(s):
    return [r for r in s.get("rows", []) if r.get("kind") == "row" and not r.get("leaving") and r["box"][3] > 0]


def under(s, at):
    view = s.get("view") or [0, 0, 0, 0]
    if not inside(view, at):
        return None
    found = [r for r in rows(s) if inside(r["box"], at)]
    return found[0]["id"] if found else None


def bottom_of(s):
    box = s["card"]
    return box[1] + box[3]


def took(said, dy):
    return (said.get("sideAfter", -1) - said.get("sideBefore", -1)) * (1 if dy > 0 else -1) > 5


def side_dy():
    said = card_do("wheel", dy=0, steps=0, mode="legacy")
    return -10 if said.get("sideBefore", 0) > 300 else 10


def move_to(target, at=None):
    s = still()
    if target == "end":
        target = s.get("limit", 0)
    card_do("offset", y=target)
    return still()


def to_top(at):
    return move_to(0, at)


def to_end(at):
    return move_to("end", at)


def fits_checks(where):
    s = still()
    t.ok("fits", f"{where}: every row in view, the list does not scroll", s.get("fits") is True and not s.get("elastic") and s.get("limit") == 0
         and abs(s.get("offset", 1)) < 0.01, s)
    at = centre(rows(s)[-1]["box"])
    dy = side_dy()
    said = wheel(dy=dy, steps=6, momentum=10, at=at)
    offsets = [p[1] for p in said.get("trace", [])]
    t.ok("fits", f"{where}: a trackpad swipe and its momentum leave the offset at 0", bool(offsets) and all(abs(o) < 0.01 for o in offsets)
         and abs(scroll().get("offset", 1)) < 0.01, said.get("trace"))
    t.ok("fits", f"{where}: the sidebar's list takes the swipe", took(said, dy), (said.get("sideBefore"), said.get("sideAfter"), said.get("hit")))
    passed = scroll().get("passed", 0)
    said = wheel(dy=side_dy(), steps=4, mode="legacy", at=at)
    offsets = [p[1] for p in said.get("trace", [])]
    handed = scroll().get("passed", 0) - passed
    t.ok("fits", f"{where}: a mouse wheel leaves the offset at 0 and every notch is handed to the sidebar's list",
         bool(offsets) and all(abs(o) < 0.01 for o in offsets) and handed == 4, (said.get("trace"), handed, said.get("hit")))
    pointer()


def overflow_checks(where, name):
    s = still()
    t.ok("scroll", f"{where}: more rows than fit, the list scrolls with the system's elasticity", s.get("fits") is False and s.get("elastic") is True
         and s.get("limit", 0) > 30, s)
    at = centre(s["view"])
    s = to_top(at)
    t.ok("band", f"{where}: at the top the band is off and no row is blurred", abs(s.get("offset", 1)) < 0.01 and s.get("band") == 0
         and all(r.get("blur", 1) == 0 for r in s.get("rows", [])), s)
    bottom = bottom_of(s)
    line = bottom - s["inset"]
    crossing = []
    for _ in range(14):
        s = scroll()
        crossing = [r for r in rows(s) if r["box"][1] < line - 0.5 and r["box"][1] + r["box"][3] > line + 0.5 and r["box"][1] < bottom - 1]
        if crossing:
            break
        wheel(dy=3, steps=1, at=at)
        time.sleep(0.05)
    t.ok("bottom", f"{where}: partway, a row's plate runs past the old inner line to the card's bottom edge", bool(crossing),
         (line, bottom, [r["box"] for r in rows(s)]))
    if crossing:
        crossing_at = [centre(crossing[0]["box"])[0], line + 1]
        pointer(crossing_at)
        time.sleep(0.2)
        shoot(f"{name}-bottom-crossing")
        pointer()
    s = to_top(at)
    said = wheel(dy=2, steps=3, at=at, mode="begin")
    s = scroll()
    t.ok("band", f"{where}: a few points down the band is partly on", 0 < s.get("band", 0) < 1, (s.get("offset"), s.get("band"), said.get("phases")))
    wheel(mode="end", at=at)
    said = wheel(dy=6, steps=4, at=at)
    s = still()
    under_band = [r for r in s.get("rows", []) if r.get("blur", 0) > 0]
    t.ok("band", f"{where}: past the band's height it is fully on and the row passing under it blurs", s.get("band") == 1 and bool(under_band),
         (s.get("offset"), s.get("band"), [(r["box"], r.get("blur")) for r in s.get("rows", [])]))
    shoot(f"{name}-partway")
    s = to_end(at)
    last = rows(s)[-1]["box"] if rows(s) else [0, 0, 0, 0]
    gap = bottom_of(s) - (last[1] + last[3])
    t.ok("bottom", f"{where}: at the end the last row rests the old 5 pt above the card's bottom", abs(s.get("offset", 0) - s.get("limit", -1)) < 0.01
         and abs(gap - 5) < 0.51, (s.get("offset"), s.get("limit"), gap, last))
    t.ok("rest", f"{where}: at rest the offset and every row sit on whole points", abs(s.get("offset", 0.5) - round(s.get("offset", 0.5))) < 0.01
         and all(abs(r["box"][1] - round(r["box"][1])) < 0.01 for r in s.get("rows", [])), (s.get("offset"), [r["box"][1] for r in s.get("rows", [])]))
    shoot(f"{name}-end")
    s = to_top(at)
    shoot(f"{name}-top")


def hover_checks():
    s = to_top(centre(scroll()["view"]))
    view = s["view"]
    at = [centre(view)[0], view[1] + view[3] - 20]
    said = wheel(dy=5, steps=10, momentum=6, at=at)
    follows = [p[3] for p in said.get("trace", [])]
    t.ok("hover", "while rows move under a still pointer, the plate is on the row under it after every step and on no other",
         bool(follows) and all(f == 1 for f in follows), said.get("trace"))
    s = still()
    shown = [r for r in rows(s) if r.get("hover")]
    t.ok("hover", "the row under the pointer wears the plate and the close key",
         len(shown) == 1 and shown[0]["id"] == under(s, at) and shown[0].get("close") is True, [(r["box"], r.get("hover"), r.get("close")) for r in rows(s)])
    pairs = list(zip(rows(s), rows(s)[1:]))
    gap_at = None
    for a, b in pairs:
        y = (a["box"][1] + a["box"][3] + b["box"][1]) / 2
        if inside(view, [at[0], y]):
            gap_at = [at[0], y]
            break
    if gap_at:
        pointer(gap_at)
        time.sleep(0.15)
        s = scroll()
        t.ok("hover", "over the gap between two rows no row is lit", not any(r.get("hover") for r in s.get("rows", [])), gap_at)
    head = s.get("head") or [0, 0, 0, 0]
    pointer([centre(view)[0], head[1] + head[3] - 3])
    time.sleep(0.15)
    s = scroll()
    t.ok("hover", "over the head, a row scrolled under it is not lit", not any(r.get("hover") for r in s.get("rows", [])),
         [(r["box"], r.get("hover")) for r in s.get("rows", [])])
    pointer()


def quiet_checks(base, first):
    s = still()
    view = s["view"]
    at = centre(view)
    to_top(at)
    began = wheel(dy=6, steps=4, at=at, mode="begin")
    s = scroll()
    o1 = s.get("offset")
    r1 = under(s, at)
    t.ok("quiet", "a gesture is under way", s.get("live") is True and o1 > 0 and r1 is not None, (s.get("live"), o1, r1, began.get("phases"), began.get("trace")))
    broadway("open", base + "arrives-mid-scroll", env=CLAUDE)
    time.sleep(0.6)
    s = scroll()
    t.ok("quiet", "during a scroll a tab arriving leaves the offset and the row under the pointer", abs(s.get("offset", -1) - o1) < 0.01
         and under(s, at) == r1, (o1, s.get("offset"), r1, under(s, at)))
    card_do("retitle", tab=r1, title="Renamed while scrolling")
    time.sleep(0.6)
    s = scroll()
    retitled = next((r for r in rows(s) if r["id"] == r1), {})
    t.ok("quiet", "during a scroll a retitle leaves the offset and the row under the pointer", abs(s.get("offset", -1) - o1) < 0.01
         and under(s, at) == r1 and retitled.get("title") == "Renamed while scrolling", (o1, s.get("offset"), retitled))
    line = ((state().get("card") or {}).get("top") or {}).get("line")
    broadway("scroll", "--tab", first, env=CLAUDE)
    broadway("scroll", "--tab", first, env=CLAUDE)
    time.sleep(0.6)
    said = state()
    s = scroll(said)
    after = ((said.get("card") or {}).get("top") or {}).get("line")
    t.ok("quiet", "during a scroll the head's line rolling leaves the offset and the row under the pointer",
         abs(s.get("offset", -1) - o1) < 0.01 and under(s, at) == r1, (line, after, o1, s.get("offset")))
    said = wheel(dy=4, mode="end", momentum=6, at=at)
    s = scroll()
    o2 = s.get("offset")
    r2 = under(s, at)
    t.ok("quiet", "the gesture over, the quiet time runs", s.get("live") is False and s.get("quiet") is True, s)
    tabs = rows(s)
    below = [r for r in tabs if r["box"][1] > (next((x["box"][1] for x in tabs if x["id"] == r2), 1e9))]
    if below:
        card_do("closetab", tab=below[-1]["id"])
        time.sleep(0.5)
        s = scroll()
        t.ok("quiet", "right after a scroll a tab closing leaves the offset and the row under the pointer",
             abs(s.get("offset", -1) - o2) < 0.01 and under(s, at) == r2, (o2, s.get("offset"), r2, under(s, at)))
    broadway("open", base + "arrives-after-scroll", env=CLAUDE)
    time.sleep(0.4)
    s = scroll()
    t.ok("quiet", "right after a scroll a tab arriving leaves the offset and the row under the pointer",
         abs(s.get("offset", -1) - o2) < 0.01 and under(s, at) == r2 and s.get("quiet") is True, (o2, s.get("offset"), s.get("quiet")))
    pointer()


def redraw_checks():
    s = still()
    time.sleep(1.8)
    s = scroll()
    laid = s.get("laidOut")
    target = rows(s)[1]["id"]
    card_do("retitle", tab=target, title="Renamed at rest")
    time.sleep(0.8)
    s = scroll()
    retitled = next((r for r in rows(s) if r["id"] == target), {})
    t.ok("redraw", "a retitle redraws its own row and lays out no other", retitled.get("title") == "Renamed at rest" and s.get("laidOut") == laid,
         (laid, s.get("laidOut"), retitled.get("title")))


def bounce_checks():
    s = still()
    at = centre(s["view"])
    to_top(at)
    said = wheel(dy=-30, steps=4, at=at)
    pulled = min(p[1] for p in said.get("trace", [[0, 0]]))
    back = wait_for(lambda: (lambda s: s if abs(s.get("offset", -1)) < 0.01 else None)(scroll()), 3)
    t.ok("bounce", "pulled past the top, the list gives with the system's elasticity and springs back by itself",
         pulled < -1 and back is not None, (pulled, scroll().get("offset"), said.get("phases")))
    s = to_top(at)


def clamp_checks():
    s = still()
    at = centre(s["view"])
    s = to_end(at)
    end = s.get("offset")
    gone = [r["id"] for r in rows(s)][-2:]
    for tab in gone:
        card_do("closetab", tab=tab)
    seen = []
    until = time.time() + 1.2
    while time.time() < until:
        seen.append(scroll().get("offset"))
        time.sleep(0.02)
    s = still()
    middle = [o for o in seen if o is not None and s.get("limit", 0) + 0.5 < o < end - 0.5]
    t.ok("clamp", "a list that got shorter under the offset eases back to its new end, not in one jump",
         abs(s.get("offset", -1) - s.get("limit", -2)) < 0.01 and end > s.get("limit", 0) + 1 and len(middle) >= 2, (end, s.get("limit"), seen))


def follow_checks(first):
    s = still()
    at = centre(s["view"])
    plain = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_")}

    def ask():
        return subprocess.Popen([BROADWAY, "--world", WORLD, "ask", "Which account?", "--choice", "Work", "--choice", "Personal",
                                 "--tab", first, "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                stdin=subprocess.DEVNULL, env=dict(plain, **CLAUDE))

    def answered(asking):
        agents("answer", **{"with": "1"})
        try:
            asking.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            asking.kill()

    def attention():
        return wait_for(lambda: ((state().get("card") or {}).get("top") or {}).get("attention"), 10)

    s = to_end(at)
    wheel(dy=-6, steps=2, at=at, mode="begin")
    s = scroll()
    end = s.get("offset")
    asking = ask()
    attention()
    s = scroll()
    t.ok("follow", "an agent asking during a scroll does not move the list", abs(s.get("offset", -1) - end) < 0.01 and s.get("live") is True,
         (end, s.get("offset"), s.get("live")))
    wheel(mode="end", at=at)
    answered(asking)
    time.sleep(1.8)
    s = to_end(at)
    end = s.get("offset")
    time.sleep(1.7)
    asking = ask()
    attention()
    s = still()
    t.ok("follow", "once the quiet time is over, an agent asking brings its rows into view as before", end > 1 and abs(s.get("offset", end)) < 0.01,
         (end, s.get("offset")))
    answered(asking)


def stills():
    for dark, name in ((False, "pale"), (True, "noir"), (False, "blue")):
        mode = f"{'dark' if dark else 'light'}-{name}"
        stage(dark)
        look(name)
        pointer()
        s = move_to(0)
        shoot(f"{mode}-top")
        s = move_to(20)
        bottom = bottom_of(s)
        line = bottom - s["inset"]
        crossing = [r for r in rows(s) if r["box"][1] < line - 0.5 and r["box"][1] + r["box"][3] > line + 0.5]
        if crossing:
            pointer([centre(crossing[0]["box"])[0], line + 1])
            time.sleep(0.3)
        shoot(f"{mode}-partway")
        pointer()
        s = move_to("end")
        shoot(f"{mode}-end")
        print(f"  {mode}: band at 20 pt, top row blur", [r.get("blur") for r in move_to(20).get("rows", [])][:3], flush=True)


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "Tests/WindowShot.swift").read_text().replace("        let args = CommandLine.arguments\n",
                                                                   "        _ = NSApplication.shared\n        let args = CommandLine.arguments\n", 1)
    (SHOT.parent / "agent-card-scroll-shot.swift").write_text(source)
    subprocess.run(["swiftc", "-O", "-parse-as-library", str(SHOT.parent / "agent-card-scroll-shot.swift"), "-o", str(SHOT)], capture_output=True)
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
        pid = PID[0]
        for n in range(30):
            sp("open", url=base + f"loose-{n}", foreground=n == 0)
        time.sleep(1)
        first = broadway("open", base + "first", env=CLAUDE)["data"]["id"]
        broadway("wait", "--tab", first, env=CLAUDE)
        time.sleep(1)
        if state().get("folded"):
            agents("press")
        time.sleep(1.2)
        link = (state().get("agents") or [{}])[0].get("id", "")[:8]
        if "--stills" in sys.argv:
            for n in range(9):
                broadway("open", base + f"more-{n}", env=CLAUDE)
            card_do("whole", link=link)
            time.sleep(1.5)
            stills()
            return 0
        for dark in (False, True):
            stage(dark)
            look("noir" if dark else "pale")
            fits_checks(f"one row {'dark' if dark else 'light'}")
        before = scroll()
        head_at = (before.get("head") or [0, 0])[1]
        first_at = rows(before)[0]["box"][1] - head_at if rows(before) else None
        opener = threading.Thread(target=lambda: broadway("open", base + "second", env=CLAUDE))
        opener.start()
        seen = []
        quiets = []
        until = time.time() + 2.0
        while time.time() < until:
            s = scroll()
            if rows(s):
                seen.append((round(s.get("offset", 0), 2), round(rows(s)[0]["box"][1] - (s.get("head") or [0, 0])[1], 2), round(s["card"][3], 1)))
                quiets.append(bool(s.get("quiet")))
            time.sleep(0.02)
        opener.join()
        heights = {h for _, _, h in seen}
        t.ok("grow", "while the card grows by a row, the first row keeps its place under the head and the list stays at its top",
             len(heights) > 2 and all(abs(o) < 0.5 and y == round(first_at, 2) for o, y, _ in seen) and seen[-1][0] == 0, (first_at, seen))
        t.ok("grow", "a card that grows with no scroll from the person does not start the quiet time",
             quiets and not any(quiets) and not scroll().get("quiet"), quiets)
        time.sleep(0.6)
        for dark in (False, True):
            stage(dark)
            look("noir" if dark else "pale")
            fits_checks(f"two rows {'dark' if dark else 'light'}")
        for n in range(8):
            broadway("open", base + f"more-{n}", env=CLAUDE)
        card_do("whole", link=link)
        time.sleep(1.5)
        for dark, name in ((False, "pale"), (True, "noir"), (False, "blue")):
            stage(dark)
            look(name)
            overflow_checks(f"{name} {'dark' if dark else 'light'}", f"{'dark' if dark else 'light'}-{name}")
        stage(False)
        look("pale")
        hover_checks()
        redraw_checks()
        bounce_checks()
        quiet_checks(base, first)
        clamp_checks()
        follow_checks(first)
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

#!/usr/bin/env python3
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")
LISTER = ROOT / ".build/agent-unseen-windows"
sv.use(f"unseen-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE
SCRATCH = Path(tempfile.mkdtemp(prefix="broadway-unseen-"))

PAGE = """<!doctype html><title>Garden Planner</title>
<style>
body{margin:0;font:16px -apple-system,sans-serif;background:rgb(40,160,110);color:#fff}
#card{width:240px;height:80px;background:rgb(0,90,200)}
#card:hover{background:rgb(220,40,40)}
#tall{height:4000px}
</style>
<h1>Garden Planner</h1>
<button id="add" onclick="clicks++">Add a row</button>
<div id="card" role="button" tabindex="0" aria-label="Hover card">Hover card</div>
<label>Season <select id="season"><option>Spring</option><option>Autumn</option></select></label>
<button id="fill" onclick="document.documentElement.requestFullscreen().then(() => full = 'yes', e => full = 'no ' + e.name)">Fill the screen</button>
<canvas id="paint" width="40" height="40"></canvas>
<video id="film" muted playsinline width="40" height="40"></video>
<div id="tall"></div>
<img id="lazy" loading="lazy" src="/lazy.gif" width="40" height="40" alt="Lazy picture">
<p id="state"></p>
<script>
var ticks = 0, frames = 0, clicks = 0, full = '', entered = false;
setInterval(() => ticks++, 100);
(function frame() { frames++; requestAnimationFrame(frame); })();
document.getElementById('card').addEventListener('mouseenter', () => entered = true);
var paint = document.getElementById('paint'), pen = paint.getContext('2d'), hue = 0;
setInterval(() => { hue = (hue + 37) % 360; pen.fillStyle = 'hsl(' + hue + ',80%,50%)'; pen.fillRect(0, 0, 40, 40); }, 50);
var film = document.getElementById('film');
film.srcObject = paint.captureStream(20);
film.play().catch(e => full = 'play ' + e.name);
setInterval(() => {
  var lazy = document.getElementById('lazy');
  document.getElementById('state').textContent = 'STATE ' + JSON.stringify({
    ticks: ticks, frames: frames, clicks: clicks, full: full, entered: entered,
    fullscreen: !!document.fullscreenElement, seen: document.visibilityState,
    hover: getComputedStyle(document.getElementById('card')).backgroundColor,
    film: film.currentTime, playing: !film.paused,
    lazy: lazy.complete && lazy.naturalWidth > 0, season: document.getElementById('season').value });
}, 200);
</script>"""

GIF = bytes.fromhex("47494638396101000100800000000000ffffff21f90401000000002c00000000010001000002024401003b")

failures = []
asked = []
samples = []
stray = []
marks = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail, flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        asked.append(self.path)
        if self.path.startswith("/lazy"):
            data, kind = GIF, "image/gif"
        else:
            data, kind = PAGE.encode(), "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def broadway(*words, timeout=60):
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)


def envelope(*words, timeout=60):
    try:
        result = broadway(*words, "--json", timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, {"ok": False, "error": {"code": "probe_timeout", "message": " ".join(words)}}
    try:
        return result, json.loads(result.stdout)
    except ValueError:
        return result, {"ok": False, "error": {"code": "unparsed", "message": result.stdout + result.stderr}}


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def state(tab):
    text = broadway("read", "--tab", tab).stdout
    found = re.search(r"STATE (\{.*\})", text)
    return json.loads(found.group(1)) if found else {}


def ref(tab, name):
    elements = envelope("snapshot", "--tab", tab)[1].get("data", {}).get("elements", [])
    found = next((e for e in elements if name in e.get("name", "")), None)
    return "@" + found["ref"] if found else None


def meets(bounds, screens):
    x, y, w, h = bounds
    return any(x < sx + sw and sx < x + w and y < sy + sh and sy < y + h for sx, sy, sw, sh in screens)


def watch(pid, browser_window, stop):
    lister = subprocess.Popen([str(LISTER), str(pid), "0.1"], stdout=subprocess.PIPE, text=True)
    try:
        for line in lister.stdout:
            if stop.is_set():
                break
            try:
                sample = json.loads(line)
            except ValueError:
                continue
            sample["mark"] = marks[-1] if marks else "start"
            samples.append(sample)
            for window in sample["windows"]:
                if window["number"] == browser_window or not window["onscreen"]:
                    continue
                stray.append({"mark": sample["mark"], "meets": meets(window["bounds"], sample["screens"]), **window})
    finally:
        lister.terminate()


KNOWN = []


def mark(name):
    marks.append(name)
    try:
        KNOWN.extend(sv.cmd({"do": "agents", "action": "windows"}).get("windows", []))
    except RuntimeError:
        pass
    time.sleep(0.25)


def blank(path):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    if not raw:
        return True
    green = sum(1 for i in range(0, len(raw) - 2, 3 * 97) if raw[i + 1] > 120 and raw[i] < 90 and raw[i + 2] < 150)
    return green < (len(raw) // (3 * 97)) // 4


def drive(tab, base):
    mark("open")
    check("the page opened", wait_for(lambda: state(tab).get("ticks", 0) > 0, 15), state(tab))

    mark("click")
    add = ref(tab, "Add a row")
    clicked = broadway("click", add, "--tab", tab) if add else None
    check("click lands in the unseen page", clicked is not None and clicked.returncode == 0 and wait_for(lambda: state(tab).get("clicks") == 1, 5), clicked and clicked.stderr)

    mark("scroll")
    before = [path for path in asked if path.startswith("/lazy")]
    check("the lazy image waits for a scroll", not before, asked)
    scrolled = broadway("scroll", "5000", "--tab", tab)
    check("scroll answers", scrolled.returncode == 0, scrolled.stderr)
    check("a lazy image loads after a scroll", wait_for(lambda: state(tab).get("lazy") is True, 10), state(tab))

    mark("wait")
    waited = broadway("wait", "--idle", "--seconds", "10", "--tab", tab)
    check("wait --idle answers", waited.returncode == 0, waited.stderr)

    first = state(tab)
    time.sleep(3)
    second = state(tab)
    check("the unseen page counts as seen by the page", second.get("seen") == "visible", second)
    check("a timer kept counting at its pace", second.get("ticks", 0) - first.get("ticks", 0) >= 20, (first, second))
    check("animation frames kept coming", second.get("frames", 0) - first.get("frames", 0) >= 60, (first, second))
    check("a video kept playing", second.get("playing") is True and second.get("film", 0) - first.get("film", 0) >= 2, (first, second))

    mark("hover")
    broadway("scroll", "-6000", "--tab", tab)
    card = ref(tab, "Hover card")
    hovered = envelope("hover", card or "@e0", "--tab", tab)[1]
    check("hover answers", hovered.get("ok") is True, hovered)
    after = state(tab)
    check("a hover style applied", after.get("hover") == "rgb(220, 40, 40)" and after.get("entered") is True, after)

    mark("shot")
    picture = SCRATCH / "unseen.png"
    shot = broadway("shot", "-o", str(picture), "--tab", tab)
    check("shot answers", shot.returncode == 0 and picture.exists(), shot.stderr)
    check("the picture is the page, not a blank", picture.exists() and not blank(picture), picture)

    mark("select")
    season = ref(tab, "Season")
    result, said = envelope("click", season or "@e0", "--tab", tab, timeout=20)
    check("clicking a list box neither hangs nor opens a menu window", result is not None, said)
    print("     click on a list box said:", json.dumps(said)[:300], flush=True)
    chosen = envelope("choose", season or "@e0", "Autumn", "--tab", tab, timeout=20)[1]
    check("choose picks from the list box", chosen.get("ok") is True and wait_for(lambda: state(tab).get("season") == "Autumn", 5), chosen)

    mark("fullscreen")
    fill = ref(tab, "Fill the screen")
    envelope("click", fill or "@e0", "--tab", tab, timeout=20)
    time.sleep(1.5)
    check("a page asking for the whole screen does not get it", state(tab).get("fullscreen") is False, state(tab))

    mark("layout")
    shifted = subprocess.run([str(LISTER), "shift", "4"], capture_output=True, text=True, timeout=30).stdout.strip()
    print("     display change:", shifted or "none", flush=True)
    moved = sv.cmd({"do": "agents", "action": "screens"})
    print("     windows AppKit moved for a screen change:", moved.get("moved"), flush=True)
    time.sleep(1)
    after = envelope("shot", "-o", str(SCRATCH / "after.png"), "--tab", tab)[1]
    check("shot still works after a screen change", after.get("ok") is True, after)
    rooms = [w for w in sv.cmd({"do": "agents", "action": "windows"}).get("windows", []) if w.get("room")]
    check("the agent page room is never ordered in", rooms and not any(w["visible"] for w in rooms), rooms)

    mark("person looks")
    sv.cmd({"do": "agents", "action": "look", "tab": tab})
    time.sleep(1)
    looked = state(tab)
    mark("person leaves")
    sv.cmd({"do": "agents", "action": "look"})
    time.sleep(1)
    first = state(tab)
    time.sleep(3)
    second = state(tab)
    check("the person sees the page in the browser window", looked.get("seen") == "visible", looked)
    check("after the person looks and leaves, the page stays awake", second.get("seen") == "visible"
          and second.get("frames", 0) - first.get("frames", 0) >= 60, (first, second))
    rooms = [w for w in sv.cmd({"do": "agents", "action": "windows"}).get("windows", []) if w.get("room")]
    check("and the room is still never ordered in", rooms and not any(w["visible"] for w in rooms), rooms)


def start():
    subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
    env = ["--env", f"SEARCH_PROBE={WORLD}", "--env", "SEARCH_MEASURE=1"]
    subprocess.run(["open", "-n", "-g", "-j", *env, str(APP)], check=True)
    check("the app is up", wait_for(lambda: broadway("status").returncode == 0, 40))
    broadway("agents", "connect")


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    LISTER.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-O", "-parse-as-library", str(ROOT / "Tests/WindowList.swift"), "-o", str(LISTER)], check=True)
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = "Unseen Probe"
    os.environ.pop("BROADWAY_TAB", None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    stop = threading.Event()
    sv.wipe()
    try:
        start()
        sv.cmd({"do": "pages", "on": True})
        staged = sv.cmd({"do": "agents", "action": "stage", "shown": False, "size": [1100, 720]})
        window, pid = staged.get("window"), staged.get("pid")
        threading.Thread(target=watch, args=(pid, window, stop), daemon=True).start()
        wait_for(lambda: samples, 10)
        tab = broadway("open", base).stdout.strip().splitlines()[-1]
        drive(tab, base)
        mark("end")
        time.sleep(0.5)
        stop.set()
        shown = [s for s in samples if any(w["number"] == window and w["onscreen"] for w in s["windows"])]
        check("the browser window was on screen at every sample", samples and len(shown) == len(samples), (len(shown), len(samples)))
        named = {}
        for row in stray:
            named.setdefault(row["number"], row)
        kinds = {w["number"]: w["kind"] for w in KNOWN}
        for number, row in named.items():
            print(f"     stray window {number} ({kinds.get(number, 'not an AppKit window of the app')}) at {row['bounds']} layer {row['layer']} alpha {row['alpha']}"
                  f" meets a screen {row['meets']} first seen at {row['mark']}", flush=True)
        check("no Broadway window but the browser window is on screen at any sample", not stray, len(stray))
        check("no Broadway window but the browser window meets a screen at any sample", not [r for r in stray if r["meets"]], len(stray))
        print(f"     {len(samples)} samples of the window list", flush=True)
    finally:
        stop.set()
        subprocess.run([BENCH, "--world", WORLD, "quit"], capture_output=True)
        for _ in range(40):
            if not held():
                break
            time.sleep(0.25)
        for pid in held():
            os.kill(int(pid), signal.SIGKILL)
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
        subprocess.run(["rm", "-rf", str(SCRATCH)])
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()

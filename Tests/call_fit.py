#!/usr/bin/env python3
"""A floating call fits its grid: every tile in sight, centred, above the call bar.

Build first (`./build.sh`), then `python3 Tests/call_fit.py [OUT] [--shots-only]`.
The fake call pages lay their tiles out by script, in inline pixels, for
their own stage (a header, a toolbar band and an open side panel take room
from it), and lay them out again on `resize`, the way Meet does. Their tiles
don't fill the element that holds them, so pinning that element to the float
isn't enough on its own. Each case floats, is shot into OUT (default
.context/call-fit) and, unless --shots-only, is checked: every tile inside
the room above the call bar, the grid centred in it, the videos still live.
"""
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import visual_diff as vd  # noqa: E402

sv.use("page-call-fit")
t = sv.T()

NAMES = ["Nadia Brooks", "Oscar Lindqvist", "Valentina Okafor-Hale", "Pia Sorensen", "Tomas Ferro", "Sam Rowe",
         "Gil Navarro", "Hana Ito", "Ivo Brandt", "Jun Mercer", "Kit Moreau", "Lou Baxter"]
COLOURS = ["#1e8e3e", "#a142f4", "#e37400", "#1a73e8", "#d93025", "#12b5cb", "#f538a0", "#5f6368", "#188038",
           "#9334e6", "#b06000", "#185abc"]

PAGE = r"""<!doctype html><title>Weekly sync - Meet</title><style>
html, body { margin: 0; height: 100%; background: #202124; color: #e8eaed; font: 14px system-ui; overflow: hidden; }
.app { position: absolute; inset: 0; display: flex; flex-direction: column; background: #202124; }
header { height: 48px; flex: none; display: flex; align-items: center; padding: 0 16px; }
.middle { flex: 1; display: flex; min-height: 0; background: #202124; }
.stage { flex: 1; position: relative; background: #2a2b2e; }
.grid { position: absolute; inset: 0; }
.tile { position: absolute; border-radius: 10px; overflow: hidden; background: #3c4043; display: flex; align-items: center; justify-content: center; }
.tile video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.tile .face { width: 30%; aspect-ratio: 1; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 28px; color: #fff; }
.tile .name { position: absolute; left: 10px; bottom: 8px; font-weight: 500; text-shadow: 0 1px 2px #000; }
aside { width: 240px; flex: none; background: #fff; color: #202124; border-radius: 8px; margin: 8px; padding: 12px; }
.bar { height: 80px; flex: none; display: flex; align-items: center; justify-content: center; gap: 10px; }
.bar button { border: 0; border-radius: 20px; background: #3c4043; color: #e8eaed; height: 40px; min-width: 40px; }
.bar .leave { background: #ea4335; width: 56px; }
</style>
<div class=app>
  <header role=banner>Weekly sync</header>
  <div class=middle><div class=stage><div class=grid>__TILES__</div></div>
    __PANEL__</div>
  <div class=bar role=toolbar aria-label="Call controls">
    <button aria-label="Turn off microphone" data-is-muted=false>m</button>
    <button aria-label="Turn off camera" data-is-muted=false>c</button>
    <button class=leave aria-label="Leave call" onclick="end()">x</button>
  </div>
</div>
<script>
const UP = __UP__;
const stage = document.querySelector('.stage');
function lay() {
  const tiles = [...document.querySelectorAll('.grid > *')];
  const W = stage.clientWidth, H = stage.clientHeight, gap = 8, n = tiles.length;
  let best = null;
  for (let cols = 1; cols <= n; cols++) {
    const rows = Math.ceil(n / cols);
    const w = Math.min((W - gap * (cols + 1)) / cols, ((H - gap * (rows + 1)) / rows) * 16 / 9);
    if (!best || w > best.w) best = {cols, rows, w};
  }
  const w = best.w, h = w * 9 / 16;
  const top = (H - (best.rows * h + (best.rows - 1) * gap)) / 2 - UP;
  tiles.forEach((tile, i) => {
    const row = Math.floor(i / best.cols), inRow = Math.min(best.cols, n - row * best.cols);
    const left = (W - (inRow * w + (inRow - 1) * gap)) / 2 + (i % best.cols) * (w + gap);
    tile.style.cssText = `left:${left}px;top:${top + row * (h + gap)}px;width:${w}px;height:${h}px`;
  });
}
lay();
addEventListener('resize', () => setTimeout(lay, 120));
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => {
  window.stream = s; window.state = 'started';
  document.querySelectorAll('video').forEach(v => { v.srcObject = s; });
}).catch(e => { window.state = 'error ' + e.name; });
window.end = () => { stream.getTracks().forEach(x => x.stop()); };
window.boxes = sel => JSON.stringify([...document.querySelectorAll(sel)].map(el => {
  const r = el.getBoundingClientRect(); return [r.left, r.top, r.right, r.bottom];
}).concat([[innerWidth, innerHeight, 0, 0]]));
window.frames = () => [...document.querySelectorAll('video')].map(v => v.currentTime).reduce((a, b) => a + b, 0);
</script>"""


def tiles(n, video, others):
    made = []
    for i in range(n):
        name = NAMES[i % len(NAMES)]
        inside = "<video autoplay muted playsinline></video>" if video or i % 3 == 0 else \
            f"<div class=face style='background:{COLOURS[i % len(COLOURS)]}'>{name[0]}</div>"
        mark = "" if video else f" data-participant-id='spaces/a/devices/{i + 1}'"
        made.append(f"<div class=tile{mark}>{inside}<span class=name>{name}</span></div>")
    if others:
        made.append("<div class='tile others'><span class=name>3 others</span></div>")
    return "".join(made)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path.strip("/") == "call":
            html = PAGE.replace("__TILES__", tiles(int(q.get("n", 6)), q.get("kind") == "video", q.get("others") == "1"))
            html = html.replace("__UP__", q.get("up", "0"))
            html = html.replace("__PANEL__", "" if q.get("panel") == "0" else '<aside role=complementary aria-label="People">People</aside>')
        else:
            html = "<!doctype html><title>idle</title><p>idle</p>"
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H

CASES = [
    ("tiles-1", "n=1"),
    ("tiles-2", "n=2"),
    ("tiles-4", "n=4"),
    ("tiles-6", "n=6"),
    ("tiles-9", "n=9"),
    ("tiles-12", "n=12"),
    ("tiles-6-wide", "n=6&panel=0"),
    ("tiles-6-up", "n=6&up=60"),
    ("tiles-6-far", "n=6&up=250"),
    ("tiles-5-others", "n=5&others=1"),
    ("video-4", "n=4&kind=video"),
]
ROOM = {"top": 8, "side": 8, "bottom": 58}
FLOAT_WIDTH = 340


def call(action="state", *values):
    return sv.cmd({"do": "call", "action": action, "values": list(values)})


def until(check, within=6):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def launch_shown():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


BLIND = []


def shoot(path):
    path = Path(path)
    path.unlink(missing_ok=True)
    if not BLIND:
        shot = vd.tool("shot", "WindowShot.swift")
        pid = next(iter(sv.holding() & sv.running()))
        number = call("show")["window"]
        time.sleep(0.8)
        ran = subprocess.run([str(shot), str(pid), str(number), str(path)], capture_output=True, text=True)
        call("hide")
        print("  ", ran.stdout.strip(), ran.stderr.strip()[-300:])
        if path.exists():
            return True
        BLIND.append(True)
        print("   note  the screen cannot be recorded now, so the call's page is drawn off the screen, without the window's bar, corners and edge")
    drawn = path.with_name(path.stem + "-drawn.png")
    drawn.unlink(missing_ok=True)
    try:
        call("draw", str(drawn.resolve()))
    except RuntimeError as error:
        print("  ", str(error)[-300:])
    return drawn.exists()


def check(name, page, query):
    import json
    selector = "video" if "kind=video" in query else "[data-participant-id], .others"
    found = json.loads(sv.ev(page, f"boxes({selector!r})"))
    width, height = found.pop()[:2]
    k = width / (call().get("width") or FLOAT_WIDTH)
    left, top = ROOM["side"] * k, ROOM["top"] * k
    right, bottom = width - ROOM["side"] * k, height - ROOM["bottom"] * k
    slack = 1.0
    inside = all(b[0] >= left - slack and b[1] >= top - slack and b[2] <= right + slack and b[3] <= bottom + slack for b in found)
    t.ok(f"{name}: every tile is inside the room above the bar", inside, (left, top, right, bottom, found))
    ux0, uy0 = min(b[0] for b in found), min(b[1] for b in found)
    ux1, uy1 = max(b[2] for b in found), max(b[3] for b in found)
    across = abs((ux0 - left) - (right - ux1)) <= 2
    down = abs((uy0 - top) - (bottom - uy1)) <= 2
    touches = min(ux0 - left, right - ux1) <= 2 or min(uy0 - top, bottom - uy1) <= 2
    t.ok(f"{name}: the grid is centred and fills one way", across and down and touches, (ux0, uy0, ux1, uy1, left, top, right, bottom))
    first = sv.ev(page, "frames()")
    time.sleep(0.6)
    t.ok(f"{name}: the videos are live", sv.ev(page, "frames()") > first, (first, sv.ev(page, "frames()")))


SIZES = [("sizes-4", "n=4"), ("sizes-9", "n=9")]


def resting(wide):
    return round((wide - 2 * ROOM["side"]) * 148 / 324 + ROOM["top"] + ROOM["bottom"])


def sized(wide):
    state = call()
    return abs(state["width"] - wide) < 1 and abs(state["height"] - resting(wide)) <= 1


def floated(name, query, idle):
    page = sv.page(f"call?{query}")
    sv.cmd({"do": "select", "id": page})
    t.ok(f"{name}: the call starts", until(lambda: sv.ev(page, "window.state") == "started"), sv.ev(page, "window.state"))
    sv.cmd({"do": "select", "id": idle})
    t.ok(f"{name}: leaving the tab floats it", until(lambda: call()["showing"]), call())
    time.sleep(2.5)
    return page


def sizes(out, idle, only, shots_only):
    for name, query in SIZES:
        if only and name not in only:
            continue
        page = floated(name, query, idle)
        state = call()
        if "largest" not in state:
            t.ok(f"{name}: the call window can be made larger", False, "this build keeps the window at one size")
            shoot(out / f"{name}-smallest.png")
            call("return")
            until(lambda: not call()["showing"])
            sv.ev(page, "end(), 1")
            sv.cmd({"do": "select", "id": idle})
            time.sleep(1)
            continue
        largest = state["largest"]
        t.ok(f"{name}: it opens at the smallest size", sized(FLOAT_WIDTH), state)
        t.ok(f"{name}: the largest is half the screen's width and more than the smallest", largest > FLOAT_WIDTH, largest)
        for label, wide in (("smallest", FLOAT_WIDTH), ("middle", round((FLOAT_WIDTH + largest) / 2)), ("largest", largest)):
            call("size", str(wide))
            t.ok(f"{name} at the {label} size: the window is {wide:g} wide and keeps its shape", until(lambda: sized(wide)), call())
            scale = min(1, 0.5 * (wide / FLOAT_WIDTH) ** 0.5)
            t.ok(f"{name} at the {label} size: the page is drawn at {scale:.2f} of its size", until(lambda: abs(call()["zoom"] - scale) < 0.01),
                 call()["zoom"])
            time.sleep(2.5)
            t.ok(f"{name} at the {label} size: shot", shoot(out / f"{name}-{label}.png"))
            if not shots_only:
                check(f"{name} at the {label} size", page, query)
        call("size", str(largest + 400))
        t.ok(f"{name}: it grows no wider than the largest", until(lambda: sized(largest)), call())
        call("size", "120")
        t.ok(f"{name}: it shrinks no smaller than today's size", until(lambda: sized(FLOAT_WIDTH)), call())
        middle = round((FLOAT_WIDTH + largest) / 2)
        call("size", str(middle))
        until(lambda: sized(middle))
        call("return")
        until(lambda: not call()["showing"])
        sv.cmd({"do": "select", "id": page})
        time.sleep(1)
        sv.cmd({"do": "select", "id": idle})
        t.ok(f"{name}: it floats again", until(lambda: call()["showing"]), call())
        t.ok(f"{name}: the chosen size is remembered for the next call", until(lambda: sized(middle)), call())
        call("edge")
        t.ok(f"{name}: a double-click on the edge goes back to the smallest", until(lambda: sized(FLOAT_WIDTH)), call())
        call("return")
        until(lambda: not call()["showing"])
        sv.cmd({"do": "select", "id": page})
        time.sleep(1)
        sv.cmd({"do": "select", "id": idle})
        t.ok(f"{name}: it floats once more", until(lambda: call()["showing"]), call())
        t.ok(f"{name}: and the smallest is remembered too", until(lambda: sized(FLOAT_WIDTH)), call())
        call("return")
        until(lambda: not call()["showing"])
        sv.ev(page, "end(), 1")
        sv.cmd({"do": "select", "id": idle})
        time.sleep(1)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    shots_only = "--shots-only" in sys.argv
    only = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--only=")), None)
    out = Path(args[0] if args else ".context/call-fit")
    out.mkdir(parents=True, exist_ok=True)
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    launch_shown()
    try:
        idle = sv.page("idle")
        for name, query in CASES:
            if only and name not in only:
                continue
            page = sv.page(f"call?{query}")
            sv.cmd({"do": "select", "id": page})
            t.ok(f"{name}: the call starts", until(lambda: sv.ev(page, "window.state") == "started"), sv.ev(page, "window.state"))
            sv.cmd({"do": "select", "id": idle})
            t.ok(f"{name}: leaving the tab floats it", until(lambda: call()["showing"]), call())
            time.sleep(2.5)
            t.ok(f"{name}: shot", shoot(out / f"{name}.png"))
            if name == "tiles-6":
                call("hover", "on")
                t.ok(f"{name}: the corners show on hover", until(lambda: call()["corners"]), call())
                t.ok(f"{name}: shot with corners", shoot(out / f"{name}-corners.png"))
                call("hover", "off")
            if not shots_only:
                check(name, page, query)
            call("return")
            until(lambda: not call()["showing"])
            sv.ev(page, "end(), 1")
            sv.cmd({"do": "select", "id": idle})
            time.sleep(1)
        sizes(out, idle, only, shots_only)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

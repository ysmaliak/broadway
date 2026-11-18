#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv
import visual_diff as vd

sv.use("page-call-present")
t = sv.T()

NAMES = ["Nadia Brooks", "Oscar Lindqvist", "Pia Sorensen", "Tomas Ferro", "Sam Rowe", "Gil Navarro", "Hana Ito", "Ivo Brandt"]
COLOURS = ["#1e8e3e", "#a142f4", "#e37400", "#1a73e8", "#d93025", "#12b5cb", "#f538a0", "#5f6368"]

PAGE = r"""<!doctype html><title>Planning - call</title><style>
html, body { margin: 0; height: 100%; background: #202124; color: #e8eaed; font: 14px system-ui; overflow: hidden; }
.app { position: absolute; inset: 0; display: flex; flex-direction: column; background: #202124; }
header { height: 48px; flex: none; display: flex; align-items: center; padding: 0 16px; }
.middle { flex: 1; display: flex; min-height: 0; }
.room { flex: 1; min-width: 0; position: relative; display: flex; flex-direction: column; gap: 8px; padding: 8px; box-sizing: border-box; }
.room.bottom { flex-direction: column-reverse; }
.room.side { flex-direction: row-reverse; }
.strip { flex: none; display: flex; gap: 8px; justify-content: center; }
.room.side .strip { flex-direction: column; }
.room.split .strip { flex: 1; flex-wrap: wrap; align-content: center; }
.room.split { flex-direction: row; }
.strip .tile { flex: none; width: 160px; height: 90px; }
.main { flex: 1; min-width: 0; min-height: 0; position: relative; }
.tile { position: relative; border-radius: 10px; overflow: hidden; background: #3c4043; display: flex; align-items: center; justify-content: center; }
.tile video, .tile canvas { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.big { position: absolute; inset: 0; }
.share { background: #000; }
.share .screen { object-fit: contain; }
.self { position: absolute; top: 6px; left: 50%; margin-left: -60px; width: 120px; height: 68px; z-index: 3; box-shadow: 0 2px 8px #000a; }
.chip { position: absolute; right: 10px; top: 10px; z-index: 4; background: #5f6368; color: #fff; border-radius: 14px; padding: 4px 10px; font-weight: 600; }
.chip.loud { visibility: visible; }
.face { width: 34%; aspect-ratio: 1; border-radius: 50%; display: flex; align-items: center; justify-content: center; font-size: 22px; color: #fff; }
.name { position: absolute; left: 8px; bottom: 6px; font-weight: 500; font-size: 12px; text-shadow: 0 1px 2px #000; }
.off { position: absolute; right: 6px; top: 6px; width: 18px; height: 18px; border-radius: 9px; background: #ea4335; }
.off::after { content: ""; position: absolute; left: 8px; top: 3px; width: 2px; height: 12px; background: #fff; transform: rotate(45deg); }
.bar { height: 80px; flex: none; display: flex; align-items: center; justify-content: center; gap: 10px; }
.bar button { border: 0; border-radius: 20px; background: #3c4043; color: #e8eaed; height: 40px; min-width: 40px; }
.bar .leave { background: #ea4335; width: 56px; }
</style>
<div class=app>
  <header role=banner>Planning</header>
  <div class=middle><div class="room __STRIP__">
    <div class=strip>__TILES__</div>
    <div class=main></div>
  </div></div>
  <div class=bar role=toolbar aria-label="Call controls">
    <button aria-label="Turn off microphone" data-is-muted=false
      onclick="pressed.push('mic'); this.dataset.isMuted = this.dataset.isMuted === 'false' ? 'true' : 'false'">m</button>
    <button aria-label="Turn off camera" data-is-muted=false>c</button>
    <button class=leave aria-label="Leave call" onclick="end()">x</button>
  </div>
</div>
<script>
const Q = new URLSearchParams(location.search);
const MARK = Q.get('mark') !== '0', KIND = Q.get('kind') || 'video', LABEL = Q.get('label') !== '0';
const main = document.querySelector('.main');
window.painted = 0;
window.pressed = [];
function paint(c) {
  const g = c.getContext('2d'), w = c.width, h = c.height;
  g.fillStyle = '#f4f1ea'; g.fillRect(0, 0, w, h);
  g.fillStyle = '#ff7a00'; g.fillRect(0, 0, w, 14); g.fillRect(0, h - 14, w, 14); g.fillRect(0, 0, 14, h); g.fillRect(w - 14, 0, 14, h);
  g.fillStyle = '#d9d4c8'; g.fillRect(14, 14, w - 28, 40);
  g.fillStyle = '#222'; g.font = '600 24px system-ui'; g.fillText('Quarterly numbers', 40, 42);
  g.fillStyle = '#fff'; g.fillRect(120, 120, w - 240, h - 240);
  g.strokeStyle = '#bbb'; g.lineWidth = 2; g.strokeRect(120, 120, w - 240, h - 240);
  const bars = [0.35, 0.6, 0.45, 0.8, 0.7, 0.95];
  bars.forEach((b, i) => { g.fillStyle = ['#1a73e8', '#12b5cb', '#1e8e3e', '#e37400', '#a142f4', '#d93025'][i];
    g.fillRect(200 + i * 150, h - 180 - b * 360, 100, b * 360); });
  g.fillStyle = '#222'; g.font = '500 28px system-ui'; g.fillText('Frame ' + (++window.painted), 160, 180);
}
function screenEl() {
  if (KIND === 'canvas') {
    const c = document.createElement('canvas'); c.width = 1280; c.height = 800; c.className = 'screen'; paint(c);
    c._timer = setInterval(() => paint(c), 100);
    return c;
  }
  const c = document.createElement('canvas'); c.width = 1280; c.height = 800; paint(c);
  const v = document.createElement('video'); v.className = 'screen'; v.autoplay = true; v.muted = true; v.playsInline = true;
  v._timer = setInterval(() => paint(c), 100);
  v.srcObject = c.captureStream(15);
  v.play().catch(() => {});
  return v;
}
function tile(kind, id, name) {
  const el = document.createElement('div'); el.className = 'tile ' + kind;
  if (MARK) el.setAttribute('data-participant-id', 'spaces/a/devices/' + id);
  if (name) { const n = document.createElement('span'); n.className = 'name'; n.textContent = name; el.appendChild(n); }
  return el;
}
function camera(el) {
  const v = document.createElement('video'); v.autoplay = true; v.muted = true; v.playsInline = true; v.className = 'cam';
  if (window.stream) v.srcObject = window.stream;
  el.insertBefore(v, el.firstChild);
}
function extras() {
  if (Q.get('self') !== '0') {
    const self = tile('self', 'me', 'You'); camera(self);
    const off = document.createElement('span'); off.className = 'off'; self.appendChild(off);
    main.appendChild(self);
  }
  if (Q.get('chip') !== '0') {
    const chip = document.createElement('div'); chip.className = 'chip' + (Q.get('loud') === '1' ? ' loud' : ''); chip.textContent = '+9';
    main.appendChild(chip);
  }
}
window.present = () => {
  main.innerHTML = '';
  const share = tile('big share', LABEL ? 'presentation' : '9', LABEL ? 'Nadia Brooks (Presentation)' : 'Nadia Brooks');
  share.insertBefore(screenEl(), share.firstChild);
  main.appendChild(share); extras();
  return 1;
};
window.stopPresenting = () => {
  const s = document.querySelector('.screen');
  if (s) { clearInterval(s._timer); if (s.srcObject) s.srcObject.getTracks().forEach(x => x.stop()); }
  main.innerHTML = '';
  const speaker = tile('big speaker', 'speaker', 'Oscar Lindqvist'); camera(speaker);
  main.appendChild(speaker); extras();
  return 1;
};
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => {
  window.stream = s; window.state = 'started';
  document.querySelectorAll('video.cam').forEach(v => { v.srcObject = s; });
}).catch(e => { window.state = 'error ' + e.name; });
document.querySelectorAll('.strip .tile[data-cam]').forEach(camera);
if (!MARK) document.querySelectorAll('[data-participant-id]').forEach(el => el.removeAttribute('data-participant-id'));
if (Q.get('present') === '0') stopPresenting(); else present();
window.end = () => { stream.getTracks().forEach(x => x.stop()); };
window.seen = sel => { const all = [...document.querySelectorAll(sel)]; if (!all.length) return 'missing';
  return all.some(el => getComputedStyle(el).visibility === 'visible' && el.getClientRects().length > 0) ? 'shown' : 'hidden'; };
window.picture = () => { const el = document.querySelector('.screen'); if (!el) return 'null';
  const r = el.getBoundingClientRect(), iw = el.videoWidth || el.width, ih = el.videoHeight || el.height, fit = getComputedStyle(el).objectFit;
  let w = r.width, h = r.height;
  if (fit === 'contain' || fit === 'scale-down') { const k = Math.min(r.width / iw, r.height / ih); w = iw * k; h = ih * k; }
  return JSON.stringify([r.left + (r.width - w) / 2, r.top + (r.height - h) / 2, r.left + (r.width + w) / 2, r.top + (r.height + h) / 2, innerWidth, innerHeight, iw, ih]); };
window.edge = () => { const el = document.querySelector('.screen'); if (!el) return 'null';
  const c = document.createElement('canvas'); c.width = 128; c.height = 80; const g = c.getContext('2d');
  try { g.drawImage(el, 0, 0, 128, 80); } catch (e) { return String(e); }
  return JSON.stringify([[0, 0], [127, 0], [0, 79], [127, 79]].map(p => [...g.getImageData(p[0], p[1], 1, 1).data])); };
window.frames = () => { const el = document.querySelector('.screen'); return el && el.tagName === 'VIDEO' ? el.currentTime : window.painted; };
window.boxes = sel => JSON.stringify([...document.querySelectorAll(sel)].map(el => {
  const r = el.getBoundingClientRect(); return [r.left, r.top, r.right, r.bottom];
}).concat([[innerWidth, innerHeight, 0, 0]]));
</script>"""


def tiles(n, cams):
    made = []
    for i in range(n):
        name = NAMES[i % len(NAMES)]
        cam = " data-cam" if i in cams else ""
        face = "" if i in cams else f"<div class=face style='background:{COLOURS[i % len(COLOURS)]}'>{name[0]}</div>"
        made.append(f"<div class=tile{cam} data-participant-id='spaces/a/devices/{i + 1}'>{face}<span class=name>{name}</span></div>")
    return "".join(made)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path.strip("/") == "call":
            n = int(q.get("n", 7))
            cams = {int(c) for c in q.get("cams", "2,4").split(",") if c != ""}
            html = PAGE.replace("__TILES__", tiles(n, cams)).replace("__STRIP__", q.get("strip", "top"))
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

PRESENTING = [
    ("marked-video", "mark=1&kind=video"),
    ("bare-video", "mark=0&kind=video&label=0&cams=3"),
    ("marked-canvas-side", "mark=1&kind=canvas&strip=side&label=0"),
    ("bare-canvas-below", "mark=0&kind=canvas&strip=bottom&loud=1"),
    ("marked-split", "mark=1&kind=video&strip=split&n=4"),
]
QUIET = [
    ("speaker-view", "mark=1&present=0"),
    ("speaker-bare", "mark=0&present=0&cams=1,3,5"),
    ("one-to-one", "mark=1&present=0&n=0&chip=0"),
]
OTHERS = {"a strip tile": ".strip .tile", "the +9 chip": ".chip", "the speaker's small tile": ".self", "a name": ".name"}
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


def room(width, height):
    k = width / (call().get("width") or FLOAT_WIDTH)
    return ROOM["side"] * k, ROOM["top"] * k, width - ROOM["side"] * k, height - ROOM["bottom"] * k


def resting(wide):
    return round((wide - 2 * ROOM["side"]) * 148 / 324 + ROOM["top"] + ROOM["bottom"])


def rests(wide=FLOAT_WIDTH):
    state = call()
    return abs(state["width"] - wide) < 1 and abs(state["height"] - resting(wide)) <= 1


def held(name, was):
    now = call()
    room = now.get("room") or []
    t.ok(f"{name}: the window is on a screen", len(room) == 4 and len(was.get("room") or []) == 4, (was, now))
    if len(room) != 4:
        return
    t.ok(f"{name}: the window changed its height", abs(now["height"] - was["height"]) > 1, (was["height"], now["height"]))
    right = was["x"] + was["width"] / 2 >= room[0] + room[2] / 2
    up = was["y"] + was["height"] / 2 >= room[1] + room[3] / 2
    across = abs(now["x"] + now["width"] - was["x"] - was["width"]) < 1 if right else abs(now["x"] - was["x"]) < 1
    down = abs(now["y"] + now["height"] - was["y"] - was["height"]) < 1 if up else abs(now["y"] - was["y"]) < 1
    corner = across and down
    t.ok(f"{name}: it grew from the corner it sits in", corner, (was["x"], was["y"], was["height"], now["x"], now["y"], now["height"]))
    inside = (now["x"] >= room[0] - 1 and now["y"] >= room[1] - 1 and now["x"] + now["width"] <= room[0] + room[2] + 1
              and now["y"] + now["height"] <= room[1] + room[3] + 1)
    t.ok(f"{name}: it is whole inside the screen", inside, (now["x"], now["y"], now["width"], now["height"], room))


def shaped(name, page, wide=FLOAT_WIDTH):
    if "picture" not in call():
        t.ok(f"{name}: the window takes the shared screen's shape", False, "this build keeps the window at one size")
        return
    found = sv.ev(page, "picture()")
    if found in (None, "null"):
        t.ok(f"{name}: there is a shared screen to take the shape of", False, found)
        return
    iw, ih = json.loads(found)[6:8]
    want = min(max(iw / ih, 0.75), 4)

    def fits():
        state = call()
        stage = (state["width"] - 2 * ROOM["side"]) / max(state["height"] - ROOM["top"] - ROOM["bottom"], 1)
        return abs(state["width"] - wide) < 1 and abs(stage - want) <= want * 0.02

    t.ok(f"{name}: the window's stage takes the picture's shape at {wide:g} wide", until(fits), (call(), want))
    time.sleep(1.5)
    x0, y0, x1, y1, width, height = json.loads(sv.ev(page, "picture()"))[:6]
    left, top, right, bottom = room(width, height)
    both = min(x0 - left, right - x1) <= 3 and min(y0 - top, bottom - y1) <= 3
    t.ok(f"{name}: the picture fills the stage both ways, with no band beside it", both, (x0, y0, x1, y1, left, top, right, bottom))


def alone(name, page):
    found = sv.ev(page, "picture()")
    if found in (None, "null"):
        t.ok(f"{name}: there is a shared screen", False, found)
        return
    x0, y0, x1, y1, width, height, iw, ih = json.loads(found)
    left, top, right, bottom = room(width, height)
    slack = 1.0
    inside = x0 >= left - slack and y0 >= top - slack and x1 <= right + slack and y1 <= bottom + slack
    t.ok(f"{name}: the shared picture is whole inside the room above the bar", inside, (x0, y0, x1, y1, left, top, right, bottom))
    across = abs((x0 - left) - (right - x1)) <= 2
    down = abs((y0 - top) - (bottom - y1)) <= 2
    touches = min(x0 - left, right - x1) <= 2 or min(y0 - top, bottom - y1) <= 2
    t.ok(f"{name}: it is centred and fills one way", across and down and touches, (x0, y0, x1, y1, left, top, right, bottom))
    shape = abs((x1 - x0) / max(y1 - y0, 1) - iw / ih) <= 0.02
    t.ok(f"{name}: it keeps its shape", shape, ((x1 - x0) / max(y1 - y0, 1), iw / ih))
    for what, sel in OTHERS.items():
        if sv.ev(page, f"seen({sel!r})") == "missing":
            continue
        t.ok(f"{name}: {what} is out of sight", sv.ev(page, f"seen({sel!r})") == "hidden", sv.ev(page, f"seen({sel!r})"))
    t.ok(f"{name}: the shared screen shows", sv.ev(page, "seen('.screen')") == "shown")
    corners = json.loads(sv.ev(page, "edge()"))
    orange = all(c[0] > 200 and 80 < c[1] < 170 and c[2] < 70 and c[3] == 255 for c in corners)
    t.ok(f"{name}: its picture reaches all four corners", orange, corners)
    first = sv.ev(page, "frames()")
    time.sleep(0.8)
    t.ok(f"{name}: the shared screen is live", sv.ev(page, "frames()") > first,
         (first, sv.ev(page, "frames()"), sv.ev(page, "document.visibilityState")))


def pressed(name, page):
    t.ok(f"{name}: the bar shows the page's microphone", until(lambda: call()["mic"] is True), call())
    call("mute")
    t.ok(f"{name}: mute presses the page's button though it is out of sight", until(lambda: sv.ev(page, "pressed.join()") == "mic"),
         sv.ev(page, "pressed.join()"))
    t.ok(f"{name}: the bar follows the page", until(lambda: call()["mic"] is False), call())
    t.ok(f"{name}: the shared screen is still alone", sv.ev(page, "seen('.screen')") == "shown"
         and sv.ev(page, "seen(\"[aria-label='Call controls']\")") == "hidden")


def larger(name, page, out, tag):
    state = call()
    if "largest" not in state:
        t.ok(f"{name}: the call window can be made larger", False, "this build keeps the window at one size")
        return
    largest = state["largest"]
    for label, wide in (("middle", round((FLOAT_WIDTH + largest) / 2)), ("largest", largest)):
        call("size", str(wide))
        shaped(f"{name} at the {label} size", page, wide)
        t.ok(f"{name} at the {label} size: shot", shoot(out / f"{name}-{label}-{tag}.png"))
        alone(f"{name} at the {label} size", page)
    call("edge")
    shaped(f"{name} back at the smallest size", page)


def tiled(name, page):
    t.ok(f"{name}: nothing is singled out as a shared screen", sv.ev(page, "document.querySelectorAll('[data-broadway-tiles-screen]').length") == 0)
    t.ok(f"{name}: the tiles are pinned as a grid", sv.ev(page, "document.querySelectorAll('[data-broadway-tiles-grid]').length") == 1)
    for what, sel in {"a strip tile": ".strip .tile", "the big tile": ".big", "the small tile": ".self"}.items():
        if sv.ev(page, f"seen({sel!r})") == "missing":
            continue
        t.ok(f"{name}: {what} shows", sv.ev(page, f"seen({sel!r})") == "shown", sv.ev(page, f"seen({sel!r})"))
    found = json.loads(sv.ev(page, "boxes('.tile')"))
    width, height = found.pop()[:2]
    left, top, right, bottom = room(width, height)
    inside = all(b[0] >= left - 1 and b[1] >= top - 1 and b[2] <= right + 1 and b[3] <= bottom + 1 for b in found)
    t.ok(f"{name}: every tile is inside the room above the bar", inside, (left, top, right, bottom, found))


def clean(name, page):
    marks = "document.querySelectorAll('[data-broadway-tiles-grid],[data-broadway-tiles-path],[data-broadway-tiles-chrome]," \
        "[data-broadway-tiles-screen],#broadway-call-tiles,#broadway-call-fit').length"
    t.ok(f"{name}: landing leaves no marks", until(lambda: sv.ev(page, marks) == 0, within=3), sv.ev(page, marks))
    t.ok(f"{name}: the page is its own again", sv.ev(page, "document.documentElement.hasAttribute('data-broadway-tiles')") is False)
    for what, sel in {"the header": "header", "the strip": ".strip", "the toolbar": "[aria-label='Call controls']"}.items():
        t.ok(f"{name}: {what} is back", sv.ev(page, f"seen({sel!r})") == "shown", sv.ev(page, f"seen({sel!r})"))


def float_it(name, query, idle):
    page = sv.page(f"call?{query}")
    sv.cmd({"do": "select", "id": page})
    t.ok(f"{name}: the call starts", until(lambda: sv.ev(page, "window.state") == "started"), sv.ev(page, "window.state"))
    sv.cmd({"do": "select", "id": idle})
    t.ok(f"{name}: leaving the tab floats it", until(lambda: call()["showing"]), call())
    time.sleep(2.5)
    return page


def land(page, idle):
    call("return")
    until(lambda: not call()["showing"])


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    shots_only = "--shots-only" in sys.argv
    only = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--only=")), None)
    tag = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tag=")), "after")
    out = Path(args[0] if args else ".context/float-review/call")
    out.mkdir(parents=True, exist_ok=True)
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    launch_shown()
    try:
        idle = sv.page("idle")
        for name, query in PRESENTING:
            if only and name not in only:
                continue
            page = float_it(name, query, idle)
            if not shots_only:
                shaped(name, page)
            t.ok(f"{name}: shot", shoot(out / f"{name}-{tag}.png"))
            if not shots_only:
                alone(name, page)
                if name == PRESENTING[0][0]:
                    pressed(name, page)
                    larger(name, page, out, tag)
            land(page, idle)
            if not shots_only:
                clean(name, page)
            sv.ev(page, "end(), 1")
            sv.cmd({"do": "select", "id": idle})
            time.sleep(1)
        for name, query in QUIET:
            if only and name not in only:
                continue
            page = float_it(name, query, idle)
            t.ok(f"{name}: shot", shoot(out / f"{name}-{tag}.png"))
            if not shots_only:
                tiled(name, page)
                t.ok(f"{name}: with nobody presenting the window keeps its resting shape", rests(), call())
            land(page, idle)
            sv.ev(page, "end(), 1")
            sv.cmd({"do": "select", "id": idle})
            time.sleep(1)
        name = "starts-and-stops"
        if not only or name in only:
            page = float_it(name, "mark=1&kind=video&present=0", idle)
            sizable = "largest" in call()
            chosen = FLOAT_WIDTH
            if not shots_only:
                tiled(f"{name}, before", page)
                t.ok(f"{name}, before: the window rests at today's size", rests(), call())
                if sizable:
                    chosen = round((FLOAT_WIDTH + call()["largest"]) / 2)
                    call("size", str(chosen))
                    t.ok(f"{name}, before: a chosen width holds with nobody presenting", until(lambda: rests(chosen)), call())
            seen = None
            if not shots_only and sizable and not BLIND and "room" in call():
                call("show")
                time.sleep(0.8)
                seen = call()
            sv.ev(page, "present()")
            time.sleep(3)
            if not shots_only:
                shaped(f"{name}, presenting", page, chosen)
            if seen:
                held(f"{name}, presenting, on the screen", seen)
            t.ok(f"{name}: shot while presenting", shoot(out / f"{name}-presenting-{tag}.png"))
            if not shots_only:
                alone(f"{name}, presenting", page)
            sv.ev(page, "stopPresenting()")
            time.sleep(3)
            if not shots_only:
                t.ok(f"{name}, after: the window goes back to its resting shape at the chosen width", until(lambda: rests(chosen)), call())
                time.sleep(1.5)
            t.ok(f"{name}: shot after it stops", shoot(out / f"{name}-stopped-{tag}.png"))
            if not shots_only:
                tiled(f"{name}, after", page)
                if sizable:
                    call("edge")
                    t.ok(f"{name}, after: a double-click on the edge goes back to the smallest", until(rests), call())
            land(page, idle)
            if not shots_only:
                clean(name, page)
            sv.ev(page, "end(), 1")
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

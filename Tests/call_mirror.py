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

sv.use("page-call-mirror")
t = sv.T()

PAGE = r"""<!doctype html><title>Standup - call</title><style>
html, body { margin: 0; height: 100%; background: #202124; color: #e8eaed; font: 14px system-ui; overflow: hidden; }
.app { position: absolute; inset: 0; display: flex; flex-direction: column; }
header { height: 48px; flex: none; display: flex; align-items: center; padding: 0 16px; }
.stage { flex: 1; min-height: 0; position: relative; padding: 8px; box-sizing: border-box; display: flex; flex-direction: column; gap: 8px; }
.grid { flex: 1; min-height: 0; display: grid; gap: 8px; grid-template-columns: 1fr 1fr; }
.grid.one { grid-template-columns: 1fr; }
.tile { position: relative; border-radius: 10px; overflow: hidden; background: #3c4043; display: flex; align-items: center; justify-content: center; min-height: 0; }
.tile video, .box video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.box { flex: 1; min-height: 0; position: relative; }
.face { width: 60px; height: 60px; border-radius: 30px; display: flex; align-items: center; justify-content: center; font-size: 24px; color: #fff; }
.name { position: absolute; left: 8px; bottom: 6px; font-weight: 500; font-size: 12px; }
.strip { flex: none; display: flex; gap: 8px; justify-content: center; }
.strip .tile { width: 160px; height: 90px; }
.main { flex: 1; min-height: 0; position: relative; }
.share { position: absolute; inset: 0; background: #000; }
.share video { object-fit: contain; }
.fill { position: absolute; inset: 0; }
#me { background: linear-gradient(90deg, #d93025 50%, #1a73e8 50%); }
.box .bar { position: absolute; left: 0; right: 0; bottom: 0; }
.flip { transform: scaleX(-1); }
.scaled { scale: -1 1; }
.turn { transform: rotateY(180deg); }
.bar { height: 72px; flex: none; display: flex; align-items: center; justify-content: center; gap: 10px; }
.bar button { border: 0; border-radius: 20px; background: #3c4043; color: #e8eaed; height: 40px; min-width: 40px; }
.bar .leave { background: #ea4335; width: 56px; }
</style>
<div class=app>__BODY__</div>
<script>
const Q = new URLSearchParams(location.search);
function camera() {
  const c = document.createElement('canvas'); c.width = 640; c.height = 360;
  const g = c.getContext('2d');
  let n = 0;
  function paint() {
    g.fillStyle = '#d93025'; g.fillRect(0, 0, 320, 360);
    g.fillStyle = '#1a73e8'; g.fillRect(320, 0, 320, 360);
    g.fillStyle = '#fff'; g.font = '700 160px system-ui'; g.fillText('L', 100, 240); g.fillText('R', 420, 240);
    g.fillStyle = '#000'; g.fillRect((n++ * 4) % 640, 0, 4, 12);
  }
  paint(); setInterval(paint, 100);
  return c.captureStream(15);
}
function screen() {
  const c = document.createElement('canvas'); c.width = 1280; c.height = 720;
  const g = c.getContext('2d');
  function paint() {
    g.fillStyle = '#f4f1ea'; g.fillRect(0, 0, 1280, 720);
    g.fillStyle = '#1e8e3e'; g.fillRect(0, 0, 640, 720);
    g.fillStyle = '#222'; g.font = '600 96px system-ui'; g.fillText('Slides', 760, 380);
  }
  paint(); setInterval(paint, 100);
  const s = c.captureStream(15);
  return s;
}
const me = document.getElementById('me');
if (me.tagName === 'VIDEO') { me.srcObject = camera(); me.play().catch(() => {}); }
else { const g = me.getContext('2d'); window.painted = 0; setInterval(() => {
  g.fillStyle = '#d93025'; g.fillRect(0, 0, 320, 360); g.fillStyle = '#1a73e8'; g.fillRect(320, 0, 320, 360);
  g.fillStyle = '#fff'; g.font = '700 160px system-ui'; g.fillText('L', 100, 240); g.fillText('R', 420, 240); window.painted++; }, 100); }
const shared = document.getElementById('shared');
if (shared) { shared.srcObject = screen(); shared.play().catch(() => {}); }
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => { window.stream = s; window.state = 'started'; })
  .catch(e => { window.state = 'error ' + e.name; });
window.end = () => { if (window.stream) stream.getTracks().forEach(x => x.stop()); };
window.facing = sel => {
  let el = document.querySelector(sel), s = 1;
  if (!el) return 0;
  for (; el; el = el.parentElement) {
    const c = getComputedStyle(el);
    if (c.transform && c.transform !== 'none') { const m = new DOMMatrixReadOnly(c.transform); if (m.a * m.d - m.b * m.c < 0) s = -s; }
    if (c.scale && c.scale !== 'none') { const p = c.scale.split(' ').map(parseFloat); if (p[0] * (p.length > 1 ? p[1] : p[0]) < 0) s = -s; }
  }
  return s;
};
window.marks = sel => { const el = document.querySelector(sel); if (!el) return 'missing';
  return [...el.attributes].map(a => a.name).filter(n => n.indexOf('data-broadway-tiles') === 0).join(' ') || 'none'; };
window.box = sel => { const r = document.querySelector(sel).getBoundingClientRect(); return JSON.stringify([r.left, r.top, r.right, r.bottom, innerWidth, innerHeight]); };
window.seen = sel => { const el = document.querySelector(sel); if (!el) return 'missing';
  return getComputedStyle(el).visibility === 'visible' && el.getClientRects().length > 0 ? 'shown' : 'hidden'; };
window.frames = sel => { const el = document.querySelector(sel); return el.tagName === 'VIDEO' ? el.currentTime : window.painted; };
</script>"""

BAR = """<div class=bar role=toolbar aria-label="Call controls">
  <button aria-label="Turn off microphone" data-is-muted=false>m</button>
  <button aria-label="Turn off camera" data-is-muted=false>c</button>
  __EXTRA__<button class=leave aria-label="Leave call" onclick="end()">x</button>
</div>"""


def faces(n):
    return "".join(f"<div class=tile data-participant-id='spaces/a/devices/{i + 2}'><div class=face style='background:#1e8e3e'>{chr(65 + i)}</div>"
                   f"<span class=name>{chr(65 + i)}</span></div>" for i in range(n))


def body(case):
    bar = BAR.replace("__EXTRA__", "")
    head = "<header role=banner>Standup</header>"
    if case == "grid":
        return f"{head}<div class=stage><div class=grid><div class=tile data-participant-id='spaces/a/devices/1'><video id=me class='flip mirror' autoplay muted playsinline></video><span class=name>You</span></div>{faces(3)}</div></div>{bar}"
    if case == "one":
        return f"{head}<div class=stage><div class='grid one'><div class=tile data-participant-id='spaces/a/devices/1'><video id=me class='flip mirror' autoplay muted playsinline></video><span class=name>You</span></div></div></div>{bar}"
    if case == "one-wrapped":
        return f"{head}<div class=stage><div class='grid one turn mirror'><div class=tile data-participant-id='spaces/a/devices/1'><video id=me autoplay muted playsinline></video><span class=name>You</span></div></div></div>{bar}"
    if case == "bare":
        return f"{head}<div class=stage><div class=box><video id=me class='flip mirror' autoplay muted playsinline></video></div></div>{bar}"
    if case == "bare-controls":
        return f"{head}<div class=stage><div class=box><video id=me class='flip mirror' autoplay muted playsinline></video>{bar}</div></div>"
    if case == "plain-controls":
        return f"{head}<div class=stage><div class=box><video id=me autoplay muted playsinline></video>{bar}</div></div>"
    if case == "bare-wrapped":
        return f"{head}<div class=stage><div class=box><div class='fill flip mirror'><video id=me autoplay muted playsinline></video></div></div></div>{bar}"
    if case == "bare-above":
        return f"{head}<div class='stage flip mirror'><div class=box><video id=me autoplay muted playsinline></video></div></div>{bar}"
    if case in ("lone", "lone-wrapped", "lone-canvas", "lone-scale"):
        extra = BAR.replace("__EXTRA__", "<button>Share screen</button>")
        video = {"lone": "<video id=me class='flip mirror' autoplay muted playsinline></video>",
                 "lone-wrapped": "<div class='fill turn mirror'><video id=me autoplay muted playsinline></video></div>",
                 "lone-scale": "<video id=me class='scaled mirror' autoplay muted playsinline></video>",
                 "lone-canvas": "<canvas id=me class='fill flip mirror' width=640 height=360></canvas>"}[case]
        return f"{head}<div class=stage><div class=box>{video}</div></div>{extra}"
    if case == "share":
        wrap = ""
        return (f"{head}<div class=stage><div class=strip><div class=tile data-participant-id='spaces/a/devices/1'><video id=me class='flip mirror' autoplay muted playsinline></video>"
                f"<span class=name>You</span></div>{faces(2)}</div><div class='main{wrap}'><div class=share data-participant-id='spaces/a/devices/presentation'>"
                f"<video id=shared autoplay muted playsinline></video><span class=name>Ana (Presentation)</span></div></div></div>{bar}")
    return "<p>idle</p>"


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path.strip("/") == "call":
            html = PAGE.replace("__BODY__", body(q.get("case", "")))
        else:
            html = "<!doctype html><title>idle</title><p>idle</p>"
        data = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H

CASES = [
    ("grid", "case=grid", "grid"),
    ("one", "case=one", "grid"),
    ("one-wrapped", "case=one-wrapped", "grid"),
    ("bare", "case=bare", "grid"),
    ("bare-controls", "case=bare-controls", "grid"),
    ("plain-controls", "case=plain-controls", "grid"),
    ("bare-wrapped", "case=bare-wrapped", "grid"),
    ("bare-above", "case=bare-above", "grid"),
    ("lone", "case=lone", "screen"),
    ("lone-wrapped", "case=lone-wrapped", "screen"),
    ("lone-canvas", "case=lone-canvas", "screen"),
    ("lone-scale", "case=lone-scale", "screen"),
    ("share", "case=share", "screen"),
]
ROOM = {"top": 8, "side": 8, "bottom": 58}


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
        if path.exists():
            return True
        BLIND.append(True)
        print("   note  the screen cannot be recorded now, so the call's page is drawn off the screen")
    drawn = path.with_name(path.stem + "-drawn.png")
    drawn.unlink(missing_ok=True)
    try:
        call("draw", str(drawn.resolve()))
    except RuntimeError as error:
        print("  ", str(error)[-300:])
    return drawn.exists()


def inside(name, page, sel):
    x0, y0, x1, y1, width, height = json.loads(sv.ev(page, f"box({sel!r})"))
    k = width / (call().get("width") or 340)
    left, top, right, bottom = ROOM["side"] * k, ROOM["top"] * k, width - ROOM["side"] * k, height - ROOM["bottom"] * k
    ok = x0 >= left - 1 and y0 >= top - 1 and x1 <= right + 1 and y1 <= bottom + 1 and x1 - x0 > 20 and y1 - y0 > 20
    t.ok(f"{name}: the picture is inside the room above the bar", ok, (x0, y0, x1, y1, left, top, right, bottom))


def case(name, query, mode, idle, out, tag):
    page = sv.page(f"call?{query}")
    sv.cmd({"do": "select", "id": page})
    t.ok(f"{name}: the call starts", until(lambda: sv.ev(page, "window.state") == "started"), sv.ev(page, "window.state"))
    time.sleep(0.5)
    tab = sv.ev(page, "facing('#me')")
    want = sv.ev(page, "document.querySelector('.mirror') ? -1 : 1")
    t.ok(f"{name}: in the tab the camera faces as the page sets it", tab == want, (want, tab))
    shown_tab = sv.ev(page, "facing('#shared')") if name.startswith("share") else None
    sv.cmd({"do": "select", "id": idle})
    t.ok(f"{name}: leaving the tab floats it", until(lambda: call()["showing"]), call())
    time.sleep(2.5)
    took = "screen" if sv.ev(page, "document.querySelectorAll('[data-broadway-tiles-screen]').length") else \
        "grid" if sv.ev(page, "document.querySelectorAll('[data-broadway-tiles-grid]').length") else "none"
    print(f"   {name}: the float took the {took} path; the mirrored element is marked {sv.ev(page, 'marks(\".mirror\")')}")
    t.ok(f"{name}: the float takes the {mode} path", took == mode, took)
    if name.startswith("share"):
        t.ok(f"{name}: the shared screen is never mirrored", sv.ev(page, "facing('#shared')") == 1, (shown_tab, sv.ev(page, "facing('#shared')")))
        t.ok(f"{name}: the shared screen shows", sv.ev(page, "seen('#shared')") == "shown")
        inside(name, page, "#shared")
    else:
        now = sv.ev(page, "facing('#me')")
        t.ok(f"{name}: the float shows the camera facing as the tab does", now == tab, (tab, now))
        t.ok(f"{name}: the camera shows", sv.ev(page, "seen('#me')") == "shown")
        inside(name, page, "#me")
        if took == "grid":
            first = sv.ev(page, "(document.getElementById('broadway-call-fit') || {}).textContent || ''")
            time.sleep(1)
            again = sv.ev(page, "(document.getElementById('broadway-call-fit') || {}).textContent || ''")
            t.ok(f"{name}: the fit settles", first == again and first != "", (first, again))
    first = sv.ev(page, "frames('#me')")
    t.ok(f"{name}: the camera is live", until(lambda: sv.ev(page, "frames('#me')") > first, within=3), (first, sv.ev(page, "frames('#me')")))
    t.ok(f"{name}: shot", shoot(out / f"{name}-{tag}.png"))
    call("return")
    until(lambda: not call()["showing"])
    t.ok(f"{name}: landing gives the camera back its own facing", until(lambda: sv.ev(page, "facing('#me')") == tab, within=3), sv.ev(page, "facing('#me')"))
    t.ok(f"{name}: landing leaves no marks", until(lambda: sv.ev(page, "document.querySelectorAll('[data-broadway-tiles-grid],[data-broadway-tiles-path],"
         "[data-broadway-tiles-screen],[data-broadway-tiles-flip],#broadway-call-tiles,#broadway-call-fit').length") == 0, within=3))
    sv.ev(page, "end(), 1")
    sv.cmd({"do": "select", "id": idle})
    time.sleep(1)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--only=")), None)
    tag = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tag=")), "after")
    out = Path(args[0] if args else ".context/call-mirror")
    out.mkdir(parents=True, exist_ok=True)
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    launch_shown()
    try:
        idle = sv.page("idle")
        for name, query, mode in CASES:
            if only and name not in only:
                continue
            case(name, query, mode, idle, out, tag)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

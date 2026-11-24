#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv
import visual_diff as vd

sv.use("page-call-people")
t = sv.T()

PAGE = r"""<!doctype html><title>Stand-up - Meet</title><style>
html, body { margin: 0; height: 100%; background: #202124; color: #e8eaed; font: 14px system-ui; overflow: hidden; }
.app { position: absolute; inset: 0; display: flex; flex-direction: column; background: #202124; }
header { height: 48px; flex: none; display: flex; align-items: center; padding: 0 16px; }
main { flex: 1; position: relative; min-height: 0; background: #2a2b2e; }
.wrap { position: absolute; }
.person { position: absolute; inset: 0; border-radius: 10px; overflow: hidden; background: #3c4043; }
.crop, .person > video, .person > canvas { position: absolute; inset: 0; }
.crop video { width: 100%; height: 100%; }
.person video, .person canvas { width: 100%; height: 100%; object-fit: cover; }
.person video.fit { object-fit: contain; }
.person.flow { position: relative; inset: auto; }
.person.flow > video { position: static; display: block; width: 100%; height: auto; }
.name { position: absolute; left: 10px; bottom: 8px; font-weight: 500; text-shadow: 0 1px 2px #000; }
.hover { position: absolute; right: 6px; top: 6px; display: flex; gap: 4px; }
.hover button, .share { border: 0; border-radius: 14px; background: #0008; color: #fff; height: 28px; min-width: 28px; font: 12px system-ui; }
.icon { font-family: system-ui; }
.stray { position: absolute; z-index: 5; border: 0; border-radius: 16px; background: #3c4043; color: #fff; padding: 6px 10px; }
.stray.one { left: 24px; top: 24px; }
.stray.two { right: 24px; top: 24px; }
.bar { height: 80px; flex: none; display: flex; align-items: center; justify-content: center; gap: 10px; }
.bar button { border: 0; border-radius: 20px; background: #3c4043; color: #e8eaed; height: 40px; min-width: 40px; }
.bar .leave { background: #ea4335; width: 56px; }
</style>
<div class=app>
  <header role=banner>Stand-up</header>
  <main></main>
  <div class=bar>
    <button aria-label="Turn on microphone" data-is-muted=true><i class=icon aria-hidden=true>mic_off</i></button>
    <button aria-label="Turn off camera" data-is-muted=false><i class=icon aria-hidden=true>videocam</i></button>
    <button aria-label="Share screen"><i class=icon aria-hidden=true>present_to_all</i></button>
    <button class=leave aria-label="Leave call" onclick="end()"><i class=icon aria-hidden=true>call_end</i></button>
  </div>
</div>
<script>
const Q = new URLSearchParams(location.search);
const N = +(Q.get('n') || 6), BARE = Q.get('bare') === '1', ROI = Q.get('roi') !== '0', RES = (Q.get('res') || '1280x720');
const CONTAIN = +(Q.get('contain') ?? -1), OWN = Q.get('own') === '1', WORD = Q.get('word') || '', PRES = Q.get('pres') || '';
const AT = +(Q.get('at') ?? 2), FLOW = Q.get('flow') === '1', OTHERS = Q.get('others') === '1';
const NAMES = ['Nadia Brooks', 'Oscar Lindqvist', 'Pia Sorensen', 'Tomas Ferro', 'Sam Rowe', 'Gil Navarro', 'Hana Ito', 'Ivo Brandt'];
const COLOURS = ['#1e8e3e', '#a142f4', '#e37400', '#1a73e8', '#d93025', '#12b5cb', '#f538a0', '#5f6368'];
const main = document.querySelector('main');
let MODE = Q.get('layout') || 'grid', FORCED = null;
const canvases = {};
function paint(c, tick) {
  const g = c.getContext('2d'), w = c.width, h = c.height;
  if (c.everyone) {
    g.fillStyle = '#202124'; g.fillRect(0, 0, w, h);
    const cw = (w - 32) / 3, ch = (h - 24) / 2;
    for (let i = 0; i < N; i++) {
      const x = 8 + (i % 3) * (cw + 8), y = 8 + Math.floor(i / 3) * (ch + 8);
      g.fillStyle = COLOURS[i % 8]; g.fillRect(x, y, cw, ch);
      g.fillStyle = '#fff'; g.font = '600 28px system-ui'; g.fillText(NAMES[i % 8], x + 16, y + ch - 20);
    }
  } else {
    g.fillStyle = c.colour; g.fillRect(0, 0, w, h);
    g.fillStyle = '#fff'; g.beginPath(); g.arc(w / 2, h / 2, Math.min(w, h) / 5, 0, 7); g.fill();
  }
  g.fillStyle = '#000'; g.fillRect(0, 0, 60, 20); g.fillStyle = '#fff'; g.font = '12px system-ui'; g.fillText(String(tick), 4, 14);
}
function source(res, colour) {
  const key = res;
  if (!canvases[key]) {
    const [w, h] = res.split('x').map(Number);
    const c = document.createElement('canvas'); c.width = w; c.height = h; c.colour = colour;
    paint(c, 0);
    canvases[key] = { canvas: c, stream: c.captureStream(5) };
  }
  return canvases[key].stream;
}
let tick = 0;
setInterval(() => { tick++; Object.values(canvases).forEach(s => paint(s.canvas, tick)); }, 500);
function video(stream, fit) {
  const v = document.createElement('video'); v.autoplay = true; v.muted = true; v.playsInline = true; v.className = 'cam' + (fit ? ' fit' : '');
  if (stream) v.srcObject = stream;
  v.play().catch(() => {});
  return v;
}
function person(i, kind) {
  const name = kind === 'pres' ? 'Nadia Brooks' : NAMES[i % 8];
  const wrap = document.createElement('div'); wrap.className = 'wrap';
  const el = document.createElement('div'); el.className = 'person' + (FLOW && kind === 'pres' ? ' flow' : ''); wrap.appendChild(el);
  const id = kind === 'pres' ? (PRES === 'label' ? 'presentation' : '99') : String(i + 1);
  if (!BARE) {
    el.setAttribute('data-participant-id', 'spaces/standup/devices/' + id);
    el.setAttribute('data-requested-participant-id', 'spaces/standup/devices/' + id);
    el.setAttribute('data-tile-media-id', 'media-' + id);
  }
  if (WORD === 'shared') el.setAttribute('data-allow-presentation', 'true');
  if ((WORD === 'data' || WORD === 'both') && i === AT) el.setAttribute('data-screen-share-tile', '');
  let shown;
  if (kind === 'pres') {
    shown = video(source(PRES === 'label' ? '1280x800' : '1920x1080', '#f4f1ea'), true);
    shown.className += ' screen';
  } else {
    const stream = OWN && i === 0 ? window.stream : source(RES, COLOURS[i % 8]);
    shown = video(stream, i === CONTAIN);
    if (OWN && i === 0) shown.classList.add('own');
  }
  if (ROI && !BARE && kind !== 'pres') {
    const crop = document.createElement('div'); crop.setAttribute('data-layout', 'roi-crop'); crop.className = 'crop';
    crop.appendChild(shown); el.appendChild(crop);
  } else el.appendChild(shown);
  const spare = video(null, false); spare.className = 'spare'; spare.style.display = 'none'; el.appendChild(spare);
  const label = document.createElement('div'); label.className = 'name';
  label.textContent = kind === 'pres' && PRES === 'label' ? name + ' (Presentation)' : name; el.appendChild(label);
  const hover = document.createElement('div'); hover.className = 'hover';
  const keys = BARE ? [['More options', 'more_horiz']] : [['Pin ' + name + ' to your main screen', 'keep'], ['Mute ' + name + "'s microphone", 'mic_off'], ['More options for ' + name, 'more_vert']];
  keys.forEach(([aria, face]) => {
    const b = document.createElement('button'); b.setAttribute('aria-label', aria);
    const f = document.createElement('i'); f.className = 'google-symbols'; f.textContent = face; b.appendChild(f);
    hover.appendChild(b);
  });
  if ((WORD === 'button' && i === AT) || (WORD === 'both' && i === AT + 2)) {
    const b = document.createElement('button'); b.className = 'share';
    b.innerHTML = '<span class=face>screen_share</span> Share screen <span>cancel_presentation</span>';
    hover.appendChild(b);
  }
  el.appendChild(hover);
  return wrap;
}
function overflow(i) {
  const wrap = document.createElement('div'); wrap.className = 'wrap';
  const el = document.createElement('div'); el.className = 'person'; el.setAttribute('role', 'button');
  el.setAttribute('aria-label', BARE ? NAMES[i % 8] : 'Show 3 more people');
  el.innerHTML = '<div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:40px;color:#fff">'
    + (BARE ? NAMES[i % 8][0] : '+3') + '</div><div class=name>' + (BARE ? NAMES[i % 8] : '3 others') + '</div>';
  wrap.appendChild(el);
  return wrap;
}
function stray() {
  const one = document.createElement('button'); one.className = 'stray one';
  one.setAttribute('aria-label', 'Others might see more of your background. Click to view your full video.'); one.textContent = 'Your background';
  const two = document.createElement('button'); two.className = 'stray two';
  two.setAttribute('aria-label', 'Gemini uses meeting conversations to answer questions'); two.innerHTML = '<i class=google-symbols>pen_spark</i>';
  main.appendChild(one); main.appendChild(two);
}
function build() {
  main.innerHTML = '';
  if (Q.get('canvas') === '1') {
    const wrap = document.createElement('div'); wrap.className = 'wrap all';
    const c = document.createElement('canvas'); c.width = 1280; c.height = 720; c.everyone = true; c.className = 'person';
    c.style.cssText = 'position:absolute;inset:0;width:100%;height:100%';
    canvases.all = { canvas: c, stream: null }; paint(c, 0);
    wrap.appendChild(c); main.appendChild(wrap);
  } else {
    if (PRES) main.appendChild(person(0, 'pres'));
    for (let i = 0; i < N; i++) main.appendChild(OTHERS && i === N - 1 ? overflow(i) : person(i, 'cam'));
  }
  stray();
  lay();
}
function want() {
  if (FORCED) return FORCED;
  if (MODE === 'auto') return innerWidth < 1000 || innerHeight < 700 ? 'speaker' : 'grid';
  return MODE === 'present' ? 'speaker' : MODE;
}
let shape = want();
function lay() {
  const wraps = [...main.querySelectorAll('.wrap')];
  const W = main.clientWidth, H = main.clientHeight, gap = 8;
  const set = (el, l, t, w, h) => { el.style.cssText = 'left:' + l + 'px;top:' + t + 'px;width:' + w + 'px;height:' + (el.querySelector('.flow') ? 'auto' : h + 'px'); };
  if (shape === 'speaker' && wraps.length > 1) {
    const strip = 90, sw = 160;
    set(wraps[0], gap, gap, W - 2 * gap, H - strip - 3 * gap);
    const rest = wraps.slice(1), left = (W - rest.length * sw - (rest.length - 1) * gap) / 2;
    rest.forEach((el, i) => set(el, left + i * (sw + gap), H - strip - gap, sw, strip));
  } else {
    const n = wraps.length;
    let best = null;
    for (let cols = 1; cols <= n; cols++) {
      const rows = Math.ceil(n / cols);
      const w = Math.min((W - gap * (cols + 1)) / cols, ((H - gap * (rows + 1)) / rows) * 16 / 9);
      if (!best || w > best.w) best = {cols, rows, w};
    }
    const w = best.w, h = w * 9 / 16, top = (H - (best.rows * h + (best.rows - 1) * gap)) / 2;
    wraps.forEach((el, i) => {
      const row = Math.floor(i / best.cols), inRow = Math.min(best.cols, n - row * best.cols);
      set(el, (W - (inRow * w + (inRow - 1) * gap)) / 2 + (i % best.cols) * (w + gap), top + row * (h + gap), w, h);
    });
  }
  window.mode = shape;
}
addEventListener('resize', () => {
  lay();
  setTimeout(() => { const next = want(); if (next !== shape) { shape = next; lay(); } }, 600);
});
window.even = () => { FORCED = 'grid'; shape = 'grid'; lay(); return 1; };
window.big = () => { FORCED = 'speaker'; shape = 'speaker'; lay(); return 1; };
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => {
  window.stream = s; window.state = 'started'; build();
}).catch(e => { window.state = 'error ' + e.name; });
window.end = () => { stream.getTracks().forEach(x => x.stop()); };
window.loop = async () => {
  const a = new RTCPeerConnection(), b = new RTCPeerConnection();
  const got = new Promise(r => { b.ontrack = e => r(e.track); });
  const s = source('640x360', '#123456');
  a.addTrack(s.getVideoTracks()[0], s);
  const o = await a.createOffer(); await a.setLocalDescription(o); await b.setRemoteDescription(o);
  const an = await b.createAnswer(); await b.setLocalDescription(an); await a.setRemoteDescription(an);
  const t = await got;
  window.remote = JSON.stringify(t.getSettings());
  return 1;
};
window.tracks = () => JSON.stringify({canvas: source(RES, COLOURS[0]).getVideoTracks()[0].getSettings(), camera: window.stream.getVideoTracks()[0].getSettings(), remote: window.remote || null});
function visible(el) {
  const r = el.getBoundingClientRect();
  return getComputedStyle(el).visibility === 'visible' && r.width >= 1 && r.height >= 1;
}
window.people = () => JSON.stringify([...document.querySelectorAll('.person')].map(el => {
  const r = el.getBoundingClientRect(), v = el.querySelector('video.cam') || el;
  return [r.left, r.top, r.right, r.bottom, visible(el) && visible(v) ? 1 : 0];
}).concat([[innerWidth, innerHeight, 0, 0, 0]]));
window.buttons = () => JSON.stringify([...document.querySelectorAll('button')].filter(visible).map(b => b.getAttribute('aria-label') || b.textContent));
window.why = () => JSON.stringify([...document.querySelectorAll('.stray')].map(b => { const r = b.getBoundingClientRect();
  return [Math.round(r.width), Math.round(r.height), b.hasAttribute('data-broadway-tiles-chrome'), getComputedStyle(b).visibility]; })
  .concat([[...document.querySelectorAll('.person')].map(p => { const r = p.getBoundingClientRect(); return [Math.round(r.width), Math.round(r.height)]; })]));
window.marks = () => { const r = document.documentElement, s = document.querySelector('[data-broadway-tiles-screen]');
  return JSON.stringify({mode: r.getAttribute('data-broadway-tiles'), found: r.getAttribute('data-broadway-tiles-found'),
    screen: s ? s.getAttribute('data-broadway-tiles-screen') : null, which: s ? (s.className || s.tagName) : null,
    grid: document.querySelectorAll('[data-broadway-tiles-grid]').length, layout: window.mode, size: [innerWidth, innerHeight]}); };
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        html = PAGE if url.path.strip("/") == "call" else "<!doctype html><title>idle</title><p>idle</p>"
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H

SMALL = (900, 640)
NORMAL = (1180, 780)
TILED = [
    ("grid", "", 6, False),
    ("lift-speaker", "layout=auto&contain=0", 6, True),
    ("speaker-contain", "layout=speaker&contain=0", 6, False),
    ("grid-contain", "contain=3", 6, False),
    ("grid-words", "word=both", 6, False),
    ("own-large", "layout=speaker&own=1&contain=0", 6, False),
    ("own-large-plain", "layout=speaker&own=1&contain=0&roi=0", 6, False),
    ("plain-lift-speaker", "layout=auto&contain=0&roi=0", 6, True),
    ("plain-lift-hd", "layout=auto&contain=0&roi=0&res=1920x1080", 6, True),
    ("plain-speaker-word", "layout=speaker&roi=0&word=shared", 6, False),
    ("plain-speaker-button", "layout=speaker&roi=0&word=button&at=0", 6, False),
    ("bare-grid", "bare=1", 6, False),
    ("bare-speaker", "bare=1&layout=speaker&contain=0", 6, False),
    ("canvas", "canvas=1", 1, False),
    ("grid-others", "others=1", (5, 6), False),
    ("bare-avatar", "bare=1&others=1", (5, 6), False),
]
SHOWN = [
    ("present-label", "pres=label&layout=present", "label"),
    ("present-guess", "pres=plain&layout=present", "guess"),
    ("present-flow", "pres=label&layout=present&flow=1", "label"),
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
QUIET = []


def shoot(path):
    if QUIET:
        return True
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
    except (RuntimeError, OSError) as error:
        print("  ", str(error)[-300:])
    return drawn.exists()


def marks(page):
    return json.loads(sv.ev(page, "marks()"))


def watch(page, seconds):
    seen = []
    end = time.time() + seconds
    while time.time() < end:
        seen.append(marks(page))
        time.sleep(0.25)
    return seen


def tiled(name, page, people):
    found_count, people = people if isinstance(people, tuple) else (people, people)
    m = marks(page)
    t.ok(f"{name}: the float is in tiles mode", m["mode"] == "" and m["screen"] is None and m["grid"] == 1, m)
    t.ok(f"{name}: it says it found {found_count}", m["found"] == str(found_count), m)
    found = json.loads(sv.ev(page, "people()"))
    width, height = found.pop()[:2]
    k = width / (call().get("width") or FLOAT_WIDTH)
    left, top = ROOM["side"] * k, ROOM["top"] * k
    right, bottom = width - ROOM["side"] * k, height - ROOM["bottom"] * k
    shown = [b for b in found if b[4]]
    t.ok(f"{name}: everyone shows", len(found) == people and len(shown) == people, found)
    inside = all(b[0] >= left - 1 and b[1] >= top - 1 and b[2] <= right + 1 and b[3] <= bottom + 1 for b in found)
    t.ok(f"{name}: everyone is inside the room above the bar", inside, (left, top, right, bottom, found))
    buttons = json.loads(sv.ev(page, "buttons()"))
    t.ok(f"{name}: no button of the page shows", buttons == [], (buttons, sv.ev(page, "why()")))


def clean(name, page):
    gone = "document.querySelectorAll('[data-broadway-tiles-grid],[data-broadway-tiles-path],[data-broadway-tiles-chrome]," \
        "[data-broadway-tiles-screen],#broadway-call-tiles,#broadway-call-fit').length"
    t.ok(f"{name}: landing leaves no marks", until(lambda: sv.ev(page, gone) == 0, within=3), sv.ev(page, gone))
    m = marks(page)
    t.ok(f"{name}: landing takes the mode and the count off the page", m["mode"] is None and m["found"] is None, m)


def settle():
    if call()["showing"]:
        call("return")
    until(lambda: not call()["showing"], within=8)


def start(name, query, idle):
    settle()
    page = sv.page(f"call?{query}")
    sv.cmd({"do": "select", "id": page})
    t.ok(f"{name}: the call starts", until(lambda: sv.ev(page, "window.state") == "started"), sv.ev(page, "window.state"))
    time.sleep(1.5)
    return page


def lift(name, page, idle):
    left = time.time()
    sv.cmd({"do": "select", "id": idle})
    t.ok(f"{name}: leaving the tab floats it", until(lambda: call()["showing"] and call()["tab"].startswith(page), within=6), call())
    return left


def land(name, page, idle):
    call("return")
    until(lambda: not call()["showing"])
    clean(name, page)
    sv.ev(page, "end(), 1")
    sv.cmd({"do": "select", "id": idle})
    time.sleep(1)


def measure(idle):
    page = start("tracks", "n=1", idle)
    sv.ev(page, "loop().catch(e => { window.remote = JSON.stringify({error: String(e)}); }), 1")
    until(lambda: sv.ev(page, "window.remote || ''") != "", within=6)
    found = json.loads(sv.ev(page, "tracks()"))
    print("   tracks", json.dumps(found))
    t.ok("tracks: another person's canvas stream carries no deviceId", not found["canvas"].get("deviceId"), found["canvas"])
    t.ok("tracks: the page's own camera carries a deviceId", bool(found["camera"].get("deviceId")), found["camera"])
    remote = json.loads(found["remote"]) if found["remote"] else None
    print("   note  a remote WebRTC track's settings:", remote)
    sv.ev(page, "end(), 1")
    time.sleep(2)
    sv.cmd({"do": "select", "id": idle})
    time.sleep(1)
    settle()


def tiles_case(name, query, people, small, idle, out, tag):
    if small:
        sv.cmd({"do": "resize", "width": SMALL[0], "height": SMALL[1], "steps": 1})
        time.sleep(0.5)
    page = start(name, query, idle)
    if small:
        t.ok(f"{name}: in the small tab the page shows one speaker and a strip", marks(page)["layout"] == "speaker", marks(page))
    lift(name, page, idle)
    seen = watch(page, 4)
    alone = [m for m in seen if m["mode"] == "screen" or m["screen"]]
    t.ok(f"{name}: nobody is shown alone at any moment after the lift", not alone, alone[:1])
    if small:
        t.ok(f"{name}: the page has gone over to its even grid", marks(page)["layout"] == "grid", marks(page))
    t.ok(f"{name}: shot", shoot(out / f"{name}.png"))
    tiled(f"{name}, 4 s after the lift", page, people)
    state = call()
    wide = round((FLOAT_WIDTH + state.get("largest", FLOAT_WIDTH * 2)) / 2)
    call("size", str(wide))
    seen = watch(page, 3)
    alone = [m for m in seen if m["mode"] == "screen" or m["screen"]]
    t.ok(f"{name}: nobody is shown alone after the float is resized", not alone, alone[:1])
    tiled(f"{name}, after a resize", page, people)
    t.ok(f"{name}: shot resized", shoot(out / f"{name}-resized.png"))
    call("edge")
    land(name, page, idle)
    if small:
        sv.cmd({"do": "resize", "width": NORMAL[0], "height": NORMAL[1], "steps": 1})
        time.sleep(0.5)


def screen_case(name, query, why, idle, out, tag):
    page = start(name, query, idle)
    lifted = lift(name, page, idle)
    first = None
    end = time.time() + 7
    while time.time() < end:
        m = marks(page)
        if m["mode"] == "screen":
            first = time.time() - lifted
            break
        time.sleep(0.1)
    t.ok(f"{name}: the presentation is shown alone", first is not None, marks(page))
    if first is None:
        land(name, page, idle)
        return
    t.ok(f"{name}: not on first sight but after holding for 2 s", first >= 1.8, round(first, 2))
    time.sleep(1)
    m = marks(page)
    t.ok(f"{name}: the screen mark says why: {why}", m["screen"] == why and "screen" in (m["which"] or ""), m)
    t.ok(f"{name}: no count is written in screen mode", m["found"] is None, m)
    t.ok(f"{name}: shot", shoot(out / f"{name}.png"))
    if "flow=1" in query:
        back = until(lambda: marks(page)["mode"] == "", within=7)
        t.ok(f"{name}: a tile sized by its picture collapses once the picture is lifted out, so the float goes back to tiles", back, marks(page))
        seen = watch(page, 6)
        modes = {m["mode"] for m in seen}
        t.ok(f"{name}: and it settles there without flipping", modes == {""}, [m["mode"] for m in seen])
        if back:
            tiled(f"{name}, settled in tiles", page, 7)
            t.ok(f"{name}: shot settled", shoot(out / f"{name}-settled.png"))
    elif why == "label":
        sv.ev(page, "even()")
        back = until(lambda: marks(page)["mode"] == "", within=6)
        t.ok(f"{name}: once the presentation is one tile among equals, the float goes back to tiles", back, marks(page))
        if back:
            time.sleep(1.5)
            tiled(f"{name}, back in tiles", page, 7)
            t.ok(f"{name}: shot back in tiles", shoot(out / f"{name}-even.png"))
        sv.ev(page, "big()")
        seen = watch(page, 5)
        again = [m for m in seen if m["mode"] == "screen"]
        t.ok(f"{name}: a dropped presentation does not come back in this float", not again, again[:1])
    land(name, page, idle)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--only=")), None)
    tag = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tag=")), "after")
    out = Path(args[0] if args else ".context/call-people") / tag
    out.mkdir(parents=True, exist_ok=True)
    if "--no-shots" in sys.argv:
        QUIET.append(True)
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    launch_shown()
    try:
        idle = sv.page("idle")
        sv.cmd({"do": "resize", "width": NORMAL[0], "height": NORMAL[1], "steps": 1})
        if not only or "tracks" in only:
            measure(idle)
        for name, query, people, small in TILED:
            if only and name not in only:
                continue
            tiles_case(name, query, people, small, idle, out, tag)
        for name, query, why in SHOWN:
            if only and name not in only:
                continue
            screen_case(name, query, why, idle, out, tag)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

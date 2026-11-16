#!/usr/bin/env python3
"""The Tempo speed badge's size, press after press, in a test copy of its own.

Build first (`./build.sh`), then `python3 Tests/tempo_badge_size.py [label]`.
BROADWAY_PROBE_APP picks another build, for before and after. The window is put
below the desktop, where `screencapture -l` pictures it alone, and keys are
bench key events handed to the tab's view: no real input.

Local fixtures only. A YouTube-like player (`#movie_player`, its video sized
by script to the stream's own aspect) switches quality between 720p, 480p
(854×480, not quite 16:9) and 360p, shows and hides its controls, scrolls,
gets zoomed, picks up hostile page CSS, goes to theater and back; a player
under a CSS scale that animates; a near-square video whose player shifts by a
pixel; a tiny embed and a huge player; and a resize while the badge is on
screen. Every press's font size is read in Search's world (the badge's
shadow root is closed) and written to `.context/tempo-size/<label>/`, with
window shots of consecutive presses.
"""
import functools
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

sv.use("tempo-badge-size")

SHOTS = "--shots" in sys.argv
ARGS = [arg for arg in sys.argv[1:] if arg != "--shots"]
LABEL = ARGS[0] if ARGS else "now"
OUT = ROOT / ".context" / "tempo-size" / LABEL
WINDOW = [0]

STATE = """(() => {
  const badge = window.__broadwayTempoBadge ? window.__broadwayTempoBadge()
    : (document.getElementById('tempo-hud-host') || {}).shadowRoot?.getElementById('tempo-speed-overlay');
  if (!badge) return null;
  const host = badge.getRootNode().host;
  const video = document.querySelector('video');
  const b = badge.getBoundingClientRect(), v = video.getBoundingClientRect();
  return { text: badge.textContent, fontSize: parseFloat(badge.style.fontSize),
    computed: parseFloat(getComputedStyle(badge).fontSize),
    box: [+b.width.toFixed(2), +b.height.toFixed(2)], drawn: +(v.width / video.offsetWidth).toFixed(3), video: [+v.width.toFixed(2), +v.height.toFixed(2)],
    inVideo: b.left >= v.left - 0.5 && b.right <= v.right + 0.5 && b.top >= v.top - 0.5 && b.bottom <= v.bottom + 0.5,
    shown: getComputedStyle(host).opacity, open: !!host.shadowRoot };
})()"""

WATCH = """(() => {
  const badge = window.__broadwayTempoBadge ? window.__broadwayTempoBadge()
    : (document.getElementById('tempo-hud-host') || {}).shadowRoot?.getElementById('tempo-speed-overlay');
  window.__sizeLog = [];
  if (window.__sizeWatch) window.__sizeWatch.disconnect();
  window.__sizeWatch = new MutationObserver(() => window.__sizeLog.push(
    { text: badge.textContent, fontSize: parseFloat(badge.style.fontSize) }));
  window.__sizeWatch.observe(badge, { attributes: true, childList: true, subtree: true, characterData: true });
  return true;
})()"""

TUBE = """<!doctype html><meta charset=utf-8><title>tube</title>
<style>
html { font-size: 10px; } body { margin: 0; background: #0f0f0f; color: #eee; font: 1.4rem/2rem Roboto, Arial, sans-serif; height: 3000px; }
#columns { padding: 24px 0 0 24px; }
#scaler { transform-origin: 0 0; }
#movie_player { position: relative; overflow: hidden; background: #000; font-size: 11px; line-height: 1.3; width: var(--pw); height: var(--ph); }
.html5-video-container { position: relative; z-index: 10; }
.html5-main-video { position: absolute; display: block; }
.ytp-chrome-bottom { position: absolute; left: 12px; right: 12px; bottom: 0; height: 48px; z-index: 59; background: linear-gradient(transparent, #0009); transition: opacity .25s; }
.ytp-autohide .ytp-chrome-bottom { opacity: 0; }
.hostile #movie_player > div:not(.html5-video-container) { font-size: 40px !important; line-height: 3 !important; letter-spacing: 6px !important; zoom: 1.3 !important; padding: 9px !important; transform: scale(1.2) !important; }
.hostile * { font-variant-numeric: slashed-zero !important; -webkit-text-stroke: 2px red; text-transform: uppercase; }
</style>
<div id=columns><div id=scaler><div id=movie_player class="html5-video-player ytp-autohide">
<div class=html5-video-container><video class="video-stream html5-main-video" muted loop playsinline></video></div>
<div class=ytp-chrome-bottom></div></div></div></div>
<script>
const q = new URLSearchParams(location.search);
const player = document.getElementById('movie_player'), video = player.querySelector('video');
window.fit = () => {
  const pw = player.clientWidth, ph = player.clientHeight;
  const a = (video.videoWidth || 16) / (video.videoHeight || 9);
  let w = pw, h = pw / a; if (h > ph) { h = ph; w = ph * a; }
  Object.assign(video.style, { width: w + 'px', height: h + 'px', left: (pw - w) / 2 + 'px', top: (ph - h) / 2 + 'px' });
  return [w, h];
};
window.size = (w, h, now) => {
  player.style.setProperty('--pw', w + 'px'); player.style.setProperty('--ph', h + 'px');
  if (now !== false) fit();
  return true;
};
window.quality = (name) => new Promise((done) => {
  const at = video.currentTime, playing = !video.paused, rate = video.playbackRate;
  video.addEventListener('loadedmetadata', () => { video.currentTime = at; fit(); video.playbackRate = rate;
    if (playing) video.play(); done([video.videoWidth, video.videoHeight]); }, { once: true });
  video.src = name + '.mp4';
});
size(q.get('w') || 853.33, q.get('h') || 480);
video.addEventListener('loadedmetadata', fit);
video.src = (q.get('src') || 'q720') + '.mp4';
video.play();
</script>"""


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {"app": sv.APP, "cases": {}}
    t = sv.T()
    with tempfile.TemporaryDirectory(prefix="broadway-tempo-size-") as folder:
        root = Path(folder)
        for name, size in [("q720", "1280x720"), ("q480", "854x480"), ("q360", "640x360"),
                           ("square", "570x600")]:
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                            f"testsrc2=size={size}:rate=24", "-t", "90", "-c:v", "libx264",
                            "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(root / f"{name}.mp4")], check=True)
        (root / "tube.html").write_text(TUBE)
        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=folder))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            sv.setup(**{"float.leave": False})
            sv.launch()
            sv.cmd({"do": "window"})
            WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "size": [1500, 1000]})["window"]
            time.sleep(1)

            def open_page(query):
                tab = sv.sp("open", url=f"{base}/tube.html?{query}")["resultID"]
                sv.cmd({"do": "select", "id": tab})
                sv.cmd({"do": "wait", "id": tab, "seconds": 10})
                time.sleep(2)
                return tab

            def ev(tab, js, world=None):
                ask = {"do": "eval", "id": tab, "js": js}
                if world:
                    ask["world"] = world
                return sv.cmd(ask).get("value")

            def run(case, tab, steps):
                rows = []
                for index, (label, group, action) in enumerate(steps, 1):
                    if action:
                        action(tab)
                    if label.startswith("hold"):
                        ev(tab, WATCH, "search")
                        sv.cmd({"do": "key", "id": tab, "text": label[-1], "hold": 1.4})
                        time.sleep(0.3)
                        log = ev(tab, "window.__sizeLog", "search") or []
                        state = ev(tab, STATE, "search") or {}
                        rows.append({"press": index, "key": label, "group": group, "ticks": log,
                                     "fontSize": state.get("fontSize"), "video": state.get("video"),
                                     "inVideo": state.get("inVideo")})
                    else:
                        key, _, wait = label.partition(":")
                        sv.cmd({"do": "key", "id": tab, "text": key})
                        time.sleep(0.25)
                        state = ev(tab, STATE, "search") or {}
                        rows.append({"press": index, "key": key, "group": group, **state})
                        time.sleep(float(wait) if wait else 1.3)
                    row = rows[-1]
                    print(f"{case} #{row['press']:>2} {row['key']:<6} {group:<10} "
                          f"font {row.get('fontSize')} box {row.get('box')} video {row.get('video')}"
                          + (f" ticks {[r['fontSize'] for r in row['ticks']]}" if "ticks" in row else ""))
                report["cases"][case] = rows
                return rows

            def same_by_group(case, rows):
                groups = {}
                for row in rows:
                    sizes = [row.get("fontSize")] + [tick["fontSize"] for tick in row.get("ticks", [])]
                    groups.setdefault(row["group"], set()).update(s for s in sizes if s is not None)
                for group, sizes in groups.items():
                    t.ok(f"{case}: one size for the {group} player", len(sizes) == 1, sorted(sizes))
                return groups

            def shot(name, tab):
                ev(tab, "(() => { const b = window.__broadwayTempoBadge ? window.__broadwayTempoBadge() : document.getElementById('tempo-hud-host').shadowRoot.getElementById('tempo-speed-overlay'); "
                        "const h = b.getRootNode().host; h.style.setProperty('transition', 'none', 'important'); "
                        "h.style.setProperty('opacity', '1', 'important'); return 1; })()", "search")
                taken = Path(folder) / f"{name}.png"
                sv.cmd({"do": "shot", "id": tab, "path": str(taken)})
                path = OUT / f"{name}.png"
                path.write_bytes(taken.read_bytes())
                return path

            js = lambda code: (lambda tab: ev(tab, code))
            wait = lambda seconds: (lambda tab: time.sleep(seconds))
            def quality(name):
                return lambda tab: (ev(tab, f"quality('{name}'), 1"), time.sleep(0.8))

            tab = open_page("w=853.33&h=480")
            steps = [] if SHOTS else [
                ("f", "default", None),
                ("f", "default", None),
                ("s", "default", None),
                ("f", "default", js("document.getElementById('movie_player').classList.remove('ytp-autohide'), 1")),
                ("s", "default", js("document.getElementById('movie_player').classList.add('ytp-autohide'), 1")),
                ("f", "default", quality("q480")),
                ("f", "default", None),
                ("s", "default", quality("q360")),
                ("s", "default", None),
                ("d", "default", quality("q720")),
                ("f", "default", js("scrollTo(0, 37.5), 1")),
                ("f", "default", js("scrollTo(0, 0), 1")),
                ("s", "default", js("document.querySelector('video').pause(), 1")),
                ("s", "default", None),
                ("holdf", "default", None),
                ("d", "default", None),
                ("f", "default", js("document.body.classList.add('hostile'), 1")),
                ("f", "default", None),
                ("s", "default", js("document.body.classList.remove('hostile'), 1")),
                ("s", "default", lambda tab: sv.cmd({"do": "magnify", "id": tab, "zoom": 1.25})),
                ("f", "default", lambda tab: sv.cmd({"do": "magnify", "id": tab, "zoom": 1.0})),
                ("f", "default", js("document.querySelector('video').play(), 1")),
                ("holds", "default", None),
                ("d", "default", None),
                ("f", "theater", js("size(1280, 720), 1")),
                ("f", "theater", None),
                ("f", "theater", quality("q480")),
                ("s", "theater", None),
                ("s", "default2", js("size(853.33, 480), 1")),
                ("s", "default2", None),
            ]
            tube = run("tube", tab, steps) if steps else []
            if SHOTS:
                ev(tab, "document.querySelector('video').pause(), 1")
                time.sleep(1.5)
                for n, key in enumerate(["f", "f", "s", "s"], 1):
                    sv.cmd({"do": "key", "id": tab, "text": key})
                    time.sleep(0.3)
                    shot(f"tube-press-{n}", tab)
                    time.sleep(1.3)
                ev(tab, "quality('q480'), 1")
                time.sleep(1)
                sv.cmd({"do": "key", "id": tab, "text": "f"})
                time.sleep(0.3)
                shot("tube-press-5-480p", tab)
                return 0
            groups = same_by_group("tube", tube)
            default = groups.get("default", set()) | groups.get("default2", set())
            t.ok("tube: back from theater, the same size as before", len(default) == 1, sorted(default))
            t.ok("tube: theater fits its own, larger size",
                 bool(groups.get("theater")) and bool(default) and min(groups["theater"]) > max(default),
                 groups)
            t.ok("tube: the badge stays inside the video", all(r.get("inVideo", True) for r in tube),
                 [r["press"] for r in tube if not r.get("inVideo", True)])
            t.ok("tube: the badge's shadow root is closed to the page",
                 ev(tab, "(document.getElementById('tempo-hud-host') || {}).shadowRoot === null") is True,
                 ev(tab, "String((document.getElementById('tempo-hud-host') || {}).shadowRoot)"))

            ev(tab, "document.querySelector('video').pause(), 1")
            time.sleep(1.5)
            for n, key in enumerate(["f", "f", "s", "s"], 1):
                sv.cmd({"do": "key", "id": tab, "text": key})
                time.sleep(0.25)
                shot(f"tube-press-{n}", tab)
                time.sleep(1.3)
            ev(tab, "quality('q480'), 1")
            time.sleep(1)
            sv.cmd({"do": "key", "id": tab, "text": "f"})
            time.sleep(0.25)
            shot("tube-press-5-480p", tab)
            time.sleep(1.3)
            sv.sp("close", id=tab)

            firsts = []
            for n in range(4):
                tab = open_page("w=853.33&h=480")
                rows = run(f"first-{n + 1}", tab, [("f", "default", None), ("f", "default", None), ("s", "default", None)])
                firsts.append([row.get("fontSize") for row in rows])
                sv.sp("close", id=tab)
            flat = {size for row in firsts for size in row}
            t.ok("a new page's first press has the size of the ones after it", len(flat) == 1, firsts)

            tab = open_page("w=853.33&h=480")
            scale = lambda s: js(f"document.getElementById('scaler').style.transform = 'scale({s})', 1")
            rows = run("scaled", tab, [
                ("f", "player", None),
                ("f", "player", scale(0.5)),
                ("f", "player", None),
                ("s", "player", scale(0.8)),
                ("s", "player", None),
                ("f", "player", scale(1)),
                ("f", "player", None),
            ])
            same_by_group("scaled", rows)
            sv.sp("close", id=tab)

            tab = open_page("w=571.5&h=600&src=square")
            jitter = lambda w: js(f"size({w}, 600), 1")
            rows = run("square", tab, [
                ("f", "player", None), ("f", "player", jitter(572.5)), ("s", "player", jitter(571.5)),
                ("s", "player", jitter(572.5)), ("f", "player", jitter(571.5)), ("f", "player", None),
            ])
            same_by_group("square", rows)
            sv.sp("close", id=tab)

            for name, (w, h) in {"tiny": (213.33, 120), "huge": (2400, 1350)}.items():
                tab = open_page(f"w={w}&h={h}")
                rows = run(name, tab, [("f", "player", None), ("f", "player", None), ("s", "player", None),
                                       ("d", "player", None)])
                same_by_group(name, rows)
                sizes = [row.get("fontSize") or 0 for row in rows]
                t.ok(f"{name}: the badge is between a fifth and half the player's height",
                     all(h * 0.2 <= s <= h * 0.5 + 0.01 for s in sizes), sizes)
                t.ok(f"{name}: and inside the video", all(row.get("inVideo") for row in rows),
                     [row.get("inVideo") for row in rows])
                sv.sp("close", id=tab)

            tab = open_page("w=853.33&h=480")
            rows = run("resize", tab, [
                ("f", "small", None),
                ("f:0.15", "small", None),
                ("f", "small-shown", js("size(1280, 720), 1")),
                ("f", "large", None),
                ("f", "large", None),
            ])
            t.ok("resize: a press while the badge is on screen keeps its size",
                 rows[2].get("fontSize") == rows[1].get("fontSize"), [r.get("fontSize") for r in rows])
            t.ok("resize: the next press after it hides fits the new player",
                 (rows[3].get("fontSize") or 0) > (rows[1].get("fontSize") or 0)
                 and rows[3].get("fontSize") == rows[4].get("fontSize"), [r.get("fontSize") for r in rows])
            sv.sp("close", id=tab)
        finally:
            t.done()
            sv.finish()
            server.shutdown()
    (OUT / "presses.json").write_text(json.dumps(report, indent=2))
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

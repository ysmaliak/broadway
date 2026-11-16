#!/usr/bin/env python3
"""The mini player's clock and speed against a page that behaves like a
streaming web player, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/mini_clock.py`. Local pages
only, served here, every sound one step above silence at volume 0.01. The
song page has a 285-second main track, Media Session metadata and handlers
(play, pause, previous, next, a seek that lands 0.4 s late, the way a
player that fetches does), and a six-second silent loop it plays while
paused, in one of three places: in the document, as a new Audio() no frame
can see, or in a frame. It reports its position through the Media Session
always, never, or only while playing. The talk page is three hours long by
its reported position and puts any speed back to 1x after 1.2 s.

What has to hold: the card's time, total and line are one reading of the
main track, whichever element plays while it is paused; the times the card
says (its accessibility value, the tooltip's last line) and the drawn line
agree; a seek shows its target at once and never snaps back;
a song offers no speed; a speed the page puts back is shown put back within
a second, is no longer offered for that page and is not kept for the site.
With BROADWAY_APP=path the probe runs against another build (main's, to see
it fail).
"""
import os
import re
import struct
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-mini-clock")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
t = sv.T()
SONG = 285
ONLY = os.environ.get("MINI_CLOCK_ONLY", "")


def wav(seconds, rate=8000, quiet=False):
    step = b"\x00\x00" * 18 if quiet else (struct.pack("<h", -1) * 9 + struct.pack("<h", 1) * 9)
    count = seconds * rate * 2
    frames = (step * (count // len(step) + 1))[:count]
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return head + b"data" + struct.pack("<I", len(frames)) + frames


def png(size=600, colour=(64, 120, 214)):
    raw = b"".join(b"\x00" + bytes(colour) * size for _ in range(size))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


LONG = wav(SONG)
KEEP = wav(6, quiet=True)
TALKWAV = wav(120)
ART = png()

SONGPAGE = """<!doctype html><title>Listen to A Singer | Player</title><p>song</p>
<audio id=main src=/long.wav></audio><div id=place></div><script>
var q = new URLSearchParams(location.search), where = q.get('keep') || 'doc', report = q.get('report') || 'none';
var main = document.getElementById('main'); main.volume = 0.01; window.log = [];
var keep = null;
if (where === 'doc') { keep = document.createElement('audio'); keep.src = '/keep.wav'; keep.loop = true; document.getElementById('place').appendChild(keep); }
if (where === 'loose') { keep = new Audio('/keep.wav'); keep.loop = true; }
if (where === 'frame') { var f = document.createElement('iframe'); f.src = '/keepframe'; f.style.width = '10px'; f.style.height = '10px'; document.getElementById('place').appendChild(f); }
function keepGo(on) {
  if (where === 'frame') { var w = document.querySelector('iframe').contentWindow; if (w && w.go) w.go(on); return; }
  if (!keep) return;
  if (on) { var p = keep.play(); if (p && p.catch) p.catch(function () {}); } else keep.pause();
}
function place() {
  if (report === 'always' || (report === 'playing' && !main.paused)) {
    navigator.mediaSession.setPositionState({ duration: main.duration || %d, position: main.currentTime, playbackRate: main.playbackRate });
  } else if (report === 'playing') {
    navigator.mediaSession.setPositionState();
  }
}
navigator.mediaSession.metadata = new MediaMetadata({ title: 'Born To Fly', artist: 'A Singer', album: 'An Album',
  artwork: [{ src: '/art.png', sizes: '600x600', type: 'image/png' }] });
window.start = function () { keepGo(false); var p = main.play(); if (p && p.catch) p.catch(function () {}); return 1; };
navigator.mediaSession.setActionHandler('play', function () { log.push('play'); start(); });
navigator.mediaSession.setActionHandler('pause', function () { log.push('pause'); main.pause(); keepGo(true); });
navigator.mediaSession.setActionHandler('previoustrack', function () { log.push('previous'); });
navigator.mediaSession.setActionHandler('nexttrack', function () { log.push('next'); });
navigator.mediaSession.setActionHandler('seekto', function (d) {
  log.push('to:' + Math.round(d.seekTime));
  setTimeout(function () { main.currentTime = d.seekTime; }, 400);
});
['play', 'pause', 'seeked', 'ratechange', 'loadedmetadata'].forEach(function (type) { main.addEventListener(type, place); });
main.addEventListener('ratechange', function () {
  if (main.playbackRate !== 1) setTimeout(function () { main.playbackRate = 1; }, 1200);
});
</script>""" % SONG

KEEPFRAME = """<!doctype html><title>keep</title><audio id=k src=/keep.wav loop></audio><script>
var k = document.getElementById('k');
window.go = function (on) { if (on) { var p = k.play(); if (p && p.catch) p.catch(function () {}); } else k.pause(); };
</script>"""

TALK = """<!doctype html><title>A Talk</title><p>talk</p><audio id=t src=/talk.wav></audio><script>
var a = document.getElementById('t'); a.volume = 0.01; window.log = []; window.pos = 1200; window.since = 0;
function now() { return a.paused ? pos : pos + (performance.now() - since) / 1000 * a.playbackRate; }
function place() { navigator.mediaSession.setPositionState({ duration: 10800, position: now(), playbackRate: a.playbackRate }); }
navigator.mediaSession.metadata = new MediaMetadata({ title: 'A Talk About Time', artist: 'A Speaker' });
navigator.mediaSession.setActionHandler('play', function () { log.push('play'); since = performance.now(); a.play(); place(); });
navigator.mediaSession.setActionHandler('pause', function () { pos = now(); log.push('pause'); a.pause(); place(); });
navigator.mediaSession.setActionHandler('seekto', function (d) { pos = d.seekTime; since = performance.now(); place(); });
a.addEventListener('ratechange', function () {
  pos = now(); since = performance.now(); place();
  if (a.playbackRate !== 1) setTimeout(function () { a.playbackRate = 1; }, 1200);
});
window.start = function () { since = performance.now(); var p = a.play(); if (p && p.catch) p.catch(function () {}); place(); return 1; };
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        pages = {"/song": SONGPAGE, "/keepframe": KEEPFRAME, "/talk": TALK}
        if path in pages:
            return self.send(pages[path].encode(), "text/html")
        files = {"/long.wav": (LONG, "audio/wav"), "/keep.wav": (KEEP, "audio/wav"), "/talk.wav": (TALKWAV, "audio/wav"),
                 "/art.png": (ART, "image/png")}
        if path in files:
            return self.send(*files[path])
        return self.send(b"<!doctype html><title>Other page</title><p>other</p>", "text/html")

    def send(self, body, kind):
        total = len(body)
        wanted = self.headers.get("Range")
        if wanted and wanted.startswith("bytes="):
            first, _, last = wanted[6:].partition("-")
            start = int(first or 0)
            end = min(int(last) if last else total - 1, total - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            body = body[start:end + 1]
        else:
            self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


def mini(action="state", *values):
    return sv.cmd({"do": "mini", "action": action, "values": [str(v) for v in values]})


def shown():
    return mini().get("shown") or {}


def view():
    return mini().get("view") or {}


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    try:
        return bool(check())
    except Exception:
        return False


def seconds(text):
    found = re.findall(r"(\d+):(\d\d)", text or "")
    return [int(m) * 60 + int(s) for m, s in found]


def drawn():
    v = view()
    said = seconds(v.get("value") or "")
    elapsed, total = said[0] if said else None, said[1] if len(said) > 1 else None
    return {"elapsed": elapsed, "total": total, "words": v.get("value") or "", "line": v.get("line")}


def main_time(tab):
    return sv.ev(tab, "main.currentTime") or 0


def opened(base, path):
    tab = sv.cmd({"do": "open", "url": f"{base}/{path}"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 10})
    return tab


def one_clock(base, other, keep, report):
    name = f"{keep}/{report}"
    song = opened(base, f"song?keep={keep}&report={report}")
    sv.cmd({"do": "select", "id": song})
    time.sleep(0.4)
    sv.ev(song, "main.currentTime = 100, start()")
    t.ok(f"[{name}] the song plays", until(lambda: sv.ev(song, "main.paused") is False))
    sv.cmd({"do": "select", "id": other})
    t.ok(f"[{name}] the card shows it", until(lambda: shown().get("title") == "Born To Fly"), mini())
    mini("hover")
    time.sleep(1.2)
    item = shown()
    t.ok(f"[{name}] playing, the total is the song's", abs(item.get("duration", 0) - SONG) < 2, item)

    mini("toggle")
    t.ok(f"[{name}] pause reaches the page", until(lambda: sv.ev(song, "main.paused") is True))
    held = main_time(song)
    time.sleep(2.5)
    item = shown()
    t.ok(f"[{name}] paused, with a short loop playing, the total is still the song's", abs(item.get("duration", 0) - SONG) < 2, item)
    t.ok(f"[{name}] paused, the time is the song's", abs(item.get("time", -99) - held) < 1.5, (item, held))
    t.ok(f"[{name}] paused, the card says paused", item.get("playing") is False, item)
    d = drawn()
    t.ok(f"[{name}] the drawn time is the song's", d["elapsed"] is not None and abs(d["elapsed"] - held) <= 1.5, (d, held))
    t.ok(f"[{name}] the total it says is the song's, and it never says what is left", d["total"] is not None
         and abs(d["total"] - SONG) <= 2 and "left" not in d["words"], d)
    t.ok(f"[{name}] the line is drawn from the same reading", d["line"] is not None and abs(d["line"] * SONG - held) <= 3, (d, held))
    line = d["line"]
    time.sleep(1.2)
    t.ok(f"[{name}] paused, the line holds still", drawn()["line"] is not None and line is not None and abs(drawn()["line"] - line) < 0.004,
         (line, drawn()))

    mini("toggle")
    t.ok(f"[{name}] play reaches the page", until(lambda: sv.ev(song, "main.paused") is False))
    time.sleep(2.2)
    samples = []
    for _ in range(6):
        d, truth = drawn(), main_time(song)
        samples.append((d["elapsed"], d["line"], round(truth, 2)))
        time.sleep(0.35)
    agree = all(e is not None and ln is not None and abs(e - tr) <= 1.5 and abs(ln * SONG - tr) <= 2.5 for e, ln, tr in samples)
    t.ok(f"[{name}] playing again, text and line follow the song together", agree, samples)

    before = main_time(song)
    target = 200
    mini("seek", target / SONG)
    seen = []
    end = time.time() + 2.2
    while time.time() < end:
        seen.append((round(time.time() - end + 2.2, 2), shown().get("time", -1), drawn()["elapsed"]))
        time.sleep(0.08)
    early = [s for s in seen if s[0] <= 0.35]
    t.ok(f"[{name}] a seek shows its target at once", early and all(abs(s[1] - target) < 2.5 for s in early), (before, seen[:6]))
    t.ok(f"[{name}] and never snaps back to the old place", all(abs(s[1] - target) < 4 for s in seen), seen)
    t.ok(f"[{name}] the seek went through the page's handler", until(lambda: "to:200" in (sv.ev(song, "log.join()") or "")), sv.ev(song, "log.join()"))
    t.ok(f"[{name}] a song offers no speed", shown().get("speed") is False, shown())
    t.ok(f"[{name}] nor a Speed item in the menu", not any(m.startswith("Speed") for m in mini("menu").get("menu", [])), mini("menu"))
    mini("hover", "off")
    sv.ev(song, "main.pause(), 1")
    sv.cmd({"do": "close", "id": song})
    until(lambda: not mini().get("items"), 4)


def speed(base, other):
    talk = opened(base, "talk")
    sv.cmd({"do": "select", "id": talk})
    time.sleep(0.4)
    sv.ev(talk, "start()")
    sv.cmd({"do": "select", "id": other})
    t.ok("[talk] the card shows it", until(lambda: shown().get("title") == "A Talk About Time"), mini())
    t.ok("[talk] long audio is offered speed", until(lambda: shown().get("speed") is True, 3), shown())
    mini("speed", 2)
    t.ok("[talk] the page plays at 2x", until(lambda: sv.ev(talk, "a.playbackRate") == 2, 3), sv.ev(talk, "a.playbackRate"))
    t.ok("[talk] the card says 2x", until(lambda: shown().get("rate") == 2, 2), shown())
    t.ok("[talk] the page puts it back", until(lambda: sv.ev(talk, "a.playbackRate") == 1, 4))
    back = time.time()
    t.ok("[talk] the card goes back with it within a second", until(lambda: shown().get("rate") == 1, 1.2), (time.time() - back, shown()))
    t.ok("[talk] and speed is not offered again for this page", until(lambda: shown().get("speed") is False, 2), shown())
    t.ok("[talk] nor in the menu", not any(m.startswith("Speed") for m in mini("menu").get("menu", [])), mini("menu"))
    speeds = sv.cmd({"do": "settings"}).get("speeds", {})
    t.ok("[talk] the refused speed is not kept for the site", speeds.get("127.0.0.1") in (None, 1, 1.0), speeds)
    sv.cmd({"do": "go", "id": talk, "url": f"{base}/talk?again"})
    time.sleep(1.5)
    sv.ev(talk, "start()")
    t.ok("[talk] another page load offers it again", until(lambda: shown().get("speed") is True, 6), shown())
    t.ok("[talk] and opens at 1x", sv.ev(talk, "a.playbackRate") == 1, sv.ev(talk, "a.playbackRate"))
    sv.ev(talk, "a.pause(), 1")
    sv.cmd({"do": "close", "id": talk})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    sv.setup()
    sv.launch()
    try:
        sv.cmd({"do": "agents", "action": "stage", "dark": False, "size": [1100, 640]})
        other = opened(base, "other")
        cases = [("doc", "playing"), ("loose", "none"), ("frame", "none"), ("doc", "always")]
        for keep, report in cases:
            if ONLY and ONLY not in (keep, f"{keep}/{report}", "clock"):
                continue
            one_clock(base, other, keep, report)
        if not ONLY or ONLY == "speed":
            speed(base, other)
    finally:
        sv.quit()
        sv.finish()
        server.shutdown()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

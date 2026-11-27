#!/usr/bin/env python3
"""The sidebar's mini player, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/mini_player.py [OUT]`. Local
pages only, served here: a music page with a Media Session and track
handlers, an audiobook with only seek handlers and a three-hour position
state, a bare <audio>, a new Audio() no frame can see, and a <video> with a
picture. Their tone is one step above silence. Each button has to reach the
page (asserted in the page), the progress has to move and seek, speed has to
change and be kept for the site, the settings have to change what is shown,
the player has to follow a switch of space and go when its tab closes, and
the video has to float instead. With MINI_PICTURES=1, pictures and a short
film of the probe's own window by its id, below the desktop, into OUT
(default .context/mini-player).
"""
import io
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-mini")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/mini-player")
PICTURES = os.environ.get("MINI_PICTURES") == "1"
t = sv.T()
WINDOW = [0]
CLIP = Path(os.environ.get("TMPDIR", "/tmp")) / f"mini-player-{os.getpid()}.mp4"


def wav(seconds=150, rate=8000):
    count = seconds * rate
    frames = bytearray(count * 2)
    for i in range(count):
        struct.pack_into("<h", frames, i * 2, 1 if (i // 9) % 2 else -1)
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return head + b"data" + struct.pack("<I", len(frames)) + bytes(frames)


def png(size=96, colour=(214, 120, 64)):
    raw = b"".join(b"\x00" + bytes(colour) * size for _ in range(size))
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


TONE = wav()
DING = wav(1)
CHIME = wav(2)
HALF = wav(30)
ART = png()

MUSIC = """<!doctype html><title>Music page</title><p>music</p><audio id=t src=/tone.wav></audio><script>
var a = document.getElementById('t'); window.log = [];
navigator.mediaSession.metadata = new MediaMetadata({ title: 'Bohemian Rhapsody (Remastered 2011)', artist: 'A Band', album: 'An Album',
  artwork: [{ src: '/art.png', sizes: '96x96', type: 'image/png' }] });
navigator.mediaSession.setActionHandler('play', function () { log.push('play'); a.play(); });
navigator.mediaSession.setActionHandler('pause', function () { log.push('pause'); a.pause(); });
navigator.mediaSession.setActionHandler('previoustrack', function () { log.push('previous'); });
navigator.mediaSession.setActionHandler('nexttrack', function () { log.push('next'); });
</script>"""

BOOK = """<!doctype html><title>Book page</title><p>book</p><audio id=t src=/tone.wav></audio><script>
var a = document.getElementById('t'); window.log = []; window.pos = 3600;
function place() { navigator.mediaSession.setPositionState({ duration: 10800, position: pos, playbackRate: a.playbackRate || 1 }); }
navigator.mediaSession.metadata = new MediaMetadata({ title: 'Chapter 7: The Long Way Round', artist: 'A Reader' });
navigator.mediaSession.setActionHandler('play', function () { log.push('play'); a.play(); place(); });
navigator.mediaSession.setActionHandler('pause', function () { log.push('pause'); a.pause(); place(); });
navigator.mediaSession.setActionHandler('seekbackward', function (d) { log.push('back:' + d.seekOffset); pos -= d.seekOffset; place(); });
navigator.mediaSession.setActionHandler('seekforward', function (d) { log.push('forward:' + d.seekOffset); pos += d.seekOffset; place(); });
navigator.mediaSession.setActionHandler('seekto', function (d) { log.push('to:' + Math.round(d.seekTime)); pos = d.seekTime; place(); });
place();
</script>"""

PLAIN = """<!doctype html><title>Plain page</title><p>plain</p><audio id=t src=/tone.wav></audio>"""

LOOSE = """<!doctype html><title>Loose page</title><p>loose</p><script>window.a = new Audio('/tone.wav'); a.loop = true;</script>"""

DINGPAGE = """<!doctype html><title>Ding page</title><p>ding</p><audio id=t src=/ding.wav></audio>"""

SYNTH = """<!doctype html><title>Synth page</title><p>synth</p><script>
window.go = function () { window.c = new AudioContext(); var o = c.createOscillator(), g = c.createGain();
  g.gain.value = 0.0001; o.connect(g); g.connect(c.destination); o.start(); return c.state; };
</script>"""

CHIMEPAGE = """<!doctype html><title>Chime page</title><p>chime</p><audio id=t src=/chime.wav></audio>
<button id=b onclick="document.getElementById('t').play()">Ring</button>"""

WEBCHIME = """<!doctype html><title>Web chime page</title><p>web chime</p><script>
window.go = function () { window.c = new AudioContext(); var b = c.createBuffer(1, c.sampleRate * 2, c.sampleRate), d = b.getChannelData(0);
  for (var i = 0; i < d.length; i++) d[i] = (Math.floor(i / 9) % 2 ? 1 : -1) * 0.0001;
  var s = c.createBufferSource(); s.buffer = b; s.connect(c.destination); s.onended = function () { window.done = true; }; s.start(); return c.state; };
</script>"""

HALFPAGE = """<!doctype html><title>Half page</title><p>half a minute</p><audio id=t src=/half.wav></audio>"""

LATECHIME = """<!doctype html><title>Late chime page</title><p>late chime</p><audio id=t></audio><script>
window.go = function () { var a = document.getElementById('t'); a.src = '/slowchime.wav?' + Date.now();
  var p = a.play(); if (p && p.catch) p.catch(function () {}); return String(a.duration); };
</script>"""

CALL = """<!doctype html><title>Call page</title><p>call</p><audio id=s></audio><audio id=t src=/chime.wav></audio><script>
window.go = function () { window.c = new AudioContext(); window.o = c.createOscillator(); var g = c.createGain(), d = c.createMediaStreamDestination();
  g.gain.value = 0.0001; o.connect(g); g.connect(d); o.start(); var s = document.getElementById('s'); s.srcObject = d.stream;
  var p = s.play(); if (p && p.catch) p.catch(function () {}); return String(s.duration); };
window.leave = function () { var p = document.getElementById('t').play(); if (p && p.catch) p.catch(function () {});
  setTimeout(function () { var s = document.getElementById('s'); s.pause(); s.srcObject = null; s.remove(); o.stop(); }, 300); return 1; };
window.hangup = function () { var p = document.getElementById('t').play(); if (p && p.catch) p.catch(function () {});
  setTimeout(function () { document.getElementById('s').pause(); o.stop(); }, 300); return 1; };
</script>"""

VIDEO = """<!doctype html><title>Video page</title><body style="margin:0;background:#000">
<video id=t src=/clip.mp4 loop playsinline style="width:800px;height:450px;display:block"></video></body>"""

SLOWVIDEO = """<!doctype html><title>Slow video page</title><body style="margin:0;background:#000">
<video id=t loop playsinline style="width:800px;height:450px;display:block"></video><script>
window.go = function () { var v = document.getElementById('t'); v.volume = 0.01; v.src = '/slow.mp4?' + Date.now();
  var p = v.play(); if (p && p.catch) p.catch(function () {}); return v.readyState; };
</script></body>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        pages = {"/abc-defg-hij": CALL, "/music": MUSIC, "/book": BOOK, "/plain": PLAIN, "/loose": LOOSE, "/video": VIDEO, "/ding": DINGPAGE, "/synth": SYNTH, "/slowvideo": SLOWVIDEO,
                 "/chime": CHIMEPAGE, "/webchime": WEBCHIME, "/half": HALFPAGE, "/latechime": LATECHIME, "/call": CALL}
        if path in pages:
            return self.send(pages[path].encode(), "text/html")
        if path == "/tone.wav":
            return self.send(TONE, "audio/wav")
        if path == "/ding.wav":
            return self.send(DING, "audio/wav")
        if path == "/chime.wav":
            return self.send(CHIME, "audio/wav")
        if path == "/slowchime.wav":
            time.sleep(2.5)
            return self.send(CHIME, "audio/wav")
        if path == "/half.wav":
            return self.send(HALF, "audio/wav")
        if path == "/art.png":
            return self.send(ART, "image/png")
        if path == "/clip.mp4" and CLIP.exists():
            return self.send(CLIP.read_bytes(), "video/mp4")
        if path == "/slow.mp4" and CLIP.exists():
            time.sleep(2.5)
            return self.send(CLIP.read_bytes(), "video/mp4")
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


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    try:
        return bool(check())
    except Exception:
        return False


def log(tab):
    return sv.ev(tab, "log.join()") or ""


def short(tab):
    return tab[:8].lower()


def setting(key, value):
    return sv.cmd({"do": "settings", "set": key, "value": value})


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [1100, 640]})["window"]
    time.sleep(0.8)


def shoot(name):
    if not PICTURES:
        return None
    path = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    return path if path.exists() else None


def pictures(name):
    if not PICTURES:
        return
    for dark in (False, True):
        stage(dark)
        shoot(f"{name}-{'dark' if dark else 'light'}")
    stage(False)


def film(name, act, frames=24):
    if not PICTURES:
        act()
        return
    folder = OUT / f"{name}-frames"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    thread = threading.Thread(target=act)
    thread.start()
    for index in range(frames):
        subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(folder / f"{index:03d}.png")], capture_output=True)
    thread.join()
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "8", "-i", str(folder / "%03d.png"),
                        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")])


def make_clip():
    if not shutil.which("ffmpeg"):
        return False
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-af", "volume=0.0005", "-t", "90",
                    "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", str(CLIP)],
                   capture_output=True)
    return CLIP.exists()


def noisy(tab):
    return any(x.get("noisy") for x in sv.cmd({"do": "small", "action": "sound"}).get("tabs", []) if x.get("id") == short(tab))


def carded(tab, title):
    state = mini()
    return short(tab) in (state.get("roles") or {}) or any(i.get("title") == title for i in state.get("items") or [])


def watch_card(tab, title, done, after=4, within=12):
    seen, heard, end, finished = [], False, time.time() + within, None
    while time.time() < end:
        if carded(tab, title):
            seen.append(round(within - (end - time.time()), 1))
        heard = heard or noisy(tab)
        if finished is None and done():
            finished = time.time()
        if finished is not None and time.time() - finished >= after:
            break
        time.sleep(0.15)
    return seen, heard, finished is not None


def short_sounds(base, other):
    sv.cmd({"do": "select", "id": other})
    chime = opened(base, "chime")
    sv.cmd({"do": "select", "id": other})
    time.sleep(0.4)
    sv.ev(chime, "document.getElementById('b').click(), 1")
    seen, heard, ended = watch_card(chime, "Chime page", lambda: sv.ev(chime, "document.getElementById('t').ended") is True)
    t.ok("a two-second chime played once on a click ends", ended, sv.ev(chime, "var e = document.getElementById('t'); [e.duration, e.currentTime, e.ended].join()"))
    t.ok("and never brings the card up, playing or ended", not seen, (seen, heard, mini()))
    sv.cmd({"do": "close", "id": chime})

    web = opened(base, "webchime")
    sv.cmd({"do": "select", "id": web})
    time.sleep(0.4)
    state = sv.ev(web, "go()")
    sv.cmd({"do": "select", "id": other})
    seen, heard, ended = watch_card(web, "Web chime page", lambda: sv.ev(web, "window.done === true"))
    t.ok("the same chime through Web Audio ends", ended, (state, ended))
    if heard:
        t.ok("and with no element to play or pause, never brings the card up", not seen, (seen, mini()))
    else:
        print("  skip  Web Audio chime: the tab never counted as making sound here", state, seen)
    sv.cmd({"do": "close", "id": web})

    late = opened(base, "latechime")
    sv.cmd({"do": "select", "id": late})
    time.sleep(0.4)
    first = sv.ev(late, "go()")
    sv.cmd({"do": "select", "id": other})
    seen, heard, ended = watch_card(late, "Late chime page", lambda: sv.ev(late, "document.getElementById('t').ended") is True, within=16)
    t.ok("a chime whose length is unknown at first", first == "NaN", first)
    t.ok("turns out two seconds long and ends", ended and abs((sv.ev(late, "document.getElementById('t').duration") or 0) - 2) < 0.1,
         sv.ev(late, "var e = document.getElementById('t'); [e.duration, e.ended].join()"))
    t.ok("and never brings the card up", not seen, (seen, heard, mini()))
    sv.cmd({"do": "close", "id": late})

    call = opened(base, "call")
    sv.cmd({"do": "select", "id": call})
    time.sleep(0.4)
    live = sv.ev(call, "go()")
    sv.cmd({"do": "select", "id": other})
    t.ok("a stream with no end is treated as long and takes the card", until(lambda: mini()["roles"].get(short(call)) == "mini", 10),
         (live, mini()))
    sv.ev(call, "leave()")
    seen, heard, ended = watch_card(call, "Call page", lambda: sv.ev(call, "document.getElementById('t').ended") is True)
    t.ok("the stream gone, its leaving chime ends", ended and sv.ev(call, "!!document.getElementById('s')") is False,
         sv.ev(call, "document.getElementById('t').ended"))
    t.ok("and the card does not stay for the chime", not carded(call, "Call page"), (seen, mini()))
    sv.cmd({"do": "close", "id": call})

    call = opened(base, "call")
    sv.cmd({"do": "select", "id": call})
    time.sleep(0.4)
    sv.ev(call, "go()")
    sv.cmd({"do": "select", "id": other})
    t.ok("a call's stream takes the card again", until(lambda: mini()["roles"].get(short(call)) == "mini", 10), mini())
    sv.ev(call, "hangup()")
    seen, heard, ended = watch_card(call, "Call page", lambda: sv.ev(call, "document.getElementById('t').ended") is True)
    t.ok("hung up with its stream left in the page, paused, the chime ends", ended and sv.ev(call, "document.getElementById('s').paused") is True,
         sv.ev(call, "document.getElementById('t').ended"))
    t.ok("on a page that is no call, the paused stream keeps its card, as a paused radio does", carded(call, "Call page"), (seen, mini()))
    sv.cmd({"do": "close", "id": call})

    sv.cmd({"do": "meetalert", "action": "fixture", "hosts": {"localhost": "meet"}, "events": []})
    port = base.rsplit(":", 1)[1]
    meeting = sv.cmd({"do": "open", "url": f"http://localhost:{port}/abc-defg-hij"})["id"]
    sv.cmd({"do": "wait", "id": meeting, "seconds": 10})
    sv.cmd({"do": "select", "id": meeting})
    time.sleep(0.4)
    sv.ev(meeting, "go()")
    sv.cmd({"do": "select", "id": other})
    seen, heard, playing = watch_card(meeting, "Call page", lambda: sv.ev(meeting, "document.getElementById('s').paused") is False, after=5)
    t.ok("a meeting page's stream plays", playing, sv.ev(meeting, "document.getElementById('s').paused"))
    t.ok("and never brings the card up", not seen, (seen, heard, mini()))
    sv.ev(meeting, "hangup()")
    seen, heard, ended = watch_card(meeting, "Call page", lambda: sv.ev(meeting, "document.getElementById('t').ended") is True)
    t.ok("hung up with its stream left paused, its chime ends", ended, sv.ev(meeting, "document.getElementById('t').ended"))
    t.ok("and the card never comes", not seen, (seen, mini()))
    sv.cmd({"do": "close", "id": meeting})
    sv.cmd({"do": "meetalert", "action": "fixture", "hosts": {}, "events": []})

    half = opened(base, "half")
    sv.cmd({"do": "select", "id": half})
    time.sleep(0.4)
    sv.ev(half, "document.getElementById('t').play(), 1")
    sv.cmd({"do": "select", "id": other})
    t.ok("thirty seconds of sound still takes the card", until(lambda: shown().get("title") == "Half page" and shown().get("playing"), 10), mini())
    mini("toggle")
    t.ok("pausing it from the card pauses the page", until(lambda: sv.ev(half, "document.getElementById('t').paused") is True))
    t.ok("and the card stays, paused", until(lambda: shown().get("title") == "Half page" and not shown().get("playing")), mini())
    time.sleep(1.5)
    t.ok("still there a moment later", shown().get("title") == "Half page", mini())
    sv.ev(half, "var e = document.getElementById('t'); e.currentTime = 28; e.play(), 1")
    t.ok("played to its end", until(lambda: sv.ev(half, "document.getElementById('t').ended") is True, 8))
    time.sleep(1.5)
    t.ok("a long track that ended keeps its card, showing play", shown().get("title") == "Half page" and not shown().get("playing"), mini())
    sv.cmd({"do": "close", "id": half})
    t.ok("its tab closed, the foot is empty", until(lambda: not shown() and not mini()["items"]), mini())


def opened(base, name):
    tab = sv.cmd({"do": "open", "url": f"{base}/{name}"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 10})
    return tab


def main():
    if PICTURES:
        OUT.mkdir(parents=True, exist_ok=True)
    clip = make_clip()
    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    sv.setup()
    sv.launch()
    try:
        sv.cmd({"do": "floataway"})
        stage(False)
        other = opened(base, "other")
        short_sounds(base, other)
        if os.environ.get("MINI_ONLY") == "short":
            return
        music = opened(base, "music")
        sv.cmd({"do": "select", "id": music})
        time.sleep(0.5)
        sv.ev(music, "document.getElementById('t').play(), 1")
        t.ok("music plays in the page", until(lambda: sv.ev(music, "document.getElementById('t').paused") is False))
        t.ok("on screen, the card shows too", until(lambda: mini()["roles"].get(short(music)) == "mini")
             and until(lambda: shown().get("title") == "Bohemian Rhapsody (Remastered 2011)"), mini())
        mini("open")
        time.sleep(0.4)
        active = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("active")), {})
        t.ok("on its own tab, the artwork leaves you where you are", active.get("id") == short(music) and shown(), (active, shown()))

        sv.cmd({"do": "select", "id": other})
        t.ok("out of sight, it shows", until(lambda: shown().get("title") == "Bohemian Rhapsody (Remastered 2011)"), mini())
        item = shown()
        t.ok("its artist under it", item.get("detail") == "A Band", item)
        t.ok("music gets previous and next", item.get("pair") == "tracks" and item.get("previous") and item.get("next"), item)
        t.ok("playing", item.get("playing"), item)
        t.ok("its artwork, fetched", until(lambda: shown().get("art")), shown())
        now = sv.cmd({"do": "nowplaying", "id": music})
        t.ok("the Mac's Now Playing says the same", now.get("title") == shown().get("title") and now.get("active"), now)
        pictures("01-music")

        mini("toggle")
        t.ok("pause reaches the page's handler", until(lambda: "pause" in log(music)), log(music))
        t.ok("the page paused", until(lambda: sv.ev(music, "document.getElementById('t').paused") is True))
        t.ok("paused stays, showing play", until(lambda: shown() and not shown()["playing"]), mini())
        pictures("02-music-paused")
        mini("toggle")
        t.ok("play reaches the page", until(lambda: sv.ev(music, "document.getElementById('t').paused") is False))
        t.ok("playing again", until(lambda: shown().get("playing")), mini())
        mini("next")
        mini("previous")
        t.ok("next and previous reach the page", until(lambda: log(music).endswith("next,previous")), log(music))

        first = shown().get("time", 0)
        time.sleep(2)
        t.ok("progress moves", until(lambda: shown().get("time", 0) > first + 1), (first, shown()))
        mini("seek", 0.5)
        t.ok("a seek reaches the element", until(lambda: abs((sv.ev(music, "document.getElementById('t').currentTime") or 0) - 75) < 4),
             sv.ev(music, "document.getElementById('t').currentTime"))
        t.ok("the line follows the seek", until(lambda: abs(shown().get("time", 0) - 75) < 5), shown())
        menu = mini("menu")["menu"]
        t.ok("right-click offers the skips music hides", "Back 15 Seconds" in menu and "Hide Player" in menu, menu)
        t.ok("a song offers no speed", shown().get("speed") is False and "Speed" not in menu, (shown(), menu))

        mini("pick", "Hide Player")
        t.ok("Hide Player in its menu hides it", until(lambda: not shown()), mini())
        t.ok("and the sound plays on", sv.ev(music, "document.getElementById('t').paused") is False)
        sv.ev(music, "document.getElementById('t').pause(), 1")
        time.sleep(0.6)
        sv.ev(music, "document.getElementById('t').play(), 1")
        t.ok("it comes back when the tab starts again", until(lambda: shown().get("title") == "Bohemian Rhapsody (Remastered 2011)"), mini())

        ding = opened(base, "ding")
        sv.cmd({"do": "select", "id": other})
        time.sleep(0.4)
        sv.ev(ding, "document.getElementById('t').play(), 1")
        time.sleep(0.3)
        seen = set()
        end = time.time() + 4
        while time.time() < end:
            seen.add(shown().get("title"))
            time.sleep(0.1)
        t.ok("a one-second sound in another tab never takes the card", seen == {"Bohemian Rhapsody (Remastered 2011)"}, seen)
        sv.ev(other, "new Audio('/ding.wav').play(), 1")
        seen = set()
        end = time.time() + 4
        while time.time() < end:
            seen.add(shown().get("title"))
            time.sleep(0.1)
        t.ok("nor one in the tab in front", seen == {"Bohemian Rhapsody (Remastered 2011)"}, seen)
        sv.cmd({"do": "close", "id": ding})

        book = opened(base, "book")
        sv.cmd({"do": "select", "id": book})
        time.sleep(0.4)
        sv.ev(book, "a.play(), place(), 1")
        sv.cmd({"do": "select", "id": other})
        t.ok("the latest to play takes the player", until(lambda: shown().get("title") == "Chapter 7: The Long Way Round"), mini())
        t.ok("the other is listed", until(lambda: len(mini()["items"]) == 2), mini())
        mini("choose", short(music))
        t.ok("another can be chosen from its menu", until(lambda: shown().get("title") == "Bohemian Rhapsody (Remastered 2011)"), mini())
        mini("choose", short(book))
        t.ok("and back", until(lambda: shown().get("title") == "Chapter 7: The Long Way Round"), mini())
        item = shown()
        t.ok("long audio gets seconds", item.get("pair") == "seconds" and item.get("skip") == 15, item)
        t.ok("its position is the page's three hours", abs(item.get("duration", 0) - 10800) < 1, item)
        pictures("03-book")
        sv.ev(music, "document.getElementById('t').pause(), 1")
        t.ok("music paused before the book started is let go", until(lambda: len(mini()["items"]) == 1), mini())
        mini("toggle")
        t.ok("the book pauses through its handler", until(lambda: log(book).endswith("pause")), log(book))
        t.ok("paused, it stays", until(lambda: shown().get("title") == "Chapter 7: The Long Way Round" and not shown().get("playing")), mini())
        mini("back")
        t.ok("back 15 reaches the page as a seek to", until(lambda: log(book).endswith("to:3585")), log(book))
        mini("forward")
        t.ok("forward 15 too", until(lambda: log(book).endswith("to:3600")), log(book))
        setting("mini.skip", 30)
        t.ok("the skip setting changes the buttons", until(lambda: shown().get("skip") == 30), shown())
        mini("back")
        t.ok("and the amount sent", until(lambda: log(book).endswith("to:3570")), log(book))
        setting("mini.skip", 15)
        setting("mini.spoken", "tracks")
        t.ok("a book without tracks keeps seconds", until(lambda: shown().get("pair") == "seconds"), shown())
        setting("mini.spoken", "seconds")
        t.ok("long audio offers speed", until(lambda: shown().get("speed") is True), shown())
        mini("speed", 1.5)
        t.ok("speed changes the element", until(lambda: sv.ev(book, "a.playbackRate") == 1.5))
        t.ok("speed is kept for the site", until(lambda: sv.cmd({"do": "settings"})["speeds"].get("127.0.0.1") == 1.5),
             sv.cmd({"do": "settings"})["speeds"])
        t.ok("the player shows the speed the page plays at", until(lambda: shown().get("rate") == 1.5 and shown().get("speed")), shown())
        mini("speed", 1)
        until(lambda: shown().get("rate") == 1, 3)
        setting("mini.speed", False)
        t.ok("speed can be hidden", until(lambda: shown() and not shown().get("speed")), shown())
        setting("mini.speed", True)
        t.ok("and shown", until(lambda: shown().get("speed")), shown())
        setting("mini.on", False)
        t.ok("the player can be turned off", until(lambda: not shown() and not mini()["items"]), mini())
        hooked = "!!(window.MediaSession && MediaSession.prototype[Symbol.for('broadway.sound')]) + ',' + HTMLMediaElement.prototype.play.toString().includes('[native code]')"
        bare = opened(base, "plain")
        t.ok("off, a new page has no hook at all", sv.ev(bare, hooked) == "false,true", sv.ev(bare, hooked))
        t.ok("nor the Search-world relay", sv.cmd({"do": "eval", "id": bare, "js": "typeof window.__broadwaySound", "world": "search"}).get("value") == "undefined",
             sv.cmd({"do": "eval", "id": bare, "js": "typeof window.__broadwaySound", "world": "search"}))
        t.ok("the tab that had it, reloaded, has it no more", (sv.cmd({"do": "go", "id": book, "url": f"{base}/plain"}), time.sleep(1.5), sv.ev(book, hooked))[2] == "false,true",
             sv.ev(book, hooked))
        sv.cmd({"do": "go", "id": book, "url": f"{base}/book"})
        time.sleep(1.5)
        sv.cmd({"do": "close", "id": bare})
        setting("mini.on", True)
        sv.cmd({"do": "go", "id": book, "url": f"{base}/book"})
        time.sleep(1.5)
        t.ok("on again, the next page has the hook", sv.ev(book, hooked) == "true,false", sv.ev(book, hooked))
        sv.ev(book, "a.play(), place(), 1")
        t.ok("and on", until(lambda: shown().get("title") == "Chapter 7: The Long Way Round"), mini())
        t.ok("the book plays again", until(lambda: shown().get("playing")), mini())

        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        time.sleep(1.5)
        t.ok("it follows a switch of space", until(lambda: shown().get("title") == "Chapter 7: The Long Way Round"), mini())
        pictures("04-other-space")
        mini("open")
        time.sleep(1)
        active = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("active")), {})
        t.ok("clicked, it goes to the tab in its space", active.get("id") == short(book), active)
        t.ok("and stays at the foot while its tab is in front", shown().get("title") == "Chapter 7: The Long Way Round", mini())
        sv.cmd({"do": "select", "id": other})
        t.ok("out of sight, still at the foot", until(lambda: shown().get("title") == "Chapter 7: The Long Way Round"), mini())

        sv.cmd({"do": "close", "id": book})
        t.ok("its tab closed, the paused music comes back", until(lambda: shown().get("title") == "Bohemian Rhapsody (Remastered 2011)"), mini())
        sv.ev(music, "document.getElementById('t').play(), 1")

        plain = opened(base, "plain")
        sv.cmd({"do": "select", "id": plain})
        time.sleep(0.4)
        sv.ev(plain, "document.getElementById('t').play(), 1")
        t.ok("the bare page plays", until(lambda: (sv.ev(plain, "document.getElementById('t').currentTime") or 0) > 0.5))
        sv.cmd({"do": "select", "id": other})
        t.ok("a bare <audio> is named by its page", until(lambda: shown().get("title") == "Plain page"), mini())
        t.ok("by its site underneath", shown().get("detail") == "127.0.0.1", shown())
        t.ok("with skips", shown().get("pair") == "seconds", shown())
        mini("toggle")
        t.ok("the element itself pauses", until(lambda: sv.ev(plain, "document.getElementById('t').paused") is True))
        t.ok("the card shows it paused", until(lambda: shown() and not shown()["playing"]), mini())
        mini("forward")
        t.ok("and skips", until(lambda: (sv.ev(plain, "document.getElementById('t').currentTime") or 0) >= 14))
        mini("toggle")
        t.ok("and plays again", until(lambda: sv.ev(plain, "document.getElementById('t').paused") is False),
             (mini(), sv.ev(plain, "var e = document.getElementById('t'); [e.paused, e.currentTime, e.ended, e.muted, e.error && e.error.code].join()")))
        sv.cmd({"do": "close", "id": plain})

        loose = opened(base, "loose")
        sv.cmd({"do": "select", "id": loose})
        time.sleep(0.4)
        sv.ev(loose, "a.play(), 1")
        sv.cmd({"do": "select", "id": other})
        t.ok("a new Audio() no frame can see still shows", until(lambda: shown().get("title") == "Loose page"), mini())
        mini("toggle")
        t.ok("and pauses", until(lambda: sv.ev(loose, "a.paused") is True))
        sv.cmd({"do": "close", "id": loose})

        synth = opened(base, "synth")
        sv.cmd({"do": "select", "id": synth})
        time.sleep(0.4)
        state = sv.ev(synth, "go()")
        sv.cmd({"do": "select", "id": other})
        if until(lambda: noisy(synth), within=4):
            seen = []
            end = time.time() + 6
            while time.time() < end:
                if carded(synth, "Synth page"):
                    seen.append(round(6 - (end - time.time()), 1))
                time.sleep(0.15)
            t.ok("Web Audio with nothing to press never takes the card, however long it lasts", not seen and noisy(synth), (seen, mini()))
        else:
            print("  skip  Web Audio made no sound here", state, mini())
        sv.cmd({"do": "close", "id": synth})

        if clip:
            video = opened(base, "video")
            sv.cmd({"do": "select", "id": video})
            time.sleep(0.5)
            sv.ev(video, "document.getElementById('t').play(), 1")
            t.ok("the video plays", until(lambda: sv.ev(video, "document.getElementById('t').paused") is False))
            t.ok("a video with a picture is the float's", until(lambda: mini()["roles"].get(short(video)) == "float"), mini())
            sv.cmd({"do": "select", "id": other})
            t.ok("leaving it, it floats", until(lambda: sv.cmd({"do": "lingering"}).get("floating", "").lower().startswith(short(video))),
                 sv.cmd({"do": "lingering"}))
            t.ok("and never shows here", all(i["title"] != "Video page" for i in mini()["items"]), mini())
            sv.cmd({"do": "select", "id": video})
            time.sleep(1.5)
            sv.ev(video, "document.getElementById('t').pause(), 1")
            sv.cmd({"do": "select", "id": other})
            time.sleep(1.5)
            sv.ev(video, "document.getElementById('t').play(), 1")
            seen = []
            end = time.time() + 1.5
            while time.time() < end:
                seen += [i["title"] for i in mini()["items"]]
                time.sleep(0.05)
            t.ok("a background video resumed never flashes the card", "Video page" not in seen, seen)
            sv.cmd({"do": "close", "id": video})

            def floating_now(tab):
                return sv.cmd({"do": "lingering"}).get("floating", "").lower().startswith(short(tab))

            slow = opened(base, "slowvideo")
            sv.cmd({"do": "select", "id": slow})
            time.sleep(0.4)
            state = sv.ev(slow, "go()")
            sv.cmd({"do": "select", "id": other})
            early = floating_now(slow)
            t.ok("left before its size is known, nothing floats yet", state == 0 and not early, (state, early))
            t.ok("and it floats once the picture comes", until(lambda: floating_now(slow), 10), sv.cmd({"do": "lingering"}))
            t.ok("it never took the card on the way", all(i["title"] != "Slow video page" for i in mini()["items"]), mini())
            sv.cmd({"do": "close", "id": slow})
            until(lambda: not sv.cmd({"do": "lingering"}).get("showing"), 4)

            slow = opened(base, "slowvideo")
            sv.cmd({"do": "select", "id": slow})
            time.sleep(0.4)
            sv.ev(slow, "go()")
            pressed = sv.cmd({"do": "floataway"})
            said = sv.cmd({"do": "lingering"}).get("announced", "")
            t.ok("Shift-Command-P while it loads says why, never nothing", pressed.get("floating") is True or "loading" in said, (pressed, said))
            t.ok("and floats as soon as there is a picture", until(lambda: floating_now(slow), 10), sv.cmd({"do": "lingering"}))
            sv.cmd({"do": "close", "id": slow})
            until(lambda: not sv.cmd({"do": "lingering"}).get("showing"), 4)
        else:
            print("  skip  no ffmpeg for the video page")

        sv.cmd({"do": "select", "id": other})
        t.ok("music again at the foot", until(lambda: shown().get("title") == "Bohemian Rhapsody (Remastered 2011)"), mini())

        def view():
            return mini().get("view") or {}

        mini("hover", "off")
        time.sleep(0.4)
        rest = view()
        card, art, keys, line = rest.get("cardFrame") or [0] * 4, rest.get("artFrame") or [0] * 4, rest.get("keyFrames") or [], rest.get("lineFrame") or [0] * 4
        t.ok("the card is one row, 44 points high", card[3] == 44, card)
        t.ok("the artwork has the same space above, beside and below it",
             art[0] == art[1] == card[3] - art[1] - art[3] and 28 <= art[2] == art[3] <= 32, (art, card))
        t.ok("previous, play or pause and next sit at the right, in that order",
             len(keys) == 3 and keys[0][0] < keys[1][0] < keys[2][0] and card[2] - keys[2][0] - keys[2][2] <= 9, keys)
        t.ok("its buttons are go to, previous, pause and next: no sound key and no close",
             rest.get("buttons") == ["Bohemian Rhapsody (Remastered 2011), A Band", "Previous", "Pause", "Next"], rest.get("buttons"))
        t.ok("the second line is the artist, with no times at rest", rest.get("detail") == "A Band", rest.get("detail"))
        t.ok("progress is a thin line at the card's bottom edge, inside its corners",
             0 < line[3] <= 2 and card[3] - 4 <= line[1] and line[1] + line[3] <= card[3] and line[0] >= 8 and line[0] + line[2] <= card[2] - 8,
             (line, card))
        t.ok("the line is drawn where the song is", abs((rest.get("line") or 0) * shown().get("duration", 0) - shown().get("time", -99)) < 4,
             (rest.get("line"), shown()))
        t.ok("a long title fades at rest", rest.get("titleCut") is True and rest.get("sliding") is False, rest)
        t.ok("its tooltip is the whole title, the artist and the times",
             re.fullmatch(r"Bohemian Rhapsody \(Remastered 2011\)\nA Band\n\d+:\d\d of 2:30", rest.get("tip", "")), rest.get("tip"))
        t.ok("the card's accessibility value says the times", re.fullmatch(r"\d+:\d\d of 2:30", rest.get("value", "")), rest.get("value"))
        t.ok("Go to the site is the help, not the tooltip", rest.get("help", "").startswith("Go to ") and "Go to" not in rest.get("tip", ""), rest)
        title = rest.get("titleFrame") or [0] * 4
        t.ok("the title has everything between the artwork and the keys",
             title[0] == art[0] + art[2] + 8 and keys and keys[0][0] - 8 <= title[0] + title[2] <= keys[0][0], (title, art, keys))
        mini("hover")
        time.sleep(0.4)
        over = view()
        t.ok("hover moves nothing", over.get("frames") == rest.get("frames"),
             [k for k in (rest.get("frames") or {}) if (over.get("frames") or {}).get(k) != rest["frames"][k]])
        t.ok("and brings no close button", over.get("buttons") == rest.get("buttons"), over.get("buttons"))
        mini("linehover")
        time.sleep(0.4)
        lit = view()
        t.ok("over the line, it thickens and the second line tells the position and the total",
             lit.get("lineThick", 0) > rest.get("lineThick", 9) and re.fullmatch(r"\d+:\d\d / 2:30", lit.get("detail", "")),
             (lit.get("lineThick"), lit.get("detail")))
        t.ok("nothing else moves for it", {k: v for k, v in lit.get("frames", {}).items()} == over.get("frames"),
             [k for k in (over.get("frames") or {}) if (lit.get("frames") or {}).get(k) != over["frames"][k]])
        mini("linehover", "off")
        time.sleep(0.3)
        t.ok("off the line, the artist is back", view().get("detail") == "A Band", view().get("detail"))
        reduced = sv.cmd({"do": "eval", "id": music, "js": "matchMedia('(prefers-reduced-motion: reduce)').matches"}).get("value") is True
        if reduced:
            print("  skip  the Mac has Reduce Motion on: the title does not slide")
        else:
            t.ok("the long title slides to its end", until(lambda: view().get("sliding") is True, 2), view())
            t.ok("once, and then rests faded again", until(lambda: view().get("sliding") is False and view().get("titleCut") is True, 10), view())
            t.ok("and does not start again while the pointer stays", not until(lambda: view().get("sliding") is True, 1.5), view())
        mini("hover", "off")

        for width in (200, 140):
            sv.cmd({"do": "ui", "sideWidth": width})
            time.sleep(0.6)
            mini("hover")
            time.sleep(0.4)
            narrow = view()
            frame = narrow.get("cardFrame", [0, 0, 0, 0])
            t.ok(f"at {width} the card fits the column", frame[2] > 0 and frame[2] <= width, narrow)
            t.ok(f"at {width} play and pause is there", narrow.get("toggle") in ("play", "pause"), narrow)
            ends = [k[0] + k[2] for k in narrow.get("keyFrames") or []]
            t.ok(f"at {width} the three keys are inside the card", len(ends) == 3 and max(ends) <= frame[2] and narrow["keyFrames"][0][0] >= 0,
                 narrow.get("keyFrames"))
            words = narrow.get("titleFrame") or [0] * 4
            t.ok(f"at {width} the title ends before the keys", words[0] + words[2] <= narrow["keyFrames"][0][0], (words, narrow.get("keyFrames")))
            mini("hover", "off")
            time.sleep(0.4)
            if PICTURES and width == 200:
                pictures("12-narrowest")
        sv.cmd({"do": "ui", "sideWidth": 258})
        time.sleep(0.6)
        if PICTURES:
            stage(False)
            film("05-pause-play", lambda: (time.sleep(0.4), mini("toggle"), time.sleep(1.2), mini("toggle"), time.sleep(0.8)))
            sv.cmd({"do": "ui", "folded": True})
            time.sleep(0.8)
            pictures("06-folded")
            sv.cmd({"do": "ui", "peek": True})
            time.sleep(0.8)
            for dark in (False, True):
                stage(dark)
                sv.cmd({"do": "ui", "peek": True})
                time.sleep(0.8)
                shoot(f"07-folded-peek-{'dark' if dark else 'light'}")
            sv.cmd({"do": "ui", "peek": False})
            sv.cmd({"do": "ui", "folded": False})
            stage(False)

        sv.cmd({"do": "close", "id": music})
        t.ok("the last one closed, the foot is empty", until(lambda: not shown() and not mini()["items"]), mini())
    finally:
        sv.quit()
        sv.finish()
        server.shutdown()
        if CLIP.exists():
            CLIP.unlink()


main()
t.done()
sys.exit(1 if t.failed else 0)

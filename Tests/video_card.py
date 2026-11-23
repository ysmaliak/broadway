#!/usr/bin/env python3
"""A video with a picture never takes the sidebar's card, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/video_card.py`. A local
YouTube-like page: a two-minute video with a picture and a sound one step
above silence, a Media Session with a title, an artist and play, pause and
seek handlers, played at 1.5x. It is played and left, paused and left, left
while floating and its float closed, taken back from its float, played with
floating turned off, played while its player is out of the layout, and
opened in the background and started there before it loads. In none of
them may the card show it or its tab hold the card's role.
"""
import os
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("video-card")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
t = sv.T()
CLIP = Path(os.environ.get("TMPDIR", "/tmp")) / f"video-card-{os.getpid()}.mp4"
TITLE = "A Long Drive Through the Countryside"

VIDEO = """<!doctype html><title>Long video</title><body style="margin:0;background:#000">
<div id=box><video id=t src=/long.mp4 playsinline style="width:800px;height:450px;display:block"></video></div><script>
var v = document.getElementById('t');
navigator.mediaSession.metadata = new MediaMetadata({ title: '%s', artist: 'A Traveller',
  artwork: [{ src: '/art.png', sizes: '96x96', type: 'image/png' }] });
navigator.mediaSession.setActionHandler('play', function () { v.play(); });
navigator.mediaSession.setActionHandler('pause', function () { v.pause(); });
navigator.mediaSession.setActionHandler('seekto', function (d) { v.currentTime = d.seekTime; });
window.go = function () { v.volume = 0.01; v.playbackRate = 1.5; var p = v.play(); if (p && p.catch) p.catch(function () {}); return 1; };
if (location.search.indexOf('auto') >= 0) { v.volume = 0.01; v.playbackRate = 1.5; v.autoplay = true; go(); }
</script></body>""" % TITLE


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/video":
            return self.send(VIDEO.encode(), "text/html")
        if path == "/long.mp4" and CLIP.exists():
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


def make_clip():
    if not shutil.which("ffmpeg"):
        return False
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=480x270:rate=24",
                    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-af", "volume=0.0005", "-t", "120",
                    "-pix_fmt", "yuv420p", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", "-shortest", str(CLIP)],
                   capture_output=True, stdin=subprocess.DEVNULL)
    return CLIP.exists()


def mini():
    return sv.cmd({"do": "mini", "action": "state", "values": []})


def short(tab):
    return tab[:8].lower()


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def brief():
    state = mini()
    return {"roles": state.get("roles"), "items": [i.get("title") for i in state.get("items", [])]}


def watch(tab, seconds):
    seen = set()
    end = time.time() + seconds
    while time.time() < end:
        state = mini()
        role = state.get("roles", {}).get(short(tab), "none")
        if role == "mini":
            seen.add("role")
        if any(i.get("title") == TITLE for i in state.get("items", [])):
            seen.add("card")
        time.sleep(0.1)
    return seen


def told(tab):
    return sv.ev(tab, "var b = v.getBoundingClientRect(); [v.paused, v.readyState, v.videoWidth, Math.round(b.width), Math.round(b.height), document.visibilityState].join()")


def floating(tab):
    return sv.cmd({"do": "lingering"}).get("floating", "").lower().startswith(short(tab))


def setting(key, value):
    return sv.cmd({"do": "settings", "set": key, "value": value})


def opened(base, query=""):
    tab = sv.cmd({"do": "open", "url": f"{base}/video{query}"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 10})
    return tab


def played(tab):
    return until(lambda: sv.ev(tab, "v.paused") is False and sv.ev(tab, "v.videoWidth") > 0)


def main():
    if not make_clip():
        print("  skip  no ffmpeg for the video page")
        return
    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    sv.setup()
    sv.launch()
    try:
        sv.cmd({"do": "floataway"})
        other = sv.cmd({"do": "open", "url": f"{base}/other"})["id"]
        sv.cmd({"do": "wait", "id": other, "seconds": 10})

        def land_all():
            if sv.cmd({"do": "lingering"}).get("showing"):
                sv.cmd({"do": "float", "action": "toggle"})
            until(lambda: not sv.cmd({"do": "lingering"}).get("showing"), 4)

        def case(name, run):
            tab = run()
            seen = watch(tab, 1.5) if tab else set()
            t.ok(f"{name}: no card", "card" not in seen and "role" not in seen, (seen, brief()))
            if tab:
                land_all()
                sv.cmd({"do": "close", "id": tab})
            sv.cmd({"do": "select", "id": other})
            time.sleep(0.3)

        def left():
            tab = opened(base)
            sv.cmd({"do": "select", "id": tab})
            time.sleep(0.4)
            sv.ev(tab, "go()")
            t.ok("left: the video plays at 1.5x", played(tab) and sv.ev(tab, "v.playbackRate") == 1.5)
            t.ok("left: it is the float's", until(lambda: mini()["roles"].get(short(tab)) == "float"), brief())
            sv.cmd({"do": "select", "id": other})
            t.ok("left: leaving it, it floats", until(lambda: floating(tab)), sv.cmd({"do": "lingering"}))
            seen = watch(tab, 2)
            sv.ev(tab, "v.pause(), 1")
            seen |= watch(tab, 2)
            t.ok("left: playing and paused while it floats, no card", not seen, (seen, brief()))
            return tab

        def paused():
            tab = opened(base)
            sv.cmd({"do": "select", "id": tab})
            time.sleep(0.4)
            sv.ev(tab, "go()")
            played(tab)
            time.sleep(1)
            sv.ev(tab, "v.pause(), 1")
            time.sleep(0.5)
            sv.cmd({"do": "select", "id": other})
            seen = watch(tab, 3)
            t.ok("paused: paused and left, no card", not seen, (seen, brief()))
            return tab

        def closed():
            tab = opened(base)
            sv.cmd({"do": "select", "id": tab})
            time.sleep(0.4)
            sv.ev(tab, "go()")
            played(tab)
            sv.cmd({"do": "select", "id": other})
            t.ok("closed: it floats", until(lambda: floating(tab)), sv.cmd({"do": "lingering"}))
            sv.cmd({"do": "float", "action": "press", "value": "close"})
            t.ok("closed: the float closes", until(lambda: not sv.cmd({"do": "lingering"}).get("showing"), 4), sv.cmd({"do": "lingering"}))
            seen = watch(tab, 3)
            sv.ev(tab, "v.pause(), 1")
            seen |= watch(tab, 2)
            sv.ev(tab, "go()")
            seen |= watch(tab, 3)
            t.ok("closed: playing on and paused behind, no card", not seen, (seen, told(tab), brief()))
            return tab

        def back():
            tab = opened(base)
            sv.cmd({"do": "select", "id": tab})
            time.sleep(0.4)
            sv.ev(tab, "go()")
            played(tab)
            sv.cmd({"do": "select", "id": other})
            t.ok("back: it floats", until(lambda: floating(tab)), sv.cmd({"do": "lingering"}))
            sv.cmd({"do": "float", "action": "press", "value": "back"})
            until(lambda: not sv.cmd({"do": "lingering"}).get("showing"), 4)
            seen = watch(tab, 2)
            sv.ev(tab, "v.pause(), 1")
            sv.cmd({"do": "select", "id": other})
            seen |= watch(tab, 3)
            t.ok("back: back in its tab, paused and left, no card", not seen, (seen, told(tab), brief()))
            return tab

        def hidden():
            tab = opened(base)
            sv.cmd({"do": "select", "id": tab})
            time.sleep(0.4)
            sv.ev(tab, "go()")
            played(tab)
            sv.ev(tab, "document.getElementById('box').style.display = 'none', 1")
            seen = watch(tab, 3)
            sv.cmd({"do": "select", "id": other})
            seen |= watch(tab, 2)
            sv.ev(tab, "v.pause(), 1")
            seen |= watch(tab, 2)
            t.ok("out of the layout: playing and paused, no card", not seen, (seen, told(tab), brief()))
            return tab

        def background():
            tab = opened(base, "?auto")
            seen = watch(tab, 4)
            playing = sv.ev(tab, "v.paused") is False
            sv.ev(tab, "go()")
            seen |= watch(tab, 3)
            sv.ev(tab, "v.pause(), 1")
            seen |= watch(tab, 2)
            t.ok("background: started before it loads, then paused, no card", not seen, (seen, playing, told(tab), brief()))
            return tab

        only = os.environ.get("VIDEO_CASES", "").split(",")
        for name, run in [("left", left), ("paused", paused), ("closed", closed), ("back", back),
                          ("out of the layout", hidden), ("background", background)]:
            if only == [""] or name in only:
                case(name, run)
    finally:
        sv.quit()
        sv.finish()
        server.shutdown()
        if CLIP.exists():
            CLIP.unlink()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

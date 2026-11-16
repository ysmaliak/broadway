#!/usr/bin/env python3
"""A film playing in another site's player frame floats on a tab or app switch.

Build first (`./build.sh`), then `python3 Tests/float_frames.py`. Needs
ffmpeg for the test videos. A page on 127.0.0.1 embeds a player page from
localhost on another port, as lv.kinogo.ec embeds cinemar.cc, and the video
plays inside that cross-origin frame. Neither host is on the player list
(Players): the bench's `film float` is told so with `player: false`. The
videos carry a silent sound track, so nothing is heard.

Floated by switching tabs and by the window going out of sight (the bench's
sight hook): the page's iframe and the frame's video are what is left showing,
the floating window's pause reaches the video in the frame, and landing puts
both back. A muted autoplay video, a short one (an ad) and a small one (a
preview) in the same kind of frame stay where they are.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-frames")

VIDEOS = {}
PLAYER_PORT = 0

TOP = """<!doctype html><meta charset=utf-8><title>{name}</title>
<style>body{{margin:0;font:14px sans-serif}} header,footer{{height:120px;background:#eee}}</style>
<header>Film page</header>
<iframe src="http://localhost:{port}/player?{name}" width={w} height={h} allow="autoplay; picture-in-picture" frameborder=0></iframe>
<footer>Comments</footer>
<script>
window.__inner = null;
addEventListener('message', function (e) {{ if (e.data && e.data.player) window.__inner = e.data; }});
</script>"""

PLAYER = """<!doctype html><meta charset=utf-8><title>player</title>
<style>html,body{{margin:0;height:100%;background:#000}} video{{width:100%;height:100%;display:block}}</style>
<div class=chrome style="position:absolute;top:0;left:0;right:0;height:30px;background:#333;color:#fff">player bar</div>
<video src="/{video}.mp4" autoplay loop playsinline {muted}></video>
<script>
var v = document.querySelector('video');
setInterval(function () {{
  parent.postMessage({{player: 1, playing: !v.paused, muted: v.muted, time: v.currentTime,
    isolated: document.documentElement.classList.contains('office-floating'),
    marked: v.hasAttribute('data-office-float')}}, '*');
}}, 100);
</script>"""

CASES = {
    "film": {"video": "film", "muted": "", "w": 800, "h": 450},
    "muted": {"video": "film", "muted": "muted", "w": 800, "h": 450},
    "ad": {"video": "ad", "muted": "", "w": 800, "h": 450},
    "tiny": {"video": "film", "muted": "", "w": 240, "h": 135},
}


def serve(handler, host):
    server = ThreadingHTTPServer((host, 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class Media(BaseHTTPRequestHandler):
    def send(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        name = url.path.strip("/")
        if name.endswith(".mp4") and name[:-4] in VIDEOS:
            data = VIDEOS[name[:-4]]
            start, end = 0, len(data) - 1
            header = self.headers.get("Range", "")
            partial = header.startswith("bytes=")
            if partial:
                first, _, last = header[6:].partition("-")
                start = int(first or 0)
                end = min(int(last), end) if last else end
            chunk = data[start:end + 1]
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(chunk)))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.end_headers()
            try:
                self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        if name == "player":
            case = CASES.get(url.query, CASES["film"])
            return self.send(PLAYER.format(video=case["video"], muted=case["muted"]).encode(), "text/html")
        if name in CASES:
            case = CASES[name]
            return self.send(TOP.format(name=name, port=PLAYER_PORT, w=case["w"], h=case["h"]).encode(), "text/html")
        self.send(b"<!doctype html><meta charset=utf-8><title>other</title><p>another page", "text/html")

    def log_message(self, *args):
        pass


def make_videos(folder):
    for name, seconds in (("film", 120), ("ad", 15)):
        path = Path(folder, f"{name}.mp4")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", f"testsrc=size=640x360:rate=15:duration={seconds}",
                        "-f", "lavfi", "-i", f"anullsrc=r=44100:cl=stereo:duration={seconds}",
                        "-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "40", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-b:a", "32k", "-movflags", "+faststart", str(path)], check=True)
        VIDEOS[name] = path.read_bytes()


def until(check, within=8.0):
    deadline = time.monotonic() + within
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last:
                return last
        except (OSError, RuntimeError, ValueError, TypeError):
            last = None
        time.sleep(0.1)
    return last


def inner(tab):
    raw = sv.ev(tab, "JSON.stringify(window.__inner)")
    return json.loads(raw) if raw else None


def outer(tab):
    raw = sv.ev(tab, """JSON.stringify({isolated: document.documentElement.classList.contains('office-floating'),
        framed: !!document.querySelector('iframe[data-office-float]')})""")
    return json.loads(raw) if raw else {}


def film(action, path, via):
    try:
        sv.cmd({"do": "film", "action": action, "path": path, "seconds": 1.5, "via": via, "player": False})
    except RuntimeError as error:
        return {"error": str(error), "hosts": [], "frames": []}
    return json.loads(Path(path + ".json").read_text())


def floated(recorded):
    return any(h.get("in") == "float" for h in recorded.get("hosts", []))


def check_film(t, out, tab, via):
    name = {"switch": "switching tabs", "sight": "out of sight"}[via]
    sv.cmd({"do": "select", "id": tab})
    playing = until(lambda: (inner(tab) or {}).get("playing"))
    t.ok(f"film, {name}: the video plays in the cross-origin frame", playing, inner(tab))
    went = film("float", f"{out}/film-{via}-float", via)
    t.ok(f"film, {name}: it floats", floated(went), went.get("error") or [h.get("in") for h in went.get("hosts", [])][-3:])
    page = until(lambda: outer(tab).get("framed") and outer(tab))
    t.ok(f"film, {name}: the page shows only the player's iframe", bool(page) and page["isolated"], outer(tab))
    frame = until(lambda: (inner(tab) or {}).get("marked") and inner(tab))
    t.ok(f"film, {name}: the frame shows only its video", bool(frame) and frame["isolated"], inner(tab))
    if via == "switch":
        sv.cmd({"do": "float", "action": "press", "value": "pause"})
        paused = until(lambda: (inner(tab) or {}).get("playing") is False)
        t.ok(f"film, {name}: the floating window's pause reaches the video in the frame", paused, inner(tab))
        sv.cmd({"do": "float", "action": "press", "value": "pause"})
        again = until(lambda: (inner(tab) or {}).get("playing") is True)
        t.ok(f"film, {name}: and play starts it again", again, inner(tab))
    came = film("land", f"{out}/film-{via}-land", via)
    t.ok(f"film, {name}: it lands", not came.get("error"), came.get("error"))
    back = until(lambda: not outer(tab).get("isolated") and not (inner(tab) or {}).get("isolated") and inner(tab))
    t.ok(f"film, {name}: the page and the frame are as they were", bool(back) and not outer(tab).get("framed")
         and not back["marked"], (outer(tab), inner(tab)))
    t.ok(f"film, {name}: and the film still plays", until(lambda: (inner(tab) or {}).get("playing")), inner(tab))
    sv.cmd({"do": "select", "id": tab})
    time.sleep(0.5)


def check_stays(t, out, case, tab, via):
    name = {"switch": "switching tabs", "sight": "out of sight"}[via]
    what = {"muted": "a muted autoplay video", "ad": "a 15 s video (an ad)", "tiny": "a 240x135 video"}[case]
    sv.cmd({"do": "select", "id": tab})
    playing = until(lambda: (inner(tab) or {}).get("playing"))
    t.ok(f"{case}, {name}: {what} plays in the frame", playing, inner(tab))
    went = film("float", f"{out}/{case}-{via}-float", via)
    time.sleep(0.5)
    t.ok(f"{case}, {name}: {what} does not float", not went.get("error") and not floated(went)
         and not outer(tab).get("isolated") and not (inner(tab) or {}).get("isolated"),
         (went.get("error"), outer(tab), inner(tab)))
    sv.cmd({"do": "select", "id": tab})
    time.sleep(0.5)


def main():
    global PLAYER_PORT
    if not shutil.which("ffmpeg"):
        sys.exit("float_frames needs ffmpeg for its test videos")
    folder = tempfile.mkdtemp(prefix="search-float-frames-")
    out = tempfile.mkdtemp(prefix="search-float-frames-film-")
    make_videos(folder)
    player = serve(Media, "127.0.0.1")
    PLAYER_PORT = player.server_port
    top = serve(Media, "127.0.0.1")
    base = f"http://127.0.0.1:{top.server_port}"
    t = sv.T()
    try:
        sv.setup()
        for host in ("127.0.0.1", "localhost"):
            subprocess.run(["defaults", "write", sv.SUITE, f"autoplay.{host}", "-bool", "true"])
        sv.launch()
        sv.cmd({"do": "window"})
        sv.sp("open", url=f"{base}/other")
        tab = sv.cmd({"do": "open", "url": f"{base}/film"})["id"]
        for via in ("switch", "sight"):
            check_film(t, out, tab, via)
        sv.cmd({"do": "close", "id": tab})
        time.sleep(0.5)
        t.ok("closing the film's tab floats nothing", sv.cmd({"do": "float", "action": "chrome"}).get("floating") is False,
             sv.cmd({"do": "float", "action": "chrome"}))
        for case in ("muted", "ad", "tiny"):
            for via in ("sight", "switch"):
                page = sv.cmd({"do": "open", "url": f"{base}/{case}"})["id"]
                check_stays(t, out, case, page, via)
                sv.cmd({"do": "close", "id": page})
    finally:
        t.done()
        sv.finish()
        for server in (player, top):
            server.shutdown()
            server.server_close()
        shutil.rmtree(folder, ignore_errors=True)
        shutil.rmtree(out, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

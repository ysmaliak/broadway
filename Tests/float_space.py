#!/usr/bin/env python3
"""A video left playing in the space you leave floats, as it does on a switch of tab.

Build first (`./build.sh`), then `python3 Tests/float_space.py`. Needs ffmpeg
for the test video. A hidden probe with two spaces and a playing video in the
first:

- each way of switching (the space's key, the bench's go, a swipe over the
  column, the space's button at the column's foot, a jump between stacked
  spaces) floats the video, and coming back to
  its tab lands it, whole and still playing;
- from the other space, the floating window's pause, close and Back to Tab
  reach the tab, and Back to Tab brings you to its space;
- a page with sound and no video floats nothing;
- with float.leave off, nothing floats.
"""
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-space")

VIDEO = b""

PAGE = b"""<!doctype html><meta charset=utf-8><title>film</title>
<style>body{margin:0;background:#222} video{width:100%;height:auto;display:block}</style>
<video src="/film.mp4" autoplay loop playsinline></video>"""

TONE = """(function () {
  var r = 8000, n = r * 120, b = new ArrayBuffer(44 + n * 2), d = new DataView(b);
  function s(o, t) { for (var i = 0; i < t.length; i++) d.setUint8(o + i, t.charCodeAt(i)) }
  s(0, 'RIFF'); d.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); d.setUint32(16, 16, true);
  d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, r, true); d.setUint32(28, r * 2, true);
  d.setUint16(32, 2, true); d.setUint16(34, 16, true); s(36, 'data'); d.setUint32(40, n * 2, true);
  for (var i = 0; i < n; i++) d.setInt16(44 + i * 2, Math.sin(i / r * 2 * Math.PI * 440) * 800, true);
  var a = document.createElement('audio'); a.id = 't';
  a.src = URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
  document.body.appendChild(a);
  a.play();
  return 1;
})()"""


class Media(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/film.mp4"):
            data = VIDEO
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
        body = PAGE if self.path.startswith("/film") else b"<!doctype html><title>other</title><p>other"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def make_video(folder):
    global VIDEO
    path = Path(folder, "film.mp4")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y",
                    "-f", "lavfi", "-i", "testsrc=size=640x360:rate=15:duration=120",
                    "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo:duration=120",
                    "-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "40", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "32k", "-movflags", "+faststart", str(path)], check=True)
    VIDEO = path.read_bytes()


def until(check, within=6.0):
    deadline = time.monotonic() + within
    last = None
    while time.monotonic() < deadline:
        try:
            last = check()
            if last:
                return last
        except (OSError, RuntimeError, ValueError, TypeError, KeyError):
            last = None
        time.sleep(0.1)
    return last


def float_state():
    return sv.cmd({"do": "lingering"})


def floating(tab=None):
    state = float_state()
    return state["showing"] and (tab is None or state["floating"].lower().startswith(tab.lower()))


def landed():
    state = float_state()
    return not state["showing"] and state["floating"] == ""


def playing(tab):
    return sv.ev(tab, "(function(){var v=document.querySelector('video');return !!v && !v.paused && v.currentTime > 0.2})()")


def paused(tab):
    return sv.ev(tab, "(function(){var v=document.querySelector('video');return !!v && v.paused})()")


def isolated(tab):
    return sv.ev(tab, "document.documentElement.classList.contains('office-floating')")


def space(**f):
    return sv.cmd({"do": "space", **f})


def current():
    return space()["current"]


def active():
    return next((x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("active")), None)


def press(button):
    return sv.cmd({"do": "float", "action": "press", "value": button})


def home(t, tab, label):
    t.ok(f"{label}: back on its tab, the video lands", until(landed), float_state())
    t.ok(f"{label}: the page is whole and still plays",
         until(lambda: not isolated(tab) and playing(tab), 8), (isolated(tab), playing(tab)))


def start(leave=True):
    sv.setup()
    for key, value in (("spaces", True), ("float.leave", leave), ("float.away", False), ("autoplay.127.0.0.1", True)):
        subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", "true" if value else "false"])
    sv.launch()
    sv.cmd({"do": "window"})


def two_spaces(t, base):
    space(action="new", name="Two")
    space(action="go", index=1)
    t.ok("two spaces, on the first", current() != "Two" and len(space()["spaces"]) == 2, space())
    other = sv.sp("open", url=f"{base}/other")["resultID"]
    tab = sv.cmd({"do": "open", "url": f"{base}/film"})["id"]
    sv.cmd({"do": "select", "id": tab})
    t.ok("the video plays", until(lambda: playing(tab), 12), playing(tab))
    time.sleep(1)
    return tab, other


def ways(t, base):
    start()
    tab, other = two_spaces(t, base)

    space(action="key", index=2)
    t.ok("the space's key: on the second space", until(lambda: current() == "Two"), space())
    t.ok("the space's key: the video floats", until(lambda: floating(tab), 8), float_state())
    t.ok("the space's key: its page shows only the video", until(lambda: isolated(tab)), isolated(tab))
    t.ok("the space's key: it keeps playing out there", until(lambda: playing(tab)), playing(tab))

    press("pause")
    t.ok("from the other space, pause reaches the page", until(lambda: paused(tab)), paused(tab))
    press("play")
    t.ok("and play again", until(lambda: playing(tab)), playing(tab))

    space(action="key", index=1)
    home(t, tab, "the space's key")

    space(action="go", index=2)
    t.ok("go: the video floats", until(lambda: floating(tab), 8), float_state())
    press("close")
    t.ok("closed from the other space, nothing floats", until(landed), float_state())
    t.ok("closed from the other space, the page is whole and plays",
         until(lambda: not isolated(tab) and playing(tab), 8), (isolated(tab), playing(tab)))
    t.ok("closed from the other space, you stay where you are", current() == "Two", space())
    space(action="go", index=1)
    t.ok("back on the first space, nothing comes out", not floating(), float_state())

    sv.cmd({"do": "select", "id": tab})
    space(action="go", index=2)
    t.ok("go again: the video floats", until(lambda: floating(tab), 8), float_state())
    press("back")
    t.ok("Back to Tab from the other space: on its space", until(lambda: current() != "Two"), space())
    t.ok("Back to Tab from the other space: on its tab", until(lambda: active() == tab), active())
    home(t, tab, "Back to Tab")

    space(action="swipe", dx=-160)
    t.ok("a swipe: on the second space", until(lambda: current() == "Two"), space())
    t.ok("a swipe: the video floats", until(lambda: floating(tab), 8), float_state())
    space(action="swipe", dx=160)
    t.ok("a swipe back: on the first space", until(lambda: current() != "Two"), space())
    home(t, tab, "a swipe back")

    foot = space(action="foot", index=2)
    t.ok("the foot's space button: on the second space", until(lambda: current() == "Two"), foot)
    t.ok("the foot's space button: the video floats", until(lambda: floating(tab), 8), float_state())
    space(action="foot", index=1)
    home(t, tab, "the foot's space button")

    sv.cmd({"do": "select", "id": other})
    t.ok("a switch of tab floats it", until(lambda: floating(tab), 8), float_state())
    space(action="go", index=2)
    time.sleep(1)
    t.ok("a switch of space after it keeps it out", floating(tab), float_state())
    space(action="go", index=1)
    time.sleep(1)
    t.ok("back on its space with another tab in front, it stays out", floating(tab), float_state())
    sv.cmd({"do": "select", "id": tab})
    home(t, tab, "its tab selected")

    sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
    sv.cmd({"do": "stacked", "action": "load"})
    time.sleep(1)
    sv.cmd({"do": "stacked", "action": "jump", "space": 2})
    t.ok("stacked: on the second space", until(lambda: current() == "Two"), space())
    t.ok("stacked: the video floats", until(lambda: floating(tab), 8), float_state())
    sv.cmd({"do": "stacked", "action": "jump", "space": 1})
    home(t, tab, "stacked")
    sv.finish()


def quiet(t, base):
    start()
    tab, _ = two_spaces(t, base)
    sv.cmd({"do": "close", "id": tab})
    sound = sv.cmd({"do": "open", "url": f"{base}/sound"})["id"]
    sv.cmd({"do": "select", "id": sound})
    time.sleep(1)
    sv.ev(sound, TONE)
    t.ok("sound alone plays", until(lambda: sv.ev(sound, "document.getElementById('t').paused") is False), "")
    space(action="go", index=2)
    time.sleep(2)
    t.ok("sound without a video: nothing floats", not floating(), float_state())
    t.ok("and the sound goes on in the space left", sv.ev(sound, "document.getElementById('t').paused") is False, "")
    sv.finish()

    start(leave=False)
    two_spaces(t, base)
    space(action="go", index=2)
    time.sleep(2)
    t.ok("float.leave off: nothing floats", not floating(), float_state())
    sv.finish()


def main():
    t = sv.T()
    with tempfile.TemporaryDirectory() as folder:
        make_video(folder)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Media)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            ways(t, base)
            quiet(t, base)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

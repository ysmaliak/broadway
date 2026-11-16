#!/usr/bin/env python3
"""A playing video floats when its window goes out of sight, not when another app comes forward.

Build first (`./build.sh`), then `python3 Tests/float_sight.py`. Needs ffmpeg
for the test video. With Settings > Video > Float the video on its own set
to Tabs or out of sight (`float.away`):

Hidden copy, the bench standing in for what macOS reports:
- the app deactivating while the window is in view floats nothing;
- the window out of sight floats the video, and in sight again lands it;
- a hidden copy's real state (the app hidden, so the window isn't seen) floats it.

Shown copy (SEARCH_SHOWN), a real window from the bench over it:
- a window covering Broadway's whole window floats the video through the occlusion
  notification alone, and taking it away lands it;
- another app's window over most of the page floats it on the app switch;
  one over a third of the page doesn't.

Pass SHOTS=<folder> for window-only captures of the test copy.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-sight")

VIDEO = b""
SHOTS = Path(os.environ["SHOTS"]) if os.environ.get("SHOTS") else None

PAGE = b"""<!doctype html><meta charset=utf-8><title>film</title>
<style>body{margin:0;background:#222} video{width:100%;height:auto;display:block}</style>
<video src="/film.mp4" autoplay loop playsinline></video>"""


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
        except (OSError, RuntimeError, ValueError, TypeError):
            last = None
        time.sleep(0.1)
    return last


def sight(action, value=None):
    request = {"do": "float", "action": action}
    if value is not None:
        request["value"] = value
    return sv.cmd(request)


def floating():
    return sight("sight", "keep").get("floating") is True


def playing(tab):
    return sv.ev(tab, "(function(){var v=document.querySelector('video');return !!v && !v.paused && v.currentTime > 0.2})()")


def isolated(tab):
    return sv.ev(tab, "document.documentElement.classList.contains('office-floating')")


def shoot(name, number):
    if not SHOTS or not number:
        return
    SHOTS.mkdir(parents=True, exist_ok=True)
    subprocess.run(["screencapture", "-x", "-o", "-l", str(number), str(SHOTS / f"{name}.png")], capture_output=True)


def start(shown):
    sv.setup()
    for key in ("float.away", "float.leave", "autoplay.127.0.0.1"):
        subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", "true"])
    if not shown:
        sv.launch()
        return
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")
    sv.cmd({"do": "idle", "action": "unhide"})


def open_film(t, base, label):
    sv.cmd({"do": "window"})
    sv.sp("open", url=f"{base}/other")
    tab = sv.cmd({"do": "open", "url": f"{base}/film"})["id"]
    sv.cmd({"do": "select", "id": tab})
    t.ok(f"{label}: the video plays", until(lambda: playing(tab), 10), playing(tab))
    return tab


def simulated(t, base):
    start(shown=False)
    tab = open_film(t, base, "hidden copy")
    sight("sight", "visible")
    report = sight("left")
    time.sleep(1.2)
    t.ok("app deactivated, window in view: nothing floats", not floating() and not isolated(tab), report)
    sight("sight", "hidden")
    sight("look")
    t.ok("window out of sight: the video floats", until(floating), sight("sight", "keep"))
    t.ok("window out of sight: the page shows only its video", until(lambda: isolated(tab)), isolated(tab))
    sight("left")
    time.sleep(0.6)
    t.ok("app deactivating while out of sight leaves it floating", floating())
    sight("sight", "visible")
    sight("look")
    t.ok("window in sight again: the video lands", until(lambda: not floating()), sight("sight", "keep"))
    t.ok("window in sight again: the page is whole and the video still plays",
         until(lambda: not isolated(tab) and playing(tab)), (isolated(tab), playing(tab)))
    sight("sight", "visible")
    sight("back")
    time.sleep(0.6)
    t.ok("app coming back with nothing floated changes nothing", not floating())
    sight("sight", "real")
    report = sight("look")
    t.ok("real state of a hidden copy: the window is not seen", report["judged"].get("shown") is False, report)
    t.ok("real state of a hidden copy: the video floats", until(floating), sight("sight", "keep"))
    sight("sight", "visible")
    sight("look")
    t.ok("and lands when the bench says it is seen again", until(lambda: not floating()), sight("sight", "keep"))
    sv.finish()


def real(t, base):
    start(shown=True)
    tab = open_film(t, base, "shown copy")
    report = sight("sight", "front")
    time.sleep(0.6)
    report = sight("look")
    window = report.get("windowNumber")
    if report["judged"].get("shown") is not True:
        print("  skip shown copy: its window isn't in view on this screen", report)
        sv.finish()
        return
    t.ok("shown copy, in view: nothing floats", not floating(), report)
    shoot("1-in-view", window)
    report = sight("cover", "1")
    t.ok("a window over all of Broadway's: macOS reports it occluded",
         until(lambda: sight("sight", "keep")["occlusionVisible"] is False), sight("sight", "keep"))
    t.ok("a window over all of Broadway's: the video floats on the occlusion notification", until(floating),
         sight("sight", "keep"))
    shoot("2-covered-panel", sight("sight", "keep").get("panel"))
    sight("cover", "0")
    t.ok("cover gone: macOS reports it visible", until(lambda: sight("sight", "keep")["occlusionVisible"]),
         sight("sight", "keep"))
    t.ok("cover gone: the video lands", until(lambda: not floating()), sight("sight", "keep"))
    t.ok("cover gone: the page is whole and playing", until(lambda: not isolated(tab) and playing(tab)),
         (isolated(tab), playing(tab)))
    shoot("3-landed", window)
    report = sight("cover", "0.8")
    sight("left")
    t.ok("80% of the page under another window, app left: floats", until(floating), sight("sight", "keep"))
    t.ok("80% of the page under another window: macOS still calls the window visible",
         sight("sight", "keep")["occlusionVisible"] is True)
    sight("cover", "0")
    sight("back")
    t.ok("uncovered and back: lands", until(lambda: not floating()), sight("sight", "keep"))
    sight("cover", "0.3")
    report = sight("left")
    time.sleep(1.2)
    report = sight("sight", "keep")
    t.ok("30% of the page under another window, app left: stays", not floating(), report)
    sight("cover", "0")
    sv.finish()


def main():
    if not shutil.which("ffmpeg"):
        sys.exit("float_sight needs ffmpeg for its test video")
    folder = tempfile.mkdtemp(prefix="search-float-sight-")
    make_video(folder)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Media)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    t = sv.T()
    try:
        if os.environ.get("ONLY") != "real":
            simulated(t, base)
        real(t, base)
    finally:
        t.done()
        sv.finish()
        server.shutdown()
        server.server_close()
        shutil.rmtree(folder, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

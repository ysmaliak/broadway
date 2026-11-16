#!/usr/bin/env python3
"""The floating video's play/pause key, filmed through a press each way.

Build first (`./build.sh`), then `python3 Tests/float_toggle_film.py OUT BOUNDS`.
BOUNDS is a helper that prints a window's x,y,w,h from its number. Needs
ffmpeg and screen recording. A shown copy floats a playing video by covering
its window (the bench's sight hook), brings the chrome up, and records the
floating window with screencapture while the bench presses pause, then play.
OUT gets toggle.mov and a strip of the key's frames around each press.
"""
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import float_sight as fs  # noqa: E402
import split_view as sv  # noqa: E402

sv.use("float-toggle")


def main():
    out, bounds = Path(sys.argv[1]), sys.argv[2]
    out.mkdir(parents=True, exist_ok=True)
    t = sv.T()
    with tempfile.TemporaryDirectory(prefix="broadway-float-toggle-") as folder:
        fs.make_video(folder)
        server = ThreadingHTTPServer(("127.0.0.1", 0), fs.Media)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        try:
            fs.start(shown=True)
            fs.open_film(t, base, "shown copy")
            fs.sight("sight", "front")
            time.sleep(0.6)
            fs.sight("cover", "1")
            t.ok("covered: the video floats", fs.until(fs.floating), fs.sight("sight", "keep"))
            panel = fs.sight("sight", "keep").get("panel")
            time.sleep(1.5)
            sv.cmd({"do": "float", "action": "hover"})
            time.sleep(0.6)
            rect = subprocess.run([bounds, str(panel)], capture_output=True, text=True).stdout.strip()
            t.ok("the floating window is on a screen", bool(rect), rect)
            film = out / "toggle.mov"
            film.unlink(missing_ok=True)
            rec = subprocess.Popen(["screencapture", "-v", "-V", "4", "-x", "-R", rect, str(film)])
            time.sleep(1.2)
            for word in ("pause", "play"):
                sv.cmd({"do": "float", "action": "hover"})
                said = sv.cmd({"do": "float", "action": "press", "value": word})
                print(f"  pressed {word} at {time.monotonic():.3f}: playing={said.get('playing')}")
                time.sleep(1.2)
            rec.wait(timeout=20)
            t.ok("filmed", film.exists() and film.stat().st_size > 0)
        finally:
            fs.sight("cover", "0")
            sv.finish()
            server.shutdown()
    return t.done()


if __name__ == "__main__":
    if not shutil.which("ffmpeg"):
        sys.exit("float_toggle_film needs ffmpeg")
    sys.exit(main())

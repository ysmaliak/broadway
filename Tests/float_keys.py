#!/usr/bin/env python3
"""Floating playback, physical keys, and return persistence in a private probe."""
import functools
import json
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("float-keys")


def main():
    with tempfile.TemporaryDirectory(prefix="broadway-float-keys-") as folder:
        root = Path(folder)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=640x360:rate=24", "-t", "120", "-c:v", "libx264",
                        "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(root / "clip.mp4")], check=True)
        (root / "index.html").write_text("""<!doctype html><title>Float keys</title>
        <body style='margin:0;background:#fafafa'><input id=editor value=untouched>
        <video src=clip.mp4 autoplay muted loop playsinline style='width:80%'></video>
        <script>window.keys=[];addEventListener('keydown',e=>keys.push(e.key));</script>""")
        (root / "other.html").write_text("<!doctype html><title>Other</title><input value=untouched>")

        class Quiet(SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=folder))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        t = sv.T()
        try:
            sv.setup(**{"float.leave": False})
            sv.launch()
            sv.cmd({"do": "window"})
            base = f"http://127.0.0.1:{server.server_port}"
            other = sv.sp("open", url=f"{base}/other.html")["resultID"]
            tab = sv.sp("open", url=f"{base}/index.html")["resultID"]
            sv.cmd({"do": "select", "id": tab})
            time.sleep(2)

            def ev(js):
                return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")

            def floating(action="chrome", value=None):
                return sv.cmd({"do": "float", "action": action, "value": value})

            def key(code, chars="", mods=None, **fields):
                return floating("key", json.dumps(dict(code=code, chars=chars, mods=mods or [], **fields)))

            def lift():
                return sv.cmd({"do": "film", "action": "float", "path": str(root / "float"), "seconds": 1})

            lift()
            floating("hover", "on")
            time.sleep(0.5)
            t.ok("a loaded video exposes its current rate", floating()["controllable"] and floating()["rate"] == 1)
            ev("document.querySelector('video').pause();document.querySelector('video').currentTime=40")
            time.sleep(1)
            key(124)
            time.sleep(0.2)
            t.ok("right seeks fifteen seconds", abs(ev("document.querySelector('video').currentTime") - 55) < 0.5)
            key(123, mods=["shift"])
            time.sleep(0.2)
            t.ok("shift left seeks five seconds", abs(ev("document.querySelector('video').currentTime") - 50) < 0.5)
            t.ok("seek HUD is visible", floating()["feedback"] == "−5 s")
            floating("scrub", "0.25")
            time.sleep(0.2)
            t.ok("scrubbing seeks to the chosen time", abs(ev("document.querySelector('video').currentTime") - 30) < 0.5)
            t.ok("scrub release briefly keeps its time in glass", floating()["feedback"] == "0:30")
            key(49, " ")
            time.sleep(0.3)
            t.ok("Space starts playback", ev("!document.querySelector('video').paused") is True)
            key(49, " ")
            time.sleep(0.3)
            t.ok("Space pauses playback", ev("document.querySelector('video').paused") is True)
            key(46, "ь")
            time.sleep(0.2)
            t.ok("Russian M physical key unmutes", ev("document.querySelector('video').muted") is False)
            key(46, "ь")
            time.sleep(0.2)
            t.ok("Russian M physical key mutes", ev("document.querySelector('video').muted") is True)
            for rate in [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]:
                floating("rate", str(rate))
                time.sleep(0.15)
                t.ok(f"speed control applies {rate}x", ev("document.querySelector('video').playbackRate") == rate)
            floating("press", "speed")
            time.sleep(0.2)
            t.ok("speed button cycles from 2 to 0.5", floating()["rate"] == 0.5)
            key(47, "Ю", ["shift"])
            time.sleep(0.2)
            t.ok("Russian greater-than physical key raises speed", ev("document.querySelector('video').playbackRate") == 0.75)
            key(43, "Б", ["shift"])
            time.sleep(0.2)
            t.ok("Russian less-than physical key lowers speed", ev("document.querySelector('video').playbackRate") == 0.5)
            state = floating()
            t.ok("speed shows once, in the top capsule", state["shown"] and state["rate"] == 0.5 and state["feedback"] == "", state)
            ev("document.querySelector('video').playbackRate=1.04")
            floating("rate", "1")
            time.sleep(0.2)
            native = sv.cmd({"do": "eval", "id": tab, "js": "document.querySelector('video').playbackRate", "world": "search"}).get("value")
            t.ok("returning to 1 uses LiveRate's native 1.0001 after catch-up", native == 1.0001 and ev("document.querySelector('video').playbackRate") == 1)
            before = ev("document.querySelector('video').currentTime")
            t.ok("Command right passes to the browser", key(124, mods=["command"])["handled"] is False)
            t.ok("Control and Option transport pass through", not key(49, mods=["control"])["handled"] and not key(46, mods=["option"])["handled"])
            time.sleep(0.2)
            t.ok("browser chords leave video position alone", ev("document.querySelector('video').currentTime") == before)
            floating("hover", "off")
            time.sleep(0.9)
            t.ok("keys outside the float pass through", key(49, " ", outside=True)["handled"] is False)
            floating("hover", "on")
            sv.cmd({"do": "select", "id": other})
            time.sleep(0.3)
            t.ok("hover handles transport over a page without a caret", key(46, "ь", outside=True)["handled"] is True)
            sv.cmd({"do": "eval", "id": other, "js": "document.querySelector('input').focus()"})
            time.sleep(0.2)
            t.ok("hover never steals a page text field's M", key(46, "ь", outside=True)["handled"] is False)
            t.ok("mapped keys never reach the floated page", ev("JSON.stringify(keys)") == "[]")
            sv.cmd({"do": "select", "id": tab})
            if floating().get("floating") is False:
                lift()
            floating("hover", "on")
            floating("rate", "1.5")
            time.sleep(0.3)
            key(36, "\r")
            time.sleep(1.5)
            t.ok("Return puts the video back", floating().get("floating") is False)
            t.ok("rate survives returning to the tab", ev("document.querySelector('video').playbackRate") == 1.5)
            lift()
            key(53, "\u001b")
            time.sleep(1.5)
            t.ok("Escape puts the video back", floating().get("floating") is False)
            lift()
            floating("hover", "on")
            ev("document.querySelector('video').remove()")
            time.sleep(0.7)
            t.ok("removing the video disables speed", floating()["controllable"] is False)
            t.ok("disabled speed makes no change", floating("rate", "2")["controllable"] is False)
        finally:
            t.done()
            sv.finish()
            server.shutdown()
        return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

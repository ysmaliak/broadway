#!/usr/bin/env python3
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

sv.use("float-extras")


def main():
    with tempfile.TemporaryDirectory(prefix="broadway-float-extras-") as folder:
        root = Path(folder)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=640x360:rate=24", "-t", "120", "-c:v", "libx264",
                        "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(root / "clip.mp4")], check=True)
        (root / "en.vtt").write_text("WEBVTT\n\n00:00.000 --> 02:00.000\nEnglish caption\n")
        (root / "pl.vtt").write_text("WEBVTT\n\n00:00.000 --> 02:00.000\nPolski napis\n")
        (root / "chapters.vtt").write_text("WEBVTT\n\n00:00.000 --> 00:40.000\nOpening\n\n00:40.000 --> 01:20.000\nMiddle\n\n01:20.000 --> 02:00.000\nEnding\n")
        (root / "index.html").write_text("""<!doctype html><title>Float extras</title>
        <body style='margin:0;background:#182330'>
        <video src=clip.mp4 autoplay muted loop playsinline style='width:80%'>
        <track kind=subtitles srclang=en label=English src=en.vtt>
        <track kind=captions srclang=pl label=Polski src=pl.vtt>
        <track kind=chapters src=chapters.vtt>
        </video>""")

        class Quiet(SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=folder))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        t = sv.T()
        try:
            sv.setup(**{"float.leave": False})
            sv.launch()
            owned = sv.running()
            worlds = [subprocess.run(["ps", "eww", "-p", pid], capture_output=True, text=True).stdout for pid in owned]
            t.ok("every Broadway from this worktree has its SEARCH_PROBE world", bool(worlds) and all(f"SEARCH_PROBE={sv.W}" in row for row in worlds))
            sv.cmd({"do": "window"})
            tab = sv.sp("open", url=f"http://127.0.0.1:{server.server_port}/index.html")["resultID"]
            sv.cmd({"do": "select", "id": tab})
            time.sleep(2)

            def ev(js):
                return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")

            def floating(action="chrome", value=None):
                return sv.cmd({"do": "float", "action": action, "value": value})

            def wait_for(predicate, seconds=4):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    if predicate():
                        return True
                    time.sleep(0.05)
                return False

            sv.cmd({"do": "film", "action": "float", "path": str(root / "float"), "seconds": 1})
            floating("hover", "on")
            t.ok("two HTML text tracks expose languages", wait_for(lambda: len(floating().get("captions", [])) == 2))
            t.ok("WebVTT chapter cues load while hidden", wait_for(lambda: len(floating().get("chapters", [])) == 3))
            t.ok("chapter titles preserve authored order", [c["name"] for c in floating()["chapters"]] == ["Opening", "Middle", "Ending"])
            t.ok("ordinary video uses its real seekable range", floating()["seekable"] and floating()["rangeEnd"] > 119 and not floating()["live"])
            floating("key", json.dumps({"code": 8, "chars": "с"}))
            t.ok("physical C toggles captions with Russian layout", wait_for(lambda: ev("document.querySelector('video').textTracks[0].mode") == "showing"))
            floating("captions", "1")
            t.ok("language selection disables the previous language", wait_for(lambda: ev("Array.from(document.querySelector('video').textTracks).map(t=>t.mode).join(',')") == "disabled,showing,hidden"))
            floating("press", "captions")
            t.ok("caption button toggles off", wait_for(lambda: not any(c["selected"] for c in floating()["captions"])))
            ev("document.querySelector('video').pause()")
            floating("scrub", "0.5")
            t.ok("ordinary video still scrubs correctly", abs(ev("document.querySelector('video').currentTime") - 60) < 0.5)
            ev("""window.v=document.querySelector('video'); window.fake={start:100,end:180,time:120,ready:4,playing:true};
                Object.defineProperties(v,{
                  duration:{configurable:true,get:()=>Infinity},
                  currentTime:{configurable:true,get:()=>fake.time,set:x=>fake.time=x},
                  paused:{configurable:true,get:()=>!fake.playing},
                  readyState:{configurable:true,get:()=>fake.ready},
                  seekable:{configurable:true,get:()=>({length:1,start:()=>fake.start,end:()=>fake.end})}
                });true;""")
            t.ok("infinite duration with range exposes DVR", wait_for(lambda: floating()["live"] and floating()["rangeStart"] == 100))
            t.ok("live lag comes from the edge", floating()["lag"] == 60)
            floating("scrub", "0.5")
            t.ok("DVR scrub accounts for the range start", ev("fake.time") == 140)
            ev("fake.start=110;fake.end=190")
            t.ok("moving live window refreshes", wait_for(lambda: floating()["rangeEnd"] == 190))
            floating("press", "live")
            t.ok("Go Live reaches the newest edge", ev("fake.time") == 190)
            floating("key", json.dumps({"code": 124}))
            t.ok("skip clamps to live edge", ev("fake.time") == 190)
            ev("fake.time=115")
            time.sleep(0.9)
            floating("key", json.dumps({"code": 123}))
            t.ok("back skip clamps to oldest DVR time", ev("fake.time") == 110)
            ev("Object.defineProperty(v,'seekable',{configurable:true,get:()=>({length:2,start:i=>[110,160][i],end:i=>[140,190][i]})});fake.time=120;true")
            time.sleep(0.9)
            floating("scrub", "0.5")
            t.ok("scrub clamps a discontinuity to a playable boundary", ev("fake.time") == 140)
            t.ok("optimistic thumb stays out of a discontinuity", abs(floating()["through"] - 0.375) < 0.001)
            floating("key", json.dumps({"code": 124}))
            t.ok("skip across a discontinuity chooses the nearest range", ev("fake.time") == 160)
            ev("Object.defineProperty(v,'seekable',{configurable:true,get:()=>({length:1,start:()=>fake.start,end:()=>fake.end})});true")
            floating("hover", "off")
            time.sleep(1.5)
            ev("fake.ready=2;v.dispatchEvent(new Event('waiting'))")
            time.sleep(0.1)
            t.ok("short stalls have no waiting flash", not floating()["waiting"])
            ev("fake.ready=4;v.dispatchEvent(new Event('playing'))")
            time.sleep(0.5)
            t.ok("recovered short stall stays calm", not floating()["waiting"])
            ev("fake.ready=2;v.dispatchEvent(new Event('waiting'))")
            t.ok("long stall shows waiting while chrome is hidden", wait_for(lambda: floating()["waiting"]) and not floating()["shown"])
            ev("fake.ready=4;v.dispatchEvent(new Event('playing'))")
            t.ok("playback recovery clears waiting", wait_for(lambda: not floating()["waiting"]))
            ev("fake.ready=2;fake.playing=false;v.dispatchEvent(new Event('pause'))")
            time.sleep(0.75)
            t.ok("paused video does not buffer", not floating()["waiting"])
            ev("fake.ready=4;fake.playing=true;Object.defineProperty(v,'seekable',{configurable:true,get:()=>({length:0})});true")
            t.ok("live without a range disables seeking", wait_for(lambda: not floating()["seekable"]))
            previous = ev("fake.time")
            floating("scrub", "1")
            t.ok("empty range cannot invent a seek", ev("fake.time") == previous)
            ev("Array.from(v.querySelectorAll('track')).forEach(t=>t.remove())")
            t.ok("removing tracks removes optional chrome", wait_for(lambda: not floating()["captions"] and not floating()["chapters"]))
            ev("v.remove()")
            t.ok("missing video clears optional state", wait_for(lambda: not floating()["controllable"] and not floating()["live"] and not floating()["waiting"]))
        finally:
            t.done()
            sv.finish()
            server.shutdown()
        return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

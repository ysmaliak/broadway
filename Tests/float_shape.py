#!/usr/bin/env python3
import functools
import json
import shutil
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("float-shape")

PAGE = """<!doctype html><meta charset=utf-8><title>{name}</title>
<style>body{{margin:0;background:#fff}}#player{{background:#000;margin:16px;width:640px;height:360px}}
video{{width:100%;height:100%;display:block}}</style>
<div id=player><video muted playsinline></video></div>
<canvas width={width} height={height} style="display:none"></canvas>
<script>
var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;
setInterval(function(){{g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,c.width,c.height);}},40);
var v=document.querySelector('video'); v.srcObject=c.captureStream(25); v.play();
</script>"""

SHAPES = {"wide": (320, 180), "classic": (320, 240), "tall": (180, 320), "cinema": (420, 180), "square": (240, 240)}

PICTURE = """(function(){var v=document.querySelector('video'),b=v.getBoundingClientRect();
var f=v.videoWidth&&v.videoHeight?Math.min(b.width/v.videoWidth,b.height/v.videoHeight):0;
var w=f?v.videoWidth*f:b.width,h=f?v.videoHeight*f:b.height;
return JSON.stringify({x:b.left+(b.width-w)/2,y:b.top+(b.height-h)/2,w:w,h:h,iw:innerWidth,ih:innerHeight,vw:v.videoWidth,vh:v.videoHeight,
floating:document.documentElement.classList.contains('office-floating')});})()"""

AREA = 440 * 247


def wait_for(description, condition, timeout=15):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = condition()
            if last:
                return last
        except (OSError, RuntimeError, KeyError, TypeError, ValueError) as error:
            last = str(error)
        time.sleep(0.1)
    return None


def view(tab):
    p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PICTURE})["value"])
    return [p["iw"], p["ih"]] if p["floating"] and p["iw"] and p["ih"] else None


def shaped(tab, ratio):
    def test():
        f = view(tab)
        return f if f and abs(f[0] / f[1] / ratio - 1) < 0.02 else None
    return test


def filled(tab):
    def test():
        p = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PICTURE})["value"])
        whole = p["floating"] and abs(p["x"]) < 2 and abs(p["y"]) < 2 and abs(p["w"] - p["iw"]) < 3 and abs(p["h"] - p["ih"]) < 3
        return p if whole else None
    return test


def main():
    pages = tempfile.mkdtemp(prefix="search-float-shape-")
    for name, (width, height) in SHAPES.items():
        Path(pages, f"{name}.html").write_text(PAGE.format(name=name, width=width, height=height))

    class Quiet(SimpleHTTPRequestHandler):
        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=pages))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        sv.cmd({"do": "window"})
        for name, (width, height) in SHAPES.items():
            ratio = width / height
            tab = sv.sp("open", url=f"{base}/{name}.html")["resultID"]
            sv.cmd({"do": "select", "id": tab})
            wait_for("the video to play", lambda: json.loads(sv.cmd({"do": "eval", "id": tab, "js": PICTURE})["value"])["vw"] == width)
            went = sv.cmd({"do": "floataway"})
            t.ok(f"{name}: the video floats", went.get("floating") is True, went)
            f = wait_for("the window to take the shape", shaped(tab, ratio))
            t.ok(f"{name}: the window has the video's shape", f is not None, view(tab))
            least = 260 * 260 / max(ratio, 1 / ratio)
            t.ok(f"{name}: the window keeps its area", f is not None and abs(f[0] * f[1] - AREA) < AREA * 0.02 and f[0] * f[1] >= least - 1, f)
            p = wait_for("the picture to fill the window", filled(tab))
            t.ok(f"{name}: the picture fills the window with no bars", p is not None, sv.cmd({"do": "eval", "id": tab, "js": PICTURE}).get("value"))
            if name == "wide":
                sv.cmd({"do": "eval", "id": tab, "js": "var c=document.querySelector('canvas');c.width=180;c.height=320;'ok'"})
                f = wait_for("the window to follow the new shape", shaped(tab, 180 / 320))
                t.ok("wide: the window follows a video that turns tall", f is not None, view(tab))
                p = wait_for("the tall picture to fill the window", filled(tab))
                t.ok("wide: the tall picture fills the window", p is not None, sv.cmd({"do": "eval", "id": tab, "js": PICTURE}).get("value"))
            back = sv.cmd({"do": "floataway"})
            t.ok(f"{name}: the video lands", back.get("floating") is False, back)
            time.sleep(1.2)
            landed = json.loads(sv.cmd({"do": "eval", "id": tab, "js": PICTURE})["value"])
            t.ok(f"{name}: back in its tab the page is as it was", landed["floating"] is False, landed)
            sv.sp("close", id=tab)
    finally:
        t.done(); sv.finish()
        server.shutdown()
        server.server_close()
        shutil.rmtree(pages, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

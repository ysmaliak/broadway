#!/usr/bin/env python3
"""The floating call's corner keys are circles over any picture.

Build first (`./build.sh`), then `python3 Tests/call_corner.py [OUT]`. A call page
shows one person whose tile is a flat light, white or dark colour, or no tiles at
all over a light page. Each floats with its corners shown and is shot by its window
number into OUT (default .context/call-corner). Through the middle of each corner
key the picture is read across and down: where it differs from the ground beside
it is the key, and a key is as tall as it is wide. The panel keeps the window's
active look, where glass lights its top and bottom edge, which over a bright
picture used to leave a key wider than tall.
"""
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import visual_diff as vd  # noqa: E402

sv.use("page-call-corner")
t = sv.T()

PAGE = r"""<!doctype html><title>Weekly sync - Meet</title><style>
html, body { margin: 0; height: 100%; background: __GROUND__; overflow: hidden; }
.stage { position: absolute; inset: 0 0 80px 0; }
.tile { position: absolute; left: 0; top: 0; width: 100vw; height: calc(100vw * 148 / 324); background: __TILE__; }
.bar { position: absolute; left: 0; right: 0; bottom: 0; height: 80px; display: flex; gap: 10px; justify-content: center; align-items: center; }
</style>
<div class=stage>__TILES__</div>
<div class=bar role=toolbar><button aria-label="Turn off microphone" data-is-muted=false>m</button>
<button aria-label="Turn off camera" data-is-muted=false>c</button><button aria-label="Leave call" onclick="end()">x</button></div>
<script>
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => { window.stream = s; window.state = 'started'; })
  .catch(e => { window.state = 'error ' + e.name; });
window.end = () => { stream.getTracks().forEach(x => x.stop()); };
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path.strip("/") == "call":
            html = PAGE.replace("__TILE__", "#" + q.get("tile", "d8d5ca")).replace("__GROUND__", "#" + q.get("ground", "202124"))
            html = html.replace("__TILES__", "" if q.get("tiles") == "0" else "<div class=tile data-participant-id='spaces/a/devices/1'></div>")
        else:
            html = "<!doctype html><title>idle</title><p>idle</p>"
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H

CASES = [
    ("light-tile", "tile=d8d5ca", "on"),
    ("white-tile", "tile=ffffff", "on"),
    ("dark-tile", "tile=202124", "on"),
    ("flat-light", "tiles=0&ground=d8d5ca", "off"),
]
INSET = 10
CIRCLE = 30
STAGE = 8


def call(action="state", *values):
    return sv.cmd({"do": "call", "action": action, "values": list(values)})


def until(check, within=6):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def launch_shown():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


def shoot(path):
    path = Path(path)
    path.unlink(missing_ok=True)
    shot = vd.tool("shot", "WindowShot.swift")
    pid = next(iter(sv.holding() & sv.running()))
    number = call("show")["window"]
    call("hover", "on")
    time.sleep(0.9)
    ran = subprocess.run([str(shot), str(pid), str(number), str(path)], capture_output=True, text=True)
    call("hover", "off")
    call("hide")
    print("  ", ran.stdout.strip(), ran.stderr.strip()[-300:])
    return path.exists()


def colours(path, kind, at, start, end):
    pixels = vd.tool("pixels", "EdgePixels.swift")
    said = subprocess.run([str(pixels), kind, str(path), str(at), str(start), str(end)], capture_output=True, text=True).stdout.split()
    line = []
    for run in said:
        place, rest = run.split(":")
        hexed, count = rest.split("x")
        line += [tuple(int(hexed[i:i + 2], 16) for i in (0, 2, 4))] * int(count)
    return line


def reach(line, ground):
    apart = [i for i, c in enumerate(line) if max(abs(a - b) for a, b in zip(c, ground)) > 14]
    return apart[-1] - apart[0] + 1 if apart else 0


def measure(path, width, left):
    picture = subprocess.run(["sips", "-g", "pixelWidth", str(path)], capture_output=True, text=True).stdout.split()[-1]
    k = int(picture) / width
    x0 = (INSET if left else width - INSET - CIRCLE) * k
    y0 = INSET * k
    side = CIRCLE * k
    middle_x, middle_y = round(x0 + side / 2), round(y0 + side / 2)
    margin = round(6 * k)
    edge = round(STAGE * k)
    if left:
        across = colours(path, "row", middle_y, edge, round(x0 + side + margin))
        ground = across[-1]
    else:
        across = colours(path, "row", middle_y, round(x0 - margin), round((width - STAGE) * k))
        ground = across[0]
    down = colours(path, "column", middle_x, edge, round(y0 + side + margin))
    return reach(across, ground) / k, reach(down, down[-1]) / k


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".context/call-corner")
    out.mkdir(parents=True, exist_ok=True)
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    launch_shown()
    try:
        idle = sv.page("idle")
        for name, query, tiles in CASES:
            page = sv.page("call?" + query)
            sv.cmd({"do": "select", "id": page})
            t.ok(f"{name}: the call starts", until(lambda: sv.ev(page, "window.state") == "started"), sv.ev(page, "window.state"))
            call("tiles", tiles)
            sv.cmd({"do": "select", "id": idle})
            t.ok(f"{name}: floats", until(lambda: call()["showing"]), call())
            time.sleep(1.5)
            path = out / f"{name}.png"
            shot = shoot(path)
            t.ok(f"{name}: shot", shot)
            width = call()["width"]
            for key, left in (("Back to Tab", True), ("Close", False)):
                if not shot:
                    break
                wide, tall = measure(path, width, left)
                t.ok(f"{name}: {key} is as tall as it is wide", wide >= CIRCLE - 1 and abs(wide - tall) <= 1, (wide, tall))
            call("return")
            until(lambda: not call()["showing"])
            sv.ev(page, "end(), 1")
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

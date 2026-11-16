#!/usr/bin/env python3
"""A floating call shows only the people: the site's own chrome goes while it floats.

Build first (`./build.sh`), then `python3 Tests/call_tiles.py [OUT]`. A fake Meet
page (a header, a toolbar with Meet's aria labels, a side panel, a toast,
captions and a grid of participant tiles) floats; the probe checks what is
visible with tiles on and off, shoots the float both ways into OUT (default
.context/call-tiles) and checks Meet's own UI comes back when the call lands.
"""
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import visual_diff as vd  # noqa: E402

sv.use("page-call-tiles")
t = sv.T()

MEET = r"""<!doctype html><title>Weekly sync - Meet</title><style>
html, body { margin: 0; height: 100%; background: #202124; color: #e8eaed; font: 14px system-ui; overflow: hidden; }
.app { position: absolute; inset: 0; display: flex; flex-direction: column; transform: translateZ(0); }
header { height: 48px; display: flex; align-items: center; gap: 12px; padding: 0 16px; }
header .grow { flex: 1; }
header button, .bar button { border: 0; border-radius: 20px; background: #3c4043; color: #e8eaed; height: 36px; min-width: 36px; }
.middle { flex: 1; display: flex; min-height: 0; }
.stage { flex: 1; position: relative; padding: 8px; }
.grid { position: absolute; inset: 8px; display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 8px; }
.tile { position: relative; border-radius: 10px; overflow: hidden; background: #3c4043; display: flex; align-items: center; justify-content: center; }
.tile video { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; }
.tile .face { width: 64px; height: 64px; border-radius: 32px; display: flex; align-items: center; justify-content: center; font-size: 28px; color: #fff; }
.tile .name { position: absolute; left: 10px; bottom: 8px; font-weight: 500; text-shadow: 0 1px 2px #000; }
.tile .more { position: absolute; right: 8px; top: 8px; border: 0; border-radius: 14px; background: #0008; color: #fff; }
aside { width: 220px; background: #fff; color: #202124; border-radius: 8px; margin: 8px; padding: 12px; }
.bar { height: 72px; display: flex; align-items: center; justify-content: center; gap: 10px; }
.bar .leave { background: #ea4335; width: 56px; }
.toast { position: fixed; left: 16px; bottom: 90px; background: #e8eaed; color: #202124; padding: 10px 14px; border-radius: 6px; }
.captions { position: absolute; left: 20%; right: 20%; bottom: 84px; background: #000c; padding: 8px; border-radius: 6px; }
</style>
<div class=app>
  <header role=banner><span>10:24</span><span>Weekly sync</span><span class=grow></span>
    <button aria-label="Meeting details">i</button><button aria-label="Show everyone">5</button><button aria-label="Annotate">&#9998;</button></header>
  <div class=middle>
    <div class=stage><div class=grid>
      <div class=tile data-participant-id="spaces/a/devices/1"><video id=v1 autoplay muted playsinline></video><span class=name>You</span><button class=more aria-label="More options for You">&#8942;</button></div>
      <div class=tile data-participant-id="spaces/a/devices/2"><video id=v2 autoplay muted playsinline></video><span class=name>Ana Lima</span><button class=more aria-label="More options for Ana Lima">&#8942;</button></div>
      <div class=tile data-participant-id="spaces/a/devices/3"><div class=face style="background:#1e8e3e">B</div><span class=name>Ben Okafor</span></div>
      <div class=tile data-participant-id="spaces/a/devices/4"><div class=face style="background:#a142f4">C</div><span class=name>Chloe Park</span></div>
      <div class=tile data-participant-id="spaces/a/devices/5"><div class=face style="background:#e37400">D</div><span class=name>Dev Rao</span></div>
      <div class="tile others"><span class=name>3 others</span></div>
    </div>
    <div class=captions role=region aria-label="Captions">Ana Lima: let's look at the numbers</div></div>
    <aside role=complementary aria-label="People">People<br>Ana Lima<br>Ben Okafor</aside>
  </div>
  <div class=bar role=toolbar aria-label="Call controls">
    <button aria-label="Ask Gemini">&#10022;</button>
    <button aria-label="Turn off microphone" data-is-muted=false onclick="this.dataset.isMuted = this.dataset.isMuted === 'false' ? 'true' : 'false'">m</button>
    <button aria-label="Turn off camera" data-is-muted=false>c</button>
    <button aria-label="More options">&#8943;</button>
    <button class=leave aria-label="Leave call" onclick="end()">x</button>
  </div>
</div>
<div class=toast role=alert>Ana Lima joined</div>
<script>
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => {
  window.stream = s; window.state = 'started';
  v1.srcObject = s; v2.srcObject = s;
}).catch(e => { window.state = 'error ' + e.name; });
window.end = () => { stream.getTracks().forEach(x => x.stop()); };
window.seen = sel => { const el = document.querySelector(sel); if (!el) return 'missing';
  return getComputedStyle(el).visibility === 'visible' && el.getClientRects().length > 0 ? 'shown' : 'hidden'; };
window.box = sel => { const r = document.querySelector(sel).getBoundingClientRect();
  return [Math.round(r.left), Math.round(r.top), Math.round(r.right - innerWidth), Math.round(r.bottom - innerHeight)].join(','); };
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        html = MEET if name == "meet" else "<!doctype html><title>idle</title><p>idle</p>"
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H

CHROME = {
    "the header": "header",
    "the toolbar": "[aria-label='Call controls']",
    "the side panel": "aside",
    "the toast": "[role=alert]",
    "the captions": "[aria-label=Captions]",
    "a tile's own menu": ".tile .more",
}
PEOPLE = {
    "a video tile": "[data-participant-id='spaces/a/devices/2']",
    "a name": "[data-participant-id='spaces/a/devices/3'] .name",
    "the others tile": ".others",
    "a video": "#v1",
}


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
    shot = vd.tool("shot", "WindowShot.swift")
    pid = next(iter(sv.holding() & sv.running()))
    number = call("show")["window"]
    time.sleep(0.8)
    ran = subprocess.run([str(shot), str(pid), str(number), str(path)], capture_output=True, text=True)
    call("hide")
    print("  ", ran.stdout.strip(), ran.stderr.strip()[-300:])
    return path.exists()


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".context/call-tiles")
    out.mkdir(parents=True, exist_ok=True)
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    launch_shown()
    try:
        idle = sv.page("idle")
        meet = sv.page("meet")
        sv.cmd({"do": "select", "id": meet})
        t.ok("the call starts", until(lambda: sv.ev(meet, "window.state") == "started"), sv.ev(meet, "window.state"))
        t.ok("in the tab, Meet's UI is all there", all(sv.ev(meet, f"seen({s!r})") == "shown" for s in CHROME.values()))

        call("tiles", "off")
        sv.cmd({"do": "select", "id": idle})
        t.ok("leaving the tab floats it", until(lambda: call()["showing"]), call())
        time.sleep(1.5)
        t.ok("with tiles off the page is untouched", sv.ev(meet, "document.documentElement.hasAttribute('data-broadway-tiles')") is False)
        t.ok("shot before", shoot(out / "float-before.png"))

        call("tiles", "on")
        t.ok("with tiles on the page is marked", until(lambda: sv.ev(meet, "document.documentElement.hasAttribute('data-broadway-tiles')") is True))
        time.sleep(0.6)
        for name, sel in CHROME.items():
            t.ok(f"{name} is hidden", sv.ev(meet, f"seen({sel!r})") == "hidden", sv.ev(meet, f"seen({sel!r})"))
        for name, sel in PEOPLE.items():
            t.ok(f"{name} shows", sv.ev(meet, f"seen({sel!r})") == "shown", sv.ev(meet, f"seen({sel!r})"))
        above = "[...document.querySelectorAll('.tile')].every(el => { const r = el.getBoundingClientRect(), k = innerWidth / 340; " \
            "return r.left >= 8 * k - 1 && r.right <= innerWidth - 8 * k + 1 && r.top >= 8 * k - 1 && r.bottom <= innerHeight - 58 * k + 1; })"
        t.ok("the tiles fit the float above its call bar", sv.ev(meet, above) is True, sv.ev(meet, "box('.grid')"))
        state = call()
        t.ok("Broadway's own controls stay", state["leaves"] is True and state["mic"] is True, state)
        t.ok("shot after", shoot(out / "float-after.png"))
        sv.ev(meet, "document.querySelector('.grid').insertAdjacentHTML('beforeend', '<div class=tile data-participant-id=\"spaces/a/devices/9\"><span class=name>Eve</span></div>'), 1")
        sv.ev(meet, "document.body.insertAdjacentHTML('beforeend', '<div role=alert class=late>Eve joined</div>'), 1")
        t.ok("someone joining keeps the grid", until(lambda: sv.ev(meet, "seen('[data-participant-id=\"spaces/a/devices/9\"]')") == "shown"))
        t.ok("a late toast stays hidden", sv.ev(meet, "seen('.late')") == "hidden", sv.ev(meet, "seen('.late')"))

        call("mute")
        t.ok("mute still presses Meet's hidden button", until(lambda: call()["mic"] is False), call())

        call("return")
        t.ok("go to tab lands it", until(lambda: not call()["showing"]), call())
        t.ok("Meet's UI comes back at once", until(lambda: sv.ev(meet, "document.documentElement.hasAttribute('data-broadway-tiles')") is False, within=2))
        t.ok("no marks are left", sv.ev(meet, "document.querySelectorAll('[data-broadway-tiles-grid],[data-broadway-tiles-path],[data-broadway-tiles-chrome],#broadway-call-tiles').length") == 0)
        for name, sel in CHROME.items():
            t.ok(f"{name} is back", sv.ev(meet, f"seen({sel!r})") == "shown", sv.ev(meet, f"seen({sel!r})"))
        t.ok("the grid is back in its place", sv.ev(meet, "box('.grid')") != "0,0,0,0", sv.ev(meet, "box('.grid')"))
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

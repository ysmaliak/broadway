#!/usr/bin/env python3
"""A call keeps a small floating window when you leave its tab, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/call_float.py`. The camera and
microphone are WebKit's pretend ones. The panel opens off every screen on a
test run. Two call pages: one with Meet-shaped buttons, one with none, which
falls back to WebKit's own mute.
"""
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-call")
t = sv.T()

CALL = r"""<!doctype html><title>call</title><script>
window.state = 'starting';
window.pressed = [];
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => { window.stream = s; window.state = 'started'; })
  .catch(e => { window.state = 'error ' + e.name; });
window.end = () => { stream.getTracks().forEach(x => x.stop()); };
</script>"""
BUTTONS = r"""<button id=m aria-label="Turn off microphone" data-is-muted=false
 onclick="pressed.push('mic'); this.dataset.isMuted = this.dataset.isMuted === 'false' ? 'true' : 'false'">m</button>
<button aria-label="Leave call" onclick="pressed.push('leave'); end()">x</button>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        html = CALL + (BUTTONS if name == "meet" else "")
        if name == "idle":
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


def call(action="state", *values):
    return sv.cmd({"do": "call", "action": action, "values": list(values)})


def until(check, within=6):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def main():
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    sv.launch()
    try:
        idle = sv.page("idle")
        meet = sv.page("meet")
        sv.cmd({"do": "select", "id": meet})
        t.ok("the call starts", until(lambda: sv.ev(meet, "window.state") == "started"), sv.ev(meet, "window.state"))
        t.ok("in front, nothing floats", not call()["showing"], call())
        sv.cmd({"do": "magnify", "id": meet, "zoom": 1.25})

        sv.cmd({"do": "select", "id": idle})
        t.ok("leaving the tab floats it", until(lambda: call()["showing"]), call())
        state = call()
        t.ok("it is the call's tab", state["tab"].startswith(meet.lower()[:8]), state)
        t.ok("off every screen on a test run", state["x"] < -10000, state)
        t.ok("the page is in the panel", state["inPanel"], state)
        kept = next(x for x in sv.sp("state")["tabs"] if x["id"] == meet)
        t.ok("the page does not take the keys", not kept["hasKeys"], kept)
        t.ok("the page is smaller", state["zoom"] < 1, state)
        t.ok("the site's own mic shows", until(lambda: call()["mic"] is True), call())
        t.ok("WebKit's camera shows", call()["camera"] is True, call())
        t.ok("the site lets us leave", call()["leaves"] is True, call())

        call("mute")
        t.ok("mute presses the site's button", until(lambda: "mic" in sv.ev(meet, "pressed.join()")))
        t.ok("the site's state follows", until(lambda: call()["mic"] is False), call())
        call("key", "d")
        t.ok("command-D presses it too", until(lambda: sv.ev(meet, "pressed.length") == 2))
        call("camera")
        t.ok("the camera mutes with WebKit where the site has no button", until(lambda: call()["camera"] is False), call())
        call("camera")
        t.ok("and comes back", until(lambda: call()["camera"] is True), call())

        call("return")
        t.ok("go to tab lands it", until(lambda: not call()["showing"]), call())
        active = sv.cmd({"do": "tabs"})
        t.ok("the call's tab is in front", any(x["id"] == meet and x.get("active") for x in active["tabs"]), active)
        t.ok("the tab's own zoom is back", until(lambda: abs(call()["zoom"] - 1.25) < 0.001), call())
        sv.cmd({"do": "magnify", "id": meet, "zoom": 1.0})
        t.ok("the call goes on", sv.ev(meet, "stream.active") is True)

        call("close")
        tabs = sv.cmd({"do": "tabs"})["tabs"]
        t.ok("command-W asks first on a call", any(x["id"] == meet for x in tabs), tabs)

        sv.cmd({"do": "select", "id": idle})
        t.ok("floats again", until(lambda: call()["showing"]), call())
        call("leave")
        t.ok("leave presses the site's button", until(lambda: "leave" in sv.ev(meet, "pressed.join()")))
        t.ok("the call ended, the window goes", until(lambda: not call()["showing"], within=8), call())

        plain = sv.page("plain")
        sv.cmd({"do": "select", "id": plain})
        t.ok("a call with no buttons starts", until(lambda: sv.ev(plain, "window.state") == "started"))
        sv.cmd({"do": "select", "id": idle})
        t.ok("it floats too", until(lambda: call()["showing"]), call())
        t.ok("WebKit's microphone shows", until(lambda: call()["mic"] is True), call())
        t.ok("no leave button without the site's", call()["leaves"] is False, call())
        call("mute")
        t.ok("WebKit mutes it", until(lambda: call()["mic"] is False), call())
        sv.cmd({"do": "call", "action": "global"})
        t.ok("the global mute unmutes it from anywhere", until(lambda: call()["mic"] is True), call())

        sv.ev(plain, "end(), 1")
        t.ok("ended by the page, the window goes", until(lambda: not call()["showing"], within=8), call())
        t.ok("and the page is out of the panel", not call()["inPanel"], call())
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

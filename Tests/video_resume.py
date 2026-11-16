#!/usr/bin/env python3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("video-resume")

PAGE = """<!doctype html><title>clip</title>
<video id=v muted playsinline style="width:640px;height:360px;background:#222"></video>
<a id=same href="">same</a>
<script>
function clip(seconds) {
  var r = 8000, n = r * seconds, b = new ArrayBuffer(44 + n * 2), d = new DataView(b);
  function s(o, t) { for (var i = 0; i < t.length; i++) d.setUint8(o + i, t.charCodeAt(i)) }
  s(0, 'RIFF'); d.setUint32(4, 36 + n * 2, true); s(8, 'WAVEfmt '); d.setUint32(16, 16, true);
  d.setUint16(20, 1, true); d.setUint16(22, 1, true); d.setUint32(24, r, true); d.setUint32(28, r * 2, true);
  d.setUint16(32, 2, true); d.setUint16(34, 16, true); s(36, 'data'); d.setUint32(40, n * 2, true);
  return URL.createObjectURL(new Blob([b], { type: 'audio/wav' }));
}
var v = document.getElementById('v');
window.swap = function (seconds) { v.src = clip(seconds); };
document.getElementById('same').href = location.href;
window.seeks = 0;
v.addEventListener('seeking', function () { window.seeks++; });
if (location.search.indexOf('self') >= 0) {
  v.addEventListener('loadedmetadata', function () {
    var kept = +localStorage.getItem('at');
    if (kept) v.currentTime = kept;
  });
  addEventListener('pagehide', function () { localStorage.setItem('at', String(v.currentTime)); });
}
v.src = clip(+(new URLSearchParams(location.search).get('len') || 60));
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
V = "document.querySelector('video')"

t = sv.T()


def ev(js):
    return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")


def ready():
    for _ in range(40):
        if ev(f"!!{V} && {V}.readyState > 0 && isFinite({V}.duration)"):
            return True
        time.sleep(0.25)
    return False


def at():
    return ev(f"{V} ? {V}.currentTime : -1")


def go(url):
    sv.cmd({"do": "go", "id": tab, "url": url})
    sv.cmd({"do": "wait", "id": tab, "seconds": 15})
    ready()


def played_to(second):
    ev(f"{V}.muted = true; {V}.play(); 1")
    time.sleep(1.5)
    ev(f"{V}.currentTime = {second}; 1")
    time.sleep(2.5)
    ev(f"{V}.pause(); 1")
    time.sleep(0.5)
    return at()


def reload():
    ev("location.reload(); 1")
    time.sleep(1)
    sv.cmd({"do": "wait", "id": tab, "seconds": 15})
    ready()
    time.sleep(2.5)


try:
    sv.setup()
    sv.launch()
    tab = sv.page("a")
    sv.cmd({"do": "select", "id": tab})

    go(f"{BASE}/clip")
    left = played_to(30)
    t.ok("the clip plays and is put at 30 s", 30 <= left < 34, left)
    reload()
    back = at()
    t.ok("reloaded: back where it was", abs(back - left) < 1.5, back)
    time.sleep(5)
    t.ok("reloaded: and still there five seconds on", abs(at() - left) < 1.5, at())
    t.ok("reloaded: one seek, Broadway's", ev("window.seeks") == 1, ev("window.seeks"))

    reload()
    t.ok("reloaded again: back where it was again", abs(at() - left) < 1.5, at())

    ev("document.getElementById('same').click(); 1")
    time.sleep(1)
    sv.cmd({"do": "wait", "id": tab, "seconds": 15})
    ready()
    time.sleep(2.5)
    t.ok("the same address from a link: from the start", at() < 1, at())

    played_to(5)
    reload()
    t.ok("five seconds in: a reload starts from the start", at() < 1, at())

    go(f"{BASE}/clip?self")
    left = played_to(40)
    reload()
    t.ok("a page that resumes itself: where it put it", abs(at() - left) < 1.5, at())
    t.ok("a page that resumes itself: only its own seek", ev("window.seeks") == 1, ev("window.seeks"))

    go(f"{BASE}/clip?first")
    ev(f"{V}.muted = true; {V}.play(); 1")
    time.sleep(1.5)
    ev(f"{V}.currentTime = 45; 1")
    time.sleep(1)
    ev("history.pushState({}, '', '/clip?len=40&next'); 1")
    time.sleep(3)
    ev("swap(40); 1")
    ready()
    left = played_to(20)
    reload()
    t.ok("a shorter video after a longer one at the same address: back where it was", ev(f"{V}.duration") < 41 and abs(at() - left) < 1.5, f"{left} -> {at()}")

    go(f"{BASE}/clip?sleep")
    left = played_to(25)
    other = sv.page("b")
    sv.cmd({"do": "select", "id": other})
    time.sleep(1)
    said = sv.cmd({"do": "sleep", "id": tab})
    t.ok("put to sleep", said.get("asleep") is True, said)
    sv.cmd({"do": "select", "id": tab})
    time.sleep(1)
    sv.cmd({"do": "wait", "id": tab, "seconds": 15})
    ready()
    time.sleep(2.5)
    t.ok("woken: back where it was", abs(at() - left) < 1.5, at())

    sv.cmd({"do": "go", "id": tab, "url": "https://www.youtube.com/watch?v=aqz-KE-bpKQ"})
    sv.cmd({"do": "wait", "id": tab, "seconds": 25})
    time.sleep(5)
    if ready():
        ev(f"{V}.muted = true; {V}.play(); 1")
        time.sleep(3)
        ev(f"{V}.currentTime = 80; 1")
        time.sleep(6)
        ev(f"{V}.pause(); 1")
        time.sleep(1)
        left = at()
        ev("location.reload(); 1")
        time.sleep(2)
        sv.cmd({"do": "wait", "id": tab, "seconds": 25})
        ready()
        time.sleep(4)
        first = at()
        time.sleep(5)
        t.ok("YouTube reloaded: back where it was, and still there", abs(first - left) < 3 and abs(at() - left) < 3, f"{left} -> {first} -> {at()}")
        ev(f"{V}.muted = true; {V}.play(); 1")
        time.sleep(3)
        t.ok("YouTube reloaded: plays on from there", at() > left, at())
    else:
        print("  skip  YouTube didn't load")
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)

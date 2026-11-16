#!/usr/bin/env python3
"""A page playing sound stops the moment its tab leaves, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/closed_audio.py` from a
worktree. Each local page plays a quiet looping tone, a <video> with sound or
a WebAudio oscillator, and while it plays it calls the probe's own server
four times a second with the media clock. The tab is then closed one way or
another: Close Tab as ⌘W and the row's cross ask for it, a tab in a group put
away, a pin put down, one page of a split pair and both, a page floating in
the small window, Close Tabs Below, Close Group, Close Other Tabs, the last
tab in the row, the window, and a tab put to sleep. A page still calling
afterwards is still playing. ⌘Z then brings the last closed tab back, as
Safari's Undo Close Tab does, and it comes back silent.
"""
import math
import struct
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("closed-audio")
t = sv.T()


def tone():
    rate, seconds = 22050, 2
    frames = b"".join(struct.pack("<h", int(24 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(rate * seconds))
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return head + b"data" + struct.pack("<I", len(frames)) + frames


TONE = tone()
PAGE = r"""<!doctype html><title>%(name)s</title><body>
<video id=v loop playsinline src="/tone.wav" width=320 height=180></video><script>
const name = %(json)s, kind = %(kind)s;
let ctx = null, last = -1;
window.start = () => {
  if (kind === 'osc') {
    ctx = new AudioContext();
    const o = ctx.createOscillator(), g = ctx.createGain();
    g.gain.value = 0.002; o.connect(g).connect(ctx.destination); o.start();
    return ctx.resume().then(() => ctx.state);
  }
  const v = document.getElementById('v'); v.volume = 0.05;
  if (kind === 'picture') {
    const c = document.createElement('canvas'); c.width = 320; c.height = 180;
    const g = c.getContext('2d'); let n = 0;
    setInterval(() => { g.fillStyle = 'hsl(' + (n++ * 7 %% 360) + ',70%%,50%%)'; g.fillRect(0, 0, 320, 180); }, 40);
    ctx = new AudioContext();
    const o = ctx.createOscillator(), q = ctx.createGain(), out = ctx.createMediaStreamDestination();
    q.gain.value = 0.002; o.connect(q).connect(out); o.start();
    v.removeAttribute('src');
    v.srcObject = new MediaStream([...c.captureStream(25).getVideoTracks(), ...out.stream.getAudioTracks()]);
  }
  return v.play().then(() => 'playing', e => 'error ' + e.name);
};
window.clock = () => kind === 'osc' ? (ctx && ctx.state === 'running' ? ctx.currentTime : -1)
  : (document.getElementById('v').paused ? -1 : document.getElementById('v').currentTime);
setInterval(() => {
  const now = clock();
  if (now >= 0 && now !== last) fetch('/beat?name=' + name + '&t=' + now).catch(() => {});
  last = now;
}, 250);
</script>"""

beats = {}
lock = threading.Lock()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/beat":
            name = parse_qs(url.query).get("name", [""])[0]
            with lock:
                beats.setdefault(name, []).append(time.time())
            body, kind = b"", "text/plain"
        elif url.path == "/tone.wav":
            body, kind = TONE, "audio/wav"
        else:
            name = url.path.strip("/")
            osc = name.startswith("osc")
            shape = "'osc'" if osc else "'picture'" if name.startswith("media-float") else "'media'"
            body = (PAGE % {"name": name, "json": '"%s"' % name, "kind": shape}).encode()
            kind = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def until(check, within=6):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def recent(name, seconds=1.5):
    with lock:
        return [b for b in beats.get(name, []) if b > time.time() - seconds]


def page(name):
    id = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
    sv.cmd({"do": "wait", "id": id, "seconds": 10})
    return id


def ev(id, js, window=None):
    return sv.cmd({"do": "eval", "id": id, "js": js, **({"window": window} if window else {})}).get("value")


def play(id, name, window=None):
    ev(id, "start(), 1", window)
    playing = until(lambda: len(recent(name)) >= 2)
    if not playing:
        ev(id, "start(), 1", window)
        playing = until(lambda: len(recent(name)) >= 2)
    t.ok(f"{name} plays", playing, ev(id, "String(clock())", window))
    return playing


def silent(name, how):
    time.sleep(2.5)
    left = recent(name, 1.5)
    t.ok(f"{how}: {name} is silent", not left, f"{len(left)} calls in the last 1.5s")
    kept = [v for v in sv.cmd({"do": "lingering"})["views"] if v["url"].endswith("/" + name)]
    t.ok(f"{how}: {name}'s page is closed", not [v for v in kept if v["playing"] or v["process"] != 0], kept)


def ids():
    return [x["id"] for x in sv.sp("state")["tabs"]]


def case_close_tab():
    """Close Tab, as ⌘W and the row's cross ask for it"""
    for name in ("media-w", "osc-w"):
        sv.page("rest")
        id = page(name)
        play(id, name)
        sv.sp("closeTab", id=id)
        t.ok(f"{name}: the tab is gone", id not in ids())
        silent(name, "Close Tab")


def case_behind():
    """a tab closed from behind, while another is in front"""
    name = "media-behind"
    id = page(name)
    play(id, name)
    front = page("front")
    sv.sp("select", id=front)
    sv.sp("closeTab", id=id)
    silent(name, "closed from behind")


def case_last():
    """the only tab in the window"""
    for x in ids():
        sv.sp("close", id=x)
    name = "media-last"
    id = page(name)
    for x in ids():
        if x != id:
            sv.sp("close", id=x)
    play(id, name)
    sv.sp("closeTab", id=id)
    silent(name, "the last tab")


def case_group():
    """a tab in a group, put away"""
    name = "media-group"
    sv.page("rest")
    id = page(name)
    sv.cmd({"do": "group", "id": id, "new": True, "name": "Work"})
    sv.cmd({"do": "group", "name": "Work", "pinned": True})
    time.sleep(0.4)
    play(id, name)
    sv.sp("closeTab", id=id)
    row = next((x for x in sv.sp("state")["tabs"] if x["id"] == id), None)
    t.ok("the grouped tab stays in the row", row is not None)
    silent(name, "put away in a group")
    name = "media-groupclose"
    id = page(name)
    sv.cmd({"do": "group", "id": id, "name": "Work"})
    play(id, name)
    sv.cmd({"do": "group", "close": True, "name": "Work"})
    silent(name, "Close Group")


def case_pin():
    """a pinned tab, put down"""
    name = "osc-pin"
    sv.page("rest")
    id = page(name)
    sv.cmd({"do": "pin", "id": id})
    play(id, name)
    sv.sp("closeTab", id=id)
    silent(name, "a pin put down")


def case_split():
    """a page of a split pair, then both"""
    a, b = "media-left", "osc-right"
    x, y = page(a), page(b)
    play(x, a)
    play(y, b)
    sv.sp("pair", id=x, **{"with": y}, side="left")
    time.sleep(1)
    sv.sp("closeTab", id=x)
    silent(a, "one page of a pair")
    c = page("media-pair")
    play(c, "media-pair")
    sv.sp("pair", id=c, **{"with": y}, side="left")
    time.sleep(1)
    sv.sp("select", id=y)
    sv.sp("closeBoth")
    silent("media-pair", "Close Both")
    silent(b, "Close Both")


def case_float():
    """a page in the small floating window"""
    name = "media-float"
    id = page(name)
    sv.sp("select", id=id)
    play(id, name)
    floated = sv.cmd({"do": "floataway"})
    t.ok("its video floats", floated.get("floating") is True, floated)
    sv.sp("closeTab", id=id)
    silent(name, "floating")
    name = "media-floatbehind"
    id = page(name)
    sv.sp("select", id=id)
    play(id, name)
    sv.cmd({"do": "floataway"})
    sv.sp("select", id=page("front3"))
    sv.sp("closeTab", id=id)
    silent(name, "floating, closed from behind")


def case_below():
    """Close Tabs Below and Close Other Tabs"""
    top = page("top")
    names = ["media-below1", "osc-below2"]
    for name in names:
        play(page(name), name)
    sv.cmd({"do": "closebelow", "id": top})
    for name in names:
        silent(name, "Close Tabs Below")
    name = "media-other"
    play(page(name), name)
    sv.sp("closeOthers", id=top)
    silent(name, "Close Other Tabs")


def case_sleep():
    """a tab put to sleep"""
    name = "media-sleep"
    id = page(name)
    play(id, name)
    sv.sp("select", id=page("front2"))
    said = sv.sp("sleep", id=id).get("sleepResult")
    t.ok("a playing tab is not put to sleep", said == "playing sound", said)
    sv.ev(id, "document.getElementById('v').pause(), 1")
    t.ok("paused, it goes quiet", until(lambda: not recent(name)))
    said = sv.sp("sleep", id=id).get("sleepResult")
    t.ok("then it sleeps", said == "asleep", said)


def case_undo():
    """⌘Z brings the last closed tab back, silent"""
    name = "osc-undo"
    id = page(name)
    play(id, name)
    sv.sp("closeTab", id=id)
    silent(name, "closed for undo")
    sv.sp("select", id=page("typing"))
    said = sv.cmd({"do": "undoclose"})
    t.ok("Edit › Undo says Undo Close Tab", said.get("title") == "Undo Close Tab", said)
    t.ok("the menu item itself reads Undo Close Tab", said.get("menuTitle") == "Undo Close Tab", said)
    t.ok("⌘Z is Edit › Undo, sent from the page in front", said.get("menuKey") == "z" and said.get("sent") is True, said)
    back = [x for x in sv.sp("state")["tabs"] if x["url"].endswith("/" + name)]
    t.ok("⌘Z brought it back", len(back) == 1, said)
    silent(name, "brought back")


def case_player():
    """a known player's page, floated on leaving and closed each way"""
    name = "media-player-w"
    id = page(name)
    play(id, name)
    sv.sp("closeTab", id=id)
    silent(name, "a player, Close Tab")
    name = "media-player-left"
    id = page(name)
    play(id, name)
    sv.sp("select", id=page("away"))
    time.sleep(1.5)
    sv.sp("closeTab", id=id)
    silent(name, "a player floated on leaving, closed from behind")
    name = "media-player-back"
    id = page(name)
    play(id, name)
    away = page("away2")
    time.sleep(1.5)
    sv.sp("select", id=id)
    time.sleep(1)
    sv.sp("closeTab", id=id)
    silent(name, "a player floated, gone back to, closed")


def case_window():
    """the window, closed with its tabs"""
    sv.cmd({"do": "windows", "action": "new"})
    time.sleep(1)
    name = "osc-window"
    id = sv.cmd({"do": "open", "url": f"{BASE}/{name}", "window": 2}).get("id")
    sv.cmd({"do": "wait", "id": id, "seconds": 10, "window": 2})
    play(id, name, 2)
    sv.cmd({"do": "windows", "action": "close", "n": 2})
    silent(name, "the window closed")


def main():
    cases = [case_close_tab, case_behind, case_last, case_group, case_pin, case_split,
             case_float, case_below, case_sleep, case_player, case_undo, case_window]
    only = sys.argv[1:]
    for case in cases:
        if only and case.__name__.removeprefix("case_") not in only:
            continue
        print(f"— {case.__doc__}")
        try:
            sv.setup(**{"tabs.groups": True, "sidebar": True, "splitView": True})
            sv.launch()
            sv.cmd({"do": "player", **({"url": BASE} if case is case_player else {})})
            case()
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

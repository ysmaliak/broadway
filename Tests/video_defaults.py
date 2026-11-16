#!/usr/bin/env python3
"""A default YouTube quality and a speed remembered per site
(VideoDefaults.swift), on local stand-ins, in a hidden probe.

Build first (`./build.sh debug`), then `python3 Tests/video_defaults.py`.
Needs ffmpeg for the test video. It runs in a world of its own
(video-defaults-<checkout>) with split_view.py's harness: started hidden,
driven through ./bench's socket, everything removed afterwards. No network.

The test settings make 127.0.0.1 one of YouTube's hosts for the run
(`test.youtubeHosts`); localhost, the same server under another name, is
"another site". The stand-in page has what YouTube's has: a
`.html5-video-player` with getAvailableQualityLevels, getPreferredQuality,
setPlaybackQualityRange and getVideoData, a `.ytp-quality-menu`, the next
video loaded into the same element without a page load, and its own speed
put back whenever a video is emptied. Presses are bench taps, delivered to
the view as mouse events: trusted, as a hand's are.
"""
import json
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("video-defaults")
VIDEO = b""

PAGE = """<!doctype html><meta charset=utf-8><title>watch</title>
<body style="margin:0">
<div id="__WRAP__" class="html5-video-player __CLASS__" style="width:640px">
<video id=video src="/clip.mp4?v=__ID__" preload=auto playsinline __ATTRS__ style="display:block;width:640px;height:240px"></video>
<div id=clock class="ytp-time-display"></div>
<div class="ytp-popup ytp-settings-menu"><div class="ytp-panel ytp-quality-menu"><div class="ytp-panel-menu">
<div class="ytp-menuitem" id=pick1080 data-q=hd1080 style="height:30px"><div class="ytp-menuitem-label">1080p60 HD</div></div>
<div class="ytp-menuitem" id=pickauto data-q=auto style="height:30px"><div class="ytp-menuitem-label">Auto</div></div>
</div></div></div>
</div>
<button id=fast style="height:30px">1.5</button> <button id=two style="height:30px">2</button>
<button id=normal style="height:30px">1</button> <button id=unmute style="height:30px">sound</button>
<script>
const q = new URLSearchParams(location.search);
const video = document.getElementById('video'), player = video.parentElement;
const all = [['hd2160', 2160], ['hd1440', 1440], ['hd1080', 1080], ['hd720', 720], ['large', 480], ['medium', 360], ['small', 240], ['tiny', 144]];
const levelsFor = max => all.filter(level => level[1] <= max).map(level => level[0]);
const kept = () => { try { return JSON.parse(JSON.parse(localStorage.getItem('yt-player-quality')).data).quality; } catch (e) { return null; } };
window.__yt = { id: q.get('v') || 'a', levels: levelsFor(+(q.get('max') || 2160)), preferred: 'auto', calls: [],
                own: +(q.get('own') || 1), stored: kept(), sets: [], told: [] };
player.getVideoData = () => ({ video_id: __yt.id });
player.getAvailableQualityLevels = () => video.readyState ? __yt.levels.concat(['auto']) : [];
player.getPreferredQuality = () => __yt.preferred;
player.setPlaybackQualityRange = (low, high) => { __yt.calls.push(high + '@' + __yt.id); __yt.preferred = high; };
player.getAvailablePlaybackRates = () => [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2];
player.getPlaybackRate = () => __yt.own;
player.setPlaybackRate = rate => { __yt.told.push(+rate); __yt.own = Math.min(Math.max(+rate, 0.25), 2); video.playbackRate = __yt.own; };
const reset = () => { __yt.sets.push(video.playbackRate + '>' + __yt.own); video.playbackRate = __yt.own; };
video.addEventListener('emptied', reset);
if (q.get('late')) video.addEventListener('loadeddata', () => setTimeout(reset, 400));
if (q.get('live') === 'now') document.getElementById('clock').classList.add('ytp-live');
if (q.get('live') === 'soon') video.addEventListener('loadeddata', () => setTimeout(() => { document.getElementById('clock').classList.add('ytp-live'); video.muted = true; video.play(); }, 500));
document.getElementById('fast').onclick = () => { video.playbackRate = 1.5; };
document.getElementById('two').onclick = () => { video.playbackRate = 2; };
document.getElementById('normal').onclick = () => { video.playbackRate = 1; };
document.getElementById('unmute').onclick = () => { video.muted = false; };
for (const item of document.querySelectorAll('.ytp-menuitem')) item.onclick = () => { __yt.preferred = item.dataset.q; };
window.next = (id, max) => { __yt.id = id; __yt.levels = levelsFor(max); __yt.preferred = 'auto'; video.src = '/clip.mp4?v=' + id; video.load(); return 0; };
window.own = () => { localStorage.setItem('yt-player-quality', JSON.stringify({ data: JSON.stringify({ quality: 720, previousQuality: 0 }),
                     expiration: Date.now() + 31104000000, creation: Date.now() })); return 0; };
window.report = () => ({ rate: video.playbackRate, calls: __yt.calls, preferred: __yt.preferred, stored: __yt.stored, now: kept(),
                         ready: video.readyState, id: __yt.id, sets: __yt.sets, muted: video.muted, own: __yt.own, told: __yt.told });
if (parent !== window) setInterval(() => parent.postMessage(report(), '*'), 300);
</script>"""


class H(BaseHTTPRequestHandler):
    def reply(self, body, kind="text/html", status=200, extra=()):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra: self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        port = self.server.server_port
        url = urlparse(self.path)
        ask = {key: values[0] for key, values in parse_qs(url.query).items()}
        if url.path == "/clip.mp4":
            start, end = 0, len(VIDEO) - 1
            header = self.headers.get("Range", "")
            partial = header.startswith("bytes=")
            if partial:
                first, _, last = header[6:].partition("-")
                start = int(first or 0)
                end = min(int(last), end) if last else end
            chunk = VIDEO[start:end + 1]
            self.reply(chunk, "video/mp4", 206 if partial else 200,
                       [("Accept-Ranges", "bytes")] + ([("Content-Range", f"bytes {start}-{end}/{len(VIDEO)}")] if partial else []))
        elif url.path == "/watch":
            attrs = " ".join(name for name in ("muted", "loop") if ask.get(name))
            page = (PAGE.replace("__WRAP__", ask.get("wrap", "movie_player")).replace("__CLASS__", ask.get("cls", ""))
                    .replace("__ID__", ask.get("v", "a")).replace("__ATTRS__", attrs))
            self.reply(page.encode())
        elif url.path == "/embedder":
            self.reply(f"""<!doctype html><title>embedder</title>
<script>addEventListener('message', function (e) {{ window.__frame = e.data; }});</script>
<iframe src="http://127.0.0.1:{port}/watch?v=framed" style="width:660px;height:360px"></iframe>""".encode())
        else:
            self.reply(b"", status=404)

    def log_message(self, *a): pass


def main():
    global VIDEO
    with tempfile.TemporaryDirectory(prefix="broadway-video-defaults-") as folder:
        clip = Path(folder, "clip.mp4")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
                        "-f", "lavfi", "-i", "sine=frequency=220", "-t", "60", "-c:v", "libx264", "-preset", "ultrafast",
                        "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", str(clip)], check=True)
        VIDEO = clip.read_bytes()
    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    tube = f"http://127.0.0.1:{port}"
    other = f"http://localhost:{port}"
    t = sv.T()

    def ev(tab, js):
        value = sv.cmd({"do": "eval", "id": tab, "js": f"JSON.stringify({js})"}).get("value")
        try: return json.loads(value)
        except (TypeError, ValueError): return value

    def until(read, good, within=8.0):
        got = None
        deadline = time.time() + within
        while time.time() < deadline:
            try: got = read()
            except RuntimeError: got = None
            if got is not None and good(got): return got
            time.sleep(0.2)
        return got

    def visit(url, private=False, wait=True):
        ask = {"do": "open", "url": url}
        if private: ask["private"] = True
        tab = sv.cmd(ask)["id"]
        if wait: until(lambda: ev(tab, "window.report && report()"), lambda r: r["ready"] >= 1, 12)
        return tab

    def report(tab): return ev(tab, "report()") or {}
    def rate(tab, wanted, within=6.0): return (until(lambda: report(tab), lambda r: r.get("rate") == wanted, within) or {}).get("rate")
    def calls(tab, wanted, within=6.0): return (until(lambda: report(tab), lambda r: r.get("calls") == wanted, within) or {}).get("calls")
    def settle(seconds=1.6): time.sleep(seconds)
    def tap(tab, selector):
        sv.cmd({"do": "select", "id": tab}); time.sleep(0.3)
        sv.cmd({"do": "tap", "id": tab, "selector": selector}); time.sleep(0.4)
    def settings(**ask): return sv.cmd({"do": "settings", **ask})
    def speeds(): return settings()["speeds"]
    def kept(site, wanted, within=4.0):
        return (until(speeds, lambda found: found.get(site) == wanted, within) or {}).get(site)

    try:
        sv.setup(**{"float.leave": False})
        subprocess.run(["defaults", "write", sv.SUITE, "test.youtubeHosts", "-array", "127.0.0.1"], check=True)
        sv.launch()
        sv.cmd({"do": "window"})

        found = settings()
        rows = {item["id"]: item for item in found["items"]}
        t.ok("Settings has both rows, in Video on Websites",
             all(rows.get(id, {}).get("group") == "video" and rows[id]["page"] == "websites" and not rows[id]["findOnly"]
                 for id in ("video.quality", "video.speed")), [rows.get("video.quality"), rows.get("video.speed")])
        t.ok("a new world lets the site decide the quality and remembers speed",
             found["values"].get("video.quality") == "site" and found["values"].get("video.speed") is True, found["values"])
        t.ok("Find a setting finds them by speed and by resolution",
             "video.speed" in [i["id"] for i in settings(find="speed")["found"]]
             and "video.quality" in [i["id"] for i in settings(find="resolution")["found"]])

        first = visit(f"{other}/watch?v=a")
        t.ok("a fresh video plays at 1x", rate(first, 1) == 1, report(first))
        tap(first, "#fast")
        t.ok("the site's own speed button sets 1.5x", rate(first, 1.5) == 1.5, report(first))
        t.ok("and it is kept for that site", kept("localhost", 1.5) == 1.5, speeds())
        second = visit(f"{other}/watch?v=b")
        t.ok("the site's next video opens at 1.5x", rate(second, 1.5) == 1.5, report(second))
        elsewhere = visit(f"{tube}/watch?v=a")
        settle()
        t.ok("a second site is untouched", report(elsewhere).get("rate") == 1 and "127.0.0.1" not in speeds(),
             (report(elsewhere), speeds()))
        t.ok("with the site deciding, the player's quality is never set",
             report(elsewhere).get("calls") == [] and report(elsewhere).get("stored") is None, report(elsewhere))

        ev(second, "next('c', 2160)")
        settle()
        again = report(second)
        t.ok("the next video without a page load opens at 1.5x, over the site's own reset",
             again.get("rate") == 1.5 and again.get("id") == "c" and len(again.get("sets", [])) == 1, again)
        late = visit(f"{other}/watch?v=late&late=1")
        settle(2.2)
        t.ok("a site that sets its own speed after the video loads is put back", report(late).get("rate") == 1.5
             and report(late).get("sets") == ["1.5>1"], report(late))
        ev(second, "(video.playbackRate = 2, 0)")
        settle(1)
        t.ok("a speed the page sets by itself is not remembered", speeds().get("localhost") == 1.5, speeds())
        ev(second, "(video.playbackRate = 1.5, 0)")

        muted = visit(f"{other}/watch?v=muted&muted=1")
        looping = visit(f"{other}/watch?v=loop&loop=1")
        advert = visit(f"{other}/watch?v=ad&cls=ad-showing")
        settle()
        t.ok("a silent video keeps its own speed", report(muted).get("rate") == 1, report(muted))
        t.ok("a looping clip keeps its own speed", report(looping).get("rate") == 1, report(looping))
        t.ok("an advert keeps its own speed", report(advert).get("rate") == 1, report(advert))
        tap(advert, "#two")
        settle(1)
        t.ok("a speed set on an advert is not remembered", speeds().get("localhost") == 1.5, speeds())
        tap(muted, "#unmute")
        t.ok("given its sound, the silent video takes the site's speed", rate(muted, 1.5) == 1.5, report(muted))
        for tab in (late, muted, looping, advert, elsewhere): sv.cmd({"do": "close", "id": tab})

        sv.cmd({"do": "select", "id": second}); time.sleep(0.4)
        sv.cmd({"do": "key", "id": second, "text": "f"})
        t.ok("Broadway's speed key steps to 1.6x", rate(second, 1.6) == 1.6, report(second))
        t.ok("and that is kept too", kept("localhost", 1.6) == 1.6, speeds())
        sv.cmd({"do": "key", "id": second, "text": "d"})
        t.ok("back to 1x is remembered as 1", rate(second, 1) == 1 and kept("localhost", 1) == 1, (report(second), speeds()))
        owned = visit(f"{other}/watch?v=own&own=1.25&late=1")
        settle(2.2)
        t.ok("and the next video opens at 1x, over a site that would pick 1.25", report(owned).get("rate") == 1
             and report(owned).get("sets") == ["1>1.25"], report(owned))
        sv.cmd({"do": "close", "id": owned})

        tap(second, "#fast")
        kept("localhost", 1.5)
        ev(second, "(video.muted = true, video.play(), 0)")
        time.sleep(1.2)
        floated = sv.cmd({"do": "floataway"})
        if floated.get("floating"):
            sv.cmd({"do": "float", "action": "hover", "value": "on"}); time.sleep(0.8)
            sv.cmd({"do": "float", "action": "press", "value": "speed"}); time.sleep(0.6)
            now = report(second).get("rate")
            t.ok("the floating video's speed pill steps the speed", now == 1.75, report(second))
            t.ok("and that is kept for the site", kept("localhost", 1.75) == 1.75, speeds())
            sv.cmd({"do": "float", "action": "toggle"}); time.sleep(1.2)
        else:
            t.ok("the video floats", False, floated)
        ev(second, "(video.pause(), video.muted = false, 0)")
        tap(second, "#fast")
        kept("localhost", 1.5)

        settings(set="video.speed", value=False)
        off = visit(f"{other}/watch?v=off")
        settle()
        t.ok("switched off, the next video opens at 1x", report(off).get("rate") == 1, report(off))
        tap(off, "#two")
        settle(1)
        t.ok("and nothing new is remembered", report(off).get("rate") == 2 and speeds().get("localhost") == 1.5,
             (report(off), speeds()))
        settings(set="video.speed", value=True)
        back = visit(f"{other}/watch?v=back")
        t.ok("switched on again, what was kept comes back", rate(back, 1.5) == 1.5, report(back))
        for tab in (off, back): sv.cmd({"do": "close", "id": tab})

        private = visit(f"{other}/watch?v=private", private=True)
        settle()
        t.ok("a private window takes no kept speed: its video opens at the site's own", report(private).get("rate") == 1,
             report(private))
        sv.cmd({"do": "tap", "id": private, "selector": "#two"}); time.sleep(0.4)
        took = rate(private, 2)
        settle(1)
        t.ok("and a speed set there leaves nothing behind", took == 2 and speeds() == {"localhost": 1.5}, (took, speeds()))
        sv.cmd({"do": "close", "id": private})

        watch = visit(f"{tube}/watch?v=sound")
        tap(watch, "#fast")
        kept("127.0.0.1", 1.5)
        quiet = visit(f"{tube}/watch?v=quiet&muted=1")
        live = visit(f"{tube}/watch?v=live&live=now")
        soon = visit(f"{tube}/watch?v=soon&live=soon")
        preview = visit(f"{tube}/watch?v=preview&muted=1&wrap=inline-player")
        t.ok("YouTube's own player takes the speed even muted", rate(quiet, 1.5) == 1.5, report(quiet))
        settle()
        t.ok("a live stream keeps its own speed", report(live).get("rate") == 1, report(live))
        t.ok("a stream found to be live once it plays gets its own speed back", rate(soon, 1) == 1, report(soon))
        t.ok("a muted preview player keeps its own speed", report(preview).get("rate") == 1, report(preview))
        t.ok("YouTube's player is told the kept speed, once", report(quiet).get("own") == 1.5 and report(quiet).get("told") == [1.5],
             report(quiet))
        t.ok("and told to go back when the stream turns out to be live", report(soon).get("told") == [1.5, 1], report(soon))
        t.ok("a player Broadway gave no speed is told nothing", report(live).get("told") == [] and report(preview).get("told") == [],
             (report(live), report(preview)))
        for tab in (quiet, live, soon, preview): sv.cmd({"do": "close", "id": tab})

        sv.cmd({"do": "select", "id": watch}); time.sleep(0.4)
        sv.cmd({"do": "key", "id": watch, "text": "f"})
        stepped = until(lambda: report(watch), lambda r: r.get("rate") == 1.6 and r.get("own") == 1.6, 6) or {}
        t.ok("Broadway's speed key on YouTube: the video and YouTube's player are both at 1.6x",
             stepped.get("rate") == 1.6 and stepped.get("own") == 1.6 and stepped.get("told") == [1.6], stepped)
        t.ok("and it is kept as his, once", kept("127.0.0.1", 1.6) == 1.6, speeds())
        ev(watch, "next('n2', 2160)")
        settle()
        carried = report(watch)
        t.ok("the next video opens at 1.6x by the player's own doing, with nothing to put back",
             carried.get("rate") == 1.6 and carried.get("id") == "n2" and carried.get("sets") == ["1.6>1.6"]
             and carried.get("told") == [1.6], carried)
        tap(watch, "#two")
        kept("127.0.0.1", 2)
        sv.cmd({"do": "key", "id": watch, "text": "f"})
        over = until(lambda: report(watch), lambda r: r.get("rate") == 2.1, 6) or {}
        t.ok("past the player's fastest, the video plays at Broadway's 2.1x and the player is held at its 2",
             over.get("rate") == 2.1 and over.get("own") == 2 and over.get("told") == [1.6, 2], over)
        t.ok("and 2.1 is what is kept", kept("127.0.0.1", 2.1) == 2.1, speeds())
        ev(watch, "next('n3', 2160)")
        settle()
        beyond = report(watch)
        t.ok("the next video is put back to 2.1x over the player's 2, and the player is not told again",
             beyond.get("rate") == 2.1 and beyond.get("own") == 2 and beyond.get("told") == [1.6, 2], beyond)
        tap(watch, "#fast")
        kept("127.0.0.1", 1.5)
        ev(watch, "(video.muted = true, video.play(), 0)")
        time.sleep(1.2)
        floated = sv.cmd({"do": "floataway"})
        if floated.get("floating"):
            sv.cmd({"do": "float", "action": "hover", "value": "on"}); time.sleep(0.8)
            sv.cmd({"do": "float", "action": "press", "value": "speed"}); time.sleep(0.6)
            pill = until(lambda: report(watch), lambda r: r.get("rate") == 1.75 and r.get("own") == 1.75, 4) or {}
            t.ok("the floating video's pill on YouTube: the video and the player are both at 1.75x",
                 pill.get("rate") == 1.75 and pill.get("own") == 1.75 and pill.get("told") == [1.6, 2, 1.75], pill)
            t.ok("and that is kept, once", kept("127.0.0.1", 1.75) == 1.75, speeds())
            sv.cmd({"do": "float", "action": "toggle"}); time.sleep(1.2)
        else:
            t.ok("the YouTube video floats", False, floated)
        ev(watch, "(video.pause(), video.muted = false, 0)")
        selling = visit(f"{tube}/watch?v=selling&cls=ad-showing")
        sv.cmd({"do": "select", "id": selling}); time.sleep(0.4)
        sv.cmd({"do": "key", "id": selling, "text": "f"})
        settle(1)
        t.ok("a speed key during an advert is not passed to YouTube's player", report(selling).get("told") == []
             and speeds().get("127.0.0.1") == 1.75, (report(selling), speeds()))
        framed = visit(f"{other}/embedder", wait=False)
        inside = until(lambda: ev(framed, "window.__frame"), lambda r: r.get("rate") == 1.5 and r.get("own") == 1.5, 10) or {}
        t.ok("YouTube's player embedded on another site takes that site's speed, and is told it",
             inside.get("rate") == 1.5 and inside.get("told") == [1.5], inside)
        for tab in (selling, framed): sv.cmd({"do": "close", "id": tab})

        sv.cmd({"do": "fieldrows", "args": ["forget"]})
        t.ok("Clear History forgets every site's speed", speeds() == {}, speeds())
        cleared = visit(f"{other}/watch?v=cleared")
        settle()
        t.ok("and the next video opens at 1x again", report(cleared).get("rate") == 1, report(cleared))
        tap(cleared, "#fast")
        t.ok("a speed set after that is kept as before", kept("localhost", 1.5) == 1.5, speeds())

        forgotten = settings(forget=True)["speeds"]
        t.ok("Forget Choices forgets every site's speed", forgotten == {}, forgotten)
        after = visit(f"{other}/watch?v=after")
        settle()
        t.ok("and the next video opens at 1x again", report(after).get("rate") == 1, report(after))
        for tab in (cleared, after, first, second, watch): sv.cmd({"do": "close", "id": tab})

        settings(set="video.quality", value="1440")
        hd = visit(f"{tube}/watch?v=q1")
        t.ok("1440p chosen: a fresh video opens at 1440p", calls(hd, ["hd1440@q1"]) == ["hd1440@q1"], report(hd))
        t.ok("and the player found that choice before it started", report(hd).get("stored") == 1440, report(hd))
        ev(hd, "next('q2', 1080)")
        t.ok("the next video without a page load: no 1440p, so the best below it",
             calls(hd, ["hd1440@q1", "hd1080@q2"]) == ["hd1440@q1", "hd1080@q2"], report(hd))
        ev(hd, "next('q3', 2160)")
        calls(hd, ["hd1440@q1", "hd1080@q2", "hd1440@q3"])
        tap(hd, "#pick1080")
        ev(hd, "(video.muted = true, video.play(), 0)")
        time.sleep(1.5)
        ev(hd, "(video.currentTime = 20, 0)")
        time.sleep(1.5)
        picked = report(hd)
        t.ok("a quality picked in the player lasts for that video", picked.get("preferred") == "hd1080"
             and picked.get("calls") == ["hd1440@q1", "hd1080@q2", "hd1440@q3"], picked)
        ev(hd, "(video.pause(), next('q4', 2160))")
        t.ok("and the video after it opens at 1440p again", (calls(hd, picked["calls"] + ["hd1440@q4"]) or [])[-1:] == ["hd1440@q4"], report(hd))

        behind = visit(f"{tube}/watch?v=behind", wait=False)
        front = visit(f"{tube}/watch?v=front", wait=False)
        sv.cmd({"do": "select", "id": front})
        t.ok("a video in a background tab opens at 1440p", calls(behind, ["hd1440@behind"], 10) == ["hd1440@behind"], report(behind))
        t.ok("and so does the one in front", calls(front, ["hd1440@front"], 10) == ["hd1440@front"], report(front))
        embed = visit(f"{other}/embedder", wait=False)
        framed = until(lambda: ev(embed, "window.__frame"), lambda r: r.get("calls") == ["hd1440@framed"], 10) or {}
        t.ok("YouTube's player embedded on another site opens at 1440p", framed.get("calls") == ["hd1440@framed"]
             and framed.get("stored") == 1440, framed)
        stranger = visit(f"{other}/watch?v=stranger")
        settle()
        t.ok("another site's player is left alone", report(stranger).get("calls") == [] and report(stranger).get("stored") is None,
             report(stranger))
        hidden = visit(f"{tube}/watch?v=hidden", private=True)
        t.ok("a private window opens at 1440p too", calls(hidden, ["hd1440@hidden"], 10) == ["hd1440@hidden"], report(hidden))
        for tab in (behind, front, embed, stranger): sv.cmd({"do": "close", "id": tab})

        settings(set="video.quality", value="last")
        t.ok("the quality picked in the player was noted", settings()["lastQuality"] == 1080, settings()["lastQuality"])
        sv.cmd({"do": "tap", "id": hidden, "selector": "#pickauto"}); time.sleep(0.6)
        t.ok("a pick in a private window is not", settings()["lastQuality"] == 1080, settings()["lastQuality"])
        sv.cmd({"do": "close", "id": hidden})
        last = visit(f"{tube}/watch?v=l1")
        t.ok("Last One I Picked: the next video opens at the 1080p picked", calls(last, ["hd1080@l1"]) == ["hd1080@l1"], report(last))
        apart = visit(f"{tube}/watch?v=apart", private=True)
        settle()
        t.ok("but not in a private window, which is left to YouTube", report(apart).get("calls") == []
             and report(apart).get("stored") is None, report(apart))
        sv.cmd({"do": "close", "id": apart})
        sv.cmd({"do": "fieldrows", "args": ["forget"]})
        t.ok("Clear History forgets the last pick", settings()["lastQuality"] == 0, settings()["lastQuality"])
        tap(last, "#pick1080")
        t.ok("a pick after that is noted again", until(lambda: settings()["lastQuality"], lambda v: v == 1080, 4) == 1080)
        tap(last, "#pickauto")
        t.ok("picking Auto in the player is a pick too", until(lambda: settings()["lastQuality"], lambda v: v == 0, 4) == 0)
        auto = visit(f"{tube}/watch?v=l2")
        settle()
        t.ok("and the next video is left to YouTube", report(auto).get("calls") == [], report(auto))
        for tab in (last, auto): sv.cmd({"do": "close", "id": tab})

        settings(set="video.quality", value="2160")
        time.sleep(1.1)
        settings(set="video.quality", value="site")
        freed = visit(f"{tube}/watch?v=free")
        settle()
        t.ok("back to Let YouTube Decide: nothing is set and the old choice is gone from the player's memory",
             report(freed).get("calls") == [] and report(freed).get("stored") is None, report(freed))
        ev(freed, "own()")
        own = visit(f"{tube}/watch?v=own")
        settle(1)
        t.ok("a quality YouTube keeps after that is its own to keep", report(own).get("stored") == 720, report(own))
        for tab in (hd, freed, own): sv.cmd({"do": "close", "id": tab})
    finally:
        t.done()
        sv.finish()
        server.shutdown()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

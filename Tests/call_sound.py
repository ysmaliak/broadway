#!/usr/bin/env python3
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import wave
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("call-sound")
WAITS = "media.click"
VIDEO = b""
PICTURE = b""
TONE = b""
CASES = ["audio stream", "audio file", "web audio", "video with sound", "video without sound", "video stream"]

PAGE = r"""<!doctype html><meta charset=utf-8><title>%s</title>
<audio id=af src=/tone.wav loop></audio>
<audio id=as></audio>
<video id=vs src=/v.mp4 loop playsinline width=120></video>
<video id=vm src=/p.mp4 loop playsinline width=120></video>
<video id=vr playsinline width=120></video>
<canvas id=c width=64 height=48></canvas>
<script>
const r = window.__r = {clicks: 0, cases: {}};
addEventListener('mousedown', () => r.clicks++, true);
addEventListener('keydown', () => r.clicks++, true);
async function play(name, el) {
  const o = r.cases[name] = {promise: 'pending', ev: []};
  for (const e of ['play', 'playing', 'pause']) el.addEventListener(e, () => o.ev.push(e));
  setTimeout(() => { o.paused = el.paused; o.time = el.currentTime; }, 2500);
  try { await el.play(); o.promise = 'ok'; } catch (e) { o.promise = e.name; }
}
async function remote(track) {
  const a = new RTCPeerConnection(), b = new RTCPeerConnection();
  a.onicecandidate = e => e.candidate && b.addIceCandidate(e.candidate);
  b.onicecandidate = e => e.candidate && a.addIceCandidate(e.candidate);
  const got = new Promise(res => b.ontrack = e => res(e.streams[0] || new MediaStream([e.track])));
  a.addTrack(track, new MediaStream([track]));
  await a.setLocalDescription(await a.createOffer()); await b.setRemoteDescription(a.localDescription);
  await b.setLocalDescription(await b.createAnswer()); await a.setRemoteDescription(b.localDescription);
  window.peers = (window.peers || []).concat([a, b]);
  return got;
}
setTimeout(async () => {
  r.at = Date.now();
  const $ = id => document.getElementById(id);
  play('audio file', $('af'));
  play('video with sound', $('vs'));
  play('video without sound', $('vm'));
  const ctx = new AudioContext();
  const w = r.cases['web audio'] = {first: ctx.state, resume: 'pending'};
  const osc = ctx.createOscillator(), gain = ctx.createGain();
  gain.gain.value = 0; osc.connect(gain).connect(ctx.destination); osc.start();
  ctx.resume().then(() => w.resume = 'ok', e => w.resume = e.name);
  setTimeout(() => { w.later = ctx.state; w.time = ctx.currentTime; }, 2500);
  try {
    const source = new AudioContext().createMediaStreamDestination();
    const voices = await remote(source.stream.getAudioTracks()[0]);
    $('as').srcObject = voices;
    play('audio stream', $('as'));
  } catch (e) { r.cases['audio stream'] = {promise: 'setup ' + e.name + ' ' + e.message, ev: []}; }
  try {
    const c = $('c'), g = c.getContext('2d'); let n = 0;
    setInterval(() => { g.fillStyle = n++ %% 2 ? '#38a' : '#a83'; g.fillRect(0, 0, 64, 48); }, 100);
    const faces = await remote(c.captureStream(10).getVideoTracks()[0]);
    $('vr').srcObject = faces;
    play('video stream', $('vr'));
  } catch (e) { r.cases['video stream'] = {promise: 'setup ' + e.name + ' ' + e.message, ev: []}; }
}, 2000);
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/v.mp4", "/p.mp4", "/tone.wav"):
            data = {"/v.mp4": VIDEO, "/p.mp4": PICTURE}.get(path, TONE)
            start, end = 0, len(data) - 1
            header = self.headers.get("Range", "")
            partial = header.startswith("bytes=")
            if partial:
                first, _, last = header[6:].partition("-")
                start = int(first or 0)
                end = min(int(last), end) if last else end
            chunk = data[start:end + 1]
            self.send_response(206 if partial else 200)
            self.send_header("Content-Type", "audio/wav" if path == "/tone.wav" else "video/mp4")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(len(chunk)))
            if partial:
                self.send_header("Content-Range", f"bytes {start}-{end}/{len(data)}")
            self.end_headers()
            try:
                self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        body = (PAGE % (path.strip("/") or "plain")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def silence():
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(22050)
        w.writeframes(struct.pack("<h", 0) * 22050 * 4)
    return out.getvalue()


def until(check, within=10):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.25)
    return check()


def alert(action="state", **values):
    return sv.cmd({"do": "meetalert", "action": action, **values})


def results(tab):
    raw = sv.ev(tab, "JSON.stringify(window.__r || null)")
    return json.loads(raw) if raw else None


def verdict(name, case):
    if not case:
        return "nothing"
    if name == "web audio":
        if case.get("later") == "running" and (case.get("time") or 0) > 0.5:
            return "played"
        if case.get("later") == "suspended":
            return "refused"
        return f"other {case}"
    if case.get("promise") == "ok" and not case.get("paused", True):
        return "played"
    if case.get("promise") == "NotAllowedError":
        return "refused"
    return f"other {case.get('promise')} paused={case.get('paused')}"


def world(waits):
    sv.setup(**{WAITS: waits})
    sv.launch()
    try:
        link = f"{sv.BASE}/cal-lsou-nd{int(waits)}"
        plain = sv.page("?plain")
        time.sleep(7)
        alert("fixture", lead="1", hosts={"127.0.0.1": "meet"},
              events=[{"title": "Sound check", "in": 0.5, "link": link}])
        alert("press", index=0, button="join")
        call = None
        for _ in range(40):
            call = next((x["id"] for x in sv.cmd({"do": "tabs"})["tabs"] if x.get("url") == link), None)
            if call:
                break
            time.sleep(0.25)
        time.sleep(7)
        out = {}
        for name, tab in (("call", call), ("other site", plain)):
            got = results(tab) if tab else None
            out[name] = {"clicks": got["clicks"] if got else None,
                         "cases": {c: verdict(c, (got or {}).get("cases", {}).get(c)) for c in CASES},
                         "raw": got}
        alert("off")
        return out
    finally:
        sv.quit()


def table(found):
    rows = ["| Case | " + " | ".join(f"{page}, videos wait {'on' if waits else 'off'}"
                                     for waits in (False, True) for page in ("call", "other site")) + " |"]
    rows.append("|---" * 5 + "|")
    for case in CASES:
        rows.append(f"| {case} | " + " | ".join(found[waits][page]["cases"][case]
                                              for waits in (False, True) for page in ("call", "other site")) + " |")
    return "\n".join(rows)


def main():
    global VIDEO, PICTURE, TONE
    ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
    if not os.path.exists(ffmpeg):
        sys.exit("Tests/call_sound.py needs ffmpeg to make its test video")
    with tempfile.TemporaryDirectory() as folder:
        out = f"{folder}/v.mp4"
        subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30",
                        "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo", "-t", "6", "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-c:a", "aac", "-movflags", "+faststart", out], check=True)
        VIDEO = Path(out).read_bytes()
        bare = f"{folder}/p.mp4"
        subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=30",
                        "-t", "6", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", bare],
                       check=True)
        PICTURE = Path(bare).read_bytes()
    TONE = silence()
    t = sv.T()
    found = {}
    try:
        for waits in (False, True):
            found[waits] = world(waits)
        print(table(found))
        if "--table" in sys.argv:
            for waits in (False, True):
                for page in ("call", "other site"):
                    print(f"{page} waits={waits}: {json.dumps(found[waits][page]['raw'])}")
            return 0
        for waits in (False, True):
            label = f"videos wait {'on' if waits else 'off'}"
            call, other = found[waits]["call"], found[waits]["other site"]
            t.ok(f"{label}: nothing in the call's page was clicked", call["clicks"] == 0, call["clicks"])
            t.ok(f"{label}: nothing in the other page was clicked", other["clicks"] == 0, other["clicks"])
            for case in CASES:
                t.ok(f"{label}: the call plays its {case}", call["cases"][case] == "played", call["cases"][case])
            for case in CASES:
                held = waits or case not in ("video without sound", "video stream")
                want = "refused" if held else "played"
                t.ok(f"{label}: another site's {case} is {want} as before", other["cases"][case] == want,
                     other["cases"][case])
    finally:
        t.done()
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/call_sound.py requires macOS and a built Broadway.app")
    sys.exit(main())

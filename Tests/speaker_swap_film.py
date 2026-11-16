#!/usr/bin/env python3
"""The speaker's mute and unmute on film, and its state checked.

Build first (`./build.sh`), then `python3 Tests/speaker_swap_film.py [dark|light] [--reduced]`.
A world of its own, shown so ScreenCaptureKit can take that one window
(Tests/WindowCapture.swift). Two tabs play a near-silent tone, one of them
pinned; `broadway tabs mute` and `broadway tabs unmute` flip both, the same bare
toggleMute() the switcher's key and the tab menu call. Each flip is filmed
and its frames land in .context/speaker-frames/, with a strip of the
speakers cropped from them and an mp4 per flip in .context/. The checks: the
row and the pin say Unmute Tab after muting and Mute Tab after unmuting, the
tabs report muted to match, and the speaker took more than one frame to
change, or with --reduced (Reduce Motion, as the test setting says it)
swapped at once.
"""
import io
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import threading
import time
import uuid
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

theme = sys.argv[1] if len(sys.argv) > 1 else "dark"
reduced = "--reduced" in sys.argv
sv.use("speaker-film-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
FRAMES = CONTEXT / "speaker-frames"
CAPTURE = FRAMES / "capture"
BROADWAY = str(Path(sv.APP) / "Contents/Helpers/broadway")


def tone():
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
        w.writeframes(b"".join(struct.pack("<h", int(2 * math.sin(i / 8))) for i in range(22050 * 2)))
    return out.getvalue()


SOUND = tone()
PAGE = b"""<!doctype html><meta charset=utf-8><title>%s</title>
<audio id=a src=/tone.wav loop autoplay></audio>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/tone.wav":
            body, kind = SOUND, "audio/wav"
        else:
            body, kind = PAGE % self.path.strip("/").encode(), "text/html"
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def broadway(*words):
    r = subprocess.run([BROADWAY, "--world", sv.W, *words, "--json"], capture_output=True, text=True, timeout=40)
    answer = json.loads(r.stdout or "{}")
    if not answer.get("ok"): print("  ..   broadway", " ".join(words), r.stdout.strip(), r.stderr.strip())
    return answer


def tab(id):
    return next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"].lower().startswith(id[:8].lower()) or id.lower().startswith(x["id"].lower()))



def film(name, act, seconds=2.0):
    folder = FRAMES / f"{name}-{theme}"
    shutil.rmtree(folder, ignore_errors=True)
    posture = sv.cmd({"do": "idle", "action": "unhide"})
    p = subprocess.Popen([str(CAPTURE), pid, str(folder), str(seconds), str(posture["number"]), "2"],
                         stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None: break
        time.sleep(0.025)
    if p.poll() is not None: raise RuntimeError(p.communicate()[0])
    time.sleep(0.15)
    act()
    print(name, p.communicate()[0].strip(), flush=True)
    frames = sorted(folder.glob("0*.png"))
    if frames:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                        "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2",
                        str(CONTEXT / f"speaker-{name}-{theme}.mp4")], check=True)
    return frames


def crop_box(frames):
    return "crop=520:300:0:210"


def strip(name, frames):
    if len(frames) < 2: return
    folder = frames[0].parent
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", "crop=300:200:20:270,scale=iw*2:ih*2:flags=neighbor,select='not(mod(n\\,4))',tile=8x2",
                    "-frames:v", "1", str(CONTEXT / f"speaker-{name}-{theme}-strip.png")], check=True)


def moving(frames):
    if len(frames) < 3: return 0
    digests = []
    for f in frames:
        r = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(f), "-vf", crop_box(frames),
                            "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True)
        digests.append(hash(r.stdout))
    return len(set(digests))


def main():
    global theme
    t = sv.T()
    FRAMES.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.setup(**{"start.fresh": False, "media.click": False, "agents.on": True})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    if reduced:
        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        theme += "-reduced"
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    global pid
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 900, "height": 560, "steps": 1})
        pinned = sv.sp("open", url=f"{BASE}/pinned")["resultID"]
        time.sleep(0.8)
        row = sv.sp("open", url=f"{BASE}/row")["resultID"]
        time.sleep(0.8)
        sv.cmd({"do": "pin", "id": pinned})
        sv.sp("open", url=f"{BASE}/quiet")
        time.sleep(0.8)
        for id in (pinned, row):
            sv.ev(id, "document.getElementById('a').play(), 1")
        real = False
        for _ in range(40):
            if all(tab(i)["noisy"] for i in (pinned, row)): real = True; break
            time.sleep(0.1)
        if not real:
            for id in (pinned, row):
                sv.sp("select", id=id); sv.cmd({"do": "ui", "noisy": True})
            sv.sp("open", url=f"{BASE}/quiet2")
        print(f"  ..   speakers from {'real playback' if real else 'the bench noisy flag (playback never reported)'}")
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(0.8)
        t.ok("both tabs play, neither muted", all(tab(i)["noisy"] and not tab(i)["muted"] for i in (pinned, row)),
             [tab(i) for i in (pinned, row)])
        muted = film("mute", lambda: broadway("tabs", "mute", row, pinned))
        t.ok("muting: both tabs report muted", all(tab(i)["muted"] for i in (pinned, row)))
        unmuted = film("unmute", lambda: broadway("tabs", "unmute", row, pinned))
        t.ok("unmuting: both tabs report unmuted", not any(tab(i)["muted"] for i in (pinned, row)))
        for name, frames in (("mute", muted), ("unmute", unmuted)):
            strip(name, frames)
            changes = moving(frames)
            if reduced:
                t.ok(f"{name} under Reduce Motion: filmed, and the speaker swaps at once ({changes} distinct)",
                     len(frames) > 1 and changes <= 3, len(frames))
            else:
                t.ok(f"{name}: filmed, and the speaker passes through in-between frames ({changes} distinct)",
                     len(frames) > 1 and changes > 3, len(frames))
        (CONTEXT / f"speaker-film-{theme}.json").write_text(json.dumps(
            {"pid": pid, "world": sv.W, "real": real, "frames": {"mute": len(muted), "unmute": len(unmuted)}}))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The sidebar row's speaker at rest and hovered, shot at 2x and measured.

Build first (`./build.sh`), then `python3 Tests/speaker_rest_shots.py [dark|light]`.
A world of its own with one tab in the window. The row is laid out silent,
then its page starts sounding with motion on, so the speaker appears the way
it does for a video that starts playing. The real pointer never crosses the
row: the rest still is taken first, then the bench marks the speaker hovered
(`speakerspot` with `over`) and the hovered still is taken. Both crops land in
.context/speaker-rest-<theme>.png and .context/speaker-hover-<theme>.png with
a side-by-side in .context/speaker-rest-hover-<theme>.png. The checks: the
glyph is drawn at the same point size, picture size and scale at rest as
hovered, and its lit box measures the same in both stills.
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
sv.use("speaker-rest-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
TMP = CONTEXT / "speaker-rest-work"
SHOT = TMP / "shot"


def tone():
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(22050)
        w.writeframes(b"".join(struct.pack("<h", int(2 * math.sin(i / 8))) for i in range(22050 * 2)))
    return out.getvalue()


SOUND = tone()
PAGE = b"""<!doctype html><meta charset=utf-8><title>Speaker at rest</title>
<audio id=a src=/tone.wav loop></audio>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body, kind = (SOUND, "audio/wav") if self.path == "/tone.wav" else (PAGE, "text/html")
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def tab(id):
    return next(x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"].lower().startswith(id[:8].lower()) or id.lower().startswith(x["id"].lower()))


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists(): raise RuntimeError(out or "no still")


def size(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], capture_output=True, text=True).stdout.split()
    return int(out[-3]), int(out[-1])


def crop(still, out, box):
    x, y, w, h = box
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", f"crop={w}:{h}:{x}:{y}", str(out)], check=True)


def lit_box(path):
    w, h = size(path)
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         capture_output=True).stdout
    inner = [(x, y) for y in range(h // 6, h - h // 6) for x in range(w // 6, w - w // 6)]
    values = sorted(raw[y * w + x] for x, y in inner)
    ground, peak = values[len(values) // 2], values[-1]
    light = peak - ground >= ground - values[0]
    cut = ground + (peak - ground) * 0.5 if light else ground - (ground - values[0]) * 0.5
    hits = [(x, y) for x, y in inner if (raw[y * w + x] > cut if light else raw[y * w + x] < cut)]
    xs, ys = [x for x, _ in hits], [y for _, y in hits]
    return (max(xs) - min(xs) + 1, max(ys) - min(ys) + 1, min(xs), min(ys)) if hits else (0, 0, 0, 0)


def main():
    t = sv.T()
    shutil.rmtree(TMP, ignore_errors=True)
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], check=True, cwd=TMP)
    sv.setup(**{"start.fresh": False, "media.click": False, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 900, "height": 560, "steps": 1})
        row = sv.sp("open", url=f"{BASE}/row")["resultID"]
        time.sleep(1.2)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(0.8)
        t.ok("the row is silent before the sound starts", not tab(row)["noisy"] and not sv.cmd({"do": "speakerspot"})["spots"])
        sv.ev(row, "document.getElementById('a').play(), 1")
        real = False
        for _ in range(40):
            if tab(row)["noisy"]: real = True; break
            time.sleep(0.1)
        if not real:
            sv.sp("select", id=row); sv.cmd({"do": "ui", "noisy": True})
        print(f"  ..   speaker from {'real playback' if real else 'the bench noisy flag'}")
        time.sleep(1.5)
        rest = sv.cmd({"do": "speakerspot"})["spots"]
        t.ok("one speaker shows, not hovered", len(rest) == 1 and not rest[0]["over"], rest)
        if len(rest) != 1: return 1
        rest_still = TMP / "rest.png"
        shoot(pid, number, rest_still)
        hover = sv.cmd({"do": "speakerspot", "over": True})["spots"]
        time.sleep(0.6)
        hover = sv.cmd({"do": "speakerspot"})["spots"]
        hover_still = TMP / "hover.png"
        shoot(pid, number, hover_still)
        sv.cmd({"do": "speakerspot", "over": False})
        width, _ = size(rest_still)
        k = max(1, round(width / 900))
        spot = rest[0]
        pad = 4
        box = (int((spot["x"] - pad) * k), int((spot["y"] - pad) * k), int((spot["side"] + 2 * pad) * k), int((spot["side"] + 2 * pad) * k))
        rest_crop, hover_crop = CONTEXT / f"speaker-rest-{theme}.png", CONTEXT / f"speaker-hover-{theme}.png"
        crop(rest_still, rest_crop, box)
        crop(hover_still, hover_crop, box)
        wide = (int((spot["x"] - 12) * k), int((spot["y"] - 10) * k), int(240 * k), int((spot["side"] + 20) * k))
        crop(rest_still, TMP / "rest-wide.png", wide)
        crop(hover_still, TMP / "hover-wide.png", wide)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(TMP / "rest-wide.png"), "-i", str(TMP / "hover-wide.png"),
                        "-filter_complex", "vstack", str(CONTEXT / f"speaker-rest-hover-{theme}.png")], check=True)
        a, b = lit_box(rest_crop), lit_box(hover_crop)
        h = hover[0] if hover else {}
        print(f"  ..   scale {k}x; rest {json.dumps(rest[0])}")
        print(f"  ..   hover {json.dumps(h)}")
        print(f"  ..   lit box rest {a[0]}x{a[1]} at {a[2]},{a[3]}; hovered {b[0]}x{b[1]} at {b[2]},{b[3]}")
        t.ok("the glyph's point size and picture are the same at rest as hovered",
             rest[0]["glyph"] == h.get("glyph") and rest[0]["image"] == h.get("image"), (rest[0], h))
        t.ok("the speaker rests at full scale", abs(rest[0]["scale"] - 1) < 0.001 and rest[0]["alpha"] == 1, rest[0])
        t.ok("the lit glyph measures the same at rest as hovered (within 2 px at 2x)",
             abs(a[0] - b[0]) <= 2 and abs(a[1] - b[1]) <= 2 and abs(a[2] - b[2]) <= 2 and abs(a[3] - b[3]) <= 2, (a, b))
        (CONTEXT / f"speaker-rest-{theme}.json").write_text(json.dumps({"scale": k, "rest": rest[0], "hover": h, "lit": {"rest": a, "hover": b}}))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

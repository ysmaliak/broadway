#!/usr/bin/env python3
"""The title ends before the call's time-left sign in every state of a call's row.

Build first (./build.sh), then python3 Tests/call_left_fade.py [LABEL].
Start it where the test copy may picture its own window (a Rex pane, not
ssh): every picture is of that window by its number (WindowShot.swift,
WindowCapture.swift), never a region of the display.

A shown test copy in a world of its own. A local page stands in for a Google
Meet call with a long title, and a fake calendar puts that call two and a
half minutes from its end, so its row shows "3m left". The row is pictured at
rest, selected, hovered, playing sound, with the tab numbers of a held
Command key, and filmed while the pointer comes and goes, while its sound
stops and while the sign first comes. Per frame, on the row's own readout
(endtrace), the title's ink and its fade end a gap short of the sign
wherever the sign shows at any strength.
"""
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "call-left"
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

OUT = ROOT / ".context" / "shots" / LABEL
TOOLS = ROOT / ".context" / "call-left-tools"
SHOT = TOOLS / "shot"
CAPTURE = TOOLS / "capture"
SIDEBAR = 260
TITLE = "Meet - Bug Sync - iOS + RC hand off"
GAP = 6
t = sv.T()


def tone():
    rate, seconds = 22050, 2
    frames = b"".join(struct.pack("<h", int(24 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(rate * seconds))
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return head + b"data" + struct.pack("<I", len(frames)) + frames


TONE = tone()
CALL = """<!doctype html><title>%s</title><body style='font:15px -apple-system;padding:40px'><h2>A call</h2>
<video id=v loop playsinline src="/tone.wav" width=320 height=180></video><script>
window.start = () => { const v = document.getElementById('v'); v.volume = 0.05; return v.play().then(() => 'playing', e => 'error ' + e.name); };
window.stop = () => { document.getElementById('v').pause(); return 'paused'; };
</script>""" % TITLE


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith("/tone.wav"):
            body, kind = TONE, "audio/wav"
        elif self.path.startswith("/abc-defg-hij"):
            body, kind = CALL.encode(), "text/html"
        else:
            body, kind = b"<!doctype html><title>A page in front</title><body><h2>A page</h2>", "text/html"
        self.send_response(200)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


pages = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=pages.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{pages.server_port}"
LINK = f"{BASE}/abc-defg-hij"
PID = None
NUMBER = None
SCALE = None


def end(action, **more):
    return sv.cmd({"do": "ui", "endtrace": {"action": action, **more}})


def row(label=TITLE):
    return next((r for r in end("now")["rows"] if r["label"] == label and r["interactive"]), None)


def hover(id, on):
    sv.cmd({"do": "rowhover", "id": id, "on": on})


def calendar(left_minutes):
    return sv.cmd({"do": "meetalert", "action": "fixture", "on": False, "hosts": {"127.0.0.1": "meet"},
                   "events": [{"title": "Bug Sync", "in": left_minutes - 30, "minutes": 30, "link": LINK}]})


def ev(id, js):
    return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")


def until(check, within=6):
    stop = time.time() + within
    while time.time() < stop:
        if check():
            return True
        time.sleep(0.2)
    return check()


def scale_of(picture):
    width = int.from_bytes(picture.read_bytes()[16:20], "big")
    return max(1, round(width / 1000))


def crop(r, scale):
    x, y = r["at"]
    return f"crop={int(r['width'] * scale)}:{int(34 * scale)}:{int(x * scale)}:{int(y * scale)}"


def shoot(name, r):
    out = OUT / f"{name}.png"
    said = subprocess.run([str(SHOT), str(PID), str(NUMBER), str(out)], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
    t.ok(f"pictured {name}", out.exists(), said)
    if out.exists() and r:
        global SCALE
        scale = SCALE = SCALE or scale_of(out)
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(out), "-vf", crop(r, scale) + ",scale=iw*2:ih*2:flags=neighbor",
                        str(OUT / f"{name}-row.png")], check=False, stdin=subprocess.DEVNULL)
    return out


def sign(r):
    if "callX" not in r or r.get("callWidth", 0) <= 0:
        return None
    return r.get("callShownX", r["callX"])


def judge(samples, label=TITLE):
    found = {"frames": 0, "signed": 0, "under": 0, "worst": 0.0, "first": []}
    for sample in samples:
        for r in sample["rows"]:
            if r["label"] != label or not r["interactive"] or not r["seen"] or not r["titled"] or len(r["shown"]) != 2:
                continue
            found["frames"] += 1
            left = sign(r)
            if left is None or r.get("call", 0) <= 0.004:
                continue
            found["signed"] += 1
            ink = r["x"] + r.get("slid", 0) + r["natural"]
            over = min(ink, r["shown"][1]) - (left - GAP)
            if over > 0.5:
                found["under"] += 1
                found["worst"] = max(found["worst"], round(over, 1))
                if len(found["first"]) < 6:
                    found["first"].append([round(sample["t"]), round(r["call"], 2), [round(v, 1) for v in r["shown"]], round(left, 1), round(r.get("slid", 0), 1)])
    return found


def film(name, act, r, seconds=0.7):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    p = subprocess.Popen([str(CAPTURE), str(PID), str(folder), str(seconds + 0.45), str(NUMBER), "2", "120"],
                         stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.15)
    end("start")
    act()
    time.sleep(seconds)
    samples = end("stop")["samples"]
    print("  ", name, p.communicate()[0].strip(), flush=True)
    (folder / "trace.json").write_text(json.dumps(samples))
    frames = sorted(folder.glob("0*.png"))
    if frames and r and SCALE:
        scale = SCALE
        work = folder / "sheet"
        work.mkdir()
        picked = frames[::max(1, len(frames) // 24)]
        for n, f in enumerate(picked):
            os.symlink(f, work / f"{n:04d}.png")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                        "-vf", f"{crop(r, scale)},tile=1x{len(picked)}:padding=4:color=red", "-frames:v", "1", str(OUT / f"{name}-sheet.png")],
                       check=False, stdin=subprocess.DEVNULL)
        shutil.rmtree(work, ignore_errors=True)
        for f in frames:
            f.unlink()
    found = judge(samples)
    print("  ", name, json.dumps(found), flush=True)
    return found


def readout(r):
    keys = ("width", "x", "room", "natural", "shown", "model", "call", "callX", "callShownX", "callWidth", "slid", "hover")
    return {k: r.get(k) for k in keys if k in r}


def still(name, r):
    left = sign(r)
    fade_end = r["model"][1] if len(r["model"]) == 2 else None
    print("  ", name, json.dumps(readout(r)), flush=True)
    if left is not None and r.get("call", 0) > 0.99 and fade_end is not None:
        ink = min(r["x"] + r["natural"], fade_end)
        t.ok(f"{name}: the title ends {GAP} points short of the sign", ink <= left - GAP + 0.5, (round(ink, 1), round(left, 1)))


def main():
    global PID, NUMBER
    OUT.mkdir(parents=True, exist_ok=True)
    TOOLS.mkdir(parents=True, exist_ok=True)
    for tool, source in [(SHOT, "WindowShot.swift"), (CAPTURE, "WindowCapture.swift")]:
        if not tool.exists():
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests" / source), "-o", str(tool)], check=True, stdin=subprocess.DEVNULL)
    sv.use("call-left-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"sidebar": True, "start.fresh": False, "meetings.next": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(SIDEBAR)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    PID = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 640, "steps": 1})
        calendar(12)
        front = sv.cmd({"do": "open", "url": f"{BASE}/home"})["id"]
        call = sv.cmd({"do": "open", "url": LINK})["id"]
        sv.cmd({"do": "wait", "id": call, "seconds": 10})
        sv.sp("select", id=front)
        NUMBER = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(1.2)
        r = row()
        t.ok("the call's row is there with no sign yet", r is not None, [x["label"] for x in end("now")["rows"]])
        if not r:
            return 1
        id = r["id"]
        shoot("no-sign", r)
        arrival = film("sign-arrives", lambda: calendar(2.5), r, seconds=1.0)
        time.sleep(0.6)
        r = row()
        t.ok("the sign shows", r.get("call", 1) > 0.99 and r.get("callWidth", 1) > 0, readout(r))
        if "callX" in r:
            t.ok("sign arrives: no frame with the title under the sign", arrival["under"] == 0 and arrival["signed"] > 0, arrival)
        shoot("rest", r)
        still("rest", r)
        sv.sp("select", id=call)
        time.sleep(0.8)
        shoot("selected", row())
        still("selected", row())
        hover(id, True)
        time.sleep(0.6)
        shoot("hovered", row())
        still("hovered", row())
        out_ = film("hover-out", lambda: hover(id, False), r)
        if "callX" in r:
            t.ok("hover out: no frame with the title under the sign", out_["under"] == 0 and out_["signed"] > 0, out_)
        film("hover-in", lambda: hover(id, True), r)
        hover(id, False)
        time.sleep(0.6)
        end("command", on=True)
        time.sleep(0.6)
        shoot("command", row())
        still("command", row())
        end("command", on=False)
        time.sleep(0.6)
        said = ev(call, "start(), 1")
        played = until(lambda: ev(call, "document.getElementById('v').paused") is False)
        time.sleep(1.5)
        shoot("playing", row())
        still("playing", row())
        hover(id, True)
        time.sleep(0.6)
        shoot("playing-hovered", row())
        out2 = film("playing-hover-out", lambda: hover(id, False), row())
        if "callX" in r:
            t.ok("playing, hover out: no frame with the title under the sign", out2["under"] == 0, out2)
        sv.sp("select", id=front)
        time.sleep(0.8)
        shoot("playing-rest", row())
        still("playing-rest", row())
        left = film("sound-stops", lambda: ev(call, "stop(), 1"), row(), seconds=1.6)
        if "callX" in r:
            t.ok("sound stops: no frame with the title under the sign", left["under"] == 0, left)
        shoot("after-sound", row())
        still("after-sound", row())
        for theme in ("dark",):
            sv.cmd({"do": "ui", "look": theme})
            time.sleep(0.8)
            shoot(f"{theme}-rest", row())
        print("   played", said, played, flush=True)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

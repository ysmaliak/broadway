#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        body = f'<html style="background:#f4efe6;font:40px system-ui"><title>{name}</title><h1>{name}</h1></html>'.encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"
look = sys.argv[1] if len(sys.argv) > 1 else "light"
sv.use("pill-doors-" + uuid.uuid4().hex[:8])
out = ROOT / ".context" / f"pill-doors-{look}"
out.mkdir(parents=True, exist_ok=True)
tools = ROOT / ".context"
subprocess.run(["swiftc", "-parse-as-library", "Tests/WindowCapture.swift", "-o", str(tools / "capture")], check=True)
subprocess.run(["swiftc", "-parse-as-library", "Tests/WindowShot.swift", "-o", str(tools / "windowshot")], check=True)
subprocess.run(["swiftc", "Tests/film_strip.swift", "-o", str(tools / "film_strip")], check=True)
for key, value in {"bench": True, "spaces": True, "tabs.groups": False, "ai": False, "sidebar": True, "start.fresh": False, "split": False}.items():
    subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", str(value).lower()], check=True)
subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", look], check=True)
subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "252"], check=True)
subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
for _ in range(200):
    if os.path.exists(sv.SOCK):
        break
    time.sleep(0.1)
time.sleep(2)
pid = next(iter(sv.holding() & sv.running()))
t = sv.T()


def cmd(**r):
    return sv.cmd(r)


def crop():
    frame = cmd(do="addresshover", on=False)["frame"]
    width, height = 1120.0, 760.0
    x, y, w, h = frame
    pad = 6
    return f"{(x - pad) / width},{(height - y - h - pad) / height},{(w + 2 * pad) / width},{(h + 2 * pad) / height}"


def film(name, action, seconds=1.6):
    folder = out / name
    for old in folder.glob("*.png") if folder.exists() else []:
        old.unlink()
    for stale in ["ready", "times.json"]:
        if (folder / stale).exists():
            (folder / stale).unlink()
    posture = cmd(do="idle", action="unhide")
    p = subprocess.Popen([str(tools / "capture"), pid, str(folder), str(seconds), str(posture["number"]), "2"], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    if p.poll() is not None:
        raise RuntimeError(p.communicate()[0])
    time.sleep(0.15)
    action()
    said = p.communicate()[0]
    print(name, said.strip(), flush=True)
    times = json.loads((folder / "times.json").read_text())
    gaps = [b - a for a, b in zip(times, times[1:])]
    t.ok(f"{name}: {len(times)} frames, longest gap {max(gaps) * 1000:.0f} ms", len(times) >= seconds * 30, {"count": len(times)})
    strip = out / f"{name}.png"
    subprocess.run([str(tools / "film_strip"), str(folder), str(strip), "", "6", "420", crop()], check=True)
    print("  strip", strip, flush=True)
    time.sleep(0.4)


def shot(name):
    posture = cmd(do="idle", action="unhide")
    path = out / f"{name}.png"
    subprocess.run([str(tools / "windowshot"), pid, str(posture["number"]), str(path)], check=True)
    x, y, w, h = cmd(do="addresshover", on=False)["frame"]
    pill = out / f"{name}-pill.png"
    subprocess.run(["sips", "-c", str(int((h + 16) * 2)), str(int((w + 16) * 2)), "--cropOffset", str(int((760 - y - h - 8) * 2)), str(max(0, int((x - 8) * 2))),
                    str(path), "--out", str(pill)], check=True, capture_output=True)
    print("  pill", pill, flush=True)
    return path


try:
    cmd(do="resize", width=1120, height=760, steps=1)
    posture = cmd(do="idle", action="front")
    t.ok("test window is available for capture", posture["visible"] and not posture["hidden"], posture)
    first = sv.sp("open", url=base + "/personal")["resultID"]
    cmd(do="wait", id=first, seconds=10)
    cmd(do="space", action="new", name="Work")
    second = sv.sp("open", url=base.replace("127.0.0.1", "localhost") + "/work")["resultID"]
    cmd(do="wait", id=second, seconds=10)
    cmd(do="space", action="new", name="Blank")
    cmd(do="space", action="go", index=1)
    time.sleep(1)
    whole = shot("rest")
    print("  shot", whole, flush=True)
    film("click-to-work", lambda: cmd(do="space", action="foot", index=2))
    t.ok("the click lands on Work", cmd(do="space")["current"] == "Work")
    film("swipe-back-slow", lambda: cmd(do="space", action="trackpad", stops=[240], speed=300), 2.4)
    t.ok("the swipe lands on Personal", cmd(do="space")["current"] == "Personal")
    film("swipe-cancel", lambda: cmd(do="space", action="trackpad", stops=[-110], speed=500, cancel=True), 2)
    t.ok("the cancelled swipe stays on Personal", cmd(do="space")["current"] == "Personal")
    cmd(do="space", action="go", index=2)
    time.sleep(1)
    film("work-to-blank", lambda: cmd(do="space", action="foot", index=3))
    t.ok("the click lands on Blank", cmd(do="space")["current"] == "Blank")
    film("blank-to-work", lambda: cmd(do="space", action="foot", index=2))
    cmd(do="space", action="go", index=1)
    time.sleep(1)
    cmd(do="space", action="hold", dx=-120)
    time.sleep(0.5)
    print("  shot", shot("mid-swipe"), flush=True)
    cmd(do="space", action="release")
    time.sleep(1.2)
    (out / "crop.json").write_text(json.dumps({"crop": crop()}))
finally:
    try:
        cmd(do="quit")
    except Exception:
        subprocess.run(["kill", pid])
    print("own test world retained:", sv.W, flush=True)

t.done()
sys.exit(1 if t.failed else 0)

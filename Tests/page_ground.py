#!/usr/bin/env python3
"""The page ground in each space's look: error pages, the new tab page and
every page that has yet to draw, shot in a test copy's own window.

Build first (`./build.sh debug`), then
`python3 Tests/page_ground.py <label> [shots|film|all]`. BROADWAY_PROBE_APP picks
another build, so a before and an after are the same run. A world of its
own, shown so ScreenCaptureKit can take that one window: stills land in
.context/page-ground/<label>/, with a contact sheet per theme; films of a
space switch onto a failed page (awake, and restored after a relaunch) at
60 fps, with each frame's page-area mean colour in films.json.
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "now"
mode = sys.argv[2] if len(sys.argv) > 2 else "all"
sv.use("page-ground-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
OUT = CONTEXT / "page-ground" / label
TOOLS = CONTEXT / "page-ground" / "tools"
SHOT, SHEET, PIXEL, CAPTURE = (TOOLS / n for n in ("shot", "sheet", "pixel", "capture"))
def closed_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


REFUSED = f"http://127.0.0.1:{closed_port()}/"
SPACES = [
    ("sky", {"colour": "sky"}),
    ("aurora", {"colours": ["8BE33A", "7CC4F2", "7B3FE4"], "intensity": 0.7}),
    ("gray", {"colour": "gray"}),
]
KINDS = ["error", "newtab", "unpainted", "blank"]


class Slow(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/slow"):
            time.sleep(120)
        body = b"<!doctype html><title>page</title><body style='background:#15151c;color:#ddd'><p>page"
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Slow)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    for name, source in (("shot", "WindowShot"), ("sheet", "ContactSheet"), ("pixel", "GroundPixel"), ("capture", "WindowCapture")):
        if not (TOOLS / name).exists():
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / f"Tests/{source}.swift"), "-o", str(TOOLS / name)], check=True)


def start():
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    return next(iter(sv.holding() & sv.running()))


def number(window=1):
    return sv.cmd({"do": "idle", "action": "unhide", "window": window})["number"]


def shoot(pid, window, path):
    out = subprocess.run([str(SHOT), str(pid), str(number(window)), str(path)], capture_output=True, text=True).stdout.strip()
    if "SKIP" in out or not path.exists():
        raise SystemExit(f"no still: {out}")


def pixel(path, box=(0.32, 0.12, 0.97, 0.95)):
    read = subprocess.run([str(PIXEL), str(path), *map(str, box)], capture_output=True, text=True).stdout
    return json.loads(read or "{}")


def opened(window, kind):
    if kind == "newtab":
        had = {t["id"] for t in sv.cmd({"do": "split", "action": "state", "window": window})["tabs"]}
        sv.cmd({"do": "split", "action": "newTab", "window": window})
        tabs = sv.cmd({"do": "split", "action": "state", "window": window})["tabs"]
        fresh = [t["id"] for t in tabs if t["id"] not in had]
        return fresh[0] if fresh else next(t["id"] for t in reversed(tabs) if t.get("blank"))
    url = {"error": REFUSED, "unpainted": f"{BASE}/slow", "blank": "about:blank"}[kind]
    return sv.cmd({"do": "split", "action": "open", "url": url, "window": window})["resultID"]


def shots(pid):
    sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 1})
    made = {}
    for index, (name, look) in enumerate(SPACES):
        if index > 0:
            sv.cmd({"do": "space", "action": "new", "name": name})
        sv.cmd({"do": "space", "action": "look", "glass": False, "transparency": 0, "grain": 0, **look})
        made[name] = {kind: opened(1, kind) for kind in KINDS}
        time.sleep(0.6)
    private = sv.cmd({"do": "windows", "action": "private"})
    time.sleep(1.5)
    window = len(sv.cmd({"do": "windows"}).get("windows", [])) or 2
    sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 1, "window": window})
    made["onyx"] = {kind: opened(window, kind) for kind in KINDS}
    time.sleep(2.5)
    cells, pixels = {"light": [], "dark": []}, {}
    for theme in ("light", "dark"):
        sv.cmd({"do": "ui", "look": theme})
        for index, (name, _) in enumerate(SPACES + [("onyx", None)]):
            on = window if name == "onyx" else 1
            if name != "onyx":
                sv.cmd({"do": "space", "action": "go", "index": index + 1})
                time.sleep(0.8)
            for kind in KINDS:
                if kind in ("unpainted", "newtab"):
                    made[name][kind] = opened(on, kind)
                sv.cmd({"do": "split", "action": "select", "id": made[name][kind], "window": on})
                time.sleep(1.2)
                path = OUT / "shots" / f"{theme}-{name}-{kind}.png"
                shoot(pid, on, path)
                cells[theme].append((f"{theme} {name} {kind}", path))
                pixels[f"{theme} {name} {kind}"] = pixel(path)
                print("  shot", path.name, pixels[f"{theme} {name} {kind}"].get("mean"), flush=True)
    sv.cmd({"do": "ui", "look": "dark"})
    sv.cmd({"do": "space", "action": "go", "index": 1})
    sv.cmd({"do": "split", "action": "select", "id": made["sky"]["error"], "window": 1})
    time.sleep(0.8)
    sv.cmd({"do": "space", "action": "look", "colours": ["FB3A4D"], "intensity": 1})
    time.sleep(1.0)
    live = OUT / "shots" / "dark-live-look-change-error.png"
    shoot(pid, 1, live)
    cells["dark"].append(("dark sky→ember live", live))
    sv.cmd({"do": "space", "action": "look", "colour": "sky"})
    for theme, row in cells.items():
        subprocess.run([str(SHEET), str(OUT / f"sheet-{theme}.png"), "4", "2240", "1520", *[f"{n}={p}" for n, p in row]], check=True)
    (OUT / "pixels.json").write_text(json.dumps(pixels, indent=1))
    sv.cmd({"do": "windows", "action": "close", "n": window})
    time.sleep(0.8)


def film(pid, name, act, seconds=2.4):
    folder = OUT / "frames" / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), pid, str(folder), str(seconds), str(number(1))], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    if p.poll() is not None:
        raise SystemExit(p.communicate()[0])
    time.sleep(0.15)
    act()
    print(name, p.communicate()[0].strip(), flush=True)
    frames = sorted(folder.glob("0*.png"))
    movie = OUT / f"film-{name}.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(movie)], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", "select='not(mod(n\\,3))',scale=480:-1,tile=8x6:padding=4:color=gray", "-frames:v", "1",
                    str(OUT / f"film-{name}-sheet.png")], check=True)
    means = [pixel(f).get("mean", [0, 0, 0]) for f in frames]
    light = [round(sum(m) / 3) for m in means]
    print(f"  {name}: {len(frames)} frames, page-area mean max {max(light)} min {min(light)}", flush=True)
    return {"frames": len(frames), "mean": light}


def titles():
    return {t["url"]: t for t in sv.cmd({"do": "titles"})["tabs"]}


def films(pid):
    key = lambda n: sv.cmd({"do": "space", "action": "key", "index": n})
    sv.cmd({"do": "ui", "look": "dark"})
    sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 1})
    sv.cmd({"do": "space", "action": "look", "colours": ["000354", "2404AA"], "intensity": 1})
    sv.cmd({"do": "split", "action": "open", "url": f"{BASE}/home"})
    sv.cmd({"do": "space", "action": "new", "name": "Work"})
    sv.cmd({"do": "space", "action": "look", "colours": ["1D1F3A", "3B2A5C"], "intensity": 1})
    sv.cmd({"do": "split", "action": "open", "url": f"{BASE}/other"})
    time.sleep(0.5)
    sv.cmd({"do": "split", "action": "open", "url": REFUSED})
    time.sleep(1.5)
    out = {}
    key(1)
    time.sleep(2.0)
    out["awake"] = film(pid, "awake", lambda: key(2))
    time.sleep(1.0)
    sv.cmd({"do": "space", "action": "look", "colours": ["8BE33A", "7CC4F2", "7B3FE4"], "intensity": 0.7})
    time.sleep(0.5)
    key(1)
    time.sleep(2.0)
    out["aurora"] = film(pid, "aurora", lambda: key(2))
    time.sleep(1.0)
    sv.cmd({"do": "space", "action": "look", "colours": ["1D1F3A", "3B2A5C"], "intensity": 1})
    key(1)
    time.sleep(1.5)
    sv.quit()
    time.sleep(1.0)
    pid = start()
    sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 1})
    time.sleep(2.0)
    out["restored"] = film(pid, "restored", lambda: key(2))
    time.sleep(1.0)
    out["restored.failed"] = titles().get(REFUSED, {}).get("failed")
    (OUT / "films.json").write_text(json.dumps(out))
    return pid


def world(**extra):
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    for k, v in extra.items():
        subprocess.run(["defaults", "write", sv.SUITE, k, "-float", str(v)], check=True)
    return start()


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    (OUT / "shots").mkdir(parents=True, exist_ok=True)
    tools()
    try:
        if mode in ("shots", "all"):
            shots(world())
            sv.quit()
        if mode in ("film", "all"):
            films(world(**{"sleep.after": 6}))
    finally:
        sv.finish()


if __name__ == "__main__":
    main()

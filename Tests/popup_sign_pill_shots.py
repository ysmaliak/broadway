#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("popsign-" + uuid.uuid4().hex[:6])
TMP = Path("/tmp") / f"broadway-popsign-{os.getpid()}"
OUT = ROOT / ".context" / "popup-sign" / LABEL
rl.SHOT = TMP / "shot"
PORT = sv.srv.server_port
SITE = f"http://localhost:{PORT}"
WIDTH = 258


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/auto"):
            body = "<title>Refused window</title><script>setTimeout(() => window.open('/opened'), 300)</script>auto"
        else:
            body = "<title>Plain page</title>plain"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def size_of(still):
    said = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(still)], capture_output=True, text=True).stdout.split()
    return int(said[said.index("pixelWidth:") + 1]), int(said[said.index("pixelHeight:") + 1])


def main():
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(**{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(WIDTH)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        plain = sv.sp("open", url=f"{SITE}/plain")["resultID"]
        time.sleep(1.2)
        page = sv.sp("open", url=f"{SITE}/auto/notes/2026/a-rather-long-article-about-windows")["resultID"]
        time.sleep(1.8)
        said = sv.cmd({"do": "popups", "id": page})
        t.ok("the page's window was refused", said.get("sign") is True, said)
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"] not in (plain, page) and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError:
                    pass
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]

        def shoot(name, height=200):
            raw = TMP / f"{name}-raw.png"
            rl.shoot(pid, number, raw)
            k = max(1, round(size_of(raw)[0] / 1000))
            t.ok(f"{name} is a 2x still", k == 2, k)
            out = OUT / f"{name}.png"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(raw), "-vf",
                            f"crop={int((WIDTH + 6) * k)}:{int(height * k)}:0:0", str(out)], check=True)
            return out

        for theme in ("light", "dark"):
            sv.cmd({"do": "ui", "look": theme, "addressBar": "host"})
            sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
            sv.cmd({"do": "select", "id": page})
            time.sleep(1.2)
            shoot(f"{theme}-host")
            sv.cmd({"do": "addresshover", "on": True})
            time.sleep(0.5)
            shoot(f"{theme}-hover")
            sv.cmd({"do": "addresshover", "on": False})
            sv.cmd({"do": "ui", "addressBar": "full"})
            time.sleep(0.8)
            shoot(f"{theme}-full")
            sv.cmd({"do": "ui", "addressBar": "host"})
            sv.cmd({"do": "select", "id": plain})
            time.sleep(1.0)
            shoot(f"{theme}-plain")
            sv.cmd({"do": "select", "id": page})
            sv.cmd({"do": "ui", "addressBar": "hidden"})
            time.sleep(1.0)
            shoot(f"{theme}-row")
            sv.cmd({"do": "ui", "addressBar": "host"})
        t.ok("the sign is still there", sv.cmd({"do": "popups", "id": page}).get("sign") is True)
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

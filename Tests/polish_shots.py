#!/usr/bin/env python3
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("polish-shots")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/polish/shell")
SHOT = Path(os.environ.get("TMPDIR", "/tmp")) / f"broadway-polish-shot-{os.getpid()}"
TAG = os.environ.get("TAG", "now")
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
SIZES = {1600: 960, 1000: 680}
WIDTHS = [int(w) for w in os.environ.get("WIDTHS", "1600,1000").split(",")]
ALL_LOOKS = {
    "pale": {"custom": "F2EEE6", "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1, "glass": False, "transparency": 0, "grain": 0},
    "black": {"custom": "000000", "intensity": 2, "glass": False, "transparency": 0, "grain": 0},
}
LOOKS = [n for n in os.environ.get("LOOKS", "pale,vivid,black").split(",") if n in ALL_LOOKS]
THEMES = [t for t in os.environ.get("THEMES", "light,dark").split(",") if t in ("light", "dark")]
WINDOW = [0]
PID = [0]
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        title = self.path.strip("/").split("/")[-1].replace("-", " ").title() or "Page"
        body = (f"<!doctype html><meta charset=utf-8><title>{title}</title>"
                f"<body style='font:16px -apple-system;margin:48px;color:#222;background:#fff'>"
                f"<h1>{title}</h1><p>{' '.join(['A page in the card.'] * 60)}</p>")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def wanted(name):
    return not ONLY or name in ONLY


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{TAG}-{name}.png"
    path.unlink(missing_ok=True)
    subprocess.run([str(SHOT), str(PID[0]), str(WINDOW[0]), str(path)], capture_output=True, text=True)
    t.ok(f"pictured {name}", path.exists())


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def stage(dark, width):
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [width, SIZES[width]]})
    WINDOW[0], PID[0] = staged["window"], staged["pid"]
    sv.cmd({"do": "ui", "look": "dark" if dark else "light"})
    time.sleep(0.8)


def opened(name):
    id = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
    time.sleep(0.25)
    return id


def furnish():
    pins = [opened(f"fav/{n}") for n in ("mail", "calendar", "notes", "music")]
    pinned = [opened(n) for n in ("team-calendar", "design-review")]
    today = [opened(n) for n in ("inbox", "pull-requests", "weekend-plans", "weather",
                                 "a-very-long-article-title-that-runs-past-the-column-edge",
                                 "flights", "groceries", "reading-list")]
    time.sleep(2)
    for id in pins:
        sv.cmd({"do": "pin", "id": id})
    sv.cmd({"do": "group", "id": pinned[0], "new": True, "name": "Work"})
    sv.cmd({"do": "group", "id": pinned[1], "name": "Work"})
    sv.cmd({"do": "group", "name": "Work", "pinned": True})
    for name in ("Alpha", "Beta", "Gamma", "Delta"):
        sv.cmd({"do": "titles", "mark": f"{BASE}/{name.lower()}", "named": name})
    sv.sp("select", id=today[2])
    time.sleep(1)
    return today


def escape():
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b"})
    time.sleep(0.4)


def round_of(theme, name, width, today):
    tag = f"{theme}-{name}-{width}"
    stage(theme == "dark", width)
    sv.cmd({"do": "space", "action": "look", **ALL_LOOKS[name]})
    sv.cmd({"do": "ui", "bookmarksBar": False, "folded": False})
    sv.sp("select", id=today[2])
    time.sleep(1.2)
    if wanted("window"):
        shoot(f"{tag}-01-window")
    if wanted("field"):
        try:
            sv.cmd({"do": "field", "text": "we"})
            time.sleep(1.0)
            shoot(f"{tag}-02-field")
        except RuntimeError as error:
            t.ok(f"{tag}: the field opened", False, error)
        sv.sp("escape")
        time.sleep(0.3)
        sv.sp("escape")
        time.sleep(0.6)
    if wanted("bar"):
        sv.cmd({"do": "ui", "bookmarksBar": True})
        time.sleep(1.0)
        shoot(f"{tag}-03-bar")
        sv.cmd({"do": "ui", "bookmarksBar": False})
        time.sleep(0.6)
    if wanted("fold"):
        sv.cmd({"do": "ui", "folded": True})
        time.sleep(1.0)
        shoot(f"{tag}-04-folded")
        sv.cmd({"do": "ui", "folded": False})
        time.sleep(0.8)
    if wanted("peek"):
        sv.cmd({"do": "peek", "url": f"{BASE}/peeked-page"})
        time.sleep(1.4)
        shoot(f"{tag}-05-peek")
        sv.cmd({"do": "peek", "url": "close"})
        time.sleep(0.8)
    if wanted("split"):
        a, b = today[0], today[1]
        sv.sp("select", id=a)
        try:
            sv.sp("pair", id=b, **{"with": a}, side="right")
            time.sleep(1.2)
            shoot(f"{tag}-06-split")
        except RuntimeError as error:
            t.ok(f"{tag}: split view opened", False, error)
        sv.sp("detach", id=b)
        sv.sp("select", id=today[2])
        time.sleep(0.8)
    if wanted("switcher"):
        sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]})
        time.sleep(0.8)
        shoot(f"{tag}-07-switcher")
        escape()
        sv.sp("select", id=today[2])
        time.sleep(0.4)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowsShot.swift"), "-o", str(SHOT)], check=True)
    try:
        sv.setup(sidebar=True, spaces=True, **{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True})
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "250"], check=True)
        launch()
        sv.cmd({"do": "window"})
        stage(False, WIDTHS[0])
        today = furnish()
        for theme in THEMES:
            for name in LOOKS:
                for width in WIDTHS:
                    round_of(theme, name, width, today)
    finally:
        t.done()
        sv.finish()
        SHOT.unlink(missing_ok=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

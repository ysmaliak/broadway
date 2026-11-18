#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("popup-shots")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/popups")
TOOLS = ROOT / ".build" / "popup-shots"
SHOT = TOOLS / "windows-shot"
FILM = TOOLS / "popup-film"
WIDTH, HEIGHT = 1100, 700
WINDOW = [0]
PID = [0]
EXTENSION = [""]
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.strip("/")
        if path.startswith("popups"):
            body = ("<!doctype html><title>Pop</title><body style='background:white'>"
                    "<script>setTimeout(function(){ window.open('/white', '_blank', 'width=300,height=200') }, 300)</script>")
        else:
            words = " ".join(["words"] * 400)
            body = (f"<!doctype html><title>{path.title() or 'Page'}</title>"
                    f"<body style='margin:12px;background:white;color:black;font:20px system-ui'><p>{words}</p>")
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


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    for source, out in ((ROOT / "Tests/WindowsShot.swift", SHOT), (ROOT / "Tests/popup_film.swift", FILM)):
        if not out.exists() or out.stat().st_mtime < source.stat().st_mtime:
            subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(out)], check=True)


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1",
                    "--env", "SEARCH_TRANSLATE_FAKE=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def stage(dark):
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})
    WINDOW[0], PID[0] = staged["window"], staged["pid"]
    time.sleep(0.8)


def popups():
    return [w for w in sv.cmd({"do": "probe"})["windows"] if w["kind"] in ("KitPopupPanel", "_NSPopoverWindow") and w["visible"]]


def until(check, within=6.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.15)
    return check()


def shoot(numbers, path):
    path.unlink(missing_ok=True)
    said = subprocess.run([str(SHOT), str(PID[0]), ",".join(str(n) for n in numbers), str(path)],
                          capture_output=True, text=True).stdout
    return path.exists(), said.strip()


def shut():
    sv.cmd({"do": "ui", "popup": "close", "bookmarksList": False, "editlook": False, "extensions": False,
            "plus": False, "recentdownloads": False, "hovercard": "off"})
    until(lambda: not popups(), 3)
    time.sleep(0.3)


def still(name, label, opener, closer=None):
    if ONLY and not any(name.startswith(o) for o in ONLY):
        return
    opener()
    up = until(popups, 4)
    if not up:
        t.ok(f"{label}: opened", False)
        (closer or shut)()
        return
    time.sleep(0.5)
    made, said = shoot([WINDOW[0], up[-1]["number"]], OUT / f"{name}.png")
    t.ok(f"{label}: pictured", made, said)
    (closer or shut)()
    t.ok(f"{label}: closed", bool(until(lambda: not popups(), 3)))
    shut()


def notice(tag):
    if ONLY and not any(f"link-notice-{tag}".startswith(o) for o in ONLY):
        return
    sv.cmd({"do": "ui", "linkNotice": True})
    time.sleep(0.9)
    made, said = shoot([WINDOW[0]], OUT / f"link-notice-{tag}.png")
    t.ok(f"link notice, {tag}: pictured", made, said)
    sv.cmd({"do": "ui", "linkNotice": False})
    time.sleep(0.4)


def hover(tab):
    rows = sv.cmd({"do": "rowframes"})["rows"]
    sv.cmd({"do": "ui", "hovercard": {"id": tab, "frame": rows[tab]}})


def extension_folder():
    folder = Path(tempfile.mkdtemp(prefix="broadway-popup-ext-"))
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Shots", "version": "1.0",
        "action": {"default_title": "Shots", "default_popup": "popup.html"},
    }))
    (folder / "popup.html").write_text(
        "<!doctype html><title>Shots</title><style>@media (prefers-color-scheme: dark) { html { background: #1e1e1e; color: #eee } }</style>"
        "<body style='margin:0;width:260px;height:160px'><p style='margin:20px;font:13px system-ui'>An extension's popup</p>")
    return folder


def install():
    sv.cmd({"do": "ext-folder", "path": str(extension_folder()), "yes": True})
    loaded = until(lambda: [e for e in sv.cmd({"do": "extensions"}).get("extensions", [])
                            if e.get("name") == "Shots" and e.get("loaded")], 10)
    t.ok("the test extension loaded", bool(loaded))
    if loaded:
        EXTENSION[0] = loaded[0]["id"]
        sv.cmd({"do": "ext-pin", "id": EXTENSION[0], "on": True})
        time.sleep(0.6)


def round_of(dark, side):
    tag = f"{'dark' if dark else 'light'}-{side}"
    stage(dark)
    sv.cmd({"do": "ui", "side": side})
    page = sv.sp("open", url=f"{BASE}/white")["resultID"]
    sv.cmd({"do": "select", "id": page})
    time.sleep(1.2)
    ui = lambda **f: (lambda: sv.cmd({"do": "ui", **f}))
    still(f"bookmark-card-{tag}", f"bookmark card, {tag}", ui(bookmarkCard=True))
    still(f"space-look-{tag}", f"space look, {tag}", ui(editlook=True))
    still(f"icon-picker-{tag}", f"icon picker, {tag}", ui(pickicon=True))
    still(f"downloads-{tag}", f"downloads list, {tag}", ui(recentdownloads=True))
    still(f"hover-card-{tag}", f"hover card, {tag}", lambda: hover(page))
    if EXTENSION[0]:
        still(f"extension-popup-{tag}", f"extension popup, {tag}",
              lambda: (sv.cmd({"do": "ext-press", "id": EXTENSION[0]}), time.sleep(3.5)))
    if not ONLY or any(o.startswith("link") for o in ONLY):
        spaces(True)
        still(f"link-chooser-{tag}", f"link chooser, {tag}", ui(linkChooser=f"{BASE}/pull/1"), ui(linkChooserDrop=True))
        notice(tag)
        spaces(False)
    sv.sp("close", id=page)


MADE_SPACES = [False]


def spaces(on):
    sv.cmd({"do": "ui", "spaces": on})
    if on and not MADE_SPACES[0]:
        MADE_SPACES[0] = True
        for name in ("Work", "Reading"):
            sv.cmd({"do": "space", "action": "new", "name": name})
    if on:
        sv.cmd({"do": "space", "action": "go", "index": 1})
    time.sleep(0.6)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tools()
    try:
        sv.setup(sidebar=True)
        launch()
        sv.cmd({"do": "window"})
        install()
        for dark in (True, False):
            for side in ("left", "right"):
                round_of(dark, side)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv
import visual_diff as vd
import glass_ink as gi

sv.use("glass-over-page")
t = sv.T()
ROOT = Path(__file__).resolve().parents[1]
WORDS = " ".join(["words"] * 600)
PICTURE = ("repeating-linear-gradient(110deg, #fff 0 64px, #000 64px 128px, #e8402a 128px 192px, #f5d21f 192px 256px,"
           " #1b3fd8 256px 320px, #fff 320px 384px, #000 384px 448px, #2db34a 448px 512px)")
PAGES = {
    "white": "background:#fff;color:#000",
    "black": "background:#000;color:#fff",
    "picture": f"background:{PICTURE};color:#fff",
}
MEMBERS = [
    ("find-bar", "FindBarView", lambda: sv.cmd({"do": "find", "text": "words"}), lambda: sv.cmd({"do": "find", "close": True})),
    ("link-notice", "OfferBarView", lambda: sv.cmd({"do": "ui", "linkNotice": True}), lambda: sv.cmd({"do": "ui", "linkNotice": False})),
    ("downloads", "RecentDownloadsView", lambda: sv.cmd({"do": "ui", "downloadsStage": "empty", "recentdownloads": True}),
     lambda: sv.cmd({"do": "ui", "recentdownloads": False})),
    ("downloads-many", "RecentDownloadsView", lambda: sv.cmd({"do": "ui", "downloadsStage": "many", "recentdownloads": True}),
     lambda: sv.cmd({"do": "ui", "recentdownloads": False, "downloadsStage": "empty"})),
    ("downloads-picked", "RecentDownloadsView", lambda: picked(), lambda: sv.cmd({"do": "ui", "recentdownloads": False, "downloadsStage": "empty"})),
]


def picked():
    sv.cmd({"do": "ui", "downloadsStage": "many", "recentdownloads": True})
    time.sleep(1.0)
    sv.cmd({"do": "downloadslist", "action": "select", "row": 1})


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        style = PAGES.get(name, PAGES["white"])
        body = (f"<!doctype html><meta charset=utf-8><title>{name.title() or 'Page'}</title>"
                f"<body style='margin:12px;font:20px system-ui;{style}'><p>{WORDS}</p>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def shoot(tool, pid, numbers, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    said = ""
    for _ in range(3):
        said = subprocess.run([str(tool), str(pid), ",".join(str(n) for n in numbers), str(path)], capture_output=True, text=True).stdout
        if path.exists():
            break
        time.sleep(0.5)
    at = re.search(r"at (-?[\d.]+),(-?[\d.]+),([\d.]+),([\d.]+)", said)
    return [float(v) for v in at.groups()] if at and path.exists() else None


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    tag = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tag=")), "after")
    only = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--only=")), None)
    out = Path(args[0] if args else ROOT / ".context" / "glass-ink" / "over-page")
    tool = vd.tool("windows-shot", "WindowsShot.swift")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    sv.setup(**{"start.fresh": False, "welcome.show": False})
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    numbers = {}
    try:
        pid = next(iter(sv.holding() & sv.running()))
        placed = sv.cmd({"do": "windowbehind"})
        t.ok("the probe's window stays behind and takes no keys", not placed["key"] and not placed["active"], str(placed))
        sv.cmd({"do": "resize", "width": 1000, "height": 640, "steps": 1})
        pages = {}
        for name in PAGES:
            pages[name] = sv.sp("open", url=f"{base}/{name}")["resultID"]
            time.sleep(0.6)
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(0.8)
            for ground, page in pages.items():
                sv.cmd({"do": "select", "id": page})
                time.sleep(1.0)
                for name, kind, show, hide in MEMBERS:
                    if only and name not in only:
                        continue
                    label = f"{name} real, {look} on {ground}"
                    show()
                    time.sleep(1.2)
                    try:
                        said = sv.cmd({"do": "inks", "under": kind})
                    except RuntimeError as error:
                        t.ok(f"{label}: shown", False, str(error)[:160])
                        hide()
                        continue
                    windows = [placed["number"]] + [n for n in said["numbers"] if n != placed["number"]]
                    path = out / name / f"real-{look}-{ground}-{tag}.png"
                    blank = out / name / "blank" / path.name
                    frame = shoot(tool, pid, windows, path)
                    t.ok(f"{label}: pictured", frame is not None)
                    after = sv.cmd({"do": "windowbehind"})
                    t.ok(f"{label}: stays behind and takes no keys", not after["key"] and not after["active"], str(after))
                    sv.cmd({"do": "inks", "under": kind, "blank": True})
                    time.sleep(0.5)
                    bare = shoot(tool, pid, windows, blank)
                    sv.cmd({"do": "inks", "under": kind, "shown": True})
                    hide()
                    time.sleep(0.6)
                    if frame is None or bare is None or frame != bare:
                        t.ok(f"{label}: pictured without its words", False, f"{frame} and {bare}")
                        continue
                    marks = []
                    for mark in said["inks"]:
                        x, y, wide, tall = mark["box"]
                        marks.append({**mark, "box": [x - frame[0], y - frame[1], wide, tall]})
                    try:
                        measured = gi.measure(path, blank, marks, frame[2])
                    except RuntimeError as error:
                        t.ok(f"{label}: measured", False, str(error))
                        continue
                    t.ok(f"{label}: has words or symbols to measure", bool(measured))
                    numbers[label] = measured
                    for mark in measured:
                        need = gi.limit(mark)
                        if mark.get("note") in gi.NOTES:
                            continue
                        t.ok(f"{label}: {gi.named(mark)} reads at {need:g} to 1 or more", mark["worst"] >= need,
                             f"{mark['worst']:g} to 1 at its worst, {mark.get('typical', 0):g} typical, ink {mark.get('ink')}, behind {mark.get('behind')}")
        kept = out / f"ink-{tag}.json"
        kept.parent.mkdir(parents=True, exist_ok=True)
        kept.write_text(json.dumps(numbers, indent=1, sort_keys=True))
        for line in gi.summary(numbers):
            print("  ink  ", line)
        for line in gi.listed(numbers):
            print("  own  ", line)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

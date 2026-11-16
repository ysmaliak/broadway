#!/usr/bin/env python3
"""A film of a ⌘-click on a page landing on its row in a live folder.

Build first (`./build.sh`), then `python3 Tests/live_open_clicks_film.py [LABEL] [light|dark]`.

A shown test copy in a world of its own, against the fake GitHub pr_rows
serves on ::1 and a page of links on 127.0.0.1. Its own window only is
filmed, by its window number (WindowCapture.swift). Films go to
.context/shots/LABEL/: a ⌘-click that points the row and leaves him on the
page, and a ⌘⇧-click that opens the folded folder on the row.
"""
import os
import shutil
import subprocess
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
label = sys.argv[1] if len(sys.argv) > 1 else "live-open-clicks"
theme = sys.argv[2] if len(sys.argv) > 2 else "light"
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

OUT = ROOT / ".context" / "shots" / label
CAPTURE = ROOT / ".context" / "shots" / "capture"
FPS = 60
PULL = f"{pr.BASE}/acme/rocket/pull"
t = sv.T()
LINKS = [
    ("files41", f"{PULL}/41/files", "#41 · the files changed"),
    ("comment45", f"{PULL}/45#issuecomment-4411", "#45 · the comment about the fuel line"),
    ("checks46", f"{PULL}/46/checks", "#46 · its checks"),
]


class Notes(BaseHTTPRequestHandler):
    def do_GET(self):
        rows = "".join(f'<p><a id="{id}" href="{href}">{words}</a></p>' for id, href, words in LINKS)
        body = ("<!doctype html><meta charset=utf-8><title>Release notes</title>"
                "<body style='font:17px -apple-system;padding:48px;line-height:1.9;color-scheme:light dark'>"
                f"<h2>Release notes</h2><p>Three pull requests to look at before Friday.</p>{rows}").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def film(pid, number, name, act, seconds=3.2):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number), "2", str(FPS)],
                         stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.6)
    act()
    print(name, p.communicate()[0].strip(), flush=True)
    frames = sorted(folder.glob("0*.png"))
    out = OUT / f"{name}.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", str(folder / "%04d.png"),
                    "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", str(out)], check=False)
    if frames:
        shutil.copy(frames[-1], OUT / f"{name}-end.png")
        shutil.copy(frames[min(len(frames) - 1, 10)], OUT / f"{name}-start.png")
    shutil.rmtree(folder, ignore_errors=True)
    t.ok(f"filmed {name}", out.exists() and len(frames) > 20, len(frames))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if not CAPTURE.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.srv.RequestHandlerClass = Notes
    sv.use("live-clicks-film-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "tabs.groups": True})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", pr.BASE], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "dev.servers", "-dict", f"127.0.0.1:{sv.srv.server_port}", "-bool", "false"], check=True)
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
        sv.cmd({"do": "resize", "width": 1100, "height": 720, "steps": 1})
        notes = sv.page("release-notes")
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me")
        prs = pr.folder(pr.live("update", "PRs"), "PRs")
        for _ in range(30):
            if prs and len(prs["items"]) == 8:
                break
            time.sleep(1)
            prs = pr.folder(pr.live("update", "PRs"), "PRs")
        t.ok("the folder holds its rows", prs and len(prs["items"]) == 8, prs)
        sv.sp("select", id=notes)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        sv.cmd({"do": "group", "name": "PRs", "fold": True})
        time.sleep(1.5)

        count = len(sv.sp("state")["tabs"])
        film(pid, number, "command-click", lambda: sv.cmd({"do": "tap", "id": notes, "selector": "#files41", "mods": ["cmd"]}))
        st = sv.sp("state")
        t.ok("the ⌘-click added no tab and left him on the page", len(st["tabs"]) == count and st["activeID"] == notes, (len(st["tabs"]), count))
        time.sleep(4.5)
        sv.cmd({"do": "group", "name": "PRs", "fold": True})
        time.sleep(1.2)
        film(pid, number, "command-shift-click", lambda: sv.cmd({"do": "tap", "id": notes, "selector": "#comment45", "mods": ["cmd", "shift"]}))
        st = sv.sp("state")
        t.ok("the ⌘⇧-click added no tab and selected the row", len(st["tabs"]) == count and st["activeID"] != notes, (len(st["tabs"]), count))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

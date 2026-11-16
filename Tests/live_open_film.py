#!/usr/bin/env python3
"""A film of a link from another app landing on its row in a live folder.

Build first (`./build.sh`), then `python3 Tests/live_open_film.py [LABEL] [light|dark]`.

A shown test copy in a world of its own, against the fake GitHub pr_rows
serves on ::1. Its own window only is filmed, by its window number
(WindowCapture.swift). Films go to .context/shots/LABEL/: a link to a row of
a folded folder, and a link to a member of a folded stack.
"""
import os
import shutil
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
label = sys.argv[1] if len(sys.argv) > 1 else "live-open"
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
STACKED = {36: 1, 37: 2, 38: 3}
plain_page = pr.pull_page


def stacked_page(number):
    body = plain_page(number)
    if number not in STACKED:
        return body
    blob = json.dumps({"stack": {"number": 7, "position": STACKED[number], "size": len(STACKED)}})
    return body + f"<script type=\"application/json\" data-target=\"react-app.embeddedData\">{blob}</script>".encode()


pr.pull_page = stacked_page


def film(pid, number, name, act, seconds=3.0):
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
    sv.use("live-open-film-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", pr.BASE], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
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
        loose = [sv.cmd({"do": "open", "url": f"{pr.BASE}/home?{name}"})["id"] for name in ("Release+notes", "Design+review")]
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me")
        prs = pr.folder(pr.live("update", "PRs"), "PRs")
        for _ in range(30):
            if prs and prs.get("stacks"):
                break
            time.sleep(1)
            prs = pr.folder(pr.live("update", "PRs"), "PRs")
        t.ok("the folder holds its rows and a stack", prs and len(prs["items"]) == 8 and prs.get("stacks"), prs)
        sv.sp("select", id=loose[0])
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(1.5)

        film(pid, number, "folded-folder", lambda: sv.cmd({"do": "route", "args": ["arrive", f"{PULL}/41/files"]}))
        time.sleep(1)
        sv.sp("select", id=loose[0])
        time.sleep(0.6)
        pr.live("stack")
        time.sleep(1.2)
        film(pid, number, "folded-stack", lambda: sv.cmd({"do": "route", "args": ["arrive", f"{PULL}/36#issuecomment-4411"]}))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

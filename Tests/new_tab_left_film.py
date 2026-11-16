#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

theme = sys.argv[1] if len(sys.argv) > 1 else "dark"
label = sys.argv[2] if len(sys.argv) > 2 else "after"
top = len(sys.argv) > 3 and sys.argv[3] == "top"
sv.use("new-tab-film-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / label
FRAMES = OUT / "film-frames"
CAPTURE = FRAMES / "capture"
SIDEBAR = 260


def film(pid, number, name, act, seconds=1.0):
    folder = FRAMES / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number)], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.15)
    act()
    p.communicate()
    return folder


def distinct(folder):
    frames = sorted(folder.glob("0*.png"))
    times = json.loads((folder / "times.json").read_text())
    seen, kept = None, []
    for i, frame in enumerate(frames):
        k = max(1, round(int(subprocess.run(["sips", "-g", "pixelWidth", str(frame)], capture_output=True, text=True).stdout.split()[-1]) / 1100))
        crop = folder / f"c{i:04d}.png"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(frame), "-vf", f"crop={SIDEBAR * k}:{300 * k}:0:0", str(crop)], check=True)
        digest = hashlib.sha1(subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(crop), "-f", "rawvideo", "-"],
                                             capture_output=True).stdout).hexdigest()
        if digest != seen:
            kept.append((round((times[i] - times[0]) * 1000), crop))
            seen = digest
    return kept


def sheet(name, kept):
    work = FRAMES / f"sheet-{name}"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    for n, (_, crop) in enumerate(kept):
        os.symlink(crop, work / f"{n:04d}.png")
    columns = min(8, len(kept))
    rows = (len(kept) + columns - 1) // columns
    out = OUT / f"{name}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"tile={columns}x{rows}:padding=4:color=gray", "-frames:v", "1", str(out)], check=True)
    return out


def main():
    t = sv.T()
    FRAMES.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False, "tabs.newAtBottom": not top})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(SIDEBAR)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    name = f"film-{theme}-{'top' if top else 'bottom'}"
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})
        a = sv.page("alpha")
        b = sv.page("bravo")
        for blank in [x["id"] for x in sv.sp("state")["tabs"] if not x["url"].startswith("http")]:
            sv.sp("close", id=blank)
        sv.sp("select", id=a)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(0.8)
        sv.sp("newTab")
        time.sleep(1.0)
        made = sv.sp("state")["activeID"]
        folder = film(pid, number, name, lambda: sv.sp("select", id=b), seconds=2.0)
        kept = distinct(folder)
        print("  distinct frames at", [ms for ms, _ in kept], "ms")
        t.ok(f"{name}: the column was filmed", len(kept) >= 1, kept)
        t.ok(f"{name}: the New Tab is gone", made not in [x["id"] for x in sv.sp("state")["tabs"]])
        print("  sheet", sheet(name, kept).relative_to(ROOT))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.chdir(ROOT)
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv

label = sys.argv[1] if len(sys.argv) > 1 else "now"
look = sys.argv[2] if len(sys.argv) > 2 else "dark"
sv.use("space-press-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "shots" / label
TOOLS = ROOT / ".context"
WIDTH, HEIGHT = 1000, 720
t = sv.T()


def spans(folder, box):
    x, y, w, h = [int(round(v * 2)) for v in box]
    found = []
    for frame in sorted(folder.glob("[0-9]*.png")):
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(frame), "-vf", f"crop={w}:{h}:{x}:{y},format=gray",
                              "-f", "rawvideo", "-"], capture_output=True).stdout
        if len(raw) != w * h:
            found.append(0)
            continue
        ground = sorted(raw)[len(raw) // 2]
        columns = [c for c in range(w) if any(abs(raw[r * w + c] - ground) > 70 for r in range(h))]
        found.append(columns[-1] - columns[0] + 1 if columns else 0)
    return found


def film(name, pid, number, mark, held, off=False, seconds=1.4):
    folder = OUT / f"press-{name}-{look}"
    folder.mkdir(parents=True, exist_ok=True)
    for old in list(folder.glob("*.png")) + [folder / "ready", folder / "times.json"]:
        if old.exists():
            old.unlink()
    capture = subprocess.Popen([str(TOOLS / "capture"), pid, str(folder), str(seconds), str(number), "2"], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or capture.poll() is not None:
            break
        time.sleep(0.025)
    if capture.poll() is not None:
        raise RuntimeError(capture.communicate()[0])
    time.sleep(0.3)
    x, y = mark[0] + mark[2] / 2, mark[1] + mark[3] / 2
    points = [[x, y], [x + 60, y - 60] if off else [x, y]]
    sv.cmd({"do": "film", "action": "drag", "to": "view", "points": points, "step": held, "frames": 1,
            "path": str(folder / "bench"), "region": "0,0,4,4"})
    print(name, capture.communicate()[0].strip(), flush=True)
    for stray in folder.glob("bench-*.png"):
        stray.unlink()
    times = json.loads((folder / "times.json").read_text())
    size = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", str(folder / "0000.png")],
                          capture_output=True, text=True).stdout.strip().split(",")
    wide, high = int(size[0]) / 2, int(size[1]) / 2
    pad = 8
    box = [mark[0] - pad, mark[1] - pad, mark[2] + 2 * pad, mark[3] + 2 * pad]
    crop = f"{box[0] / wide},{box[1] / high},{box[2] / wide},{box[3] / high}"
    subprocess.run([str(TOOLS / "film_strip"), str(folder), str(OUT / f"press-{name}-{look}.png"), "", "12", "120", crop], check=True)
    wide = spans(folder, mark)
    rest = wide[0]
    low = min(wide)
    moving = [(round(times[i] * 1000), wide[i]) for i in range(1, len(wide)) if wide[i] != wide[i - 1] or wide[i] != rest]
    jump = max((abs(b - a) for a, b in zip(wide, wide[1:])), default=0)
    between = sorted({w for w in wide if low < w < rest})
    report = {"rest": rest, "lowest": low, "largestStep": jump, "sizesBetween": between, "moving": moving, "frames": len(wide)}
    (OUT / f"press-{name}-{look}.json").write_text(json.dumps(report, indent=1))
    print("  ", report, flush=True)
    return report


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", "Tests/WindowCapture.swift", "-o", str(TOOLS / "capture")], check=True)
    subprocess.run(["swiftc", "Tests/film_strip.swift", "-o", str(TOOLS / "film_strip")], check=True)
    sv.setup(spaces=True, sidebar=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", look], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
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
        sv.cmd({"do": "resize", "width": WIDTH, "height": HEIGHT, "steps": 1})
        posture = sv.cmd({"do": "idle", "action": "front"})
        time.sleep(1.5)
        sv.cmd({"do": "space", "action": "icon", "icon": "house"})
        time.sleep(0.8)
        mark = sv.cmd({"do": "columnscroll"})["marks"]["Personal"]
        if mark[1] + mark[3] > HEIGHT:
            raise RuntimeError(f"the mark's frame is from before the resize: {mark}")
        print("mark", mark, flush=True)
        number = posture["number"]
        # Given the one space's mark at rest
        # When it is pressed and let go at once, quickly, and after a hold
        tap = film("tap", pid, number, mark, 0.02)
        quick = film("quick", pid, number, mark, 0.08)
        hold = film("hold", pid, number, mark, 0.4)
        again = [film(f"hold-{turn}", pid, number, mark, 0.4) for turn in (2, 3, 4)]
        away = film("away", pid, number, mark, 0.08, off=True)
        # Then
        for name, seen in [("quick", quick), ("hold", hold), ("away", away)] + [(f"hold-{turn + 2}", seen) for turn, seen in enumerate(again)]:
            t.ok(f"{name}: the mark gives under the press", seen["lowest"] < seen["rest"], seen)
            t.ok(f"{name}: it passes through sizes between", len(seen["sizesBetween"]) >= 2, seen)
            t.ok(f"{name}: no jump of more than a third of the way in a frame",
                 seen["largestStep"] * 3 <= max(3, seen["rest"] - seen["lowest"]) + 3, seen)
        t.ok("tap: nothing jumps", tap["largestStep"] <= 2, tap)
        t.ok("every press ends at rest", all(seen["moving"] == [] or seen["moving"][-1][1] != seen["lowest"] for seen in [tap, quick, hold, away] + again))
    finally:
        sv.finish()
    t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

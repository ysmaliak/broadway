#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
label = sys.argv[1] if len(sys.argv) > 1 else "now"
theme = sys.argv[2] if len(sys.argv) > 2 else "dark"
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

STACKED = {36: 1, 37: 2, 38: 3}
plain_page = pr.pull_page


def stacked_page(number):
    body = plain_page(number)
    if number not in STACKED:
        return body
    blob = json.dumps({"stack": {"number": 7, "position": STACKED[number], "size": len(STACKED)}})
    return body + f"<script type=\"application/json\" data-target=\"react-app.embeddedData\">{blob}</script>".encode()


pr.pull_page = stacked_page

OUT = ROOT / ".context" / "shots" / label
CAPTURE = ROOT / ".context" / "shots" / "capture"
SIDEBAR = 260
FPS = 120
t = sv.T()


def trace(action):
    return sv.cmd({"do": "ui", "foldtrace": {"action": action}})


def film(pid, number, name, act, seconds=1.0):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number), "2", str(FPS)],
                         stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.15)
    trace("start")
    act()
    time.sleep(0.8)
    samples = trace("stop")["samples"]
    print(name, p.communicate()[0].strip(), flush=True)
    (folder / "trace.json").write_text(json.dumps(samples))
    return folder, samples


def sheet(name, folder, span=0.45, columns=8, height=300):
    frames = sorted(folder.glob("0*.png"))
    if len(frames) < 4:
        return
    times = json.loads((folder / "times.json").read_text())
    import hashlib
    first = hashlib.sha1(frames[2].read_bytes()).hexdigest()
    start = next((i for i in range(2, len(frames)) if hashlib.sha1(frames[i].read_bytes()).hexdigest() != first), 3)
    start = max(0, start - 1)
    picked = [i for i in range(start, len(frames)) if times[i] - times[start] <= span]
    work = folder / "sheet"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir()
    for n, i in enumerate(picked):
        os.symlink(frames[i], work / f"{n:04d}.png")
    rows = (len(picked) + columns - 1) // columns
    out = OUT / f"{name}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"crop={SIDEBAR * 2}:{height * 2}:0:0,tile={columns}x{rows}:padding=4:color=red",
                    "-frames:v", "1", str(out)], check=True)
    gaps = sorted(b - a for a, b in zip(times, times[1:]))
    rate = round(1 / gaps[len(gaps) // 2]) if gaps and gaps[len(gaps) // 2] > 0 else 60
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(rate), "-start_number", str(start),
                    "-i", str(folder / "%04d.png"), "-vf", f"crop={SIDEBAR * 2}:{height * 2}:0:0",
                    "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")], check=False)
    print("  sheet", out.relative_to(ROOT), f"{len(picked)} frames over {span}s from frame {start}", flush=True)


def measure(name, samples):
    seen = [(s["t"], c) for s in samples for c in s.get("chips", [])]
    if not seen:
        return {"name": name, "frames": 0}
    rest = seen[0][1][:2] if seen[0][0] < 1 else [1.0, 1.0]
    off = [(round(ms), round(c[0] - rest[0], 2), round(c[1] - rest[1], 2), round(c[2], 3), round(c[3], 3))
           for ms, c in seen if abs(c[0] - rest[0]) > 0.25 or abs(c[1] - rest[1]) > 0.25]
    faded = [(round(ms), round(c[2], 3), round(c[3], 3)) for ms, c in seen if abs(c[2] - c[3]) > 0.04]
    worst = max((abs(c[1] - rest[1]) + abs(c[0] - rest[0]) for _, c in seen), default=0)
    report = {"name": name, "frames": len(seen), "rest": [round(v, 2) for v in rest], "worst": round(worst, 2),
              "apart": len(off), "fadedApart": len(faded), "firstApart": off[:12], "firstFaded": faded[:8]}
    print("  measured", json.dumps(report), flush=True)
    return report


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    if not CAPTURE.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.use("stack-chevron-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", pr.BASE], check=True)
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
    found = []
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me")
        pr.live("unfold", "PRs")
        prs = pr.folder(pr.live("update", "PRs"), "PRs")
        for _ in range(30):
            if prs and prs.get("stacks"):
                break
            time.sleep(1)
            prs = pr.folder(pr.live("update", "PRs"), "PRs")
        print("  bylines", [i["byline"] for i in prs["items"]], flush=True)
        t.ok("the folder holds a stack", prs and prs.get("stacks"), prs and prs.get("stacks"))
        time.sleep(1)
        chips = sv.cmd({"do": "rowframes"}).get("chevrons", [])
        t.ok("rowframes lists the one chevron", len(chips) == 1, chips)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(1)

        def toggle(again=None):
            ask = {"do": "group", "name": "PRs", "fold": True}
            if again:
                ask["again"] = again
            return lambda: sv.cmd(ask)

        scenes = [("fold", toggle()), ("unfold", toggle()), ("fold-back", toggle([0.09])), ("unfold-back", toggle([0.09]))]
        for name, act in scenes:
            if name == "unfold-back":
                sv.cmd({"do": "group", "name": "PRs", "fold": True})
                time.sleep(1.2)
            folder, samples = film(pid, number, name, act)
            sheet(name, folder)
            found.append(measure(name, samples))
            time.sleep(1.2)
        pr.live("unfold", "PRs")
        time.sleep(1.2)
        pr.live("stack")
        time.sleep(1)
        for name, act in [("folded-stack-fold", toggle()), ("folded-stack-unfold", toggle())]:
            folder, samples = film(pid, number, name, act)
            sheet(name, folder)
            found.append(measure(name, samples))
            time.sleep(1.2)
        (OUT / "measured.json").write_text(json.dumps(found, indent=1))
        for row in found:
            t.ok(f"{row['name']}: the chip stays on its icon in every frame ({row.get('frames')} frames)",
                 row.get("frames", 0) > 5 and row.get("apart") == 0 and row.get("fadedApart") == 0, row)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

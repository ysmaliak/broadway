#!/usr/bin/env python3
"""Stacked spaces on film: a test copy's own window, nothing else.

Build first (`./build.sh`), then `python3 Tests/stacked_spaces_film.py dark [label]`
(or light). A world of its own, shown so ScreenCaptureKit can take that one
window (Tests/WindowCapture.swift); films land in .context/ as
stacked-<scene>-<theme>.mp4: a jump to a section, a tab picked in another
section and two sections away, a section folded and unfolded, the front
space folded and unfolded, the section whose heading is held folded, a fold
reversed halfway, a slow scroll through the held headings, rubber bands and
a fast wheel, the wheel over a front section taller than the window, a row
carried to another section, a header carried below the others.

With a label, contact sheets of each motion (every frame of its first half
second, cropped to the sidebar) land in .context/stacked-motion/<label>/,
with the scroll trace and the nested-scroll numbers in <label>/numbers.json.
"""
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
import stacked_spaces as ss  # noqa: E402

theme = sys.argv[1] if len(sys.argv) > 1 else "dark"
label = sys.argv[2] if len(sys.argv) > 2 else None
sv.use("stacked-film-" + uuid.uuid4().hex[:6])
CONTEXT = ROOT / ".context"
FRAMES = CONTEXT / "stacked-frames"
CAPTURE = FRAMES / "capture"
SHEETS = CONTEXT / "stacked-motion" / label if label else None
SIDEBAR = 260
numbers = {}


def film(name, act, seconds=1.2):
    folder = FRAMES / f"{name}-{theme}"
    shutil.rmtree(folder, ignore_errors=True)
    posture = sv.cmd({"do": "idle", "action": "unhide"})
    p = subprocess.Popen([str(CAPTURE), pid, str(folder), str(seconds), str(posture["number"])],
                         stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None: break
        time.sleep(0.025)
    if p.poll() is not None: raise RuntimeError(p.communicate()[0])
    time.sleep(0.15)
    act()
    print(name, p.communicate()[0].strip(), flush=True)
    frames = sorted(folder.glob("0*.png"))
    movie = CONTEXT / f"stacked-{name}-{theme}.mp4"
    if frames:
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                        "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", str(movie)], check=True)
        shutil.copy(frames[-1], CONTEXT / f"stacked-{name}-{theme}.png")
    return len(frames)


def sheet(name, top=0, height=None, span=0.5, every=1, start=None, after=0.0, columns=10, source=None):
    if not SHEETS: return
    folder = FRAMES / f"{source or name}-{theme}"
    frames = sorted(folder.glob("0*.png"))
    if not frames: return
    times = json.loads((folder / "times.json").read_text())
    if start is None:
        first = hashlib.sha1(frames[0].read_bytes()).hexdigest()
        start = next((i for i, f in enumerate(frames) if hashlib.sha1(f.read_bytes()).hexdigest() != first), 0)
        start = max(0, start - 1)
    if after:
        start = next((i for i in range(start, len(frames)) if times[i] - times[start] >= after), start)
    picked = [i for i in range(start, len(frames)) if times[i] - times[start] <= span][::every]
    work = FRAMES / f"sheet-{name}"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    for n, i in enumerate(picked):
        os.symlink(frames[i], work / f"{n:04d}.png")
    rows = (len(picked) + columns - 1) // columns
    crop = f"crop={SIDEBAR}:{height or 'ih'}:0:{top}"
    SHEETS.mkdir(parents=True, exist_ok=True)
    out = SHEETS / f"{name}-{theme}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"{crop},tile={columns}x{rows}:padding=4:color=gray", "-frames:v", "1", str(out)], check=True)
    print("  sheet", out.relative_to(ROOT), f"frames {start}..{picked[-1] if picked else start} of {len(frames)}", flush=True)


def tabs(prefix, count):
    return [sv.page(f"{prefix}-{k}") for k in range(1, count + 1)]


def main():
    t = sv.T()
    FRAMES.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.setup(spaces=True, **{"spaces.stacked": True, "tabs.groups": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    global pid
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 1})
        first = sv.sp("state")["spaceID"]
        personal = tabs("one", 7)
        a = personal[0]
        work = sv.sp("space", spaceAction="new", name="Work")["spaceID"]
        worked = tabs("work", 6)
        d = worked[1]
        sv.sp("space", spaceAction="new", name="Travel")
        travel = tabs("travel", 3)
        e = travel[0]
        sv.sp("space", spaceAction="new", name="Reading")
        tabs("reading", 5)
        sv.sp("space", spaceAction="go", spaceID=first)
        sv.sp("select", id=a)
        r = ss.settle(lambda r: all(s["header"] for s in r["sections"]), action="load")
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(0.6)
        shots = {}
        shots["pick"] = film("pick", lambda: ss.st(action="select", id=d))
        sheet("pick", height=200)
        ss.st(action="select", id=a)
        time.sleep(0.6)
        shots["pick2"] = film("pick2", lambda: ss.st(action="select", id=e))
        sheet("pick2", height=200)
        ss.st(action="select", id=a)
        time.sleep(0.6)
        ss.st(action="scroll", y=0)
        time.sleep(0.3)
        shots["fold"] = film("fold", lambda: ss.st(action="fold", space=2))
        sheet("fold", every=1)
        time.sleep(0.4)
        shots["unfold"] = film("unfold", lambda: ss.st(action="fold", space=2, on=False))
        sheet("unfold", every=1)
        time.sleep(0.4)
        ss.st(action="select", id=personal[3])
        time.sleep(0.6)
        shots["foldfront"] = film("foldfront", lambda: ss.st(action="fold", space=1))
        sheet("foldfront", every=1)
        time.sleep(0.4)
        shots["unfoldfront"] = film("unfoldfront", lambda: ss.st(action="fold", space=1, on=False))
        sheet("unfoldfront", every=1)
        time.sleep(0.4)

        def reverse():
            ss.st(action="fold", space=2)
            time.sleep(0.07)
            ss.st(action="fold", space=2, on=False)

        shots["reverse"] = film("reverse", reverse)
        sheet("reverse", span=0.6)
        time.sleep(0.4)
        r = ss.st()
        held_at = ss.section(r, 1)["header"]["y"] + 120
        ss.st(action="scroll", y=held_at)
        time.sleep(0.5)
        r = ss.st()
        numbers["foldheld.before"] = {"scrolled": r["scrolled"], "headers": [s["header"] for s in r["sections"]]}
        shots["foldheld"] = film("foldheld", lambda: ss.st(action="fold", space=2))
        sheet("foldheld", every=1)
        time.sleep(0.5)
        r = ss.st()
        numbers["foldheld.after"] = {"scrolled": r["scrolled"], "headers": [s["header"] for s in r["sections"]]}
        ss.st(action="fold", space=2, on=False)
        ss.st(action="scroll", y=0)
        time.sleep(0.6)

        sv.cmd({"do": "resize", "width": 1120, "height": 560, "steps": 1})
        time.sleep(0.8)
        r = ss.st()
        bottom = max(0, r["content"] - r["viewport"])
        numbers["scroll.size"] = {"content": r["content"], "viewport": r["viewport"]}
        seconds = bottom / 3 / 60 + 0.6
        shots["scroll"] = film("scroll", lambda: ss.st(action="run", **{"from": 0, "to": bottom, "step": 3}), seconds=seconds)
        heads = [s["header"]["y"] for s in r["sections"][1:]]
        for k, y in enumerate(heads):
            sheet(f"scroll-catch{k + 2}", source="scroll", after=max(0.0, (y - 30) / 3 / 60), span=0.4, height=300)
        r = ss.st(trace=True)
        numbers["scroll.end"] = {"scrolled": r["scrolled"]}
        numbers["scroll.trace"] = r.get("trace", [])
        time.sleep(0.4)
        shots["bandbottom"] = film("bandbottom", lambda: ss.st(action="wheel", dy=-160, steps=8, ms=130, y=300), seconds=1.4)
        sheet("bandbottom", span=0.8, every=2)
        ss.st(action="scroll", y=0)
        time.sleep(0.4)
        shots["bandtop"] = film("bandtop", lambda: ss.st(action="wheel", dy=160, steps=8, ms=130, y=300), seconds=1.4)
        sheet("bandtop", span=0.8, every=2)
        time.sleep(0.4)
        shots["wheelfast"] = film("wheelfast", lambda: ss.st(action="wheel", dy=-900, steps=6, ms=90, glide=30, y=300), seconds=1.6)
        sheet("wheelfast", span=0.8, every=2)
        ss.st(action="scroll", y=0)
        time.sleep(0.4)

        tabs("one-more", 10)
        ss.st(action="select", id=a)
        ss.st(action="scroll", y=0)
        time.sleep(0.8)
        r = ss.st()
        numbers["nested.before"] = {"scrolled": r["scrolled"], "inner": r["inner"], "content": r["content"]}
        shots["nested"] = film("nested", lambda: ss.st(action="wheel", dy=-240, steps=10, ms=200, glide=20, y=200), seconds=1.6)
        sheet("nested", span=1.0, every=2)
        time.sleep(0.3)
        r = ss.st()
        numbers["nested.after"] = {"scrolled": r["scrolled"], "inner": r["inner"]}
        shots["nestedup"] = film("nestedup", lambda: ss.st(action="wheel", dy=200, steps=10, ms=200, y=200), seconds=1.4)
        r = ss.st()
        numbers["nested.up"] = {"scrolled": r["scrolled"], "inner": r["inner"]}
        moved_inside = any(abs(v) > 0.5 for k in ("nested.after", "nested.up") for v in numbers[k]["inner"].values())
        print("  ..   nested:", json.dumps({k: numbers[k] for k in numbers if k.startswith("nested")}))
        t.ok("no section's own list moved under the wheel", not moved_inside)
        t.ok("the wheel over the front section moved the column", numbers["nested.after"]["scrolled"] > 20,
             numbers["nested.after"]["scrolled"])
        if SHEETS:
            (SHEETS / "numbers.json").write_text(json.dumps(numbers, indent=1))

        sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 1})
        ss.st(action="fold", space=2, on=False)
        ss.st(action="jump", space=1)
        time.sleep(0.6)
        r = ss.st()
        shots["drag"] = film("drag", lambda: ss.carry(r, a, 1), seconds=1.4)
        r = ss.settle(lambda r: a in ss.section(r, 1)["tabs"])
        t.ok("the carried row reached Work", a in ss.section(r, 1)["tabs"])

        def reorder():
            ss.st(action="lift", space=1)
            time.sleep(0.3)
            for k in range(1, 41):
                ss.st(action="carry", dy=120 * k / 40)
                time.sleep(0.012)
            time.sleep(0.35)
            ss.st(action="letgo")

        time.sleep(0.6)
        shots["reorder"] = film("reorder", reorder, seconds=2.4)
        r = ss.settle(lambda r: [s["name"] for s in r["sections"]][0] == "Work")
        names = [s["name"] for s in r["sections"]]
        t.ok("the carried header took Personal below the others", names[0] == "Work" and names.index("Personal") >= 2, names)
        t.ok(f"every scene filmed in {theme}", all(n > 1 for n in shots.values()), shots)
        posture = ss.negatives([pid])
        print(f"  ..   invalid view geometry while filming: {posture} (the shown window's capture posture; "
              "Tests/stacked_spaces.py checks the stacked column itself for none)")
        (CONTEXT / f"stacked-films-{theme}.json").write_text(json.dumps({"frames": shots, "pid": pid, "world": sv.W,
                                                                          "geometryWarnings": posture}))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

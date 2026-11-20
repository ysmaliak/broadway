#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import visual_diff as vd  # noqa: E402

sv.use("update-close")
t = sv.T()
SIZE = [1100, 720]
TINT = {"colours": ["FF89B3", "FF8A1F"], "intensity": 0.75}
GROUNDS = ("plain", "tinted")
WIDTHS = (258, 200)
EDGE = 4


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    return int(next(iter(sv.holding() & sv.running())))


def crop(source, dest, view, column, scale):
    top = max(0, view[1] - 40)
    bottom = column[1] + column[3]
    box = [int(column[0] * scale), int(top * scale), int(column[2] * scale), int((bottom - top) * scale)]
    done = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(source), "-vf", "crop={2}:{3}:{0}:{1}".format(*box), str(dest)],
                          capture_output=True, text=True)
    return done.returncode == 0 and dest.exists()


def corner(source, dest, close, height, scale):
    top = height - (close[1] + close[3]) - 10
    box = [0, int(max(0, top) * scale), int(60 * scale), int(40 * scale)]
    done = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(source), "-vf",
                           "crop={2}:{3}:{0}:{1},scale=iw*4:ih*4:flags=neighbor".format(*box), str(dest)], capture_output=True, text=True)
    return done.returncode == 0 and dest.exists()


def pictures(out, label):
    shot = vd.tool("shot", "WindowShot.swift")
    out.mkdir(parents=True, exist_ok=True)
    measures = {}
    staged = [1000]
    for ground in GROUNDS:
        for width in WIDTHS:
            sv.setup(**{"sidebar": True, "start.fresh": False})
            subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(width)], check=True)
            pid = launch()
            try:
                for n in range(3):
                    sv.cmd({"do": "open", "url": f"about:blank#{n}"})
                time.sleep(1)
                if ground == "tinted":
                    sv.cmd({"do": "space", "action": "look", **TINT})
                for look in ("light", "dark"):
                    staged[0] += 1
                    sv.cmd({"do": "updates", "stage": "9.9", "build": str(staged[0])})
                    number = sv.cmd({"do": "agents", "action": "stage", "dark": look == "dark", "shown": True, "size": SIZE})["window"]
                    time.sleep(1.2)
                    said = sv.cmd({"do": "updates", "hover": True}).get("sidebar", {})
                    time.sleep(0.8)
                    said = sv.cmd({"do": "updates"}).get("sidebar", {})
                    called = f"{label}-{width}-{look}-{ground}"
                    card = said.get("card") or {}
                    view = said.get("view")
                    column = said.get("column")
                    t.ok(f"{called}: the update card is shown", bool(said.get("shown")) and bool(view), str(said.get("shown")))
                    t.ok(f"{called}: its close key is showing", card.get("closeShown") is True, str(card.get("closeShown")))
                    whole = out / f".{called}-whole.png"
                    subprocess.run([str(shot), str(pid), str(number), str(whole)], capture_output=True, text=True)
                    content = sv.cmd({"do": "probe"})
                    height = column[1] + column[3] if column else 0
                    scale = 2
                    if whole.exists() and view and column:
                        made = subprocess.run(["sips", "-g", "pixelWidth", str(whole)], capture_output=True, text=True).stdout.split()
                        scale = round(int(made[-1]) / SIZE[0])
                        t.ok(f"{called}: pictured", crop(whole, out / f"{called}.png", view, column, scale))
                        corner(whole, out / f"{called}-corner.png", card.get("closeDrawn", card.get("close")), height, scale)
                    else:
                        t.ok(f"{called}: pictured", False, "no window picture")
                    whole.unlink(missing_ok=True)
                    close = card.get("close") or [0, 0, 0, 0]
                    drawn = card.get("closeDrawn") or close
                    measures[called] = {"close": close, "drawn": drawn, "card": card.get("card"), "column": column,
                                        "fromLeft": round(close[0], 2), "drawnFromLeft": round(drawn[0], 2),
                                        "fromBottom": round(drawn[1], 2), "columnWidth": content.get("columnWidth")}
                    print(f"  {called}: key at {close[0]:.2f} from the left edge, {drawn[0]:.2f} while the card is grown, "
                          f"{drawn[1]:.2f} up from the window's foot")
                    sv.cmd({"do": "updates", "hover": False})
            finally:
                sv.quit()
                sv.finish()
    (out / f"measures-{label}.json").write_text(json.dumps(measures, indent=1, sort_keys=True))
    return measures


def peeks(out, label):
    shot = vd.tool("shot", "WindowShot.swift")
    out.mkdir(parents=True, exist_ok=True)
    measures = {}
    for width in (420, 258):
        sv.setup(**{"sidebar": True, "start.fresh": False})
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(width)], check=True)
        pid = launch()
        try:
            sv.cmd({"do": "open", "url": "about:blank#page"})
            time.sleep(1)
            for look in ("light", "dark"):
                number = sv.cmd({"do": "agents", "action": "stage", "dark": look == "dark", "shown": True, "size": [640, 560]})["window"]
                sv.cmd({"do": "peek", "url": "about:blank#peek"})
                time.sleep(1.5)
                said = sv.cmd({"do": "probe"})
                knobs = said.get("peekKnobs")
                called = f"{label}-peek-{width}-{look}"
                t.ok(f"{called}: the peek's knobs are shown", bool(knobs), str(knobs))
                whole = out / f".{called}-whole.png"
                subprocess.run([str(shot), str(pid), str(number), str(whole)], capture_output=True, text=True)
                if whole.exists() and knobs:
                    made = subprocess.run(["sips", "-g", "pixelWidth", str(whole)], capture_output=True, text=True).stdout.split()
                    scale = round(int(made[-1]) / knobs[4])
                    left = max(0, knobs[4] - 260)
                    box = [int(left * scale), 0, int((knobs[4] - left) * scale), int(min(220, knobs[1] + knobs[3] + 40) * scale)]
                    done = subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(whole), "-vf", "crop={2}:{3}:{0}:{1}".format(*box),
                                           str(out / f"{called}.png")], capture_output=True, text=True)
                    t.ok(f"{called}: pictured", done.returncode == 0)
                    gap = knobs[4] - knobs[0] - knobs[2]
                    measures[called] = {"knobs": knobs, "fromRight": round(gap, 2), "fromTop": round(knobs[1], 2)}
                    print(f"  {called}: knobs end {gap:.2f} from the window's right edge, {knobs[1]:.2f} from its top")
                else:
                    t.ok(f"{called}: pictured", False, "no window picture")
                whole.unlink(missing_ok=True)
                sv.cmd({"do": "peek", "url": "close"})
                time.sleep(0.8)
        finally:
            sv.quit()
            sv.finish()
    (out / f"peek-measures-{label}.json").write_text(json.dumps(measures, indent=1, sort_keys=True))
    return measures


if __name__ == "__main__":
    args = sys.argv[1:]
    out = Path(args[0])
    label = args[1]
    measures = pictures(out, label)
    peeked = peeks(out, label)
    if len(args) > 2 and args[2] == "check":
        for called, said in sorted(measures.items()):
            t.ok(f"{called}: the key sits {EDGE} points or more inside the window", said["fromLeft"] >= EDGE and said["drawnFromLeft"] >= EDGE,
                 json.dumps(said))
        for called, said in sorted(peeked.items()):
            t.ok(f"{called}: the knobs sit {EDGE} points or more inside the window", said["fromRight"] >= EDGE, json.dumps(said))
    t.done()
    sys.exit(1 if t.failed else 0)

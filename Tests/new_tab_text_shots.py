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
sys.path.insert(0, str(ROOT / "Tests"))
label = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
import split_view as sv
import raised_look_shots as rl

sv.use("ntp-text-" + uuid.uuid4().hex[:6])
TMP = Path("/tmp") / f"broadway-ntp-text-{os.getpid()}"
OUT = ROOT / ".context" / "ntp-text" / label
rl.SHOT = TMP / "shot"
MEASURE = TMP / "measure"
KEYS = {"a": 0, "b": 11, "e": 14, "h": 4, "i": 34, "o": 31, "r": 15, "s": 1, "t": 17, "u": 32, "y": 16}


def press(code, chars, mods=()):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})


def type_text(text):
    for ch in text:
        press(KEYS[ch.lower()], ch, ["shift"] if ch.isupper() else [])
    time.sleep(0.4)


def clear():
    for _ in range(60):
        state = sv.cmd({"do": "sitesearch", "action": "state"})
        if not state["typed"] and not state["chip"]:
            break
        sv.cmd({"do": "sitesearch", "action": "delete"})
    sv.cmd({"do": "sitesearch", "action": "delete"})
    time.sleep(0.4)


def trim():
    for _ in range(20):
        if not sv.cmd({"do": "sitesearch", "action": "state"})["typed"]:
            break
        sv.cmd({"do": "sitesearch", "action": "delete"})


def still(name):
    raw = TMP / f"{name}-raw.png"
    out = TMP / f"{name}.png"
    for attempt in range(4):
        try:
            rl.shoot(pid, number, raw)
            break
        except RuntimeError:
            if attempt == 3:
                raise
            sv.cmd({"do": "idle", "action": "unhide"})
            time.sleep(0.8)
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(raw), "--out", str(out)],
                   capture_output=True, check=True)
    return out


def crop(src, box, path):
    k = max(1, round(rl.scale_of(src)))
    x, y, w, h = box[0] - 12, box[1] - 12, min(box[2], 360) + 12, box[3] + 24
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int(w * k)}:{int(h * k)}:{int(x * k)}:{int(y * k)}", str(path)], check=True)


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    for src, dst in [("WindowShot.swift", rl.SHOT), ("NewTabTextMeasure.swift", MEASURE)]:
        copy = TMP / src
        shutil.copy(ROOT / "Tests" / src, copy)
        subprocess.run(["swiftc", "-parse-as-library", str(copy), "-o", str(dst)], check=True, cwd=TMP)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False, "split": True})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    rows = []
    try:
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "resize", "width": 1100, "height": 700, "steps": 1})
        sv.cmd({"do": "idle", "action": "front"})

        def blank():
            return [x["id"][:8].lower() for x in sv.cmd({"do": "tabs"})["tabs"] if not x["url"].startswith("http")][0]

        def shoot(name, measure_caret, skip=3):
            time.sleep(0.8)
            got = sv.cmd({"do": "newtabframes"})
            page = next((p for p in got["pages"] if p["text"]), None)
            if not page:
                t.ok(f"{name}: a field with text", False)
                return
            shot = still(name)
            crop(shot, page["field"], OUT / f"{name}.png")
            text, lens = page["text"], page["lens"]
            boxes = [lens, [text[0] + skip, text[1], 60, text[3]], [text[0] - 1, text[1], 3.5, text[3]] if measure_caret else [0, 0, 0, 0]]
            args = [str(MEASURE), str(shot), str(got["window"][0]), *map(str, page["field"])] + [str(v) for b in boxes for v in b]
            m = json.loads(subprocess.run(args, capture_output=True, text=True, check=True).stdout)
            mid = m["mid"]
            centre = lambda band: None if band is None else round((band[0] + band[1]) / 2 - mid, 2)
            row = {"case": name, "field": page["field"], "text": text, "mid": mid, "lens": m["bands"][0], "glyphs": m["bands"][1],
                   "caret": m["bands"][2], "lensOff": centre(m["bands"][0]), "glyphsOff": centre(m["bands"][1]),
                   "caretOff": centre(m["bands"][2])}
            rows.append(row)
            print(f"  {name}: lens {row['lensOff']} text {row['glyphsOff']} caret {row['caretOff']} (pt from the midline; bands {m['bands']})")
            t.ok(f"{name}: magnifier on the midline", row["lensOff"] is not None and abs(row["lensOff"]) <= 0.75, row["lensOff"])
            t.ok(f"{name}: text on the midline", row["glyphsOff"] is not None and abs(row["glyphsOff"]) <= 0.75, row["glyphsOff"])

        for look in ["light", "dark"]:
            sv.cmd({"do": "ui", "look": look})
            sv.sp("select", id=blank())
            time.sleep(0.6)
            shoot(f"{look}-empty", True)
            type_text("HHHHHHHH")
            shoot(f"{look}-typed", False)
            clear()
            type_text("youtube")
            press(48, "\t")
            time.sleep(0.3)
            trim()
            type_text("HHHHHH")
            shoot(f"{look}-site", False, skip=100)
            clear()
            type_text("history")
            press(48, "\t")
            time.sleep(0.3)
            trim()
            type_text("HHHHHH")
            shoot(f"{look}-place", False, skip=100)
            clear()
            sv.cmd({"do": "sitesearch", "action": "esc"})
            other = rl.opened("blue", "Other")
            sv.sp("newTab")
            time.sleep(0.4)
            sv.sp("pair", id=blank(), **{"with": other}, side="left")
            time.sleep(0.8)
            sv.sp("select", id=other)
            sv.sp("focus", id=other)
            shoot(f"{look}-resting", False)
            sv.sp("close", id=other)
            time.sleep(0.6)
        (OUT / "results.json").write_text(json.dumps(rows, indent=1))
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

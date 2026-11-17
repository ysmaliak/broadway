#!/usr/bin/env python3
"""A Split View pinned as one item among the pins, in light and dark.

Build first (`./build.sh`), then `python3 Tests/pinned_split_shots.py`. A world
of its own opens in the background, four made-up pages come up, one is pinned
alone and two are paired and pinned as a split. The window is put below every
ordinary window, never key, and pictured by its own id into
.context/pinned-split/.
"""
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
import raised_look_shots as rl  # noqa: E402

sv.use("pinned-split-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "pinned-split"
TMP = OUT / "work"
rl.SHOT = TMP / "shot"
WIDTH = 258
drawn = []


def still(name):
    raw = TMP / f"{name}-raw.png"
    out = OUT / f"{name}.png"
    try:
        rl.shoot(pid, number, raw)
    except RuntimeError as e:
        print(f"  capture of {name} failed ({e}), drawn offscreen instead")
        drawn.append(name)
        sv.cmd({"do": "windowpicture", "path": str(out)})
        return out
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(raw), "--out", str(out)],
                   capture_output=True, check=True)
    return out


def crop(src, box, path):
    k = max(1, round(rl.scale_of(src)))
    x, y, w, h = box
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int(w * k)}:{int(h * k)}:{int(max(0, x) * k)}:{int(max(0, y) * k)}", str(path)], check=True)


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    TMP.mkdir(parents=True, exist_ok=True)
    copy = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", copy)
    subprocess.run(["swiftc", "-parse-as-library", str(copy), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(**{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True, "split": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(WIDTH)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})
        alone = rl.opened("orange", "Pond calendar")
        left = rl.opened("blue", "Reading list")
        right = rl.opened("green", "Pricing")
        loose = rl.opened("violet", "Reed notes")
        time.sleep(2)
        made = {i[:8].lower() for i in (alone, left, right, loose)}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        sv.cmd({"do": "pin", "id": alone})
        sv.sp("pair", id=right, **{"with": left}, side="right")
        time.sleep(0.8)
        said = sv.cmd({"do": "pin", "id": left, "split": True})
        t.ok("the split is pinned", said["pinnedSplit"], said)
        st = sv.sp("state")
        t.ok("both pages and the lone pin are pins", len(st["pins"]) == 3, st["pins"])
        t.ok("the split is still one", any(left in p["tabs"] and right in p["tabs"] for p in st["splits"]), st["splits"])
        placed = sv.cmd({"do": "windowbehind"})
        number = placed["number"]
        t.ok("the probe's window stays behind and takes no keys", not placed["key"] and not placed["active"], placed)
        side = [0, 0, WIDTH + 12, 200]
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(0.8)
            sv.sp("select", id=left)
            time.sleep(1.0)
            crop(still(f"window-{look}-split-in-front"), side, OUT / f"pins-{look}-split-in-front.png")
            sv.sp("select", id=loose)
            time.sleep(1.0)
            crop(still(f"window-{look}-tab-in-front"), side, OUT / f"pins-{look}-tab-in-front.png")
        print(OUT)
        print("real window pictures" if not drawn else f"drawn offscreen: {drawn}")
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
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

sv.use("split-tint-" + uuid.uuid4().hex[:6])
TMP = Path("/tmp") / f"broadway-split-tint-{os.getpid()}"
OUT = ROOT / ".context" / "split-tint" / label
rl.SHOT = TMP / "shot"
WIDTH = 258
GROUNDS = {
    "near": {"custom": "000000", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
}
CASES = [("dark", "near"), ("light", "pale"), ("dark", "vivid"), ("light", "vivid")]


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
    x, y, w, h = box
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int(w * k)}:{int(h * k)}:{int(x * k)}:{int(y * k)}", str(path)], check=True)


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    copy = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests/WindowShot.swift", copy)
    subprocess.run(["swiftc", "-parse-as-library", str(copy), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True, "split": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(WIDTH)], check=True)
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
        sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})
        rows = [rl.opened(icon, title) for icon, title in
                [("blue", "Mobile Sync"), ("violet", "My issues"), ("black", "Kit Moreau (@kitmoreau) on X"),
                 ("black", "Hana Ito on X"), ("green", "Release notes")]]
        time.sleep(2)
        made = {i[:8].lower() for i in rows}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        above, left, right, below = rows[1], rows[2], rows[3], rows[4]
        sv.sp("pair", id=right, **{"with": left}, side="right")
        time.sleep(1.0)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]

        def box():
            got = sv.cmd({"do": "rowframes"})["rows"]
            top, under = got.get(rows[0][:8].lower()), got.get(below[:8].lower())
            if not top or not under:
                return None
            return [0, max(0, top[1] - 8), WIDTH + 12, under[1] + under[3] + 8 - max(0, top[1] - 8)]

        def hover(id, on):
            try:
                sv.cmd({"do": "rowhover", "id": id[:8].lower(), "on": on})
                return True
            except RuntimeError as e:
                print("  no hover:", e)
                return False

        def focus(id):
            sv.sp("select", id=id)
            time.sleep(0.3)
            sv.sp("focus", id=id)

        states = [
            ("left-focused", lambda: focus(left), None, left),
            ("right-focused", lambda: focus(right), None, right),
            ("right-focused-left-hovered", lambda: (focus(right), time.sleep(0.4), hover(left, True), time.sleep(0.5), hover(left, True)),
             lambda: hover(left, False), right),
            ("row-selected", lambda: sv.sp("select", id=above), None, above),
        ]
        for theme, ground in CASES:
            sv.cmd({"do": "ui", "look": theme})
            sv.cmd({"do": "space", "action": "look", **GROUNDS[ground]})
            sv.cmd({"do": "ui", "windowPointer": [900, 600], "pointerPhase": "move"})
            for name, prep, undo, front in states:
                prep()
                time.sleep(1.0)
                tag = f"{theme}-{ground}-{name}"
                active = sv.sp("state")["activeID"]
                t.ok(f"{tag}: the keys go to the page meant", active == front, (active, front))
                area = box()
                t.ok(f"{tag}: the rows have frames", area is not None)
                if area is None:
                    continue
                crop(still(tag), area, OUT / f"{tag}.png")
                print(f"  {tag}")
                if undo:
                    undo()
                    time.sleep(0.3)
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

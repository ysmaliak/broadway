#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "now"
themes = [a for a in sys.argv[2:] if a in ("dark", "light")] or ["dark", "light"]
OUT = ROOT / ".context" / "shots" / label
TOOLS = ROOT / ".build" / "downloads-shots"
WINDOWS = TOOLS / "windows-shot"
MENU = TOOLS / "menu-shot"
STAGES = [s for s in ["empty", "running", "kept", "failed", "many"] if s in os.environ.get("ONLY", s)]
NATIVE = os.environ.get("NATIVE", "1") == "1"
HOVER = {"kept": 1, "many": 7, "failed": 0}
PLACES = [p for p in os.environ.get("PLACES", "middle,left").split(",") if p]
WORK = "00000000-0000-0000-0000-0000000000B2"
SIZE = (1000, 720)
PAD = 28
t = sv.T()


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    for source, out in ((ROOT / "Tests/WindowsShot.swift", WINDOWS), (ROOT / "Tests/MenuShot.swift", MENU)):
        if not out.exists() or out.stat().st_mtime < source.stat().st_mtime:
            subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(out)], check=True)


def start(theme):
    sv.use("downloads-shots-" + uuid.uuid4().hex[:6])
    sv.setup(spaces=True, **{"start.fresh": False})
    os.makedirs(sv.SUPPORT, exist_ok=True)
    Path(sv.SUPPORT, "spaces.json").write_text(json.dumps([
        {"id": sv.FIRST_SPACE, "name": "Personal", "colour": 0},
        {"id": WORK, "name": "Work", "colour": 0, "sharesSignIns": True},
    ]))
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
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
    sv.cmd({"do": "resize", "width": SIZE[0], "height": SIZE[1], "steps": 1})
    sv.cmd({"do": "ui", "windowAt": "bottom"})
    sv.sp("open", url=f"{sv.BASE}/page")
    time.sleep(1)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    time.sleep(1)
    return pid, number


def windows():
    return sv.cmd({"do": "probe"})["windows"]


def popup():
    kinds = ("KitPopupPanel", "_NSPopoverWindow")
    found = [w for w in windows() if w["kind"] in kinds and w["visible"]]
    return found[-1] if found else None


def until(check, within=5.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.15)
    return check()


def union(a, b):
    x, y = min(a[0], b[0]), min(a[1], b[1])
    return [x, y, max(a[0] + a[2], b[0] + b[2]) - x, max(a[1] + a[3], b[1] + b[3]) - y]


def crop(whole, cut, frame, box):
    scale = 2
    x = max(0, box[0] - frame[0] - PAD)
    top = max(0, (frame[1] + frame[3]) - (box[1] + box[3]) - PAD)
    width = min(frame[2] - x, box[2] + PAD * 2)
    height = min(frame[3] - top, box[3] + PAD * 2)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(whole), "-vf",
                    f"crop={int(width * scale)}:{int(height * scale)}:{int(x * scale)}:{int(top * scale)}", str(cut)], check=True)


def downloads(pid, number, name, stage):
    sv.cmd({"do": "ui", "downloadsStage": stage})
    time.sleep(0.3)
    sv.cmd({"do": "ui", "recentdownloads": True})
    up = until(popup)
    t.ok(f"{name}: opened", bool(up))
    if not up:
        return
    time.sleep(0.9)
    up = popup() or up
    main = next(w for w in windows() if w["number"] == number)
    whole = OUT / f"{name}-window.png"
    said = subprocess.run([str(WINDOWS), str(pid), f"{number},{up['number']}", str(whole)],
                          capture_output=True, text=True).stdout.strip()
    made = whole.exists() and said.startswith("shot")
    t.ok(f"{name}: pictured", made, said)
    if made:
        crop(whole, OUT / f"{name}.png", union(main["frame"], up["frame"]), up["frame"])
        (OUT / f"{name}.json").write_text(json.dumps({"popup": up, "window": main["frame"]}))
    if made and stage in HOVER and up["kind"] != "KitPopupPanel":
        rows = sv.cmd({"do": "downloadslist"})["rows"]
        (OUT / f"{name}.rows.json").write_text(json.dumps(rows, indent=1))
        lit = OUT / f"{name}-lit.png"
        for tag, row in (("hover", HOVER[stage]), ("foot", len(rows) - 2)):
            sv.cmd({"do": "downloadslist", "action": "select", "row": row})
            time.sleep(0.4)
            subprocess.run([str(WINDOWS), str(pid), f"{number},{up['number']}", str(lit)], capture_output=True, text=True)
            crop(lit, OUT / f"{name}-{tag}.png", union(main["frame"], up["frame"]), up["frame"])
        lit.unlink(missing_ok=True)
        sv.cmd({"do": "downloadslist", "action": "select", "row": -1})
    if made and stage != "many":
        whole.unlink()
    sv.cmd({"do": "ui", "recentdownloads": False})
    t.ok(f"{name}: closed", bool(until(lambda: not popup(), 3)))
    time.sleep(0.3)


def still_open():
    try:
        sv.cmd({"do": "ctxmenu", "action": "read"})
        return True
    except RuntimeError:
        return False


def close_menu():
    try:
        sv.cmd({"do": "ctxmenu", "action": "close"})
    except RuntimeError:
        pass


def native(pid, number, name, box, **ask):
    whole = OUT / f"{name}-window.png"
    took = False
    for _ in range(6):
        try:
            sv.cmd({"do": "ctxmenu", "hold": 4, **ask})
        except RuntimeError as error:
            print(f"  {name}: {error}")
            time.sleep(0.5)
            continue
        time.sleep(0.6)
        said = subprocess.run([str(MENU), str(pid), str(number), str(whole)], capture_output=True, text=True).stdout.strip()
        words = said.split()
        took = said.startswith("shot") and int(words[words.index("menus") + 1]) >= 1 and still_open()
        if took:
            break
        close_menu()
        time.sleep(0.8)
    close_menu()
    time.sleep(0.5)
    t.ok(f"{name}: pictured", took)
    if took:
        x, y, width, height = (v * 2 for v in box)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(whole), "-vf", f"crop={width}:{height}:{x}:{y}",
                        str(OUT / f"{name}.png")], check=True)
        whole.unlink()


def round_of(theme):
    pid, number = start(theme)
    try:
        for stage in STAGES:
            downloads(pid, number, f"{stage}-{theme}", stage)
        for place in PLACES:
            sv.cmd({"do": "ui", "windowAt": place})
            time.sleep(0.6)
            downloads(pid, number, f"many-{theme}-window-{place}", "many")
        sv.cmd({"do": "ui", "windowAt": "bottom"})
        time.sleep(0.6)
        if NATIVE:
            native(pid, number, f"native-plus-{theme}", (0, SIZE[1] - 330, 520, 330), kind="pluslist")
            native(pid, number, f"native-site-{theme}", (0, 0, 520, 420), kind="site")
            native(pid, number, f"native-space-{theme}", (100, 100, 520, 420), kind="space", at=[140, 140])
        if os.environ.get("ONLY"):
            return
        sv.cmd({"do": "space", "action": "go", "index": 2})
        time.sleep(1)
        sv.cmd({"do": "space", "action": "look", "colour": "coral"})
        sv.sp("open", url=f"{sv.BASE}/page")
        time.sleep(1.2)
        for stage in ("kept", "many"):
            downloads(pid, number, f"{stage}-{theme}-colour", stage)
        if NATIVE:
            native(pid, number, f"native-plus-{theme}-colour", (0, SIZE[1] - 330, 520, 330), kind="pluslist")
            native(pid, number, f"native-site-{theme}-colour", (0, 0, 520, 420), kind="site")
    finally:
        sv.finish()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tools()
    for theme in themes:
        round_of(theme)
    t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

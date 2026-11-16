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

sv.use("split-chrome-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "split-chrome" / label
TMP = OUT / "work"
rl.SHOT = TMP / "shot"
WIDTH = 258


def still(name):
    raw = TMP / f"{name}-raw.png"
    out = OUT / f"{name}.png"
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
                    f"crop={int(w * k)}:{int(h * k)}:{int(max(0, x) * k)}:{int(max(0, y) * k)}", str(path)], check=True)


def click(x, y):
    return sv.cmd({"do": "hit", "x": x, "y": y, "click": True}).get("view", "")


def url(id):
    return next(x["url"] for x in sv.sp("state")["tabs"] if x["id"] == id)


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
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
        rows = [rl.opened(icon, title) for icon, title in [("blue", "Reading list"), ("black", "Kit Moreau on X")]]
        rows.append(sv.sp("open", url=rl.BASE.replace("127.0.0.1", "localhost") + "/p9/black/" + "Hana on X".encode().hex())["resultID"])
        time.sleep(0.3)
        rows.append(rl.opened("green", "Pricing"))
        time.sleep(2)
        made = {i[:8].lower() for i in rows}
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        left, right = rows[1], rows[2]
        sv.sp("pair", id=right, **{"with": left}, side="right")
        time.sleep(1.0)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "ui", "look": "dark"})
        sv.cmd({"do": "ui", "windowPointer": [990, 690], "pointerPhase": "move"})

        def focus(id):
            sv.sp("select", id=id)
            time.sleep(0.3)
            sv.sp("focus", id=id)
            time.sleep(0.8)

        def says(id):
            return url(id).split("://", 1)[-1]

        side = [0, 0, WIDTH + 12, 260]
        for name, front, other in (("left", left, right), ("right", right, left)):
            focus(front)
            st = sv.sp("state")
            t.ok(f"{name} focused: the keys are there", st["activeID"] == front, st["activeID"])
            t.ok(f"{name} focused: a pair is in front", any(front in p["tabs"] for p in st["splits"]), st["splits"])
            pill = sv.sp("pill")
            t.ok(f"{name} focused: the pill is shown", pill["shown"], pill)
            t.ok(f"{name} focused: the pill says the focused page", pill["says"] and says(front).startswith(pill["says"]),
                 (pill["says"], says(front)))
            t.ok(f"{name} focused: not the other page", not says(other).startswith(pill["says"]), (pill["says"], says(other)))
            shot = still(f"window-{name}-focused")
            crop(shot, side, OUT / f"pill-{name}-focused.png")

        focus(right)
        pill = sv.sp("pill")
        x, y, w, h = pill["frame"]
        sv.cmd({"do": "ui", "tabKeys": {"clearBoard": True}})
        hit = click(x + w - 45, y + h / 2)
        t.ok("copy button: the press lands on it", hit in ("DoorView", "KitSymbol"), hit)
        time.sleep(0.4)
        board = sv.cmd({"do": "ui", "tabKeys": {}})["board"]["string"]
        t.ok("copy button: the focused page's address only", board == url(right), (board, url(right), url(left)))
        sv.cmd({"do": "ui", "windowPointer": [990, 690], "pointerPhase": "move"})

        for name, front, other in (("right", right, left), ("left", left, right)):
            focus(front)
            before = url(other)
            pill = sv.sp("pill")
            x, y, w, h = pill["frame"]
            hit = click(x + 40, y + h / 2)
            t.ok(f"{name}: the press lands on the pill", hit == "SideAddressView", hit)
            time.sleep(0.6)
            st = sv.cmd({"do": "suggest"})
            t.ok(f"{name}: a click on the pill opens the field", st["editing"], st)
            if name == "right":
                still("window-editing-right")
            target = f"{rl.BASE}/typed-{name}"
            sv.cmd({"do": "field", "text": target, "go": True})
            time.sleep(1.0)
            t.ok(f"{name}: typing goes to the focused page", url(front).rstrip("/") == target, (url(front), target))
            t.ok(f"{name}: the other page stays", url(other) == before, (url(other), before))
            pill = sv.sp("pill")
            t.ok(f"{name}: the pill says where it went", pill["says"] and says(front).startswith(pill["says"]), (pill["says"], says(front)))
        focus(right)
        still("window-after-typing")

        sv.cmd({"do": "ui", "windowPointer": [990, 690], "pointerPhase": "move"})
        d = sv.sp("divider")
        dx, dy, dw, dh = d["frame"]
        area = [dx + dw / 2 - 60, dy + dh / 2 - 70, 120, 140]
        t.ok("divider at rest: the grip is hidden", d["pill"]["opacity"] == 0 and d["pill"]["model"] == 0, d["pill"])
        crop(still("divider-rest-window"), area, OUT / "divider-rest.png")
        mid = sv.sp("divider", hover=True, wait=0.06)
        t.ok("divider hovered: the grip fades in, not at once", 0 < mid["pill"]["opacity"] < 1, mid["pill"])
        lit = sv.sp("divider", wait=0.4)
        t.ok("divider hovered: the grip is shown", lit["pill"]["opacity"] == 1 and lit["pill"]["height"] == 40, lit["pill"])
        crop(still("divider-hover-window"), area, OUT / "divider-hover.png")
        gone = sv.sp("divider", hover=False, wait=0.4)
        t.ok("divider left: the grip is hidden again", gone["pill"]["opacity"] == 0, gone["pill"])
        held = sv.sp("divider", hold=True, wait=0.4)
        t.ok("divider held: the grip is shown", held["pill"]["opacity"] == 1, held["pill"])
        crop(still("divider-held-window"), area, OUT / "divider-held.png")
        free = sv.sp("divider", hold=False, wait=0.4)
        t.ok("divider let go: the grip is hidden", free["pill"]["opacity"] == 0, free["pill"])

        sv.cmd({"do": "ui", "look": "light"})
        time.sleep(0.6)
        focus(left)
        crop(still("window-light-left-focused"), side, OUT / "pill-light-left-focused.png")
        sv.sp("divider", hover=True, wait=0.4)
        crop(still("divider-light-hover-window"), area, OUT / "divider-light-hover.png")
        sv.sp("divider", hover=False, wait=0.4)
        crop(still("divider-light-rest-window"), area, OUT / "divider-light-rest.png")
        print(OUT)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

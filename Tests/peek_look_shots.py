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
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("peek-look-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_PROBE_APP"):
    sv.APP = os.environ["BROADWAY_PROBE_APP"]
WORK = ROOT / ".context" / "peek-look"
OUT = WORK / label
rl.SHOT = WORK / "shot"
WIDTH = 260
LOOKS = {
    "plain": {"colour": "gray", "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0},
    "tinted": {"colours": ["FF8A1F", "3139FB"], "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0.6},
    "glass": {"colours": ["FF8A1F", "3139FB"], "intensity": 0.8, "glass": True, "transparency": 0, "grain": 0},
    "seethrough": {"colour": "gray", "intensity": 0.8, "glass": False, "transparency": 0.6, "grain": 0},
}
CASES = [(theme, look, "left", True) for theme in ["light", "dark"] for look in LOOKS]
CASES += [("dark", "tinted", "right", True), ("light", "plain", "left", False), ("dark", "plain", "left", False)]
if os.environ.get("PEEK_CASES"):
    CASES = [c for c in CASES if f"{c[0]}-{c[1]}" in os.environ["PEEK_CASES"].split(",")]


def ui(**r):
    return sv.cmd({"do": "ui", **r})


def main():
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(rl.SHOT)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False})
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
    frames = {}
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        ui(groups=True, cards=True)
        pins = [rl.opened(icon, f"Pin {n}") for n, icon in enumerate(rl.PINS[:6])]
        loose = [rl.opened(icon, title) for icon, title in rl.LOOSE]
        kept = [rl.opened(icon, title) for icon, title in rl.FOLDER[1]]
        time.sleep(2)
        for id in pins:
            sv.cmd({"do": "pin", "id": id})
        sv.cmd({"do": "group", "id": kept[0], "new": True, "name": rl.FOLDER[0]})
        for id in kept[1:]:
            sv.cmd({"do": "group", "id": id, "name": rl.FOLDER[0]})
        sv.sp("select", id=loose[0])
        made = [i[:8].lower() for i in pins + loose + kept]
        for blank in [k for k in sv.cmd({"do": "rowframes"})["rows"] if k not in made]:
            try:
                sv.sp("close", id=blank)
            except RuntimeError:
                pass
        busy = ("document.body.style.margin='0';document.body.innerHTML="
                "'<div style=\"font:700 64px -apple-system;line-height:1.1;padding:20px\">'"
                "+['Busy page under the peek','#e33 #fb0 #2a5 #36f #111'].join('<br>')"
                "+'</div>'+['#e33','#fb0','#2a5','#36f','#111'].map(c=>'<div style=\"height:90px;background:'+c+'\"></div>').join('');'1'")
        sv.ev(loose[0], busy)
        ui(pointerless=True)
        time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        crop = WIDTH + 40

        def shot(name, side="left"):
            still = WORK / f"{label}-{name}-full.png"
            k = 0
            for _ in range(5):
                try:
                    rl.shoot(pid, number, still)
                    k = rl.scale_of(still)
                except RuntimeError:
                    k = 0
                if k >= 2:
                    break
                time.sleep(0.5)
            path = OUT / f"{name}.png"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf",
                            f"crop={crop * k}:ih:{0 if side == 'left' else 'iw-ow'}:0", str(path)], check=True)
            still.unlink()
            return path

        for theme, look, side, cards in CASES:
            ui(look=theme, side=side, cards=cards)
            sv.cmd({"do": "space", "action": "look", "custom": "808080"})
            sv.cmd({"do": "space", "action": "look", **LOOKS[look]})
            ui(windowPointer=[500, 600], pointerPhase="move")
            ui(folded=False)
            time.sleep(1.4)
            case = f"{theme}-{look}" + ("" if side == "left" else f"-{side}") + ("" if cards else "-nocards")
            docked = shot(f"{case}-docked", side)
            frames[f"{case}-docked"] = sv.cmd({"do": "rowframes"})
            ui(folded=True)
            time.sleep(0.8)
            ui(peek=True)
            time.sleep(1.2)
            peeking = sv.cmd({"do": "probe"}).get("peeking")
            t.ok(f"{case}: the column peeks", peeking is True, peeking)
            peek = shot(f"{case}-peek", side)
            frames[f"{case}-peek"] = sv.cmd({"do": "rowframes"})
            ui(peek=False)
            time.sleep(0.6)
            ui(folded=False)
            time.sleep(0.6)
            pair = OUT / f"{case}-pair.png"
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(docked), "-i", str(peek),
                            "-filter_complex", "[0][1]hstack=inputs=2", str(pair)], check=True)
            print(pair, flush=True)
        ui(side="left", cards=True)
        (OUT / "frames.json").write_text(json.dumps(frames, indent=1))
    finally:
        sv.finish()
    t.done()


if __name__ == "__main__":
    main()

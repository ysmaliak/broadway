#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv
import visual_diff as vd

sv.use("float-review-shots")
t = sv.T()

LONG = "https://files.example.test/a/very/long/path/that/keeps/going/and/going/past/the/edge/of/any/bubble/there/is/quarterly-report-final-v7.pdf?download=1&token=abcdefghijklmnopqrstuvwxyz"
GROUNDS = {"light": "#ffffff", "dark": "#161618"}

SURFACES = [
    ("float-feedback", "speed", {"text": "1.5×"}),
    ("float-feedback", "long", {"text": "Skipped 10 seconds back"}),
    ("float-controls", "wide", {}),
    ("float-controls", "small", {"width": 240, "height": 135}),
    ("float-controls", "large", {"width": 720, "height": 405}),
    ("float-controls", "paused", {"playing": False}),
    ("float-controls", "live", {"live": True}),
    ("float-controls", "waiting", {"waiting": True}),
    ("float-controls", "bare", {"captions": False, "chapters": False, "rate": 1}),
    ("float-controls", "feedback", {"feedback": "Skipped 10 seconds back"}),
    ("mini-player", "paused", {"playing": False}),
    ("mini-player", "playing", {"playing": True}),
    ("mini-player", "skips", {"playing": True, "pair": "skips"}),
    ("call-bar", "all", {"mic": True, "camera": True, "leaves": True}),
    ("call-bar", "muted", {"mic": False, "camera": False, "leaves": True}),
    ("call-bar", "mic-only", {"mic": True, "camera": None, "leaves": False}),
    ("escape-reminder", "shown", {}),
    ("recording-pill", "one", {"lines": [["reel", "Reel", "is recording your screen"]]}),
    ("recording-pill", "three", {"lines": [["reel", "Reel", "is recording your screen"], ["huddle", "Huddle", "is using your camera"],
                                           ["notes", "Notes", "is using your microphone"]]}),
    ("recording-pill", "long", {"lines": [["long", "An Extension With A Very Long Name Indeed", "is recording your screen and your microphone"]]}),
    ("recording-pill", "longest", {"lines": [["longest", "Screen And Camera Recorder For Classrooms, Studios And Everyone Else Who Shares", "is using your camera and microphone"],
                                             ["reel", "Reel", "is recording your screen"]]}),
    ("link-bubble", "short", {"address": "https://example.test/"}),
    ("link-bubble", "long", {"address": LONG}),
    ("agent-pointer", "type", {"kind": "type"}),
    ("agent-pointer", "click", {"kind": "click"}),
    ("agent-character", "shown", {}),
    ("driving-bar", "shown", {}),
    ("at-rest", "shown", {}),
    ("passkey-switch", "broadway", {"broadway": True}),
    ("passkey-switch", "system", {"broadway": False}),
    ("hover-tab-card", "preview", {}),
    ("hover-tab-card", "plain", {"plain": True}),
    ("hover-folder-list", "preview", {}),
    ("account-list", "logins", {"kind": "logins"}),
    ("tab-offers", "none-picked", {}),
    ("tab-offers", "picked", {"picked": 1}),
    ("popup-sign", "rest", {}),
    ("popup-sign", "shown", {"shown": True}),
    ("translate-sign", "done", {"shown": True}),
    ("translate-sign", "working", {"shown": True, "working": True}),
    ("capture-question", "shown", {}),
    ("screen-question", "shown", {}),
    ("password-offer", "shown", {}),
    ("password-offer", "long", {"user": "a.very.long.address.for.a.shared.mailbox@mail.example.test"}),
    ("password-offer", "changed", {"changed": True}),
    ("capture-question", "microphone", {"wants": "microphone"}),
    ("capture-question", "location", {"wants": "location"}),
    ("screen-question", "sound", {"sound": True}),
    ("shield-offer", "shown", {}),
    ("find-bar", "found", {}),
    ("find-bar-empty", "empty", {}),
    ("find-bar-narrow", "narrow", {}),
    ("find-count", "shown", {}),
    ("form-fill-card", "card", {}),
    ("form-fill-done", "done", {}),
    ("form-fill-offer", "offer", {}),
    ("form-drafts-working", "working", {}),
    ("form-drafts-card", "card", {}),
    ("form-drafts-warned", "warned", {}),
    ("meeting-alert", "one", {}),
    ("meeting-alert-two", "two", {}),
    ("meeting-alert-faces", "faces", {}),
    ("meeting-alert-long", "long", {}),
    ("integration-hover", "shown", {}),
    ("integration-preview", "shown", {}),
    ("agent-card", "shown", {}),
    ("agent-badge", "shown", {}),
    ("recent-downloads", "shown", {}),
    ("selection-result", "shown", {}),
    ("field-bar", "shown", {}),
    ("field-slab", "shown", {}),
    ("field-rows", "shown", {}),
    ("now-rows", "shown", {}),
    ("field-chips", "shown", {}),
    ("field-menu", "shown", {}),
    ("command-list", "shown", {}),
    ("account-list", "offer", {"kind": "offer"}),
    ("space-look-chooser", "shown", {}),
    ("space-look-editor", "shown", {}),
]


DRAWN = "--drawn" in sys.argv
STILL = "--still" in sys.argv
FAMILY = {
    "float-feedback", "call-bar", "link-bubble", "driving-bar", "agent-card", "capture-question", "screen-question", "password-offer",
    "shield-offer", "find-bar", "find-bar-empty", "find-bar-narrow", "find-count", "form-fill-card", "form-fill-done", "form-fill-offer",
    "form-drafts-working", "form-drafts-card", "form-drafts-warned", "meeting-alert", "meeting-alert-two", "meeting-alert-faces",
    "meeting-alert-long", "selection-result",
}


def judge(where, control, short):
    named = control["label"] or control["title"] or control["kind"]
    wide, tall = control["hit"]
    field = "Field" in control["kind"]
    row = control["kind"].endswith("Cell")
    surface = where.split(" ")[0]
    least = min(wide, tall)
    if control["enabled"] and wide and tall:
        if least < 24:
            short.append(f"{where}: {named} reach {wide:g} by {tall:g}")
        t.ok(f"{where}: {named} can be hit over at least 24 points", least >= 24, f"reach {wide:g} by {tall:g}, drawn {control['size']}")
    t.ok(f"{where}: {named} has a name for VoiceOver", bool(control["label"] or control["title"]), str(control))
    if not control["title"] and not field and not row and "Slider" not in control["kind"] and max(control["size"]) < 60:
        t.ok(f"{where}: {named} is only a symbol and has a tooltip", bool(control["help"]), str(control))


def picture(shot, pid, number, path):
    path.unlink(missing_ok=True)
    said = ""
    for _ in range(3):
        if DRAWN:
            try:
                said = str(sv.cmd({"do": "surface", "action": "draw", "path": str(path.resolve())}))
            except RuntimeError as error:
                said = str(error)
        else:
            ran = subprocess.run([str(shot), str(pid), str(number), str(path)], capture_output=True, text=True)
            said = ran.stdout.strip() + ran.stderr.strip()
        if path.exists() or "screen recording permission unavailable" in said or "capture failure" in said:
            break
        time.sleep(0.5)
    return said[-200:]


LONG_TITLE = "a-page-whose-title-goes-on-and-on-well-past-the-width-of-any-card-the-switcher-could-ever-draw"


def shown():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def window(out, tag, shot):
    folder = out / "tab-switcher"
    folder.mkdir(parents=True, exist_ok=True)
    sv.setup()
    shown()
    try:
        pid = next(iter(sv.holding() & sv.running()))
        opened = [sv.page(name) for name in ("first", "second", "third")]
        states = [("three", []), ("long", [LONG_TITLE, LONG_TITLE + "-again"]), ("many", [f"tab-{n}" for n in range(9)])]
        for state, more in states:
            opened += [sv.page(name) for name in more]
            for look in ("light", "dark"):
                sv.cmd({"do": "ui", "look": look})
                time.sleep(0.6)
                sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]})
                time.sleep(1.0)
                up = sv.cmd({"do": "switcher"})
                t.ok(f"tab switcher {state}, {look}: up with its ten latest tabs at most",
                     up["visible"] and len(up["candidates"]) == min(len(opened), 10), str(up)[:200])
                x, y, wide, tall = up["panel"]
                frame = max(sv.cmd({"do": "probe"})["windows"], key=lambda w: w["frame"][2] * w["frame"][3])
                t.ok(f"tab switcher {state}, {look}: the panel is inside the window",
                     x >= 0 and y >= 0 and x + wide <= frame["frame"][2] + 0.5 and y + tall <= frame["frame"][3] + 0.5, f"{up['panel']} in {frame['frame']}")
                inside = all(cx >= x - 0.5 and cy >= y - 0.5 and cx + cw <= x + wide + 0.5 and cy + ch <= y + tall + 0.5
                             for cx, cy, cw, ch in up["cards"].values())
                t.ok(f"tab switcher {state}, {look}: every card is inside the panel", inside, str(up["cards"])[:300])
                path = folder / f"{state}-{look}-{tag}.png"
                path.unlink(missing_ok=True)
                ran = subprocess.run([str(shot), str(pid), str(frame["number"]), str(path)], capture_output=True, text=True)
                t.ok(f"tab switcher {state}, {look}: pictured", path.exists(), (ran.stdout.strip() + ran.stderr.strip())[-200:])
                sv.sp("mouse", points=[[5, 5], [5, 5]])
                time.sleep(0.6)
                t.ok(f"tab switcher {state}, {look}: put away", not sv.cmd({"do": "switcher"})["visible"])
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


def still(only):
    sv.setup(**{"motion.testReduced": "--with-motion" not in sys.argv})
    sv.launch()
    try:
        seen = 0
        for name, state, request in SURFACES:
            if name not in FAMILY or (only and name not in only):
                continue
            for look in ("light", "dark"):
                label = f"{name} {state}, {look}, with Reduce Motion"
                try:
                    made = sv.cmd({"do": "surface", "name": name, "look": look, "ground": GROUNDS[look], "pad": 24, "moving": True,
                                   **{k: v for k, v in request.items() if v is not None}})
                except RuntimeError as error:
                    t.ok(f"{label}: drawn", False, str(error)[:200])
                    continue
                seen += 1
                t.ok(f"{label}: nothing moves, and no fade is longer than 0.2 seconds", made.get("moving") == [], made.get("moving"))
                sv.cmd({"do": "surface", "action": "close"})
        t.ok("the family was drawn", seen > 0, seen)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    only = next((a.split("=", 1)[1].split(",") for a in sys.argv if a.startswith("--only=")), None)
    tag = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--tag=")), "after")
    out = Path(args[0] if args else ".context/float-fixes")
    shot = None if STILL or (DRAWN and "--window" not in sys.argv) else vd.tool("shot", "WindowShot.swift")
    if DRAWN:
        print("  note  each surface is drawn by the bench off the screen, so glass shows without what is behind it")
    if "--window" in sys.argv:
        return window(out, tag, shot)
    if STILL:
        return still(only)
    sv.setup()
    sv.launch()
    try:
        pid = next(iter(sv.holding() & sv.running()))
        audit = {}
        short = []
        bare = "--no-shots" in sys.argv
        for name, state, request in SURFACES:
            if only and name not in only:
                continue
            folder = out / name
            folder.mkdir(parents=True, exist_ok=True)
            for look in ("light", "dark"):
                for ground, colour in GROUNDS.items():
                    label = f"{name} {state}, {look} on {ground}"
                    first = look == "light" and ground == "light"
                    if bare and not first:
                        continue
                    try:
                        made = sv.cmd({"do": "surface", "name": name, "look": look, "ground": colour, "pad": 24, "controls": first,
                                       **{k: v for k, v in request.items() if v is not None}})
                    except RuntimeError as error:
                        t.ok(f"{label}: drawn", False, str(error)[:200])
                        continue
                    if not bare:
                        time.sleep(0.6)
                        path = folder / f"{state}-{look}-{ground}-{tag}{'-drawn' if DRAWN else ''}.png"
                        said = picture(shot, pid, made["number"], path)
                        t.ok(f"{label}: pictured", path.exists(), said)
                    if first:
                        audit[f"{name} {state}"] = made.get("controls", [])
                        for control in made.get("controls", []):
                            judge(f"{name} {state}", control, short)
                    sv.cmd({"do": "surface", "action": "close"})
        kept = out / f"controls-{tag}.json"
        if only and kept.exists():
            audit = {**json.loads(kept.read_text()), **audit}
        kept.write_text(json.dumps(audit, indent=1, sort_keys=True))
        print(f"{len(short)} controls have a reach under 24 points")
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

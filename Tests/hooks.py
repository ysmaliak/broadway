#!/usr/bin/env python3
"""Hooks, end to end, in a hidden probe world of their own.

Build first (`./build.sh`), then `python3 Tests/hooks.py [OUT]`. The world's
own hooks.json and the programs it names are written into the world's folder
before the app starts, so nothing reads the person's file and nothing runs
from outside the world. The app starts hidden. A link arrives from outside and
a hook sends it to a space, a timer hook runs, a changed program is refused,
a hook the build doesn't know is kept, and the person's link rule wins.

With OUT, pictures of Settings › Agents › Hooks with four hooks in different
states, and of the Add Hook sheet, in light and dark. The probe's own window is
kept behind every other window (windowbehind), never active and never key, and
each still is a real picture by window id. The Links sheet is taken by its own
window. The Site requests sheet, which grows its warning after it is shown,
comes out drawn into its parent's picture, so it is taken in place there. If a
capture fails, the bench draws the window offscreen instead and the probe says
which. The unfolded section also gets an access audit, written to
OUT/access.json. The world is removed afterwards.
"""
import hashlib
import os
import shutil
import subprocess
import json
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("hooks-probe")
PROGRAMS = Path(sv.SUPPORT) / "programs"
ROOT = Path(__file__).resolve().parents[1]
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"hooks-probe-{os.getpid()}"
SHOT = TMP / "shot"


def tool():
    TMP.mkdir(parents=True, exist_ok=True)
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", TMP / "WindowShot.swift")
    subprocess.run(["swiftc", "-parse-as-library", str(TMP / "WindowShot.swift"), "-o", str(SHOT)], cwd=str(TMP), check=True)
IDS = {name: str(uuid.uuid4()).upper() for name in ["link", "permission", "timer", "download", "unknown"]}


def program(name, body):
    path = PROGRAMS / name
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)
    return path


def plant():
    PROGRAMS.mkdir(parents=True, exist_ok=True)
    links = program("send-to-reading", f"cat > '{PROGRAMS}/link.in'\necho '{{\"space\": \"Reading\"}}'")
    meet = program("meeting-sites", "echo '{\"answer\": \"allow\"}'")
    approved = hashlib.sha256(meet.read_bytes()).hexdigest()
    program("meeting-sites", "echo '{\"answer\": \"allow\"}'\necho 'changed later' >&2")
    tidy = program("tidy-downloads", f"cat > '{PROGRAMS}/timer.in'")
    sort = program("sort-downloads", "sleep 60")
    hooks = [
        {"id": IDS["link"], "event": "link", "program": str(links), "on": True},
        {"id": IDS["permission"], "event": "permission", "program": str(meet), "on": True, "hash": approved},
        {"id": IDS["timer"], "event": "timer", "program": str(tidy), "on": True, "minutes": 15},
        {"id": IDS["download"], "event": "download", "program": str(sort), "on": False,
         "off": "Switched off after three time-outs or crashes in a row"},
        {"id": IDS["unknown"], "event": "clipboard", "program": str(tidy), "on": True, "colour": "teal"},
    ]
    (Path(sv.SUPPORT) / "hooks.json").write_text(json.dumps({"version": 1, "hooks": hooks}, indent=2))


def hooks(**f): return sv.cmd({"do": "hooks", **f})
def ui(**f): return sv.cmd({"do": "ui", **f})
def row(listed, name): return next(h for h in listed["hooks"] if h["id"] == IDS[name])


def front_space():
    return sv.cmd({"do": "windows"})["windows"][0]["space"]


def wait(check, seconds=8):
    until = time.time() + seconds
    while time.time() < until:
        if check():
            return True
        time.sleep(0.2)
    return False


def checks(t):
    listed = hooks(action="look")
    time.sleep(0.6)
    listed = hooks()
    t.ok("the world's own file is read, four hooks and one it doesn't know", len(listed["hooks"]) == 4 and listed["unknown"] == 1,
         listed)
    t.ok("limit 7: a changed program is not run and its row says so",
         wait(lambda: row(hooks(), "permission")["line"] == "Changed since you approved it"), row(hooks(), "permission"))
    t.ok("a hook Broadway switched off says why", row(listed, "download")["line"] == "Switched off after three time-outs or crashes in a row")

    home = front_space()
    sv.cmd({"do": "windows", "action": "link", "url": "https://docs.example.com/guide?id=7&q=\"a b\";$(x)"})
    t.ok("a link from outside goes to the space its hook named", wait(lambda: front_space() == "Reading"), front_space())
    given = json.loads((PROGRAMS / "link.in").read_text()) if (PROGRAMS / "link.in").exists() else {}
    t.ok("limit 5: the address arrives whole, as data", given.get("url") == "https://docs.example.com/guide?id=7&q=%22a%20b%22;$(x)", given)
    t.ok("the link hook's row says it ran", row(hooks(), "link")["line"].startswith("Ran "), row(hooks(), "link"))

    sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.6)
    sv.cmd({"do": "route", "args": ["add", "docs.example.com", "space", home]})
    (PROGRAMS / "link.in").unlink(missing_ok=True)
    sv.cmd({"do": "windows", "action": "link", "url": "https://docs.example.com/other"})
    time.sleep(2)
    t.ok("the person's link rule wins over a hook", front_space() == home and not (PROGRAMS / "link.in").exists(), front_space())
    sv.cmd({"do": "route", "args": ["clear"]})

    t.ok("the timer has not run before its minutes", not (PROGRAMS / "timer.in").exists())
    hooks(action="tick", minutes=16)
    t.ok("a timer hook runs when its minutes have passed", wait(lambda: (PROGRAMS / "timer.in").exists()))
    timer = json.loads((PROGRAMS / "timer.in").read_text()) if (PROGRAMS / "timer.in").exists() else {}
    t.ok("the timer is given the time and its minutes", timer.get("event") == "timer" and timer.get("minutes") == 15, timer)
    t.ok("the file still holds the hook it doesn't know",
         any(h.get("event") == "clipboard" for h in json.loads((Path(sv.SUPPORT) / "hooks.json").read_text())["hooks"]))


def pictures(out, t):
    out.mkdir(parents=True, exist_ok=True)
    shots = []
    gaps = {}
    drawn = []
    tool()
    pid = next(iter(sv.holding() & sv.running()))

    def shoot(name, number):
        path = out / f"{name}.png"
        path.unlink(missing_ok=True)
        said = ""
        for _ in range(4):
            got = subprocess.run([str(SHOT), pid, str(number), str(path)], cwd=str(TMP), capture_output=True, text=True)
            said = (got.stdout + got.stderr).strip()[-300:]
            if path.exists():
                shots.append(path.name)
                return
            time.sleep(0.8)
        print(f"  capture of {name} failed ({said}), drawn offscreen instead")
        hooks(action="picture", path=str(path), window=number)
        if path.exists():
            shots.append(path.name)
            drawn.append(path.name)
        else:
            t.ok(f"picture {name}", False)

    sv.cmd({"do": "resize", "width": 1040, "height": 1400, "steps": 1})
    ui(settings=True); time.sleep(1.5)
    placed = sv.cmd({"do": "windowbehind"})
    number = placed["number"]
    t.ok("the probe's window stays behind and takes no keys", not placed["key"] and not placed["active"], placed)
    time.sleep(0.8)
    for theme in ["dark", "light"]:
        ui(look=theme); time.sleep(0.8)
        ui(settingsPage="agents"); time.sleep(1.2)
        if theme == "dark":
            try:
                ui(settingsPress="settings.row.agents.hooks"); time.sleep(1.2)
            except RuntimeError as error:
                t.ok("the Hooks section unfolds", False, error)
        try:
            ui(settingsPoint="agents.hooks"); time.sleep(0.8)
            ui(settingsPoint=""); time.sleep(0.4)
        except RuntimeError as error:
            t.ok("the Hooks section scrolls into view", False, error)
        gaps[theme] = [gap for w in sv.cmd({"do": "axaudit"})["windows"] for gap in w["gaps"]]
        t.ok(f"the unfolded Hooks section has nothing VoiceOver would miss, {theme}",
             not [gap for gap in gaps[theme] if "hook" in json.dumps(gap).lower()], gaps[theme])
        shoot(f"hooks-section-{theme}", number)
        for event in ["permission", "link"]:
            sheet = hooks(action="sheet", event=event)["sheet"]
            time.sleep(2.5)
            if sheet:
                shoot(f"hooks-sheet-{event}-{theme}", number if event == "permission" else sheet)
            else:
                t.ok(f"the {event} sheet opens", False)
            hooks(action="closesheet")
            time.sleep(0.6)
    (out / "access.json").write_text(json.dumps(gaps, indent=1))
    (out / "drawn.json").write_text(json.dumps(drawn))
    print(f"{len(shots)} pictures in {out}, {len(drawn)} of them drawn offscreen: {drawn}")


def main():
    out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else None
    t = sv.T()
    sv.setup(spaces=True, **{"start.fresh": True})
    plant()
    sv.launch()
    try:
        sv.cmd({"do": "space", "action": "new", "name": "Reading"}); time.sleep(0.8)
        sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.8)
        checks(t)
        if out:
            pictures(out, t)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

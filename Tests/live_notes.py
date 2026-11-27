#!/usr/bin/env python3
"""Every live folder note, at the narrowest sidebar and the default one, and the limited note pictured.

Build first (`./build.sh`), then `python3 Tests/live_notes.py`. A world of its
own opens in the background, kept below every ordinary window and never key.
Five folders that are never read (GitHub, Linear, a Linear cycle, YouTube and
a feed on an invented host) are given each state in turn, and the bench
says, for every note on screen, its words and whether any line is cut. A
folder that has gone three hours without a good read and is limited by its
site must say `Couldn't read <site>` in one line with no Try Again, keep the
limit and the wait in its help tag, and no note may be cut at either width.
That note is pictured by the window's own id at both widths, light and dark,
into .context/live-limited/.
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

sv.use("live-notes-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "live-limited"
TMP = OUT / "work"
rl.SHOT = TMP / "shot"
NARROW = 200
DEFAULT = 245
SHOTS = "--no-shots" not in sys.argv
FOLDERS = [
    ("PRs", "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me+archived%3Afalse"),
    ("Issues", "linear:assigned"),
    ("Cycle", "linear:cycle/eng"),
    ("Videos", "https://www.youtube.com/feed/subscriptions"),
    ("News", "https://dispatch-times.example/feed.xml"),
]
STATES = ["waiting", "fine", "paused", "running", "signIn", "sso", "unread", "offline", "limited"]
drawn = []
t = sv.T()


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def notes():
    return sv.cmd({"do": "live", "args": ["notes"]})["notes"]


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


def crop(src, width, path):
    k = max(1, round(rl.scale_of(src)))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int((width + 14) * k)}:{int(300 * k)}:0:0", str(path)], check=True)


def survey(width):
    sv.cmd({"do": "ui", "sideWidth": width})
    time.sleep(0.8)
    cut = []
    for state in STATES:
        for name, _ in FOLDERS:
            if state == "sso":
                live("force", name, "sso", "Octo Corporation Spain")
            else:
                live("force", name, state)
        time.sleep(0.6)
        for note in notes():
            if note["cut"]:
                cut.append((state, note["folder"], note["text"], note["detail"], round(note["width"])))
    live("statuses", "Issues", "started")
    live("force", "Issues", "fine")
    time.sleep(0.6)
    for note in notes():
        if note["cut"]:
            cut.append(("fine, statuses left out", note["folder"], note["text"], note["detail"], round(note["width"])))
    live("statuses", "Issues", "triage,unstarted,started")
    t.ok(f"{width} pt: no note is cut", not cut, cut)
    return cut


def limited(width):
    sv.cmd({"do": "ui", "sideWidth": width})
    for name, _ in FOLDERS:
        live("aged", name, "180")
        live("force", name, "limited")
    time.sleep(0.8)
    shown = {n["folder"]: n for n in notes()}
    pr = shown.get("PRs", {})
    t.ok(f"{width} pt: a folder long out of date and limited says Couldn't read GitHub in one line", pr.get("text") == "Couldn't read GitHub" and pr.get("detail") == "", pr)
    t.ok(f"{width} pt: with no Try Again while the limit holds", pr.get("retry") is False and pr.get("button") is False, pr)
    t.ok(f"{width} pt: and the limit and the wait in its help tag", pr.get("tip", "").startswith("Updated ")
         and pr.get("tip", "").endswith(". Limited by GitHub, trying again in 10 minutes."), pr)
    issues = shown.get("Issues", {})
    t.ok(f"{width} pt: Linear says the same of itself", issues.get("text") == "Couldn't read Linear" and issues.get("detail") == ""
         and issues.get("tip", "").endswith(". Limited by Linear, trying again in 10 minutes."), issues)
    t.ok(f"{width} pt: nothing limited is cut", not any(n["cut"] for n in shown.values()), list(shown.values()))
    folder = next(f for f in live("force", "PRs", "limited")["folders"] if f["name"] == "PRs")
    t.ok(f"{width} pt: the whole sentence stays the folder's failure words", folder["failure"] == "GitHub is limiting requests. Trying again in 10 minutes.", folder["failure"])
    for name, _ in FOLDERS:
        live("force", name, "unread")
    time.sleep(0.6)
    pr = {n["folder"]: n for n in notes()}.get("PRs", {})
    t.ok(f"{width} pt: Couldn't read is the button, with Try again under it", pr.get("text") == "Couldn't read GitHub" and pr.get("detail") == "Try again" and pr.get("button") is True, pr)
    for name, _ in FOLDERS:
        live("force", name, "limited")
    time.sleep(0.6)


def main():
    global pid, number
    if SHOTS:
        shutil.rmtree(OUT, ignore_errors=True)
        TMP.mkdir(parents=True, exist_ok=True)
        copy = TMP / "WindowShot.swift"
        shutil.copy(ROOT / "Tests/WindowShot.swift", copy)
        subprocess.run(["swiftc", "-parse-as-library", str(copy), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(DEFAULT)], check=True)
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
        placed = sv.cmd({"do": "windowbehind"})
        number = placed["number"]
        t.ok("the probe's window stays behind and takes no keys", not placed["key"] and not placed["active"], placed)
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        for name, source in FOLDERS:
            live("add", name, source)
            live("unfold", name)
        for width in (NARROW, DEFAULT):
            survey(width)
        for width in (DEFAULT, NARROW):
            limited(width)
            if SHOTS:
                for look in ("light", "dark"):
                    sv.cmd({"do": "ui", "look": look})
                    time.sleep(1.0)
                    crop(still(f"window-{width}-{look}"), width, OUT / f"limited-{width}-{look}.png")
        if SHOTS:
            print(OUT)
            print("real window pictures" if not drawn else f"drawn offscreen: {drawn}")
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

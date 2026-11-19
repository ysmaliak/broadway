#!/usr/bin/env python3
import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import visual_diff as vd  # noqa: E402

parser = argparse.ArgumentParser(description="Bottom notices on a stand-in window: an offer, a note with a button, a line with "
                                 "Undo and an agent's question, each pictured from the window's own number in the middle of "
                                 "coming, at rest and in the middle of going, in light and dark, into .context/notice-shots/LABEL/. "
                                 "Then the real motion runs and is read back, with and without Reduce Motion. Build first. Run it "
                                 "from a pane that may record the screen, since pictures of a window need that.")
parser.add_argument("label", nargs="?", default="after")
parser.add_argument("--no-shots", action="store_true", help="read the motion back without pictures")
options = parser.parse_args()
OUT = ROOT / ".context" / "notice-shots" / options.label
STATES = [("coming", 0.5, False), ("rest", 1.0, False), ("going", 0.5, True)]
t = sv.T()


def picture(shot, pid, number, path):
    path.unlink(missing_ok=True)
    said = ""
    for _ in range(3):
        ran = subprocess.run([str(shot), str(pid), str(number), str(path)], capture_output=True, text=True)
        said = (ran.stdout + ran.stderr).strip()
        if path.exists() or "permission" in said:
            break
        time.sleep(0.5)
    return said[-200:]


def motion(reduced):
    sv.setup(**{"motion.testReduced": reduced})
    sv.launch()
    try:
        made = sv.cmd({"do": "notices", "look": "light"})
        t.ok(f"{'reduced' if reduced else 'motion'}: four notices are up", made.get("count") == 4, made)
        for leaving in (False, True):
            ran = sv.cmd({"do": "notices", "action": "run", "leaving": leaving})
            word = "going" if leaving else "coming"
            moves = ran.get("animations", [])
            t.ok(f"{word}: every notice has a fade", all(any(a["key"] == "arrive.fade" for a in each) for each in moves), moves)
            if reduced:
                t.ok(f"{word} under Reduce Motion: a fade only, nothing moves", all(a["fadeOnly"] for each in moves for a in each), moves)
            elif not ran.get("calm"):
                t.ok(f"{word}: every notice also rises or falls with the shared spring",
                     all(any(a["key"] == "arrive" and a["path"] == "transform" for a in each) for each in moves), moves)
            time.sleep(0.5)
        sv.cmd({"do": "notices", "action": "close"})
    finally:
        sv.finish()


def shots():
    OUT.mkdir(parents=True, exist_ok=True)
    shot = vd.tool("shot", "WindowShot.swift")
    sv.setup()
    sv.launch()
    try:
        for look in ("light", "dark"):
            made = sv.cmd({"do": "notices", "look": look})
            pid, number = made["pid"], made["number"]
            for state, share, leaving in STATES:
                posed = sv.cmd({"do": "notices", "action": "pose", "share": share, "leaving": leaving})
                time.sleep(0.3)
                path = OUT / f"{state}-{look}.png"
                said = picture(shot, pid, number, path)
                t.ok(f"{state}, {look}: pictured from window {number}", path.exists() and posed.get("count") == 4, said or posed)
            sv.cmd({"do": "notices", "action": "close"})
    finally:
        sv.finish()


def main():
    sv.use("notice-shots")
    motion(False)
    motion(True)
    if not options.no_shots:
        shots()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

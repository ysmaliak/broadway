#!/usr/bin/env python3
"""Typing in the floating field: keystroke to suggestion paint.

Build first (`./build.sh`), then `python3 Tests/field_typing.py [OUT.json]`.
A test copy in a world of its own, started hidden, with forty visits in
history. Each round opens the ⌘T field and types a query a character at a
time; for every keystroke the bench gives the time to insert it and the time
until the run loop next rests, the list worked out and painted. Main-thread
busy time and the longest span come from the idle watch over the round.
BROADWAY_APP picks another build, for before and after.
"""
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-typing")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/field-typing.json")
ROUNDS = int(os.environ.get("ROUNDS", "6"))
SETTLE = os.environ.get("SETTLE") == "1"
QUERIES = ["swift observation macros", "visited page", "core animation springs"]


def press(code, chars, *mods):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}",
                    "--env", "SEARCH_MEASURE=1", sv.APP], check=True)
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def close_field():
    for _ in range(2):
        if not sv.cmd({"do": "fieldrows", "args": ["state"]}).get("showing"):
            break
        press(53, "\u001b")
        time.sleep(0.4)


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p * (len(values) - 1))))]


def main():
    try:
        sv.setup(**{"sidebar": True, "newtab.floating": True})
        launch()
        sv.cmd({"do": "window"})
        sv.page("Typing ground")
        for i in range(40):
            sv.cmd({"do": "fieldrows", "args": ["visit", f"{sv.BASE}/visited-{i:02d}", str(5 + i * 3), f"Visited page {i:02d} swift"]})
        time.sleep(1)
        inserted, rested, busy, longest, rounds, settled = [], [], [], [], [], []
        for r in range(ROUNDS):
            press(17, "t", "cmd")
            time.sleep(0.8)
            sv.cmd({"do": "idle", "action": "start"})
            sv.cmd({"do": "idle", "action": "frames"})
            got = sv.cmd({"do": "field", "text": QUERIES[r % len(QUERIES)], "type": True, "settle": SETTLE})
            gaps = sv.cmd({"do": "idle", "action": "gaps"})
            if r > 0:
                inserted += [m[0] for m in got["ms"]]
                rested += [m[1] for m in got["ms"]]
                busy.append(gaps.get("busyMs", 0))
                longest.append(gaps.get("longestMs", 0))
                rounds.append([round(m[1], 2) for m in got["ms"]])
                if SETTLE:
                    settled.append([round(m[2], 2) for m in got["ms"]])
            close_field()
            time.sleep(0.5)
        out = {
            "app": sv.APP,
            "keystrokes": len(rested),
            "insertedMedian": statistics.median(inserted),
            "restedMedian": statistics.median(rested),
            "restedP90": pct(rested, 0.9),
            "restedMax": max(rested),
            "busyMsMedian": statistics.median(busy),
            "longestMsMedian": statistics.median(longest),
            "longestMsMax": max(longest),
            "rounds": rounds,
        }
        if SETTLE:
            out["settled"] = settled
        print(json.dumps(out, indent=2))
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(out, indent=2) + "\n")
    finally:
        sv.finish()


if __name__ == "__main__":
    main()

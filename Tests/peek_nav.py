#!/usr/bin/env python3
"""The hidden sidebar moves as one piece with its top line.

Build first (`./build.sh`), then `python3 Tests/peek_nav.py [OUT]` (the
traces go to OUT/peek_nav.json, a temporary folder by default). A world of
its own (SEARCH_PROBE, drawn behind the app in front with SEARCH_SHOWN),
with the column folded for good and the real pointer left out (bench
`pointerless`). Each run calls the peek the way the edge's dwell does,
through bench `ui peektrace {rigid}`, which reads on every display frame,
from the layers' presentation: where back, forward and reload, the space
title and the address field sit inside the sliding card, how far the
traffic lights have slid against the card, and which animations those
views carry. The plain toggle (docked to hidden and back) is read the same
way against the docked column.

Pass: on every frame the nav buttons, title and address sit where they
rest, the lights' slide equals the card's (or the docked column's), and
nothing but the card's own slide animates.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("peek-nav")
t = sv.T()
TOLERANCE = 0.5


def c(**r):
    return sv.cmd(r)


def launch_shown():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", "SEARCH_SHOWN=1", "--env", f"SEARCH_PROBE={sv.W}", sv.APP], check=True)
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())
    return sv.pids()


def check(name, trace, slides=True):
    rigid = trace.get("rigid") or {}
    frames = rigid.get("frames", 0)
    if slides:
        t.ok(f"{name}: the card slid, frame by frame", frames > 3 and rigid.get("sliding", 0) > 3,
             {"frames": frames, "sliding": rigid.get("sliding")})
    t.ok(f"{name}: nav buttons rest inside the card on every frame", rigid.get("helmDrift", 99) <= TOLERANCE,
         rigid.get("helmDrift"))
    t.ok(f"{name}: title and address rest inside the card on every frame", rigid.get("headDrift", 99) <= TOLERANCE,
         rigid.get("headDrift"))
    t.ok(f"{name}: the traffic lights slide with the card", rigid.get("lightsDrift", 99) <= TOLERANCE,
         {"drift": rigid.get("lightsDrift"), "worst": rigid.get("lightsWorst")})
    t.ok(f"{name}: nothing in the top line animates on its own", not rigid.get("keys"), rigid.get("keys"))


try:
    sv.setup(**{"sidebar": True, "tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                "tabs.cards": False, "start.fresh": False, "split": False, "spaces": True})
    pids = launch_shown()
    t.ok("one test copy", len(pids) == 1, pids)
    base = sv.BASE
    for n in range(3):
        sv.sp("open", url=f"{base}/page-{n}")
    time.sleep(1.5)
    results = {}
    for side in ("left", "right"):
        c(do="ui", side=side)
        c(do="ui", folded=True, pointerless=True)
        time.sleep(1.2)
        for run in range(2):
            results[f"{side}-out-{run}"] = c(do="ui", peektrace={"out": True, "seconds": 0.6, "rigid": True})
            time.sleep(0.4)
            results[f"{side}-in-{run}"] = c(do="ui", peektrace={"out": False, "seconds": 0.6, "rigid": True})
            time.sleep(0.4)
        c(do="ui", peek=True)
        time.sleep(0.05)
        results[f"{side}-turn"] = c(do="ui", peektrace={"out": False, "seconds": 0.6, "rigid": True})
        time.sleep(0.4)
        c(do="ui", peek=True)
        time.sleep(0.6)
        results[f"{side}-dock"] = c(do="ui", peektrace={"toggle": True, "seconds": 0.7, "rigid": True})
        time.sleep(0.5)
        c(do="ui", pointerless=True, covered=True)
        time.sleep(0.8)
        c(do="ui", folded=False)
        time.sleep(0.8)
        results[f"{side}-fold"] = c(do="ui", peektrace={"toggle": True, "seconds": 0.7, "rigid": True})
        time.sleep(0.5)
        results[f"{side}-unfold"] = c(do="ui", peektrace={"toggle": True, "seconds": 0.7, "rigid": True})
        time.sleep(0.5)
        c(do="ui", covered=False)
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(tempfile.gettempdir()) / f"peek-nav-{sv.W}"
    out.mkdir(parents=True, exist_ok=True)
    (out / "peek_nav.json").write_text(json.dumps(results, indent=1))
    for name, trace in results.items():
        rigid = trace.get("rigid") or {}
        if name.endswith("-turn"):
            t.ok(f"{name}: turned back mid-slide, the top line stays with the card",
                 rigid.get("helmDrift", 99) <= TOLERANCE and rigid.get("lightsDrift", 99) <= TOLERANCE and not rigid.get("keys"),
                 rigid)
        elif name.endswith("-dock"):
            check(name, trace, slides=False)
            moved = max([abs(p[1]) for p in rigid.get("path", [])] or [99])
            t.ok(f"{name}: docked from the open card, the column is in place from its first frame",
                 rigid.get("frames", 0) > 3 and rigid.get("sliding", 99) == 0 and moved <= TOLERANCE,
                 {"frames": rigid.get("frames"), "sliding": rigid.get("sliding"), "moved": moved})
            t.ok(f"{name}: the card is gone on the first frame of the dock, no ghost of its buttons",
                 rigid.get("cardShown", 99) == 0, rigid.get("cardShown"))
        else:
            check(name, trace)
except Exception:
    import traceback
    traceback.print_exc()
    t.failed += 1
finally:
    sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)

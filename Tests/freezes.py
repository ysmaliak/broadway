#!/usr/bin/env python3
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("freezes")
failures = []


def ok(name, cond, said=None):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  {json.dumps(said)[:1500]}"))
    if not cond:
        failures.append(name)


def freezes():
    return sv.cmd({"do": "freezes"})


def wait(check, within=12.0):
    deadline = time.time() + within
    while time.time() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.25)
    return None


sv.setup()
sv.launch()
try:
    sv.cmd({"do": "freezes", "action": "forget"})
    empty = freezes()
    ok("with no freeze, Copy Last Freeze is off", empty["count"] == 0 and not empty["enabled"], empty)
    ok("the freeze file lives in the test world's folder", "/Broadway (freezes-" in empty["file"], empty["file"])

    sv.cmd({"do": "freezes", "action": "stall", "seconds": 1.2})
    time.sleep(2.5)
    short = freezes()
    ok("a stall of 1.2 seconds is not recorded", short["count"] == 0, short)

    sv.cmd({"do": "freezes", "action": "stall", "seconds": 3.0})
    found = wait(lambda: (lambda f: f if f["count"] == 1 and f["freezes"][0]["ended"] else None)(freezes()))
    ok("a stall of 3 seconds is recorded once it ends", found is not None, freezes())
    if found:
        freeze = found["freezes"][0]
        ok("it lasted between 2 and 3.5 seconds", 2.0 <= freeze["seconds"] <= 3.5, freeze)
        ok("the watchdog caught the main thread's stack", freeze["frames"] > 3 and freeze["from"] == "watchdog", freeze)
        ok("Copy Last Freeze is on", found["enabled"], found)
        report = found["report"]
        print(report)
        ok("the report names the stall's sleep on the main thread", "usleep" in report or "nanosleep" in report or "__semwait_signal" in report,
           report)
        ok("the report holds no path from this Mac", "/Users/" not in report and os.path.expanduser("~") not in report, report)
        ok("the report says Broadway's version and macOS", "Broadway: " in report and "System: macOS " in report, report)
        copied = sv.cmd({"do": "freezes", "action": "copy"})
        ok("Copy Last Freeze copies the report", copied["copied"] and copied["handed"] == ["copy " + report], copied)
finally:
    sv.finish()

print("ALL PASS" if not failures else f"{len(failures)} FAILED: {failures}")
sys.exit(1 if failures else 0)

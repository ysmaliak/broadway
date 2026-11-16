#!/usr/bin/env python3
"""Open and close things fifty times; memory comes back, and nothing leaks.

Build first (`./build.sh`), then `python3 Tests/churn_leaks.py [--json PATH]
[--rounds N] [--leaks]`. A test copy in a world of its own, shown behind the
app in front (SEARCH_SHOWN, so Settings is its own window), never brought
forward. Each kind is warmed up five times, then measured: footprint after a
settle, N opens and closes of tabs (a local page each), windows, Settings and
the peek, and the footprint and live counts (bench `alive`) after each. With
`--leaks`, `leaks` runs on the test copy at the end and its summary and root
cycles are kept beside the JSON.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
sv.use("churn-leaks")

ROOT = Path(__file__).resolve().parents[1]


def arg(name, default):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else default


OUT = Path(arg("--json", ROOT / ".context/churn.json"))
ROUNDS = int(arg("--rounds", 50))


def footprint(pid):
    out = subprocess.run(["footprint", "-f", "bytes", "--noCategories", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"phys_footprint:\s*(\d+)", out)
    return round(int(m.group(1)) / 1e6, 1) if m else None


def launch():
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    return next(iter(sv.holding() & sv.running()))


def tab_round(i):
    r = sv.sp("open", url=f"{sv.BASE}/churn-{i}")["resultID"]
    time.sleep(0.25)
    sv.sp("close", id=r)


def window_round(i):
    sv.cmd({"do": "windows", "action": "new"}); time.sleep(0.5)
    n = sv.cmd({"do": "alive"})["windows"]
    sv.cmd({"do": "windows", "action": "close", "n": n}); time.sleep(0.4)


def settings_round(i):
    sv.cmd({"do": "ui", "settings": True}); time.sleep(0.5)
    sv.cmd({"do": "ui", "settingsClose": True}); time.sleep(0.3)


def peek_round(i):
    sv.cmd({"do": "peek", "url": f"{sv.BASE}/peek-{i}"}); time.sleep(0.5)
    sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.3)


def settle(pid, seconds=8):
    time.sleep(seconds)
    alive = sv.cmd({"do": "alive"})
    return {"footprintMB": footprint(pid), "tabs": alive["tabs"], "pages": alive["pages"], "windows": alive["windows"],
            "inRows": alive["inRows"]}


def main():
    t = sv.T()
    out = {"rounds": ROUNDS, "load": os.getloadavg(), "kinds": {}}
    try:
        sv.setup(sidebar=True)
        pid = launch()
        out["pid"] = int(pid)
        home = sv.page("home")
        for x in [x["id"] for x in sv.sp("state")["tabs"] if x["id"] != home]: sv.sp("close", id=x)
        for name, step in [("tabs", tab_round), ("windows", window_round), ("settings", settings_round), ("peek", peek_round)]:
            for i in range(5): step(f"warm-{i}")
            before = settle(pid)
            started = time.time()
            for i in range(ROUNDS): step(i)
            after = settle(pid)
            grew = round(after["footprintMB"] - before["footprintMB"], 1)
            out["kinds"][name] = {"before": before, "after": after, "grewMB": grew, "seconds": round(time.time() - started, 1),
                                  "load": os.getloadavg()}
            print(f"{name:9} {before['footprintMB']:7.1f} → {after['footprintMB']:7.1f} MB ({grew:+.1f})  "
                  f"tabs {before['tabs']}→{after['tabs']} pages {before['pages']}→{after['pages']} windows {before['windows']}→{after['windows']}")
            t.ok(f"{name}: live tabs and pages back where they were",
                 after["tabs"] <= before["tabs"] and after["pages"] <= before["pages"] and after["windows"] <= before["windows"], (before, after))
            t.ok(f"{name}: footprint within 25 MB of where it started", grew < 25, grew)
        if "--leaks" in sys.argv:
            report = subprocess.run(["leaks", str(pid)], capture_output=True, text=True).stdout
            Path(OUT.with_suffix(".leaks.txt")).write_text(report)
            m = re.search(r"Process \d+: (\d+) leaks? for (\d+) total leaked bytes", report)
            out["leaks"] = {"count": int(m.group(1)), "bytes": int(m.group(2))} if m else report[-400:]
            out["cycles"] = report.count("ROOT CYCLE")
            print("leaks:", out["leaks"], "root cycles:", out["cycles"])
    finally:
        sv.finish()
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(out, indent=1))
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

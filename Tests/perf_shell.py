#!/usr/bin/env python3
"""Launch, memory with twenty tabs, and a space switch, for before and after.

Build first (`./build.sh`), then `python3 Tests/perf_shell.py [OUT.json]`;
BROADWAY_APP picks another build. A test copy in a world of its own, started
hidden behind the app in front. Launch is from `open` to the bench socket
answering a window state, three times. Memory is the app's phys_footprint
five seconds after twenty local pages opened. A space switch is the
main-thread busy time and longest span from the idle watch over a switch
to the second space and back, five times.
"""
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("perf-shell")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/perf-shell.json")


def footprint(pid):
    out = subprocess.run(["footprint", "-f", "bytes", "--noCategories", "-p", str(pid)],
                         capture_output=True, text=True).stdout
    m = re.search(r"phys_footprint:\s*(\d+)", out)
    return int(m.group(1)) if m else None


def timed_launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    began = time.monotonic()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", sv.APP], check=True)
    answered = None
    for _ in range(600):
        if os.path.exists(sv.SOCK):
            try:
                sv.cmd({"do": "window"})
                answered = time.monotonic() - began
                break
            except Exception:
                pass
        time.sleep(0.02)
    time.sleep(1)
    sv.started.update(sv.running() - before)
    if answered is None:
        raise RuntimeError("no bench socket")
    return answered * 1000


def main():
    out = {"app": sv.APP}
    try:
        launches = []
        for _ in range(3):
            sv.setup(sidebar=True, spaces=True)
            launches.append(timed_launch())
            sv.quit()
            time.sleep(1)
        out["launchMs"] = [round(x) for x in launches]
        out["launchMsMedian"] = round(statistics.median(launches))
        out["loadLaunch"] = os.getloadavg()

        sv.setup(sidebar=True, spaces=True)
        timed_launch()
        for i in range(20):
            sv.sp("open", url=f"{sv.BASE}/page-{i:02d}")
            time.sleep(0.3)
        time.sleep(5)
        pid = sv.pids()[0]
        out["footprintMB20Tabs"] = round(footprint(pid) / 1e6, 1)
        out["load20Tabs"] = os.getloadavg()

        sv.cmd({"do": "space", "action": "new", "name": "Two"})
        time.sleep(1)
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1)
        busy, longest = [], []
        for _ in range(5):
            for index in (2, 1):
                sv.cmd({"do": "idle", "action": "start"})
                sv.cmd({"do": "idle", "action": "frames"})
                sv.cmd({"do": "space", "action": "goto", "index": index})
                time.sleep(1.2)
                gaps = sv.cmd({"do": "idle", "action": "gaps"})
                busy.append(gaps.get("busyMs", 0))
                longest.append(gaps.get("longestMs", 0))
        out["spaceSwitchBusyMsMedian"] = round(statistics.median(busy), 1)
        out["spaceSwitchLongestMsMedian"] = round(statistics.median(longest), 1)
        out["spaceSwitchLongestMsMax"] = round(max(longest), 1)
        out["loadSpaceSwitch"] = os.getloadavg()
        if os.environ.get("PERF_100"):
            for i in range(20, 100):
                sv.sp("open", url=f"{sv.BASE}/page-{i:02d}")
                time.sleep(0.2)
            time.sleep(8)
            out["footprintMB100Tabs"] = round(footprint(pid) / 1e6, 1)
            out["load100Tabs"] = os.getloadavg()
        print(json.dumps(out, indent=2))
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(out, indent=2) + "\n")
    finally:
        sv.finish()


if __name__ == "__main__":
    main()

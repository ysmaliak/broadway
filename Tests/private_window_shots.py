#!/usr/bin/env python3
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import world_out as wo  # noqa: E402

sv.use("private-window-shots")
OUT = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parents[1] / ".context" / "evidence" / "private-window")

os.makedirs(OUT, exist_ok=True)
t = sv.T()
try:
    sv.setup(sidebar=True)
    sv.launch()
    sv.cmd({"do": "windows", "action": "private"})
    time.sleep(2)
    for name in ["notes", "reading"]:
        sv.cmd({"do": "split", "action": "open", "url": f"{sv.BASE}/{name}", "window": 2})
        time.sleep(1)
    for look in ["light", "dark"]:
        sv.cmd({"do": "ui", "look": look})
        time.sleep(3)
        for n, kind in [(2, "private"), (1, "normal")]:
            path = f"{OUT}/{kind}-{look}.png"
            made = wo.spot(sv, f"{kind}-{look}.png")
            sv.cmd({"do": "picture", "path": str(made), "page": False, "window": n})
            if made.exists():
                wo.bring(made, path)
            t.ok(f"{kind} window, {look}: pictured", os.path.getsize(path) > 0 if os.path.exists(path) else False, path)
    sv.cmd({"do": "ui", "look": "system"})
finally:
    t.done()
    sv.finish()
sys.exit(1 if t.failed else 0)

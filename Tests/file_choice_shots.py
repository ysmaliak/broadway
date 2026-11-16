#!/usr/bin/env python3
"""Window-only compositor captures, each from its own disposable test world."""
import json
import subprocess
import time
import uuid
from pathlib import Path

import file_choice as fc

sv = fc.sv


def main():
    t = sv.T()
    shots = Path(__file__).resolve().parents[1] / ".context" / "evidence"
    shots.mkdir(parents=True, exist_ok=True)
    for mode, selector, private in [("images", "#image", False), ("multiple", "#multi", False), ("private-empty", "#any", True)]:
        sv.use("fc-" + mode[0] + "-" + uuid.uuid4().hex[:8])
        support = Path(sv.SUPPORT)
        support.mkdir(parents=True, exist_ok=False)
        (support / "seed.png").write_bytes(fc.PNG)
        (support / "notes.txt").write_text("Local fixture")
        subprocess.run(["defaults", "write", sv.SUITE, "bench", "-bool", "true"], check=True)
        try:
            sv.launch()
            sv.cmd({"do": "window"})
            fc.box("enable")
            sv.cmd({"do": "ui", "look": "light"})
            for name in ["seed.png", "notes.txt"]:
                sv.cmd({"do": "uploads", "action": "add", "values": [str(support / name), "fixture.example"]})
            tab = (sv.cmd({"do": "open", "url": sv.BASE + "/shot", "private": True})["id"] if private
                   else sv.sp("open", url=sv.BASE + "/shot")["resultID"])
            n = next(w["n"] for w in sv.cmd({"do": "windows", "action": "list"})["windows"] if w["private"]) if private else None
            sv.cmd({"do": "select", "id": tab})
            fc.until(lambda: sv.ev(tab, "!!document.querySelector('#image')") is True)
            if not private:
                sv.ev(tab, "document.querySelector('#download').click();1")
                fc.until(lambda: any(x["name"] == "recent.png" for x in sv.cmd({"do": "uploads"})["items"]))
            sv.ev(tab, f"document.querySelector('{selector}').focus();document.querySelector('{selector}').click();1")
            fc.until(lambda: fc.box(window=n).get("ready"))
            if mode == "multiple":
                fc.box("select", "0")
                fc.box("select", "2", "command")
                fc.box("select", "0", "shift")
            result = fc.capture_picker(shots / f"file-choice-{mode}.png", n)
            t.ok(f"{mode} native picker window captured", result["saved"], result)
            time.sleep(0.2)
            state = fc.box(window=n)
            t.ok(f"{mode} stays inside the visibility guard", not state.get("onScreen"), state)
        finally:
            fc.cleanup_world(support)
    (shots / "file-choice-visual-results.json").write_text(json.dumps({"passed": t.passed, "failed": t.failed}, indent=2))
    t.done()
    if t.failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

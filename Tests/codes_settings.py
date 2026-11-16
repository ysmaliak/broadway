#!/usr/bin/env python3
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("codes-set")
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".context" / "codes-messages"
SHOT = OUT / "shot"


def settings(**f): return sv.cmd({"do": "settings", **f})


def shot(t, name):
    if not SHOT.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests" / "WindowShot.swift"), "-o", str(SHOT)], check=True)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    time.sleep(0.8)
    pid = next(iter(sv.holding() & sv.running()))
    path = OUT / f"{name}.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    t.ok(f"pictured {name}", path.exists(), said)


def main():
    t = sv.T()
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"codes.messages": True, "start.fresh": True})
        sv.launch()
        found = [i["id"] for i in settings(find="one-time code")["found"]]
        t.ok("“one-time code” finds Codes from Gmail first", found[:1] == ["codes.gmail"], found)
        for words in ["sms", "text message", "full disk access", "messages"]:
            hits = [i["id"] for i in settings(find=words)["found"]]
            t.ok(f"“{words}” finds no code row", not any(h.startswith("codes.") for h in hits), hits)
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.2)
        sv.cmd({"do": "ui", "settingsPage": "passwords"})
        time.sleep(1.2)
        shown = settings(row="codes.gmail")
        rows = shown.get("rows", [])
        t.ok("Passwords has Codes from Gmail", "codes.gmail" in rows, rows)
        t.ok("…and no Messages row or access line, with the old key still set",
             not any(r.startswith("codes.messages") for r in rows), rows)
        t.ok("…its switch is on by default", (shown.get("row") or {}).get("on") is True, shown.get("row"))
        sv.cmd({"do": "ui", "look": "dark"})
        time.sleep(1.0)
        shot(t, "settings-passwords-dark")
        sv.cmd({"do": "ui", "settings": False})
        time.sleep(0.6)
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("onepassword-set")

INTEGRATION = "Turn on Integrate with 1Password CLI in the 1Password app, in Settings › Developer"
MISSING = "The 1Password command line tool isn't on this Mac. Install 1Password CLI from 1Password's website."


def settings(**f): return sv.cmd({"do": "settings", **f})


def row(id):
    shown = settings(row=id)
    return shown.get("row") or {}, shown.get("rows", [])


def main():
    t = sv.T()
    real = any(os.access(p, os.X_OK) for p in ["/opt/homebrew/bin/op", "/usr/local/bin/op"])
    try:
        sv.setup(**{"start.fresh": True})
        sv.launch()
        found = [i["id"] for i in settings(find="1password")["found"]]
        t.ok("“1password” finds the switch first", found[:1] == ["passwords.onepassword"], found)
        sv.cmd({"do": "ui", "settings": True}); time.sleep(1.2)
        sv.cmd({"do": "ui", "settingsPage": "passwords"}); time.sleep(1.2)
        shown, rows = row("passwords.onepassword")
        t.ok("Passwords › Sign-ins has the 1Password row", "passwords.onepassword" in rows, rows)
        t.ok("…off by default", shown.get("on") is False, shown)
        t.ok("…saying what it needs", shown.get("detail") == "Uses the 1Password command line tool", shown)
        sv.cmd({"do": "ui", "settings": False}); time.sleep(0.6)

        sv.setup(**{"start.fresh": True, "passwords.onepassword": True})
        sv.launch()
        sv.cmd({"do": "ui", "settings": True}); time.sleep(1.2)
        sv.cmd({"do": "ui", "settingsPage": "passwords"})
        detail, rows = "", []
        for _ in range(40):
            time.sleep(0.5)
            shown, rows = row("passwords.onepassword")
            detail = shown.get("detail", "")
            if detail and detail != "Looking for 1Password":
                break
        t.ok("turned on, the switch is on", shown.get("on") is True, shown)
        print(f"  real op here: {real}, the row says: {detail}")
        if real:
            t.ok("with op here and no account in the app, the row says what 1Password needs", detail == INTEGRATION, detail)
        else:
            t.ok("with no op here, the row says to install it", detail == MISSING, detail)
        t.ok("…and offers Check Again", "passwords.onepassword.again" in rows, rows)
        sv.cmd({"do": "ui", "settings": False}); time.sleep(0.6)
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

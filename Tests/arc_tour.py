#!/usr/bin/env python3
"""A fresh test copy's small surfaces, pictured window-only.

Build first (`./build.sh`), then `python3 Tests/arc_tour.py [OUT]`. A test
copy in a world of its own, with an empty profile, started hidden; its window
is put below the desktop, where nothing shows on a screen and
`screencapture -l` still pictures it alone. It pictures the first window,
the welcome when the build has one, the New Tab page, the empty History,
Downloads, Bookmarks and Files pages, a page that can't be found, a refused
connection, and the About window when the build has one. BROADWAY_APP picks
another build, for before and after.
"""
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("arc-tour")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/tour")
WINDOW = [0]
t = sv.T()


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [1100, 720]})["window"]
    time.sleep(1.0)


def shoot(name, number=None):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(number or WINDOW[0]), str(path)], capture_output=True)
    t.ok(f"pictured {name}", path.exists())
    return path


def open_url(url, wait=1.5):
    r = sv.sp("open", url=url)
    time.sleep(wait)
    return r.get("resultID")


def closed_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def welcome(action, **more):
    try:
        return sv.cmd({"do": "welcome", "action": action, **more})
    except RuntimeError:
        return None


def about():
    try:
        return sv.cmd({"do": "about"}).get("window")
    except RuntimeError:
        return None


def main():
    try:
        for dark in (False, True):
            mode = "dark" if dark else "light"
            sv.setup(**{"onboarding.show": True, "delight.show": True}); sv.launch()
            stage(dark)
            shoot(f"{mode}-01-first-window")
            state = welcome("state")
            if state and state.get("shown"):
                typed = welcome("press", key="abc")
                t.ok("typing during the intro reaches nothing behind it", typed["typed"] == "" and typed["phase"] == "intro", typed)
                ret = welcome("press", key="return")
                t.ok("Return skips the intro to the first step", ret["phase"] == "steps" and ret["index"] == 0, ret)
                for index, step in enumerate(state.get("steps", [])):
                    number = sv.cmd({"do": "surface", "name": "onboarding", "step": index + 1, "look": mode})["number"]
                    time.sleep(0.6)
                    shoot(f"{mode}-02-welcome-{step}", number)
                    sv.cmd({"do": "surface", "action": "close"})
                welcome("look:noir")
                painted = welcome("primary")
                t.ok("the first step paints the space", painted and painted.get("look") == "noir" and painted["index"] == 1, painted)
                welcome("go:bring")
                if dark:
                    done = welcome("press", key="return")
                    t.ok("Return on the last step opens Bring Things Over", done["isBringing"] and not done["shown"], done)
                else:
                    done = welcome("press", key="escape")
                    t.ok("Escape on the last step starts fresh", not done["isBringing"] and not done["shown"], done)
                t.ok("finishing marks the welcome seen", done and done.get("seen") and not done.get("shown"), done)
                skipped = welcome("replay")
                skipped = welcome("press", key="cmd-w")
                t.ok("Command-W ends it from anywhere", not skipped["shown"] and skipped["seen"], skipped)
                time.sleep(1.2)
                shoot(f"{mode}-03-after-welcome")
            open_url("broadway://history"); shoot(f"{mode}-04-history")
            open_url("broadway://bookmarks"); shoot(f"{mode}-06-bookmarks")
            open_url("broadway://files"); shoot(f"{mode}-07-files")
            open_url("http://nothing-here.invalid/", wait=3); shoot(f"{mode}-08-not-found")
            open_url(f"http://127.0.0.1:{closed_port()}/", wait=3); shoot(f"{mode}-09-refused")
            trouble = sv.cmd({"do": "trouble"})
            t.ok("a refused connection is read as refused", trouble.get("trouble") == "refused", trouble)
            pinned = open_url(f"{sv.BASE}/first-pin", wait=1)
            sv.cmd({"do": "pin", "id": pinned})
            time.sleep(0.5)
            shoot(f"{mode}-11-first-pin")
            delight = sv.cmd({"do": "delight"})
            t.ok("the first pin is celebrated", "delight.firstPin" in delight.get("celebrated", []), delight)
            second = open_url(f"{sv.BASE}/second-pin", wait=1)
            sv.cmd({"do": "pin", "id": second})
            again = sv.cmd({"do": "delight"})
            t.ok("and only once", again.get("celebrated", []).count("delight.firstPin") == 1, again)
            number = about()
            if number:
                time.sleep(0.8)
                shoot(f"{mode}-10-about", number)
            sv.finish()
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""The picture under the pointer while a tab is out of its window, on screen.

Build first (`./build.sh`), then `python3 Tests/tab_tear_shots.py` from a
worktree. The world is shown (SEARCH_SHOWN=1), as dia_raised_shots.py does
it, and the drag is the sidebar's own gesture driven by `bench tear`. Each
still is one window taken by its number with WindowShot.swift: the picture's
own panel and the probe's main window at the same moment. Never a region of
the display. Stills go to .context/tear/ in this checkout.

Four stills of the picture: a tab with a page picture and a tab whose page
failed to load, which has none (the card), each light and dark. Then, with Reduce Motion, the picture is checked
to come and go with no animation.
"""
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-tear-shots")
OUT = sv.ROOT / ".context" / "tear"
SHOT = sv.ROOT / ".build" / "tear-window-shot"
FRAME = [80, 220, 820, 600]


def tear(action, **more):
    return sv.cmd({"do": "tear", "action": action, **more})


def launch_shown():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


def shoot(pid, number, name):
    path = OUT / f"{name}.png"
    ran = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True)
    print("  ", ran.stdout.strip(), ran.stderr.strip()[-300:])
    return path.exists()


def away_point():
    left, bottom, width, height = FRAME
    return [left + width + 260, bottom + height - 220]


def still(t, pid, main, id, name):
    tear("begin", id=id)
    said = tear("move", at=away_point())
    time.sleep(0.8)
    said = tear("read")
    t.ok(f"{name}: the tab is away and its picture is on screen", said["away"] and said["picture"] and said["pictureShown"], said)
    if said.get("pictureNumber"):
        t.ok(f"{name}: a still of the picture", shoot(pid, said["pictureNumber"], f"{name}-picture"))
        shoot(pid, main, f"{name}-window")
    tear("cancel")
    time.sleep(0.6)
    return said


def main():
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(sv.ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(splitView=True)
    launch_shown()
    try:
        pid = next(iter(sv.holding() & sv.running()))
        main = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        print("  shown, window", main, flush=True)
        sv.cmd({"do": "windows", "action": "frame", "n": 1, "frame": FRAME})
        page = sv.cmd({"do": "split", "action": "open", "url": f"{sv.BASE}/tear-picture-with-a-longer-title-than-fits"})["resultID"]
        sv.cmd({"do": "split", "action": "open", "url": f"{sv.BASE}/other"})
        time.sleep(1.5)
        print("  opened two pages", flush=True)
        blank = sv.cmd({"do": "split", "action": "open", "url": "http://127.0.0.1:9/an-unreachable-page-whose-address-is-far-too-long-to-fit-on-the-card"})["resultID"]
        time.sleep(2)
        print("  a tab with no picture", blank, flush=True)
        sv.cmd({"do": "select", "id": page})
        time.sleep(1.5)
        sv.cmd({"do": "select", "id": blank})
        time.sleep(1)
        for look in ["light", "dark"]:
            sv.cmd({"do": "ui", "look": look})
            time.sleep(1)
            said = still(t, pid, main, page, f"page-{look}")
            t.ok(f"page-{look}: it shows the page's picture, not the card", not said.get("card"), said)
            said = still(t, pid, main, blank, f"card-{look}")
            t.ok(f"card-{look}: a tab with no picture shows the card", said.get("card"), said)

        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(1)
        tear("begin", id=page)
        said = tear("move", at=away_point())
        t.ok("Reduce Motion: the picture is up at once, with nothing moving", said["picture"] and said["pictureShown"] and not said["moving"], said)
        said = tear("move", at=[FRAME[0] + 120, FRAME[1] + FRAME[3] - 200])
        t.ok("Reduce Motion: back inside, it is gone at once", not said["picture"] and not said["pictureShown"], said)
        tear("letgo")
        subprocess.run(["defaults", "delete", sv.SUITE, "motion.testReduced"], capture_output=True)
        time.sleep(0.5)
        tear("begin", id=page)
        said = tear("move", at=away_point())
        t.ok("with motion: the picture comes in with its fade and spring", said["picture"] and len(said["moving"]) > 0, said)
        tear("cancel")
    except Exception as error:
        t.ok("ran to the end", False, error)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

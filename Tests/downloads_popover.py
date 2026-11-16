#!/usr/bin/env python3
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

ESC, DOWN, UP, RETURN, SPACE = 53, 125, 126, 36, 49
t = sv.T()
plain = sv.srv.RequestHandlerClass


class Files(plain):
    def do_GET(self):
        if self.path not in ("/slow.bin", "/quick.zip"):
            return plain.do_GET(self)
        pieces = 60 if self.path == "/slow.bin" else 1
        piece = b"0" * 65536
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{self.path[1:]}"')
        self.send_header("Content-Length", str(pieces * len(piece)))
        self.end_headers()
        try:
            for _ in range(pieces):
                self.wfile.write(piece)
                self.wfile.flush()
                if pieces > 1:
                    time.sleep(0.2)
        except OSError:
            pass


sv.srv.RequestHandlerClass = Files


def start():
    sv.use("downloads-popover-" + uuid.uuid4().hex[:6])
    sv.setup(sidebar=True, **{"start.fresh": False})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    sv.cmd({"do": "resize", "width": 1000, "height": 720, "steps": 1})
    sv.cmd({"do": "ui", "downloadsbutton": True, "windowAt": "bottom"})
    sv.sp("open", url=f"{sv.BASE}/page")
    time.sleep(1)
    sv.cmd({"do": "idle", "action": "unhide"})
    time.sleep(1)


def probe():
    return sv.cmd({"do": "probe"})


def popovers():
    return [w for w in probe()["windows"] if w["kind"] == "_NSPopoverWindow" and w["visible"]]


def until(check, within=4.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.15)
    return check()


def stage(name):
    sv.cmd({"do": "ui", "downloadsStage": name})
    time.sleep(0.3)


def settled():
    try:
        return sv.cmd({"do": "downloadslist"})["responder"] == "DownloadsTable"
    except RuntimeError:
        return False


def show():
    sv.cmd({"do": "ui", "recentdownloads": True})
    up = until(popovers)
    until(settled)
    return up


def hide():
    sv.cmd({"do": "ui", "recentdownloads": False})
    until(lambda: not popovers())
    time.sleep(0.3)


def rows(**ask):
    return sv.cmd({"do": "downloadslist", **ask})["rows"]


def named(found, name):
    return next((r for r in found if r.get("name") == name), None)


def case_surface():
    stage("kept")
    up = show()
    t.ok("the list opens in a system popover", bool(up), probe()["windows"])
    t.ok("no custom popup panel is up", not [w for w in probe()["windows"] if w["kind"] == "KitPopupPanel" and w["visible"]])
    main = next(w for w in probe()["windows"] if w["kind"] != "_NSPopoverWindow" and w["visible"] and w["frame"][2] > 600)
    if up:
        frame, window = up[0]["frame"], main["frame"]
        t.ok("it opens above the button, inside the window's bottom, when the window sits on the screen's bottom edge",
             frame[1] >= window[1] - 16 and frame[1] + frame[3] <= window[1] + window[3] + 16, (frame, window))
    hide()
    t.ok("closing it leaves no popover", not popovers())


def case_rows():
    stage("empty")
    show()
    found = rows()
    t.ok("empty: one quiet line, then the two actions",
         [r["name"] for r in found] == ["No Recent Downloads", "Show All Downloads", "Clear"], [r["name"] for r in found])
    t.ok("empty: the line can't be chosen", not found[0]["clickable"])
    t.ok("empty: Show All Downloads can be chosen and Clear can't", found[1]["clickable"] and not found[2]["clickable"], found[1:])
    hide()

    stage("many")
    show()
    found = rows()
    running = named(found, "Xcode_27.1.xip")
    t.ok("running: a bar, its size, Pause and Cancel",
         running and running["bar"] and not running["indeterminate"] and running["keys"] == ["pause", "cancel"]
         and running["detail"] == "1.93 GB of 4.6 GB", running)
    unsized = named(found, "stream-capture.mov")
    t.ok("running with no size: the bar turns and says what came", unsized and unsized["indeterminate"]
         and unsized["detail"] == "48 MB downloaded", unsized)
    paused = named(found, "dataset.tar.gz")
    t.ok("paused: says so, with Resume and Remove", paused and paused["keys"] == ["resume", "remove"]
         and paused["detail"].startswith("Paused · "), paused)
    failed = named(found, "ubuntu-26.10-desktop-arm64.iso")
    t.ok("failed: no bar, the reason, Retry and Remove", failed and not failed["bar"]
         and failed["detail"] == "The network connection was lost." and failed["keys"] == ["retry", "remove"], failed)
    t.ok("failed: a shorter row than a running one", failed and running and failed["height"] < running["height"])
    kept = named(found, "Installer.dmg")
    t.ok("kept: its icon, where it came from, Show in Finder; a click opens it",
         kept and kept["icon"] and kept["detail"] == "downloads.example.com" and kept["keys"] == ["reveal"] and kept["clickable"]
         and kept["menu"] == ["open", "reveal", "forget"], kept)
    gone = named(found, "Gone already.pdf")
    t.ok("kept but missing: no click, its button off, only Remove from List in its menu",
         gone and not gone["clickable"] and not gone["enabled"] and gone["menu"] == ["forget"], gone)
    long = [r for r in found if r.get("name", "").startswith("Quarterly planning notes")]
    t.ok("a long name keeps inside its row", len(long) == 2 and all(r["nameWidth"] <= r["frame"][1] - 40 for r in long), long)
    t.ok("running rows are not chosen by a click", running and not running["clickable"])
    up = popovers()
    main = next(w for w in probe()["windows"] if w["kind"] != "_NSPopoverWindow" and w["visible"] and w["frame"][2] > 600)
    t.ok("many rows: the popover stops growing and the list scrolls",
         up and up[0]["frame"][3] < 560 and sum(r.get("height", 0) for r in found) > 392, (up, main))
    t.ok("Clear can be chosen when there is something to clear", found[-1]["name"] == "Clear" and found[-1]["clickable"])


def case_actions():
    before = popovers()[0]["frame"][3]
    count = len(rows())
    index = next(i for i, r in enumerate(rows()) if r.get("name") == "ubuntu-26.10-desktop-arm64.iso")
    after = rows(action="press", row=index, verb="remove")
    t.ok("Remove takes a failed download off the list", len(after) == count - 1
         and not named(after, "ubuntu-26.10-desktop-arm64.iso"), [r["name"] for r in after])
    index = next(i for i, r in enumerate(after) if r.get("name") == "dataset.tar.gz")
    after = rows(action="press", row=index, verb="remove")
    t.ok("Remove takes a paused download off the list", not named(after, "dataset.tar.gz"))
    index = next(i for i, r in enumerate(after) if r.get("name") == "Notes.txt")
    after = rows(action="press", row=index, verb="forget")
    t.ok("Remove from List forgets a kept file", not named(after, "Notes.txt"))
    t.ok("the popover is still up after those", bool(popovers()))
    hide()
    stage("failed")
    show()
    shorter = popovers()[0]["frame"][3]
    found = rows()
    index = next(i for i, r in enumerate(found) if r.get("name") == "ubuntu-26.10-desktop-arm64.iso")
    rows(action="press", row=index, verb="remove")
    time.sleep(0.6)
    t.ok("the popover shrinks when a row goes", popovers() and popovers()[0]["frame"][3] < shorter < before,
         (popovers(), shorter, before))
    found = rows()
    sv.cmd({"do": "downloadslist", "action": "press", "row": len(found) - 2})
    time.sleep(0.8)
    state = probe()
    t.ok("Show All Downloads closes the list and opens Downloads", not state["downloadsOpen"] and state["downloads"]
         and not popovers(), (state["downloadsOpen"], state["downloads"]))
    sv.cmd({"do": "ui", "downloads": False})
    time.sleep(0.5)
    stage("kept")
    show()
    found = rows()
    sv.cmd({"do": "downloadslist", "action": "press", "row": len(found) - 1})
    time.sleep(0.8)
    t.ok("Clear closes the list", not probe()["downloadsOpen"] and not popovers())
    sv.cmd({"do": "ui", "downloadsbutton": True})
    show()
    t.ok("Clear empties it", [r["name"] for r in rows()][0] == "No Recent Downloads", rows())
    hide()


def click(name, verb=None):
    index = next(i for i, r in enumerate(rows()) if r.get("name") == name)
    ask = {"do": "downloadslist", "action": "click", "row": index}
    if verb:
        ask["verb"] = verb
    return sv.cmd(ask)


def press(name):
    index = next(i for i, r in enumerate(rows()) if r.get("name") == name)
    return sv.cmd({"do": "downloadslist", "action": "axpress", "row": index})


def case_clicks():
    stage("many")
    show()
    said = click("ubuntu-26.10-desktop-arm64.iso", "remove")
    t.ok("a click on a row's Remove button takes the row away and leaves the list open",
         said["hit"] == "NSButton" and said["open"] and not named(said["rows"], "ubuntu-26.10-desktop-arm64.iso"), said["hit"])
    count = len(said["rows"])
    said = click("Gone already.pdf")
    t.ok("a click on a file that is gone does nothing", said["open"] and len(said["rows"]) == count and not said["asked"], said["asked"])
    said = click("Xcode_27.1.xip")
    t.ok("a click on a running download does nothing", said["open"] and len(said["rows"]) == count and not said["asked"])
    said = click("broadway-press-kit.zip", "reveal")
    t.ok("a click on the magnifier shows the file in Finder and closes the list",
         said["asked"] == ["reveal broadway-press-kit.zip"] and not said["open"], said["asked"])
    show()
    said = click("Installer.dmg")
    t.ok("one click on a kept file opens it and closes the list",
         said["asked"][-1:] == ["open Installer.dmg"] and not said["open"] and not popovers(), said["asked"])
    show()
    said = click("Show All Downloads")
    t.ok("a click on Show All Downloads opens Downloads", not said["open"] and probe()["downloads"])
    sv.cmd({"do": "ui", "downloads": False})
    time.sleep(0.5)
    show()
    said = press("Gone already.pdf")
    t.ok("VoiceOver's press on a file that is gone is refused", not said["pressed"] and said["open"], said)
    said = press("Notes.txt")
    t.ok("VoiceOver's press on a kept file opens it", said["pressed"] and said["asked"][-1:] == ["open Notes.txt"] and not said["open"], said)
    show()
    said = press("Show All Downloads")
    t.ok("VoiceOver's press on Show All Downloads opens Downloads", said["pressed"] and not said["open"] and probe()["downloads"], said)
    sv.cmd({"do": "ui", "downloads": False})
    time.sleep(0.5)
    show()
    said = press("Clear")
    t.ok("VoiceOver's press on Clear clears", said["pressed"] and not said["open"], said)
    hide()


def case_keys():
    stage("kept")
    up = show()
    answer = sv.cmd({"do": "downloadslist"})
    t.ok("the list takes the keyboard", answer["responder"] == "DownloadsTable", answer["responder"])
    t.ok("nothing is chosen when it opens", not any(r["selected"] for r in answer["rows"]))
    found = rows(action="key", code=DOWN)
    t.ok("Down chooses the first row", [r["selected"] for r in found] == [True, False, False, False, False], found)
    rows(action="key", code=DOWN)
    found = rows(action="key", code=DOWN)
    t.ok("Down again reaches the last file", found[2]["selected"])
    found = rows(action="key", code=DOWN)
    t.ok("Down from the last file goes to Show All Downloads", found[3]["selected"] and not found[2]["selected"], found)
    found = rows(action="key", code=DOWN)
    t.ok("then to Clear", found[4]["selected"])
    rows(action="key", code=UP)
    found = rows(action="key", code=UP)
    t.ok("Up comes back into the files", found[2]["selected"] and not found[3]["selected"], found)
    found = rows(action="select", row=1)
    t.ok("one row is chosen at a time", sum(1 for r in found if r["selected"]) == 1 and found[1]["selected"])
    sv.cmd({"do": "press", "code": ESC, "chars": "\x1b", "number": up[0]["number"]})
    time.sleep(0.6)
    t.ok("Escape in the popover closes it", not probe()["downloadsOpen"] and not popovers(), probe()["downloadsOpen"])
    show()
    sv.cmd({"do": "press", "code": ESC, "chars": "\x1b"})
    time.sleep(0.6)
    t.ok("Escape in the window closes it", not probe()["downloadsOpen"] and not popovers())
    show()
    rows(action="key", code=DOWN)
    rows(action="key", code=DOWN)
    rows(action="key", code=DOWN)
    rows(action="key", code=DOWN)
    sv.cmd({"do": "downloadslist", "action": "key", "code": RETURN})
    time.sleep(0.8)
    state = probe()
    t.ok("Return on Show All Downloads opens Downloads", state["downloads"] and not state["downloadsOpen"])
    sv.cmd({"do": "ui", "downloads": False})
    time.sleep(0.5)
    show()
    for _ in range(5):
        rows(action="key", code=DOWN)
    sv.cmd({"do": "downloadslist", "action": "key", "code": SPACE})
    time.sleep(0.8)
    t.ok("Space on Clear clears and closes", not probe()["downloadsOpen"])
    show()
    t.ok("and the list is empty after it", rows()[0]["name"] == "No Recent Downloads", rows())
    hide()


def case_door():
    stage("kept")
    hide()
    for via in ("window", "post"):
        opened = sv.cmd({"do": "downloadslist", "action": "click", "via": via})["open"]
        t.ok(f"a press on the button opens the list ({via})", opened and bool(until(popovers)))
        until(settled)
        closed = sv.cmd({"do": "downloadslist", "action": "click", "via": via})["open"]
        t.ok(f"a press on the button while it is open closes it, and it stays closed ({via})",
             not closed and not probe()["downloadsOpen"] and not popovers(), (closed, probe()["downloadsOpen"]))
        again = sv.cmd({"do": "downloadslist", "action": "click", "via": via})["open"]
        t.ok(f"the next press opens it again ({via})", again and bool(until(popovers)))
        hide()
    show()
    sv.cmd({"do": "downloadslist", "action": "click", "via": "post", "at": [700, 300]})
    t.ok("a press on the page closes it", not probe()["downloadsOpen"] and not popovers())
    show()
    sv.cmd({"do": "ui", "bookmarkCard": True})
    time.sleep(0.8)
    t.ok("another popup opening closes the list", not probe()["downloadsOpen"] and not popovers())
    sv.cmd({"do": "ui", "popup": "close"})
    time.sleep(0.4)


def case_reduce_motion():
    subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
    time.sleep(0.3)
    stage("kept")
    sv.cmd({"do": "ui", "recentdownloads": True})
    time.sleep(0.12)
    t.ok("Reduce Motion: the popover is there at once", bool(popovers()))
    hide()
    subprocess.run(["defaults", "delete", sv.SUITE, "motion.testReduced"], check=True)


def fetch(tab, path):
    sv.ev(tab, f"var a = document.createElement('a'); a.href = '{path}'; document.body.appendChild(a); a.click(), 1")


def case_live():
    stage("empty")
    tab = sv.page("page")
    sv.cmd({"do": "select", "id": tab})
    fetch(tab, "/slow.bin")
    time.sleep(1.0)
    up = show()
    first = until(lambda: [r for r in rows() if r.get("name") == "slow.bin"])
    t.ok("a real download has a row with a bar and its controls",
         bool(first) and first[0]["bar"] and "cancel" in first[0]["keys"], first)
    if not first:
        hide()
        return
    tall = up[0]["frame"][3]
    time.sleep(1.5)
    later = [r for r in rows() if r.get("name") == "slow.bin"]
    t.ok("its bar and words follow the download while the list is open",
         bool(later) and later[0]["id"] == first[0]["id"] and later[0]["fraction"] > first[0]["fraction"]
         and later[0]["detail"] != first[0]["detail"], (first[0]["fraction"], later))
    def slow():
        return next(((i, r) for i, r in enumerate(rows()) if r.get("name") == "slow.bin"), (None, None))

    index, row = slow()
    if "pause" in row["keys"]:
        sv.cmd({"do": "downloadslist", "action": "press", "row": index, "verb": "pause"})
        held = until(lambda: [r for _, r in [slow()] if r and set(r["keys"]) & {"resume", "retry"}], 8)
        t.ok("Pause stops it, and the row offers to go on", bool(held), slow()[1])
        if held:
            again = "resume" if "resume" in held[0]["keys"] else "retry"
            sv.cmd({"do": "downloadslist", "action": "press", "row": slow()[0], "verb": again})
            going = until(lambda: [r for _, r in [slow()] if r and r["bar"] and "cancel" in r["keys"] and "remove" not in r["keys"]], 8)
            t.ok(f"{again.capitalize()} sets it going again in the same list", bool(going), slow()[1])
    index, row = slow()
    sv.cmd({"do": "downloadslist", "action": "press", "row": index, "verb": "cancel"})
    gone = until(lambda: not [r for r in rows() if r.get("name") == "slow.bin"])
    t.ok("Cancel takes the row away and the list stays open", gone and probe()["downloadsOpen"], rows())
    small = until(lambda: [w for w in popovers() if w["frame"][3] < tall])
    t.ok("the popover shrinks to the rows left", bool(small), (tall, popovers()))
    fetch(tab, "/quick.zip")
    kept = until(lambda: [r for r in rows() if r.get("name") == "quick.zip" and r["keys"] == ["reveal"]], 8)
    t.ok("a finished download becomes a file row while the list is open",
         bool(kept) and kept[0]["clickable"] and not kept[0]["bar"], rows())
    saved = Path(sv.SUPPORT, "Downloads")
    t.ok("the file is in the test world's own folder", (saved / "quick.zip").exists(),
         sorted(f.name for f in saved.iterdir()) if saved.exists() else saved)
    hide()


def case_access():
    stage("many")
    show()
    audit = sv.cmd({"do": "axaudit"})
    seen = [w for w in audit["windows"] if w["type"] == "_NSPopoverWindow" and w["visible"]]
    t.ok("the audit walks the popover", len(seen) == 1, [w["type"] for w in audit["windows"]])
    gaps = [g for w in audit["windows"] for g in w.get("gaps", [])]
    t.ok("no control in the popover or the window is without a name", not gaps, gaps)
    found = sv.cmd({"do": "downloadslist"})["rows"]
    keys = [r for r in found if r.get("keys") and r.get("enabled")]
    odd = [r["name"] for r in keys if not set(r["keys"]) <= set(r["menu"])]
    t.ok("every row with working controls also offers them in its menu", bool(keys) and not odd, odd)
    hide()


def main():
    try:
        start()
        for case in (case_surface, case_rows, case_actions, case_clicks, case_keys, case_door, case_reduce_motion, case_access, case_live):
            print(case.__name__)
            case()
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

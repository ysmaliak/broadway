#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
CODES = {"d": 2, "o": 31, "w": 13, "n": 45, "l": 37, "x": 7, "p": 35, "r": 15, "t": 17, "s": 1}
TAB, RETURN, ESCAPE, DOWN = (48, "\t"), (36, "\r"), (53, "\u001b"), (125, "\uf701")
plain = sv.srv.RequestHandlerClass


class Files(plain):
    def do_GET(self):
        if self.path not in ("/slow.bin", "/quick.zip"):
            return plain.do_GET(self)
        slow = self.path == "/slow.bin"
        total = (120 if slow else 1) * 65536
        start = 0
        asked = self.headers.get("Range", "")
        if asked.startswith("bytes="):
            start = int(asked[6:].split("-")[0] or 0)
        self.send_response(206 if start else 200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{self.path[1:]}"')
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"' + self.path[1:] + '-1"')
        self.send_header("Last-Modified", "Wed, 01 Oct 2025 10:00:00 GMT")
        self.send_header("Content-Length", str(total - start))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{total - 1}/{total}")
        self.end_headers()
        sent = start
        try:
            while sent < total:
                piece = min(65536, total - sent)
                self.wfile.write(b"0" * piece)
                self.wfile.flush()
                sent += piece
                if slow:
                    time.sleep(0.15)
        except OSError:
            pass


sv.srv.RequestHandlerClass = Files
sv.use("downloads-field")
t = sv.T()


def press(key, mods=()):
    code, chars = key if isinstance(key, tuple) else (CODES[key], key)
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})
    time.sleep(0.15)


def type_in(text):
    for ch in text:
        press(ch)


def rows(*args):
    return sv.cmd({"do": "fieldrows", "args": list(args)})


def drawn():
    return rows("downloadrows")


def probe():
    return sv.cmd({"do": "probe"})


def until(check, within=6.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.2)
    return check()


def row(state, title):
    return next((r for r in state["drawnRows"] if r["title"] == title), None)


def close():
    rows("close")
    time.sleep(0.4)


def up_on_downloads():
    s = drawn()
    return s if s["place"] == "downloads" and s["showing"] else None


def on_downloads(label, tabs):
    s = until(up_on_downloads, 3) or drawn()
    t.ok(f"{label}: the field comes up on Downloads", s["place"] == "downloads" and s["showing"], (s["place"], s["showing"]))
    t.ok(f"{label}: no Downloads tab opens", not s["downloadsTab"] and s["tabs"] == tabs, (s["downloadsTab"], s["tabs"], tabs))
    t.ok(f"{label}: the field has the keys", probe()["responderIsAddress"])
    return s


def fetch(tab, path):
    sv.ev(tab, f"var a = document.createElement('a'); a.href = '{path}'; document.body.appendChild(a); a.click(), 1")
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        if sv.cmd({"do": "sitefiles"}).get("cards"):
            sv.cmd({"do": "sitefiles", "action": "allow"})
            return
        time.sleep(0.2)


def still(name, folder):
    work = Path(tempfile.mkdtemp(prefix="downloads-field-shot-"))
    try:
        source = work / "WindowShot.swift"
        source.write_text((ROOT / "Tests" / "WindowShot.swift").read_text())
        built = subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(work / "shot")], cwd=str(work), capture_output=True, text=True)
        if built.returncode != 0:
            print("  no shot tool", built.stderr[-400:])
            return None
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(0.8)
        pid = next(iter(sv.holding() & sv.running()), None)
        path = Path(folder).resolve() / f"{name}.png"
        path.unlink(missing_ok=True)
        for _ in range(4):
            said = subprocess.run([str(work / "shot"), str(pid), str(number), str(path)], cwd=str(work), capture_output=True, text=True)
            if path.exists():
                break
            print("  shot said", pid, number, said.stdout.strip(), said.stderr.strip()[-300:])
            time.sleep(0.8)
        return path if path.exists() else None
    finally:
        shutil.rmtree(work, ignore_errors=True)


def popover_rows():
    try:
        return sv.cmd({"do": "downloadslist"})["rows"]
    except RuntimeError:
        sv.cmd({"do": "ui", "recentdownloads": True})
        return None


def case_doors(tabs):
    sv.cmd({"do": "ui", "downloads": True})
    s = on_downloads("the Downloads command", tabs)
    t.ok("with nothing downloaded yet it says so and nothing is lit", s["rows"] == [] and s["picked"] == -1, (s["rows"], s["picked"]))
    close()
    s = drawn()
    t.ok("closing the field leaves Downloads", s["place"] == "", s["place"])

    rows("command", "history.downloads")
    on_downloads("History, Downloads in the menu", tabs)
    close()

    sv.cmd({"do": "ui", "downloadsbutton": True})
    time.sleep(0.4)
    sv.cmd({"do": "ui", "recentdownloads": True})
    found = until(popover_rows, 6) or []
    names = [r.get("name") for r in found]
    if "Show All Downloads" in names:
        sv.cmd({"do": "downloadslist", "action": "press", "row": names.index("Show All Downloads")})
        time.sleep(0.8)
        on_downloads("Show All Downloads in the popover", tabs)
        t.ok("the popover is closed", not probe()["downloadsOpen"])
        close()
    else:
        t.ok("the popover lists Show All Downloads", False, names)

    press("t", ["cmd"])
    time.sleep(0.3)
    rows("type", "broadway://downloads")
    press(RETURN)
    time.sleep(0.5)
    on_downloads("broadway://downloads typed in the field", tabs)
    close()

    press("t", ["cmd"])
    time.sleep(0.3)
    type_in("downl")
    press(TAB)
    on_downloads("downl and Tab", tabs)
    close()

    sv.cmd({"do": "ui", "show": "broadway://downloads"})
    time.sleep(0.5)
    on_downloads("broadway://downloads opened as a link or bookmark would be", tabs)
    close()


def going_again():
    r = row(drawn(), "slow.bin")
    return r if r and r["hints"] and r["hints"][-1] == "⌃X Cancel" else None


def paused_now():
    s = drawn()
    return s if s["returnWord"] in ("Resume", "Retry") else None


def kept_quick():
    r = row(drawn(), "quick.zip")
    return r if r and not r["bar"] else None


def case_live(tab, tabs):
    sv.cmd({"do": "select", "id": tab})
    fetch(tab, "/slow.bin")
    time.sleep(0.8)
    sv.cmd({"do": "ui", "downloads": True})
    first = until(lambda: row(drawn(), "slow.bin"), 8)
    t.ok("a running download is a row with a bar and its bytes", bool(first) and first["bar"] and " of " in first["progress"], first)
    if not first:
        return
    s = drawn()
    t.ok("its row is lit first and names Pause and Cancel", s["picked"] == 0 and first["lit"] and first["hints"] == ["⌘P Pause", "⌃X Cancel"],
         (s["picked"], first))
    t.ok("Return does nothing on a running download", s["idle"], s["idle"])
    time.sleep(1.5)
    later = row(drawn(), "slow.bin")
    t.ok("its bar and bytes move in place while the list stays put",
         bool(later) and later["fraction"] > first["fraction"] and later["progress"] != first["progress"] and drawn()["picked"] == 0, (first, later))
    t.ok("the byte count holds its width", bool(later) and later["progressWidth"] >= first["progressWidth"], (first, later))

    press("p", ["cmd"])
    held = until(paused_now, 8)
    t.ok("⌘P pauses it and Return offers to go on", bool(held), drawn()["returnWord"])
    if held:
        word = held["returnWord"]
        paused = row(held, "slow.bin")
        t.ok("the paused row says so and stays lit", bool(paused) and paused["progress"].startswith("Paused") and held["picked"] == 0, paused)
        press(RETURN)
        going = until(going_again, 8)
        t.ok(f"Return on it says {word} and sets it going again in the same list", bool(going) and drawn()["place"] == "downloads",
             row(drawn(), "slow.bin"))

    press("x", ["ctrl"])
    gone = until(lambda: not row(drawn(), "slow.bin"), 8)
    s = drawn()
    t.ok("⌃X cancels it, the row goes and the field stays on Downloads", gone and s["place"] == "downloads" and s["showing"], s["drawnRows"][:2])

    fetch(tab, "/quick.zip")
    kept = until(kept_quick, 8)
    t.ok("a finished download turns up as a file row while the field is open", bool(kept), drawn()["drawnRows"][:2])
    s = drawn()
    t.ok("the new file is first and lit", bool(s["drawnRows"]) and s["drawnRows"][0]["title"] == "quick.zip" and s["picked"] == 0, s["drawnRows"][:1])
    t.ok("a file row names its keys", bool(kept) and kept["hints"] == ["⌘R Show in Finder", "⇧⌘C Copy Path", "⌃X Remove"], kept)
    said = rows("rowmenu")
    items = said.get("items", [])
    t.ok("a file row's own menu is the downloads menu", items[:1] == ["Open"] and "Show in Finder" in items
         and "Copy File" in items and items[-1:] == ["Remove from List"], items)
    press(RETURN)
    time.sleep(0.5)
    s = rows("places")
    t.ok("Return opens the file with its app and puts the field away",
         any(f.startswith("open ") and f.endswith("/quick.zip") for f in s["files"]) and not s["showing"], (s["files"], s["showing"]))
    sv.cmd({"do": "ui", "downloads": True})
    time.sleep(0.4)
    press("x", ["ctrl"])
    s = rows("places")
    t.ok("⌃X takes the file off the list", "quick.zip" not in s["downloads"], s["downloads"])
    close()


def many_up():
    s = drawn()
    return s if len(s["drawnRows"]) >= 11 else None


def case_staged(folder):
    sv.cmd({"do": "ui", "downloadsStage": "many"})
    time.sleep(0.4)
    sv.cmd({"do": "ui", "downloads": True})
    s = until(many_up, 4) or drawn()
    titles = [r["title"] for r in s["drawnRows"]]
    t.ok("current downloads come first, then files newest first",
         titles[:2] == ["Xcode_27.1.xip", "stream-capture.mov"] and titles[3:5] == ["dataset.tar.gz", "ubuntu-26.10-desktop-arm64.iso"]
         and titles[5:6] == ["Screenshot 2026-11-13.png"] and titles[-1:] == ["Notes.txt"], titles)
    xcode = row(s, "Xcode_27.1.xip")
    t.ok("a sized download shows a bar and its bytes", bool(xcode) and xcode["bar"] and not xcode["indeterminate"]
         and xcode["progress"].startswith("1.93 GB of 4.6"), xcode)
    stream = row(s, "stream-capture.mov")
    t.ok("an unsized one turns its bar and says what came", bool(stream) and stream["indeterminate"] and stream["progress"].startswith("48") and stream["progress"].endswith(" MB downloaded"), stream)
    paused = row(s, "dataset.tar.gz")
    t.ok("a paused one says so with its bytes", bool(paused) and paused["progress"].startswith("Paused · "), paused)
    failed = row(s, "ubuntu-26.10-desktop-arm64.iso")
    t.ok("a failed one says why, with no bar", bool(failed) and not failed["bar"] and failed["progress"] == "The network connection was lost."
         and failed["aside"] == "Failed", failed)
    gone = row(s, "Gone already.pdf")
    t.ok("a file that is gone looks gone", bool(gone) and gone["dimmed"] and gone["aside"] == "Moved or deleted", gone)
    long = [r for r in s["drawnRows"] if r["title"].startswith("Quarterly planning notes")]
    t.ok("a long name keeps inside its row", bool(long) and all(r["titleWidth"] < r["width"] for r in long), long)
    said = rows("rowmenu")
    t.ok("a running row's own menu is Pause and Cancel", said.get("items") == ["Pause", "Cancel"], said.get("items"))
    rows("type", "ubuntu")
    listed = [r[0] for r in rows("state")["rows"]]
    t.ok("typing filters the current downloads too", listed == ["ubuntu-26.10-desktop-arm64.iso"], listed)
    s = drawn()
    t.ok("Return on a failed download says Retry", s["returnWord"] == "Retry" and not s["idle"], s["returnWord"])
    rows("type", "")
    if folder:
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(0.8)
            picture = still(f"downloads-field-{look}", folder)
            t.ok(f"a picture of the Downloads place in {look}", picture is not None, folder)
            if picture:
                print("  picture", picture)
        sv.cmd({"do": "ui", "look": "system"})
    close()
    sv.cmd({"do": "ui", "downloadsStage": "empty"})


def case_long():
    rows("keepmany", "300")
    sv.cmd({"do": "ui", "downloads": True})
    time.sleep(0.6)
    s = drawn()
    t.ok("every file is listed, not thirty", len(s["rows"]) >= 300, len(s["rows"]))
    t.ok("only the rows near the screen are made", 0 < s["built"] < 150, s["built"])
    rows("scrollend")
    time.sleep(0.4)
    s = drawn()
    t.ok("scrolled to the end, the oldest file is there", bool(s["drawnRows"]) and s["drawnRows"][-1]["title"] == "file-0.txt", s["drawnRows"][-1:])
    t.ok("and still only rows near the screen are made", 0 < s["built"] < 150, s["built"])
    close()


def start():
    sv.setup(sidebar=True, **{"newtab.floating": True, "start.fresh": False})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    sv.cmd({"do": "resize", "width": 1000, "height": 720, "steps": 1})
    sv.cmd({"do": "ui", "downloadsbutton": True})
    tab = sv.page("page")
    sv.cmd({"do": "idle", "action": "unhide"})
    time.sleep(1)
    return tab


def main():
    folder = None
    if "--stills" in sys.argv:
        folder = sys.argv[sys.argv.index("--stills") + 1]
        Path(folder).mkdir(parents=True, exist_ok=True)
    try:
        tab = start()
        tabs = len(sv.sp("state")["tabs"])
        if "--stills-only" not in sys.argv:
            case_doors(tabs)
            case_live(tab, tabs)
        case_staged(folder)
        if "--stills-only" not in sys.argv:
            case_long()
        t.ok("no Downloads tab was left behind", not probe()["downloadsTab"])
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

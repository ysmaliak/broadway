#!/usr/bin/env python3
"""Recent file choices through WebKit, in a unique hidden test world."""
import base64
import json
import shutil
import subprocess
import sys
import time
import uuid
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("file-choice-" + uuid.uuid4().hex[:12])
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")
HTML = b"""<!doctype html><title>File choice probe</title>
<body style="font:18px system-ui;background:#f2f4f8;padding:70px;color:#253144">
<h1>Give this page a file</h1><p>Local fixture, no network account.</p>
<p><label>Image <input id=image type=file accept="image/*"></label></p>
<p><label>Several <input id=multi type=file accept=".png,text/plain" multiple></label></p>
<p><label>Any file <input id=any type=file></label></p>
<p><label>Folder <input id=folder type=file webkitdirectory multiple></label></p>
<a id=download href=/recent.png download>Download image</a>
<a id=private href=/private.png download>Private image</a>
<script>window.changes=0;window.cancels=0;
document.addEventListener('change',()=>changes++);
document.addEventListener('cancel',()=>cancels++,true);</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        image = self.path.endswith(".png")
        body = PNG if image else HTML
        if self.path == "/frame":
            body = b'<iframe src="/inside"></iframe>'
        self.send_response(200)
        self.send_header("Content-Type", "image/png" if image else "text/html")
        if image:
            self.send_header("Content-Disposition", f'attachment; filename="{self.path[1:]}"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def box(action="state", *values, window=None):
    return sv.cmd({"do": "filebox", "action": action, "values": list(values), **({"window": window} if window else {})})


def capture_picker(path, window=None):
    state = box("shot-start", window=window)
    try:
        result = subprocess.run(["swift", str(Path(__file__).with_name("capture_file_choice.swift")),
                                 str(state["pid"]), str(state["window"]), str(state["width"]), str(state["height"]), str(path)],
                                capture_output=True, text=True, timeout=30)
        return {"saved": result.returncode == 0 and path.exists(), "detail": result.stdout + result.stderr}
    finally:
        box("shot-end", window=window)


def until(check, within=10):
    end = time.monotonic() + within
    while time.monotonic() < end:
        result = check()
        if result:
            return result
        time.sleep(0.15)
    raise AssertionError("timed out")


def cleanup_world(support):
    sv.quit()
    for path in sv.stores():
        if Path(path).exists():
            shutil.rmtree(path)
    shutil.rmtree(support, ignore_errors=True)
    subprocess.run(["defaults", "delete", sv.SUITE], capture_output=True)


def main():
    t = sv.T()
    support = Path(sv.SUPPORT)
    support.mkdir(parents=True, exist_ok=False)
    (support / "seed.png").write_bytes(PNG)
    (support / "notes.txt").write_text("Local fixture")
    subprocess.run(["defaults", "write", sv.SUITE, "bench", "-bool", "true"], check=True)
    try:
        sv.launch()
        sv.cmd({"do": "window"})
        box("enable")
        sv.cmd({"do": "ui", "look": "light"})
        tab = sv.sp("open", url=sv.BASE + "/page")["resultID"]
        sv.cmd({"do": "select", "id": tab})
        until(lambda: sv.ev(tab, "!!document.querySelector('#image')") is True)
        for name in ["seed.png", "notes.txt", "missing.png"]:
            sv.cmd({"do": "uploads", "action": "add", "values": [str(support / name), "fixture.example"]})

        def open_picker(selector, page=tab, window=None):
            sv.ev(page, f"document.querySelector('{selector}').focus();document.querySelector('{selector}').click();1")
            def ready():
                state = box(window=window)
                return state if state.get("pending") and state.get("ready") and state.get("tab", "").startswith(page.lower()) else None
            return until(ready)

        def chosen(selector, page=tab):
            return sv.ev(page, f"Array.from(document.querySelector('{selector}').files).map(f=>f.name)")

        sv.cmd({"do": "tap", "id": tab, "selector": "#download"})
        until(lambda: any(x["name"] == "recent.png" for x in sv.cmd({"do": "uploads"})["items"]))
        state = open_picker("#image")
        t.ok("real delegate reads image accept and single mode", state["accept"] == "image/*" and not state["multiple"], state)
        t.ok("picker remains available for dragging from Finder", state["keepsWhenInactive"], state)
        t.ok("newest matching downloads and uploads only", [x["name"] for x in state["items"]] == ["recent.png", "seed.png"], state)
        shots = Path(__file__).resolve().parents[1] / ".context" / "evidence"
        shots.mkdir(parents=True, exist_ok=True)
        box("key", "49")
        t.ok("Space enters Quick Look path", box()["preview"])
        box("key", "49")
        box("key", "36")
        until(lambda: chosen("#image") == ["recent.png"])
        t.ok("Return supplies the real file to WebKit", chosen("#image") == ["recent.png"] and not box()["pending"])
        t.ok("chosen download recorded as upload", any(x["name"] == "recent.png" and x["uploaded"] for x in sv.cmd({"do": "uploads"})["items"]))

        state = open_picker("#multi")
        t.ok("multiple and extension plus MIME accept reach picker", state["multiple"] and len(state["items"]) == 3, state)
        box("select", "0")
        box("select", "0", "command")
        box("pick")
        t.ok("deselecting every row does not choose a file", box()["pending"] and box()["selected"] == [])
        box("select", "0")
        box("select", "2", "command")
        t.ok("Command selection keeps separate rows", box()["selected"] == [0, 2])
        box("select", "0", "shift")
        t.ok("Shift selection includes the range", box()["selected"] == [0, 1, 2])
        box("key", "36")
        until(lambda: len(chosen("#multi")) == 3)
        t.ok("multiple completion reaches input.files", set(chosen("#multi")) == {"recent.png", "seed.png", "notes.txt"})

        state = open_picker("#any")
        t.ok("no accept offers every existing file", state["accept"] == "" and len(state["items"]) == 3, state)
        box("submit", str(support / "notes.txt"), str(support / "seed.png"))
        t.ok("single input rejects multiple files without completing", box()["pending"] and bool(box()["trouble"]))
        box("cancel")
        state = open_picker("#image")
        box("submit", str(support / "notes.txt"))
        t.ok("completion revalidates accepted types", box()["pending"] and bool(box()["trouble"]))
        box("key", "53")
        until(lambda: not box()["pending"])
        t.ok("Escape cancels the chooser", not box()["pending"])
        t.ok("cancel preserves previous image selection", chosen("#image") == ["recent.png"])

        open_picker("#any")
        t.ok("drop provider accepted", box("drop", str(support / "notes.txt"))["accepted"])
        until(lambda: chosen("#any") == ["notes.txt"])
        t.ok("dropped file reaches the WebKit completion", chosen("#any") == ["notes.txt"])

        state = open_picker("#image")
        for _ in state["items"]:
            box("key", "125")
        box("key", "36")
        t.ok("Choose in Finder hands off with completion pending", box()["finder"] and box()["pending"])
        box("submit", str(support / "seed.png"))
        until(lambda: chosen("#image") == ["seed.png"])
        t.ok("Finder completion uses the same validated reply", chosen("#image") == ["seed.png"])
        open_picker("#folder")
        t.ok("directory inputs use Finder", box()["finder"] and box()["directories"])
        box("cancel")

        open_picker("#any")
        sv.cmd({"do": "go", "id": tab, "url": sv.BASE + "/navigated"})
        until(lambda: not box()["pending"])
        t.ok("navigation cancels the outstanding completion", not box()["pending"])
        until(lambda: sv.ev(tab, "!!document.querySelector('#image')") is True)
        open_picker("#any")
        other = sv.sp("open", url=sv.BASE + "/other")["resultID"]
        sv.cmd({"do": "select", "id": other})
        until(lambda: not box()["pending"])
        t.ok("switching tabs cancels", not box()["pending"])

        framed = sv.sp("open", url=sv.BASE + "/frame")["resultID"]
        sv.cmd({"do": "select", "id": framed})
        until(lambda: sv.ev(framed, "!!document.querySelector('iframe')?.contentDocument?.querySelector('#image')") is True)
        sv.ev(framed, "document.querySelector('iframe').contentDocument.querySelector('#image').click();1")
        state = until(lambda: box() if box().get("ready") else None)
        t.ok("iframe accept is read from the initiating frame", state["accept"] == "image/*" and not state["finder"], state)
        box("key", "36")
        until(lambda: sv.ev(framed, "document.querySelector('iframe').contentDocument.querySelector('#image').files.length") == 1)
        t.ok("iframe receives its file completion", sv.ev(framed, "document.querySelector('iframe').contentDocument.querySelector('#image').files.length") == 1)
        sv.sp("close", id=framed)
        sv.cmd({"do": "select", "id": tab})

        sv.cmd({"do": "peek", "url": sv.BASE + "/peek-file"})
        until(lambda: box("peek-eval", "!!document.querySelector('#image')").get("value") is True)
        box("peek-eval", "document.querySelector('#image').click();1")
        peek_state = until(lambda: box() if box().get("ready") else None)
        t.ok("peek page keeps its file chooser", peek_state["accept"] == "image/*", peek_state)
        box("key", "36")
        until(lambda: box("peek-eval", "document.querySelector('#image').files.length").get("value") == 1)
        t.ok("peek page receives its file", box("peek-eval", "document.querySelector('#image').files.length").get("value") == 1)
        box("peek-eval", "document.querySelector('#image').click();1")
        until(lambda: box().get("ready"))
        sv.cmd({"do": "peek", "url": "close"})
        t.ok("closing peek cancels its file chooser", not box()["pending"])

        private = sv.cmd({"do": "open", "url": sv.BASE + "/private-page", "private": True})["id"]
        pn = next(w["n"] for w in sv.cmd({"do": "windows", "action": "list"})["windows"] if w["private"])
        sv.cmd({"do": "select", "id": private})
        until(lambda: sv.ev(private, "!!document.querySelector('#image')") is True)
        state = open_picker("#any", private, pn)
        t.ok("private chooser cannot see regular files", state["items"] == [], state)
        box("cancel", window=pn)
        sv.cmd({"do": "tap", "id": private, "selector": "#private", "window": pn})
        until(lambda: (support / "Downloads" / "private.png").exists())
        time.sleep(0.6)
        state = open_picker("#any", private, pn)
        t.ok("private chooser offers only this window's download", [x["name"] for x in state["items"]] == ["private.png"], state)
        box("key", "36", window=pn)
        until(lambda: chosen("#any", private) == ["private.png"])
        t.ok("private selection is absent from shared Files", not any(x["name"] == "private.png" for x in sv.cmd({"do": "uploads"})["items"]))
        created = sv.cmd({"do": "windows", "action": "private"})
        second_window = created["windows"][-1]["n"]
        other_private = sv.cmd({"do": "split", "action": "open", "url": sv.BASE + "/another-private", "window": second_window})["resultID"]
        sv.cmd({"do": "select", "id": other_private})
        until(lambda: sv.ev(other_private, "!!document.querySelector('#any')") is True)
        sv.ev(other_private, "document.querySelector('#any').click();1")
        other_state = until(lambda: box(window=second_window) if box(window=second_window).get("ready") else None)
        t.ok("another private window cannot see the first one's download", other_state["items"] == [], other_state)
        closed = sv.cmd({"do": "windows", "action": "close", "n": second_window})
        t.ok("window closes with its chooser outstanding", len(closed["windows"]) == 2, closed)
        last_state = open_picker("#any", private, pn)
        t.ok("a private window has its downloads before closing", last_state["privateDownloads"] == 1, last_state)
        closed = sv.cmd({"do": "windows", "action": "close", "n": pn})
        t.ok("closing it with its chooser up closes the window", len(closed["windows"]) == 1, closed)
        t.ok("and the first window's chooser is untouched", not box()["pending"], box())
        fresh = sv.cmd({"do": "open", "url": sv.BASE + "/last-private", "private": True})["id"]
        fn = next(w["n"] for w in sv.cmd({"do": "windows", "action": "list"})["windows"] if w["private"])
        sv.cmd({"do": "select", "id": fresh})
        until(lambda: sv.ev(fresh, "!!document.querySelector('#any')") is True)
        fresh_state = open_picker("#any", fresh, fn)
        t.ok("a new private window starts with no private recent files", fresh_state["items"] == [] and fresh_state["privateDownloads"] == 0, fresh_state)
        box("cancel", window=fn)
        sv.cmd({"do": "windows", "action": "close", "n": fn})

        sv.cmd({"do": "select", "id": tab})
        state = open_picker("#any")
        doomed = next(x["path"] for x in state["items"] if x["name"] == "seed.png")
        Path(doomed).unlink()
        box("submit", doomed)
        t.ok("file removed while open is rejected at completion", box()["pending"] and bool(box()["trouble"]))
        box("cancel")
        state = open_picker("#any")
        t.ok("missing files are hidden on next open", "seed.png" not in [x["name"] for x in state["items"]])
        sv.sp("close", id=tab)
        until(lambda: not box()["pending"])
        t.ok("closing a tab cancels", not box()["pending"])
        last = sv.sp("open", url=sv.BASE + "/page")["resultID"]
        sv.cmd({"do": "select", "id": last})
        until(lambda: sv.ev(last, "!!document.querySelector('#any')") is True)
        open_picker("#any", last)
        sv.cmd({"do": "windows", "action": "close", "n": 1})
        t.ok("closing the last window cancels its chooser", not box()["pending"], box())
        t.ok("offscreen probe stays inside the visibility guard", not box().get("onScreen"), box())
        (shots / "file-choice-results.json").write_text(json.dumps({"passed": t.passed, "failed": t.failed}, indent=2))
    finally:
        cleanup_world(support)
    t.done()
    if t.failed:
        raise SystemExit(1)


if __name__ == "__main__":
    main()

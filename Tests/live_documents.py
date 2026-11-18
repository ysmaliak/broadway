#!/usr/bin/env python3
"""The Google Drive live folder, read from invented fixtures on a local server, and pictured.

Build first (`./build.sh`), then `python3 Tests/live_documents.py`. A world of
its own opens in the background, kept below every ordinary window and never
key. `integrations.api` points the Drive reader at a server on 127.0.0.1, which
serves Drive's recent view as `/stage/drive.google.com/drive/recent`: three
invented files, then a redirect to an invented sign-in page, then a page in a
shape the reader does not know. Nothing is asked of Google: every request the
world makes to the server is checked to be a staged one, and the rows are never
opened. The folder with its three rows and a More on Google Drive row, signed
out, quiet after one failed read, and Out of date after three hours without a
good one are pictured by the window's own id, light and dark, into
.context/live-documents/.
"""
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import raised_look_shots as rl  # noqa: E402

sv.use("live-documents-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "live-documents"
TMP = OUT / "work"
rl.SHOT = TMP / "shot"
WIDTH = 245
SHOTS = "--no-shots" not in sys.argv
NAME = "Recent Files"
RECENT = "https://drive.google.com/drive/recent"
MODE = {"now": "good"}
ASKED = []
drawn = []
t = sv.T()


def escaped(text):
    return (text.replace("\\", "\\\\").replace("'", "\\x27").replace('"', "\\x22")
            .replace("/", "\\/").replace("<", "\\x3c"))


def entry(file_id, title, mime, hours):
    fields = [None] * 115
    fields[0], fields[2], fields[3] = file_id, title, mime
    fields[10] = int((time.time() - hours * 3600) * 1000)
    return fields


FILES = [
    entry("1TideTablesForTheSpitWharf_9876543-zz", "Tide tables for the spit", "application/vnd.google-apps.spreadsheet", 5),
    entry("1HarbourLightsBudgetQ3xYz0123456789ab", "Harbour lights budget", "application/vnd.google-apps.document", 2),
    entry("1FerryTimetableWinterScan00112233445", "Ferry timetable, winter", "application/pdf", 30),
]


def recent_page():
    data = json.dumps([FILES, None, "en"], separators=(",", ":"))
    return ("<!doctype html><title>Recent - Google Drive</title><script>var a = 1;window['_DRIVE_ivd'] = '"
            + escaped(data) + "';</script><div id=drive></div>")


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, body, headers=()):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        ASKED.append(self.path)
        path = self.path.split("?")[0]
        if path == "/stage/drive.google.com/drive/recent":
            if MODE["now"] == "good":
                return self.send(200, recent_page())
            if MODE["now"] == "out":
                return self.send(302, "", [("Location", "/stage/accounts.google.com/v3/signin/identifier?continue=drive")])
            return self.send(200, "<!doctype html><title>Google Drive</title><script>var other = {files: []};</script><div id=drive></div>")
        if path == "/stage/accounts.google.com/v3/signin/identifier":
            return self.send(200, "<!doctype html><form><input type=email name=identifier><button>Next</button></form>")
        return self.send(404, "<!doctype html><p>Not here</p>")


srv = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder():
    return next(f for f in live("list")["folders"] if f["name"] == NAME)


def notes():
    return [n for n in live("notes")["notes"] if n["folder"] == NAME]


def still(name):
    raw = TMP / f"{name}-raw.png"
    out = OUT / f"{name}.png"
    try:
        rl.shoot(pid, number, raw)
    except RuntimeError as e:
        print(f"  capture of {name} failed ({e}), drawn offscreen instead")
        drawn.append(name)
        sv.cmd({"do": "windowpicture", "path": str(out)})
        return out
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(raw), "--out", str(out)],
                   capture_output=True, check=True)
    return out


def crop(src, path):
    k = max(1, round(rl.scale_of(src)))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int((WIDTH + 14) * k)}:{int(330 * k)}:0:0", str(path)], check=True)


def pictures(name):
    if not SHOTS:
        return
    for look in ("light", "dark"):
        sv.cmd({"do": "ui", "look": look})
        time.sleep(1.0)
        crop(still(f"window-{name}-{look}"), OUT / f"drive-{name}-{look}.png")


def read(mode):
    MODE["now"] = mode
    live("update", NAME)
    time.sleep(0.8)
    return folder()


def main():
    global pid, number
    if SHOTS:
        shutil.rmtree(OUT, ignore_errors=True)
        TMP.mkdir(parents=True, exist_ok=True)
        copy = TMP / "WindowShot.swift"
        shutil.copy(ROOT / "Tests/WindowShot.swift", copy)
        subprocess.run(["swiftc", "-parse-as-library", str(copy), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(WIDTH)], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", f"http://127.0.0.1:{srv.server_port}"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        placed = sv.cmd({"do": "windowbehind"})
        number = placed["number"]
        t.ok("the probe's window stays behind and takes no keys", not placed["key"] and not placed["active"], placed)
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        live("add-page", NAME, "page", RECENT)
        live("unfold", NAME)

        got = read("good")
        titles = [i["title"] for i in got["items"]]
        t.ok("three files read, newest first", titles == ["Harbour lights budget", "Tide tables for the spit", "Ferry timetable, winter"], got)
        t.ok("each row says its kind and when it was edited",
             [i["byline"] for i in got["items"]] == ["Doc · Edited 2 hours ago", "Sheet · Edited 5 hours ago", "PDF · Edited 30 hours ago"],
             [i["byline"] for i in got["items"]])
        t.ok("each row opens the file's own editor or Drive page",
             [i["url"].split("/d/")[0] for i in got["items"]] == ["https://docs.google.com/document", "https://docs.google.com/spreadsheets",
                                                                  "https://drive.google.com/file"], [i["url"] for i in got["items"]])
        drawn_lines = live("bylines")["bylines"]
        t.ok("and each drawn row shows that line", drawn_lines == ["Doc · Edited 2 hours ago", "Sheet · Edited 5 hours ago", "PDF · Edited 30 hours ago"],
             drawn_lines)
        live("force", NAME, "more")
        time.sleep(0.6)
        t.ok("past the cap the folder says More on Google Drive, at the recent view", folder()["more"] == RECENT, folder()["more"])
        pictures("rows")

        got = read("out")
        t.ok("a sign-in page is signed out, not an empty list", got["state"] == "signIn" and len(got["items"]) == 3, (got["state"], len(got["items"])))
        shown = notes()
        t.ok("the note says Sign in to Google Drive", shown and shown[0]["text"] == "Sign in to Google Drive" and not shown[0]["cut"], shown)
        pictures("signed-out")

        got = read("odd")
        t.ok("a shape the reader does not know is Couldn't read and keeps the rows", got["state"] == "failed" and len(got["items"]) == 3,
             (got["state"], len(got["items"])))
        shown = notes()
        t.ok("one failed read says nothing on the row and keeps the cause in the menu",
             not shown and got["said"] == "" and got["detail"][-1] == "Couldn't read Google Drive", (shown, got["said"], got["detail"]))
        pictures("couldnt-read")
        live("aged", NAME, "180")
        got = read("odd")
        t.ok("three hours without a good read, the row says Out of date and keeps the rows",
             got["said"] == "Out of date" and len(got["items"]) == 3 and not notes(), (got["said"], len(got["items"]), got["help"]))
        pictures("out-of-date")

        staged = [p for p in ASKED if not p.startswith("/stage/drive.google.com/") and not p.startswith("/stage/accounts.google.com/")]
        t.ok("every request the world made for the folder went to the local stage", ASKED and not staged, (ASKED, staged))
        if SHOTS:
            print(OUT)
            print("real window pictures" if not drawn else f"drawn offscreen: {drawn}")
    finally:
        sv.finish()
        srv.shutdown()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

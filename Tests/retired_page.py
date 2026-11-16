#!/usr/bin/env python3
"""A Mac that had the morning brief starts clean, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/retired_page.py` from a
worktree. The world is seeded the way a Mac that used the brief is left: its
settings, its two weather files, its marks in now.json, a key given to Show
Morning Brief, a pinned brief and a session whose front tab is
broadway://brief. After launch none of it is left, the brief tab is not
restored, and no tab shows an error page.
"""
import json
import os
import plistlib
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("retired-page")
FIRST = "00000000-0000-0000-0000-000000000001"
SINCE_2001 = 978307200


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"<!doctype html><title>Kept</title><h1>Kept</h1>"
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def write(key, kind, value):
    subprocess.run(["defaults", "write", sv.SUITE, key, kind, *value], check=True)


def seed(kept):
    write("brief.on", "-bool", ["true"])
    write("brief.from", "-int", ["0"])
    write("brief.until", "-int", ["24"])
    write("brief.off", "-array", ["weather"])
    write("brief.shown", "-string", ["2026-11-14"])
    write("brief.sources", "-array", ["mail", "slack"])
    write("brief.jira.site", "-string", ["acme.atlassian.net"])
    write("brief.slack.workspace", "-string", ["acme.slack.com"])
    write("weather.api", "-string", ["http://127.0.0.1:1"])
    write("meetings.alerts", "-bool", ["true"])
    shortcuts = json.dumps({"view.brief": {}, "file.reopen": {}}).encode().hex()
    write("shortcuts", "-data", [shortcuts])
    support = Path(sv.SUPPORT)
    support.mkdir(parents=True, exist_ok=True)
    later = time.time() + 3600 - SINCE_2001
    (support / "now.json").write_text(json.dumps({"brief.done:mail:1@a": later, "brief.snooze:slack:2": later, "now:kept": later}))
    for name in ("brief-weather.json", "brief-place.json"):
        (support / name).write_text("{}")
    brief = {"url": "broadway://brief", "title": "Morning Brief"}
    pin = {"id": "6B000000-0000-0000-0000-0000000000B1", "letter": "B", "home": "broadway://brief", "title": "Morning Brief"}
    (support / "pins.json").write_text(json.dumps({FIRST: [pin], "shared": []}))
    tabs = [brief, {"url": kept, "title": "Kept"},
            dict(brief, pin="B", home="broadway://brief", pinID=pin["id"])]
    (support / "session.json").write_text(json.dumps({"tabs": tabs, "active": 0}))


def settings():
    out = subprocess.run(["defaults", "export", sv.SUITE, "-"], capture_output=True, text=True).stdout
    return plistlib.loads(out.encode()) if out.strip() else {}


def main():
    t = sv.T()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    kept = f"http://127.0.0.1:{server.server_port}/kept"
    try:
        sv.setup(**{"start.fresh": False, "welcome.show": False})
        seed(kept)
        sv.launch()
        time.sleep(2)
        state = sv.sp("state")
        tabs = state["tabs"]
        urls = [x["url"] for x in tabs]
        t.ok("the session came back with the kept tab", kept in urls, urls)
        t.ok("no tab is the old page", not [x for x in tabs if "brief" in x["url"] or "brief" in x["internal"]], tabs)
        t.ok("no tab is one of our pages at an address we no longer have",
             not [x for x in tabs if x["url"].startswith("broadway:")], urls)
        front = next((x for x in tabs if x["id"] == state["activeID"]), {})
        t.ok("the front tab is the kept page, not an error", front.get("url") == kept and front.get("title") == "Kept", front)
        support = Path(sv.SUPPORT)
        t.ok("the weather files are gone", not (support / "brief-weather.json").exists() and not (support / "brief-place.json").exists(),
             sorted(os.listdir(support)))
        marks = json.loads((support / "now.json").read_text())
        t.ok("now.json keeps only what the Now rows wrote", list(marks) == ["now:kept"], marks)
        pins = json.loads((support / "pins.json").read_text())
        t.ok("no pin is the old page", "brief" not in json.dumps(pins), pins)
        sv.cmd({"do": "quit"})
        time.sleep(1.5)
        stored = settings()
        left = sorted(k for k in stored if k.startswith("brief.") or k == "weather.api")
        t.ok("no setting of the brief is left", not left, left)
        t.ok("other settings stay", stored.get("meetings.alerts") is True, stored.get("meetings.alerts"))
        keys = json.loads(bytes(stored.get("shortcuts", b"{}")) or b"{}")
        t.ok("the key given to Show Morning Brief is forgotten", list(keys) == ["file.reopen"], keys)
        session = json.loads((support / "session.json").read_text())
        t.ok("the saved session holds no brief tab", "brief" not in json.dumps(session), session["tabs"])
    finally:
        server.shutdown()
        sv.finish()
    t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

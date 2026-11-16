#!/usr/bin/env python3
"""The Files page, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/files_page.py`. A test run
never shows a file chooser, so what a chooser records is told to it with
`uploads add`; a real download comes from a local server.
"""
import os
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-files")
t = sv.T()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"report"
        self.send_response(200)
        if self.path.endswith(".zip"):
            self.send_header("Content-Type", "application/zip")
            self.send_header("Content-Disposition", 'attachment; filename="report-for-files.zip"')
        else:
            body = b'<!doctype html><title>files</title><a id=d href="/report.zip">get</a>'
            self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def files(action="state", *values):
    return sv.cmd({"do": "uploads", "action": action, "values": list(values)})


def names(state):
    return [x["name"] for x in state["items"]]


def until(check, within=6):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def main():
    sv.setup()
    sv.launch()
    try:
        tab = sv.page("page")
        sv.cmd({"do": "select", "id": tab})
        t.ok("empty to begin with", files()["items"] == [], files())
        files("add", "/tmp/holiday-photo.png", "shop.example")
        t.ok("a file given to a site is listed", names(files()) == ["holiday-photo.png"], files())
        t.ok("with the site", files()["items"][0]["source"] == "shop.example", files())

        sv.ev(tab, "document.getElementById('d').click(), 1")
        t.ok("a download is listed", until(lambda: any("report-for-files" in n for n in names(files()))), files())
        fetched = next(x for x in files()["items"] if "report-for-files" in x["name"])
        t.ok("from the site it came from", fetched["source"] == "127.0.0.1", fetched)
        t.ok("newest first", names(files())[0].startswith("report-for-files"), names(files()))

        t.ok("found by name", names(files("find", "HOLIDAY")) == ["holiday-photo.png"], files("find", "HOLIDAY"))
        t.ok("found by source", names(files("find", "shop")) == ["holiday-photo.png"], files("find", "shop"))
        t.ok("nothing for a stranger", names(files("find", "nothing-like-this")) == [], files("find", "nothing-like-this"))

        files("open")
        time.sleep(0.5)
        kinds = [x["internal"] for x in sv.sp("state")["tabs"]]
        t.ok("the page opens in a tab", "broadway://files" in kinds, kinds)
        sv.quit()
        sv.launch()
        t.ok("uploads come back after a relaunch", "holiday-photo.png" in names(files()), files())
        fetched = next((x for x in files()["items"] if "report-for-files" in x["name"]), None)
        if fetched and fetched["path"]:
            try:
                os.remove(fetched["path"])
            except OSError:
                pass
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()

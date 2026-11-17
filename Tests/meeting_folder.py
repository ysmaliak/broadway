#!/usr/bin/env python3
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("meeting-folder")
t = sv.T()

CALL = """<!doctype html><meta charset=utf-8><title>Weekly design call</title>
<a id=go target=_blank href=/notes-page style="display:block;font-size:60px;line-height:200px">the shared notes</a>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        html = CALL if name.count("-") == 2 else f"<!doctype html><title>{name}</title><p>{name}"
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def alert(action="state", **values):
    return sv.cmd({"do": "meetalert", "action": action, **values})


def folders():
    return sv.cmd({"do": "meetfolder"})


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def folder(name):
    return next((g for g in sv.cmd({"do": "group"})["groups"] if g["name"] == name), None)


def main():
    sv.setup(**{"groups.meetings": True})
    sv.launch()
    try:
        link = f"{sv.BASE}/des-ignc-all"
        sv.page("?before")
        alert("fixture", lead="1", hosts={"127.0.0.1": "meet"},
              events=[{"title": "Design review", "in": 0.5, "link": link}])
        alert("press", index=0, button="join")
        call = None
        for _ in range(40):
            call = next((x["id"] for x in tabs() if x.get("url") == link), None)
            if call:
                break
            time.sleep(0.25)
        t.ok("the reminder's Join opens the call", call is not None, [x.get("url") for x in tabs()])
        if not call:
            return
        until(lambda: sv.ev(call, "document.title") == "Weekly design call")
        t.ok("no folder for a call with no other tab", folder("Design review") is None, sv.cmd({"do": "group"})["groups"])

        before = {x["id"] for x in tabs()}
        sv.cmd({"do": "select", "id": call})
        time.sleep(0.5)
        sv.cmd({"do": "tap", "id": call, "selector": "#go"})
        t.ok("a link from the call opens a tab", until(lambda: len({x["id"] for x in tabs()} - before) == 1),
             [x.get("url") for x in tabs()])
        notes = next(iter({x["id"] for x in tabs()} - before), None)
        t.ok("a folder named after the meeting", until(lambda: folder("Design review") is not None),
             sv.cmd({"do": "group"})["groups"])
        made = folder("Design review") or {}
        t.ok("it holds the call and the page opened from it", sorted(made.get("tabs", [])) == sorted([call, notes]), made)
        state = folders()
        t.ok("Broadway says so once, with Undo", state["announced"] == "Made a folder for this meeting" and state["undo"], state)

        sv.cmd({"do": "select", "id": call})
        time.sleep(0.5)
        hand = sv.page("byhand")
        time.sleep(1)
        t.ok("a tab opened by hand during the call stays outside",
             hand not in (folder("Design review") or {}).get("tabs", []), folder("Design review"))
        sv.sp("close", id=call)
        time.sleep(0.5)
        kept = folder("Design review") or {}
        t.ok("the call's tab closed, the folder and its page stay", kept.get("tabs") == [notes], kept)

        time.sleep(2)
        sv.quit()
        sv.launch()
        back = folder("Design review")
        t.ok("after a restart the folder is back with its page", back is not None and len(back["tabs"]) == 1,
             sv.cmd({"do": "group"})["groups"])
        alert("fixture", lead="1", hosts={"127.0.0.1": "meet"},
              events=[{"title": "Design review", "in": 0.5, "link": link}])
        alert("press", index=0, button="join")
        again = None
        for _ in range(40):
            again = next((x["id"] for x in tabs() if x.get("url") == link), None)
            if again:
                break
            time.sleep(0.25)
        t.ok("joining the same meeting again puts the call in its folder",
             until(lambda: again in (folder("Design review") or {}).get("tabs", [])), folder("Design review"))
        t.ok("still one folder for the meeting", len(folders()["folders"]) == 1, folders())
    finally:
        alert("off")
        sv.quit()
        sv.finish()
    t.done()


if __name__ == "__main__":
    main()
    sys.exit(1 if t.failed else 0)

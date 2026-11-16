#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/IntegrationFixtures"
SESSION = "fixture-session"
USER = {"id": "u-acme", "organization": {"id": "o-acme", "urlKey": "acme"}}
NO_USER = {"errors": [{"message": "Authentication required, no user context",
                       "extensions": {"type": "authentication error", "code": "AUTHENTICATION_ERROR"}}]}
PULLS = [(512, "Retry uploads on 502", "dana"), (36, "Audio recording: the model", "octo-sam"), (41, "Cache the build graph", "octo-sam"),
         (47, "Trim the launch path", "octo-sam"), (44, "Bump Swift to 6.2", "lee")]
SHOTS = next((Path(a) for a in sys.argv[1:] if not a.startswith("--")), None) if __name__ == "__main__" else None
LASTS = 6.0
LOOK = 2.0
state = {"pulls": True}


def pulls():
    rows = "".join(f'<li class="js-issue-row"><a href="/acme/rocket/pull/{number}">{title}</a>'
                   f'<span>#{number} opened today by <a data-testid="author-filter-link" href="/{author}">{author}</a></span></li>'
                   for number, title, author in (PULLS if state["pulls"] else []))
    return ('<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title>'
            + (f"<ul>{rows}</ul>" if rows else "<main><h3>No results matched your search.</h3></main>")).encode()


class Api(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def answer(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0"))).decode()
        if self.path != "/linear-session/graphql" or f"session={SESSION}" not in self.headers.get("cookie", ""):
            return self.answer(NO_USER, 401)
        if "availableUsers" in body:
            return self.answer({"data": {"availableUsers": {"users": [USER]}}})
        if "assignedIssues" in body:
            return self.answer(json.loads((FIXTURES / "linear-assigned.json").read_text()))
        self.answer(NO_USER, 401)

    def do_GET(self):
        if not self.path.startswith("/github/page/pulls"):
            return self.answer({}, 404)
        body = pulls()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = (f"<!doctype html><title>{name}</title><body style='font:15px -apple-system;padding:40px'>"
                f"<h2>{name}</h2><p>A page of the fake site.").encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def offer(*args, window=None):
    ask = {"do": "live", "args": ["offer", *args]}
    if window:
        ask["window"] = window
    return sv.cmd(ask)


def until(test, within=8.0, every=0.15, **kw):
    end = time.time() + within
    now = offer(**kw)
    while not test(now) and time.time() < end:
        time.sleep(every)
        now = offer(**kw)
    return now


def shown(now):
    return now.get("shown") or {}


def visit(base, *paths, pause=0.9):
    for path in paths:
        sv.cmd({"do": "ui", "go": f"{base}/{path}"})
        time.sleep(pause)


def prepare(lasts=LASTS):
    offer("pace", str(lasts), "0.3", str(LOOK), "3")
    offer("front", "on")
    offer("sight", "on")


def blocks():
    return sv.cmd({"do": "rowframes"})["blocks"]


def run(api, hub, line):
    t = sv.T()
    GH = f"http://127.0.0.1:{hub.server_port}"
    LN = f"http://127.0.0.1:{line.server_port}"
    sv.setup(spaces=True, **{"live.on": True, "live.suggest": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", f"http://127.0.0.1:{api.server_port}"], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "live.suggest.hosts", "-string",
                    f"{hub.server_port}=github.com,{line.server_port}=linear.app"], check=True)
    quiet = [part for port in (hub.server_port, line.server_port, sv.srv.server_port) for part in (f"127.0.0.1:{port}", "-bool", "false")]
    subprocess.run(["defaults", "write", sv.SUITE, "dev.servers", "-dict", *quiet], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 1100, "height": 760, "steps": 1})
        prepare()

        print("the right visit, and the wrong ones")
        plain = sv.sp("open", url=f"{sv.BASE}/plain")["resultID"]
        time.sleep(1.2)
        now = offer()
        t.ok("a site with no live folder offers nothing", not shown(now) and now["reason"] == "site", now)
        hubTab = sv.sp("open", url=f"{GH}/acme/rocket")["resultID"]
        time.sleep(1.5)
        now = offer()
        t.ok("a first visit is too early", not shown(now) and now["visits"] == 1 and now["reason"] == "", now)
        visit(GH, "acme/rocket/pulls")
        now = offer()
        t.ok("a second visit is too early", not shown(now) and now["visits"] == 2, now)
        visit(GH, "acme/rocket/issues")
        now = until(lambda s: shown(s).get("running") and s.get("view"))
        ghost = shown(now)
        view = now.get("view") or {}
        t.ok("the third visit brings the ghost", ghost.get("id") == "github", now)
        t.ok("it carries the folder's name and what adding gives",
             ghost.get("name") == "PRs" and ghost.get("gives") == "Your open pull requests on GitHub, kept up to date", ghost)
        t.ok("it knows the folder would have things in it", ghost.get("items") == 5, ghost)
        t.ok("its two controls say Add and No Thanks", view.get("add") == "Add" and view.get("decline") == "No Thanks", view)
        t.ok("VoiceOver reads the ghost, its caption and each control by the folder's name",
             view.get("label") == "Suggested folder: PRs" and "pull requests" in view.get("help", "")
             and view.get("addLabel") == "Add Folder: PRs" and view.get("declineLabel") == "No Thanks: PRs", view)
        t.ok("it is announced once", now["spoken"] == ["Suggested folder in the sidebar: PRs. Your open pull requests on GitHub, kept up to date."],
             now["spoken"])
        t.ok("the clock is running", ghost.get("running") and 0 < ghost.get("left", 0) <= LASTS, ghost)
        placed = blocks()
        kinds = [b["kind"] for b in placed]
        t.ok("the ghost stands where a pinned folder goes: above the divider and the tab rows",
             "ghost" in kinds and "divider" in kinds and kinds.index("ghost") < kinds.index("divider"), kinds)
        frame = view.get("frame") or [0, 0, 0, 0]
        add, decline = view.get("addFrame") or [0] * 4, view.get("declineFrame") or [0] * 4
        inside = all(frame[0] <= b[0] and b[0] + b[2] <= frame[0] + frame[2] and frame[1] <= b[1] and b[1] + b[3] <= frame[1] + frame[3]
                     for b in (add, decline))
        t.ok("both controls sit inside the dashed frame, Add before No Thanks", inside and add[0] + add[2] <= decline[0], [frame, add, decline])
        t.ok("it is one row high, the height of a folded folder's heading", frame[3] == 34, frame)
        t.ok("the name is whole and No Thanks is in words while there is room", not view.get("folded") and view.get("nameWidth", 0) > 0, view)
        time.sleep(0.9)
        later = offer()
        t.ok("No Thanks carries the clock: its fill has grown with the time gone",
             later["view"]["time"] < view.get("time", 0) - 0.08 and abs(later["view"]["time"] - shown(later).get("share", 0)) < 0.08,
             [view.get("time"), later["view"]["time"], shown(later).get("share")])
        rows = sv.cmd({"do": "folders"})
        t.ok("no folder is made by showing it", not live()["folders"] and "PRs" not in json.dumps(rows), rows)
        t.ok("the page's tabs are untouched", len(sv.sp("state")["tabs"]) >= 2)

        print("holds")
        offer("hover", "on")
        held = offer()
        time.sleep(1.2)
        still = offer()
        t.ok("the pointer over the ghost holds the clock",
             "held" in shown(held).get("holds", []) and not shown(still).get("running") and abs(shown(still)["left"] - shown(held)["left"]) < 0.05,
             [shown(held), shown(still)])
        t.ok("and the fill on No Thanks stands still while it is held", abs(still["view"]["time"] - held["view"]["time"]) < 0.01,
             [held["view"]["time"], still["view"]["time"]])
        offer("hover", "off")
        t.ok("and it runs again when the pointer leaves", shown(until(lambda s: shown(s).get("running"), within=2)).get("running"))
        time.sleep(0.7)
        moved = offer()
        t.ok("and the fill moves on", moved["view"]["time"] < still["view"]["time"] - 0.05, [still["view"]["time"], moved["view"]["time"]])
        t.ok("the controls take the keyboard only when the Mac's keyboard navigation is on", offer("keys", "off")["view"]["focusable"] == [False, False])
        offer("keys", "on")
        offer("focus", "add")
        focused = offer()
        t.ok("with it on, both take the keyboard, and one that has it holds the clock",
             "held" in shown(focused).get("holds", []) and focused["view"]["focusable"] == [True, True], focused)
        offer("focus", "none")
        offer("keys", "real")
        sv.cmd({"do": "ui", "folded": True})
        folded = until(lambda s: "hidden" in shown(s).get("holds", []), within=3)
        t.ok("a folded sidebar holds it", "hidden" in shown(folded).get("holds", []) and not shown(folded).get("running"), shown(folded))
        sv.cmd({"do": "ui", "folded": False})
        back = until(lambda s: shown(s).get("running"), within=3)
        t.ok("and unfolding lets it run", shown(back).get("running"), shown(back))
        away = shown(offer("front", "off"))
        t.ok("Broadway not in front holds it", away.get("holds") == ["away"] and not away.get("running"), away)
        offer("front", "on")
        unseen = shown(offer("sight", "off"))
        t.ok("a window he can't see holds it", unseen.get("holds") == ["unseen"] and not unseen.get("running"), unseen)
        offer("sight", "on")

        print("leaving and coming back")
        before = shown(offer())
        sv.cmd({"do": "select", "id": plain})
        gone = until(lambda s: not shown(s) and s["ghosts"] == 0, within=3)
        entry = next((p for p in gone["past"] if p["id"] == "github"), {})
        t.ok("another tab in front: the ghost leaves with him", not shown(gone) and gone["ghosts"] == 0, gone)
        t.ok("and it is not spent: what he saw is kept, nothing is turned down",
             entry and not entry["turnedDown"] and 0 < entry["seen"] < LASTS, entry)
        sv.cmd({"do": "select", "id": hubTab})
        again = until(lambda s: shown(s) and s.get("view"))
        due = max(LASTS - entry["seen"], LOOK)
        t.ok("back on the site it returns with the time it had left, never less than a last look",
             shown(again).get("id") == "github" and due - 1.0 < shown(again)["left"] <= due + 0.05 and shown(again)["left"] <= before["left"] + LOOK,
             [shown(again), entry, due])
        t.ok("and is not announced a second time", len(again["spoken"]) == 1, again["spoken"])

        print("a second source while one ghost is up")
        offer("pace", str(LASTS + 4), "0.3", str(LOOK), "3")
        lineTab = sv.sp("open", url=f"{LN}/acme/team/ENG/active")["resultID"]
        time.sleep(1)
        visit(LN, "acme/issue/ENG-231/rate-limit-the-export-endpoint", "acme/inbox")
        time.sleep(1.5)
        now = offer()
        tried = next((p for p in now["past"] if p["id"] == "linear"), {})
        t.ok("a site the space is not signed in to offers nothing", not shown(now) and now["visits"] >= 3 and tried.get("tried"), now)
        live("linear-cookie", SESSION)
        visit(LN, "login", "acme/team/ENG/active")
        now = until(lambda s: shown(s) and s.get("view"))
        t.ok("signed in, the same site offers its folder", shown(now).get("id") == "linear" and shown(now).get("name") == "My Issues", now)
        t.ok("only ever one ghost", now["ghosts"] == 1 and [b["kind"] for b in blocks()].count("ghost") == 1, now["ghosts"])
        offer("hover", "on")
        sv.cmd({"do": "ui", "sideWidth": 200})
        time.sleep(0.8)
        tight = offer()
        box, no = tight["view"]["frame"], tight["view"]["declineFrame"]
        t.ok("a name with no room for the words folds No Thanks to a cross, still inside the outline",
             tight["view"]["folded"] and no[2] == 22 and box[0] <= no[0] and no[0] + no[2] <= box[0] + box[2] and box[3] == 34, tight["view"])
        t.ok("the cross is drawn at its size and the name keeps some room", tight["view"]["crossWidth"] >= 8 and tight["view"]["nameWidth"] >= 40,
             tight["view"])
        if SHOTS:
            for theme in ("light", "dark"):
                sv.cmd({"do": "ui", "look": theme})
                offer("hover", "on")
                time.sleep(0.6)
                with tempfile.TemporaryDirectory() as folder:
                    sv.cmd({"do": "picture", "path": f"{folder}/cross.png"})
                    SHOTS.mkdir(parents=True, exist_ok=True)
                    shutil.move(f"{folder}/cross.png", SHOTS / f"folded-cross-{theme}.png")
        offer("hover", "off")
        time.sleep(0.6)
        after = offer()
        t.ok("and the cross carries the clock", after["view"]["folded"] and after["view"]["time"] < tight["view"]["time"] - 0.05,
             [tight["view"]["time"], after["view"]["time"]])
        offer("hover", "on")
        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(0.7)
        offer("hover", "off")
        fills = []
        for _ in range(5):
            time.sleep(0.4)
            fills.append(round(1 - offer()["view"]["time"], 3))
        subprocess.run(["defaults", "delete", sv.SUITE, "motion.testReduced"], check=True)
        t.ok("with Reduce Motion the fill moves in eighths", all(abs(f * 8 - round(f * 8)) < 0.02 for f in fills) and len(set(fills)) >= 2, fills)
        offer("hover", "on")
        sv.cmd({"do": "ui", "sideWidth": 258})
        time.sleep(0.6)
        offer("hover", "off")
        offer("pace", str(LASTS), "0.3", str(LOOK), "3")
        sv.cmd({"do": "select", "id": hubTab})
        now = until(lambda s: shown(s).get("id") == "github" and s.get("view"))
        t.ok("each ghost belongs to the site in front", shown(now).get("id") == "github" and now["ghosts"] == 1, now)
        sv.cmd({"do": "split", "action": "close", "id": lineTab})

        print("the timer")
        sv.cmd({"do": "select", "id": hubTab})
        until(lambda s: shown(s).get("id") == "github")
        timed = until(lambda s: not shown(s), within=LASTS + 6, every=0.25)
        entry = next((p for p in timed["past"] if p["id"] == "github"), {})
        t.ok("left alone, the ghost turns itself down", not shown(timed) and entry.get("turnedDown") and entry.get("byTimer"), timed)
        visit(GH, "acme/rocket/actions", "acme/rocket")
        time.sleep(1)
        now = offer()
        t.ok("and the next visit shows nothing", not shown(now) and now["reason"] == "turned down" and not now["waiting"], now)

        print("Settings")
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.2)
        sv.cmd({"do": "ui", "settingsPage": "livefolders"})
        time.sleep(1.2)
        if SHOTS:
            for theme in ("dark", "light"):
                sv.cmd({"do": "ui", "look": theme})
                time.sleep(0.8)
                with tempfile.TemporaryDirectory() as folder:
                    sv.cmd({"do": "picture", "path": f"{folder}/settings.png"})
                    SHOTS.mkdir(parents=True, exist_ok=True)
                    shutil.move(f"{folder}/settings.png", SHOTS / f"settings-live-folders-{theme}.png")
            sv.cmd({"do": "ui", "look": "dark"})
        sv.cmd({"do": "ui", "settingsPress": "settings.live.add.github"})
        time.sleep(1)
        t.ok("turned down, Settings still adds the folder", [f["name"] for f in live()["folders"]] == ["PRs"], live()["folders"])
        live("remove", "PRs")
        time.sleep(0.8)
        t.ok("and taking that folder away brings no suggestion back", not shown(offer()) and next(p for p in offer()["past"] if p["id"] == "github")["turnedDown"],
             offer())
        sv.cmd({"do": "ui", "settingsPress": "settings.live.offers.again"})
        time.sleep(0.5)
        sv.cmd({"do": "ui", "settings": False})
        sv.cmd({"do": "select", "id": hubTab})
        now = until(lambda s: shown(s) and s.get("view"))
        t.ok("Suggest Again in Settings brings it back", shown(now).get("id") == "github" and not any(p["turnedDown"] for p in now["past"]), now)
        sv.cmd({"do": "settings", "find": "", "set": "live.offers", "value": False})
        off = until(lambda s: not shown(s), within=3)
        t.ok("the switch off takes the ghost away", not shown(off) and off["reason"] == "suggestions off" and not off["on"], off)
        entry = next((p for p in off["past"] if p["id"] == "github"), {})
        t.ok("without turning it down", not entry.get("turnedDown"), entry)
        visit(GH, "acme/rocket/wiki")
        time.sleep(1)
        t.ok("and nothing is offered while it is off", not shown(offer()))
        sv.cmd({"do": "settings", "find": "", "set": "live.offers", "value": True})
        now = until(lambda s: shown(s) and s.get("view"))
        t.ok("on again, it is offered again", shown(now).get("id") == "github", now)

        print("No Thanks")
        offer("keys", "on")
        offer("focus", "decline")
        offer("key", "space")
        offer("keys", "real")
        now = until(lambda s: not shown(s), within=3)
        entry = next((p for p in now["past"] if p["id"] == "github"), {})
        t.ok("No Thanks, pressed with the space bar, takes it away for good", not shown(now) and entry.get("turnedDown") and not entry.get("byTimer"), now)
        visit(GH, "acme/rocket/pulls")
        time.sleep(1)
        t.ok("the next visit shows nothing", not shown(offer()) and offer()["reason"] == "turned down")
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        sv.cmd({"do": "space", "action": "go", "index": 2})
        time.sleep(1.5)
        sv.sp("open", url=f"{GH}/acme/rocket")
        time.sleep(1.5)
        now = offer()
        t.ok("visits made in another space do not count here", not shown(now) and now["visits"] == 1 and now["reason"] == "", now)
        visit(GH, "acme/rocket/pulls", "acme/rocket/issues")
        now = until(lambda s: shown(s) and s.get("view"), within=6)
        t.ok("another space is asked for itself, after its own three visits",
             shown(now).get("id") == "github" and shown(now).get("space") == "Work" and now["visits"] == 3, now)
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1.5)
        now = offer()
        t.ok("and the ghost stays in its own space", not shown(now) and now["ghosts"] == 0, now)
        sv.quit()
        time.sleep(1)
        sv.launch()
        prepare()
        visit(GH, "acme/rocket/pulls")
        time.sleep(1.2)
        now = offer()
        t.ok("turned down is remembered after a relaunch", not shown(now) and now["reason"] == "turned down", now)

        print("a private window")
        quiet = sv.sp("private")["window"]
        sv.cmd({"do": "split", "action": "open", "url": f"{GH}/acme/rocket", "window": quiet})
        time.sleep(1.5)
        now = offer(window=quiet)
        t.ok("a private window is never offered a folder", not shown(now) and now["reason"] == "private" and now["ghosts"] == 0, now)
        sv.cmd({"do": "windows", "action": "close", "n": quiet})

        print("not a row, and its space's own")
        offer("pace", "90", "0.3", str(LOOK), "3")
        offer("again")
        now = until(lambda s: shown(s) and s.get("view"))
        t.ok("asked again from the bench, the ghost is back", shown(now).get("id") == "github", now)
        tabs = [x["id"] for x in sv.sp("state")["tabs"]]
        spot = now["view"]["frame"]
        rows = sv.cmd({"do": "rowframes"})["rows"]
        carried = next(id for id in rows if id != sv.cmd({"do": "rowframes"})["active"])
        start = [rows[carried][0] + 60, rows[carried][1] + rows[carried][3] / 2]
        end = [spot[0] + spot[2] / 2, spot[1] + spot[3] / 2]
        points = [[start[0] + (end[0] - start[0]) * k / 6, start[1] + (end[1] - start[1]) * k / 6] for k in range(7)] + [end]
        sv.cmd({"do": "film", "action": "pindrag", "id": carried, "points": points, "frames": 12, "every": 0.04,
                "path": os.path.join(sv.SUPPORT, "drag")})
        time.sleep(1.2)
        now = offer()
        after = [x["id"] for x in sv.sp("state")["tabs"]]
        t.ok("a tab let go over the ghost goes into nothing: no folder, no pin, the ghost untouched",
             shown(now).get("id") == "github" and now["ghosts"] == 1 and not live()["folders"] and not sv.cmd({"do": "group"})["groups"]
             and sorted(after) == sorted(tabs) and not sv.cmd({"do": "windows"})["windows"][0]["pins"],
             [now.get("shown"), sv.cmd({"do": "group"})["groups"], after])
        sv.cmd({"do": "space", "action": "hold", "dx": -40})
        time.sleep(0.4)
        moving = offer("press", "add")
        t.ok("mid-swipe its controls do nothing", moving["moving"] and shown(moving).get("id") == "github" and not live()["folders"], moving)
        sv.cmd({"do": "space", "action": "release"})
        time.sleep(1.2)
        now = offer()
        t.ok("and it is still there when the spaces rest where they were", shown(now).get("id") == "github" and shown(now).get("space") == "Personal", now)
        sv.cmd({"do": "settings", "find": "", "set": "spaces.stacked", "value": "stacked"})
        time.sleep(1.5)
        now = offer()
        t.ok("stacked spaces draw it once, in its own space", shown(now).get("id") == "github" and len(now["drawn"]) == 1 and "hidden" not in shown(now)["holds"], now)
        sv.cmd({"do": "stacked", "action": "fold", "space": 1, "on": True})
        time.sleep(1.2)
        now = offer()
        t.ok("a stacked space folded to its front tab shows no ghost, and the clock waits", not now["drawn"] and "hidden" in shown(now).get("holds", []), now)
        sv.cmd({"do": "stacked", "action": "fold", "space": 1, "on": False})
        time.sleep(1.2)
        now = offer()
        t.ok("unfolded, it is back and running", len(now["drawn"]) == 1 and shown(now).get("running"), now)
        sv.cmd({"do": "settings", "find": "", "set": "spaces.stacked", "value": "side"})
        time.sleep(1.5)

        print("Add Folder")
        now = until(lambda s: shown(s) and s.get("view"))
        t.ok("back side by side, the ghost is where it was", shown(now).get("id") == "github", now)
        before = len(sv.sp("state")["tabs"])
        slot = next(b for b in blocks() if b["kind"] == "ghost")
        offer("press", "add")
        time.sleep(1.2)
        now = offer()
        folders = [f for f in live()["folders"] if f["name"] == "PRs"]
        t.ok("Add Folder makes the live folder", len(folders) == 1 and folders[0]["kind"] == "pullRequests", live()["folders"])
        t.ok("filled at once with what was read", folders and len(folders[0]["items"]) == 5 and len(folders[0]["tabs"]) == 5, folders)
        t.ok("the ghost is gone and nothing is turned down", not shown(now) and now["ghosts"] == 0 and now["reason"] == "covered"
             and not any(p["turnedDown"] for p in now["past"]), now)
        placed = blocks()
        made = next((b for b in placed if b["kind"] == "folder"), {})
        t.ok("the folder stands in the ghost's place", made and abs(made["x"] - slot["x"]) < 0.6 and abs(made["y"] - slot["y"]) < 0.6
             and abs(made["w"] - slot["w"]) < 0.6, [slot, made])
        groups = sv.cmd({"do": "group"})["groups"]
        t.ok("and lands open", [g["collapsed"] for g in groups if g["name"] == "PRs"] == [False], groups)
        t.ok("⌘Z is offered by name", now["canUndo"] and "Add Live Folder" in now["undoName"], [now["canUndo"], now["undoName"]])
        undone = offer("undo")
        time.sleep(1)
        t.ok("⌘Z takes the folder away again", not [f for f in live()["folders"] if f["name"] == "PRs"], live()["folders"])
        t.ok("with its folder in the sidebar and its tabs", not [g for g in sv.cmd({"do": "group"})["groups"] if g["name"] == "PRs"]
             and len(sv.sp("state")["tabs"]) == before, [sv.cmd({"do": "group"})["groups"], len(sv.sp("state")["tabs"]), before])
        t.ok("and, as for every step Broadway undoes, there is no redo", not undone["canRedo"], undone["canRedo"])
        now = until(lambda s: shown(s) and s.get("view"))
        t.ok("and the suggestion is his to answer again", shown(now).get("id") == "github", now)
        offer("press", "add")
        time.sleep(1.2)
        visit(GH, "acme/rocket/pulls")
        time.sleep(1)
        now = offer()
        t.ok("with the folder there, the site offers nothing more", not shown(now) and now["reason"] == "covered", now)
    finally:
        sv.finish()
        t.done()
    return t.failed


if __name__ == "__main__":
    sv.use("live-offers")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sys.exit(1 if run(serve(Api), serve(Pages), serve(Pages)) else 0)

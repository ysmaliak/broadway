#!/usr/bin/env python3
"""A live folder's row in each state, with what its menu and help tag say, and the Settings row for how often folders update.

Build first (`./build.sh`), then `python3 Tests/live_quiet_shots.py [OUT]`.

A hidden test copy in a world of its own reads three folders from a fake on
::1: PRs (three rows, folded), Reviews (two rows, open) and Empty (no rows,
open). Each is taken through fresh, one failed read, three hours of failed
reads, a three-hour-old list whose next read fails once, three hours limited
by its site, three hours offline, sign in, paused and reading. In every state the copy draws its own window (`picture`, at
twice the points), cut to the sidebar, and says what each heading shows, the
line under an open folder, the first lines of the folder's menu and the help
tag. Nothing is taken from a screen, so an open menu and a help tag are given
as their words beside the picture. The long failure is also drawn dark, in a
tinted space and in the narrowest sidebar, where the words give way to a
mark. The last pictures are Settings › Live Folders with each interval
chosen.
"""
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

sv.use("live-quiet")
sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / ".context" / "live-quiet-shots"
SCALE = 2
MODE = {"loads": 0.0}
ROWS = {
    "prs": [(36, "Add the field recorder", "sam"), (37, "Teach the rocket to count", "sam"), (41, "Cache the build graph", "dana")],
    "reviews": [(61, "Fold the solar panels", "lee"), (63, "Paint the nose cone", "dana")],
    "empty": [],
}
NAMES = ["PRs", "Reviews", "Empty"]
LONG = "Rocket Pull Requests Waiting for Review"
PALE = {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0}
t = sv.T()
report = {"scenes": {}, "settings": {}}


def page(name):
    rows = "".join(f'<li class="js-issue-row"><a href="/acme/rocket/pull/{n}">{title}</a>'
                   f'<span>#{n} opened today by <a data-testid="author-filter-link" href="/{who}">{who}</a></span></li>'
                   for n, title, who in ROWS.get(name, []))
    return ('<!doctype html><meta name="user-login" content="sam"><title>Pull requests</title><ul>' + rows + "</ul>").encode()


class Site(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        parts = self.path.split("/")
        body = b"<!doctype html><title>Launch notes</title><body style='font:15px -apple-system;padding:40px'><h2>Launch notes</h2>"
        if len(parts) > 2 and parts[1] == "work":
            if MODE["loads"] > 0:
                time.sleep(MODE["loads"])
            body = page(parts[2])
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6
    daemon_threads = True


site = Loopback6(("::1", 0), Site)
threading.Thread(target=site.serve_forever, daemon=True).start()
BASE = f"http://[::1]:{site.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder(name):
    return next((f for f in live()["folders"] if f["name"] == name), None)


def shoot(name, width, height, crop=True):
    drawn = Path(tempfile.mkdtemp()) / f"{name}.png"
    got = sv.cmd({"do": "picture", "path": str(drawn), "page": False, "scale": SCALE})
    if drawn.exists():
        cut = f"crop={int(width * SCALE)}:{int(height * SCALE)}:0:0" if crop else "null"
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(drawn), "-vf", cut, str(OUT / f"{name}.png")], check=True)
    shutil.rmtree(drawn.parent, ignore_errors=True)
    t.ok(f"pictured {name}", (OUT / f"{name}.png").exists(), got)


def fresh():
    for name in NAMES:
        live("force", name, "running")
        got = next(f for f in live("update", name)["folders"] if f["name"] == name)
        if got["state"] != "fine":
            got = next(f for f in live("update", name)["folders"] if f["name"] == name)
        t.ok(f"{name} reads fine again", got["state"] == "fine", (got["state"], got["cause"]))


def scene(name, width=240, wants=None):
    time.sleep(0.9)
    said = {}
    for each in NAMES:
        h = live("heading", each)
        f = folder(each)
        menu = live("foldermenu", each).get("items", [])
        said[each] = {"heading": {k: h.get(k) for k in ("said", "marked", "statusTip", "statusShown", "pill", "title", "ring", "spoken", "chip",
                                                         "nameCut", "width")},
                      "state": f["state"], "cause": f["cause"], "rows": len(f["items"]), "stale": f["stale"], "help": f["help"],
                      "menu": [m["title"] for m in menu if m["header"]],
                      "items": [m["title"] for m in menu if not m["header"] and not m["separator"]][:3]}
    lines = {n["folder"]: {k: n.get(k) for k in ("text", "detail", "button", "tip", "cut")} for n in live("notes")["notes"]}
    for each in NAMES:
        said[each]["line"] = lines.get(each, {}).get("text", "")
    if wants:
        for each, (heading_says, line_says) in wants.items():
            got = said[each]
            t.ok(f"{name}: {each} says {heading_says!r} on its row and {line_says!r} under it",
                 (got["heading"]["said"] or got["heading"]["title"] or "") == heading_says and got["line"] == line_says,
                 (got["heading"], got["line"]))
    t.ok(f"{name}: no line under a folder is cut", not any(v.get("cut") for v in lines.values()), lines)
    shoot(name, width, 400)
    report["scenes"][name] = {"folders": said, "lines": lines}
    return said


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "welcome.show": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "240"], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 900, "height": 700, "steps": 1})
        sv.cmd({"do": "window"})
        sv.cmd({"do": "open", "url": f"{BASE}/home"})
        for name, slug in (("PRs", "prs"), ("Reviews", "reviews"), ("Empty", "empty")):
            live("add-page", name, "pullRequests", f"{BASE}/work/{slug}/pulls?q=is%3Aopen+is%3Apr")
            read = next(f for f in live("update", name)["folders"] if f["name"] == name)
            t.ok(f"{name} reads its rows", read["state"] == "fine" and len(read["items"]) == len(ROWS[slug]), (read["state"], len(read["items"])))
        live("unfold", "Reviews")
        live("unfold", "Empty")
        live("fold", "PRs")
        sv.cmd({"do": "ui", "look": "light"})
        time.sleep(1.2)

        quiet = {"PRs": ("", ""), "Reviews": ("", ""), "Empty": ("", "No pull requests")}
        said = scene("fresh", wants=quiet)
        t.ok("fresh: the menu starts with when the folder was updated", said["PRs"]["menu"] == ["Updated a moment ago"], said["PRs"]["menu"])
        t.ok("fresh: then Update Now and Stop Updating", said["PRs"]["items"][:2] == ["Update Now", "Stop Updating"], said["PRs"]["items"])

        for name in NAMES:
            live("force", name, "failed")
        said = scene("failed-once", wants=quiet)
        t.ok("failed once: the rows stay", [said[n]["rows"] for n in NAMES] == [3, 2, 0], [said[n]["rows"] for n in NAMES])
        t.ok("failed once: the menu says why for someone who looks", said["PRs"]["menu"][-1].startswith("Couldn't read"), said["PRs"]["menu"])

        fresh()
        for name in NAMES:
            live("force", name, "old")
            live("force", name, "failed")
        said = scene("old-failed-once", wants=quiet)
        t.ok("an old list whose next read fails once: the menu says how old it is and why",
             said["PRs"]["menu"][0].startswith("Updated ") and said["PRs"]["menu"][0] != "Updated a moment ago"
             and said["PRs"]["menu"][-1].startswith("Couldn't read"), said["PRs"]["menu"])
        waits = folder("PRs")
        t.ok("it has been stuck for less than one more try takes", 0 <= waits["stuck"] < waits["grace"] == 360 and not waits["stale"],
             (waits["stuck"], waits["grace"], waits["long"]))

        fresh()
        for name in NAMES:
            live("aged", name, "480")
        live("here", "away")
        for name in NAMES:
            live("force", name, "failed")
        gone = folder("PRs")
        t.ok("a folder that got stuck while the person was away says nothing while they are away", gone["said"] == "" and gone["stuck"] >= 8 * 3600 - 60,
             (gone["said"], gone["stuck"]))
        live("here", "0")
        back = scene("back-after-away", wants=quiet)
        t.ok("and nothing when they come back, until another try has failed", not folder("PRs")["stale"], back["PRs"]["heading"])
        live("here", "7")
        time.sleep(0.4)
        later = folder("PRs")
        t.ok("seven minutes after they are back and still failing, it says Out of date", later["said"] == "Out of date", (later["said"], later["stuck"]))
        live("here", "away")
        t.ok("a row that says Out of date keeps saying it while the person is away", folder("PRs")["said"] == "Out of date", folder("PRs")["said"])
        live("here", "0")
        t.ok("and when they come back", folder("PRs")["said"] == "Out of date", folder("PRs")["said"])
        live("aged", "PRs", "0")

        fresh()
        for name in NAMES:
            live("aged", name, "180")
            live("force", name, "failed")
        said = scene("failing-long", wants={"PRs": ("Out of date", ""), "Reviews": ("Out of date", "")})
        site_words = said["PRs"]["menu"][-1]
        t.ok("failing long: the empty folder says it could not be read", not said["Empty"]["heading"]["said"]
             and said["Empty"]["line"] in (site_words, "Couldn't read this site"), (said["Empty"]["heading"], said["Empty"]["line"]))
        t.ok("failing long: the rows stay", [said[n]["rows"] for n in NAMES] == [3, 2, 0], [said[n]["rows"] for n in NAMES])
        t.ok("failing long: the help tag says since when and why", said["PRs"]["heading"]["statusTip"].startswith("Updated ")
             and said["PRs"]["heading"]["statusTip"].endswith(f". {site_words}."), said["PRs"]["heading"]["statusTip"])
        t.ok("failing long: the empty folder offers Try again", report["scenes"]["failing-long"]["lines"].get("Empty", {}).get("detail") == "Try again",
             report["scenes"]["failing-long"]["lines"])
        live("heading", "PRs", "hover")
        scene("failing-long-hover")
        live("heading", "PRs", "rest")
        sv.cmd({"do": "ui", "look": "dark"})
        scene("failing-long-dark")
        sv.cmd({"do": "ui", "look": "light"})

        fresh()
        for name in NAMES:
            live("aged", name, "180")
            live("force", name, "limited")
        said = scene("limited-long")
        t.ok("limited: the row says Out of date and the help tag says the limit and the wait",
             said["PRs"]["heading"]["said"] == "Out of date" and ", trying again in 10 minutes." in said["PRs"]["heading"]["statusTip"], said["PRs"]["heading"])
        t.ok("limited: the empty folder has no Try again while the limit holds",
             report["scenes"]["limited-long"]["lines"].get("Empty", {}).get("button") is False, report["scenes"]["limited-long"]["lines"])

        fresh()
        for name in NAMES:
            live("aged", name, "180")
        live("net", "down")
        said = scene("offline-long")
        t.ok("offline: the rows say Out of date and the empty folder says You're offline",
             said["PRs"]["heading"]["said"] == "Out of date" and said["Empty"]["line"] == "You're offline" and said["PRs"]["menu"][-1] == "You're offline",
             (said["PRs"]["heading"], said["Empty"]["line"], said["PRs"]["menu"]))
        live("net", "up")

        fresh()
        for name in NAMES:
            live("force", name, "signIn")
        said = scene("sign-in")
        t.ok("sign in: the folded row keeps its button and the open ones their line",
             said["PRs"]["heading"]["pill"] and said["Reviews"]["line"].startswith("Sign in") and said["Empty"]["line"].startswith("Sign in"),
             (said["PRs"]["heading"], said["Reviews"]["line"], said["Empty"]["line"]))

        fresh()
        for name in NAMES:
            live("force", name, "paused")
        said = scene("paused", wants={"PRs": ("Paused", ""), "Reviews": ("Paused", ""), "Empty": ("", "Not updating")})
        t.ok("paused: the menu offers Start Updating", "Start Updating" in said["PRs"]["items"], said["PRs"]["items"])

        fresh()
        for name in NAMES:
            live("aged", name, "180")
            live("force", name, "failed")
        sv.cmd({"do": "space", "action": "look", **PALE})
        scene("failing-long-pale")
        live("add-page", LONG, "pullRequests", f"{BASE}/work/prs/pulls?q=is%3Aopen+is%3Apr")
        live("update", LONG)
        live("fold", LONG)
        live("aged", LONG, "180")
        live("force", LONG, "failed")
        sv.cmd({"do": "ui", "sideWidth": 200})
        narrow = scene("failing-long-narrowest", 200)
        t.ok("narrowest: every row still says Out of date and the folded one keeps its count",
             all(narrow[n]["heading"]["said"] == "Out of date" and narrow[n]["heading"]["statusShown"] for n in ("PRs", "Reviews"))
             and narrow["PRs"]["heading"]["chip"], {n: narrow[n]["heading"] for n in ("PRs", "Reviews")})
        long = live("heading", LONG)
        t.ok("narrowest: a long name keeps a mark for Out of date, with the words in its help tag and spoken",
             long.get("said") == "Out of date" and long.get("marked") is True and long.get("statusShown") is True
             and long.get("statusTip", "").startswith("Updated "), long)
        report["scenes"]["failing-long-narrowest"]["long"] = long
        sv.cmd({"do": "ui", "sideWidth": 240})
        live("remove", LONG)

        fresh()
        MODE["loads"] = 600.0
        for name in NAMES:
            live("ask", name)
        said = scene("reading")
        t.ok("reading: every heading carries the ring and nothing else", all(said[n]["heading"]["ring"] and not said[n]["heading"]["said"] for n in NAMES),
             {n: said[n]["heading"] for n in NAMES})
        t.ok("reading: the menu says Updating", said["PRs"]["menu"] == ["Updating…"], said["PRs"]["menu"])

        sv.cmd({"do": "ui", "settings": True})
        time.sleep(0.6)
        sv.cmd({"do": "ui", "settingsPage": "livefolders"})
        time.sleep(0.8)
        first = sv.cmd({"do": "settings", "find": "how often"})
        t.ok("Settings finds the interval by the words how often", any(i.get("id") == "live.every" for i in first.get("found", [])), first.get("found"))
        t.ok("with no stored value it is five minutes", first["values"].get("live.every") == 5, first["values"].get("live.every"))
        for minutes in (5, 1, 15, 30, 60):
            got = sv.cmd({"do": "settings", "find": "", "set": "live.every", "value": minutes, "row": "live.every"})
            time.sleep(0.5)
            every = folder("PRs")["every"]
            t.ok(f"{minutes} min: the setting is kept and the folders take it", got["values"].get("live.every") == minutes and every == minutes * 60,
                 (got["values"].get("live.every"), every))
            t.ok(f"{minutes} min: its row is on the page", "live.every" in got.get("rows", []), got.get("rows"))
            shoot(f"settings-every-{minutes}", 0, 0, crop=False)
            report["settings"][str(minutes)] = {"value": got["values"].get("live.every"), "every": every, "row": got.get("row")}
        try:
            refused = sv.cmd({"do": "settings", "find": "", "set": "live.every", "value": 7})
        except RuntimeError as e:
            refused = {"error": str(e)}
        t.ok("a value that is not a choice is refused", "error" in refused, refused)
        t.ok("and the setting stays as it was", sv.cmd({"do": "settings", "find": ""})["values"].get("live.every") == 60, refused)
        sv.cmd({"do": "settings", "find": "", "set": "live.every", "value": 5})
        (OUT / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))
    finally:
        sv.finish()
    print(OUT)
    t.done()
    return int(t.failed != 0)



if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""A link opened in a new tab inside Broadway, and a link from another app
with ⌥ held, go to the row of a live folder that already has the item.

Build first (`./build.sh`), then `python3 Tests/live_open_clicks.py`.

A hidden test copy in a world of its own reads the fake signed-in GitHub
that pr_rows serves on ::1 (never the real site or anyone's account). A page
on another host (127.0.0.1) links to its pull requests; clicks are trusted
ones (`tap`, `linkmenu`).

- ⌘-click, the middle button and Open Link in New Tab each point the row at
  the address, add no tab, leave him on the page, and say where it went.
- ⌘⇧-click and a clicked link that asks for a new window select the row.
- A link to a pull request the folder lacks opens the ordinary new tab.
- A link on a row's own page to that same pull request opens the ordinary
  new tab, and the row's page stays where it is.
- From another space a behind-open points the row there and nothing moves.
- ⌥ on a link from another app that has a row shows no chooser and lands on
  the row; with no row the chooser comes up as before.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402
import live_open as lo  # noqa: E402

t = lo.t
PULL = lo.PULL
STYLE = 'style="display:block;font-size:26px;line-height:44px;padding:0 20px"'
LINKS = [
    ("files41", f"{PULL}/41/files#diff-1", ""),
    ("comment44", f"{PULL}/44#issuecomment-1", ""),
    ("pull45", f"{PULL}/45#issuecomment-9", ""),
    ("checks46", f"{PULL}/46/checks", ""),
    ("commit512", f"{PULL}/512/commits/0a1b2c3", ""),
    ("gone999", f"{PULL}/999", ""),
    ("window36", f"{PULL}/36/files", ' target="_blank"'),
    ("again41", f"{PULL}/41/checks", ""),
]
HREF = {name: href for name, href, _ in LINKS}
fake_page = pr.pull_page


class Links(BaseHTTPRequestHandler):
    def do_GET(self):
        name = urlparse(self.path).path
        rows = "".join(f'<a id="{id}" href="{href}"{extra} {STYLE}>{id}</a>' for id, href, extra in LINKS)
        body = f"<!doctype html><meta charset=utf-8><title>{name}</title>{rows}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


def linked_page(number):
    own = f'<a id="own" href="/acme/rocket/pull/{number}/commits/abc" {STYLE}>own commits</a>'
    return fake_page(number) + own.encode()


def tap(tab, anchor, wait=1.6, **extra):
    said = sv.cmd({"do": "tap", "id": tab, "selector": f"#{anchor}", **extra})
    time.sleep(wait)
    return said


def spot(tab, anchor):
    return sv.ev(tab, f"(() => {{ const r = document.querySelector('#{anchor}').getBoundingClientRect(); return [r.left + 40, r.top + r.height / 2]; }})()")


def at(number):
    st = lo.state()
    return sv.url(st, lo.row(number))


def notice():
    return lo.route()["notice"]


def behind(name, page, act, anchor, number):
    before = len(lo.state()["tabs"])
    hits = pr.HITS.get(number, 0)
    act()
    st = lo.state()
    t.ok(f"{name}: no tab was added and he is still on the page",
         len(st["tabs"]) == before and st["activeID"] == page, (len(st["tabs"]), before, st["activeID"], page))
    t.ok(f"{name}: the row is at the address clicked", at(number) == HREF[anchor], (at(number), HREF[anchor]))
    t.ok(f"{name}: the row's page was read", pr.HITS.get(number, 0) > hits, (hits, pr.HITS.get(number, 0)))
    t.ok(f"{name}: a quiet word says where it went", notice() == "Opened in its row in PRs", notice())


def main():
    pr.pull_page = linked_page
    sv.srv.RequestHandlerClass = Links
    sv.use("live-open-clicks")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "spaces": True, "tabs.groups": True})
    lo.subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", pr.BASE], check=True)
    lo.subprocess.run(["defaults", "write", sv.SUITE, "tabs.newPlace", "next"], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 640, "steps": 1})
        page = sv.page("links")
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me")
        found = pr.folder(pr.live("update", "PRs"), "PRs")
        for _ in range(20):
            if found and found["state"] == "fine" and len(found["items"]) == 8:
                break
            time.sleep(1)
            found = pr.folder(pr.live("update", "PRs"), "PRs")
        t.ok("the folder reads the fake", found["state"] == "fine" and len(found["items"]) == 8, found)
        sv.cmd({"do": "window"})
        time.sleep(1)
        sv.sp("select", id=page); time.sleep(0.6)
        t.ok("the folder starts folded, and he is on the page of links", lo.folded() is True and lo.state()["activeID"] == page, lo.state()["groups"])

        behind("⌘-click", page, lambda: tap(page, "files41", mods=["cmd"]), "files41", 41)
        t.ok("⌘-click: the folder stays folded", lo.folded() is True, lo.state()["groups"])
        recent = lo.route()["recent"]
        t.ok("⌘-click: Recent says it in the same words",
             recent and recent[0]["went"] == "Its row goes there in the background" and recent[0]["from"].startswith("A page"), recent)

        behind("the middle button", page, lambda: tap(page, "comment44", button="middle"), "comment44", 44)

        x, y = spot(page, "pull45")
        picked = {}
        behind("Open Link in New Tab", page,
               lambda: picked.update(sv.cmd({"do": "linkmenu", "id": page, "x": x, "y": y, "pick": "Open Link in New Tab"})) or time.sleep(0.8),
               "pull45", 45)

        before = len(lo.state()["tabs"])
        tap(page, "checks46", mods=["cmd", "shift"])
        st = lo.state()
        t.ok("⌘⇧-click: the row is selected at the address, with no new tab",
             st["activeID"] == lo.row(46) and len(st["tabs"]) == before and at(46) == HREF["checks46"],
             (st["activeID"], lo.row(46), len(st["tabs"]), before, at(46)))
        t.ok("⌘⇧-click: the folded folder opened for its row, and the selected row is the word", lo.folded() is False and notice() == "", (lo.folded(), notice()))

        sv.sp("select", id=page); time.sleep(0.5)
        before = len(lo.state()["tabs"])
        tap(page, "window36")
        st = lo.state()
        t.ok("a clicked link that asks for a new window, to another site: its row is selected, with no new tab",
             st["activeID"] == lo.row(36) and len(st["tabs"]) == before and at(36) == HREF["window36"],
             (st["activeID"], lo.row(36), len(st["tabs"]), before, at(36)))

        sv.sp("select", id=page); time.sleep(0.5)
        before = lo.state()
        tap(page, "gone999", mods=["cmd"])
        st = lo.state()
        ids = sv.order(st)
        new = [x for x in ids if x not in sv.order(before)]
        t.ok("a pull request the folder lacks: the ordinary new tab, right after its page, outside the folder",
             len(new) == 1 and ids.index(new[0]) == ids.index(page) + 1 and sv.url(st, new[0]) == HREF["gone999"]
             and new[0] not in [x["id"] for x in lo.prs()["tabs"]] and st["activeID"] == page,
             (new, ids, st["activeID"]))

        own = lo.row(41)
        sv.sp("select", id=own); time.sleep(1.0)
        stood = at(41)
        before = lo.state()
        tap(own, "own", mods=["cmd"])
        st = lo.state()
        new = [x for x in sv.order(st) if x not in sv.order(before)]
        t.ok("a link on a row's page to its own pull request: the ordinary new tab",
             len(new) == 1 and sv.url(st, new[0]) == f"{PULL}/41/commits/abc", (new, [x["url"] for x in st["tabs"]]))
        t.ok("and the row's page stays where it is, with him still on it",
             at(41) == stood and sv.ev(own, "location.href") == stood and st["activeID"] == own, (at(41), stood, st["activeID"]))

        home = len(lo.state()["tabs"])
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        time.sleep(1.2)
        away = sv.page("links-in-work")
        there = len(lo.state()["tabs"])
        t.ok("Work has its own row, without the folder", pr.folder(pr.live(), "PRs")["tabs"] == [] and there < home, (there, home))
        tap(away, "again41", mods=["cmd"], wait=2.0)
        st = lo.state()
        said = notice()
        t.ok("from another space, a behind-open adds no tab and nothing moves",
             len(st["tabs"]) == there and st["activeID"] == away, (len(st["tabs"]), there, st["activeID"]))
        t.ok("and a quiet word names the folder and its space", said.startswith("Opened in its row in PRs in "), said)
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1.2)
        t.ok("the row in the first space is at the address clicked, and no tab came with it",
             at(41) == HREF["again41"] and len(lo.state()["tabs"]) == home, (at(41), len(lo.state()["tabs"]), home))

        sv.sp("select", id=page); time.sleep(0.5)
        held = lo.route("decide", f"{PULL}/45/files", "alt")
        t.ok("⌥ on a link from another app with a row: the tester says it isn't asked about",
             held["steps"] == ["Already in PRs", "⌥ was held, but a live folder has it, so you aren't asked", "Shown there"], held)
        before = len(lo.state()["tabs"])
        said = lo.route("arrive", f"{PULL}/45/files", "alt")
        time.sleep(1.6)
        st = lo.state()
        t.ok("⌥ with a row: no chooser, the row is selected at the address, no tab was added",
             lo.route()["chooser"] == [] and st["activeID"] == lo.row(45) and at(45) == f"{PULL}/45/files" and len(st["tabs"]) == before,
             (lo.route()["chooser"], st["activeID"], at(45), len(st["tabs"]), before))

        asked = lo.route("decide", f"{PULL}/999/files", "alt")
        t.ok("⌥ with no row: the tester says he chooses", asked["steps"][0] == "⌥ was held, so you choose", asked)
        lo.route("arrive", f"{PULL}/999/files", "alt")
        time.sleep(1.2)
        rows = lo.route()["chooser"]
        t.ok("⌥ with no row: the chooser comes up as before, and nothing opens yet",
             "New Window" in rows and len(lo.state()["tabs"]) == before, (rows, len(lo.state()["tabs"]), before))
    finally:
        sv.finish()
    t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

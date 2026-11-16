#!/usr/bin/env python3
"""A link from another app to a row of a live folder goes to that row.

Build first (`./build.sh`), then `python3 Tests/live_open.py`.

A hidden test copy in a world of its own reads the fake signed-in GitHub
that pr_rows serves on ::1 (never the real site or anyone's account): a PRs
folder of eight rows, three of them a stack. Links are handed over the way
another app hands them (`route arrive`), and what the tester would say is
read with `route decide`.

- Each kind of address for a pull request (its page, Files, a commit, a
  comment, a query, tracking parameters, a Slack redirect) selects the row,
  adds no tab, and the row's page is at the address asked for.
- The same address again leaves the page alone: nothing is read again.
- A folded folder opens for the row; a folded stack opens for its member;
  a row scrolled out of sight is scrolled to.
- A row in another space brings that space, says so, and the notice's
  Open in New Tab puts a tab where the link would have gone.
- A rule for another space does not make a second tab.
- A pull request that is not in the folder, and one hidden from it, open
  the ordinary way.
"""
import json
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

t = sv.T()
STACKED = {36: 1, 37: 2, 38: 3}
plain_page = pr.pull_page


def stacked_page(number):
    body = plain_page(number)
    if number not in STACKED:
        return body
    blob = json.dumps({"stack": {"number": 7, "position": STACKED[number], "size": len(STACKED)}})
    return body + f"<script type=\"application/json\" data-target=\"react-app.embeddedData\">{blob}</script>".encode()


pr.pull_page = stacked_page
PULL = f"{pr.BASE}/acme/rocket/pull"


def route(*args):
    return sv.cmd({"do": "route", "args": list(args)})


def state():
    return sv.sp("state")


def prs():
    return pr.folder(pr.live(), "PRs")


def row(number):
    found = prs()
    at = next(i for i, item in enumerate(found["items"]) if item["url"] == f"{PULL}/{number}")
    return found["tabs"][at]["id"]


def label(number):
    found = prs()
    at = next(i for i, item in enumerate(found["items"]) if item["url"] == f"{PULL}/{number}")
    return found["tabs"][at]["label"]


def arrive(address, wait=1.6):
    said = route("arrive", address)
    time.sleep(wait)
    return said


def active():
    st = state()
    return st["activeID"], sv.url(st, st["activeID"]), len(st["tabs"])


def shown(tab):
    return sv.ev(tab, "location.href")


def in_sight(tab):
    frames = sv.cmd({"do": "rowframes"})["rows"]
    column = sv.cmd({"do": "columnscroll"})
    frame = frames.get(tab)
    return bool(frame) and frame[1] >= 0 and frame[1] + frame[3] <= column["height"], (frame, column.get("offset"), column.get("height"))


def folded(name="PRs"):
    live = pr.folder(pr.live(), name)
    ids = {tab["id"] for tab in live["tabs"]}
    st = state()
    groups = {gid for tab, gid in zip(st["tabs"], st["groupIDs"]) if tab["id"] in ids}
    return next(g["collapsed"] for g in st["groups"] if g["id"] in groups)


def lands(name, address, number, wants=None):
    wants = wants or address
    before = len(state()["tabs"])
    arrive(address)
    tab, url, count = active()
    t.ok(f"{name}: the row is selected and no tab was added", tab == row(number) and count == before, (tab, row(number), count, before))
    t.ok(f"{name}: the row is at the address asked for", url == wants and shown(tab) == wants, (url, shown(tab), wants))
    seen, where = in_sight(tab)
    t.ok(f"{name}: the row is in sight", seen, where)
    return tab


def main():
    sv.use("live-open")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "spaces": True})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", pr.BASE], check=True)
    sv.launch()
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 560, "steps": 1})
        loose = [sv.cmd({"do": "open", "url": f"{pr.BASE}/home?Page+{n}"})["id"] for n in range(1, 13)]
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me")
        found = pr.folder(pr.live("update", "PRs"), "PRs")
        for _ in range(20):
            if found and found["state"] == "fine" and found.get("stacks"):
                break
            time.sleep(1)
            found = pr.folder(pr.live("update", "PRs"), "PRs")
        t.ok("the folder reads the fake, with its stack", found["state"] == "fine" and len(found["items"]) == 8 and found.get("stacks"), found)
        sv.cmd({"do": "window"})
        time.sleep(1)
        sv.sp("select", id=loose[0]); time.sleep(0.5)
        t.ok("the folder starts folded", folded() is True, state()["groups"])

        said = route("decide", f"{PULL}/41/files?utm_source=slack#diff-1")
        t.ok("the tester says it in plain words",
             said["steps"] == ["Took the tracking parameters off", "Already in PRs", "Shown there"]
             and said["url"] == f"{PULL}/41/files#diff-1", said)
        gone = route("decide", f"{PULL}/999")
        t.ok("the tester says nothing of rows for a pull request the folder lacks", gone["steps"] == ["Opens where you are"], gone)

        lands("Files, with tracking", f"{PULL}/41/files?utm_source=slack#diff-1", 41, wants=f"{PULL}/41/files#diff-1")
        t.ok("the folded folder opened for its row", folded() is False, state()["groups"])
        recent = route()["recent"]
        t.ok("Recent says where it went and why", recent and recent[0]["went"] == "Shown there", recent)

        hits = dict(pr.HITS)
        before = len(state()["tabs"])
        arrive(f"{PULL}/41/files#diff-1")
        tab, url, count = active()
        t.ok("the same address again: still the row, no tab, nothing read again",
             tab == row(41) and count == before and pr.HITS == hits, (tab, count, before, hits, dict(pr.HITS)))

        title = label(41)
        arrive(f"{PULL}/41/files#diff-2")
        tab, url, count = active()
        t.ok("another place on the page it is on: the page moves there, nothing is read again",
             tab == row(41) and count == before and pr.HITS == hits and shown(tab) == f"{PULL}/41/files#diff-2",
             (shown(tab), hits, dict(pr.HITS)))
        t.ok("and the row keeps its title", title and label(41) == title, (title, label(41)))

        sv.sp("select", id=loose[0]); time.sleep(0.4)
        lands("the pull request itself", f"{PULL}/44", 44)
        hits = dict(pr.HITS)
        title = label(44)
        sv.sp("select", id=loose[0]); time.sleep(0.4)
        lands("a comment on a page already loaded", f"{PULL}/44#issuecomment-1", 44)
        t.ok("the loaded page was not read again, and the row keeps its title",
             pr.HITS == hits and title and label(44) == title, (hits, dict(pr.HITS), title, label(44)))
        sv.sp("select", id=loose[0]); time.sleep(0.4)
        arrive(f"{PULL}/44")
        tab, url, count = active()
        t.ok("the bare pull request leaves a page at a comment where it is",
             tab == row(44) and pr.HITS == hits and shown(tab) == f"{PULL}/44#issuecomment-1", (shown(tab), hits, dict(pr.HITS)))
        sv.sp("select", id=loose[0]); time.sleep(0.4)
        lands("a commit", f"{PULL}/512/commits/0a1b2c3", 512)
        sv.sp("select", id=loose[0]); time.sleep(0.4)
        lands("a comment", f"{PULL}/45#issuecomment-4411", 45)
        sv.sp("select", id=loose[0]); time.sleep(0.4)
        lands("a query", f"{PULL}/46/files?w=1", 46)
        sv.sp("select", id=loose[0]); time.sleep(0.4)
        wrapped = "https://slack-redir.net/link?url=" + quote(f"{PULL}/41/checks", safe="")
        lands("a Slack redirect", wrapped, 41, wants=f"{PULL}/41/checks")

        sv.sp("select", id=loose[0]); time.sleep(0.4)
        st = pr.live("stack")
        time.sleep(0.8)
        t.ok("the stack is folded", [x["folded"] for x in pr.folder(st, "PRs")["stacks"]] == [True], pr.folder(st, "PRs")["stacks"])
        rows = sv.cmd({"do": "rowframes"})["rows"]
        t.ok("folded, the stack's lower rows are gone", row(36) not in rows and row(37) not in rows, sorted(rows))
        lands("a row inside a folded stack", f"{PULL}/36/files", 36)
        t.ok("the stack opened for it", [x["folded"] for x in prs()["stacks"]] == [False], prs()["stacks"])

        sv.sp("select", id=loose[-1])
        time.sleep(1.2)
        column = sv.cmd({"do": "columnscroll"})
        seen, where = in_sight(row(512))
        t.ok("the column scrolls, and the folder's first row is out of sight", column["scrolls"] and not seen, (column.get("offset"), where))
        lands("a row scrolled out of sight", f"{PULL}/512/files", 512)

        sv.sp("select", id=loose[0]); time.sleep(0.4)
        sv.cmd({"do": "group", "name": "PRs", "fold": True}); time.sleep(0.8)
        t.ok("the folder is folded again", folded() is True, state()["groups"])
        before = len(state()["tabs"])
        arrive(f"{PULL}/999/files")
        tab, url, count = active()
        t.ok("a pull request the folder lacks opens the ordinary way: a new tab, outside the folder",
             count == before + 1 and url == f"{PULL}/999/files" and tab not in [x["id"] for x in prs()["tabs"]] and folded() is True,
             (tab, url, count, before))

        pr.live("hide", row(44))
        time.sleep(0.6)
        t.ok("a row hidden from the folder is gone from it", f"{PULL}/44" not in [i["url"] for i in prs()["items"]], prs()["items"])
        before = len(state()["tabs"])
        arrive(f"{PULL}/44/files")
        tab, url, count = active()
        t.ok("a hidden pull request opens the ordinary way, and stays hidden",
             count == before + 1 and url == f"{PULL}/44/files" and f"{PULL}/44" not in [i["url"] for i in prs()["items"]],
             (url, count, before))

        home = len(state()["tabs"])
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        time.sleep(1.2)
        work = sv.cmd({"do": "open", "url": f"{pr.BASE}/home?In+Work"})["id"]
        time.sleep(0.6)
        there = len(state()["tabs"])
        t.ok("Work has its own row, without the folder", pr.folder(pr.live(), "PRs")["tabs"] == [] and there < home, (there, home))
        said = route("decide", f"{PULL}/45/files")
        t.ok("from Work, the tester names the folder's space", said["steps"][0].startswith("Already in PRs in ") and said["steps"][-1] == "Shown there", said)
        route("pattern", f"*/acme/rocket/pull/*", "space", "Work")
        ruled = route("decide", f"{PULL}/45/files")
        t.ok("a rule for Work does not move it", ruled["steps"][-2].endswith("so the rule doesn't move it") and ruled["steps"][-1] == "Shown there", ruled)
        arrive(f"{PULL}/45/files", wait=2.2)
        tab, url, count = active()
        notice = route()["notice"]
        t.ok("a row in another space: that space comes forward on the row, at the address",
             count == home and tab == row(45) and url == f"{PULL}/45/files", (tab, url, count, home))
        t.ok("and a quiet word says where", notice == "Shown in PRs", notice)
        sv.cmd({"do": "space", "action": "go", "index": 2})
        time.sleep(1.2)
        st = state()
        t.ok("Work got no second tab for it",
             len(st["tabs"]) == there and work in sv.order(st) and not any("/pull/" in x["url"] for x in st["tabs"]),
             [x["url"] for x in st["tabs"]])
        route("clear")
    finally:
        sv.finish()
    t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

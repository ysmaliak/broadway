#!/usr/bin/env python3
"""Hide Draft Review Requests: a pull request folder asks GitHub for its review lists without drafts.

Build first (`./build.sh`), then `python3 Tests/draft_reviews.py`.

A test copy in a world of its own reads a stand-in for GitHub on ::1
through `integrations.api`, so the rows carry github.com addresses and
nothing is asked of the real site. The stand-in answers each list by the
words of its search, as GitHub's search would: review-requested:@me,
author:@me, assignee:@me, and draft:false leaves drafts out. An empty list
says "No results matched your search", as GitHub's does.

- A folder with Review Requests, Created by You and Assigned to You reads
  five pull requests: a draft asking for review (#1), a ready one asking
  for review (#2), a draft of your own (#3), a draft asking for review and
  assigned to you (#4), and a draft asking for review in a stack with two
  of your own (#11 to #13).
- The item sits in the folder's menu right under Lists, without a check.
  Picking it takes #1 and #12 away at once, keeps #3 and #4 with their
  Draft label, and the next read asks Review Requests with draft:false
  and Created by You and Assigned to You as before. The item has its check.
- Picking it again reads without draft:false and #1 and #12 come back.
- A github:reviews folder asks its own address with draft:false added,
  and its stored address stays as it was.

A stand-in proves what Broadway asks, not what GitHub answers.
"""
import json
import socket
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

t = sv.T()
LISTS = "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse"
REVIEWS = "https://github.com/pulls?q=is%3Aopen+is%3Apr+review-requested%3A%40me+archived%3Afalse"
ITEM = "Hide Draft Review Requests"
PR = {
    1: dict(title="Sketch the new onboarding", draft=True, review=True),
    2: dict(title="Retry uploads on 502", review=True),
    3: dict(title="Try a lighter list cell", draft=True, created=True),
    4: dict(title="Move settings to the sidebar", draft=True, review=True, assigned=True),
    11: dict(title="Rail - Add the model", created=True, stack=1),
    12: dict(title="Rail - Keep rails in the store", draft=True, review=True, stack=2),
    13: dict(title="Rail - Show the rail", created=True, stack=3),
}
ASKED = []
OPEN = '<svg aria-label="Open pull request" class="octicon octicon-git-pull-request fgColor-open" width="16" height="16"></svg>'
DRAFT = '<svg aria-label="Draft pull request" class="octicon octicon-git-pull-request-draft fgColor-muted" width="16" height="16"></svg>'


def url(n):
    return f"https://github.com/acme/rocket/pull/{n}"


def matching(search):
    words = set(search.split())
    found = []
    for n, pr in PR.items():
        if "draft:false" in words and pr.get("draft"):
            continue
        if "review-requested:@me" in words and pr.get("review") or "author:@me" in words and pr.get("created") \
                or "assignee:@me" in words and pr.get("assigned"):
            found.append(n)
    return found


def list_page(search):
    numbers = matching(search)
    rows = "".join(
        f'<li class="listItem"><h3><a href="{url(n)}" data-testid="listitem-title-link"><span>{PR[n]["title"]}</span></a></h3>'
        f'<div><div class="leadingElement">{DRAFT if PR[n].get("draft") else OPEN}</div><span>#{n}</span>'
        f'<a data-testid="author-filter-link" href="/acme/rocket/pulls?q=author%3Aocto-sam">octo-sam</a></div></li>' for n in numbers)
    if not numbers:
        rows = "</ul><h3>No results matched your search.</h3><ul>"
    blob = json.dumps({"payload": {"pullRequestsIndex": {"results": {"items": [
        {"number": n, "permalink": url(n), "updatedAt": "2026-11-18T09:00:00Z"} for n in numbers]}}}})
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title><body><ul role="list">{rows}</ul>'
            f'<script type="application/json" data-target="react-app.embeddedData">{blob}</script>').encode()


def pull_page(n):
    pr = PR[n]
    position = pr.get("stack")
    head = f"rail-{position}" if position else f"work-{n}"
    base = f"rail-{position - 1}" if position and position > 1 else "main"
    status = "draft" if pr.get("draft") else "pullOpened"
    pull = {"baseBranch": base, "headBranch": head, "headRepositoryName": "rocket", "headRepositoryOwnerLogin": "acme",
            "number": n, "state": "OPEN", "title": pr["title"]}
    blob = json.dumps({"stack": {"number": 21, "position": position} if position else None, "pullRequest": pull})
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>{pr["title"]} · Pull Request #{n} · acme/rocket</title><body>'
            f'<div data-component="PageHeader.Description"><span data-component="StateLabel" data-status="{status}">Open</span></div>'
            f'<script type="application/json" data-target="react-app.embeddedData">{blob}</script>').encode()


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, body=b""):
        self.send_response(status)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parts = urlsplit(self.path)
        if parts.path == "/github/page/pulls":
            search = parse_qs(parts.query).get("q", [""])[0]
            ASKED.append(search)
            return self.send(200, list_page(search))
        bits = parts.path.split("/")
        if len(bits) == 7 and bits[1:5] == ["github", "page", "acme", "rocket"] and bits[5] == "pull" and bits[6].isdigit() and int(bits[6]) in PR:
            return self.send(200, pull_page(int(bits[6])))
        self.send(404, b"Not Found")


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


srv = Loopback6(("::1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://[::1]:{srv.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder(name, st=None):
    st = st or live()
    return next((f for f in st["folders"] if f["name"] == name), None)


def rows(name, st=None):
    found = folder(name, st)
    return {int(i["url"].rsplit("/", 1)[1]): i for i in found["items"]} if found else {}


def menu(name):
    return sv.cmd({"do": "live", "args": ["foldermenu", name]})["items"]


def pick(name):
    sv.cmd({"do": "live", "args": ["foldermenu", name, ITEM]})


BROADWAY = str(ROOT / "build/Broadway.app/Contents/Helpers/broadway")


def broadway(*words):
    got = subprocess.run([BROADWAY, "--world", sv.W, *words, "--json"], capture_output=True, text=True, timeout=40)
    try:
        said = json.loads(got.stdout or "{}")
    except json.JSONDecodeError:
        return got.returncode, {"raw": got.stdout + got.stderr}
    if got.returncode != 0 and isinstance(said, dict):
        said["stderr"] = got.stderr[-400:]
    return got.returncode, said.get("data", said) if isinstance(said, dict) else said


def ident(name):
    code, said = broadway("live", "list")
    found = next((f for f in said.get("folders", []) if f.get("name") == name), None) if isinstance(said, dict) else None
    return found["id"] if found else None


def start():
    sv.use("drafts-" + uuid.uuid4().hex[:4])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "agents.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", BASE], check=True)
    sv.launch()


def lists_folder():
    print("— a folder with Review Requests, Created by You and Assigned to You")
    live("add", "PRs", LISTS)
    live("lists", "PRs", "reviewRequests,created,assigned")
    live("unfold", "PRs")
    found = rows("PRs", live("update", "PRs"))
    for _ in range(15):
        if "/3" in (found.get(13) or {}).get("byline", ""):
            break
        time.sleep(1)
        found = rows("PRs", live("update", "PRs"))
    t.ok("switch off: every pull request shows", sorted(found) == [1, 2, 3, 4, 11, 12, 13], sorted(found))
    t.ok("switch off: the stack counts three", [found[n]["byline"].split(" ")[1] if " " in found[n]["byline"] else "" for n in (13, 12, 11)]
         == ["3/3", "2/3", "1/3"], {n: found[n]["byline"] for n in (11, 12, 13)})

    items = menu("PRs")
    titles = [i["title"] for i in items]
    t.ok("the item sits right under Lists", ITEM in titles and titles.index(ITEM) == titles.index("Lists") + 1, titles)
    t.ok("and has no check", not next(i for i in items if i["title"] == ITEM)["on"], items)

    ASKED.clear()
    pick("PRs")
    now = rows("PRs")
    t.ok("picking it takes the drafts that only ask for review away at once", sorted(now) == [2, 3, 4, 11, 13], sorted(now))
    st = live("update", "PRs")
    now = rows("PRs", st)
    t.ok("the next read leaves them out", sorted(now) == [2, 3, 4, 11, 13], sorted(now))
    t.ok("the folder reads fine", folder("PRs", st)["state"] == "fine", folder("PRs", st)["state"])
    t.ok("your own draft keeps its Draft label", now[3]["label"] == "Draft", now[3])
    t.ok("a draft assigned to you stays through Assigned to You, labeled Draft", now[4]["label"] == "Draft" and now[4]["list"] == "assigned", now[4])
    t.ok("the two stack members left count two", sorted(now[n]["byline"].split(" ")[1] for n in (11, 13)) == ["1/2", "2/2"],
         {n: now[n]["byline"] for n in (11, 13)})
    review = [q for q in ASKED if "review-requested:@me" in q]
    others = [q for q in ASKED if "review-requested:@me" not in q]
    t.ok("Review Requests is asked with draft:false", review and all("draft:false" in q for q in review), ASKED)
    t.ok("Created by You and Assigned to You are asked as before", others and all("draft:" not in q for q in others), ASKED)
    t.ok("the folder says it hides drafts", folder("PRs")["hidesDrafts"], folder("PRs")["hidesDrafts"])
    t.ok("the item has its check", next(i for i in menu("PRs") if i["title"] == ITEM)["on"], menu("PRs"))

    ASKED.clear()
    pick("PRs")
    st = live("update", "PRs")
    now = rows("PRs", st)
    t.ok("picking it again brings the drafts back", sorted(now) == [1, 2, 3, 4, 11, 12, 13], sorted(now))
    t.ok("and asks without draft:false", ASKED and all("draft:" not in q for q in ASKED), ASKED)
    t.ok("the item has no check again", not next(i for i in menu("PRs") if i["title"] == ITEM)["on"], menu("PRs"))
    live("remove", "PRs")


def address_folder():
    print("— a github:reviews folder")
    live("add", "Reviews", "github:reviews")
    live("unfold", "Reviews")
    found = rows("Reviews", live("update", "Reviews"))
    t.ok("switch off: drafts and ready pull requests asking for review show", sorted(found) == [1, 2, 4, 12], sorted(found))
    titles = [i["title"] for i in menu("Reviews")]
    t.ok("the item is in its menu though it has no Lists", ITEM in titles and "Lists" not in titles, titles)
    ASKED.clear()
    pick("Reviews")
    t.ok("picking it takes the drafts away at once", sorted(rows("Reviews")) == [2], sorted(rows("Reviews")))
    st = live("update", "Reviews")
    t.ok("the next read leaves them out", sorted(rows("Reviews", st)) == [2], sorted(rows("Reviews", st)))
    t.ok("it asks its search with draft:false", ASKED and all("review-requested:@me" in q and "draft:false" in q for q in ASKED), ASKED)
    t.ok("its stored address stays as it was", folder("Reviews", st)["address"] == REVIEWS, folder("Reviews", st)["address"])
    pick("Reviews")
    st = live("update", "Reviews")
    t.ok("off again, the drafts come back", sorted(rows("Reviews", st)) == [1, 2, 4, 12], sorted(rows("Reviews", st)))
    live("remove", "Reviews")


def command():
    print("— broadway live drafts and live show")
    live("add", "PRs", LISTS)
    live("add", "Mine", "github:mine")
    prs, mine = ident("PRs"), ident("Mine")
    t.ok("both folders are listed", prs and mine, broadway("live", "list"))
    if not (prs and mine):
        return
    code, said = broadway("live", "show", prs)
    t.ok("live show says the switch is off", code == 0 and said.get("hidesDraftReviewRequests") is False, (code, said))
    code, said = broadway("live", "drafts", prs, "hide")
    t.ok("live drafts hide is taken", code == 0 and said.get("hidesDraftReviewRequests") is True, (code, said))
    t.ok("and says what it does", said.get("message") == "Leaves out draft review requests", said)
    t.ok("the folder hides drafts", folder("PRs")["hidesDrafts"], folder("PRs"))
    code, said = broadway("live", "show", prs)
    t.ok("live show says the switch is on", code == 0 and said.get("hidesDraftReviewRequests") is True, (code, said))
    code, said = broadway("live", "show", mine)
    t.ok("a folder that asks for no review has no switch to show", code == 0 and "hidesDraftReviewRequests" not in said, (code, said))
    code, said = broadway("live", "drafts", mine, "hide")
    t.ok("a folder that asks for no review is refused", code != 0, (code, said))
    code, said = broadway("live", "drafts", prs, "maybe")
    t.ok("a word other than hide or show is refused", code != 0, (code, said))
    code, said = broadway("live", "drafts", prs, "show")
    t.ok("live drafts show turns it off", code == 0 and not folder("PRs")["hidesDrafts"], (code, said))
    live("remove", "PRs")
    live("remove", "Mine")


def checks():
    start()
    try:
        lists_folder()
        address_folder()
        command()
    finally:
        sv.finish()


if __name__ == "__main__":
    checks()
    t.done()
    sys.exit(1 if t.failed else 0)

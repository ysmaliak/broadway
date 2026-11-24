#!/usr/bin/env python3
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
import split_view as sv

t = sv.T()
LISTS = "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse"
OPEN = '<svg aria-label="Open pull request" class="octicon octicon-git-pull-request fgColor-open" width="16" height="16"></svg>'
STATE = {"updated": "2026-11-18T09:00:00Z", "timeline": []}
ASKED = []


def url(n):
    return f"https://github.com/acme/rocket/pull/{n}"


OTHERS = {7: "review-requested:@me", 8: "assignee:@me", 9: "author:@me"}
TITLES = {5: "Retry uploads on 502", 7: "Trim the cache", 8: "Move settings to the sidebar", 9: "Try a lighter list cell"}


def matching(search):
    words = set(search.split())
    if "reviewed-by:@me" in words and "-author:@me" in words:
        return [5]
    return [n for n, word in OTHERS.items() if word in words]


def list_page(search):
    numbers = matching(search)
    rows = "".join(
        f'<li class="listItem"><h3><a href="{url(n)}" data-testid="listitem-title-link"><span>{TITLES[n]}</span></a></h3>'
        f'<div><div class="leadingElement">{OPEN}</div><span>#{n}</span>'
        f'<a data-testid="author-filter-link" href="/acme/rocket/pulls?q=author%3Adana">dana</a></div></li>' for n in numbers)
    if not numbers:
        rows = "</ul><h3>No results matched your search.</h3><ul>"
    blob = json.dumps({"payload": {"pullRequestsIndex": {"results": {"items": [
        {"number": n, "permalink": url(n), "updatedAt": STATE["updated"]} for n in numbers]}}}})
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title><body><ul role="list">{rows}</ul>'
            f'<script type="application/json" data-target="react-app.embeddedData">{blob}</script>').encode()


def who(name, stamp):
    return (f'<a class="author Link--primary text-bold" data-hovercard-type="user" href="/{name}">{name}</a>'
            f'<a href="#c" class="js-timestamp"><relative-time datetime="{stamp}" class="no-wrap">Nov 18</relative-time></a>')


def review(name, stamp):
    return (f'<div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="PRR_kwDOreview">'
            f'<div class="TimelineItem"><div class="TimelineItem-body"><strong>{who(name, stamp)}</strong> requested changes</div></div></div>')


def push(name, stamp):
    return (f'<div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="C_kwDOpush">'
            f'<div class="TimelineItem-body">{who(name, stamp)} added <span>1</span> commit</div>'
            f'<a class="avatar avatar-user" data-test-selector="commits-avatar-stack-avatar-link" href="/{name}"></a></div>')


def comment(name, stamp):
    return (f'<div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="IC_kwDOcomment">'
            f'<div class="TimelineItem js-comment-container"><div class="timeline-comment-header">{who(name, stamp)}</div>'
            f'<div class="comment-body markdown-body"><p>Thanks, looks right now</p></div></div></div>')


def pull_page(n):
    pull = {"baseBranch": "main", "headBranch": f"work-{n}", "headRepositoryName": "rocket", "headRepositoryOwnerLogin": "acme",
            "number": n, "state": "OPEN", "title": TITLES[n]}
    blob = json.dumps({"pullRequest": pull})
    timeline = "".join(STATE["timeline"]) if n == 5 else ""
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>{TITLES[n]} · Pull Request #{n} · acme/rocket</title><body>'
            f'<div data-component="PageHeader.Description"><span data-component="StateLabel" data-status="pullOpened">Open</span></div>'
            f'<div class="timeline-comment"><div class="timeline-comment-header">{who("dana", "2026-11-17T09:00:00Z")}</div></div>'
            f'<div id="partial-timeline">{timeline}</div><div id="discussion-timeline-actions"></div>'
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
        if len(bits) == 7 and bits[1:6] == ["github", "page", "acme", "rocket", "pull"] and bits[6].isdigit() and int(bits[6]) in TITLES:
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


def read_until(name, done, tries=15):
    found = rows(name, live("update", name))
    for _ in range(tries):
        if done(found):
            return found
        time.sleep(1)
        found = rows(name, live("update", name))
    return found


def start():
    sv.use("again-" + uuid.uuid4().hex[:4])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "agents.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", BASE], check=True)
    sv.launch()


def back_and_away():
    print("— a pull request you reviewed")
    STATE["timeline"] = [review("octo-sam", "2026-11-18T08:00:00Z")]
    live("add", "PRs", LISTS)
    live("unfold", "PRs")
    found = rows("PRs", live("update", "PRs"))
    time.sleep(2)
    found = rows("PRs", live("update", "PRs"))
    st = live()
    t.ok("the folder reads its four standard lists", folder("PRs", st)["lists"] == ["reviewRequests", "changed", "created", "assigned"],
         folder("PRs", st)["lists"])
    t.ok("Changed Since Your Review is asked", any("reviewed-by:@me" in q and "-author:@me" in q for q in ASKED), ASKED)
    t.ok("and asked last", ASKED and "reviewed-by:@me" in ASKED[-1], ASKED)
    t.ok("the folder reads fine", folder("PRs", st)["state"] == "fine", folder("PRs", st)["state"])
    t.ok("the other lists show their rows", sorted(found) == [7, 8, 9], sorted(found))
    t.ok("with nothing new since the review it is absent", 5 not in found, found)

    print("— the author pushes")
    STATE["timeline"].append(push("dana", "2026-11-18T10:00:00Z"))
    STATE["updated"] = "2026-11-18T10:00:00Z"
    found = read_until("PRs", lambda rows: 5 in rows)
    t.ok("it appears", 5 in found, found)
    t.ok("labeled Review again", (found.get(5) or {}).get("label") == "Review again", found.get(5))
    t.ok("from Changed Since Your Review", (found.get(5) or {}).get("list") == "changed", found.get(5))

    print("— the reviewer answers")
    STATE["timeline"].append(comment("octo-sam", "2026-11-18T11:00:00Z"))
    STATE["updated"] = "2026-11-18T11:00:00Z"
    found = read_until("PRs", lambda rows: 5 not in rows)
    t.ok("it leaves again", 5 not in found, found)
    t.ok("and the other rows stay", sorted(found) == [7, 8, 9], sorted(found))
    t.ok("the folder still reads fine", folder("PRs")["state"] == "fine", folder("PRs")["state"])
    live("remove", "PRs")


def checks():
    start()
    try:
        back_and_away()
    finally:
        sv.finish()


if __name__ == "__main__":
    checks()
    t.done()
    sys.exit(1 if t.failed else 0)

#!/usr/bin/env python3
"""Merging a pull request in a stack turns the stack below it Merged too.

Build first (`./build.sh`), then `python3 Tests/merged_stack.py`.

A test copy in a world of its own reads a fake signed-in GitHub on ::1
through `integrations.api`, so the folder's rows carry github.com
addresses and nothing is asked of the real site. The fake lists open pull
requests (merged ones leave the list, as `is:open` does) and serves each
one's own page with GitHub's header state (`data-status`) and its
`"state"` and `"stack"` in the embedded JSON. A stacked page also lists the
other members with their own states ahead of its header, so a state read
from the page must be this pull request's.

- Rail: four pull requests in one GitHub stack (#61 to #64, positions 1
  to 4). Merging #63 from its page turns #63, then #62 and #61, and leaves
  #64 open. #90, in another repository with the same stack number and
  branch names, and #70, on its own, stay as they were.
- The three leave together after the hold. A read of the list that still
  shows them open (search lags) does not bring them back while their own
  pages say merged. The next read without them confirms them.
- Dock: #81 to #83 in another stack. #82 is merged alone: #81 turns and
  leaves with it. A read right after says open, which is not believed so
  soon after a merge, so #81 stays away. A read once that has settled
  still says open, so it comes back with its own state, not Merged, and
  #83 never moved.
"""
import json
import os
import socket
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

t = sv.T()
PULLS = "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me"
PR = {
    61: ("acme/rocket", "main", "rail-model", 21, 1, "Rail - Add the model"),
    62: ("acme/rocket", "rail-model", "rail-store", 21, 2, "Rail - Keep rails in the store"),
    63: ("acme/rocket", "rail-store", "rail-view", 21, 3, "Rail - Show the rail beside the list"),
    64: ("acme/rocket", "rail-view", "rail-polish", 21, 4, "Rail - Polish the rail's ends"),
    70: ("acme/rocket", "main", "docs-typo", None, None, "Fix a typo in the guide"),
    81: ("acme/rocket", "main", "dock-shell", 22, 1, "Dock - Add the shell"),
    82: ("acme/rocket", "dock-shell", "dock-icons", 22, 2, "Dock - Draw the icons"),
    83: ("acme/rocket", "dock-icons", "dock-badges", 22, 3, "Dock - Badge the icons"),
    90: ("acme/lander", "rail-model", "rail-store", 21, 1, "Lander - Keep rails in the store"),
}
ORDER = [61, 62, 63, 64, 70, 81, 82, 83, 90]
STATE = {n: "open" for n in PR}
STAMPS = {n: "2026-11-10T09:00:00Z" for n in PR}
LAG = set()
HITS = {}
OPEN = '<svg aria-label="Open pull request" class="octicon octicon-git-pull-request fgColor-open" width="16" height="16"></svg>'
PASS = '<svg aria-label="All checks have passed" class="octicon octicon-check" width="12" height="12"></svg>'


def url(n):
    return f"https://github.com/{PR[n][0]}/pull/{n}"


def listed():
    return [n for n in ORDER if STATE[n] == "open" or n in LAG]


def list_page():
    rows = "".join(
        f'<li class="listItem"><h3><a href="{url(n)}" data-testid="listitem-title-link"><span>{PR[n][5]}</span></a></h3>'
        f'<div><div class="leadingElement">{OPEN}</div><span>#{n}</span>'
        f'<a data-testid="author-filter-link" href="/{PR[n][0]}/pulls?q=author%3Aocto-sam">octo-sam</a>'
        f'<span>Review required</span><span>{PASS}</span></div></li>' for n in listed())
    blob = json.dumps({"payload": {"pullRequestsIndex": {"results": {"items": [
        {"number": n, "permalink": url(n), "updatedAt": STAMPS[n] if n not in LAG else "2026-11-10T09:00:00Z"} for n in listed()]}}}})
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title><body><ul role="list">{rows}</ul>'
            f'<script type="application/json" data-target="react-app.embeddedData">{blob}</script>').encode()


def pull_page(n):
    repo, base, head, stack, position, title = PR[n]
    state = STATE[n]
    status = {"open": "pullOpened", "merged": "pullMerged"}[state]
    owner, name = repo.split("/")
    pull = {"baseBranch": base, "headBranch": head, "headRepositoryName": name, "headRepositoryOwnerLogin": owner,
            "number": n, "state": state.upper(), "title": title}
    others = [m for m in ORDER if m != n and stack and PR[m][0] == repo and PR[m][3] == stack]
    members = [{"number": m, "state": STATE[m].upper()} for m in others]
    blob = json.dumps({"stack": {"number": stack, "position": position, "pullRequests": members} if stack else None, "pullRequest": pull})
    listed = "".join(f'<li><span data-component="StateLabel" data-status="{ {"open": "pullOpened", "merged": "pullMerged"}[STATE[m]] }">'
                     f'{STATE[m].title()}</span> #{m}</li>' for m in others)
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>{title} · Pull Request #{n} · {repo}</title><body>'
            f'<ul class="stack">{listed}</ul>'
            f'<div data-component="PageHeader.Description"><span data-component="StateLabel" data-status="{status}">{state.title()}</span></div>'
            f'<script type="application/json" data-target="react-app.embeddedData">{blob}</script>').encode()


class Fake(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, body=b"", kind="text/html"):
        self.send_response(status)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/github/page/pulls":
            return self.send(200, list_page())
        parts = path.split("/")
        if len(parts) == 7 and parts[1:3] == ["github", "page"] and parts[5] == "pull" and parts[6].isdigit():
            n = int(parts[6])
            if n in PR and "/".join(parts[3:5]) == PR[n][0]:
                HITS[n] = HITS.get(n, 0) + 1
                return self.send(200, pull_page(n))
        if path.startswith("/home"):
            return self.send(200, b"<!doctype html><title>A page</title><body style='font:15px -apple-system;padding:40px'><h2>A page</h2>")
        self.send(404, b"Not Found")


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


srv = Loopback6(("::1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://[::1]:{srv.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def prs(st=None):
    st = st or live()
    return next((f for f in st["folders"] if f["name"] == "PRs"), None)


def rows(st=None):
    found = prs(st)
    return {int(i["url"].rsplit("/", 1)[1]): i for i in found["items"]} if found else {}


def merge(*numbers):
    for n in numbers:
        STATE[n] = "merged"
        STAMPS[n] = "2026-11-16T12:00:00Z"


def read():
    return rows(live("update", "PRs"))


def start():
    sv.use("merged-stack-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", BASE], check=True)
    sv.launch()


def filled():
    live("add-page", "PRs", "pullRequests", PULLS)
    live("unfold", "PRs")
    found = read()
    for _ in range(20):
        if " 4/4" in (found.get(64) or {}).get("byline", ""):
            break
        time.sleep(1)
        found = read()
    return found


def checks():
    start()
    try:
        found = filled()
        print("    bylines:", {n: i["byline"] for n, i in found.items()}, flush=True)
        t.ok("the folder reads the fake with github.com rows and both stacks",
             sorted(found) == sorted(PR) and found[64]["byline"].startswith("octo-sam 4/4") and found[61]["byline"].startswith("octo-sam 1/4")
             and found[83]["byline"].startswith("octo-sam 3/3"), {n: i["byline"] for n, i in found.items()})

        merge(61, 62, 63)
        now = rows(live("merged", url(63)))
        t.ok("#63 turns Merged at once, the one in front", now[63]["label"] == "Merged" and now[63]["merging"], now[63])
        time.sleep(0.45)
        now = rows()
        t.ok("#62 and #61 below it turn Merged too",
             all(now[n]["label"] == "Merged" and now[n]["merging"] for n in (61, 62)), {n: now[n] for n in (61, 62)})
        t.ok("they wait for a read to confirm them, #63 does not", now[61].get("claimed") and now[62].get("claimed") and not now[63].get("claimed"),
             {n: now[n].get("claimed") for n in (61, 62, 63)})
        t.ok("#64 above it stays open", now[64]["label"] != "Merged" and not now[64]["merging"], now[64])
        t.ok("#90 in another repository with the same stack number stays", now[90]["label"] != "Merged", now[90])
        t.ok("#70 on its own stays", now[70]["label"] != "Merged", now[70])
        time.sleep(2.4)
        now = rows()
        t.ok("after the hold the three have left together and #64 stays", not ({61, 62, 63} & set(now)) and 64 in now, sorted(now))
        t.ok("#64 is a stack of one now, no longer 4/4", "/" not in now[64]["byline"], now[64]["byline"])

        LAG.update({61, 62, 63})
        HITS.clear()
        now = read()
        t.ok("a read that still lists them open, as search lags, leaves them out while their pages say merged",
             not ({61, 62, 63} & set(now)), sorted(now))
        t.ok("their own pages were read again for it", all(HITS.get(n) for n in (61, 62)), HITS)
        LAG.clear()
        now = read()
        t.ok("the next read without them keeps them gone", not ({61, 62, 63} & set(now)) and 64 in now, sorted(now))

        merge(82)
        live("merged", url(82))
        time.sleep(0.45)
        now = rows()
        t.ok("#82 merged alone: #81 below it turns too, unconfirmed", now[81]["label"] == "Merged" and now[81].get("claimed"), now[81])
        t.ok("#83 above it stays", now[83]["label"] != "Merged", now[83])
        time.sleep(2.4)
        now = rows()
        t.ok("#81 leaves with #82 after the hold", 81 not in now and 82 not in now, sorted(now))
        HITS.clear()
        now = read()
        t.ok("a read right after the merge that says open does not bring #81 back yet", 81 not in now, sorted(now))
        t.ok("its page was read for it, beside #82's merged state", HITS.get(81), HITS)
        time.sleep(6)
        HITS.clear()
        now = read()
        t.ok("a read once the merge has settled still says open, so #81 comes back as it was",
             81 in now and now[81]["label"] != "Merged" and not now[81]["merging"] and not now[81].get("claimed"), now.get(81))
        t.ok("its page was read for it", HITS.get(81), HITS)
        t.ok("#82 stays gone", 82 not in now, sorted(now))
    finally:
        sv.finish()


if __name__ == "__main__":
    checks()
    t.done()
    sys.exit(1 if t.failed else 0)

#!/usr/bin/env python3
"""A live folder catches up when a pull request's page is reloaded.

Build first (`./build.sh`), then `python3 Tests/stack_catch_up.py`.

A test copy with its own shown window reads a fake signed-in GitHub on ::1
through `integrations.api`, as `merged_stack.py` does. #31 and #32 start
as two pull requests on their own. The fake then joins them into one stack
with their `updatedAt` left as it was, as GitHub may when a stack is
combined, and the page of #32 is loaded again by the person (`live reload`
makes the calls a reload makes: a real github.com page is never opened).
Within a few seconds the folder shows them folded as one stack, 1/2 and
2/2, from one read of each page. A burst of reloads makes no more reads
than one. The folder is pictured before and after, light and dark, from the
window's own number, in .context/stack-catch-up/.
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
WORK = ROOT / ".context" / "stack-catch-up"
SHOT = WORK / "shot"
PR = {
    31: ["main", "wing-frame", None, None, "Wing - Build the frame"],
    32: ["main", "wing-skin", None, None, "Wing - Stretch the skin"],
    33: ["main", "docs-typo", None, None, "Fix a typo in the guide"],
}
ORDER = [31, 32, 33]
STAMP = "2026-11-10T09:00:00Z"
HITS = {}
LISTS = [0]
WHEN = {}
OPEN = '<svg aria-label="Open pull request" class="octicon octicon-git-pull-request fgColor-open" width="16" height="16"></svg>'


def url(n):
    return f"https://github.com/acme/rocket/pull/{n}"


def list_page():
    rows = "".join(
        f'<li class="listItem"><h3><a href="{url(n)}" data-testid="listitem-title-link"><span>{PR[n][4]}</span></a></h3>'
        f'<div><div class="leadingElement">{OPEN}</div><span>#{n}</span>'
        f'<a data-testid="author-filter-link" href="/acme/rocket/pulls?q=author%3Aocto-sam">octo-sam</a>'
        f'<span>Review required</span></div></li>' for n in ORDER)
    blob = json.dumps({"payload": {"pullRequestsIndex": {"results": {"items": [
        {"number": n, "permalink": url(n), "updatedAt": STAMP} for n in ORDER]}}}})
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title><body><ul role="list">{rows}</ul>'
            f'<script type="application/json" data-target="react-app.embeddedData">{blob}</script>').encode()


def pull_page(n):
    base, head, stack, position, title = PR[n]
    pull = {"baseBranch": base, "headBranch": head, "headRepositoryName": "rocket", "headRepositoryOwnerLogin": "acme",
            "number": n, "state": "OPEN", "title": title}
    members = [{"number": m, "state": "OPEN"} for m in ORDER if m != n and stack and PR[m][2] == stack]
    blob = json.dumps({"stack": {"number": stack, "position": position, "pullRequests": members} if stack else None, "pullRequest": pull})
    return (f'<!doctype html><meta name="user-login" content="octo-sam"><title>{title} · Pull Request #{n} · acme/rocket</title><body>'
            f'<div data-component="PageHeader.Description"><span data-component="StateLabel" data-status="pullOpened">Open</span></div>'
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
        path = self.path.split("?")[0]
        if path == "/github/page/pulls":
            LISTS[0] += 1
            return self.send(200, list_page())
        parts = path.split("/")
        if len(parts) == 7 and parts[1:3] == ["github", "page"] and parts[3:5] == ["acme", "rocket"] and parts[5] == "pull" \
                and parts[6].isdigit() and int(parts[6]) in PR:
            n = int(parts[6])
            HITS[n] = HITS.get(n, 0) + 1
            WHEN.setdefault(n, time.monotonic())
            return self.send(200, pull_page(n))
        self.send(404, b"Not Found")


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


srv = Loopback6(("::1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://[::1]:{srv.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def rows(st=None):
    st = st or live()
    found = next((f for f in st["folders"] if f["name"] == "PRs"), None)
    return {int(i["url"].rsplit("/", 1)[1]): i for i in found["items"]} if found else {}


def chips(found):
    out = {}
    for n, item in found.items():
        words = item.get("byline", "").split()
        out[n] = next((w for w in words if "/" in w and w.replace("/", "").isdigit()), "-")
    return out


def launch():
    sv.use("stack-catch-up-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", BASE], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    return next(iter(sv.holding() & sv.running()))


def take(pid, number, name):
    for theme in ["light", "dark"]:
        sv.cmd({"do": "ui", "look": theme})
        time.sleep(0.9)
        still = WORK / f"{name}-{theme}-whole.png"
        out = subprocess.run([str(SHOT), str(pid), str(number), str(still)], capture_output=True, text=True).stdout.strip()
        if not still.exists():
            t.ok(f"a picture {name} {theme}", False, out)
            continue
        width = subprocess.run(["sips", "-g", "pixelWidth", str(still)], capture_output=True, text=True).stdout.split()[-1]
        k = max(1, round(int(width) / 1000)) if width.isdigit() else 2
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", f"crop={320 * k}:{420 * k}:0:0",
                        str(WORK / f"{name}-{theme}.png")], check=True, stdin=subprocess.DEVNULL)
        print("   ", WORK / f"{name}-{theme}.png", flush=True)


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    pid = launch()
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})
        live("add-page", "PRs", "pullRequests", PULLS)
        live("unfold", "PRs")
        found = rows(live("update", "PRs"))
        for _ in range(20):
            if sorted(found) == ORDER:
                break
            time.sleep(1)
            found = rows(live("update", "PRs"))
        t.ok("the folder reads the three pull requests on their own", sorted(found) == ORDER and chips(found) == {31: "-", 32: "-", 33: "-"},
             {n: i.get("byline") for n, i in found.items()})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1)
        take(pid, number, "before")

        PR[31][2:4] = [9, 1]
        PR[32][0] = "wing-frame"
        PR[32][2:4] = [9, 2]
        HITS.clear()
        WHEN.clear()
        lists = LISTS[0]
        began = time.monotonic()
        live("reload", url(32))
        found = rows()
        while time.monotonic() - began < 8 and chips(found) != {31: "1/2", 32: "2/2", 33: "-"}:
            time.sleep(0.2)
            found = rows()
        took = time.monotonic() - began
        print(f"    folded after {took:.1f} s, page reads {dict(HITS)} at {({n: round(at - began, 1) for n, at in WHEN.items()})} s, "
              f"list reads {LISTS[0] - lists}", flush=True)
        t.ok("within a few seconds of the reload the two fold as one stack", chips(found) == {31: "1/2", 32: "2/2", 33: "-"} and took < 8,
             (round(took, 1), chips(found)))
        t.ok("from one read of each page, the one reloaded and the other member", HITS == {31: 1, 32: 1}, HITS)

        time.sleep(6)
        HITS.clear()
        for _ in range(5):
            live("reload", url(32))
            time.sleep(0.3)
        time.sleep(3)
        print(f"    a burst of five reloads: page reads {dict(HITS)}", flush=True)
        t.ok("a burst of reloads makes one read", HITS == {32: 1}, HITS)

        time.sleep(16)
        print(f"    list reads since the first reload: {LISTS[0] - lists}", flush=True)
        t.ok("the list is read at most twice in the half minute after", LISTS[0] - lists <= 2, LISTS[0] - lists)
        found = rows()
        t.ok("the stack holds after the list is read again", chips(found) == {31: "1/2", 32: "2/2", 33: "-"}, chips(found))
        take(pid, number, "after")
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
    t.done()
    sys.exit(1 if t.failed else 0)

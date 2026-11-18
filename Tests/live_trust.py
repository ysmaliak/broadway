#!/usr/bin/env python3
"""A live folder changes only on what Broadway knows, and says by its cause what is wrong.

Build first (`./build.sh`), then `python3 Tests/live_trust.py [SHOTS_DIR]`.
The app starts hidden in a world of its own (live-trust-<checkout>). A
server on ::1 serves one invented pull request list, and between reads it
turns: the list, a server error, an empty page with no "nothing here"
marker, a 429 with Retry-After, a 403 rate-limit page, then the list again
with one more row. After each step the probe reads the folder through the
bench: its rows, its note, its age and that every tab it had is still
there. Nothing that failed may take a row or a tab.

With SHOTS_DIR, a GitHub folder that is never read is given invented rows
and then each state in turn (offline, limited, couldn't read, old, more on
the site) and pictured light and dark. The app draws its own window
offscreen (`picture`), so the world stays hidden, and glass shows without
what would be behind it.
"""
import shutil
import socket
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("live-trust")
sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
SHOTS = next((Path(a) for a in sys.argv[1:] if not a.startswith("--")), None)
t = sv.T()

MODE = {"page": "list"}
ROWS = [(36, "Add the recorder model", "sam"), (37, "Add the recorder view", "sam"), (41, "Cache the build graph", "dana")]
HEAD = '<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title>'


def row(number, title, author):
    return (f'<li class="js-issue-row"><a href="/octocorp/ios/pull/{number}">{title}</a>'
            f'<span>#{number} opened today by <a data-testid="author-filter-link" href="/{author}">{author}</a></span></li>')


class Site(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, body=b"", headers=()):
        self.send_response(status)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.path.startswith("/trust/pulls"):
            return self.send(200, b"<!doctype html><title>Home</title><h2>Home</h2>")
        page = MODE["page"]
        if page == "error":
            return self.send(500, b"<!doctype html><title>Server error</title><h1>Something went wrong</h1>")
        if page == "empty":
            return self.send(200, (HEAD + "<main></main>").encode())
        if page == "limit":
            return self.send(429, b"<!doctype html><title>Too many requests</title><h1>Too many requests</h1>", [("retry-after", "600")])
        if page == "limit-page":
            return self.send(403, b"<!doctype html><title>Rate limit</title><h1>You have exceeded a secondary rate limit</h1>")
        rows = ROWS + ([(52, "Retry uploads on 502", "lee")] if page == "again" else [])
        return self.send(200, (HEAD + "<ul>" + "".join(row(*r) for r in rows) + "</ul>").encode())


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


site = Loopback6(("::1", 0), Site)
threading.Thread(target=site.serve_forever, daemon=True).start()
SITE = f"http://[::1]:{site.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder(st, name):
    return next((f for f in st["folders"] if f["name"] == name), None)


def shoot(name):
    if not SHOTS:
        return
    drawn = Path(tempfile.mkdtemp()) / f"{name}.png"
    got = sv.cmd({"do": "picture", "path": str(drawn), "page": False})
    if drawn.exists():
        shutil.move(str(drawn), SHOTS / f"{name}.png")
    drawn.parent.rmdir()
    t.ok(f"pictured {name}", (SHOTS / f"{name}.png").exists(), got)


def steps():
    print("— a folder reads a list that turns")
    live("add-page", "Trust", "pullRequests", f"{SITE}/trust/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")
    live("unfold", "Trust")
    MODE["page"] = "list"
    first = folder(live("update", "Trust"), "Trust")
    titles = [i["title"] for i in first["items"]]
    tabs = [x["id"] for x in first["tabs"]]
    t.ok("the list reads three rows", first["state"] == "fine" and len(titles) == 3, (first["state"], titles))
    t.ok("each row is a tab", len(tabs) == 3, first["tabs"])
    t.ok("a fresh read shows no age and no note", first["age"] == "" and first["note"] == "", (first["age"], first["note"]))

    def kept(st, step):
        got = folder(st, "Trust")
        t.ok(f"{step}: every row stays", [i["title"] for i in got["items"]] == titles, [i["title"] for i in got["items"]])
        t.ok(f"{step}: every tab stays", [x["id"] for x in got["tabs"]] == tabs, got["tabs"])
        t.ok(f"{step}: no age while the last good read is new", got["age"] == "", got["age"])
        return got

    MODE["page"] = "error"
    got = kept(live("update", "Trust"), "a server error")
    t.ok("a server error is a failed read said as Couldn't read", got["state"] == "failed" and got["failure"].startswith("Couldn't read"),
         (got["state"], got["cause"], got["failure"]))
    t.ok("folded, it says Can't read", got["status"] == "Can't read", got["status"])

    MODE["page"] = "empty"
    began = time.time()
    got = kept(live("update", "Trust"), "an empty page with no marker")
    t.ok("an empty page with no marker is read again before it is judged", time.time() - began >= 2, round(time.time() - began, 1))
    t.ok("and twice empty without a marker it is a failed read, never an empty list",
         got["state"] == "failed" and got["cause"] == "unread", (got["state"], got["cause"], got["failure"]))

    MODE["page"] = "limit"
    got = kept(live("update", "Trust"), "a 429")
    t.ok("a 429 is a limit, never a sign-out", got["state"] == "failed" and got["cause"] == "limited", (got["state"], got["cause"]))
    t.ok("its words give the wait from Retry-After", got["failure"].endswith("is limiting requests. Trying again in 10 minutes."), got["failure"])
    t.ok("folded, it says Limited", got["status"] == "Limited", got["status"])

    MODE["page"] = "limit-page"
    got = kept(live("update", "Trust"), "a 403 limit page")
    t.ok("a 403 limit page is a limit too", got["state"] == "failed" and got["cause"] == "limited", (got["state"], got["cause"], got["failure"]))

    MODE["page"] = "again"
    got = folder(live("update", "Trust"), "Trust")
    now = [i["title"] for i in got["items"]]
    t.ok("the list again is believed at once", got["state"] == "fine" and got["note"] == "" and got["cause"] == "", (got["state"], got["note"], got["cause"]))
    t.ok("the three rows stay and the new one arrives", all(x in now for x in titles) and "Retry uploads on 502" in now, now)
    t.ok("every earlier tab is still there", all(x in [y["id"] for y in got["tabs"]] for x in tabs), got["tabs"])
    live("remove", "Trust")


def pictures():
    print("— a GitHub folder in each state")
    live("add", "PRs", "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me+archived%3Afalse")
    live("unfold", "PRs")
    sv.cmd({"do": "window"})
    words = {
        "offline": ("failure", "You're offline"),
        "limited": ("failure", "GitHub is limiting requests. Trying again in 10 minutes."),
        "unread": ("failure", "Couldn't read GitHub"),
        "old": ("age", "Read 3 hours ago"),
        "more": ("more", "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me+archived%3Afalse"),
    }
    for look in ("light", "dark"):
        sv.cmd({"do": "ui", "look": look})
        time.sleep(0.9)
        for state, (field, wanted) in words.items():
            live("force", "PRs", "rows")
            got = folder(live("force", "PRs", state), "PRs")
            t.ok(f"{look}: {state} says {wanted}", got[field] == wanted, (got[field], got["state"], got["status"]))
            t.ok(f"{look}: {state} keeps its three rows", len(got["items"]) == 3 and len(got["tabs"]) == 3, (len(got["items"]), len(got["tabs"])))
            time.sleep(0.7)
            shoot(f"live-trust-{state}-{look}")
    live("remove", "PRs")


def main():
    if SHOTS:
        SHOTS.mkdir(parents=True, exist_ok=True)
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    sv.launch()
    try:
        sv.cmd({"do": "open", "url": f"{SITE}/home"})
        steps()
        pictures()
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

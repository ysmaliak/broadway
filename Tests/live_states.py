#!/usr/bin/env python3
"""What an open live folder shows in each state, against a signed-out fake.

Build first (`./build.sh`), then `python3 Tests/live_states.py [SHOTS_DIR]`.
The app starts hidden in a world of its own (live-states-<checkout>) with no
sign-ins. A server on 127.0.0.1 answers the way GitHub answers someone
signed out: a personal list sends you to /login, a private repository is a
404 page with an empty user-login, a dashboard can be a bare 404, and a
signed-in list can be empty. The folders in the pictures are only given a
state (`live force`), never asked to read. The PR rows themselves are
Tests/pr_rows.py's, read from a signed-in page.

The single sign-on world (`sso()`) is a PRs folder that reads a signed-in
list page on a second fake, on ::1 so rows carry no port badge. The page
turns, in order: three PRs; the same list with GitHub's "Single sign-on to
see results in the Octo Corp organization" banner and no rows (the markup
copies Tests/IntegrationFixtures/github-sso-banner.html); signed out (a 302
to /login); the rows again plus one (recovery); and a signed-in list with
no banner and nothing in it. The folder must keep its three PRs under a
"Single sign-on for Octo Corp" note whose link is the banner's, keep them
under "Sign in to GitHub" when signed out, drop the note and refresh on
recovery, and say "No pull requests" only for the real empty list. Between
the two, the sign-on is done: the note's link opens its page in a tab, and
when that tab moves on to the list the folder must stop asking at once and
show it is loading (state `waiting`, no note, the loading bar on its
heading open and folded) while its own read, slowed to LOADS seconds, is
under way. With SHOTS_DIR, the SSO, loading and recovery states are shot
window-only (WindowShot.swift), light and dark.

With SHOTS_DIR, the window is pictured by the app itself (`picture`), for
each state, dark and light; the app stays hidden, so
nothing shows on a screen. The app draws into a temporary folder and the
picture is moved to SHOTS_DIR: a hidden test copy asked to write on another
volume can wait on a permission it never shows.
"""
import os
import shutil
import socket
import tempfile
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("live-states")
sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
SHOTS = next((Path(a) for a in sys.argv[1:] if not a.startswith("--")), None)
t = sv.T()

LOGIN = (b"<!doctype html><meta name=\"user-login\" content=\"\"><title>Sign in</title>"
         b"<form action=/session method=post><input name=login><input type=password name=password></form>")
PRIVATE = (b"<!doctype html><meta name=\"user-login\" content=\"\"><title>Page not found</title>"
           b"<a href=\"/login?return_to=/acme/secret/pulls\">Sign in</a><p>404</p>")
EMPTY = (b"<!doctype html><meta name=\"user-login\" content=\"octo-sam\"><title>Pull requests</title>"
         b"<p>No results matched your search.</p>")


class Fake(BaseHTTPRequestHandler):
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
        if self.path.startswith("/pulls"):
            return self.send(302, headers=[("location", "/login?return_to=" + self.path.replace("?", "%3F"))])
        if self.path.startswith("/login"):
            return self.send(200, LOGIN)
        if self.path.startswith("/acme/secret/pulls"):
            return self.send(404, PRIVATE)
        if self.path.startswith("/issues"):
            return self.send(404, b"Not Found")
        if self.path.startswith("/home"):
            return self.send(200, b"<!doctype html><title>Home</title><body style='font:15px -apple-system;padding:40px'><h2>A page</h2>")
        if self.path.startswith("/signed-in/pulls"):
            return self.send(200, EMPTY)
        self.send(404, b"Not Found")


srv = ThreadingHTTPServer(("127.0.0.1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


MODE = {"page": "rows", "loads": 0.0}
LOADS = 22.0
SSO_URL = "/orgs/octocorp/sso?return_to=%2Fwork%2Fpulls"


def work_row(number, title, author):
    return (f'<li class="js-issue-row"><a href="/octocorp/ios/pull/{number}">{title}</a>'
            f'<span>#{number} opened today by <a data-testid="author-filter-link" href="/{author}">{author}</a></span></li>')


def work_page():
    rows = [(36, "[OCT-35] Field Recording - Add the model", "octo-sam"), (37, "[OCT-35] Field Recording - Add the recorder", "octo-sam"),
            (41, "Cache the build graph", "dana")]
    if MODE["page"] == "back":
        rows.append((52, "Retry uploads on 502", "lee"))
    head = '<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title>'
    if MODE["page"] in ("rows", "back"):
        return (head + "<ul>" + "".join(work_row(*r) for r in rows) + "</ul>").encode()
    if MODE["page"] == "sso":
        return (head + '<div class="js-flash-container"><div class="flash flash-full flash-notice"><div class="px-2">'
                '<div class="flex-auto">Single sign-on to see results in the <strong>Octo Corp</strong> organization</div>'
                f'<a href="{SSO_URL}" class="btn btn-sm">Single sign-on</a></div></div></div>'
                '<main><h3>No results matched your search.</h3></main>').encode()
    return (head + "<main><h3>No results matched your search.</h3></main>").encode()


class Work(BaseHTTPRequestHandler):
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
        if self.path.startswith("/work/pulls"):
            if MODE["loads"] > 0 and "tab=1" not in self.path:
                time.sleep(MODE["loads"])
            if MODE["page"] == "out":
                return self.send(302, headers=[("location", "/login?return_to=%2Fwork%2Fpulls")])
            return self.send(200, work_page())
        if self.path.startswith("/login"):
            return self.send(200, LOGIN)
        if self.path.startswith("/home"):
            return self.send(200, b"<!doctype html><title>Release notes</title><body style='font:15px -apple-system;padding:40px'><h2>Release notes</h2>")
        self.send(404, b"Not Found")


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


work = Loopback6(("::1", 0), Work)
threading.Thread(target=work.serve_forever, daemon=True).start()
WORK = f"http://[::1]:{work.server_port}"
TOOLS = Path(os.environ.get("BROADWAY_PROBE_TOOLS") or Path(__file__).resolve().parents[1] / ".context" / "live-sso-tools")
SHOT = TOOLS / "shot"


def window_shot(name):
    """The test copy's own window only, by its window number (WindowShot.swift)."""
    if not SHOTS:
        return
    if not SHOT.exists():
        TOOLS.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(Path(__file__).resolve().parent / "WindowShot.swift"), "-o", str(SHOT)], check=True)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    time.sleep(0.8)
    pid = next(iter(sv.holding() & sv.running()))
    out = SHOTS / f"{name}.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(out)], capture_output=True, text=True).stdout.strip()
    t.ok(f"pictured {name}", out.exists(), said)


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


def classification():
    print("— reading a signed-out fake")
    cases = [
        ("Fake PRs", "pullRequests", f"{BASE}/pulls?q=is%3Aopen+is%3Apr+review-requested%3A%40me", "signIn", "a personal list sent to /login asks to sign in"),
        ("Fake Private", "repository", f"{BASE}/acme/secret/pulls", "signIn", "a private repository's 404 with an empty user-login asks to sign in"),
        ("Fake Issues", "issues", f"{BASE}/issues?q=is%3Aopen+is%3Aissue+involves%3A%40me", "signIn", "a personal dashboard's bare 404 asks to sign in"),
        ("Fake Empty", "pullRequests", f"{BASE}/signed-in/pulls?q=is%3Aopen+author%3A%40me", "fine", "a signed-in list with nothing in it is fine and empty"),
    ]
    for name, kind, url, _, _ in cases:
        live("add-page", name, kind, url)
    for name, _, _, wanted, said in cases:
        began = time.time()
        got = folder(live("update", name), name)
        t.ok(said, got["state"] == wanted and not got["items"], (got["state"], got["status"], len(got["items"])))
        if wanted == "signIn":
            t.ok(f"{name}: and says so within 3 s", time.time() - began < 3, round(time.time() - began, 1))
    for name, *_ in cases:
        live("remove", name)


def pictures():
    print("— an open PR folder in each state")
    live("add", "PRs", "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
    live("add", "My Issues", "linear:assigned")
    live("add", "Subscriptions", "https://www.youtube.com/feed/subscriptions")
    for name in ("PRs", "My Issues", "Subscriptions"):
        live("unfold", name)
    sv.cmd({"do": "window"})
    for dark in (True, False):
        look = "dark" if dark else "light"
        sv.cmd({"do": "ui", "look": look})
        time.sleep(0.9)
        live("force", "My Issues", "signIn")
        live("force", "Subscriptions", "signIn")
        for state in ("waiting", "signIn", "failed", "fine"):
            st = live("force", "PRs", state)
            t.ok(f"{look}: PRs is {state}", folder(st, "PRs")["state"] == state, folder(st, "PRs")["state"])
            time.sleep(0.6)
            shoot(f"live-{state}-{look}")


def sso():
    print("— single sign-on keeps the last PRs")
    sv.use("live-sso")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    sv.launch()
    try:
        sv.cmd({"do": "open", "url": f"{WORK}/home"})
        live("add-page", "PRs", "pullRequests", f"{WORK}/work/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")
        live("unfold", "PRs")
        MODE["page"] = "rows"
        prs = folder(live("update", "PRs"), "PRs")
        before = [i["title"] for i in prs["items"]]
        t.ok("the folder reads three PRs", prs["state"] == "fine" and len(before) == 3, prs)

        MODE["page"] = "sso"
        prs = folder(live("update", "PRs"), "PRs")
        t.ok("the banner with no rows is single sign-on, not empty", prs["state"] == "signIn" and prs["sso"] == WORK + SSO_URL,
             (prs["state"], prs["sso"], prs["note"]))
        t.ok("and names the organisation", prs["ssoOrg"] == "Octo Corp" and prs["status"] == "Single sign-on", (prs["ssoOrg"], prs["status"]))
        t.ok("the three PRs stay, as tabs", [i["title"] for i in prs["items"]] == before and len(prs["tabs"]) == 3, prs["items"])
        t.ok("the note is single sign-on, never No pull requests", prs["note"].startswith("sso("), prs["note"])
        sv.cmd({"do": "window"})
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(1.2)
            window_shot(f"live-sso-{look}")
        folded_sign_in()
        signed_on(False)
        signed_on(True)

        MODE["page"] = "out"
        prs = folder(live("update", "PRs"), "PRs")
        t.ok("signed out keeps the PRs under Sign in", prs["state"] == "signIn" and prs["note"] == "signIn" and prs["sso"] == ""
             and [i["title"] for i in prs["items"]] == before, (prs["state"], prs["note"], len(prs["items"])))
        live("fold", "PRs")
        time.sleep(0.6)
        h = live("heading", "PRs")
        t.ok("folded and signed out, the heading says Sign in", h.get("pill") and h.get("title") == "Sign in" and not h.get("chip"), h)

        MODE["page"] = "back"
        prs = folder(live("update", "PRs"), "PRs")
        time.sleep(0.6)
        h = live("heading", "PRs")
        t.ok("read fine again, the folded heading drops the button and shows its count", not h.get("pill") and h.get("chip"), h)
        live("unfold", "PRs")
        sv.cmd({"do": "ui", "sideWidth": 258})
        time.sleep(0.6)
        t.ok("recovery drops the note and refreshes the PRs", prs["state"] == "fine" and prs["note"] == "" and prs["sso"] == ""
             and len(prs["items"]) == 4 and len(prs["tabs"]) == 4, (prs["state"], prs["note"], [i["title"] for i in prs["items"]]))
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(1.2)
            window_shot(f"live-sso-recovered-{look}")

        MODE["page"] = "empty"
        prs = folder(live("update", "PRs"), "PRs")
        t.ok("a good read that is really empty says No pull requests", prs["state"] == "fine" and prs["note"] == "empty"
             and not prs["items"], (prs["state"], prs["note"], len(prs["items"])))
    finally:
        sv.finish()


def signed_on(folded):
    shape = "folded" if folded else "open"
    print(f"— once the sign-on is done, the folder loads ({shape})")
    MODE["page"] = "sso"
    asks = folder(live("update", "PRs"), "PRs")
    t.ok(f"{shape}: the folder asks again", asks["state"] == "signIn" and asks["note"].startswith("sso("), (asks["state"], asks["note"]))
    if folded:
        live("fold", "PRs")
    MODE["page"] = "rows"
    MODE["loads"] = LOADS
    try:
        live("sign-in", "PRs")
        page = None
        until = time.time() + 10
        while time.time() < until and page is None:
            page = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if "/orgs/octocorp/sso" in x["url"]), None)
            time.sleep(0.1)
        t.ok(f"{shape}: the folder's sign-in opens the sign-on page", page is not None, page)
        if page is None:
            return
        time.sleep(0.8)
        sv.cmd({"do": "eval", "id": page["id"], "js": f"location.href = {WORK + '/work/pulls?q=is%3Aopen&tab=1'!r}; 1"})
        prs = None
        until = time.time() + 5
        while time.time() < until:
            prs = folder(live(), "PRs")
            if prs["state"] == "waiting":
                break
            time.sleep(0.05)
        t.ok(f"{shape}: the tab leaving the sign-on page stops the asking at once", prs["state"] == "waiting" and prs["note"] == ""
             and prs["status"] == "" and prs["sso"] == "", (prs["state"], prs["note"], prs["status"]))
        t.ok(f"{shape}: the three PRs stay in place while it loads", len(prs["items"]) == 3, len(prs["items"]))
        time.sleep(0.6)
        h = live("heading", "PRs")
        x, _, w, _ = h.get("loadingFrame", [0, 0, 0, 0])
        t.ok(f"{shape}: the loading bar right of the name, no button, spoken as loading",
             h.get("loading") is True and not h.get("pill") and h.get("spoken") == "Loading PRs"
             and x >= h.get("nameEnd", 1e9) and x + w <= h.get("width", 0), h)
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(1.0)
            window_shot(f"live-sso-loading-{shape}-{look}")
        t.ok(f"{shape}: still loading after the shots", folder(live(), "PRs")["state"] == "waiting", folder(live(), "PRs")["state"])
        until = time.time() + LOADS + 30
        while time.time() < until and folder(live(), "PRs")["state"] != "fine":
            time.sleep(0.2)
        prs = folder(live(), "PRs")
        t.ok(f"{shape}: the read answers with the rows", prs["state"] == "fine" and len(prs["items"]) == 3, (prs["state"], len(prs["items"])))
        h = live("heading", "PRs")
        t.ok(f"{shape}: and the bar is gone", not h.get("loading"), h)
        if folded:
            live("unfold", "PRs")
        time.sleep(0.4)
    finally:
        MODE["loads"] = 0.0


def folded_sign_in():
    print("— a folded folder that asks for single sign-on keeps its button")
    live("fold", "PRs")
    for width in (245, 200):
        sv.cmd({"do": "ui", "sideWidth": width})
        time.sleep(0.8)
        h = live("heading", "PRs")
        x, y, w, hgt = h.get("pillFrame", [0, 0, 0, 0])
        t.ok(f"{width} pt: the folded heading shows the sign-in button", h.get("pill") is True, h)
        t.ok(f"{width} pt: in place of the count", h.get("chip") is False, h)
        t.ok(f"{width} pt: inside the heading, right of the name", w > 0 and x >= h.get("nameEnd", 1e9) and x + w <= h.get("width", 0), h)
        t.ok(f"{width} pt: spoken as the single sign-on", h.get("label") == "Single sign-on for Octo Corp" and h.get("tip") == "Single sign-on for Octo Corp", h)
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(1.2)
            window_shot(f"live-sso-folded-{width}-{look}")
    sv.cmd({"do": "ui", "sideWidth": 245})
    live("unfold", "PRs")
    time.sleep(0.6)


def main():
    if SHOTS:
        SHOTS.mkdir(parents=True, exist_ok=True)
    if "--sso" in sys.argv:
        sso()
        shutil.rmtree(TOOLS, ignore_errors=True)
        t.done()
        sys.exit(1 if t.failed else 0)
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    sv.launch()
    try:
        pictures()
        for name in ("PRs", "My Issues", "Subscriptions"):
            live("remove", name)
        classification()
    finally:
        sv.finish()
    sso()
    shutil.rmtree(TOOLS, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

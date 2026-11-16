#!/usr/bin/env python3
"""GitHub and Linear with the space's sign-in only, in a hidden probe against fixtures.

Build first (`./build.sh`), then run `python3 Tests/integrations.py [SHOTS_DIR]`.
Broadway takes no API key or token. The app starts hidden in worlds of its own
and never touches github.com, linear.app or anyone's account:

- signed in: `integrations.api` points the Linear session at a server on
  127.0.0.1 that answers like Linear (availableUsers with the cookie alone,
  any other query only with the user and organization headers it handed
  out). The Linear folders first find no linear.app cookie and ask to sign
  in without a request; then the probe plants a fake cookie. The GitHub
  folder reads pr_rows' signed-in pull request page and a notifications
  page here. No request may carry an Authorization header. Settings, the
  field and the `broadway` command are asked for anything about a key.
- retired: a world is saved with three live folders, then its
  live-folders.json is rewritten as an older Broadway would have left it:
  a GitLab Merge Requests folder and a Vercel Deployments folder, and a
  GitHub folder whose state is the retired "connect". Opened again, the two
  retired folders are ordinary folders that keep their tabs, and the GitHub
  folder still reads. With SHOTS_DIR the probe's own window is pictured.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/IntegrationFixtures"
BROADWAY = str(ROOT / "build/Broadway.app/Contents/Helpers/broadway")
OPENROUTER = "groups.openrouter"
KEY_WORDS = ("token", "api key", "personal access", "openrouter", "gitlab", "vercel", "jev", "keychain item")

seen = []
github = []
SESSION = "fixture-session"
USERS = [{"id": "u-north", "organization": {"id": "o-north", "urlKey": "north"}},
         {"id": "u-acme", "organization": {"id": "o-acme", "urlKey": "acme"}}]
NO_USER = {"errors": [{"message": "Authentication required, no user context",
                       "extensions": {"type": "authentication error", "code": "AUTHENTICATION_ERROR"}}]}
state = {"later": False, "session_refuses": False}
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


def noted(self):
    github.append({"path": self.path, "auth": self.headers.get("authorization", "")})
    return plain(self)


plain = pr.Fake.do_GET
pr.Fake.do_GET = noted


def feed(base, name):
    entries = "".join(
        f"<entry><title>{name} {n}</title><link href=\"{base}/post/{name}-{n}\"/><id>{name}-{n}</id>"
        f"<updated>2026-11-0{n}T10:00:00Z</updated></entry>" for n in (1, 2))
    return f"<?xml version=\"1.0\"?><feed xmlns=\"http://www.w3.org/2005/Atom\"><title>{name}</title>{entries}</feed>".encode()


NOTIFICATIONS = b"""<!doctype html><meta name="user-login" content="octo-sam"><title>Notifications</title><body><ul>
<li><a href="/acme/rocket/pull/412">Retry uploads on 502</a></li>
<li><a href="/acme/rocket/issues/400">Uploads stall at 99%</a></li>
<li><a href="/acme/rocket/releases">Releases</a></li></ul>"""


class Fixtures(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, body, kind="application/json", status=200):
        self.send_response(status)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def answer(self, name, status=200):
        self.send((FIXTURES / f"{name}.json").read_bytes(), status=status)

    def json(self, payload, status=200):
        self.send(json.dumps(payload).encode(), status=status)

    def session(self, body):
        if f"session={SESSION}" not in self.headers.get("cookie", ""):
            return self.json(NO_USER, 401)
        if "availableUsers" in body:
            return self.json({"data": {"availableUsers": {"users": USERS}}})
        pair = (self.headers.get("user"), self.headers.get("organization"))
        if state["session_refuses"] or pair not in [(u["id"], u["organization"]["id"]) for u in USERS]:
            return self.json(NO_USER, 401)
        if "assignedIssues" in body:
            return self.answer("linear-assigned-later" if state["later"] else "linear-assigned")
        if "notifications" in body:
            return self.answer("linear-inbox")
        if "activeCycle" in body:
            return self.answer("linear-cycle")
        return self.json(NO_USER, 401)

    def note(self, body=""):
        seen.append({"method": self.command, "path": self.path, "auth": self.headers.get("authorization", ""),
                     "cookie": self.headers.get("cookie", ""), "body": body,
                     "user": self.headers.get("user", ""), "organization": self.headers.get("organization", "")})

    def do_GET(self):
        self.note()
        base = f"http://127.0.0.1:{self.server.server_port}"
        if self.path.startswith("/feed/"):
            return self.send(feed(base, self.path.split("/")[2].split(".")[0]), "application/atom+xml")
        if self.path.startswith("/notifications"):
            return self.send(NOTIFICATIONS, "text/html")
        if self.path.startswith("/post/") or self.path == "/page":
            return self.send(b"<!doctype html><title>A page</title><p>Something to be on", "text/html")
        self.send(b"Not Found", "text/plain", 404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0"))).decode()
        self.note(body)
        if self.path == "/linear-session/graphql":
            return self.session(body)
        self.json(NO_USER, 404)


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder(st, name):
    return next((f for f in st["folders"] if f["name"] == name), None)


def broadway(*words):
    return subprocess.run([BROADWAY, "--world", sv.W, *words], capture_output=True, text=True, timeout=40)


def sessions():
    return [r for r in seen if r["path"] == "/linear-session/graphql"]


def keyed(text):
    low = text.lower()
    return [word for word in KEY_WORDS if word in low]


def signed_in(base):
    print("== signed in")
    sv.use("integ")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "agents.on": True})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", base])
    sv.launch()

    print("— Linear signed out")
    live("add", "My Issues", "linear:assigned")
    st = live("update", "My Issues")
    check("a signed-out Linear folder asks to sign in", folder(st, "My Issues")["status"] == "Sign in", folder(st, "My Issues"))
    check("no cookies, so nothing was sent", seen == [], seen)

    print("— Linear with the space's sign-in")
    live("linear-cookie", SESSION)
    st = live("update", "My Issues")
    mine = folder(st, "My Issues")
    check("signed in on linear.app, My Issues reads", mine["state"] == "fine" and len(mine["items"]) == 2, mine)
    asked = sessions()
    check("first who is asking, then the issues", len(asked) == 2 and "availableUsers" in asked[0]["body"] and "assignedIssues" in asked[1]["body"], [r["body"][:60] for r in asked])
    check("the question goes with the cookie alone", asked[0]["cookie"] == f"session={SESSION}" and not asked[0]["user"] and not asked[0]["organization"], asked[0])
    check("the issues go with the first user, the folder naming no workspace", (asked[1]["user"], asked[1]["organization"]) == ("u-north", "o-north"), asked[1])
    check("each row says its key and state", [i["byline"] for i in mine["items"]] == ["ENG-231 • In Progress", "ENG-198 • Todo"], mine["items"])
    check("each row is a sleeping tab in the folder", len(mine["tabs"]) == 2 and all(t["asleep"] for t in mine["tabs"]), mine["tabs"])
    check("nothing in Now from the backlog", not [r for r in st["now"] if "Assigned" in r[1]], st["now"])
    live("update", "My Issues")
    check("a second refresh is one request", len(sessions()) == 3, len(seen))
    state["later"] = True
    st = live("update", "My Issues")
    mine = folder(st, "My Issues")
    check("a newly assigned issue joins, in the order of its status", [i["byline"] for i in mine["items"]] == ["ENG-231 • In Review", "ENG-240 • Todo", "ENG-198 • Todo"], mine["items"])
    check("Now offers the new one", ["Add a CSV download to reports", "Assigned to you · ENG-240"] in [r[:2] for r in st["now"]], st["now"])
    live("add", "Acme Inbox", "https://linear.app/acme/inbox")
    st = live("update", "Acme Inbox")
    asked = sessions()
    check("a folder in a workspace reads as that workspace's user", folder(st, "Acme Inbox")["state"] == "fine" and (asked[-1]["user"], asked[-1]["organization"]) == ("u-acme", "o-acme"), asked[-1])
    live("remove", "Acme Inbox")
    live("add", "Mentions", "linear:mentions")
    live("add", "ENG Cycle", "linear:cycle/eng")
    st = live("update", "Mentions")
    check("Mentions keeps mentions", [i["byline"] for i in folder(st, "Mentions")["items"]] == ["DES-12 • Mention", "ENG-231 • Mention"], folder(st, "Mentions"))
    st = live("update", "ENG Cycle")
    check("a team's cycle reads", len(folder(st, "ENG Cycle")["items"]) == 2, folder(st, "ENG Cycle"))
    state["session_refuses"] = True
    before = len(sessions())
    st = live("update", "My Issues")
    asked = sessions()[before:]
    check("a refused sign-in asks who again once, then says Sign in", folder(st, "My Issues")["status"] == "Sign in" and ["availableUsers" in r["body"] for r in asked] == [False, True, False], [r["body"][:40] for r in asked])
    check("and keeps the rows it had", len(folder(st, "My Issues")["items"]) == 3, folder(st, "My Issues"))
    state["session_refuses"] = False
    check("Linear was only ever asked on its session address", all(r["path"] == "/linear-session/graphql" for r in seen if r["method"] == "POST"), [r["path"] for r in seen])

    print("— GitHub with the space's sign-in")
    live("add-page", "Pull Requests", "pullRequests", f"{pr.BASE}{pr.PULLS}")
    pulls = folder(live("update", "Pull Requests"), "Pull Requests")
    check("the Pull Requests folder reads the signed-in page", pulls["state"] == "fine" and len(pulls["items"]) == 8, pulls)
    check("rows say who, their stack and where they stand",
          [i["byline"] for i in pulls["items"]] == ["dana", "octo-sam 3/3 • Draft", "octo-sam 2/3 • Changes requested", "octo-sam 1/3 • Approved",
                                                    "octo-sam", "lee • Approved", "dana • Changes requested", ""], [i["byline"] for i in pulls["items"]])
    check("and wear their checks", [i["checks"] for i in pulls["items"]] == ["failing", "pending", "failing", "passing", "passing", "passing", "passing", "pending"],
          [i["checks"] for i in pulls["items"]])
    check("no row says Conflict", all("Conflict" not in i["byline"] and i["label"] != "Conflict" for i in pulls["items"]), pulls["items"])
    check("each row is a tab in the folder", len(pulls["tabs"]) == 8, pulls["tabs"])
    live("add-page", "Notifications", "notifications", f"{base}/notifications")
    threads = folder(live("update", "Notifications"), "Notifications")
    check("a notifications page gives its pull requests and issues", threads["state"] == "fine" and [i["title"] for i in threads["items"]] == ["Retry uploads on 502", "Uploads stall at 99%"], threads)
    check("GitHub's pages were read", any(r["path"].startswith("/signed-in/pulls") for r in github) and any(r["path"].startswith("/notifications") for r in seen), (github[:3], seen[-3:]))
    check("no request anywhere carried an Authorization header", all(not r["auth"] for r in seen + github), [r for r in seen + github if r["auth"]])

    print("— names in the field")
    typed = sv.cmd({"do": "fieldrows", "args": ["type", "acme/rocket#412"]})
    check("owner/repo#N is offered first", typed["rows"][0][3] == "https://github.com/acme/rocket/issues/412", typed["rows"][:2])
    typed = sv.cmd({"do": "fieldrows", "args": ["type", "eng-231"]})
    check("a Linear key is no longer opened by name", all("linear.app" not in r[3] for r in typed["rows"]), typed["rows"])

    print("— the broadway command")
    made = broadway("live", "add", "Inbox", "linear:inbox", "--json")
    check("broadway live add takes linear:inbox", made.returncode == 0, made.stderr or made.stdout)
    for source in ("gitlab:mrs", "vercel:deployments", "vercel:project/web", "github:actions/acme/rocket"):
        refused = broadway("live", "add", "Gone", source, "--json")
        check(f"broadway live add refuses {source}", refused.returncode != 0, refused.stdout[:200])
    names = [f["name"] for f in json.loads(broadway("live", "list", "--json").stdout)["data"]["folders"]]
    check("and none of them made a folder", "Gone" not in names, names)
    helped = broadway("live", "--help").stdout + broadway("help", "live").stdout
    check("the live help names no token, GitLab or Vercel", not keyed(helped), keyed(helped))
    for words in (["token"], ["api", "key"], ["openrouter"], ["gitlab"], ["vercel"]):
        found = broadway("settings", "find", *words, "--json")
        rows = json.loads(found.stdout)["data"] if found.returncode == 0 and found.stdout.strip().startswith("{") else {}
        ids = [row.get("id", "") for row in (rows.get("settings") or rows.get("items") or [])] if isinstance(rows, dict) else []
        check(f"broadway settings find {' '.join(words)} finds no account row", not [i for i in ids if i.startswith("integrations.") or (i.startswith("ai.") and i != OPENROUTER)], found.stdout[:300])
    for gone in ("integrations.gitlab", "integrations.vercel"):
        check(f"broadway settings get {gone} knows no such row", broadway("settings", "get", gone).returncode != 0)

    print("— Settings")
    sv.cmd({"do": "ui", "settingsPage": "accounts"})
    page = sv.cmd({"do": "settings"})
    check("the old Accounts address opens Live Folders", page["settingsPage"] == "livefolders", page.get("settingsPage"))
    check("there is no Accounts page", "accounts" not in page["pages"], page["pages"])
    ids = [i["id"] for i in page["items"]]
    left = [i for i in ids if i.startswith("integrations.") and i != "integrations.now"]
    check("no row is left from Accounts", not left, left)
    check("Show in Now is on Field", any(i["id"] == "integrations.now" and i["page"] == "field" for i in page["items"]), ids)
    check("nothing in Settings is left from the morning brief", not [i for i in ids if i.startswith("brief")], ids)
    wordy = {i["id"]: keyed(i["title"] + " " + i["detail"]) for i in page["items"] if i["page"] in ("tabs", "field", "livefolders") and i["id"] != OPENROUTER}
    check("no row on Tabs, Field or Live Folders names a key", not {k: v for k, v in wordy.items() if v}, {k: v for k, v in wordy.items() if v})
    for words in ("token", "api key", "personal access token", "openrouter", "gitlab", "vercel"):
        found = sv.cmd({"do": "settings", "find": words})["found"]
        check(f"Find a setting: \"{words}\" finds no account row", not [i["id"] for i in found if i["id"] in ("integrations.github", "integrations.linear") or i["page"] == "ai"], [i["id"] for i in found])
    try:
        said = live("connect", "github", "anything")
    except RuntimeError as error:
        said = {"error": str(error)}
    check("the bench has no connect either", "accounts" not in said and "connected" not in said, said)
    sv.finish()


def groups(session, name):
    found = []

    def walk(node):
        if isinstance(node, dict):
            if node.get("name") == name and "collapsed" in node:
                found.append(node)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(session)
    return found


def members(session, identifier):
    count = 0

    def walk(node):
        nonlocal count
        if isinstance(node, dict):
            if "collapsed" not in node and any(isinstance(v, str) and v.upper() == identifier.upper() for v in node.values()):
                count += 1
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(session)
    return count


def retired(base):
    print("== retired folders in a saved session")
    sv.use("integ-old")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", base])
    sv.launch()
    live("add", "Merge Requests", f"{base}/feed/merge.xml")
    live("add", "Deployments", f"{base}/feed/deploys.xml")
    live("add-page", "PRs", "pullRequests", f"{pr.BASE}{pr.PULLS}")
    for name in ("Merge Requests", "Deployments", "PRs"):
        st = live("update", name)
    before = {name: len(folder(st, name)["tabs"]) for name in ("Merge Requests", "Deployments", "PRs")}
    check("the saved world has three live folders with their tabs", before == {"Merge Requests": 2, "Deployments": 2, "PRs": 8}, before)
    time.sleep(1.5)
    sv.quit()
    time.sleep(1)

    path = Path(sv.SUPPORT) / "live-folders.json"
    saved = json.loads(path.read_text())
    ids = {}
    for entry in saved:
        ids[entry["name"]] = entry["id"]
        if entry["name"] == "Merge Requests":
            entry["source"] = {"kind": "mergeRequests", "address": "https://gitlab.com/dashboard/merge_requests"}
            entry["state"] = "connect"
        if entry["name"] == "Deployments":
            entry["source"] = {"kind": "deployments", "address": "https://vercel.com/dashboard"}
            entry["state"] = "fine"
        if entry["name"] == "PRs":
            entry["state"] = "connect"
    path.write_text(json.dumps(saved))
    old = sv.session()
    check("before opening, the session holds them as live folders",
          all(len(groups(old, name)) == 1 and groups(old, name)[0].get("live") for name in ids), {n: groups(old, n) for n in ids})

    sv.launch()
    st = live("state")
    check("it opens, and only the GitHub folder is still a live folder", [f["name"] for f in st["folders"]] == ["PRs"], [f["name"] for f in st["folders"]])
    pulls = folder(live("update", "PRs"), "PRs")
    check("the GitHub folder saved as \"connect\" reads again", pulls["state"] == "fine" and len(pulls["items"]) == 8 and len(pulls["tabs"]) == 8, pulls)
    kept = subprocess.run(["defaults", "read", sv.SUITE, "live.retired"], capture_output=True, text=True).stdout
    check("the two retired ids are remembered for the other windows and spaces", all(ids[n] in kept for n in ("Merge Requests", "Deployments")), kept)
    check("and are gone from live-folders.json", [e["name"] for e in json.loads(path.read_text())] == ["PRs"], path.read_text()[:300])
    if pr.SHOTS:
        sv.cmd({"do": "window"})
        time.sleep(1)
        pr.shoot("no-keys-retired-folders")
    time.sleep(1.5)
    sv.quit()
    time.sleep(1)
    now = sv.session()
    for name in ("Merge Requests", "Deployments"):
        found = groups(now, name)
        check(f"{name} is an ordinary folder now", len(found) == 1 and not found[0].get("live") and not found[0].get("held"), found)
        check(f"and keeps its two tabs", len(found) == 1 and members(now, found[0]["id"]) == 2, (found, members(now, found[0]["id"]) if found else None))
    sv.launch()
    st = live("state")
    check("a second opening changes nothing", [f["name"] for f in st["folders"]] == ["PRs"], [f["name"] for f in st["folders"]])
    sv.finish()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    if pr.SHOTS:
        pr.SHOTS.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixtures)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    for world in (signed_in, retired):
        try:
            world(base)
        except Exception as error:
            check(f"{world.__name__} ran to the end", False, repr(error))
            sv.finish()
        (Path.home() / f"Library/Preferences/{sv.SUITE}.plist").unlink(missing_ok=True)
    failures.extend(["pr_rows helper"] * pr.t.failed)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()

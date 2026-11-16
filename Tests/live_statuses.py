#!/usr/bin/env python3
"""A Linear folder shows only the statuses it chooses, in a hidden probe against an invented Linear.

Build first (`./build.sh`), then run `python3 Tests/live_statuses.py [OUT_DIR]`.
A server on 127.0.0.1 answers like Linear's session API and, like Linear, honours
the folder's `nin` filter on state type. Its invented workspace holds 32 Backlog
issues, all newer than one Triage, one Todo and one In Progress issue, so a
request that did not leave Backlog out would spend its 30 rows on Backlog.

- a new My Issues folder leaves Backlog out, in the request and in its rows
- its settings page has a Statuses section, pictured from the probe's own
  window into OUT_DIR (drawn by the app, no screen recording)
- pressing Backlog there brings Backlog back at once and is kept
- `broadway live statuses` changes the choice, `broadway live show` reads it,
  and a made-up status or a GitHub folder is refused
- a folder whose issues are all left out says so when empty
- the Inbox asks for every status
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
BROADWAY = str(ROOT / "build/Broadway.app/Contents/Helpers/broadway")
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "live-statuses").resolve()
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"live-statuses-{os.getpid()}"
SESSION = "invented-session"
USERS = [{"id": "u-acme", "organization": {"id": "o-acme", "urlKey": "acme"}}]
NO_USER = {"errors": [{"message": "Authentication required", "extensions": {"code": "AUTHENTICATION_ERROR"}}]}

asked = []
failures = []
mode = {"only_backlog": False}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


def issue(key, title, name, kind, minute):
    return {"identifier": key, "title": title, "url": f"https://linear.app/acme/issue/{key}/invented",
            "updatedAt": f"2026-11-0{1 + minute // 1440}T{(minute // 60) % 24:02d}:{minute % 60:02d}:00.000Z",
            "state": {"name": name, "type": kind, "position": 1},
            "comments": {"nodes": []}, "history": {"nodes": []}}


def everything():
    rows = [issue(f"ACM-{100 + n}", f"Someday idea {n}", "Backlog", "backlog", 3000 + n) for n in range(32)]
    if not mode["only_backlog"]:
        rows += [issue("ACM-1", "Sort the new reports", "Triage", "triage", 30),
                 issue("ACM-2", "Draw the export button", "Todo", "unstarted", 20),
                 issue("ACM-3", "Speed up the search page", "In Review", "started", 10)]
    return sorted(rows, key=lambda row: row["updatedAt"], reverse=True)


def answered(query):
    left = re.search(r"nin: \[([^\]]*)\]", query)
    out = {kind.strip().strip('"') for kind in left.group(1).split(",")} if left else set()
    rows = [row for row in everything() if row["state"]["type"] not in out]
    first = re.search(r"Issues\(first: (\d+)", query)
    return rows[: int(first.group(1))] if first else rows


class Linear(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, payload, status=200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", "0"))).decode()
        if self.path != "/linear-session/graphql" or f"session={SESSION}" not in self.headers.get("cookie", ""):
            return self.send(NO_USER, 401)
        query = json.loads(body).get("query", "")
        if "availableUsers" in query:
            return self.send({"data": {"availableUsers": {"users": USERS}}})
        asked.append(query)
        if "assignedIssues" in query:
            return self.send({"data": {"viewer": {"id": "u-acme", "assignedIssues": {"nodes": answered(query)}}}})
        if "notifications" in query:
            return self.send({"data": {"viewer": {"id": "u-acme"}, "notifications": {"nodes": []}}})
        self.send(NO_USER, 401)


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder(st, name):
    return next((f for f in st["folders"] if f["name"] == name), None)


def broadway(*words):
    got = subprocess.run([BROADWAY, "--world", sv.W, *words, "--json"], capture_output=True, text=True, timeout=40)
    try:
        return got.returncode, json.loads(got.stdout or "{}")
    except json.JSONDecodeError:
        return got.returncode, {"raw": got.stdout + got.stderr}


def wait(test, seconds=8):
    end = time.time() + seconds
    while time.time() < end:
        found = test()
        if found:
            return found
        time.sleep(0.25)
    return test()


def picture(name):
    path = OUT / f"{name}.png"
    drawn = TMP / f"{name}.png"
    got = sv.cmd({"do": "picture", "path": str(drawn), "page": False})
    if drawn.exists():
        shutil.copy(drawn, path)
    check(f"the probe's window is pictured as {path.name}", path.exists() and got.get("saved") == str(drawn), got)
    return got


def run(base):
    sv.use("lstat")
    sv.setup(**{"live.on": True, "agents.on": True, "start.fresh": True})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", base])
    sv.launch()
    live("add", "My Issues", "linear:assigned")
    live("linear-cookie", SESSION)

    print("— a new folder leaves Backlog out")
    mine = folder(live("update", "My Issues"), "My Issues")
    check("it chooses Triage, Todo and In Progress", mine["statuses"] == ["triage", "unstarted", "started"], mine["statuses"])
    check("Linear is asked to leave Backlog out", asked and '"backlog"' in asked[-1] and '"completed"' in asked[-1], asked[-1:])
    check("so Backlog uses none of the 30 rows and the three others show",
          [i["title"] for i in mine["items"]] == ["Sort the new reports", "Speed up the search page", "Draw the export button"],
          [i["title"] for i in mine["items"]])

    print("— its settings page")
    sv.cmd({"do": "resize", "width": 1100, "height": 980, "steps": 1})
    sv.cmd({"do": "ui", "settings": True})
    time.sleep(1.2)
    sv.cmd({"do": "ui", "settingsPage": "livefolders"})
    time.sleep(1.2)
    sv.cmd({"do": "ui", "settingsDetail": "livefolder"})
    time.sleep(1.2)
    for status in ("triage", "backlog", "unstarted", "started"):
        said = sv.cmd({"do": "ui", "settingsPoint": "live.status." + status})
        check(f"the Statuses section has a {status} row", "error" not in said, said)
    picture("statuses-default")

    before = len(asked)
    pressed = sv.cmd({"do": "ui", "settingsPress": "settings.live.status.backlog"})
    check("the Backlog switch presses", "error" not in pressed, pressed)
    mine = wait(lambda: (lambda f: f if len(f["items"]) == 30 else None)(folder(live("state"), "My Issues")))
    check("Backlog is chosen and kept on the folder", mine and mine["statuses"] == ["triage", "backlog", "unstarted", "started"], mine and mine["statuses"])
    check("it read again at once, asking for Backlog", len(asked) > before and '"backlog"' not in asked[-1], asked[before:])
    check("and Backlog rows fill the folder", mine and sum(i["label"] == "Backlog" for i in mine["items"]) == 30, mine and [i["label"] for i in mine["items"]][:5])
    picture("statuses-backlog-on")
    stored = Path(sv.SUPPORT) / "live-folders.json"
    saved = wait(lambda: next((f for f in json.loads(stored.read_text()) if f["name"] == "My Issues" and f["source"].get("statuses")), None)
                 if stored.exists() else None)
    check("the choice is saved with the folder", saved and saved["source"]["statuses"] == ["triage", "backlog", "unstarted", "started"],
          saved and saved["source"])

    print("— the command")
    listed = broadway("live", "list")
    ident = next(f["id"] for f in (listed[1].get("data") or {}).get("folders", []) if f["name"] == "My Issues")
    code, said = broadway("live", "statuses", ident, "progress")
    check("broadway live statuses takes progress", code == 0, said)
    mine = wait(lambda: (lambda f: f if len(f["items"]) == 1 else None)(folder(live("state"), "My Issues")))
    check("the folder now shows In Progress alone", mine and [i["label"] for i in mine["items"]] == ["In Review"], mine and mine["items"])
    code, shown = broadway("live", "show", ident)
    data = shown.get("data", {})
    check("broadway live show says what it shows and leaves out",
          data.get("statuses") == ["In Progress"] and data.get("leftOut") == ["Triage", "Backlog", "Todo"], data)
    code, said = broadway("live", "statuses", ident, "done")
    check("a status that isn't one is refused", code != 0, said)
    live("add", "PRs", "github:reviews")
    prs = next(f["id"] for f in broadway("live", "list")[1]["data"]["folders"] if f["name"] == "PRs")
    code, said = broadway("live", "statuses", prs, "backlog")
    check("a GitHub folder is refused with a hint", code != 0 and "hint" in json.dumps(said), said)
    code, help_ = 0, subprocess.run([BROADWAY, "live", "statuses", "--help"], capture_output=True, text=True).stdout
    check("the verb has help", "triage, backlog, todo and progress" in help_, help_[:300])

    print("— all left out")
    mode["only_backlog"] = True
    broadway("live", "statuses", ident, "triage", "todo", "progress")
    mine = wait(lambda: (lambda f: f if f["note"] == "empty" else None)(folder(live("state"), "My Issues")))
    check("the empty folder says Backlog is left out", mine and mine["empty"] == "No issues outside Backlog", mine and (mine["note"], mine["empty"]))
    live("unfold", "My Issues")
    time.sleep(0.8)
    picture("statuses-empty")

    print("— the Inbox")
    live("add", "Inbox", "linear:inbox")
    inbox = folder(live("update", "Inbox"), "Inbox")
    check("the Inbox has no statuses to choose", inbox["statuses"] == [], inbox["statuses"])
    check("and asks for every status", "notifications" in asked[-1] and "backlog" not in asked[-1], asked[-1][:200])
    sv.finish()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    OUT.mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Linear)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run(f"http://127.0.0.1:{server.server_port}")
    except Exception as error:
        check("the probe ran to the end", False, repr(error))
        sv.finish()
    (Path.home() / f"Library/Preferences/{sv.SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()

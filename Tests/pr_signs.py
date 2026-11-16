#!/usr/bin/env python3
"""PR rows show new activity and unanswered comments, with no token.

Build first (`./build.sh`), then `python3 Tests/pr_signs.py [SHOTS_DIR]`.

A hidden test copy reads a fake signed-in GitHub on ::1 (never the real site
or anyone's account): a PR list page, and each open PR's own page with
timeline markup copied from github.com's conversation page (author links,
relative-time stamps, review threads with data-resolved, bots under /apps/,
commits by their avatar link only). The viewer is octo-sam.

- The first read lights nothing (the folder's baseline) but shows the
  bubble on rows with open threads or comments after your last action.
- A second read, after dana reviews 52 and comments on 54 and their
  updatedAt moves, lights those two rows only and reads only their pages.
- Opening 52 clears its dot; 54 keeps its dot and bubble.
- With SHOTS_DIR, the app pictures its own window at 2x: at rest, with the
  dot, with the bubble, both, and the both-row hovered, light and dark.
"""
import json
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

SHOTS = Path(sys.argv[1]) if len(sys.argv) > 1 else None
t = sv.T()
ME = "octo-sam"
ROWS = [
    (51, "Defer the feed work until after the first frame"),
    (52, "Retry uploads that time out on a slow network"),
    (53, "Cache the build graph so cold builds stay fast"),
    (54, "Bump Swift to 6.2 and fix the new warnings"),
]
STATE = {"round": 1}
HITS = {}


def stamp(minutes):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(1_793_000_000 + minutes * 60))


def author(who, minutes):
    href = f"/apps/{who[4:]}" if who.startswith("bot:") else f"/{who}"
    return (f'<a class="author Link--primary text-bold css-overflow-wrap-anywhere " data-hovercard-type="user" href="{href}">{who}</a>'
            f'<a href="#x" class="js-timestamp Link--secondary"><relative-time datetime="{stamp(minutes)}" class="no-wrap">Nov 12</relative-time></a>')


def comment(who, minutes):
    return (f'<div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="IC_kw{minutes}">'
            f'<div class="timeline-comment-header">{author(who, minutes)}</div><div class="comment-body markdown-body"><p>Thoughts?</p></div></div>')


def thread(resolved, said):
    body = "".join(author(who, m) + '<div class="comment-body">Why?</div>' for who, m in said)
    return (f'<turbo-frame id="review-thread-or-comment-id-{said[0][1]}"><review-thread-collapsible class="review-thread-component" '
            f'data-resolved="{"true" if resolved else "false"}"><div class="js-comments-holder">{body}</div></review-thread-collapsible></turbo-frame>')


def review(who, minutes, threads=(), changes=False):
    word = "requested changes" if changes else "approved these changes"
    return (f'<div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="PRR_kw{minutes}">'
            f'<div class="TimelineItem-body">{author(who, minutes)} {word}</div>{"".join(threads)}</div>')


def commit(who):
    return ('<div class="js-timeline-item js-timeline-progressive-focus-container" data-gid="C_kwcommit">'
            f'<a class="avatar avatar-user" data-test-selector="commits-avatar-stack-avatar-link" href="/{who}"><img alt="@{who}"></a></div>')


def timeline(number):
    later = STATE["round"] > 1
    if number == 51:
        return [comment("bot:codecov", 2), comment(ME, 3)]
    if number == 52:
        out = [comment("dana", 2), comment(ME, 3), commit("bot:dependabot")]
        return out + ([review("dana", 20)] if later else [])
    if number == 53:
        return [review("lee", 2, [thread(False, [(ME, 1), ("lee", 2)]), thread(True, [("lee", 2)])]), comment(ME, 4)]
    if number == 54:
        out = [review("lee", 2, [thread(False, [("lee", 2)]), thread(False, [("bot:copilot-pull-request-reviewer", 2)])], changes=True),
               commit(ME)]
        return out + ([comment("dana", 21)] if later else [])
    return []


def updated(number):
    return stamp(30 if STATE["round"] > 1 and number in (52, 54) else 10)


def pull_page(number):
    blob = json.dumps({"pullRequest": {"baseBranch": "main", "headBranch": f"b{number}", "headRepositoryName": "rocket",
                                       "headRepositoryOwnerLogin": "acme", "number": number, "state": "OPEN"}})
    return (f'<!doctype html><meta name="user-login" content="{ME}"><title>PR {number}</title><body>'
            f'<script type="application/json" data-target="react-app.embeddedData">{blob}</script>'
            f'<div class="timeline-comment"><div class="timeline-comment-header">{author(ME, 0)}</div></div>'
            f'<div id="partial-timeline">{"".join(timeline(number))}</div><div id="discussion-timeline-actions"></div>').encode()


def item(number, title):
    return (f'<li class="listItem"><h3><a href="/acme/rocket/pull/{number}" data-testid="listitem-title-link"><span>{title}</span></a></h3>'
            f'<div><svg aria-label="Open pull request" class="octicon octicon-git-pull-request"></svg>'
            f'<a data-testid="author-filter-link" href="/acme/rocket/pulls?q=author%3A{ME}">{ME}</a>'
            f'<svg aria-label="All checks have passed" class="octicon octicon-check"></svg></div></li>')


def page():
    rows = "".join(item(*row) for row in ROWS)
    items = [{"number": n, "permalink": f"{BASE}/acme/rocket/pull/{n}", "updatedAt": updated(n)} for n, _ in ROWS]
    blob = json.dumps({"payload": {"pullRequestsIndex": {"results": {"items": items}}}})
    return (f'<!doctype html><meta name="user-login" content="{ME}"><title>Pull requests</title><body><ul role="list">{rows}</ul>'
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
        if self.path.startswith("/acme/rocket/pull/"):
            number = int(self.path.split("/")[4].split("?")[0])
            HITS[number] = HITS.get(number, 0) + 1
            return self.send(200, pull_page(number))
        if self.path.startswith("/signed-in/pulls"):
            return self.send(200, page())
        if self.path.startswith("/home"):
            return self.send(200, b"<!doctype html><title>Release notes</title><body style='font:15px -apple-system;padding:40px'>Notes")
        self.send(404, b"Not Found")


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


srv = Loopback6(("::1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://[::1]:{srv.server_port}"
TOOLS = Path(__file__).resolve().parents[1] / ".context" / "pr-signs-tools"
SHOT = TOOLS / "shot"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def prs():
    return next(f for f in live()["folders"] if f["name"] == "PRs")


def signs(folder):
    return {int(i["url"].rsplit("/", 1)[1]): (i["fresh"], i["unanswered"]) for i in folder["items"]}


def shoot(name, crop=None):
    if not SHOTS:
        return
    if not SHOT.exists():
        TOOLS.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(Path(__file__).resolve().parent / "WindowShot.swift"), "-o", str(SHOT)], check=True)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    time.sleep(0.8)
    pid = next(iter(sv.holding() & sv.running()))
    out = SHOTS / f"{name}.png"
    said = ""
    for _ in range(4):
        ran = subprocess.run([str(SHOT), str(pid), str(number), str(out)], capture_output=True, text=True)
        said = (ran.stdout + ran.stderr).strip()
        if out.exists():
            break
        time.sleep(1)
    t.ok(f"pictured {name}", out.exists(), said)
    if crop and out.exists():
        x, y, w, h = crop
        subprocess.run(["sips", "-c", str(h), str(w), "--cropOffset", str(y), str(x), str(out), "--out", str(SHOTS / f"{name}-rows.png")],
                       capture_output=True)


def band(ids):
    rows = sv.cmd({"do": "rowframes"})["rows"]
    frames = [rows[i] for i in ids if i in rows]
    if not frames:
        return None
    scale = 2
    left = min(f[0] for f in frames) - 8
    top = min(f[1] for f in frames) - 8
    right = max(f[0] + f[2] for f in frames) + 8
    bottom = max(f[1] + f[3] for f in frames) + 8
    return (int(left * scale), int(top * scale), int((right - left) * scale), int((bottom - top) * scale))


def main():
    if SHOTS:
        SHOTS.mkdir(parents=True, exist_ok=True)
    sv.use("pr-signs")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False, "tabs.cards": False})
    sv.launch()
    try:
        sv.cmd({"do": "open", "url": f"{BASE}/home"})
        live("add-page", "PRs", "pullRequests", f"{BASE}/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me")
        live("unfold", "PRs")
        HITS.clear()
        first = signs(live("update", "PRs") and prs())
        print("    first read:", first)
        t.ok("the first read lights nothing", not any(fresh for fresh, _ in first.values()), first)
        t.ok("the bubble counts open threads and comments after your last action, bots and resolved threads left out",
             {n: u for n, (_, u) in first.items()} == {51: 0, 52: 0, 53: 1, 54: 1}, first)
        t.ok("each open PR's page is read once", sorted(HITS) == [51, 52, 53, 54] and set(HITS.values()) == {1}, HITS)
        STATE["round"] = 2
        HITS.clear()
        second = signs(live("update", "PRs") and prs())
        print("    second read:", second)
        t.ok("dana's review and comment light their rows only",
             {n: f for n, (f, _) in second.items()} == {51: False, 52: True, 53: False, 54: True}, second)
        t.ok("dana's comment after your push waits on you too", second[54][1] == 2, second)
        t.ok("only the two PRs whose updatedAt moved are read again", sorted(HITS) == [52, 54], HITS)
        folder = prs()
        ids = {int(i["url"].rsplit("/", 1)[1]): tab["id"] for i, tab in zip(folder["items"], folder["tabs"])}
        t.ok("the tabs carry the signs", {ids[n]: second[n][1] for n in ids} == {tab["id"]: tab["unanswered"] for tab in folder["tabs"]},
             folder["tabs"])
        sv.cmd({"do": "window"})
        time.sleep(1.5)
        got = sv.cmd({"do": "rowframes"})
        t.ok("all four rows are drawn", all(ids[n] in got["rows"] for n in ids), got["rows"])
        if SHOTS:
            sv.cmd({"do": "idle", "action": "unhide"})
            time.sleep(1)
            crop = band(list(ids.values()))
            for theme in ("light", "dark"):
                sv.cmd({"do": "ui", "look": theme})
                sv.cmd({"do": "space", "action": "look", "glass": False, "transparency": 0, "grain": 0, "custom": "FFD3E0", "intensity": 0.8})
                time.sleep(1)
                shoot(f"pr-signs-{theme}", crop)
                sv.cmd({"do": "rowhover", "id": ids[54], "on": True})
                time.sleep(1)
                shoot(f"pr-signs-{theme}-hovered", crop)
                sv.cmd({"do": "rowhover", "id": ids[54], "on": False})
                time.sleep(0.4)
        sv.sp("select", id=ids[52])
        time.sleep(0.5)
        third = signs(prs())
        t.ok("opening 52 clears its dot and leaves 54 lit", third[52][0] is False and third[54][0] is True, third)
        t.ok("the bubble stays until you answer", third[54][1] == 2 and third[53][1] == 1, third)
    finally:
        sv.finish()
    shutil.rmtree(TOOLS, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

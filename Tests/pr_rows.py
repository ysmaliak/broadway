#!/usr/bin/env python3
"""PR rows next to normal tabs: a normal tab's height, who, stack, draft, checks.

Build first (`./build.sh`), then `python3 Tests/pr_rows.py [SHOTS_DIR]`.

A hidden test copy in a world of its own against a fake GitHub on ::1
(IPv6 loopback, so rows carry no local-server port badge), never the real
site or anyone's account. Broadway takes no token: the folder reads a
signed-in PR list page whose rows copy the markup of github.com's React
list (author in a[data-testid=author-filter-link], draft only in the icon's
aria-label, review state and checks filled in late into skeletons, relative
links, updatedAt in the embedded JSON). Each open PR's own page carries its
branches as github.com's does ("baseBranch", "headBranch" in the embedded
JSON, the "wants to merge … from …" links) and, for the three in a stack,
GitHub's own "stack" object, so the stack shows top first.

The rows' frames come from `rowframes`; every PR row must be as tall as a
normal tab and step as far, and each checks mark must sit on its row's
favicon corner, on one-line and two-line rows. With SHOTS_DIR the window is
pictured (WindowShot.swift, by its window number) on three looks (pale,
vivid, black), light and dark, with a selected and a hovered row.

Other probes import this module for its fake and call `add_prs()` to get a
filled PRs folder, or serve `page(rows, base)` themselves under
/github/page/pulls, where a test run's `integrations.api` sends the reads
of a github.com folder.
"""
import json
import re
import shutil
import socket
import struct
import zlib
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

SHOTS = Path(sys.argv[1]) if len(sys.argv) > 1 else None
TOKENS = (Path(__file__).resolve().parents[1] / "Sources/Search/Kit/Tokens.swift").read_text()
ROW = float(re.search(r"static let sideRowHeight: CGFloat = (\d+)", TOKENS).group(1))
STEP = ROW + float(re.search(r"static let sideGap: CGFloat = (\d+)", TOKENS).group(1))
t = sv.T()
AUTHORS = {"octo-sam", "dana", "lee"}
LONG = "[OCT-1459] Startup - Defer the heavy list work until after the first frame is on screen"


ICON = {"open": '<svg aria-label="Open pull request" class="octicon octicon-git-pull-request fgColor-open" width="16" height="16"></svg>',
        "draft": '<svg aria-label="Draft pull request" class="octicon octicon-git-pull-request-draft fgColor-muted" width="16" height="16"></svg>'}
CHECK = {"passing": '<svg aria-label="All checks have passed" class="octicon octicon-check" width="12" height="12"></svg>',
         "failing": '<svg aria-label="Some checks failed" class="octicon octicon-x" width="12" height="12"></svg>',
         "pending": '<svg aria-label="Checks pending" class="octicon octicon-dot-fill" width="12" height="12"></svg>'}
ROWS = [
    (512, LONG, "dana", "open", "Review required", "failing"),
    (37, "[OCT-35] Field Recording - Add the recorder", "octo-sam", "open", "Changes requested", "failing"),
    (38, "[OCT-35] Field Recording - Add upload", "octo-sam", "draft", "", "pending"),
    (41, "Cache the build graph so cold builds stop resolving every package again", "octo-sam", "open", "Review required", "passing"),
    (36, "[OCT-35] Field Recording - Add the model", "octo-sam", "open", "Approved", "passing"),
    (44, "Bump Swift to 6.2", "lee", "open", "Approved", "passing"),
    (45, "Ship the widget under its title attribute", "dana", "open", "Changes requested", "passing"),
    (46, "Nobody's name on this one", None, "open", "", "pending"),
]
BRANCHES = {512: ("main", "dana", "defer-feed"), 37: ("audio-model", "acme", "audio-recorder"),
            38: ("audio-recorder", "acme", "audio-upload"), 41: ("main", "acme", "graph-cache"),
            36: ("main", "acme", "audio-model"), 44: ("main", "acme", "swift-6-2"),
            45: ("main", "dana", "audio-recorder"), 46: ("main", "acme", "nameless")}
STACK = {36: 1, 37: 2, 38: 3}
PULLS = "/signed-in/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me"
UPDATED = "2026-11-04T09:00:00Z"
HITS = {}
STAMPS = {}
talk = lambda number: ""


def item(number, title, author, icon, review, checks, late=True):
    anchor = (f'<a href="/acme/rocket/pull/{number}" title="{title}" data-testid="listitem-title-link"></a>' if number == 45
              else f'<a href="/acme/rocket/pull/{number}" data-testid="listitem-title-link"><span>{title}</span></a>')
    who = (f'<a data-testid="author-filter-link" aria-label="Filter by author {author}" href="/acme/rocket/pulls?q=author%3A{author}">{author}</a>'
           if author else "")
    if not late:
        return (f'<li class="listItem" tabindex="-1"><div data-listview-item-title-container="true"><h3>{anchor}</h3></div>'
                f'<div><div class="leadingElement">{ICON[icon]}</div><div class="description"><span>#{number}</span>'
                f'<span data-testid="timestamp-container">{who}<span> opened </span><relative-time>Nov 4, 2026</relative-time></span>'
                f'<span>{review}</span><span>{CHECK[checks]}</span></div></div></li>')
    return f"""<li class="listItem" tabindex="-1"><div data-listview-item-title-container="true"><h3>
{anchor}</h3></div>
<div><div class="leadingElement">{ICON[icon]}</div><div class="description"><span>#{number}</span>
<span data-testid="timestamp-container"><span aria-hidden="true">·</span>
{who}
<span> opened </span><relative-time>Nov 4, 2026</relative-time></span>
<span><span aria-hidden="true">·</span><div style="height:12px;width:100px" data-testid="deferred-review-skeleton" data-review="{review}"></div></span>
<span><span aria-hidden="true">·</span><div style="height:12px;width:28px" data-testid="deferred-status-skeleton" data-checks="{checks}"></div></span>
</div></div></li>"""


LATE = """<script>setTimeout(() => {
  for (const s of document.querySelectorAll('[data-testid=deferred-review-skeleton]')) { const t = document.createElement('span'); t.textContent = s.dataset.review; s.replaceWith(t); }
  for (const s of document.querySelectorAll('[data-testid=deferred-status-skeleton]')) { const t = document.createElement('span'); t.innerHTML = CHECKS[s.dataset.checks]; s.replaceWith(t); }
}, 1500);</script>"""


def embedded(rows, base):
    items = [{"number": n, "permalink": f"{base}/acme/rocket/pull/{n}", "updatedAt": STAMPS.get(n, UPDATED), "repoNameWithOwner": "acme/rocket"}
             for n, *_ in rows]
    return json.dumps({"payload": {"pullRequestsIndex": {"results": {"items": items}}}})


def pull_page(number):
    base, owner, head = BRANCHES[number]
    pull = {"author": {"login": owner}, "baseBranch": base, "commitsCount": 1, "headBranch": head,
            "headRepositoryName": "rocket", "headRepositoryOwnerLogin": owner, "number": number, "state": "OPEN"}
    blob = json.dumps({"pullRequest": pull, "stack": {"number": 14, "position": STACK[number]} if number in STACK else None})
    return (f"<!doctype html><meta name=\"user-login\" content=\"octo-sam\"><title>PR {number}</title><body>"
            f"<script type=\"application/json\" data-target=\"react-app.embeddedData\">{blob}</script>"
            f"<div>octo-sam wants to merge 1 commit into<div><a href=\"/acme/rocket/tree/{base}\" data-component=\"BranchName\">acme:{base}</a>"
            f"<span>from </span><a href=\"/{owner}/rocket/tree/{head}\" data-component=\"BranchName\">{owner}:{head}</a></div></div>"
            f"{talk(number)}").encode()


def page(rows=None, base=None, late=True):
    rows = ROWS if rows is None else rows
    listed = "".join(item(*row, late=late) for row in rows)
    return (f"<!doctype html><meta name=\"user-login\" content=\"octo-sam\"><title>Pull requests</title>"
            f"<body><ul role=\"list\">{listed}</ul><script>const CHECKS = {json.dumps(CHECK)};</script>{LATE if late else ''}"
            f"<script type=\"application/json\" data-target=\"react-app.embeddedData\">{embedded(rows, base or BASE)}</script>").encode()


def icon(side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            d = (dx * dx + dy * dy) ** 0.5
            inside = d <= side / 2 - 1
            ring = side / 2 - 7 <= d <= side / 2 - 4
            v = 245 if ring else 24
            rows += bytes([v, v, v, 255 if inside else 0])
    chunk = lambda kind, data: struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


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
        if self.path.startswith("/favicon"):
            return self.send(200, icon(), "image/png")
        if self.path.startswith("/acme/rocket/pull/"):
            number = int(self.path.split("/")[4].split("?")[0])
            HITS[number] = HITS.get(number, 0) + 1
            return self.send(200, pull_page(number)) if number in BRANCHES else self.send(404, b"Not Found")
        if self.path.startswith("/signed-in/pulls"):
            return self.send(200, page())
        if self.path.startswith("/home"):
            name = self.path.split("?")[-1].replace("+", " ") if "?" in self.path else "A page"
            return self.send(200, f"<!doctype html><title>{name}</title><body style='font:15px -apple-system;padding:40px'><h2>{name}</h2>".encode())
        self.send(404, b"Not Found")


class Loopback6(ThreadingHTTPServer):
    address_family = socket.AF_INET6


srv = Loopback6(("::1", 0), Fake)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://[::1]:{srv.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder(st, name):
    return next((f for f in st["folders"] if f["name"] == name), None)


def add_prs(name="PRs"):
    live("add-page", name, "pullRequests", f"{BASE}{PULLS}")
    return live("update", name)


TOOLS = Path(__file__).resolve().parents[1] / ".context" / "pr-rows-tools"
SHOT = TOOLS / "shot"


def shoot(name):
    """The test copy's own window only, by its window number (WindowShot.swift)."""
    if not SHOTS:
        return None
    if not SHOT.exists():
        TOOLS.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(Path(__file__).resolve().parent / "WindowShot.swift"), "-o", str(SHOT)], check=True)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    time.sleep(0.8)
    pid = next(iter(sv.holding() & sv.running()))
    out = SHOTS / f"{name}.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(out)], capture_output=True, text=True).stdout.strip()
    t.ok(f"pictured {name}", out.exists(), said)
    return out


def frames(prs, normal_ids):
    rows = sv.cmd({"do": "rowframes"})["rows"]
    pr_ids = [tab["id"] for tab in prs["tabs"]]
    pr_frames = [rows[i] for i in pr_ids if i in rows]
    normal = [rows[i] for i in normal_ids if i in rows]
    heights = sorted({round(f[3], 1) for f in pr_frames})
    steps = sorted({round(b[1] - a[1], 1) for a, b in zip(pr_frames, pr_frames[1:])})
    return heights, steps, sorted({round(f[3], 1) for f in normal}), len(pr_frames)


def marks(prs):
    """Each checks mark's frame against its row's favicon (`icons` from
    rowframes): the mark's centre must fall inside the favicon's
    bottom-trailing quarter, and its frame inside the favicon plus the
    mark's 1 pt ring, clear of the title's x (the favicon's maxX + 7)."""
    got = sv.cmd({"do": "rowframes"})
    rows, checks, icons = got["rows"], got.get("checks", {}), got.get("icons", {})
    placed = []
    for tab, item in zip(prs["tabs"], prs["items"]):
        if not item["checks"] or tab["id"] not in rows:
            continue
        mark, icon = checks.get(tab["id"]), icons.get(tab["id"])
        if not mark or not icon:
            placed.append((item["title"][:20], bool(item["byline"]), None))
            continue
        cx, cy = mark[0] + mark[2] / 2, mark[1] + mark[3] / 2
        inside = (mark[0] >= icon[0] - 1 and mark[1] >= icon[1] - 1 and mark[0] + mark[2] <= icon[0] + icon[2] + 1
                  and mark[1] + mark[3] <= icon[1] + icon[3] + 1 and mark[0] + mark[2] + 1 + 3 <= icon[0] + icon[2] + 7)
        placed.append((item["title"][:20], bool(item["byline"]),
                       (round(cx - icon[0], 1), round(cy - icon[1], 1)) if inside else None))
    return placed


def column(prs):
    """In a card that holds a stack, every row's favicon shares one x, and
    that x is clear of each fold chevron's hit target by at least 4 pt."""
    got = sv.cmd({"do": "rowframes"})
    icons, chevrons = got.get("icons", {}), got.get("chevrons", [])
    xs = sorted({round(icons[tab["id"]][0], 1) for tab in prs["tabs"] if tab["id"] in icons})
    gaps = [round(xs[0] - (c[0] + c[2]), 1) for c in chevrons] if xs else []
    return xs, gaps


LOOKS = [("pale", {"custom": "FFD3E0", "intensity": 0.8}), ("vivid", {"custom": "3139FB", "intensity": 2.0}),
         ("black", {"custom": "000000", "intensity": 2.0})]


def fold_stack(name):
    """The stack's top row carries the one fold chevron: pressed, the rest of
    the stack goes and the top row keeps its n/m; pressed again, it is back."""
    st = live("stack")
    prs = folder(st, "PRs")
    ids = [tab["id"] for tab in prs["tabs"]]
    t.ok(f"{name}: one fold chevron, on the stack's top row", st.get("chevrons") == 1 and [x["id"] for x in prs["stacks"]] == [ids[1]],
         (st.get("chevrons"), prs["stacks"], ids))
    t.ok(f"{name}: pressed, the stack folds and the chevron says Unfold Stack",
         st.get("pressed") and st.get("label") == "Unfold Stack" and [x["folded"] for x in prs["stacks"]] == [True], (st.get("label"), prs["stacks"]))
    time.sleep(0.6)
    rows = sv.cmd({"do": "rowframes"})["rows"]
    t.ok(f"{name}: folded, the top row stays and the rest of the stack is gone",
         ids[1] in rows and ids[2] not in rows and ids[3] not in rows and ids[4] in rows, (ids, sorted(rows)))
    t.ok(f"{name}: folded, the top row still says 3/3", prs["items"][1]["byline"].startswith("octo-sam 3/3"), prs["items"][1])
    st = live("stack")
    time.sleep(0.6)
    rows = sv.cmd({"do": "rowframes"})["rows"]
    t.ok(f"{name}: pressed again, the stack is back and says Fold Stack",
         st.get("label") == "Fold Stack" and all(i in rows for i in ids[1:4]), (st.get("label"), ids, sorted(rows)))


def joined_after_relaunch(name):
    time.sleep(1.5)
    sv.quit()
    time.sleep(1)
    path = Path(sv.SUPPORT) / "live-folders.json"
    saved = json.loads(path.read_text())
    for entry in saved:
        if entry.get("name") != "PRs":
            continue
        for row in entry.get("items", []):
            if "pageRead" in row:
                row["pageRead"] -= 660
            if row["key"].endswith("/pull/46") and row.get("branch"):
                row["branch"]["base"] = "audio-upload"
    path.write_text(json.dumps(saved))
    BRANCHES[46], STACK[46] = ("audio-upload", "acme", "nameless"), 4
    HITS.clear()
    try:
        sv.launch()
        prs = folder(live("update", "PRs"), "PRs")
        bylines = [i["byline"] for i in prs["items"]]
        print("    joined:", bylines, dict(HITS))
        t.ok(f"{name}: after a relaunch, the row that joined the stack tops it and every chip says n/4",
             bylines == ["dana", "4/4", "octo-sam 3/4 • Draft", "octo-sam 2/4 • Changes requested", "octo-sam 1/4 • Approved",
                         "octo-sam", "lee • Approved", "dana • Changes requested"], bylines)
        t.ok(f"{name}: only the joined row, the old top and the other members were read", set(HITS) == {36, 37, 38, 46}, dict(HITS))
    finally:
        BRANCHES[46] = ("main", "acme", "nameless")
        STACK.pop(46, None)


def world(name):
    global talk
    talk = lambda number: '<div id="discussion-timeline-actions"></div>'
    print(f"— {name}")
    sv.use(f"pr-rows-{name}")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    sv.launch()
    report = {}
    try:
        normal = [sv.cmd({"do": "open", "url": f"{BASE}/home?{label}"})["id"] for label in ("Release+notes", "Design+review")]
        live("add-page", "PRs", "pullRequests", f"{BASE}{PULLS}")
        HITS.clear()
        live("unfold", "PRs")
        began = time.time()
        prs = folder(live("update", "PRs"), "PRs")
        report["read"] = round(time.time() - began, 1)
        t.ok(f"{name}: the folder reads the fake", prs["state"] == "fine" and len(prs["items"]) >= 5, prs)
        bylines = [i["byline"] for i in prs["items"]]
        print("    bylines:", bylines)
        t.ok(f"{name}: every two-line row says who", all(b.split(" ")[0] in AUTHORS for b in bylines if b), bylines)
        t.ok(f"{name}: the stack, top first, at its first member's place",
             bylines == ["dana", "octo-sam 3/3 • Draft", "octo-sam 2/3 • Changes requested", "octo-sam 1/3 • Approved",
                         "octo-sam", "lee • Approved", "dana • Changes requested", ""], bylines)
        t.ok(f"{name}: checks come from the late cells too",
             [i["checks"] for i in prs["items"]] == ["failing", "pending", "failing", "passing", "passing", "passing", "passing", "pending"],
             [i["checks"] for i in prs["items"]])
        fetched = dict(HITS)
        t.ok(f"{name}: one page read per open PR, each once", sorted(fetched) == sorted(BRANCHES) and set(fetched.values()) == {1}, fetched)
        live("update", "PRs")
        t.ok(f"{name}: a second read with the same updatedAt reads no PR page", HITS == fetched, (fetched, HITS))
        report["pr_pages"] = fetched
        sv.cmd({"do": "window"})
        time.sleep(1.5)
        heights, steps, normal_heights, drawn = frames(prs, normal)
        report.update(pr_heights=heights, pr_steps=steps, normal_heights=normal_heights, drawn=drawn)
        print("    frames:", report)
        t.ok(f"{name}: every PR row is a normal tab's {ROW:g} pt", heights == [ROW] and normal_heights == [ROW], (heights, normal_heights))
        t.ok(f"{name}: and steps {STEP:g} pt, row and gap, like the tabs", steps == [STEP], steps)
        placed = marks(prs)
        report["marks"] = placed
        print("    marks (title, two lines, centre from favicon origin):", placed)
        t.ok(f"{name}: every checks mark sits on its favicon's bottom-trailing corner, one line or two",
             placed and all(at and 7 < at[0] <= 15.5 and 7 < at[1] <= 15.5 for _, _, at in placed), placed)
        xs, gaps = column(prs)
        report["column"] = (xs, gaps)
        t.ok(f"{name}: with a stack in the card, every favicon shares one x clear of the chevron",
             len(xs) == 1 and gaps and all(g >= 4 for g in gaps), (xs, gaps))
        t.ok(f"{name}: a one-line row carries its mark too", any(not two and at for _, two, at in placed), placed)
        fold_stack(name)
        if SHOTS:
            sv.cmd({"do": "idle", "action": "unhide"})
            time.sleep(1)
            ids = [tab["id"] for tab in prs["tabs"]]
            sv.sp("select", id=ids[2])
            time.sleep(1.5)
            for look_name, look in LOOKS:
                for theme in ("light", "dark"):
                    sv.cmd({"do": "ui", "look": theme})
                    sv.cmd({"do": "space", "action": "look", "glass": False, "transparency": 0, "grain": 0, **look})
                    time.sleep(0.6)
                    sv.cmd({"do": "rowhover", "id": ids[3], "on": True})
                    time.sleep(1.2)
                    shoot(f"pr-rows-{look_name}-{theme}")
                    if look_name == LOOKS[0][0]:
                        sv.cmd({"do": "rowhover", "id": ids[3], "on": False})
                        sv.sp("select", id=ids[0]); time.sleep(0.6)
                        live("stack"); time.sleep(1)
                        shoot(f"pr-rows-{look_name}-{theme}-folded")
                        live("stack"); time.sleep(0.6)
                        sv.sp("select", id=ids[2]); time.sleep(0.6)
        joined_after_relaunch(name)
    finally:
        sv.finish()
    return report


def main():
    if SHOTS:
        SHOTS.mkdir(parents=True, exist_ok=True)
    found = {"page": world("page")}
    print(json.dumps(found))
    shutil.rmtree(TOOLS, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

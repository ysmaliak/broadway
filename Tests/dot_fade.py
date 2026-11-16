#!/usr/bin/env python3
"""The title is always faded behind the unseen dot.

Build first (`./build.sh debug`), then `python3 Tests/dot_fade.py [LABEL] [film]`.

A shown test copy in a world of its own, against the signed-in GitHub
pages of pr_rows.py, each PR's page given a timeline and review threads so
rows can light. Every way the dot or the room kept for it can change is
driven through the bench while `endtrace` reads, on the window's display
link, each row's dot and count as they are shown and the title's fade as it
is shown and as it will rest.

The rule, per frame and per row: while the dot (or the count beside it)
shows at any strength, the fade is where it rests, and the title's ink ends
before the mark. A hover on a row with no dot is the control: its fade must
be seen sweeping, as it always has.

With `film`, each case is also filmed from the test copy's own window by its
window number (WindowCapture.swift), never a region of the display, into
.context/shots/LABEL/.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
FILM = "film" in sys.argv[2:]
ONLY = [a for a in sys.argv[2:] if a != "film"]
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

OUT = ROOT / ".context" / "shots" / LABEL
CAPTURE = ROOT / ".context" / "shots" / "capture"
SIDEBAR = 260
FPS = 120
t = sv.T()
said = {"comments": {}, "threads": set()}
LONG = "Rework the offline cache so a cold start reads nothing it does not show on the first screen"
FITS = "Bump Swift to 6.2 everywhere"
STACK = {36: 1, 37: 2, 38: 3}
SLOW = "slow/an-address-long-enough-to-run-well-past-the-end-of-its-row-while-the-page-loads"


def talk(number):
    parts = []
    if number in said["comments"]:
        parts.append(f'<div class="js-timeline-item" data-gid="PRR_{number}"><a class="author" href="/lee">lee</a>'
                     f'<relative-time datetime="2026-11-05T{said["comments"][number]:02d}:00:00Z"></relative-time> commented</div>')
    if number in said["threads"]:
        parts.append(f'<div class="js-timeline-item" data-gid="PRR_t{number}"><review-thread-collapsible data-resolved="false">'
                     '<a class="author" href="/dana">dana</a><relative-time datetime="2026-11-05T11:00:00Z"></relative-time>'
                     '</review-thread-collapsible></div>')
    return "".join(parts) + '<div class="discussion-timeline-actions"></div>'


def touched(*numbers):
    said["turn"] = said.get("turn", 0) + 1
    for number in numbers:
        pr.STAMPS[number] = f"2026-11-06T00:{said['turn']:02d}:00Z"


pr.talk = talk
pr.STACK = STACK
pr.ROWS = [
    (512, pr.LONG, "dana", "open", "Review required", "failing"),
    (36, "[OCT-35] Field Recording - Add the model to the recorder's store", "octo-sam", "open", "Approved", "passing"),
    (37, "[OCT-35] Field Recording - Add the recorder and its meters", "octo-sam", "open", "Changes requested", "failing"),
    (38, "[OCT-35] Field Recording - Add upload and the retry queue", "octo-sam", "draft", "", "pending"),
    (41, "Cache the build graph so cold builds stop resolving every package again", "octo-sam", "open", "", "passing"),
    (44, "Bump Swift", "lee", "open", "Approved", "pending"),
]


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        name = self.path.split("?")[-1].replace("+", " ") if "?" in self.path else "A page"
        if self.path.startswith("/slow"):
            time.sleep(0.9)
        body = f"<!doctype html><title>{name}</title><body style='font:15px -apple-system;padding:40px'><h2>{name}</h2>".encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


pages = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=pages.serve_forever, daemon=True).start()
PAGES = f"http://127.0.0.1:{pages.server_port}"


def end(action, **more):
    return sv.cmd({"do": "ui", "endtrace": {"action": action, **more}})


def rows():
    return end("now")["rows"]


def row(id, interactive=True):
    return next((r for r in rows() if r["id"] == id and r["interactive"] == interactive), None)


REST = {}


def judge(samples, ids=None):
    """Each frame of each row against the rule. `under`: ink past where it
    may end while a mark shows. `sweeping`: the fade not where it rests
    while a mark shows. `moved`: frames in which the fade was between places
    at all, mark or no mark. `lit`: rows whose mark is at full strength in
    the last frame."""
    found = {"frames": 0, "marked": 0, "under": 0, "sweeping": 0, "moved": 0, "worst": 0.0, "first": [], "lit": 0}
    for r in samples[-1]["rows"] if samples else []:
        if (ids is None or r["id"] in ids) and r["seen"] and (r["dot"] > 0.99 or r["talk"] > 0.99):
            found["lit"] += 1
    for sample in samples:
        for r in sample["rows"]:
            if ids is not None and r["id"] not in ids:
                continue
            if not r["seen"] or not r["titled"] or len(r["shown"]) != 2 or len(r["model"]) != 2:
                continue
            found["frames"] += 1
            ink = r["x"] + r["natural"]
            reaches = ink > min(r["shown"][0], r["model"][0]) + 0.5
            apart = max(abs(r["shown"][0] - r["model"][0]), abs(r["shown"][1] - r["model"][1]))
            if reaches and apart > 0.5:
                found["moved"] += 1
            dot = r["dot"] > 0.004 or r["dotTurning"]
            talk = r["talk"] > 0.004
            if not (dot or talk):
                continue
            found["marked"] += 1
            limit = r["talkX"] - 2 if talk else r["width"] - REST["fromEnd"]
            over = min(ink, r["shown"][1]) - limit
            full = min(ink, r["shown"][0]) - (limit - (28 if ink > limit + 0.5 else 0))
            bad = None
            if over > 0.5 or full > 0.5:
                found["under"] += 1
                found["worst"] = max(found["worst"], round(max(over, full), 1))
                bad = "under"
            elif reaches and apart > 0.5:
                found["sweeping"] += 1
                bad = "sweeping"
            if bad and len(found["first"]) < 6:
                found["first"].append([round(sample["t"]), r["id"], bad, round(r["dot"], 2), round(r["talk"], 2),
                                       [round(v, 1) for v in r["shown"]], [round(v, 1) for v in r["model"]], round(limit, 1)])
    return found


PID = None
NUMBER = None
found = {}


def case(name, act, ids=None, seconds=0.9, lead=0.15, after=None):
    if ONLY and not any(name.startswith(o) for o in ONLY):
        return None
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    p = None
    if FILM:
        p = subprocess.Popen([str(CAPTURE), str(PID), str(folder), str(seconds + lead + 0.3), str(NUMBER), "2", str(FPS)],
                             stdout=subprocess.PIPE, text=True)
        for _ in range(200):
            if (folder / "ready").exists() or p.poll() is not None:
                break
            time.sleep(0.025)
    time.sleep(lead)
    end("start")
    try:
        act()
    except RuntimeError as error:
        print("  ", name, "could not be driven:", error, flush=True)
    time.sleep(seconds)
    samples = end("stop")["samples"]
    if p:
        print("  ", name, p.communicate()[0].strip(), flush=True)
    (folder / "trace.json").write_text(json.dumps(samples))
    report = judge(samples, ids)
    report["name"] = name
    found[name] = report
    print("  traced", json.dumps(report), flush=True)
    if FILM:
        sheet(name, folder, samples, ids)
    if after:
        after()
    time.sleep(0.5)
    return report


def sheet(name, folder, samples, ids, span=0.4, columns=6):
    frames = sorted(folder.glob("0*.png"))
    if len(frames) < 4:
        return
    times = json.loads((folder / "times.json").read_text())
    at = [r["at"] for s in samples for r in s["rows"] if ids and r["id"] in ids]
    top = max(0, min(a[1] for a in at) - 6) if at else 0
    tall = (max(a[1] for a in at) - top + 34 + 6) if at else 300
    crop = f"crop={SIDEBAR * 2}:{int(tall * 2)}:0:{int(top * 2)}"
    digest = lambda f: hashlib.sha1(subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(f), "-vf", crop, "-f", "rawvideo", "-"],
                                                   capture_output=True).stdout).hexdigest()
    first = digest(frames[2])
    start = next((i for i in range(2, len(frames)) if digest(frames[i]) != first), 3)
    start = max(0, start - 1)
    picked = [i for i in range(start, len(frames)) if times[i] - times[start] <= span]
    work = folder / "sheet"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir()
    for n, i in enumerate(picked):
        os.symlink(frames[i], work / f"{n:04d}.png")
    lines = (len(picked) + columns - 1) // columns
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                    "-vf", f"{crop},tile={columns}x{lines}:padding=4:color=red", "-frames:v", "1", str(OUT / f"{name}.png")], check=False)
    gaps = sorted(b - a for a, b in zip(times, times[1:]))
    rate = round(1 / gaps[len(gaps) // 2]) if gaps and gaps[len(gaps) // 2] > 0 else 60
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(rate), "-i", str(folder / "%04d.png"),
                    "-vf", f"crop={SIDEBAR * 2}:{min(1400, 700 * 2)}:0:0", "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")], check=False)
    for frame in frames:
        frame.unlink()
    shutil.rmtree(work, ignore_errors=True)
    print("   sheet", (OUT / f"{name}.png").relative_to(ROOT), f"{len(picked)} frames over {span}s from frame {start} at {rate} fps", flush=True)


BRIEF = {"tab-rename-begins"}
ARRIVES = {"tab-arrive", "tab-command-let-go", "tab-loading", "tab-fits-arrive", "tab-short-arrive",
           "tab-arrive-under-a-passing-pointer", "tab-rename-ends", "live-arrive", "live-count-arrives",
           "live-count-beside-a-dot", "live-dot-beside-a-count", "calm-arrive"}


def unread(id):
    sv.cmd({"do": "ui", "unread": id})


def hover(id, on):
    sv.cmd({"do": "rowhover", "id": id, "on": on})


def main():
    global PID, NUMBER
    OUT.mkdir(parents=True, exist_ok=True)
    if FILM and not CAPTURE.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    sv.use("dot-fade-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "start.fresh": False, "spaces": True, "tabs.shortcuts": True})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", "dark"], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(SIDEBAR)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    PID = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        opened = {}
        for key, title in [("long", LONG), ("fits", FITS), ("short", "Notes"), ("other", "Another long title that runs well past the end of its row in the list"),
                           ("front", "The page in front, with a title long enough to fade at the end of the row")]:
            opened[key] = sv.cmd({"do": "open", "url": f"{PAGES}/{SLOW if key == 'long' else 'home'}?{title.replace(' ', '+')}"})["id"]
            time.sleep(1.5 if key == "long" else 0.5)
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}{pr.PULLS}")
        pr.live("unfold", "PRs")
        prs = pr.folder(pr.live("update", "PRs"), "PRs")
        t.ok("the folder reads the fake and lights nothing at first", prs["state"] == "fine" and len(prs["items"]) == 6 and prs["fresh"] == 0, prs)
        for _ in range(20):
            if prs.get("stacks"):
                break
            time.sleep(0.5)
            prs = pr.folder(pr.live("state"), "PRs")
        pulls = {int(item["url"].rsplit("/", 1)[1]): tab["id"] for tab, item in zip(prs["tabs"], prs["items"])}
        print("  rows", pulls, [i["byline"] for i in prs["items"]], prs.get("stacks"), flush=True)
        NUMBER = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(1.2)

        hover(opened["other"], True)
        time.sleep(0.5)
        resting = row(opened["other"])
        REST["fromEnd"] = resting["width"] - resting["model"][1]
        hover(opened["other"], False)
        time.sleep(0.4)
        print("  a row at rest under the cross ends its ink", round(REST["fromEnd"], 1), "pt from the row's end", flush=True)

        control = case("control-hover-in", lambda: hover(opened["other"], True), [opened["other"]])
        case("control-hover-out", lambda: hover(opened["other"], False), [opened["other"]])
        if control:
            t.ok("control: an ordinary row's fade is seen sweeping under the cross", control["moved"] >= 3, control)

        case("tab-arrive", lambda: unread(opened["long"]), [opened["long"]])
        case("tab-hover-in", lambda: hover(opened["long"], True), [opened["long"]])
        case("tab-hover-out", lambda: hover(opened["long"], False), [opened["long"]])
        case("tab-command-held", lambda: end("command", on=True), [opened["long"]])
        case("tab-command-let-go", lambda: end("command", on=False), [opened["long"]])
        case("tab-loading", lambda: sv.cmd({"do": "go", "id": opened["long"], "url": f"{PAGES}/{SLOW}?{LONG.replace(' ', '+')}"}),
             [opened["long"]], seconds=1.8)
        case("tab-sidebar-narrower", lambda: sv.cmd({"do": "resize", "width": 900, "height": 760, "steps": 12}), [opened["long"]], seconds=1.2)
        case("tab-key-lost", lambda: sv.cmd({"do": "idle", "action": "give"}), [opened["long"]])
        case("tab-key-back", lambda: sv.cmd({"do": "idle", "action": "front"}), [opened["long"]])
        case("tab-clear-by-select", lambda: sv.sp("select", id=opened["long"]), [opened["long"]],
             after=lambda: sv.sp("select", id=opened["front"]))
        case("tab-fits-arrive", lambda: unread(opened["fits"]), [opened["fits"]])
        case("tab-short-arrive", lambda: unread(opened["short"]), [opened["short"]])

        def comment(*numbers, threads=(), hour=10):
            said["comments"].update({number: hour for number in numbers})
            said["threads"].update(threads)
            touched(*numbers, *threads)
            return lambda: pr.live("update", "PRs")

        def crossed():
            unread(opened["other"])
            time.sleep(0.04)
            hover(opened["other"], True)
            time.sleep(0.04)
            hover(opened["other"], False)

        case("tab-arrive-under-a-passing-pointer", crossed, [opened["other"]])
        case("tab-sidebar-wider", lambda: [sv.cmd({"do": "ui", "sideWidth": SIDEBAR + 4 * step}) for step in range(1, 11)], None, seconds=1.0)
        case("tab-sidebar-back", lambda: [sv.cmd({"do": "ui", "sideWidth": SIDEBAR + 40 - 4 * step}) for step in range(1, 11)], None, seconds=1.0)

        unread(opened["front"])
        time.sleep(0.6)
        case("tab-rename-begins", lambda: sv.cmd({"do": "ui", "edittab": ""}), [opened["front"]])
        case("tab-rename-ends", lambda: sv.cmd({"do": "ui", "finishedit": True}), [opened["front"]])
        sv.sp("select", id=opened["short"])
        time.sleep(0.4)
        sv.sp("select", id=opened["front"])
        time.sleep(0.6)

        ids = list(pulls.values())
        case("live-arrive", comment(512, 37), ids, seconds=1.2)
        st = pr.folder(pr.live("state"), "PRs")
        t.ok("a review by someone else lights its rows", st["fresh"] == 2, st["fresh"])
        case("live-hover-in", lambda: hover(pulls[512], True), ids)
        case("live-hover-out", lambda: hover(pulls[512], False), ids)
        case("live-count-arrives", comment(41, threads=(41,)), ids, seconds=1.2)
        case("live-count-beside-a-dot", comment(threads=(37,)), ids, seconds=1.2)
        case("live-clear-beside-a-count", lambda: pr.live("seen", f"{pr.BASE}/acme/rocket/pull/41"), ids)
        case("live-dot-beside-a-count", comment(41, hour=13), ids, seconds=1.2)
        case("live-folder-fold", lambda: sv.cmd({"do": "group", "name": "PRs", "fold": True}), ids, seconds=1.2)
        case("live-folder-unfold", lambda: sv.cmd({"do": "group", "name": "PRs", "fold": True}), ids, seconds=1.2)
        case("live-folder-fold-again", lambda: sv.cmd({"do": "group", "name": "PRs", "fold": True}), ids, seconds=1.2)
        said["comments"][36] = 10
        touched(36)
        pr.live("update", "PRs")
        time.sleep(0.6)
        case("live-unfold-after-activity", lambda: sv.cmd({"do": "group", "name": "PRs", "fold": True}), ids, seconds=1.2)
        case("live-stack-fold", lambda: pr.live("stack"), ids, seconds=1.2)
        case("live-stack-unfold", lambda: pr.live("stack"), ids, seconds=1.2)
        case("live-sidebar-fold", lambda: sv.cmd({"do": "ui", "sidebar": False}), ids, seconds=1.2)
        case("live-sidebar-unfold", lambda: sv.cmd({"do": "ui", "sidebar": True}), ids, seconds=1.2)
        space = lambda action, **more: sv.cmd({"do": "space", "action": action, **more})
        space("new", name="Two")
        time.sleep(1.5)
        case("space-go-back", lambda: space("go", index=1), None, seconds=1.4)
        case("space-go-away", lambda: space("go", index=2), None, seconds=1.4)
        case("space-swipe-held", lambda: space("hold", dx=140), None, seconds=0.8)
        case("space-swipe-let-go", lambda: space("release"), None, seconds=1.4)
        if pr.folder(pr.live("state"), "PRs") is None:
            space("go", index=1)
            time.sleep(1.2)
        case("live-clear-by-landing", lambda: pr.live("seen", "https://github.com/acme/rocket/pull/512/files"), ids)
        case("live-clear-by-select", lambda: sv.sp("select", id=pulls[37]), ids, seconds=1.2,
             after=lambda: sv.sp("select", id=opened["front"]))
        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(1.5)
        calm = [case("calm-hover-in", lambda: hover(opened["front"], True), None),
                case("calm-hover-out", lambda: hover(opened["front"], False), None),
                case("calm-arrive", comment(38, hour=14), ids, seconds=1.2),
                case("calm-clear", lambda: pr.live("seen", "https://github.com/acme/rocket/pull/38"), ids)]
        if all(calm):
            t.ok("Reduce Motion: no fade sweeps at all, cross or dot", all(report["moved"] == 0 for report in calm), calm)
        (OUT / "found.json").write_text(json.dumps(found, indent=1))
        for name, report in found.items():
            if name.startswith("control"):
                continue
            t.ok(f"{name}: no frame with ink behind a showing mark, none with the fade sweeping under one "
                 f"({report['marked']} marked frames of {report['frames']})",
                 report["frames"] > (0 if name in BRIEF else 5) and report["under"] == 0 and report["sweeping"] == 0, report)
        for name in sorted(ARRIVES & set(found)):
            t.ok(f"{name}: the mark is there at full strength when it is over", found[name]["lit"] >= 1, found[name])
        still = found.get("tab-short-arrive")
        if still:
            t.ok("a short title's fade never moves when its dot comes", still["moved"] == 0, still)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

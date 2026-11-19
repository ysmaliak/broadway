#!/usr/bin/env python3
"""The comment sign at a pull request row's end, at rest, sliding and hovered.

Build first (`./build.sh`), then `python3 Tests/talk_slide_shots.py [LABEL]`.
Start it where the test copy may picture its own window (a Rex pane, not
ssh): every picture is of that window by its number (WindowShot.swift,
WindowCapture.swift), never a region of the display.

A shown test copy in a world of its own, against pr_rows.py's fake GitHub.
One pull request is given an open review thread by someone else, so its row
shows the sign and a dot, and is then marked seen, so the dot goes and the
sign alone stays. In light and in dark: the row at rest, filmed while the
pointer comes and while it goes, and hovered. Each film gives a sheet of its
frames and the frame halfway through the slide, into .context/shots/LABEL/.

Per look, on the row's own readout (`endtrace`): at rest the sign's right
edge is the close glyph's; hovered it sits a gap short of the close square;
the slide is seen between the two; in no frame does the title's shown ink
reach the sign where the sign is shown; and in no frame does the close
button show while the sign is still over its glyph.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "talk-slide"
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

OUT = ROOT / ".context" / "shots" / LABEL
TOOLS = ROOT / ".context" / "talk-slide-tools"
SHOT = TOOLS / "shot"
CAPTURE = TOOLS / "capture"
SIDEBAR = 260
THREAD = 41
t = sv.T()
said = {"thread": False}


def talk(number):
    tail = '<div class="discussion-timeline-actions"></div>'
    if number != THREAD or not said["thread"]:
        return tail
    return ('<div class="js-timeline-item" data-gid="PRR_t41"><review-thread-collapsible data-resolved="false">'
            '<a class="author" href="/dana">dana</a><relative-time datetime="2026-11-05T11:00:00Z"></relative-time>'
            '</review-thread-collapsible></div>' + tail)


pr.talk = talk
PID = None
NUMBER = None


def end(action, **more):
    return sv.cmd({"do": "ui", "endtrace": {"action": action, **more}})


def row(id):
    return next((r for r in end("now")["rows"] if r["id"] == id and r["interactive"]), None)


def hover(id, on):
    sv.cmd({"do": "rowhover", "id": id, "on": on})


def shoot(name):
    out = OUT / f"{name}.png"
    said_ = subprocess.run([str(SHOT), str(PID), str(NUMBER), str(out)], capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout.strip()
    t.ok(f"pictured {name}", out.exists(), said_)
    return out


def scale_of(picture):
    width = int.from_bytes(picture.read_bytes()[16:20], "big")
    return max(1, round(width / 1000))


def crop(r, scale):
    x, y = r["at"]
    return f"crop={int(r['width'] * scale)}:{int(34 * scale)}:{int(x * scale)}:{int(y * scale)}"


def film(name, act, r, scale, seconds=0.6):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True, exist_ok=True)
    p = subprocess.Popen([str(CAPTURE), str(PID), str(folder), str(seconds + 0.45), str(NUMBER), "2", "120"],
                         stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.15)
    end("start")
    act()
    time.sleep(seconds)
    samples = end("stop")["samples"]
    print("  ", name, p.communicate()[0].strip(), flush=True)
    (folder / "trace.json").write_text(json.dumps(samples))
    frames = sorted(folder.glob("0*.png"))
    area = crop(r, scale)
    digest = lambda f: hashlib.sha1(subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(f), "-vf", area, "-f", "rawvideo", "-"],
                                                   capture_output=True, stdin=subprocess.DEVNULL).stdout).hexdigest()
    x, y = r["at"]
    end_area = f"crop={int(64 * scale)}:{int(34 * scale)}:{int((x + r['width'] - 64) * scale)}:{int(y * scale)},format=gray"
    grey = lambda f: subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(f), "-vf", end_area, "-f", "rawvideo", "-"],
                                    capture_output=True, stdin=subprocess.DEVNULL).stdout
    far = lambda a, b: sum(abs(p - q) for p, q in zip(a, b)) / max(1, len(a))
    if len(frames) >= 4:
        sums = [digest(f) for f in frames]
        changing = [i for i in range(1, len(frames)) if sums[i] != sums[i - 1]]
        print("   film", name, len(frames), "frames", area, len(set(sums)), "looks", flush=True)
        if changing:
            ends = [grey(f) for f in frames]
            apart = [min(far(e, ends[0]), far(e, ends[-1])) for e in ends]
            middle = max(range(len(frames)), key=lambda i: apart[i])
            moving = [i for i in range(len(frames)) if far(ends[i], ends[i - 1]) > 0.05] if len(frames) > 1 else []
            first = max(0, (moving[0] if moving else changing[0]) - 1)
            last = min(len(frames) - 1, (moving[-1] if moving else changing[-1]) + 1)
            shutil.copy(frames[middle], OUT / f"{name}-mid.png")
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(frames[middle]), "-vf", area, str(OUT / f"{name}-mid-row.png")],
                           check=False, stdin=subprocess.DEVNULL)
            work = folder / "sheet"
            work.mkdir()
            for n, i in enumerate(range(first, last + 1)):
                os.symlink(frames[i], work / f"{n:04d}.png")
            count = last - first + 1
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(work / "%04d.png"),
                            "-vf", f"{area},tile=1x{count}:padding=4:color=red", "-frames:v", "1", str(OUT / f"{name}-sheet.png")],
                           check=False, stdin=subprocess.DEVNULL)
            print("   sheet", (OUT / f"{name}-sheet.png").relative_to(ROOT), f"{count} frames, middle {middle}", flush=True)
            shutil.rmtree(work, ignore_errors=True)
        for frame in frames:
            frame.unlink()
    return samples


def judge(samples, id, rest_x, aside_x, leaving):
    found = {"frames": 0, "between": 0, "under": 0, "covered": 0, "worst": 0.0, "first": []}
    for sample in samples:
        for r in sample["rows"]:
            if r["id"] != id or not r["seen"] or r["talk"] < 0.99:
                continue
            found["frames"] += 1
            shown = r["talkShownX"]
            right = shown + r["talkRight"] - r["talkX"]
            if min(rest_x, aside_x) + 0.5 < shown < max(rest_x, aside_x) - 0.5:
                found["between"] += 1
            if r["titled"] and len(r["shown"]) == 2:
                ink = min(r["x"] + r["natural"], r["shown"][1])
                over = ink - (shown - 2)
                if over > 0.5:
                    found["under"] += 1
                    found["worst"] = max(found["worst"], round(over, 1))
                    if len(found["first"]) < 6:
                        found["first"].append(["under", round(sample["t"]), round(ink, 1), round(shown, 1)])
            showing = r["cross"] > 0.05 or (leaving and r["crossTurning"])
            if showing and right > r["crossLeft"] + 0.5:
                found["covered"] += 1
                if len(found["first"]) < 6:
                    found["first"].append(["covered", round(sample["t"]), round(right, 1), round(r["crossLeft"], 1), round(r["cross"], 2)])
    return found


def main():
    global PID, NUMBER
    OUT.mkdir(parents=True, exist_ok=True)
    TOOLS.mkdir(parents=True, exist_ok=True)
    for tool, source in [(SHOT, "WindowShot.swift"), (CAPTURE, "WindowCapture.swift")]:
        if not tool.exists():
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests" / source), "-o", str(tool)], check=True, stdin=subprocess.DEVNULL)
    sv.use("talk-slide-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "start.fresh": False, "spaces": True})
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
    measures = {}
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        front = sv.cmd({"do": "open", "url": f"{pr.BASE}/home?A+page+in+front"})["id"]
        pr.live("add-page", "PRs", "pullRequests", f"{pr.BASE}{pr.PULLS}")
        pr.live("unfold", "PRs")
        prs = pr.folder(pr.live("update", "PRs"), "PRs")
        t.ok("the folder reads the fake", prs["state"] == "fine" and len(prs["items"]) >= 5, prs.get("state"))
        pulls = {int(item["url"].rsplit("/", 1)[1]): tab["id"] for tab, item in zip(prs["tabs"], prs["items"])}
        id = pulls[THREAD]
        said["thread"] = True
        pr.STAMPS[THREAD] = "2026-11-06T00:01:00Z"
        pr.live("update", "PRs")
        time.sleep(1.2)
        pr.live("seen", f"{pr.BASE}/acme/rocket/pull/{THREAD}")
        sv.sp("select", id=id)
        time.sleep(1.2)
        sv.sp("select", id=front)
        NUMBER = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        sv.cmd({"do": "idle", "action": "front"})
        time.sleep(1.2)
        r = row(id)
        item = next((i for i in pr.folder(pr.live("state"), "PRs")["items"] if i["url"].endswith(f"/{THREAD}")), None)
        t.ok("the row shows the sign and no dot", r and r["talk"] > 0.99 and r["dot"] == 0, (r and {k: r[k] for k in ("talk", "dot")}, item))
        if not r or r["talk"] < 0.99 or r["dot"] > 0:
            return
        for theme in ("light", "dark"):
            sv.cmd({"do": "ui", "look": theme})
            time.sleep(0.8)
            rest = row(id)
            scale = scale_of(shoot(f"{theme}-rest"))
            hover(id, True)
            time.sleep(0.6)
            over = row(id)
            hover(id, False)
            time.sleep(0.6)
            rest_x, aside_x = rest["talkX"], over["talkX"]
            came = film(f"{theme}-hover-in", lambda: hover(id, True), rest, scale)
            shoot(f"{theme}-hovered")
            went = film(f"{theme}-hover-out", lambda: hover(id, False), rest, scale)
            back = row(id)
            m = {"rest": {"talkX": rest["talkX"], "talkRight": rest["talkRight"], "crossRight": round(rest["crossRight"], 2),
                          "crossLeft": round(rest["crossLeft"], 2), "titleEnd": round(rest["model"][1], 2), "width": rest["width"]},
                 "hovered": {"talkX": over["talkX"], "talkRight": over["talkRight"], "titleEnd": round(over["model"][1], 2)},
                 "in": judge(came, id, rest_x, aside_x, False), "out": judge(went, id, rest_x, aside_x, True)}
            measures[theme] = m
            print("  ", theme, json.dumps(m), flush=True)
            t.ok(f"{theme}: at rest the sign's right edge is the close glyph's", abs(rest["talkRight"] - rest["crossRight"]) <= 0.5,
                 (rest["talkRight"], rest["crossRight"]))
            t.ok(f"{theme}: hovered the sign sits a gap short of the close square and the close shows",
                 over["talkX"] < rest_x - 4 and over["cross"] > 0.99 and over["talkRight"] + 3 <= rest["crossLeft"], m["hovered"])
            t.ok(f"{theme}: the title gives the sign's room back at rest", rest["model"][1] > over["model"][1] + 4, m)
            for way in ("in", "out"):
                j = m[way]
                t.ok(f"{theme}: hover {way}: the sign is seen sliding, no ink reaches it and the close never shows over it",
                     j["frames"] > 5 and j["between"] >= 2 and j["under"] == 0 and j["covered"] == 0, j)
            t.ok(f"{theme}: when the pointer has left, it is all back at rest", back["talkX"] == rest_x and back["model"] == rest["model"],
                 (back["talkX"], rest_x))
        (OUT / "measures.json").write_text(json.dumps(measures, indent=1))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

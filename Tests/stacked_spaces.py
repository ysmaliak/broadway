#!/usr/bin/env python3
"""Stacked spaces: every space as a section of one column.

Build first (`./build.sh`), then `python3 Tests/stacked_spaces.py`. It uses
the split suite's harness: started hidden in a world of its own, no window
shown or brought forward, everything removed afterwards. Three spaces with
pages in each; the mode switched on through Settings' own control; every
section drawn under its header; a tab in another section selected without
a slide; a section folded and unfolded; a tab dropped on another section;
⌃1–⌃3 jumping to sections; a header carried to reorder the spaces, put
back by Esc, and filmed; a swipe doing nothing; the choice kept across a
relaunch and switched back off.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("stacked-spaces")

DIGITS = {1: 18, 2: 19, 3: 20}


def st(**f): return sv.cmd({"do": "stacked", **f})
def choice(v=None):
    req = {"do": "settings"}
    if v: req.update({"set": "spaces.stacked", "value": v})
    return sv.cmd(req)["values"]["spaces.stacked"]


def settle(want, within=4, **f):
    until = time.time() + within
    while True:
        r = st(**f) if f else st()
        if want(r) or time.time() > until: return r
        time.sleep(0.2)


def section(r, index): return r["sections"][index]


def centre(r, index):
    h = section(r, index)["header"]
    return [r["page"]["x"] + 120, r["page"]["y"] + h["y"] + h["height"] / 2]


def carry(r, tab, index):
    start = [r["page"]["x"] + 120, r["page"]["y"] + section(r, 0)["header"]["y"] + 50]
    end = centre(r, index)
    points = [[start[0], start[1] + (end[1] - start[1]) * k / 6] for k in range(7)] + [end]
    return sv.cmd({"do": "film", "action": "pindrag", "id": tab, "points": points, "frames": 12, "every": 0.04,
                   "path": os.path.join(sv.SUPPORT, "drag")})


def mine():
    out = subprocess.run(["ps", "eww", "-ax", "-o", "pid,command"], capture_output=True, text=True).stdout
    return [line.split()[0] for line in out.splitlines() if f"SEARCH_PROBE={sv.W} " in line + " "]


def negatives(pids=None):
    found = 0
    for pid in pids or mine():
        r = subprocess.run(["log", "show", "--predicate", f"processID == {pid}", "--last", "15m"],
                           capture_output=True, text=True)
        found += sum("Invalid view geometry" in line for line in r.stdout.splitlines())
    return found


def press_space(n):
    sv.cmd({"do": "press", "code": DIGITS[n], "chars": str(n), "mods": ["ctrl"]})
    time.sleep(0.4)


def main():
    t = sv.T()
    sv.setup(spaces=True)
    sv.launch()
    try:
        first = sv.sp("state")["spaceID"]
        a = sv.page("one-a"); b = sv.page("one-b")
        second = sv.sp("space", spaceAction="new", name="Work")["spaceID"]
        c = sv.page("work-c"); d = sv.page("work-d")
        third = sv.sp("space", spaceAction="new", name="Travel")["spaceID"]
        e = sv.page("travel-e")
        sv.sp("space", spaceAction="go", spaceID=first)
        sv.sp("select", id=a)

        r = st()
        t.ok("side by side by default", r["stacked"] is False and choice() == "side", r["stacked"])

        t.ok("Settings' control turns stacked on", choice("stacked") == "stacked")
        r = settle(lambda r: all(s["header"] for s in r["sections"]), action="load")
        t.ok("stacked mode is on", r["stacked"] is True)
        t.ok("three sections, in the spaces' order",
             [s["id"] for s in r["sections"]] == [first, second, third], [s["name"] for s in r["sections"]])
        t.ok("every section's header is drawn", all(s["header"] for s in r["sections"]),
             [s["header"] for s in r["sections"]])
        ys = [s["header"]["y"] for s in r["sections"] if s["header"]]
        t.ok("headers run top to bottom", ys == sorted(ys) and len(set(ys)) == len(ys), ys)
        t.ok("each section holds its own tabs",
             a in section(r, 0)["tabs"] and c in section(r, 1)["tabs"] and e in section(r, 2)["tabs"]
             and c not in section(r, 0)["tabs"] and a not in section(r, 1)["tabs"],
             [s["tabs"] for s in r["sections"]])
        t.ok("each section draws its rows",
             a in section(r, 0)["drawn"] and d in section(r, 1)["drawn"] and e in section(r, 2)["drawn"],
             [s["drawn"] for s in r["sections"]])

        r = st(action="select", id=d)
        t.ok("a tab in another section: its space becomes the window's", r["space"] == second, r["space"])
        t.ok("…and the tab is the one in front", r["active"] == d, r["active"])
        t.ok("…with no slide: the ground only fades", r["spaceNext"] in (-1, 0), r["spaceNext"])
        r = settle(lambda r: r["spaceNext"] == -1)
        t.ok("the fade ends", r["spaceNext"] == -1, r["spaceNext"])
        t.ok("the space left keeps its tabs as a section", a in section(r, 0)["tabs"] and a in section(r, 0)["drawn"])
        t.ok("a tab in the space left is still there to go back to",
             st(action="select", id=b)["active"] == b and st()["space"] == first)

        r = st(action="fold", space=3)
        t.ok("folding Travel remembers it", section(r, 2)["folded"] is True)
        r = settle(lambda r: section(r, 2)["drawn"] == [])
        t.ok("a folded section draws only its header", section(r, 2)["drawn"] == [] and section(r, 2)["header"], section(r, 2))
        r = st(action="fold", space=3)
        r = settle(lambda r: e in section(r, 2)["drawn"])
        t.ok("unfolded, its rows come back", e in section(r, 2)["drawn"], section(r, 2))

        r = st()
        dragged = carry(r, a, 1)
        crossed = [line.split()[-1] for line in dragged["probe"]]
        t.ok("a row carried over Work's header lights it", "true" in crossed, dragged["probe"])
        r = settle(lambda r: a in section(r, 1)["tabs"])
        t.ok("…and let go there, it moves to Work", a in section(r, 1)["tabs"] and a not in section(r, 0)["tabs"],
             [s["tabs"] for s in r["sections"]])
        t.ok("…and nothing stays lit", r["lit"] == "", r["lit"])
        t.ok("the space on screen stays the one it came from", r["space"] == first, r["space"])

        r = st(action="drop", id=b, space=3)
        r = settle(lambda r: b in section(r, 2)["tabs"])
        t.ok("a tab dropped on Travel moves there", b in section(r, 2)["tabs"] and b not in section(r, 0)["tabs"],
             [s["tabs"] for s in r["sections"]])

        press_space(2)
        r = st()
        t.ok("⌃2 goes to Work's section", r["space"] == second, r["space"])
        press_space(3)
        r = settle(lambda r: r["scrolled"] > 0)
        t.ok("⌃3 goes to Travel's section", r["space"] == third, r["space"])
        press_space(1)
        r = st()
        t.ok("⌃1 back to the first", r["space"] == first, r["space"])

        st(action="fold", space=2, on=True)
        r = st(action="jump", space=2)
        t.ok("a jump to a folded section unfolds it", section(r, 1)["folded"] is False and r["space"] == second)

        here = st()["space"]
        sv.cmd({"do": "space", "action": "swipe", "dx": -160})
        time.sleep(0.8)
        t.ok("a swipe changes nothing while stacked", st()["space"] == here)

        r = st(action="newtab", space=1)
        t.ok("a section's + opens a tab in that space", r["space"] == first, r["space"])

        st(action="fold", space=3, on=True)
        before = [s["folded"] for s in st()["sections"]]
        y0 = section(st(), 0)["header"]["y"]
        r = st(action="lift", space=1)
        t.ok("a header pressed and moved lifts its space", r["carrying"] == first, r["carrying"])
        r = settle(lambda r: all(s["drawn"] == [] for s in r["sections"]))
        t.ok("…and every section gathers to its header while it is carried",
             all(s["drawn"] == [] for s in r["sections"]), [s["drawn"] for s in r["sections"]])
        heads = sorted(s["header"]["y"] for s in r["sections"])
        step = heads[1] - heads[0]
        t.ok("…with the carried header where it was picked up", abs(section(r, 0)["header"]["y"] - y0) < 1,
             (section(r, 0)["header"]["y"], y0))
        r = st(action="carry", dy=step * 1.2)
        t.ok("carried past half of Work, Work makes room above it", r["order"] == [second, first, third], r["order"])
        t.ok("…and the space order isn't changed until it is let go",
             [s["id"] for s in r["sections"]] == [first, second, third])
        r = settle(lambda r: abs(section(r, 0)["header"]["y"] - (y0 + step)) < 1)
        t.ok("…the carried header stays under the hand",
             abs(section(r, 0)["header"]["y"] + r["shift"] - (y0 + step * 1.2)) < 2,
             (section(r, 0)["header"]["y"], r["shift"], y0, step))
        r = st(action="letgo")
        t.ok("let go, the new order is the spaces' own",
             [s["id"] for s in r["sections"]] == [second, first, third] and r["carrying"] == "",
             [s["name"] for s in r["sections"]])
        t.ok("…and the window's spaces follow it", [s["id"] for s in sv.cmd({"do": "space"})["spaces"]] == [second, first, third])
        r = settle(lambda r: d in section(r, 0)["drawn"] or c in section(r, 0)["drawn"])
        t.ok("…the sections open again as they were",
             [s["folded"] for s in r["sections"]] == [before[1], before[0], before[2]] and section(r, 1)["drawn"],
             [(s["name"], s["folded"], s["drawn"], s["header"], s["tabs"]) for s in r["sections"]] + [r["scrolled"], r["space"], r["carrying"], r["lead"]])
        press_space(1)
        t.ok("⌃1 now goes to Work, the new first", st()["space"] == second, st()["space"])

        r = st(action="lift", space=1)
        r = st(action="carry", dy=step * 2.2)
        t.ok("carried again, the order shown changes", r["order"] == [first, third, second], r["order"])
        sv.cmd({"do": "press", "code": 53, "chars": "\x1b", "mods": []})
        r = settle(lambda r: r["carrying"] == "")
        t.ok("Esc puts it back", r["carrying"] == "" and r["order"] == [second, first, third], (r["carrying"], r["order"]))
        r = st(action="letgo")
        t.ok("…and letting go after Esc moves nothing", [s["id"] for s in r["sections"]] == [second, first, third],
             [s["name"] for s in r["sections"]])

        r = st(action="lift", space=2)
        r = st(action="letgo")
        t.ok("lifted and let go in place, nothing moves", [s["id"] for s in r["sections"]] == [second, first, third])

        filmed = sv.cmd({"do": "film", "action": "headerdrag", "space": 1, "dys": [step * k / 8 for k in range(1, 11)],
                         "frames": 24, "every": 0.03, "path": os.path.join(os.environ.get("STACKED_FILM", sv.SUPPORT), "header")})
        r = settle(lambda r: r["carrying"] == "" and [s["id"] for s in r["sections"]] == [first, second, third])
        t.ok("a filmed drag puts the spaces back in their first order", [s["id"] for s in r["sections"]] == [first, second, third],
             [s["name"] for s in r["sections"]])
        t.ok("…and drew every frame", len(filmed.get("frames", [])) == 24, filmed.get("error"))
        r = settle(lambda r: [s["folded"] for s in r["sections"]] == before)
        t.ok("no section's fold changed through any of it", [s["folded"] for s in r["sections"]] == before,
             [s["folded"] for s in r["sections"]])
        st(action="fold", space=3, on=False)
        t.ok("the spaces' order is kept: Spaces menu, ⌃ and the foot read the same list",
             [s["id"] for s in sv.cmd({"do": "space"})["spaces"]] == [first, second, third])

        sv.quit(); sv.launch()
        t.ok("the choice is kept across a relaunch", choice() == "stacked")
        r = settle(lambda r: all(s["header"] for s in r["sections"]), action="load")
        t.ok("…and the sections are drawn again", all(s["header"] for s in r["sections"]), [s["header"] for s in r["sections"]])

        bad = negatives()
        t.ok("no view was given a negative width", bad == 0, bad)

        t.ok("switched back to side by side", choice("side") == "side" and st()["stacked"] is False)
        sv.sp("space", spaceAction="go", spaceID=first)
        sv.cmd({"do": "space", "action": "swipe", "dx": -160})
        time.sleep(1.2)
        t.ok("side by side, a swipe goes to the next space again", sv.sp("state")["spaceID"] == second)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


FILM = os.environ.get("STACKED_FILM")
PAINT = {}


def trace(act, forget=False, rest=0.7, film=None):
    ask = {"action": "start", "forget": forget}
    if film:
        film = os.path.abspath(film)
        os.makedirs(film, exist_ok=True)
        for old in Path(film).glob("frame-*.png"): old.unlink()
        ask.update({"film": os.path.join(film, "frame"), "paint": PAINT})
    sv.cmd({"do": "ui", "stagetrace": ask})
    act()
    time.sleep(rest)
    out = sv.cmd({"do": "ui", "stagetrace": {"action": "stop"}})
    if film: sheet(film, out["samples"])
    return out["samples"]


def sheet(folder, samples):
    files = sorted(Path(folder).glob("frame-*.png"))
    if not files: return
    samples = [x for x in samples if not x.get("cycle")]
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "120", "-i", os.path.join(folder, "frame-%03d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", os.path.join(folder, "film.mp4")], check=False)
    turned = next((i for i, x in enumerate(samples) if x["active"] != samples[0]["active"]), 1)
    picked = files[max(0, turned - 1):][:12]
    listing = Path(folder) / "sheet.txt"
    listing.write_text("".join(f"file '{f}'\n" for f in picked))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
                    "-vf", "scale=480:-1,tile=4x3:padding=6:color=gray", "-frames:v", "1", os.path.join(folder, "sheet.jpg")], check=False)
    (Path(folder) / "samples.json").write_text(__import__("json").dumps(samples))


def judged(samples, want, also=()):
    moved = [(round(s["t"]), round(s.get("pageX", 0), 1), round(s.get("pageOpacity", 1), 2)) for s in samples
             if abs(s.get("pageX", 0)) > 0.5 or s.get("pageOpacity", 1) < 0.99]
    seen = [(round(s["t"]), s["intruders"]) for s in samples if s.get("intruders")]
    landed = next((i for i, s in enumerate(samples) if s["active"] == want), None)
    wrong = ["never landed"] if landed is None else \
        [(round(s["t"]), s.get("webs")) for s in samples[landed:] if not all(x in s.get("webs", []) for x in (want, *also))]
    left = samples[0].get("webs", []) if samples else []
    stray = [(round(s["t"]), s.get("webs")) for s in samples[:landed or 0]
             if any(x not in (*left, want, *also) for x in s.get("webs", []))]
    heads = [(round(s["t"]), k, round(v - samples[0]["heads"].get(k, v), 1)) for s in samples for k, v in s["heads"].items()
             if abs(v - samples[0]["heads"].get(k, v)) > 0.5]
    scrolls = [(round(s["t"]), s["scrolled"]) for s in samples if abs(s["scrolled"] - samples[0]["scrolled"]) > 0.5]
    times = [s["t"] for s in samples]
    gap = max((b - a for a, b in zip(times, times[1:])), default=0)
    return {"frames": len(samples), "span": times[-1] - times[0] if times else 0, "gap": round(gap), "moved": moved, "intruders": seen, "landed": landed, "wrong": wrong, "stray": stray,
            "heads": heads, "scrolls": scrolls, "announced": sorted({s["announced"] for s in samples if s["announced"]})}


def still_case(t, name, act, want, space, also=(), forget=False, announces=False, film=None):
    time.sleep(1.8)
    r = judged(trace(act, forget=forget, film=film), want, also)
    print(f"    {name}: {r['frames']} frames over {round(r['span'])} ms, longest gap {r['gap']} ms, landed at {r['landed']}, "
          f"moved {len(r['moved'])}, intruders {len(r['intruders'])}")
    t.ok(f"{name}: sampled from the click until rest", r["frames"] >= 4 and r["span"] >= 600, (r["frames"], r["span"]))
    t.ok(f"{name}: the page never leaves rest", not r["moved"], r["moved"][:6])
    t.ok(f"{name}: no picture or preview of a space in the page area", not r["intruders"], r["intruders"][:6])
    t.ok(f"{name}: the new tab is on screen from its first frame", r["landed"] is not None and not r["wrong"], (r["landed"], r["wrong"][:4]))
    t.ok(f"{name}: no other tab of the space is on screen on the way", not r["stray"], r["stray"][:4])
    t.ok(f"{name}: the sidebar holds still", not r["heads"] and not r["scrolls"], (r["heads"][:4], r["scrolls"][:4]))
    if announces:
        t.ok(f"{name}: the space is announced", space in r["announced"], r["announced"])
    else:
        t.ok(f"{name}: nothing is announced", space not in r["announced"], r["announced"])
    return r


def still():
    t = sv.T()
    sv.setup(spaces=True)
    sv.launch()
    try:
        first = sv.sp("state")["spaceID"]
        a = sv.page("still-a"); b = sv.page("still-b")
        second = sv.sp("space", spaceAction="new", name="Work")["spaceID"]
        c = sv.page("still-c"); d = sv.page("still-d")
        PAINT.update({a: "b04a32", b: "c9782c", c: "2f6f9e", d: "3d8c6a"})
        sv.sp("space", spaceAction="go", spaceID=first)
        sv.sp("select", id=a)
        choice("stacked")
        settle(lambda r: all(s["header"] for s in r["sections"]), action="load")
        time.sleep(1)

        def select(tab): return lambda: st(action="select", id=tab)
        def front(index): return st()["sections"][index]["front"]
        def back(tab):
            time.sleep(0.3); st(action="select", id=tab); time.sleep(0.6)

        for forget in (False, True):
            kept = "no picture" if forget else "kept picture"
            film = os.path.join(FILM, "personal-to-work") if FILM and not forget else None
            still_case(t, f"Personal → Work tab, {kept}", select(d), d, "Work", forget=forget, film=film)
            still_case(t, f"Work → Personal tab, {kept}", select(b), b, "Personal", forget=forget)
            back(a)

        time.sleep(1.8)
        samples = trace(lambda: st(action="newtab", space=2))
        now = st()
        fresh = now["active"]
        r = judged(samples, fresh)
        left = samples[0].get("webs", []) if samples else []
        others = [(round(s["t"]), s.get("webs")) for s in samples if any(x not in (*left, fresh) for x in s.get("webs", []))]
        print(f"    New Tab in Work's section: {r['frames']} frames over {round(r['span'])} ms, landed at {r['landed']}, "
              f"first frames {[(round(s['t']), s['active'], s.get('webs')) for s in samples[:4]]}")
        t.ok("New Tab in Work's section opens a tab there", now["space"] == second and fresh in now["sections"][1]["tabs"]
             and fresh not in (c, d), (fresh, now["space"]))
        t.ok("New Tab in Work's section: no other tab of the space is on screen on the way", not others, others[:4])
        t.ok("New Tab in Work's section: the page never leaves rest", not r["moved"], r["moved"][:6])
        t.ok("New Tab in Work's section: no picture or preview of a space in the page area", not r["intruders"], r["intruders"][:6])
        t.ok("New Tab in Work's section: the column doesn't scroll", not r["scrolls"], r["scrolls"][:4])
        t.ok("New Tab in Work's section: nothing is announced", "Work" not in r["announced"], r["announced"])
        sv.sp("select", id=c)
        e = sv.page("still-e")
        sv.cmd({"do": "pin", "id": e})
        pinned = sv.cmd({"do": "pin", "id": e, "everywhere": False})
        t.ok("a pin kept only in Work", pinned["pin"] and pinned["everywhere"] is False, pinned)
        sv.sp("select", id=c)
        back(a)
        still_case(t, "Personal → a pin of Work", select(e), e, "Work")
        sv.sp("select", id=c)
        back(a)

        still_case(t, "a jump to Work", lambda: st(action="jump", space=2), front(1), "Work", announces=True)
        back(a)
        still_case(t, "⌃2", lambda: press_space(2), front(1), "Work", announces=True)
        back(a)
        still_case(t, "the space switched from outside (broadway)", lambda: sv.cmd({"do": "space", "action": "go", "index": 2}),
                   front(1), "Work")
        sv.sp("select", id=c)
        sv.sp("pair", id=d, **{"with": c}, side="right")
        time.sleep(0.8)
        back(a)
        still_case(t, "Personal → a split pair in Work", select(c), c, "Work", also=(d,))
        still_case(t, "a split pair in Work → Personal", select(b), b, "Personal")
        back(a)
        still_case(t, "Personal → a split pair in Work, no picture", select(d), d, "Work", also=(c,), forget=True)

        choice("side")
        time.sleep(1)
        sv.sp("space", spaceAction="go", spaceID=first)
        time.sleep(1.8)
        samples = trace(lambda: sv.cmd({"do": "space", "action": "slide", "index": 2}), rest=1.0)
        r = judged(samples, "")
        print(f"    side by side: {r['frames']} frames over {round(r['span'])} ms, moved {len(r['moved'])}, intruders {len(r['intruders'])}")
        print("    page x:", [(round(s["t"]), round(s.get("pageX", 0))) for s in samples])
        far = max((abs(x) for _, x, _ in r["moved"]), default=0)
        t.ok("side by side, the space still slides: the page travels", len(r["moved"]) >= 2 and far > 100, r["moved"][:6])
        t.ok("…and the next space's picture or preview rides in beside it", len(r["intruders"]) >= 1, r["intruders"][:4])
        t.ok("…and lands in Work", sv.sp("state")["spaceID"] == second)
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    if sys.argv[1:] == ["still"]: sys.exit(still())
    sys.exit(main() | still())

#!/usr/bin/env python3
"""The agents card rides with its space, and nothing in the column moves when a switch settles.

Build first (`./build.sh`), then `python3 Tests/card_ride.py [OUT]`. A test copy in a
world of its own (SEARCH_SHOWN, so the ride runs as on screen), its window below the
desktop. Two spaces: Work, with twenty tabs, the list scrolled part way, a tab near the
end in front and a stand-in agent holding a tab of its own (so Work has the agents card),
and Home, with three tabs and no agent.

Each switch is traced every frame by the app itself (bench "space pagetrace"): every page
and card the column draws, where it is in the ride, its height, its list offset and every
row's place.

- ride: during a ride, a space with sessions has its card on its own page, at the page's x,
  and a space without has no card and a list that reaches the foot.
- land: at the last frame of the ride, the page that lands has the rows, list height, list
  offset and card it has once the switch has settled.
- still: from the end of the ride on, nothing on that page moves: no offset change, no row
  that moves, no card that comes or goes.
- the agent's tab is never a row in the list, on the incoming page either.

Switches: a swipe each way, a swipe let go halfway that springs back, the space shortcut
each way, and the same under Reduce Motion. BROADWAY_PROBE_APP picks another build, for
before and after. Out: .context/card-ride/result.txt.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("card-ride")

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/card-ride")
BROADWAY = str(Path(sv.APP) / "Contents/Helpers/broadway")
CLAUDE = {"BROADWAY_AGENT": "claude-ride", "BROADWAY_AGENT_NAME": "Claude Code"}
WIDTH, HEIGHT = 1000, 620
t = sv.T()
lines = []


def ok(name, cond, extra=""):
    lines.append(f"{'ok  ' if cond else 'FAIL'} {name}" + ("" if cond else f"  {str(extra)[:600]}"))
    t.ok(name, cond, str(extra)[:600])


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def broadway(*words, env=None):
    made = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_")}
    made.update(env or {})
    run = subprocess.run([BROADWAY, "--world", sv.W, *words, "--json"], capture_output=True, text=True,
                         stdin=subprocess.DEVNULL, env=made, timeout=60)
    try:
        return json.loads(run.stdout)
    except ValueError:
        return {"ok": False, "raw": run.stdout + run.stderr}


def space(**f):
    return sv.cmd({"do": "space", **f})


def pages():
    return space(action="pages")


CAPTURE = ROOT / ".context/capture"
WINDOW = [0]


def film(name, act, seconds=1.6):
    if not os.environ.get("FILM"):
        return act()
    if not CAPTURE.exists():
        CAPTURE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], capture_output=True)
    pid = next(iter(sv.holding() & sv.running()), None)
    folder = OUT / f"film-{name}"
    subprocess.run(["rm", "-rf", str(folder)])
    folder.mkdir(parents=True)
    run = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(WINDOW[0]), "2"], stdout=subprocess.PIPE, text=True)
    for _ in range(240):
        if (folder / "ready").exists() or run.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.25)
    act()
    run.communicate()
    frames = sorted(folder.glob("*.png"))
    if len(frames) < 10:
        print(f"  no film for {name}", flush=True)
        return None
    step = max(1, len(frames) // 24)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", f"select='not(mod(n\\,{step}))',crop=iw*0.3:ih:0:0,scale=iw/2:-1,tile=12x2:padding=4", "-frames:v", "1",
                    str(OUT / f"{name}-sheet.png")], stdin=subprocess.DEVNULL)
    return None


def trace(act, name, seconds=2.4):
    space(action="pagetrace", seconds=seconds)
    time.sleep(0.05)
    film(name.replace(" ", "-") + ("-reduced" if os.environ.get("REDUCED") == "1" else ""), act)
    time.sleep(seconds + 0.3)
    frames = space(action="pagetrace", report=True)["frames"]
    for _ in range(40):
        now = pages()
        if not now["moving"] and not now["adopted"]:
            break
        time.sleep(0.1)
    now["t"] = frames[-1]["t"] + 1 if frames else 0
    return frames + [now]


def page_of(frame, name):
    found = [p for p in frame["shown"] if p["kind"] == "page" and p["space"] == name]
    return min(found, key=lambda p: abs(p["x"] + frame["ride"])) if found else None


def card_of(frame, name):
    found = [c for c in frame["shown"] if c["kind"] == "card" and c["space"] == name]
    return min(found, key=lambda c: abs(c["x"] + frame["ride"])) if found else None


def shape(frame, name):
    page, card = page_of(frame, name), card_of(frame, name)
    if not page:
        return None
    return {"height": round(page["height"], 1), "list": round(page["list"], 1), "offset": round(page["offset"], 1),
            "rows": {k: round(v[0], 1) for k, v in page["rows"].items()},
            "card": None if not card else (round(card["y"], 1), round(card["h"], 1), round(card["x"] - page["x"], 1),
                                           card["top"].get("title"), card["top"].get("line"),
                                           round((card["top"].get("titleBox") or [0, 0, 0])[2], 1))}


def differ(a, b):
    if a is None or b is None:
        return "missing"
    out = {}
    for key in ("height", "list", "offset", "card"):
        if a[key] != b[key] and not (isinstance(a[key], float) and abs(a[key] - b[key]) <= 0.5):
            out[key] = (a[key], b[key])
    moved = {k: (a["rows"].get(k), b["rows"].get(k)) for k in set(a["rows"]) | set(b["rows"])
             if a["rows"].get(k) is None or b["rows"].get(k) is None or abs(a["rows"][k] - b["rows"][k]) > 0.5}
    if moved:
        out["rows"] = dict(list(moved.items())[:6])
    return out


def check(label, frames, land, leave, cards, agent_row):
    if len(frames) < 10:
        ok(f"{label}: traced", False, len(frames))
        return
    last = frames[-1]
    ok(f"{label}: lands in {land}", last["here"] == land and not last["moving"] and not last["adopted"],
       (last["here"], last["moving"], last["adopted"]))
    settled = shape(last, land)
    riding = [f for f in frames if f["moving"]]
    if riding:
        end = riding[-1]
        ok(f"{label}: at the last ride frame {land}'s page is what lands", not differ(shape(end, land), settled),
           differ(shape(end, land), settled))
        for name in (land, leave):
            wrong = []
            for f in riding:
                page, card = page_of(f, name), card_of(f, name)
                if page is None or abs(page["x"] + f["ride"]) >= page.get("w", WIDTH):
                    continue
                if cards[name] and (card is None or abs(card["x"] - page["x"]) > 0.5 or abs(card["y"] - page["height"]) > 0.5):
                    wrong.append((round(f["t"], 3), page and page["x"], card and (card["x"], card["y"])))
                if not cards[name] and card is not None:
                    wrong.append((round(f["t"], 3), "a card", card["x"]))
                if card is not None and not card.get("drawn", True):
                    wrong.append((round(f["t"], 3), "a card AppKit does not draw", card["x"]))
            ok(f"{label}: {name}'s card {'rides on its page' if cards[name] else 'is absent'} through the ride", not wrong, wrong[:4])
    after = [f for f in frames if not f["moving"] and frames.index(f) > (frames.index(riding[-1]) if riding else -1)]
    moves = []
    for f in after:
        gap = differ(shape(f, land), settled)
        if gap:
            moves.append((round(f["t"], 3), f["adopted"], gap))
    ok(f"{label}: nothing on {land}'s page moves once the ride is over", not moves, moves[:3])
    listed = [f for f in frames if agent_row in (shape(f, "Work") or {"rows": {}})["rows"]]
    ok(f"{label}: the agent's tab is never a list row", not listed, [round(f["t"], 3) for f in listed[:4]])


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    reduced = os.environ.get("REDUCED") == "1"
    try:
        sv.setup(**{"sidebar": True, "layout.cards": True, "start.fresh": False, "agents.on": True, "spaces": True,
                    "motion.testReduced": reduced})
        launch()
        sv.cmd({"do": "window"})
        WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": True, "size": [WIDTH, HEIGHT]})["window"]
        time.sleep(0.8)
        space(action="rename", name="Work", icon="briefcase")
        work = [sv.page(f"work-{n:02d}") for n in range(20)]
        agent = broadway("open", sv.BASE + "/agent-tab", env=CLAUDE).get("data", {}).get("id", "")
        broadway("wait", "--tab", agent, env=CLAUDE)
        sv.sp("select", id=work[2])
        time.sleep(0.6)
        sv.cmd({"do": "columnscroll", "wheel": 2000, "y": 200})
        time.sleep(0.8)
        left = shape(pages(), "Work") or {"rows": {}, "offset": 0}
        space(action="new", name="Home")
        time.sleep(1.0)
        space(action="rename", name="Home", icon="house")
        for n in range(3):
            sv.page(f"home-{n}")
        space(action="goto", index=1)
        time.sleep(1.6)
        now = pages()
        work_card = card_of(now, "Work")
        ok("setup: Work shows its agents card", now["here"] == "Work" and work_card is not None and work_card["h"] > 20, now)
        ok("setup: Work's front tab is scrolled out of view, so a reveal would move the list",
           work[2].lower()[:8] not in left["rows"] and left["offset"] > 100, left)
        back = shape(now, "Work")
        ok("reveal: back in Work the list is where it was left, its front tab still out of view", not differ(back, left),
           differ(back, left))
        agent_row = agent.lower()[:8]
        cards = {"Work": True, "Home": False}

        switches = [
            ("swipe Work to Home", lambda: space(action="swipe", dx=-200), "Home", "Work"),
            ("swipe Home to Work", lambda: space(action="swipe", dx=200), "Work", "Home"),
            ("shortcut Work to Home", lambda: space(action="goto", index=2), "Home", "Work"),
            ("shortcut Home to Work", lambda: space(action="goto", index=1), "Work", "Home"),
        ]
        for label, act, land, leave in switches:
            frames = trace(act, label)
            (OUT / f"{label.replace(' ', '-')}{'-reduced' if reduced else ''}.json").write_text(json.dumps(frames))
            check(label + (" (Reduce Motion)" if reduced else ""), frames, land, leave, cards, agent_row)
            time.sleep(0.6)

        if not reduced:
            before = shape(pages(), "Work")

            def halfway():
                space(action="hold", dx=-30)
                time.sleep(0.35)
                space(action="release")

            frames = trace(halfway, "let go halfway")
            (OUT / "let-go-halfway.json").write_text(json.dumps(frames))
            last = frames[-1]
            ok("let go halfway: springs back to Work", last["here"] == "Work" and not last["moving"], (last["here"], last["moving"]))
            ok("let go halfway: Work is as it was", not differ(shape(last, "Work"), before), differ(shape(last, "Work"), before))
            homes = [f for f in frames if f["moving"] and card_of(f, "Home")]
            ok("let go halfway: Home never shows a card", not homes, [round(f["t"], 3) for f in homes[:4]])
    finally:
        sv.finish()
    (OUT / f"result{'-reduced' if reduced else ''}.txt").write_text("\n".join(lines) + f"\n{t.passed} passed, {t.failed} failed\n")
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())

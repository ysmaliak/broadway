#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fullscreen-tab")
SHOTS = Path(sys.argv[sys.argv.index("--shots") + 1]) if "--shots" in sys.argv else None
IN_FULLSCREEN = 2

FIXTURE = """
document.body.innerHTML = '';
document.body.style.margin = '0';
document.body.style.background = '#1d6fd8';
var video = document.createElement('video');
video.id = 'video';
video.style.cssText = 'width:320px;height:180px;background:#e8c547;display:block;margin:20px';
var go = document.createElement('button');
go.id = 'go';
go.textContent = 'Full screen';
go.style.cssText = 'font-size:20px;margin:20px';
go.onclick = function () { video.requestFullscreen(); };
document.body.appendChild(video);
document.body.appendChild(go);
1
"""


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")
    sv.cmd({"do": "idle", "action": "unhide"})


def probe():
    return sv.cmd({"do": "probe"})


def stage_of(p, tab):
    return next((s["frame"] for s in p.get("stages", []) if s.get("page") == tab), None)


def stand_ins(p):
    return p.get("standIns", [])


def wait(cond, within=8.0):
    end = time.time() + within
    while time.time() < end:
        p = probe()
        if cond(p):
            return p
        time.sleep(0.15)
    return probe()


def full(tab):
    return lambda p: p.get("fullscreenStates", {}).get(tab) == IN_FULLSCREEN


def home(tab):
    return lambda p: tab not in p.get("fullscreenStates", {}) and not stand_ins(p)


def go_full(tab):
    sv.ev(tab, FIXTURE)
    time.sleep(0.3)
    sv.cmd({"do": "tap", "id": tab, "selector": "#go"})
    return wait(full(tab))


def hit(x, y):
    return sv.cmd({"do": "hit", "x": x, "y": y})["view"]


def on_stand_in(x, y):
    return sv.cmd({"do": "hit", "x": x, "y": y}).get("standIn") is True


def middle(frame):
    return frame[0] + frame[2] / 2, frame[1] + frame[3] / 2


def click(x, y):
    sv.sp("mouse", points=[[x, y], [x, y]], to="view")


def window_number(p):
    return next((w["number"] for w in p.get("windows", [])
                 if w["visible"] and w["frame"][2] > 400 and "FullScreen" not in w["kind"]), None)


def shoot(name):
    if not SHOTS:
        return
    SHOTS.mkdir(parents=True, exist_ok=True)
    number = window_number(probe())
    if number:
        subprocess.run(["screencapture", "-x", "-o", "-l", str(number), str(SHOTS / f"{name}.png")], capture_output=True)


def fullscreen_windows(p):
    return [w for w in p.get("windows", []) if "FullScreen" in w["kind"] and w["visible"]]


def alone(t):
    name = "alone"
    sv.setup(sidebar=True, splitView=False); launch()
    b = sv.page("b")
    a = sv.page("a")
    time.sleep(0.8)
    before = probe()
    page = stage_of(before, a)
    t.ok(f"{name}: the page is on its stage before", page is not None, before.get("stages"))
    column = hit(60, 300)

    p = go_full(a)
    entered = full(a)(p)
    t.ok(f"{name}: the video goes full screen for real", entered, p.get("fullscreenStates"))
    if not entered:
        sv.quit()
        return
    time.sleep(0.8)
    p = probe()
    s = stand_ins(p)
    t.ok(f"{name}: one stand-in, the full-screen tab's, up", len(s) == 1 and s[0].get("tab") == a and not s[0]["hidden"], s)
    t.ok(f"{name}: the stand-in's frame is the page's own", bool(s) and s[0]["frame"] == page, (s, page))
    t.ok(f"{name}: the column answers a press in it", hit(60, 300) == column and column not in ("StageView", "PageView"), (column, hit(60, 300)))
    x, y = middle(page)
    t.ok(f"{name}: the stand-in takes a press on the page", on_stand_in(x, y), hit(x, y))
    shoot("alone-1-standin")

    sv.cmd({"do": "select", "id": b}); time.sleep(0.8)
    p = probe()
    s = stand_ins(p)
    t.ok(f"{name}: another tab picked shows its page", stage_of(p, b) == page, p.get("stages"))
    t.ok(f"{name}: the stand-in stays, hidden", len(s) == 1 and s[0]["hidden"], s)
    t.ok(f"{name}: a press on the page goes to the other tab's page", not on_stand_in(x, y) and hit(x, y) not in ("StageView", "NSVisualEffectView"), hit(x, y))
    t.ok(f"{name}: the video is still full screen", full(a)(p), p.get("fullscreenStates"))
    t.ok(f"{name}: the other tab's page answers", sv.ev(b, "document.title") == "b")
    shoot("alone-2-other-tab")

    sv.cmd({"do": "select", "id": a}); time.sleep(0.8)
    p = probe()
    s = stand_ins(p)
    t.ok(f"{name}: back on the full-screen tab, its stand-in is up again", len(s) == 1 and not s[0]["hidden"] and s[0]["frame"] == page, s)
    t.ok(f"{name}: and takes a press on the page", on_stand_in(x, y), hit(x, y))
    shoot("alone-3-back")

    click(x, y)
    p = wait(home(a))
    t.ok(f"{name}: a click on the stand-in brings the video home", home(a)(p), (p.get("fullscreenStates"), stand_ins(p)))
    time.sleep(0.8)
    p = probe()
    t.ok(f"{name}: home where it was", stage_of(p, a) == page and p.get("activePageFrame") == page, (p.get("stages"), page))
    t.ok(f"{name}: no full-screen window left", not fullscreen_windows(p), p.get("windows"))
    t.ok(f"{name}: the page is out of full screen", sv.ev(a, "document.fullscreenElement === null") is True)

    p = go_full(a)
    if full(a)(p):
        time.sleep(0.6)
        sv.cmd({"do": "select", "id": b}); time.sleep(0.6)
        sv.ev(a, "document.exitFullscreen(); 1")
        p = wait(home(a))
        t.ok(f"{name}: left while another tab is in front, nothing stays behind", home(a)(p), (p.get("fullscreenStates"), stand_ins(p)))
        time.sleep(0.6)
        p = probe()
        t.ok(f"{name}: the tab in front keeps its page", stage_of(p, b) == page, p.get("stages"))
        sv.cmd({"do": "select", "id": a}); time.sleep(0.8)
        p = probe()
        t.ok(f"{name}: back on the tab, its page is home, at its size", stage_of(p, a) == page and not stand_ins(p), (p.get("stages"), stand_ins(p)))
        t.ok(f"{name}: and still answers", sv.ev(a, "document.title") == "a")
    else:
        t.ok(f"{name}: the video goes full screen a second time", False, p.get("fullscreenStates"))

    p = go_full(a)
    if full(a)(p):
        time.sleep(0.6)
        sv.cmd({"do": "select", "id": b}); time.sleep(0.6)
        sv.sp("closeTab", id=a); time.sleep(0.4)
        p = wait(lambda p: not stand_ins(p) and not fullscreen_windows(p))
        t.ok(f"{name}: a tab closed while its video is full screen leaves no stand-in", not stand_ins(p), stand_ins(p))
        t.ok(f"{name}: nor a full-screen window", not fullscreen_windows(p), p.get("windows"))
        t.ok(f"{name}: the tab in front keeps its page", stage_of(p, b) == page, p.get("stages"))
    else:
        t.ok(f"{name}: the video goes full screen a third time", False, p.get("fullscreenStates"))
    sv.quit()


def pair(t):
    name = "Split View pair"
    sv.setup(sidebar=True, splitView=True); launch()
    a = sv.page("a")
    b = sv.page("b")
    sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
    sv.sp("focus", id=a); time.sleep(0.6)
    before = probe()
    left, right = stage_of(before, a), stage_of(before, b)
    t.ok(f"{name}: both pages on screen before", left is not None and right is not None, before.get("stages"))
    column = hit(60, 300)

    p = go_full(a)
    entered = full(a)(p)
    t.ok(f"{name}: the left pane's video goes full screen for real", entered, p.get("fullscreenStates"))
    if not entered:
        sv.quit()
        return
    time.sleep(0.8)
    p = probe()
    s = stand_ins(p)
    t.ok(f"{name}: the stand-in's frame is the left pane's page", len(s) == 1 and not s[0]["hidden"] and s[0]["frame"] == left, (s, left))
    t.ok(f"{name}: the right pane stays where it was", stage_of(p, b) == right, (p.get("stages"), right))
    rx, ry = middle(right)
    t.ok(f"{name}: a press in the right pane goes to its page", not on_stand_in(rx, ry) and hit(rx, ry) not in ("StageView", "NSVisualEffectView"), hit(rx, ry))
    t.ok(f"{name}: the column answers a press in it", hit(60, 300) == column, (column, hit(60, 300)))
    t.ok(f"{name}: the right pane's page answers", sv.ev(b, "document.title") == "b")
    shoot("pair-1-standin")

    lx, ly = middle(left)
    click(lx, ly)
    p = wait(home(a))
    t.ok(f"{name}: a click on the stand-in brings the video home", home(a)(p), (p.get("fullscreenStates"), stand_ins(p)))
    time.sleep(0.8)
    p = probe()
    t.ok(f"{name}: home in its pane, the pair as it was", stage_of(p, a) == left and stage_of(p, b) == right, (p.get("stages"), left, right))
    sv.quit()


def main():
    t = sv.T()
    try:
        alone(t)
        pair(t)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

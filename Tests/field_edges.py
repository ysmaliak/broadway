#!/usr/bin/env python3
"""The floating field's list edges, pictured window-only.

Build first (`./build.sh`), then `python3 Tests/field_edges.py [OUT]`. A test
copy in a world of its own, started hidden, its window put below the desktop
where `screencapture -l` still pictures it alone. New tabs show the floating
field; a page is open under it and thirty visits fill the field's History
place, more rows than the panel holds.

Under the input a hairline shows only while rows are hidden above it, across
the panel's whole width. The list runs to the panel's bottom edge, under the
bar, and its last row scrolls clear of the bar. Walking the list with the
arrow keys, down to the end and back up, every selected row lands whole
between the line and the bar. The panel's height and the bar's place are as
they were. Dark and light, then the space's tint, then ⌘K's menu, then legacy
scroll bars. BROADWAY_APP picks another build, for before and after; a build
without the list running under the bar fails its checks but is pictured.
"""
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import column_edges as ce  # noqa: E402

sv.use("field-edges")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/field-edges")
WIDTH, HEIGHT = 1100, 760
BAR_ROOM = 52
PANEL_HEIGHT = 462
VISITS = 30
t = sv.T()
WINDOW = [0]
HOST = [0, 0]


def press(code, chars, *mods):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})


def field(*args):
    return sv.cmd({"do": "fieldrows", "args": list(args)})


def stage(dark):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})["window"]
    time.sleep(0.8)


def shoot(name):
    path = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    if not path.exists():
        t.ok(f"{name}: pictured", False, WINDOW[0])
        return None, 1
    picture = ce.read_png(path)
    return picture, picture[0] / WIDTH


def frame(state, name):
    r = state.get("layout", {}).get(name)
    if not r:
        return None
    x, y, w, h = r
    return x + HOST[0], y + HOST[1], w, h


def legacy_launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", sv.APP,
                    "--args", "-AppleShowScrollBars", "Always"])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


def open_field():
    press(17, "t", "cmd")
    time.sleep(0.8)
    state = field("place", "history")
    time.sleep(0.8)
    return field("state")


def close_field():
    press(53, "\u001b")
    time.sleep(0.3)
    if field("state").get("showing"):
        press(53, "\u001b")
    time.sleep(0.6)


def gutter_ink(picture, scale, x, y0, y1):
    return [ce.grey(picture, int(x * scale), y) for y in range(int(y0 * scale), int(y1 * scale))]


def line_seen(picture, scale, x, y):
    """A one-pixel line at Y: the pixel row there stands off the rows just
    above and below it, which are the same ground."""
    ys = list(range(int(y * scale) - 4, int(y * scale) + 4))
    values = [ce.grey(picture, int(x * scale), yy) for yy in ys]
    ground = sorted(values)[len(values) // 2]
    return max(abs(v - ground) for v in values)


def bar_gap_ink(picture, scale, state):
    """Ink between the filter button and the Open pill, over the bar's height:
    what of a row shows through between them."""
    panel, bar = frame(state, "field.panel"), frame(state, "field.bar")
    x0, x1 = panel[0] + 70, panel[0] + panel[2] * 0.55
    values = [ce.grey(picture, int(x * scale), int(y * scale))
              for y in range(int(bar[1]), int(bar[1] + bar[3]))
              for x in range(int(x0), int(x1), 2)]
    return max(values) - min(values)


def rows_in(state):
    out = {}
    for key in state.get("layout", {}):
        if key.startswith("field.row."):
            out[int(key.rsplit(".", 1)[1])] = frame(state, key)
    return out


def walk_check(label, down=True):
    state = field("state")
    count = len(state.get("rows", []))
    steps = count + 1
    bad = []
    lit = []
    for _ in range(steps):
        before = field("state").get("picked")
        press(125 if down else 126, "" if down else "")
        time.sleep(0.45)
        state = field("state")
        if state.get("picked") == before:
            field("walk", "1" if down else "-1")
            time.sleep(0.45)
            state = field("state")
        picked = state.get("picked", -1)
        if picked < 0:
            continue
        lit.append(picked)
        row = frame(state, f"field.row.{picked}")
        top = frame(state, "field.list")
        if not top and frame(state, "field.panel"):
            panel = frame(state, "field.panel")
            top = (panel[0], panel[1] + 60, panel[2], panel[3] - 60)
        bar = frame(state, "field.bar")
        if not row or not top or not bar:
            bad.append((picked, "unmeasured"))
            continue
        if row[1] < top[1] - 0.5 or row[1] + row[3] > bar[1] + 0.5:
            bad.append((picked, round(row[1], 1), round(row[1] + row[3], 1), round(top[1], 1), round(bar[1], 1)))
    t.ok(f"{label}: every row walked to lands whole between the line and the bar ({len(lit)} steps)",
         not bad and len(set(lit)) >= min(count, VISITS), bad[:6])
    return state


def resting(label, dark):
    stage(dark)
    state = open_field()
    picture, scale = shoot(f"{label}-rest")
    panel, top, bar = frame(state, "field.panel"), frame(state, "field.list"), frame(state, "field.bar")
    edges = state.get("edges", {})
    rows = state.get("rows", [])
    t.ok(f"{label}: a long list ({len(rows)} rows)", len(rows) >= 20, len(rows))
    t.ok(f"{label}: panel {PANEL_HEIGHT} high", panel and abs(panel[3] - PANEL_HEIGHT) < 0.5, panel)
    t.ok(f"{label}: bar 11 points over the panel's bottom",
         panel and bar and abs((panel[1] + panel[3]) - (bar[1] + bar[3]) - 11) < 0.5, (panel, bar))
    t.ok(f"{label}: the list runs to the panel's bottom",
         panel and top and abs((top[1] + top[3]) - (panel[1] + panel[3])) < 0.5, (panel, top))
    t.ok(f"{label}: the list's bottom margin is the bar's room",
         abs(edges.get("field.insetBottom", -1) - BAR_ROOM) < 0.5, edges.get("field.insetBottom"))
    t.ok(f"{label}: no top line at rest", edges.get("field.top") == 0, edges)
    if picture and top:
        left = line_seen(picture, scale, top[0] + 3, top[1])
        t.ok(f"{label}: no line drawn under the input at rest", left <= 3, left)
    if picture and bar:
        ink = bar_gap_ink(picture, scale, state)
        t.ok(f"{label}: a row shows between the bar's buttons", ink > 40, ink)
    return state


def middle_and_end(label):
    state = field("state")
    for _ in range(12):
        press(125, "")
        time.sleep(0.2)
    time.sleep(0.6)
    state = field("state")
    if state.get("picked", -1) < 10:
        field("pick", "12")
        time.sleep(0.6)
        state = field("state")
    picture, scale = shoot(f"{label}-middle")
    top = frame(state, "field.list")
    edges = state.get("edges", {})
    t.ok(f"{label}: scrolled, rows hidden above (top line on)", edges.get("field.top") == 1, edges)
    if picture and top:
        left = line_seen(picture, scale, top[0] + 3, top[1])
        right = line_seen(picture, scale, top[0] + top[2] - 3, top[1])
        t.ok(f"{label}: the line is drawn across the panel, left and right gutters", left > 3 and right > 3, (left, right))
    if picture:
        ink = bar_gap_ink(picture, scale, state)
        t.ok(f"{label}: rows run behind the bar when scrolled", ink > 40, ink)
    count = len(state.get("rows", []))
    field("pick", str(count - 1))
    time.sleep(0.8)
    state = field("state")
    picture, scale = shoot(f"{label}-end")
    rows, bar = rows_in(state), frame(state, "field.bar")
    last = rows.get(count - 1)
    t.ok(f"{label}: at the end the last row sits clear of the bar",
         last and bar and last[1] + last[3] <= bar[1] + 0.5, (last, bar))
    t.ok(f"{label}: at the end the line is still on", state.get("edges", {}).get("field.top") == 1)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"sidebar": True, "newtab.floating": True})
        sv.launch()
        sv.cmd({"do": "window"})
        stage(True)
        sv.page("Field ground")
        for i in range(VISITS):
            field("visit", f"{sv.BASE}/visited-{i:02d}", str(5 + i * 7), f"Visited page {i:02d}")
        time.sleep(0.5)
        host = sv.cmd({"do": "fieldrows", "args": ["state"]}).get("host")
        if host:
            HOST[:] = host[:2]
        elif os.environ.get("FIELD_HOST"):
            HOST[:] = [float(v) for v in os.environ["FIELD_HOST"].split(",")]
        print("  host offset", HOST)
        for dark in (True, False):
            look = "dark" if dark else "light"
            resting(look, dark)
            middle_and_end(look)
            close_field()
        stage(True)
        open_field()
        field("pick", "0")
        time.sleep(0.6)
        walk_check("walk down", down=True)
        walk_check("walk up", down=False)
        close_field()
        sv.cmd({"do": "space", "action": "look", "colour": "coral"})
        time.sleep(0.8)
        for dark in (True, False):
            look = "dark" if dark else "light"
            stage(dark)
            open_field()
            for _ in range(10):
                press(125, "")
                time.sleep(0.15)
            time.sleep(0.6)
            shoot(f"tint-{look}-middle")
            close_field()
        stage(True)
        open_field()
        state = field("actions")
        time.sleep(0.8)
        state = field("state")
        shoot("menu-dark")
        t.ok("menu: the bottom margin is the bar's room",
             abs(state.get("edges", {}).get("field.insetBottom", -1) - BAR_ROOM) < 0.5, state.get("edges"))
        close_field()
        sv.quit()
        time.sleep(1)
        legacy_launch()
        stage(True)
        open_field()
        for _ in range(12):
            press(125, "\uf701")
            time.sleep(0.15)
        time.sleep(0.6)
        state = field("state")
        picture, scale = shoot("legacy-dark-middle")
        panel, top, bar = frame(state, "field.panel"), frame(state, "field.list"), frame(state, "field.bar")
        if picture and panel and bar:
            top_y = top[1] if top else panel[1] + 60
            right = panel[0] + panel[2]
            gutter = [ce.grey(picture, int(x * scale), int(y * scale))
                      for y in range(int(top_y + 10), int(bar[1] - 10))
                      for x in range(int(right - 5), int(right - 2))]
            t.ok("legacy scroll bars: no scroller in the panel's right gutter (the list hides its indicators)",
                 max(gutter) - min(gutter) <= 12, max(gutter) - min(gutter))
        close_field()
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

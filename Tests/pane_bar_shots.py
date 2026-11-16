#!/usr/bin/env python3
"""Split View's pane bars over black, white and colourful pages, pictured.

Build first (`./build.sh debug`), then `python3 Tests/pane_bar_shots.py [label]`.
Two pairs in one window of a test copy: a black page beside a white one, and a
colourful page beside a black one. Every page has a fixed header at its top.
Shot in dark and light on four space grounds (near-black, pale, vivid, and a
see-through black), with each pane focused. Crops of the bars land in
.context/pane-bars/<label>/ with a sheet per theme, and measure.json holds, per
pane, the bar's tone, each change of colour down the seam and the page's colour
8 points under the bar. Each shot checks that the bar is one flat colour from
top to foot, that one device pixel of line stands off it, and that the page
keeps its own colour from the very next pixel down: one hairline, no shade.
Every card wears one point of edge, a quiet step off the sidebar's own colour:
the unfocused card's top, sides, foot-of-bar side pixel and bottom are checked
to be one colour across the whole point with the fill right inside, that colour
to stand a little off the sidebar beside the card, the focused card's outline
to stand further off that sidebar, and a page alone (a white one and a black one) to
have the edge on all four sides with the page right inside.
corners-<theme>.png holds every card's four corners at three times their size.

GROUNDS=near,glass picks grounds (glass and palethrough are extra). SHARE=0.37
gives the left page that share of each pair, for an uneven split. DESK=1
shoots the window over the desktop, which a see-through bar needs to be judged:
a window shot alone has nothing behind the blur.
"""
import json
import math
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
label = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
import split_view as sv
import raised_look_shots as rl

sv.use("pane-bars-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "pane-bars" / label
TMP = OUT / "work"
rl.SHOT = TMP / "shot"
rl.PIXEL = TMP / "pixel"
WIDTH = 258
BAR = 32
CLEAR = 8
GROUNDS = {
    "near": {"custom": "000000", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "pale": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "vivid": {"custom": "3139FB", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0},
    "through": {"custom": "000000", "intensity": 2.0, "glass": False, "transparency": 0.41, "grain": 0.3},
    "glass": {"custom": "8A93A6", "intensity": 0.6, "glass": True, "transparency": 0.7, "grain": 0},
    "palethrough": {"custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0.41, "grain": 0},
}
PICKED = os.environ.get("GROUNDS", "near,pale,vivid,through").split(",")
GROUNDS = {k: GROUNDS[k] for k in PICKED if k in GROUNDS}
DESK = os.environ.get("DESK") == "1"
SHARE = os.environ.get("SHARE")
FLAT = 2
PAGES = {
    "black": ("#000", "#000", "#e7e9ea", "#2f3336"),
    "white": ("#fff", "#fff", "#0f1419", "#e6e6e6"),
    "colour": ("linear-gradient(135deg,#ff3d7f,#ffb400 55%,#00c2a8)", "#e6007a", "#fff", "#b0005d"),
}
HEADERS = {"black": [0, 0, 0], "white": [255, 255, 255], "colour": [230, 0, 122]}


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("/")[0]
        ground, head, ink, rule = PAGES.get(name, PAGES["white"])
        body = (f"<!doctype html><meta charset=utf-8><title>{name} page</title>"
                f"<style>html,body{{margin:0;min-height:300vh;background:{ground};color:{ink};"
                f"font:17px -apple-system}}header{{position:fixed;top:0;left:0;right:0;height:53px;"
                f"background:{head};border-bottom:1px solid {rule};display:flex;align-items:center;"
                f"padding:0 16px;font-weight:800;font-size:20px}}p{{margin:80px 16px}}</style>"
                f"<header>{name.capitalize()} header</header><p>{name} page").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
ALSO = f"http://localhost:{server.server_port}"


def still(name):
    raw = TMP / f"{name}-raw.png"
    out = OUT / "windows" / f"{name}.png"
    for attempt in range(4):
        try:
            rl.shoot(pid, number, raw)
            break
        except RuntimeError:
            if attempt == 3:
                raise
            sv.cmd({"do": "idle", "action": "unhide"})
            time.sleep(0.8)
    subprocess.run(["sips", "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc", str(raw), "--out", str(out)],
                   capture_output=True, check=True)
    return out


def crop(src, box, path, zoom=1):
    k = max(1, round(rl.scale_of(src)))
    x, y, w, h = box
    grown = f",scale=iw*{zoom}:ih*{zoom}:flags=neighbor" if zoom != 1 else ""
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(src), "-vf",
                    f"crop={int(w * k)}:{int(h * k)}:{int(max(0, x) * k)}:{int(max(0, y) * k)}{grown}", str(path)], check=True)


def off(a, b):
    return max(abs(p - q) for p, q in zip(a, b))


def row(names, path):
    inputs = sum([["-i", str(n)] for n in names], [])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                    f"hstack=inputs={len(names)}", str(path)], check=True)


def sheet(names, path):
    inputs = sum([["-i", str(OUT / f"{n}.png")] for n in names], [])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                    f"vstack=inputs={len(names)}", str(path)], check=True)


def main():
    global pid, number
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    (OUT / "windows").mkdir(parents=True, exist_ok=True)
    (OUT / "corners").mkdir(parents=True, exist_ok=True)
    TMP.mkdir(parents=True, exist_ok=True)
    copy = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / ("DeskShot.swift" if DESK else "WindowShot.swift"), copy)
    subprocess.run(["swiftc", "-parse-as-library", str(copy), "-o", str(rl.SHOT)], check=True, cwd=TMP)
    (TMP / "pixel.swift").write_text(rl.PIXEL_SOURCE)
    subprocess.run(["swiftc", "-O", str(TMP / "pixel.swift"), "-o", str(rl.PIXEL)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True, "split": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(WIDTH)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    report = {}
    try:
        sv.cmd({"do": "resize", "width": 1100, "height": 560, "steps": 1})
        opened = {}
        for key, url in [("black", f"{BASE}/black"), ("white", f"{ALSO}/white"),
                         ("colour", f"{BASE}/colour"), ("black2", f"{ALSO}/black")]:
            opened[key] = sv.sp("open", url=url)["resultID"]
            time.sleep(0.4)
        time.sleep(2)
        made = {i[:8].lower() for i in opened.values()}
        blank = None
        for tab in sv.cmd({"do": "tabs"})["tabs"]:
            if tab["id"][:8].lower() not in made and not tab["url"].startswith("http"):
                if blank is None:
                    blank = tab["id"]
                    continue
                try:
                    sv.sp("close", id=tab["id"])
                except RuntimeError as e:
                    print("  could not close the blank tab:", e)
        for kind, url in [("white", f"{BASE}/white"), ("black", f"{ALSO}/black")]:
            opened["lone-" + kind] = sv.sp("open", url=url)["resultID"]
            time.sleep(0.4)
        time.sleep(1.5)
        sv.sp("pair", id=opened["white"], **{"with": opened["black"]}, side="right")
        time.sleep(1.0)
        sv.sp("pair", id=opened["black2"], **{"with": opened["colour"]}, side="right")
        time.sleep(1.0)
        if SHARE:
            for split in sv.sp("state")["splits"]:
                sv.sp("fraction", split=split["id"], fraction=float(SHARE))
            time.sleep(1.0)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        scale = None

        def focus(id):
            sv.sp("select", id=id)
            time.sleep(0.3)
            sv.sp("focus", id=id)
            time.sleep(0.9)

        strong = {}
        states = [("black-white", "black", "white", "left"), ("black-white", "white", "black", "right"),
                  ("colour-black", "colour", "black2", "left")]
        for theme in ["dark", "light"]:
            for ground, look in GROUNDS.items():
                sv.cmd({"do": "ui", "look": theme})
                sv.cmd({"do": "space", "action": "look", **look})
                sv.cmd({"do": "ui", "windowPointer": [1090, 550], "pointerPhase": "move"})
                time.sleep(0.8)
                for pair, front, other, side in states:
                    focus(opened[front])
                    tag = f"{theme}-{ground}-{pair}-{side}"
                    st = sv.sp("state")
                    t.ok(f"{tag}: the keys go to the page meant", st["activeID"] == opened[front], st["activeID"])
                    frames = {f["id"]: f for f in st["paneFrames"]}
                    panes = [frames.get(opened[k][:8].lower()) for k in (front, other)]
                    t.ok(f"{tag}: both pages are on the stage", all(panes), list(frames))
                    if not all(panes):
                        continue
                    shot = still(tag)
                    scale = scale or rl.scale_of(shot, 1100)
                    left = min(p["x"] for p in panes)
                    top = min(p["y"] for p in panes) - BAR
                    crop(shot, [left - 8, top - 8, 1100 - left + 8, BAR + 70], OUT / f"{tag}.png")
                    report[tag] = {}
                    corners = []
                    for key, pane in sorted(zip((front, other), panes), key=lambda kp: kp[1]["x"]):
                        for end, cx in (("l", pane["x"] - 6), ("r", pane["x"] + pane["width"] - 26)):
                            corners.append(OUT / "corners" / f"{tag}-{key}-{end}.png")
                            crop(shot, [cx, top - 6, 32, BAR + 16], corners[-1], zoom=3)
                            corners.append(OUT / "corners" / f"{tag}-{key}-{end}-foot.png")
                            crop(shot, [cx, pane["y"] + pane["height"] - 42, 32, BAR + 16], corners[-1], zoom=3)
                    row(corners, OUT / "corners" / f"{tag}.png")
                    for path in corners:
                        path.unlink()
                    for key, pane in zip((front, other), panes):
                        x = pane["x"] + 120
                        seam = rl.trace(shot, x, pane["y"] - BAR - 2, pane["y"] + CLEAR)
                        k = rl.scale_of(shot, 1100)
                        first = rl.pixels(shot, [(round(x * k), round((pane["y"] + CLEAR) * k))])[0]
                        kind = key.rstrip("2")
                        t.ok(f"{tag}: the {kind} page's fixed header shows right under the bar",
                             all(abs(a - b) <= 6 for a, b in zip(first, HEADERS[kind])), first)
                        foot = round(pane["y"] * k)
                        high = round((pane["y"] - BAR + 4) * k)
                        rows = rl.pixels(shot, [(round(x * k), y) for y in [high] + list(range(foot - 2, foot + round(CLEAR * k)))])
                        fill, above, line, page = rows[0], rows[2], rows[3], rows[4:]
                        t.ok(f"{tag}: the {kind} page's bar is one flat colour",
                             all(abs(a - b) <= FLAT for a, b in zip(fill, above)), [fill, above])
                        t.ok(f"{tag}: the {kind} page's bar ends in a line that stands off it",
                             max(abs(a - b) for a, b in zip(line, above)) >= 8, [above, line])
                        t.ok(f"{tag}: one hairline and then the {kind} page, unshaded",
                             all(abs(a - b) <= 6 for row in page for a, b in zip(row, HEADERS[kind])), page[:4])
                        headerTop = sv.cmd({"do": "eval", "id": opened[key],
                                            "js": "document.querySelector('header').getBoundingClientRect().top"}).get("value")
                        t.ok(f"{tag}: the {kind} page's header is at its viewport's top", headerTop in (0, "0"), headerTop)
                        head = round((pane["y"] - BAR) * k)
                        mid = round((pane["y"] - BAR / 2) * k)
                        west = math.floor(pane["x"] * k + 0.02)
                        east = math.ceil((pane["x"] + pane["width"]) * k - 0.02) - 1
                        low = round((pane["y"] + pane["height"]) * k) - 1
                        deep = round((pane["y"] + pane["height"] / 2) * k)
                        thick = max(1, round(k))
                        beside = west - 3 if pane["x"] < left + 1 else east + 3
                        rim = rl.pixels(shot, [(round(x * k), head), (round(x * k), head + thick), (west, mid), (west + thick, mid),
                                               (east, mid), (east - thick, mid), (west, foot), (east, foot),
                                               (west, deep), (east, deep), (round(x * k), low),
                                               (round(x * k), head + thick - 1), (west + thick - 1, mid), (east - thick + 1, mid),
                                               (west + thick - 1, deep), (east - thick + 1, deep), (round(x * k), low - thick + 1),
                                               (beside, mid)])
                        report[tag][key] = {"focused": key == front, "seam": seam, "pageTop": first, "fill": fill, "line": line,
                                            "rim": rim}
                    lit, quiet = report[tag].get(front), report[tag].get(other)
                    if lit and quiet:
                        rim, fill = quiet["rim"], quiet["fill"]
                        edge = rim[0]
                        strong[(theme, ground)] = edge
                        t.ok(f"{tag}: the unfocused card has one colour of edge along its top, a point deep",
                             off(rim[11], edge) <= 3 and off(rim[1], fill) <= FLAT, [rim[0], rim[11], rim[1], fill])
                        t.ok(f"{tag}: the unfocused card has the edge's colour down both sides of its bar",
                             off(rim[2], edge) <= 3 and off(rim[12], edge) <= 3 and off(rim[3], fill) <= FLAT
                             and off(rim[4], edge) <= 3 and off(rim[13], edge) <= 3 and off(rim[5], fill) <= FLAT,
                             [rim[2:6], rim[12:14], edge, fill])
                        t.ok(f"{tag}: the bar's line leaves no notch in the unfocused card's edge",
                             off(rim[6], edge) <= 3 and off(rim[7], edge) <= 3, [rim[6:8], edge])
                        t.ok(f"{tag}: the unfocused card's edge runs down the page's sides and along its bottom",
                             all(off(spot, edge) <= 3 for spot in rim[8:11] + rim[14:17]), [rim[8:11], rim[14:17], edge])
                        solid = ground not in ("through", "glass", "palethrough")
                        step, cue = off(edge, rim[17]), off(lit["rim"][0], lit["rim"][17])
                        if solid:
                            t.ok(f"{tag}: the edge is a quiet step off the sidebar beside the card",
                                 3 <= step <= 24, [edge, rim[17]])
                        t.ok(f"{tag}: the focused card's outline stands further off the sidebar than the other's edge",
                             cue > step and (not solid or cue >= 2 * step) and off(lit["rim"][11], lit["rim"][0]) <= 3,
                             [lit["rim"][0], lit["rim"][11], lit["rim"][17], edge, rim[17]])
                for kind in ("white", "black"):
                    id = opened["lone-" + kind]
                    focus(id)
                    tag = f"{theme}-{ground}-lone-{kind}"
                    pane = next((f for f in sv.sp("state")["paneFrames"] if f["id"] == id[:8].lower()), None)
                    edge = strong.get((theme, ground))
                    t.ok(f"{tag}: the page alone is on the stage", bool(pane and edge), pane)
                    if not (pane and edge):
                        continue
                    shot = still(tag)
                    k = rl.scale_of(shot, 1100)
                    l, r = math.floor(pane["x"] * k + 0.02), math.ceil((pane["x"] + pane["width"]) * k - 0.02) - 1
                    u, d = math.floor(pane["y"] * k + 0.02), math.ceil((pane["y"] + pane["height"]) * k - 0.02) - 1
                    cx, cy = round((pane["x"] + 120) * k), round((pane["y"] + 30) * k)
                    thick = max(1, round(k))
                    spots = [(cx, u), (cx, d), (l, cy), (r, cy), (cx, u + thick), (cx, d - thick), (l + thick, cy), (r - thick, cy),
                             (cx, u + thick - 1), (cx, d - thick + 1), (l + thick - 1, cy), (r - thick + 1, cy)]
                    rim = rl.pixels(shot, spots)
                    t.ok(f"{tag}: the page alone has the edge's colour on all four sides, a point deep",
                         all(off(spot, edge) <= 3 for spot in rim[:4] + rim[8:]), [rim[:4], rim[8:], edge])
                    t.ok(f"{tag}: the page starts on the very next pixel in",
                         all(off(spot, HEADERS[kind]) <= 6 for spot in rim[4:8]), rim[4:8])
                    corners = []
                    for name, bx, by in (("tl", pane["x"] - 6, pane["y"] - 6), ("tr", pane["x"] + pane["width"] - 26, pane["y"] - 6),
                                         ("bl", pane["x"] - 6, pane["y"] + pane["height"] - 26),
                                         ("br", pane["x"] + pane["width"] - 26, pane["y"] + pane["height"] - 26)):
                        corners.append(OUT / "corners" / f"{tag}-{name}.png")
                        crop(shot, [bx, by, 32, 32], corners[-1], zoom=3)
                    row(corners, OUT / "corners" / f"{tag}.png")
                    for path in corners:
                        path.unlink()
                    report[tag] = {"edge": edge, "rim": rim}
                    print(f"  {tag}")
                    if kind == "black" and blank:
                        sv.sp("select", id=blank)
                        time.sleep(0.9)
                        tag = f"{theme}-{ground}-lone-blank"
                        shot = still(tag)
                        rim = rl.pixels(shot, spots)
                        t.ok(f"{tag}: a new tab's card has the edge's colour on all four sides, a point deep",
                             all(off(spot, edge) <= 3 for spot in rim[:4] + rim[8:]), [rim[:4], rim[8:], edge])
                        t.ok(f"{tag}: the new tab's card starts on the very next pixel in",
                             all(off(spot, rim[4]) <= FLAT for spot in rim[5:8]), rim[4:8])
                        crop(shot, [pane["x"] - 6, pane["y"] - 6, 64, 32], OUT / "corners" / f"{tag}.png", zoom=3)
                        report[tag] = {"edge": edge, "rim": rim}
                        print(f"  {tag}")
                    print(f"  {tag}")
        (OUT / "measure.json").write_text(json.dumps({"scale": scale, "shots": report}, indent=1))
        for theme in ["dark", "light"]:
            names = [f"{theme}-{g}-{p}-{s}" for g in GROUNDS for p, _, _, s in states]
            sheet(names, OUT / f"sheet-{theme}.png")
            subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *sum([["-i", str(OUT / "corners" / f"{n}.png")] for n in names], []),
                            "-filter_complex", f"vstack=inputs={len(names)}", str(OUT / f"corners-{theme}.png")], check=True)
            alone = [f"{theme}-{g}-lone-{kind}" for g in GROUNDS for kind in ("white", "black")]
            alone = [n for n in alone if (OUT / "corners" / f"{n}.png").exists()]
            if alone:
                subprocess.run(["ffmpeg", "-y", "-loglevel", "error",
                                *sum([["-i", str(OUT / "corners" / f"{n}.png")] for n in alone], []),
                                "-filter_complex", f"vstack=inputs={len(alone)}", str(OUT / f"alone-{theme}.png")], check=True)
        print(OUT, "scale", scale)
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

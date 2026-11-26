#!/usr/bin/env python3
import json
import shutil
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("side-chrome")
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/side-chrome")
SIZE = (1100, 700)
COLUMN = 258
WINDOW = [0]
PID = [0]
TOOL = ROOT / ".build" / "side-chrome-shot"
t = sv.T()
FACTS = {}

NOIR = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45, "glass": False}
FLAT = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.0, "grain": 0.0, "glass": False}
NAVY = {"custom": "000354", "intensity": 0.9, "transparency": 0.0, "grain": 0.0, "glass": False}
PALE = {"custom": "FFF1C9", "intensity": 0.8, "transparency": 0.0, "grain": 0.0, "glass": False}
BLUE = {"custom": "3139FB", "intensity": 0.8, "transparency": 0.0, "grain": 0.0, "glass": False}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = dx * dx + dy * dy <= (side / 2 - 1) ** 2
            rows += bytes([int(colour[0] * 255), int(colour[1] * 255), int(colour[2] * 255), 255 if inside else 0])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


ICON = png((0.08, 0.62, 0.66))


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/icon"):
            body, kind = ICON, "image/png"
        else:
            title = bytes.fromhex(self.path.strip("/").split("/")[-1]).decode()
            body = (f"<!doctype html><meta charset=utf-8><title>{title}</title>"
                    f"<link rel=icon href='/icon.png'><p>{title}").encode()
            kind = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


def opened(base, title):
    tab = sv.sp("open", url=f"{base}/p/{title.encode().hex()}")["resultID"]
    time.sleep(1.5)
    return tab[:8].lower()


def stage(dark):
    said = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": list(SIZE)})
    WINDOW[0], PID[0] = said["window"], said["pid"]
    time.sleep(1.0)


def look(settings):
    sv.cmd({"do": "space", "action": "look", **settings})
    time.sleep(0.8)


def point(index):
    for on in (True, False):
        sv.cmd({"do": "space", "action": "point", "index": index, "on": on})
        time.sleep(0.4)


def shoot(name):
    path = OUT / f"{name}.png"
    said = ""
    for turn in range(6):
        said = subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True, text=True).stderr
        if path.exists():
            return path
        if not TOOL.exists():
            TOOL.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(TOOL)], check=True)
        said += subprocess.run([str(TOOL), str(PID[0]), str(WINDOW[0]), str(path)], capture_output=True, text=True).stdout
        if path.exists():
            return path
        time.sleep(1.0)
    raise RuntimeError(f"no picture of window {WINDOW[0]}: {said.strip()}")


def scale_of(path):
    with open(path, "rb") as file:
        head = file.read(24)
    return struct.unpack(">I", head[16:20])[0] / SIZE[0]


class Patch:
    def __init__(self, path, box):
        self.k = scale_of(path)
        self.x = round(box[0] * self.k)
        self.y = round(box[1] * self.k)
        self.w = max(1, round(box[2] * self.k))
        self.h = max(1, round(box[3] * self.k))
        raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-vf", f"crop={self.w}:{self.h}:{self.x}:{self.y}",
                              "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
        self.lum = [(raw[i] * 299 + raw[i + 1] * 587 + raw[i + 2] * 114) // 1000 for i in range(0, self.w * self.h * 3, 3)]
        self.ground = sorted(self.lum)[len(self.lum) // 2]
        self.contrast = max(abs(v - self.ground) for v in self.lum)

    def ink(self, x, y, level):
        return abs(self.lum[y * self.w + x] - self.ground) > level

    def runs(self, level=40, gap=0.0, rows=None):
        rows = rows or range(self.h)
        marked = [any(self.ink(x, y, level) for y in rows) for x in range(self.w)]
        found, start = [], None
        for x, on in enumerate(marked + [False]):
            if on and start is None:
                start = x
            elif not on and start is not None:
                found.append([start, x])
                start = None
        merged = []
        for run in found:
            if merged and run[0] - merged[-1][1] < gap * self.k:
                merged[-1][1] = run[1]
            else:
                merged.append(run)
        return merged

    def box(self, run, level=40):
        ys = [y for y in range(self.h) if any(self.ink(x, y, level) for x in range(run[0], run[1]))]
        if not ys:
            return None
        return [(self.x + run[0]) / self.k, (self.y + ys[0]) / self.k, (run[1] - run[0]) / self.k, (ys[-1] + 1 - ys[0]) / self.k]


def mid(box):
    return [box[0] + box[2] / 2, box[1] + box[3] / 2]


def line(path, band, level=40):
    patch = Patch(path, band)
    groups = patch.runs(level, gap=3.0)
    if len(groups) < 2:
        return None
    icon = patch.box(groups[0], level)
    letters = [run for run in patch.runs(level) if run[0] >= groups[1][0]]
    cap = patch.box(letters[0], level)
    return {"icon": icon, "cap": cap, "words": patch.box(groups[1], level)}


def cut(path, name, box, zoom=1):
    k = scale_of(path)
    x, y, w, h = [round(v * k) for v in box]
    out = OUT / f"{name}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(path), "-vf",
                    f"crop={w}:{h}:{x}:{y},scale=iw*{zoom}:ih*{zoom}:flags=neighbor", str(out)], check=True)
    return out


def rows_now():
    said = sv.cmd({"do": "rowframes"})
    tabs = {tab["id"][:8].lower(): tab for tab in sv.sp("state")["tabs"]}
    return said["rows"], tabs


def near(a, b, within=0.5):
    return abs(a - b) <= within


def measure(scene, path, plain, bring, checks):
    facts = {}
    rows, _ = rows_now()
    title = line(path, [4, 45, COLUMN - 8, 30])
    facts["title"] = title
    for name, id in (("plain", plain), ("bring", bring)):
        row = rows.get(id)
        facts[name + "Row"] = row
        facts[name] = line(path, [row[0] + 5, row[1] + 4, row[2] - 45, row[3] - 8]) if row else None
    foot = Patch(path, [8, SIZE[1] - 37, COLUMN - 16, 32])
    groups = foot.runs(30, gap=8.0)
    facts["foot"] = [foot.box(run, 30) for run in groups]
    edges = sv.cmd({"do": "columnscroll"})
    marks = edges.get("marks", {})
    facts["marks"] = marks
    facts["markContrast"] = {}
    for name, rect in marks.items():
        spot = Patch(path, [rect[0] - 4, rect[1], rect[2] + 8, rect[3]])
        facts["markContrast"][name] = spot.contrast
    card = sv.cmd({"do": "updates"})["sidebar"]
    if card["shown"]:
        frame = card["card"]["card"]
        top = SIZE[1] - (frame[1] + frame[3])
        facts["cardFrame"] = [frame[0], top, frame[2], frame[3]]
        patch = Patch(path, [frame[0] + 4, top + 8, frame[2] - 8, frame[3] - 16])
        facts["card"] = [patch.box(run) for run in patch.runs(40, gap=5.0)]
    FACTS[scene] = facts
    cut(path, f"{scene}-title", [0, 40, COLUMN, 44])
    if facts.get("bringRow"):
        row = facts["bringRow"]
        low = min(row[1], facts["plainRow"][1]) if facts.get("plainRow") else row[1]
        high = max(row[1], facts["plainRow"][1]) if facts.get("plainRow") else row[1]
        cut(path, f"{scene}-rows", [0, low - 4, COLUMN, high - low + row[3] + 8])
    cut(path, f"{scene}-foot", [0, SIZE[1] - 110, COLUMN + 26, 110])
    if not checks:
        return facts
    ref = facts.get("plain")
    t.ok(f"{scene}: the plain row, the Bring row and the space title are all found",
         bool(ref and facts.get("bring") and title), {k: bool(facts.get(k)) for k in ("plain", "bring", "title")})
    if not (ref and facts.get("bring") and title):
        return facts
    grid = mid(ref["icon"])[0]
    words = ref["words"][0]
    for name in ("title", "bring"):
        got = facts[name]
        t.ok(f"{scene}: the {name} icon's centre is on the row icon's centre x",
             near(mid(got["icon"])[0], grid), (mid(got["icon"])[0], grid))
        t.ok(f"{scene}: the {name} words start at the row title's x", near(got["words"][0], words, 0.75), (got["words"][0], words))
    for name in ("title", "bring", "plain"):
        got = facts[name]
        t.ok(f"{scene}: the {name} icon is centred on its words' cap height",
             near(mid(got["icon"])[1], mid(got["cap"])[1]), (mid(got["icon"])[1], mid(got["cap"])[1]))
    marks_found = [box for box in facts["foot"] if box]
    t.ok(f"{scene}: the foot shows downloads, the space and plus", len(marks_found) == 3, facts["foot"])
    if len(marks_found) == 3:
        left, space, right = marks_found
        t.ok(f"{scene}: the downloads icon's centre is on the row icon's centre x", near(mid(left)[0], grid), (mid(left)[0], grid))
        t.ok(f"{scene}: plus mirrors it from the other edge", near(COLUMN - mid(right)[0], grid), (COLUMN - mid(right)[0], grid))
        ys = [mid(box)[1] for box in marks_found]
        t.ok(f"{scene}: the three share one centre line", max(ys) - min(ys) <= 0.75, ys)
        heights = [box[3] for box in marks_found]
        t.ok(f"{scene}: the three read as one size", max(heights) - min(heights) <= 3.5, heights)
    for name, contrast in facts["markContrast"].items():
        t.ok(f"{scene}: the foot icon of {name} stands out from the ground", contrast >= 70, contrast)
    if "card" in facts:
        parts = [box for box in facts["card"] if box]
        frame = facts["cardFrame"]
        t.ok(f"{scene}: the card holds words and a button, no icon", len(parts) == 2, parts)
        if len(parts) >= 2:
            lead = parts[0][0] - frame[0]
            tail = frame[0] + frame[2] - (parts[-1][0] + parts[-1][2])
            t.ok(f"{scene}: the title starts as far in as Restart ends", near(lead, tail, 1.25), (lead, tail))
    return facts


def sheet(kind, scenes):
    inputs = [OUT / f"{scene}-{kind}.png" for scene in scenes if (OUT / f"{scene}-{kind}.png").exists()]
    if len(inputs) < 2:
        return
    args = sum([["-i", str(path)] for path in inputs], [])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *args, "-filter_complex", f"vstack=inputs={len(inputs)}",
                    str(OUT / f"sheet-{kind}.png")], check=True)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    sv.setup(spaces=True)
    sv.launch()
    scenes = []
    try:
        stage(False)
        sv.cmd({"do": "ui", "spaces": True, "cards": True, "sideWidth": COLUMN})
        sv.cmd({"do": "space", "action": "rename", "name": "Personal", "icon": "house"})
        plain = opened(base, "Example page")
        sv.cmd({"do": "ui", "lead": "import"})
        time.sleep(1.0)
        rows, tabs = rows_now()
        bring = next(id for id, tab in tabs.items() if "import" in str(tab.get("internal") or ""))
        for id in [id for id in rows if id not in (plain, bring)]:
            try:
                sv.sp("close", id=id)
            except RuntimeError:
                pass
        sv.cmd({"do": "updates", "stage": "0.2", "build": "900"})
        time.sleep(1.5)

        def scene(name, dark=None, checks=True):
            if dark is not None:
                stage(dark)
            point(1)
            path = shoot(name)
            measure(name, path, plain, bring, checks)
            scenes.append(name)

        scene("gray-light", False)
        scene("gray-dark", True)
        stage(False)
        look(NOIR)
        scene("noir-light", checks=False)
        scene("noir-dark", True, checks=False)
        look(FLAT)
        scene("flat-dark")
        scene("flat-light", False)
        look(PALE)
        scene("pale-light")
        scene("pale-dark", True, checks=False)
        look(NAVY)
        scene("navy-dark", checks=False)
        scene("navy-light", False, checks=False)
        look(BLUE)
        scene("blue-light", checks=False)
        look(NOIR)
        for name in ("noir-light", "noir-dark", "pale-dark", "navy-dark", "navy-light", "blue-light"):
            for who, contrast in FACTS[name]["markContrast"].items():
                t.ok(f"{name}: the foot icon of {who} stands out from the ground", contrast >= 70, contrast)

        stage(False)
        before, _ = rows_now()
        for kind in ("history", "downloads", "bookmarks", "files"):
            sv.cmd({"do": "ui", "show": f"broadway://{kind}"})
            time.sleep(0.6)
        time.sleep(1.0)
        rows, tabs = rows_now()
        path = shoot("pages-light")
        grid = mid(FACTS["flat-light"]["plain"]["icon"])[0]
        added = sorted((id for id in rows if id not in before), key=lambda id: rows[id][1])
        t.ok("pages: four more internal pages have rows", len(added) == 4, added)
        for id in added:
            row = rows[id]
            got = line(path, [row[0] + 5, row[1] + 4, row[2] - 45, row[3] - 8])
            name = tabs.get(id, {}).get("title") or id
            t.ok(f"pages: the {name} row's icon and words are found", bool(got), row)
            if not got:
                continue
            FACTS.setdefault("pages", {})[name] = got
            t.ok(f"pages: the {name} icon's centre is on the row icon's centre x", near(mid(got["icon"])[0], grid), (mid(got["icon"])[0], grid))
            t.ok(f"pages: the {name} icon is centred on its words' cap height",
                 near(mid(got["icon"])[1], mid(got["cap"])[1], 0.75), (mid(got["icon"])[1], mid(got["cap"])[1]))
            longest = max(got["icon"][2], got["icon"][3])
            t.ok(f"pages: the {name} icon is the size of the others", 12 <= longest <= 14.5, got["icon"])
        if added:
            top = min(rows[id][1] for id in rows)
            low = max(rows[id][1] + rows[id][3] for id in rows)
            cut(path, "pages-light-rows", [0, top - 4, COLUMN, low - top + 8])
        if added:
            sv.cmd({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]})
            time.sleep(1.0)
            said = sv.cmd({"do": "switcher"})
            t.ok("pages: the tab switcher is up with the internal pages", said["visible"] and len(said["cards"]) >= 5, said)
            path = shoot("pages-switcher-light")
            if said["panel"][2] > 0:
                cut(path, "pages-switcher-light-panel", [v + d for v, d in zip(said["panel"], (-8, -8, 16, 16))])
            sv.cmd({"do": "press", "code": 53, "chars": "\u001b", "mods": ["ctrl"]})
            time.sleep(0.8)
            if sv.cmd({"do": "switcher"})["visible"]:
                sv.sp("mouse", points=[[SIZE[0] - 20, SIZE[1] - 20], [SIZE[0] - 20, SIZE[1] - 20]])
                time.sleep(0.8)
        for id in added:
            try:
                sv.sp("close", id=id)
            except RuntimeError:
                pass
        time.sleep(0.8)
        look(NOIR)
        for system_dark in (False, True):
            sv.cmd({"do": "ui", "glassDark": system_dark})
            time.sleep(0.8)
            said = sv.cmd({"do": "probe"}).get("appearance", "")
            for dark in (True, False):
                shot = f"system-{'dark' if system_dark else 'light'}-noir-{'dark' if dark else 'light'}"
                t.ok(f"{shot}: the app's own look is {'dark' if system_dark else 'light'}", ("Dark" in said) == system_dark, said)
                stage(dark)
                point(1)
                path = shoot(shot)
                cut(path, f"{shot}-foot", [0, SIZE[1] - 110, COLUMN + 26, 110])
                rect = sv.cmd({"do": "columnscroll"}).get("marks", {}).get("Personal")
                contrast = Patch(path, [rect[0] - 4, rect[1], rect[2] + 8, rect[3]]).contrast if rect else 0
                FACTS[shot] = {"markContrast": {"Personal": contrast}}
                t.ok(f"{shot}: the pointed foot icon stands out from the ground", contrast >= 70, contrast)
                scenes.append(shot)
        stage(False)
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        time.sleep(1.5)
        sv.cmd({"do": "space", "action": "rename", "name": "Work", "icon": "briefcase"})
        look(PALE)
        sv.cmd({"do": "space", "action": "new", "name": "Reading"})
        time.sleep(1.5)
        sv.cmd({"do": "space", "action": "rename", "name": "Reading", "icon": "📚"})
        look(BLUE)
        for dark in (False, True):
            stage(dark)
            for index, name in ((1, "Personal"), (2, "Work"), (3, "Reading"), (1, "Personal")):
                sv.cmd({"do": "space", "action": "goto", "index": index})
                time.sleep(2.0)
                point(index)
                shot = f"paged-{name.lower()}-{'dark' if dark else 'light'}"
                path = shoot(shot)
                cut(path, f"{shot}-foot", [0, SIZE[1] - 110, COLUMN + 26, 110])
                cut(path, f"{shot}-title", [0, 40, COLUMN, 44])
                marks = sv.cmd({"do": "columnscroll"}).get("marks", {})
                for who in ("Personal", "Work"):
                    rect = marks.get(who)
                    contrast = Patch(path, [rect[0] - 4, rect[1], rect[2] + 8, rect[3]]).contrast if rect else 0
                    least = 70 if who == name else 40
                    t.ok(f"{shot}: the foot icon of {who} stands out from the ground", contrast >= least, contrast)
                if shot not in scenes:
                    scenes.append(shot)
        stage(False)
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1.2)
        sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
        time.sleep(1.5)
        for dark in (False, True):
            stage(dark)
            path = shoot(f"stacked-{'dark' if dark else 'light'}")
            cut(path, f"stacked-{'dark' if dark else 'light'}-column", [0, 0, COLUMN + 26, SIZE[1]])
            head = line(path, [4, 93, COLUMN - 8, 30])
            grid = FACTS["flat-light"]["plain"]
            name = "stacked-dark" if dark else "stacked-light"
            FACTS[name] = {"title": head}
            t.ok(f"{name}: the first heading is found", bool(head), head)
            if head:
                t.ok(f"{name}: the heading icon's centre is on the row icon's centre x",
                     near(mid(head["icon"])[0], mid(grid["icon"])[0]), (mid(head["icon"])[0], mid(grid["icon"])[0]))
                t.ok(f"{name}: the heading words start at the row title's x", near(head["words"][0], grid["words"][0], 0.75),
                     (head["words"][0], grid["words"][0]))
                t.ok(f"{name}: the heading icon is centred on its words' cap height",
                     near(mid(head["icon"])[1], mid(head["cap"])[1], 0.75), (mid(head["icon"])[1], mid(head["cap"])[1]))
        sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "side"})
        stage(False)
    finally:
        sv.finish()
        server.shutdown()
    for kind in ("title", "rows", "foot"):
        sheet(kind, scenes)
    (OUT / "facts.json").write_text(json.dumps(FACTS, indent=1))
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

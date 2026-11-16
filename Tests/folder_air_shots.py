#!/usr/bin/env python3
import argparse
import json
import struct
import zlib
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="now")
parser.add_argument("--width", type=float, default=258)
parser.add_argument("--scene", choices=["world", "picture"], default="world")
options = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

OUT = ROOT / ".context" / "after" / options.label
WIDTH, HEIGHT = 1000, 860
COUNT = [3]
ICONS = {"magenta": (1.0, 0.0, 1.0), "grey": (0.5, 0.5, 0.52), "blue": (0.2, 0.45, 0.95)}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            inside = 2 <= x < side - 2 and 2 <= y < side - 2
            r, g, b = colour
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 if inside else 0])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def rows():
    return [(700 + n, f"Change {700 + n}", "octo-sam", "open", "Approved", "passing") for n in range(COUNT[0])]


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body, kind, status=200):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/github/page/pulls"):
            return self.reply(pr.page(rows(), BASE, late=False), "text/html; charset=utf-8")
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon":
            return self.reply(png(ICONS[parts[-1].removesuffix(".png")]), "image/png")
        icon = parts[1] if len(parts) > 1 else "grey"
        title = urllib.parse.unquote(parts[0])
        self.reply((f"<!doctype html><meta charset=utf-8><title>{title}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#33373d'>").encode(), "text/html; charset=utf-8")


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("folder-air-" + uuid.uuid4().hex[:6])
t = sv.T()


def cmd(**r): return sv.cmd(r)
def state(): return sv.sp("state")
def live(*args): return sv.cmd({"do": "live", "args": list(args)})


def opened(name, icon="grey"):
    id = sv.sp("open", url=f"{BASE}/{urllib.parse.quote(name)}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    return id


SHOT = Path(os.environ.get("FOLDER_AIR_SHOT", "/tmp/folder-air-tools/shot"))


def tool():
    if SHOT.exists():
        return
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    source = SHOT.parent / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(SHOT.parent), check=True)


def picture(name, scratch):
    number = cmd(do="idle", action="unhide")["number"]
    time.sleep(0.6)
    pid = next(iter(sv.holding() & sv.running()))
    drawn = scratch / f"{name}-whole.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(drawn)], cwd=str(scratch),
                          capture_output=True, text=True).stdout.strip()
    if not drawn.exists():
        t.ok(f"pictured {name}", False, said)
        return
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(drawn)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(width / WIDTH))
    cut = scratch / f"{name}.png"
    column = int(options.width) + 12
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(drawn), "-vf",
                    f"crop={column * k}:{HEIGHT * k}:0:0", str(cut)], check=True)
    shutil.copy(cut, OUT / f"{name}.png")
    t.ok(f"pictured {name}", (OUT / f"{name}.png").exists())


def gaps(blocks):
    ordered = sorted(blocks, key=lambda b: b["y"])
    return [{"above": a["kind"], "below": b["kind"], "gap": round(b["y"] - (a["y"] + a["h"]), 2)}
            for a, b in zip(ordered, ordered[1:])]


def pitches(frames, order):
    def centre(name):
        box = frames["headings"].get(name) or frames["rows"].get(name)
        return box[1] + box[3] / 2 if box else None
    marks = [(name, centre(name)) for name in order]
    return [{"above": a, "below": b, "pitch": round(q - p, 2)} for (a, p), (b, q) in zip(marks, marks[1:]) if p is not None and q is not None]


def look(folder, how):
    cmd(do="group", name=folder, look=how)


def states(ids, scratch, measure):
    for folder in ["Reading", "Work", "Pinned"]:
        cmd(do="group", name=folder, fold=True)
    time.sleep(1.2)
    cmd(do="ui", look="dark")
    sv.sp("select", id=ids["Notes"])
    look("Reading", "hover")
    look("Work", "drop")
    time.sleep(0.8)
    picture("states-hover-drop-dark", scratch)
    look("Work", "clear")
    look("Reading", "clear")
    sv.sp("select", id=ids["Between"])
    look("Later", "edit")
    time.sleep(0.8)
    picture("states-rename-dark", scratch)
    look("Later", "clear")
    lines = {}
    for name, folder, how in [("line-over-folder", "Reading", "line"), ("line-between-folders", "Work", "line"),
                              ("line-under-folder", "Work", "lineunder"), ("line-over-live", "Pull Requests", "line"),
                              ("line-under-pinned", "Pinned", "lineunder")]:
        look(folder, how)
        time.sleep(0.5)
        found = cmd(do="rowframes")
        lines[name] = found.get("line")
        picture(f"{name}-dark", scratch)
    look("Reading", "clear")
    cmd(do="group", name="Later", fold=True)
    time.sleep(1.0)
    cmd(do="ui", look="light")
    sv.sp("select", id=ids["Between"])
    look("Later", "hover")
    look("Work", "drop")
    time.sleep(0.8)
    picture("states-hover-drop-light", scratch)
    look("Later", "clear")
    look("Work", "clear")
    measure["lines"] = lines


PICTURE = ["Reading list", "I finally fixed my sleep - YouTube", "Самоделкин – покупка дома, переезд", "Меняю ПИКАП на ДОМ",
           "Lantern Popup Options", "Lantern Settings Options", "Riley Park on X", "Claude Status"]


def picture_scene(scratch, measure):
    ids = {n: opened(n) for n in PICTURE}
    for x in state()["tabs"]:
        if not x.get("url"):
            sv.sp("close", id=x["id"])
    cmd(do="group", id=ids[PICTURE[1]], new=True, name="Garage Talks")
    cmd(do="group", id=ids[PICTURE[2]], name="Garage Talks")
    sv.sp("select", id=ids["Claude Status"])
    time.sleep(2.0)
    names = {ids[n]: n for n in PICTURE}
    for fold in ["open", "folded"]:
        if fold == "folded":
            cmd(do="group", name="Garage Talks", fold=True)
            time.sleep(1.2)
        frames = cmd(do="rowframes")
        frames["rows"] = {names.get(k, k): v for k, v in frames["rows"].items()}
        order = [PICTURE[0], "Garage Talks"] + (PICTURE[1:] if fold == "open" else PICTURE[3:])
        measure[fold] = {"pitches": pitches(frames, order), "gaps": gaps(frames["blocks"]) if frames.get("blocks") else None}
        for theme in ["dark", "light"]:
            cmd(do="ui", look=theme)
            time.sleep(1.0)
            picture(f"picture-{fold}-{theme}", scratch)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="folder-air-"))
    tool()
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.aiGroups": False, "ai": False, "ai.groups": False,
                                           "tabs.cards": True, "layout.cards": True, "start.fresh": False, "split": False,
                                           "tabs.newAtBottom": True, "live.on": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(options.width)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    measure = {"width": options.width}
    try:
        cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        if options.scene == "picture":
            picture_scene(scratch, measure)
            (OUT / "measure.json").write_text(json.dumps(measure, indent=1, ensure_ascii=False))
            return
        names = ["Inbox", "Notes", "Read-1", "Read-2", "Work-1", "Work-2", "Between", "Last-1", "Last-2", "Pinned-1"]
        ids = {n: opened(n, "blue" if "-" in n else "grey") for n in names}
        for x in state()["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        for folder, members in [("Reading", ["Read-1", "Read-2"]), ("Work", ["Work-1", "Work-2"]),
                                ("Later", ["Last-1", "Last-2"]), ("Pinned", ["Pinned-1"])]:
            cmd(do="group", id=ids[members[0]], new=True, name=folder)
            for m in members[1:]:
                cmd(do="group", id=ids[m], name=folder)
        cmd(do="group", name="Pinned", pinned=True)
        live("add-page", "Pull Requests", "pullRequests", f"{BASE}/github/page/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")
        live("unfold", "Pull Requests")
        live("update", "Pull Requests")
        sv.sp("select", id=ids["Inbox"])
        time.sleep(2.0)
        for fold in ["open", "folded"]:
            if fold == "folded":
                for folder in ["Reading", "Work", "Pinned"]:
                    cmd(do="group", name=folder, fold=True)
                time.sleep(1.2)
            frames = cmd(do="rowframes")
            measure[fold] = {"rows": frames.get("rows"), "blocks": frames.get("blocks"),
                             "gaps": gaps(frames["blocks"]) if frames.get("blocks") else None,
                             "column": cmd(do="columnscroll").get("measured") if fold == "open" else None}
            for theme in ["dark", "light"]:
                cmd(do="ui", look=theme)
                time.sleep(1.0)
                picture(f"{fold}-{theme}", scratch)
        states(ids, scratch, measure)
        (OUT / "measure.json").write_text(json.dumps(measure, indent=1))
    finally:
        t.done()
        sv.finish()
        shutil.rmtree(scratch, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import argparse
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
parser = argparse.ArgumentParser()
parser.add_argument("label", nargs="?", default="after")
parser.add_argument("--only", default="")
parser.add_argument("--looks", default="dark")
parser.add_argument("--shots", action="store_true")
options = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv
import pr_rows as pr

OUT = ROOT / ".context" / options.label
WIDTH, HEIGHT = 1000, 1100
COLUMN = 270
NOIR = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45, "glass": False}
ICONS = {"grey": (0.5, 0.5, 0.52), "red": (0.9, 0.15, 0.15), "blue": (0.2, 0.45, 0.95), "orange": (0.95, 0.5, 0.1)}
only = set(filter(None, options.only.split(",")))


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


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body, kind):
        try:
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        if self.path.startswith("/github/page/pulls"):
            return self.reply(pr.page([(701, "Change 701", "octo-sam", "open", "Approved", "passing")], BASE, late=False),
                              "text/html; charset=utf-8")
        parts = self.path.strip("/").split("/")
        if parts[0] == "icon":
            return self.reply(png(ICONS.get(parts[-1].removesuffix(".png"), ICONS["grey"])), "image/png")
        icon = parts[1] if len(parts) > 1 else "grey"
        title = urllib.parse.unquote(parts[0])
        self.reply((f"<!doctype html><meta charset=utf-8><title>{title}</title><link rel=icon href='/icon/{icon}.png'>"
                    f"<body style='background:#202124'>").encode(), "text/html; charset=utf-8")


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("tab-out-" + uuid.uuid4().hex[:6])
t = sv.T()
IDS = {}
NAMES = {}
SHOT = Path(os.environ.get("TAB_OUT_SHOT", "/tmp/tab-out-tools/shot"))
LOG = []
STATE = {"pid": None, "number": None, "scratch": None, "look": options.looks}


def cmd(**r): return sv.cmd(r)
def grid(**more): return sv.cmd({"do": "foldergrid", **more})
def folders(*args): return sv.cmd({"do": "folders", "args": list(args)})


def opened(name, icon="grey"):
    id = sv.sp("open", url=f"{BASE}/{urllib.parse.quote(name)}/{icon}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    IDS[name] = id
    NAMES[id] = name
    return id


def tool():
    if SHOT.exists():
        return
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    source = SHOT.parent / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(SHOT.parent), check=True)


def picture(name):
    if not options.shots:
        return None
    scratch = STATE["scratch"]
    whole = scratch / f"{name}-whole.png"
    subprocess.run([str(SHOT), str(STATE["pid"]), str(STATE["number"]), str(whole)], capture_output=True, text=True)
    if not whole.exists():
        return None
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(whole)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(width / WIDTH))
    out = OUT / f"{name}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(whole), "-vf",
                    f"crop={COLUMN * k}:ih:0:0", str(out)], check=True)
    whole.unlink()
    return out


def items(g=None):
    g = g or grid()
    return [NAMES.get(i, i) for i in g["items"]]


def rows(g):
    return {NAMES.get(r["id"], r["label"]): r for r in g["rows"]}


def heads(g):
    return {h["name"]: h for h in g["headings"]}


def folder_of(g, name):
    r = rows(g).get(name)
    return None if r is None else r["folder"]


def arrangement():
    state = folders()
    return json.dumps([state["order"], [[r["name"], r["tabs"]] for r in state["rows"]]])


def mouse(points, **extra):
    sv.sp("mouse", points=[[round(x, 1), round(y, 1)] for x, y in points], to="view", **extra)


def path(a, b, steps=6):
    return [(a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps) for i in range(1, steps + 1)]


def row_point(g, name, where=0.5, x=0.42):
    f = rows(g)[name]["frame"]
    return (f[0] + f[2] * x, f[1] + f[3] * where)


def head_point(g, name, where=0.5):
    f = heads(g)[name]["frame"]
    return (f[0] + f[2] * 0.42, f[1] + f[3] * where)


def drop_word(g):
    d = g.get("drop") or {}
    words = []
    if "group" in d:
        member = NAMES.get(d.get("member"), d.get("member"))
        words.append(f"into {d['group']}" + (f" {'after' if d.get('after') else 'before'} {member}" if member else ""))
    if "loose" in d:
        words.append("loose before " + (NAMES.get(d["loose"], d["loose"]) or "the end"))
    if "line" in d:
        words.append("line x=%.0f y=%.1f w=%.0f" % (d["line"][0], d["line"][1], d["line"][2]))
    if "outline" in d:
        words.append("outline")
    return ", ".join(words) or "nothing"


def carry(name, source, stops, expect, undo=True, start=None):
    if only and name not in only:
        return None
    g0 = grid(undoMark=True)
    before = items(g0)
    shape = arrangement()
    entry = {"name": name, "source": source, "before": before, "stops": []}
    lifted = rows(g0)[source]["frame"] if start is None else None
    start = start or row_point(g0, source)
    entry["undoBefore"] = g0.get("undo")
    mouse([start, (start[0], start[1] + 3), (start[0], start[1] + 7)], hold=True)
    time.sleep(0.2)
    last = (start[0], start[1] + 7)
    for index, stop_spec in enumerate(stops):
        what, point = stop_spec[0], stop_spec[1]
        want = stop_spec[2] if len(stop_spec) > 2 else ""
        if lifted and point[1] > lifted[1] + lifted[3]:
            point = (point[0], point[1] - lifted[3] - 3)
        mouse(path(last, point), resume=True, hold=True)
        last = point
        time.sleep(0.45)
        g = grid()
        shot = picture(f"{name}-{index + 1}")
        stop = {"what": what, "point": [round(point[0], 1), round(point[1], 1)], "drop": g.get("drop"),
                "seen": drop_word(g), "edges": g.get("edges"), "shot": shot.name if shot else None,
                "rows": {n: r["frame"] for n, r in rows(g).items()}}
        entry["stops"].append(stop)
        print(f"   {name} {index + 1} {what}: {stop['seen']} | top line {g.get('edges', {}).get('top')}", flush=True)
        drop = g.get("drop") or {}
        for word in filter(None, want.split("+")):
            if word.startswith("-"):
                t.ok(f"{name} {index + 1}: no {word[1:]} while {what}", word[1:] not in drop, stop["seen"])
                continue
            seen = (word in drop) if word in ("line", "outline") else g.get("edges", {}).get(word) == 1
            t.ok(f"{name} {index + 1}: {word} shows while {what}", seen, stop["seen"])
    mouse([last], resume=True)
    time.sleep(0.9)
    g = grid()
    entry["after"] = items(g)
    entry["folder"] = folder_of(g, source)
    entry["undoAfter"] = g.get("undo")
    print("   undo:", entry["undoBefore"], "->", entry["undoAfter"], flush=True)
    picture(f"{name}-landed")
    ok, said = expect(g)
    entry["landed"] = ok
    entry["said"] = said
    t.ok(f"{name}: {said}", ok, (entry["after"], entry["folder"]))
    entry["changed"] = arrangement() != shape
    if name.startswith("wiggle"):
        t.ok(f"{name}: nothing moved", not entry["changed"], entry["after"])
    if undo and entry["changed"]:
        grid(undo=True)
        time.sleep(0.8)
        back = items()
        entry["undone"] = back
        if undo == "record":
            entry["undoRestored"] = arrangement() == shape
            print(f"   {name}: Undo restored the arrangement: {entry['undoRestored']}", flush=True)
        else:
            t.ok(f"{name}: Undo puts it back", arrangement() == shape, (before, back))
    LOG.append(entry)
    (OUT / "log.json").write_text(json.dumps(LOG, indent=1, ensure_ascii=False))
    return entry


def unchanged(source, folder):
    def check(g):
        fine = folder_of(g, source) == folder and any(h["name"] == folder for h in g["headings"])
        return fine, f"{source} let go on its own slot stays in {folder}, and {folder} stays"
    return check


def placed_between(source, above, below, folder=""):
    def check(g):
        order = items(g)
        if source not in order and folder == "":
            return False, f"{source} lands between {above} and {below}"
        at = order.index(source) if source in order else -1
        fine = folder_of(g, source) == folder and (above is None or (above in order and order.index(above) == at - 1)) \
            and (below is None or (below in order and order.index(below) == at + 1))
        return fine, f"{source} lands loose between {above or 'the top'} and {below or 'the end'}"
    return check


def beside(source, other):
    def check(g):
        order = items(g)
        fine = source in order and other in order and abs(order.index(source) - order.index(other)) == 1 and folder_of(g, source) == ""
        return fine, f"{source} lands as a loose tab beside {other}, where the opened gap was"
    return check


def inside(source, folder, after=None, before=None):
    def check(g):
        fine = folder_of(g, source) == folder
        members = [n for n, r in sorted(rows(g).items(), key=lambda kv: kv[1]["frame"][1]) if r["folder"] == folder]
        if fine and after:
            fine = after in members and source in members and members.index(source) == members.index(after) + 1
        if fine and before:
            fine = before in members and source in members and members.index(source) == members.index(before) - 1
        return fine, f"{source} lands in {folder}" + (f" after {after}" if after else "") + (f" before {before}" if before else "")
    return check


def world():
    tool()
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.newAtBottom": True, "ai": False, "ai.groups": False,
                                           "tabs.aiGroups": False, "live.on": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(COLUMN - 12)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    STATE["pid"] = next(iter(sv.holding() & sv.running()))
    cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
    STATE["number"] = cmd(do="idle", action="unhide")["number"]
    sv.cmd({"do": "space", "action": "rename", "name": "Personal", "icon": "house"})
    sv.cmd({"do": "space", "action": "look", **NOIR})
    pins = [opened("X", "grey"), opened("Cloudflare", "orange")]
    names = [("Reading list", "grey"), ("Самоделкин – покупка дома", "red"), ("Otter Workshop - YouTube", "red")]
    names += [(n, "blue") for n in ["Lantern Popup Options", "Lantern Landing Page", "Lantern, a notes app", "App name",
                                    "Lantern Settings Options", "Lantern, the Mac"]]
    names += [("Claude Status", "orange"), ("Account - Apple Developer", "grey"), ("Namecheap", "orange"),
              ("Suggested Folder Options", "grey"), ("Suggested Folder Options 2", "grey"), ("lamp shades - Google Search", "blue")]
    for n, icon in names:
        opened(n, icon)
    for x in sv.sp("state")["tabs"]:
        if not x.get("url") or x["id"] not in NAMES:
            try:
                sv.sp("close", id=x["id"])
            except RuntimeError:
                pass
    for p in pins:
        cmd(do="pin", id=p)
    folders("with", "test", IDS["Reading list"], IDS["Самоделкин – покупка дома"])
    folders("with", "Lantern Vibes", *[IDS[n] for n, icon in names[3:9]])
    folders("with", "Folder Options", IDS["Suggested Folder Options"], IDS["Suggested Folder Options 2"])
    sv.sp("select", id=IDS["Account - Apple Developer"])
    cmd(do="ui", look=STATE["look"])
    time.sleep(1.5)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    STATE["scratch"] = Path(tempfile.mkdtemp(prefix="tab-out-"))
    BK, MB = "Самоделкин – покупка дома", "Reading list"
    try:
        world()
        g = grid()
        start = items(g)
        print("   list:", start, flush=True)
        t.ok("the world is his: three folders between loose tabs", start[:3] == ["folder:test", "Otter Workshop - YouTube", "folder:Lantern Vibes"]
             and start[-2:] == ["folder:Folder Options", "lamp shades - Google Search"] and g["edges"]["top"] == 0, start)
        picture("world")

        def gap(g, a, b):
            ra, rb = rows(g)[a]["frame"], rows(g)[b]["frame"]
            return (ra[0] + ra[2] * 0.42, (ra[1] + ra[3] + rb[1]) / 2)

        g = grid()
        lift = row_point(g, BK)
        carry("wiggle-last-row", BK, [("7 points under its own slot", (lift[0], lift[1] + 7), "-line")], unchanged(BK, "test"))
        g = grid()
        carry("between-loose", BK, [("over Account - Apple Developer", row_point(g, "Account - Apple Developer"), "line"),
                                    ("between Account and Namecheap", gap(g, "Account - Apple Developer", "Namecheap"), "line")],
              placed_between(BK, "Account - Apple Developer", "Namecheap"))
        g = grid()
        top = heads(g)["test"]["frame"]
        carry("top-above-folder", MB, [("over the test heading's top", (top[0] + top[2] * 0.42, top[1] + 3), "line"),
                                       ("in the strip above the list", (top[0] + top[2] * 0.42, top[1] - 4), "line+top")],
              placed_between(MB, None, "folder:test"))
        g = grid()
        last = rows(g)["lamp shades - Google Search"]["frame"]
        carry("end-after-loose", BK, [("below the last tab", (last[0] + last[2] * 0.42, last[1] + last[3] + 8), "line")],
              placed_between(BK, "lamp shades - Google Search", None))
        g = grid()
        carry("after-folder-out", BK, [("top of Claude Status, under Lantern Vibes", row_point(g, "Claude Status", 0.2), "line")],
              placed_between(BK, "folder:Lantern Vibes", "Claude Status"))
        g = grid()
        carry("into-folder-end", BK, [("bottom of Lantern Vibes' last row", row_point(g, "Lantern, the Mac", 0.8), "line")],
              inside(BK, "Lantern Vibes", after="Lantern, the Mac"))
        g = grid()
        fo = heads(g)["Folder Options"]["frame"]
        carry("before-folder-out", BK, [("bottom of Namecheap", row_point(g, "Namecheap", 0.8), "line"),
                                        ("top of the Folder Options heading", (fo[0] + fo[2] * 0.42, fo[1] + 3), "line")],
              placed_between(BK, "Namecheap", "folder:Folder Options"))
        g = grid()
        carry("folder-to-folder", BK, [("over Lantern Landing Page's top", row_point(g, "Lantern Landing Page", 0.3), "line")],
              inside(BK, "Lantern Vibes", before="Lantern Landing Page"))
        g = grid()
        carry("loose-into-folder", "Claude Status", [("over the Folder Options heading", head_point(g, "Folder Options"), "outline")],
              inside("Claude Status", "Folder Options"))
        g = grid()
        carry("loose-reorder-across", "Otter Workshop - YouTube",
              [("down across Lantern Vibes", row_point(g, "Claude Status", 0.5)),
               ("between Claude Status and Account", gap(g, "Claude Status", "Account - Apple Developer"))],
              placed_between("Otter Workshop - YouTube", "Claude Status", "Account - Apple Developer"))

        cmd(do="group", name="Lantern Vibes", fold=True)
        time.sleep(1.0)
        g = grid()
        bv = heads(g)["Lantern Vibes"]["frame"]
        carry("folded-after", BK, [("bottom of folded Lantern Vibes", (bv[0] + bv[2] * 0.42, bv[1] + bv[3] - 3), "line")],
              placed_between(BK, "folder:Lantern Vibes", "Claude Status"))
        g = grid()
        bv = heads(g)["Lantern Vibes"]["frame"]
        carry("folded-before", BK, [("top of folded Lantern Vibes", (bv[0] + bv[2] * 0.42, bv[1] + 3), "line")],
              placed_between(BK, "Otter Workshop - YouTube", "folder:Lantern Vibes"))
        g = grid()
        bv = heads(g)["Lantern Vibes"]["frame"]
        carry("loose-into-folded-edge", "Claude Status", [("3 points into folded Lantern Vibes' heading", (bv[0] + bv[2] * 0.42, bv[1] + 3), "outline")],
              inside("Claude Status", "Lantern Vibes"))
        cmd(do="group", name="Lantern Vibes", fold=True)
        time.sleep(1.0)

        folders("with", "Solo", IDS["lamp shades - Google Search"])
        time.sleep(0.8)
        g = grid()
        lift = row_point(g, "lamp shades - Google Search")
        carry("wiggle-only-row", "lamp shades - Google Search", [("7 points under its own slot", (lift[0], lift[1] + 7), "-line")],
              unchanged("lamp shades - Google Search", "Solo"))
        folders("remove", "Solo")
        time.sleep(0.8)

        cmd(do="resize", width=WIDTH, height=640, steps=1)
        time.sleep(1.0)
        sv.cmd({"do": "columnscroll", "wheel": 120})
        time.sleep(0.8)
        g = grid()
        scrolled = g["edges"]["top"] == 1
        t.ok("scrolled: the list is scrolled", scrolled, g["edges"])
        if scrolled:
            entry = carry("scrolled-between-loose", "Lantern Settings Options",
                          [("between Account and Namecheap, scrolled", gap(g, "Account - Apple Developer", "Namecheap"), "line")],
                          placed_between("Lantern Settings Options", "Account - Apple Developer", "Namecheap"))
            if entry:
                line = (entry["stops"][-1]["drop"] or {}).get("line")
                a, n = entry["stops"][-1]["rows"]["Account - Apple Developer"], entry["stops"][-1]["rows"]["Namecheap"]
                t.ok("scrolled: the line sits between the two rows where they are now",
                     bool(line) and a[1] + a[3] - 1 <= line[1] + line[3] / 2 <= n[1] + 1, (line, a, n))
        cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        time.sleep(1.0)

        cmd(do="group", id=IDS["lamp shades - Google Search"], name="Folder Options")
        time.sleep(0.8)
        g = grid()
        fo = g["items"][-1]
        card = [b for b in g["blocks"] if b["kind"] == "folder"][-1]
        carry("end-after-folder", BK, [("below the last folder", (card["x"] + card["w"] * 0.42, card["y"] + card["h"] + 8), "line")],
              placed_between(BK, "folder:Folder Options", None))
        cmd(do="group", id=IDS["lamp shades - Google Search"], name="none")
        time.sleep(0.8)

        folders("new", "Inner", "Lantern Vibes")
        cmd(do="group", id=IDS["App name"], name="Inner")
        time.sleep(1.0)
        g = grid()
        carry("nested-to-parent", "App name", [("over Lantern Landing Page's top", row_point(g, "Lantern Landing Page", 0.3), "line")],
              inside("App name", "Lantern Vibes", before="Lantern Landing Page"))
        g = grid()
        carry("nested-to-loose", "App name", [("between Claude Status and Account", gap(g, "Claude Status", "Account - Apple Developer"), "line")],
              placed_between("App name", "Claude Status", "Account - Apple Developer"))

        g = grid()
        top = heads(g)["test"]["frame"]
        moved = carry("top-above-folder-kept", MB, [("over the test heading's top", (top[0] + top[2] * 0.42, top[1] + 3), "line")],
                      placed_between(MB, None, "folder:test"), undo=False)
        if moved and moved.get("landed"):
            g = grid()
            first = rows(g)[MB]["frame"]
            carry("top-above-loose", "Lantern Popup Options",
                  [("above the first loose tab", (first[0] + first[2] * 0.42, first[1] - 3), "line")],
                  placed_between("Lantern Popup Options", None, MB))
        if moved and moved.get("landed"):
            grid(undo=True)
            time.sleep(0.8)

        frames = cmd(do="rowframes")["rows"]
        x = frames[IDS["X"]]
        g = grid()
        carry("pin-to-loose", "X", [("between Account and Namecheap", gap(g, "Account - Apple Developer", "Namecheap"))],
              beside("X", "Account - Apple Developer"), start=(x[0] + x[2] / 2, x[1] + x[3] / 2))

        sv.cmd({"do": "live", "args": ["add-page", "Pull Requests", "pullRequests",
                                       f"{BASE}/github/page/pulls?q=is%3Aopen+is%3Apr+author%3A%40me"]})
        sv.cmd({"do": "live", "args": ["unfold", "Pull Requests"]})
        sv.cmd({"do": "live", "args": ["update", "Pull Requests"]})
        for _ in range(50):
            g = grid()
            live = [r for r in g["rows"] if r["folder"] == "Pull Requests"]
            if live: break
            time.sleep(0.2)
        picture("live-world")
        if live:
            row = live[0]
            NAMES[row["id"]] = row["label"]
            g = grid()
            carry("live-row-out", row["label"], [("between Account and Namecheap", gap(g, "Account - Apple Developer", "Namecheap"), "line")],
                  placed_between(row["label"], "Account - Apple Developer", "Namecheap"), undo="record")
        else:
            t.ok("a live folder row to carry", False, [r["folder"] for r in g["rows"]])
    finally:
        (OUT / "log.json").write_text(json.dumps(LOG, indent=1, ensure_ascii=False))
        t.done()
        sv.finish()
        shutil.rmtree(STATE["scratch"], ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

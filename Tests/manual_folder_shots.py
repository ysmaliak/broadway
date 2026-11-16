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
parser.add_argument("--width", type=float, default=258)
options = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402
import pr_rows as pr  # noqa: E402

OUT = ROOT / ".context" / options.label
WIDTH, HEIGHT = 1000, 900
ICONS = {"grey": (0.5, 0.5, 0.52), "blue": (0.2, 0.45, 0.95)}


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


def pulls():
    return [(701, "Change 701", "octo-sam", "open", "Approved", "passing")]


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def reply(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/github/page/pulls"):
            return self.reply(pr.page(pulls(), BASE, late=False), "text/html; charset=utf-8")
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
sv.use("manual-folders-" + uuid.uuid4().hex[:6])
t = sv.T()
ANCHOR = {}


def cmd(**r): return sv.cmd(r)
def state(): return sv.sp("state")
def live(*args): return sv.cmd({"do": "live", "args": list(args)})
def ai(*args): return sv.cmd({"do": "aigroups", "args": list(args)})
def folders(*args): return sv.cmd({"do": "folders", "args": list(args)})
def grid(**more): return sv.cmd({"do": "foldergrid", **more})


def opened(name, icon="grey"):
    more = {"from": ANCHOR["id"]} if "id" in ANCHOR else {}
    id = sv.sp("open", url=f"{BASE}/{urllib.parse.quote(name)}/{icon}", **more)["resultID"]
    cmd(do="wait", id=id, seconds=10)
    return id


def wait_for(test, within=10):
    until = time.time() + within
    while time.time() < until:
        value = test()
        if value:
            return value
        time.sleep(0.2)
    return test()


SHOT = Path(os.environ.get("MANUAL_FOLDER_SHOT", "/tmp/manual-folder-tools/shot"))


def tool():
    if SHOT.exists():
        return
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    source = SHOT.parent / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(SHOT.parent), check=True)


SCALE = [2]


def picture(name, scratch):
    number = cmd(do="idle", action="unhide")["number"]
    time.sleep(0.6)
    pid = next(iter(sv.holding() & sv.running()))
    drawn = scratch / f"{name}-whole.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(drawn)], cwd=str(scratch),
                          capture_output=True, text=True).stdout.strip()
    if not drawn.exists():
        t.ok(f"pictured {name}", False, said)
        return None
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(drawn)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(width / WIDTH))
    SCALE[0] = k
    column = int(options.width) + 12
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(drawn), "-vf",
                    f"crop={column * k}:{HEIGHT * k}:0:0", str(OUT / f"{name}.png")], check=True)
    t.ok(f"pictured {name}", (OUT / f"{name}.png").exists())
    return OUT / f"{name}.png"


def pixels(path, box):
    k = SCALE[0]
    x, y, w, h = [int(round(v * k)) for v in box]
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-vf", f"crop={w}:{h}:{x}:{y}",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout
    return [raw[row * w:(row + 1) * w] for row in range(h)], w, h


def ink(path, box, dark):
    rows, w, h = pixels(path, box)
    if not rows or len(rows[0]) != w:
        return None
    def lit(v): return v > 200 if dark else v < 90
    xs = [x for x in range(w) if any(lit(rows[y][x]) for y in range(h))]
    ys = [y for y in range(h) if any(lit(v) for v in rows[y])]
    if not xs or not ys:
        return None
    k = SCALE[0]
    return {"left": round(box[0] + xs[0] / k, 2), "right": round(box[0] + (xs[-1] + 1) / k, 2),
            "top": round(box[1] + ys[0] / k, 2), "bottom": round(box[1] + (ys[-1] + 1) / k, 2)}


def drawn(path, box):
    rows, w, h = pixels(path, box)
    if not rows or len(rows[0]) != w:
        return None
    counts = {}
    for row in rows:
        for v in row:
            counts[v] = counts.get(v, 0) + 1
    ground = max(counts, key=counts.get)
    xs = [x for x in range(w) if any(abs(rows[y][x] - ground) > 40 for y in range(h))]
    ys = [y for y in range(h) if any(abs(v - ground) > 40 for v in rows[y])]
    if not xs or not ys:
        return None
    k = SCALE[0]
    return {"left": round(box[0] + xs[0] / k, 2), "right": round(box[0] + (xs[-1] + 1) / k, 2),
            "top": round(box[1] + ys[0] / k, 2), "bottom": round(box[1] + (ys[-1] + 1) / k, 2)}


def seen_pixels(shots, found):
    out = {}
    for theme, path in shots.items():
        if not path:
            continue
        heads, rows = {}, {}
        for head in found["headings"]:
            if "mark" not in head or "nameHost" not in head:
                continue
            frame = head["frame"]
            icon = drawn(path, [head["mark"][0] - 2, frame[1] + 3, head["mark"][2] + 4, frame[3] - 6])
            name = drawn(path, [head["nameHost"][0] - 3, frame[1] + 3, head["nameWidth"] + 4, frame[3] - 6])
            heads[head["name"]] = {"depth": head["depth"], "kind": head["kind"], "icon": icon, "name": name}
        for row in found["rows"]:
            if "icon" not in row or "title" not in row:
                continue
            frame = row["frame"]
            icon = drawn(path, [row["icon"][0] - 2, row["icon"][1] - 2, row["icon"][2] + 4, row["icon"][3] + 4])
            name = drawn(path, [row["title"][0] - 3, frame[1] + 5, 40, 16])
            rows[row["label"]] = {"folder": row["folder"], "icon": icon, "name": name}
        out[theme] = {"headings": heads, "rows": rows}
    return out


def pixel_offsets(seen, parents):
    out = []
    for theme, found in seen.items():
        loose = [r for r in found["rows"].values() if r["folder"] == ""]
        for name, head in found["headings"].items():
            parent = parents.get(name)
            peers = loose if parent is None else [r for r in found["rows"].values() if r["folder"] == parent]
            if not peers or not head["icon"] or not head["name"] or not peers[0]["icon"] or not peers[0]["name"]:
                continue
            peer = peers[0]
            out.append({"theme": theme, "heading": name, "depth": head["depth"], "kind": head["kind"],
                        "iconCentre": round((head["icon"]["left"] + head["icon"]["right"]) / 2, 2),
                        "rowIconCentre": round((peer["icon"]["left"] + peer["icon"]["right"]) / 2, 2),
                        "nameLeft": head["name"]["left"], "rowTitleLeft": peer["name"]["left"],
                        "textMiddle": round((head["name"]["top"] + head["name"]["bottom"]) / 2
                                            - (head["icon"]["top"] + head["icon"]["bottom"]) / 2, 2)})
    return out


def centre(box): return round(box[0] + box[2] / 2, 2)
def middle(box): return round(box[1] + box[3] / 2, 2)


def table(found):
    rows = {}
    for row in found["rows"]:
        if "icon" in row and "title" in row:
            rows[row["label"]] = {"folder": row["folder"], "icon": centre(row["icon"]), "iconY": middle(row["icon"]),
                                  "title": round(row["title"][0], 2), "rowY": middle(row["frame"])}
    heads = {}
    for head in found["headings"]:
        entry = {"kind": head["kind"], "depth": head["depth"], "raised": head["raised"], "collapsed": head["collapsed"],
                 "emoji": head["emoji"], "height": head["frame"][3], "y": round(head["frame"][1], 2)}
        if "mark" in head:
            entry["icon"] = centre(head["mark"])
            entry["iconY"] = round(middle(head["mark"]) - middle(head["frame"]), 2)
        if "nameHost" in head:
            entry["name"] = round(head["nameHost"][0], 2)
            entry["nameY"] = round(middle(head["nameHost"]) - middle(head["frame"]), 2)
        if "chevron" in head:
            entry["chevronGap"] = round(head["chevron"][0] - (head.get("nameHost", head["chevron"])[0] + head["nameWidth"]), 2)
        if "chip" in head:
            entry["chipRight"] = round(head["frame"][0] + head["frame"][2] - (head["chip"][0] + head["chip"][2]), 2)
        if "field" in head:
            entry["field"] = round(head["field"][0], 2)
        heads[head["name"]] = entry
    return {"rows": rows, "headings": heads, "items": found["items"], "raised": found["raised"], "editing": found["editing"]}


def against(found, parents):
    seen = table(found)
    loose = [r for r in seen["rows"].values() if r["folder"] == ""]
    out = []
    for name, head in seen["headings"].items():
        if "icon" not in head:
            continue
        parent = parents.get(name)
        peers = loose if parent is None else [r for r in seen["rows"].values() if r["folder"] == parent]
        if not peers:
            continue
        out.append({"heading": name, "kind": head["kind"], "depth": head["depth"], "raised": head["raised"],
                    "iconOff": round(head["icon"] - peers[0]["icon"], 2), "nameOff": round(head.get("name", 0) - peers[0]["title"], 2)})
    return out


def gaps(blocks):
    ordered = sorted(blocks, key=lambda b: b["y"])
    return [{"above": a["kind"], "below": b["kind"], "gap": round(b["y"] - (a["y"] + a["h"]), 2)}
            for a, b in zip(ordered, ordered[1:])]


def both(name, scratch):
    out = {}
    for theme in ["dark", "light"]:
        cmd(do="ui", look=theme)
        time.sleep(1.0)
        out[theme] = picture(f"{name}-{theme}", scratch)
    return out


def name_ink(shots, found, name):
    head = next((h for h in found["headings"] if h["name"] == name), None)
    if not head:
        return None
    part = head.get("field") or head.get("nameHost")
    if not part:
        return None
    box = [part[0] - 6, head["frame"][1] + 2, min(120, head["nameWidth"] + 16), head["frame"][3] - 4]
    return {theme: ink(path, box, theme == "dark") for theme, path in shots.items() if path}


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="manual-folders-"))
    tool()
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "ai": True, "ai.groups": True, "tabs.cards": True,
                                           "layout.cards": True, "start.fresh": False, "split": False,
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
        ai("fake", "0.2", "0.5")
        blank = next((x["id"] for x in state()["tabs"] if x.get("blank")), None)
        if blank:
            ANCHOR["id"] = blank
        ids = {n: opened(n) for n in ["Inbox", "Notes", "Budget"]}
        for n in ["Lisbon flights", "Lisbon hotels"]:
            ids[n] = opened(n, "blue")
        made = wait_for(lambda: [g for g in ai("state")["groups"] if g["ai"] and g["how"]], 10)
        t.ok("the fake engine made an AI folder", len(made) == 1 and made[0]["name"] == "Lisbon", made)
        live("add-page", "Pull Requests", "pullRequests", f"{BASE}/github/page/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")
        live("unfold", "Pull Requests")
        live("update", "Pull Requests")
        ANCHOR.clear()
        for x in state()["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        sv.sp("select", id=ids["Inbox"])
        time.sleep(2.0)

        found = grid(make=True)
        time.sleep(1.0)
        found = grid()
        new = found["editing"]
        t.ok("New Folder from the menu starts with its name being edited", new != "", found["editing"])
        measure["new"] = {"name": new, "items": found["items"], "raised": found["raised"]}
        t.ok("it is the first thing in the list, under the raised folders", found["items"][:1] == [f"folder:{new}"], found["items"])
        t.ok("it is not raised", new not in found["raised"], found["raised"])
        shots = both("new-editing", scratch)
        measure["new"]["editing"] = table(grid())["headings"].get(new)
        measure["new"]["fieldInk"] = name_ink(shots, grid(), new)
        cmd(do="group", name=new, look="clear")
        time.sleep(0.8)
        shots = both("new-empty", scratch)
        found = grid()
        measure["new"]["rest"] = table(found)["headings"].get(new)
        measure["new"]["nameInk"] = name_ink(shots, found, new)
        measure["new"]["gaps"] = gaps(found["blocks"])
        t.ok("the field's text sits exactly where the name sits, light and dark",
             measure["new"]["fieldInk"] == measure["new"]["nameInk"] and None not in (measure["new"]["nameInk"] or {None: None}).values(),
             (measure["new"]["fieldInk"], measure["new"]["nameInk"]))
        t.ok("an empty folder is as far from the row under it as a row is",
             {(g["above"], g["below"]): g["gap"] for g in measure["new"]["gaps"]}.get(("folder", "row")) == 3, measure["new"]["gaps"])
        cmd(do="group", name=new, fold=True)
        time.sleep(1.0)
        both("new-empty-folded", scratch)
        cmd(do="group", name=new, fold=True)
        time.sleep(1.0)

        cmd(do="group", id=ids["Budget"], name=new)
        ai("rename", new, "Hand")
        time.sleep(0.8)
        cmd(do="group", id=ids["Notes"], new=True, name="From Tab")
        time.sleep(1.0)
        found = grid()
        measure["fromTab"] = {"items": found["items"], "raised": found["raised"]}
        t.ok("a folder made from a tab sits where the tab was, holding it",
             found["items"] == ["folder:Hand", ids["Inbox"], "folder:From Tab", "folder:Lisbon"], found["items"])
        both("filled", scratch)
        cmd(do="group", name="From Tab", ungroup=True)
        sv.sp("close", id=ids["Notes"])

        folders("new", "Child", "Hand")
        ids["Kite"] = opened("Kite")
        cmd(do="group", id=ids["Kite"], name="Child")
        folders("new", "Grand", "Child")
        ids["Maple"] = opened("Maple")
        cmd(do="group", id=ids["Maple"], name="Grand")
        folders("new", "Sub", "Lisbon")
        ids["Otter"] = opened("Otter")
        cmd(do="group", id=ids["Otter"], name="Sub")
        ids["Quartz read"] = opened("Quartz read")
        cmd(do="group", id=ids["Quartz read"], name="none")
        sv.cmd({"do": "searchfolder", "args": ["filter", "read"]})
        folders("new", "Raised")
        ids["Violet"] = opened("Violet")
        cmd(do="group", id=ids["Violet"], name="Raised")
        cmd(do="group", name="Raised", pinned=True)
        sv.cmd({"do": "icon", "args": ["set", "folder", "Raised", "emoji", "📌"]})
        sv.sp("select", id=ids["Inbox"])
        time.sleep(2.0)
        parents = {"Child": "Hand", "Grand": "Child", "Sub": "Lisbon"}
        found = grid()
        measure["open"] = {"grid": table(found), "against": against(found, parents), "gaps": gaps(found["blocks"])}
        off = [a for a in measure["open"]["against"] if a["iconOff"] != 0 or a["nameOff"] != 0]
        kinds = {(a["kind"], a["depth"], a["raised"]) for a in measure["open"]["against"]}
        t.ok("every heading's icon and name are on its sibling rows' grid", not off, off)
        t.ok("hand-made at depth 0, 1 and 2, AI-made, live, search and raised were all measured",
             {("hand", 0, False), ("hand", 1, False), ("hand", 2, False), ("ai", 0, False), ("live", 0, True),
              ("search", 0, False), ("hand", 0, True)} <= kinds, sorted(kinds))
        heads = measure["open"]["grid"]["headings"].values()
        t.ok("every heading centres its icon and its name on its own middle",
             all(h.get("iconY") == 0 and h.get("nameY") == 0 and h["height"] == 28 for h in heads), list(heads))
        shots = both("grid-open", scratch)
        measure["open"]["pixels"] = pixel_offsets(seen_pixels(shots, found), parents)
        far = [p for p in measure["open"]["pixels"]
               if abs(p["iconCentre"] - p["rowIconCentre"]) > 1 or abs(p["nameLeft"] - p["rowTitleLeft"]) > 1]
        t.ok("in the pictures too, each heading's icon and name are within a point of its sibling row's", not far, far)
        for name in ["Grand", "Child", "Sub"]:
            cmd(do="group", name=name, fold=True)
        time.sleep(1.2)
        found = grid()
        measure["inner-folded"] = {"grid": table(found), "against": against(found, parents)}
        shots = both("grid-inner-folded", scratch)
        measure["inner-folded"]["pixels"] = pixel_offsets(seen_pixels(shots, found), parents)
        for name in [h["name"] for h in found["headings"] if h["depth"] == 0]:
            cmd(do="group", name=name, fold=True)
        time.sleep(1.4)
        found = grid()
        measure["folded"] = {"grid": table(found), "against": against(found, parents), "gaps": gaps(found["blocks"])}
        shots = both("grid-folded", scratch)
        measure["folded"]["pixels"] = pixel_offsets(seen_pixels(shots, found), parents)
        (OUT / "measure.json").write_text(json.dumps(measure, indent=1, ensure_ascii=False))
    finally:
        t.done()
        sv.finish()
        shutil.rmtree(scratch, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

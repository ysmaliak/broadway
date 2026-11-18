#!/usr/bin/env python3
import argparse
import json
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
parser.add_argument("label", nargs="?", default="after")
parser.add_argument("--only", default="")
parser.add_argument("--shots", action="store_true")
parser.add_argument("--trace", default="")
options = parser.parse_args()
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402

OUT = ROOT / ".context" / "split-row-drag" / options.label
WIDTH, HEIGHT = 1100, 900
COLUMN = 270
only = set(filter(None, options.only.split(",")))
FEED = """<?xml version="1.0"?><rss version="2.0"><channel><title>News</title><link>{base}/</link>
<item><title>First story</title><link>{base}/story-1</link></item>
<item><title>Second story</title><link>{base}/story-2</link></item></channel></rss>"""


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        if self.path.startswith("/feed.xml"):
            body, kind = FEED.format(base=BASE).encode(), "application/rss+xml"
        else:
            name = urllib.parse.unquote(self.path.strip("/").split("?")[0]) or "page"
            body = (f"<!doctype html><meta charset=utf-8><title>{name}</title>"
                    f"<body style='background:#f4f1ea;font:28px -apple-system;margin:40px'><h1>{name}</h1>").encode()
            kind = "text/html; charset=utf-8"
        try:
            self.send_response(200)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("split-row-" + uuid.uuid4().hex[:6])
t = sv.T()
IDS, NAMES = {}, {}
TABLE = []
STATE = {"pid": None, "number": None, "scratch": None}
SHOT = Path(tempfile.gettempdir()) / "split-row-drag-tools" / "shot"


def cmd(**r): return sv.cmd(r)
def grid(**more): return sv.cmd({"do": "foldergrid", **more})
def folders(*args): return sv.cmd({"do": "folders", "args": list(args)})
def live(*args): return sv.cmd({"do": "live", "args": list(args)})
def short(id): return (id or "")[:8].lower()
def name(id): return NAMES.get(short(id), id)


def opened(label):
    id = sv.sp("open", url=f"{BASE}/{urllib.parse.quote(label)}")["resultID"]
    cmd(do="wait", id=id, seconds=10)
    IDS[label] = short(id)
    NAMES[short(id)] = label
    return id


def tool():
    if SHOT.exists():
        return
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    source = SHOT.parent / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(SHOT.parent), check=True)


def picture(label, whole_window=False):
    if not options.shots:
        return None
    whole = STATE["scratch"] / f"{label}-whole.png"
    made = subprocess.run([str(SHOT), str(STATE["pid"]), str(STATE["number"]), str(whole)], capture_output=True, text=True, timeout=20)
    out = OUT / f"{label}.png"
    if not whole.exists():
        if not STATE.get("said"):
            print("   window pictures unavailable here, the column drawn by the app instead:", made.stdout.strip()[-120:], flush=True)
            STATE["said"] = True
        frames = STATE["scratch"] / f"{label}-frames"
        grid(sample=0.05, frames=str(frames), width=COLUMN)
        first = frames / "0000.png"
        if not first.exists():
            return None
        shutil.move(str(first), out)
        return out
    if whole_window:
        shutil.move(str(whole), out)
        return out
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(whole)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(width / WIDTH))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(whole), "-vf", f"crop={COLUMN * k}:ih:0:0", str(out)], check=True)
    whole.unlink()
    return out


def mouse(points, **extra):
    sv.sp("mouse", points=[[round(x, 1), round(y, 1)] for x, y in points], to="view", **extra)


def path(a, b, steps=8):
    return [(a[0] + (b[0] - a[0]) * i / steps, a[1] + (b[1] - a[1]) * i / steps) for i in range(1, steps + 1)]


def rows(g): return {name(r["id"]): r for r in g["rows"]}
def heads(g): return {h["name"]: h for h in g["headings"]}
def items(g=None): return [name(i) if not i.startswith("folder:") else i for i in (g or grid())["items"]]


def the_pair(g=None):
    g = g or grid()
    for s in g.get("splits", []):
        if name(s["left"]) == "Left":
            return s
    return None


def paired():
    st = sv.sp("state")
    return any({name(s["left"]), name(s["right"])} == {"Left", "Right"} for s in st["splits"])


def where():
    g = grid()
    st = sv.sp("state")
    pairs = [[name(s["left"]), name(s["right"])] for s in st["splits"]]
    s = the_pair(g)
    pins = [name(p) for p in st.get("pins", [])]
    return {"paired": ["Left", "Right"] in pairs, "pairs": pairs, "folder": s["folder"] if s else None,
            "items": items(g), "pins": pins, "active": name(st.get("activeID")),
            "folders": {h["name"]: members(g, h["name"]) for h in g["headings"]}}


def members(g, folder):
    shown = [(r["frame"][1], name(r["id"]), r["folder"]) for r in g["rows"]]
    shown += [(s["frame"][1], name(s["left"]), s["folder"]) for s in g.get("splits", [])]
    return [n for _, n, f in sorted(shown) if f == folder]


def arrangement():
    st = folders()
    return json.dumps([st["order"], [[r["name"], r["tabs"]] for r in st["rows"]], sorted(map(sorted, where()["pairs"]))])


def drop_word(g):
    d = g.get("drop") or {}
    words = []
    if "group" in d:
        member = name(d.get("member"))
        words.append(f"into {d['group']}" + (f" {'after' if d.get('after') else 'before'} {member}" if member else ""))
    if "loose" in d:
        words.append("loose before " + (name(d["loose"]) or "the end"))
    if "line" in d:
        words.append("line")
    if "outline" in d:
        words.append("outline")
    return ", ".join(words) or "nothing"


def head_point(g, label, where_=0.5):
    f = heads(g)[label]["frame"]
    return (f[0] + f[2] * 0.42, f[1] + f[3] * where_)


def row_point(g, label, where_=0.5):
    f = rows(g)[label]["frame"]
    return (f[0] + f[2] * 0.42, f[1] + f[3] * where_)


def gap(g, above, below):
    a, b = rows(g)[above]["frame"], rows(g)[below]["frame"]
    return (a[0] + a[2] * 0.42, (a[1] + a[3] + b[1]) / 2)


def chip_point(g, half=0):
    s = the_pair(g)
    c = s["chips"][half]
    return (c[0] + c[2] * 0.5, c[1] + c[3] * 0.5)


def stage():
    cards = sv.sp("state")["stage"].get("cards", [])
    xs = [c[0] for c in cards] + [c[2] for c in cards]
    ys = [c[1] for c in cards] + [c[3] for c in cards]
    return min(xs), min(ys), max(xs), max(ys)


def carry(label, stops, expect, half=0, undo=True, wanted="", whole_window=False, hold=0.45, undo_checked=True,
          front="Loose A", active=None, press=None):
    if only and label not in only:
        return None
    sv.sp("select", id=IDS["Loose B" if front != "Loose B" else "Loose C"])
    sv.sp("select", id=IDS[front])
    if front in ("Left", "Right"):
        sv.sp("focus", id=IDS[front])
    time.sleep(0.4)
    g0 = grid(undoMark=True)
    shape = arrangement()
    before = where()
    entry = {"case": label, "before": before, "stops": []}
    if the_pair(g0) is None:
        entry["result"] = "no split row to press"
        t.ok(f"{label}: a split row to press", False, items(g0))
        TABLE.append(entry)
        return entry
    start = press(g0) if press else chip_point(g0, half)
    mouse([start, (start[0], start[1] + 3), (start[0], start[1] + 7)], hold=True)
    time.sleep(0.25)
    last = (start[0], start[1] + 7)
    for index, (what, aim) in enumerate(stops):
        point = aim(grid())
        if hold == 0 and index == len(stops) - 1:
            mouse(path(last, point, 3) + [point], resume=True)
            last = None
            entry["stops"].append({"what": what, "point": [round(point[0], 1), round(point[1], 1)], "seen": "let go at once"})
            break
        mouse(path(last, point), resume=True, hold=True)
        last = point
        time.sleep(hold if index < len(stops) - 1 else max(hold, 0.45))
        g = grid()
        shot = picture(f"{label}-{index + 1}", whole_window)
        lifted = the_pair(g)
        if label in options.trace.split(","):
            print("   trace held:", json.dumps(g.get("drag")), flush=True)
        stop = {"what": what, "point": [round(point[0], 1), round(point[1], 1)], "seen": drop_word(g), "drop": g.get("drop"),
                "rowShown": lifted is not None and lifted.get("alpha", 1) > 0.5, "shot": shot.name if shot else None}
        entry["stops"].append(stop)
        print(f"   {label} {index + 1} {what}: {stop['seen']}", flush=True)
    if last is not None:
        mouse([last], resume=True)
    time.sleep(1.0)
    if label in options.trace.split(","):
        print("   trace after:", json.dumps(grid().get("drag")), flush=True)
    after = where()
    entry["after"] = after
    shot = picture(f"{label}-landed", whole_window)
    entry["landedShot"] = shot.name if shot else None
    ok, said = expect(before, after)
    entry["result"] = said if ok else f"not as wanted: {describe(after)}"
    entry["ok"] = ok
    entry["changed"] = arrangement() != shape
    t.ok(f"{label}: {said}", ok, describe(after))
    if active:
        looked = sv.cmd({"do": "probe"})
        entry["activeAfter"] = after.get("active")
        entry["editingAfter"] = bool(looked.get("editingTab"))
        t.ok(f"{label}: {active} is the tab in front afterwards", after.get("active") == active, after.get("active"))
        t.ok(f"{label}: no address field opened", not looked.get("editingTab"), looked.get("editingTab"))
    if wanted:
        seen = entry["stops"][-1]["seen"] if entry["stops"] else ""
        t.ok(f"{label}: the mark under the pointer was '{wanted}'", all(w in seen for w in wanted.split("+")), seen)
    if undo and entry["changed"]:
        grid(undo=True)
        time.sleep(0.9)
        back = arrangement() == shape
        entry["undone"] = back
        if undo_checked:
            t.ok(f"{label}: Undo puts the pair back where it was, a pair", back and paired(), describe(where()))
        else:
            entry["undoNote"] = describe(where())
            print(f"   {label}: after Undo (not checked): {describe(where())}", flush=True)
    print(f"   {label}: {entry['result']}", flush=True)
    TABLE.append(entry)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "table.json").write_text(json.dumps(TABLE, indent=1, ensure_ascii=False))
    return entry


def describe(w):
    return f"paired={w['paired']} folder={w['folder']!r} items={w['items']} pins={w['pins']} pairs={w['pairs']}"


def in_folder(folder, after=None, before=None):
    def check(_, w):
        members_ = w["folders"].get(folder, [])
        fine = w["paired"] and w["folder"] == folder
        if fine and after:
            fine = after in members_ and "Left" in members_ and members_.index("Left") == members_.index(after) + 1
        if fine and before:
            fine = before in members_ and "Left" in members_ and members_.index("Left") == members_.index(before) - 1
        return fine, f"the pair lands in {folder}" + (f" after {after}" if after else "") + (f" before {before}" if before else "") + ", still a pair"
    return check


def loose_between(above, below):
    def check(_, w):
        order = w["items"]
        at = order.index("Left") if "Left" in order else -1
        fine = w["paired"] and w["folder"] == "" and at >= 0 \
            and (above is None or (at > 0 and order[at - 1] == above)) and (below is None or (at + 1 < len(order) and order[at + 1] == below))
        return fine, f"the pair lands loose between {above or 'the top'} and {below or 'the end'}, still a pair"
    return check


def stays():
    def check(before, w):
        fine = w["paired"] and w["folder"] == before["folder"] and w["items"] == before["items"] and w["pins"] == before["pins"]
        return fine, "refused: the pair stays where it was, a pair"
    return check


def world():
    tool()
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "tabs.newAtBottom": True, "ai": False, "ai.groups": False,
                                           "tabs.aiGroups": False, "live.on": True, "start.fresh": False, "welcome.show": False,
                                           "layout.cards": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(COLUMN - 12)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    STATE["pid"] = next(iter(sv.holding() & sv.running()))
    cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
    STATE["number"] = cmd(do="idle", action="unhide")["number"]
    sv.sp("enabled", on=True)
    for label in ["Pin", "Loose A", "Left", "Right", "Loose B", "Loose C", "Work 1", "Work 2", "Shut 1", "Outer 1", "Inner 1",
                  "Other Left", "Other Right"]:
        opened(label)
    for x in sv.sp("state")["tabs"]:
        if short(x["id"]) not in NAMES:
            try:
                sv.sp("close", id=x["id"])
            except RuntimeError:
                pass
    cmd(do="pin", id=IDS["Pin"])
    sv.sp("pair", id=IDS["Right"], **{"with": IDS["Left"]}, side="right")
    sv.sp("pair", id=IDS["Other Right"], **{"with": IDS["Other Left"]}, side="right")
    folders("with", "Work", IDS["Work 1"], IDS["Work 2"])
    folders("with", "Shut", IDS["Shut 1"])
    folders("with", "Outer", IDS["Outer 1"])
    folders("with", "Inner", IDS["Inner 1"])
    folders("nest", "Inner", "Outer")
    live("on")
    live("add", "News", f"{BASE}/feed.xml")
    sv.sp("select", id=IDS["Loose A"])
    time.sleep(1.5)
    shut = heads(grid()).get("Shut")
    if shut and not shut["collapsed"]:
        cmd(do="group", name="Shut", fold=True)
    time.sleep(1.5)


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    STATE["scratch"] = Path(tempfile.mkdtemp(prefix="split-row-"))
    try:
        world()
        w = where()
        print("   list:", w["items"], flush=True)
        print("   folders:", w["folders"], flush=True)
        t.ok("the world: a loose pair among loose tabs, folders below, a live folder, a pin",
             w["paired"] and w["folder"] == "" and w["pins"] == ["Pin"] and "News" in w["folders"], describe(w))
        picture("world", whole_window=True)

        carry("loose-down", [("between Loose B and Loose C", lambda g: gap(g, "Loose B", "Loose C"))],
              loose_between("Loose B", "Loose C"), wanted="loose before Loose C")
        carry("loose-up", [("above Loose A", lambda g: row_point(g, "Loose A", 0.2))],
              loose_between(None, "Loose A"), wanted="loose before Loose A")
        carry("heading-open", [("over the Work heading", lambda g: head_point(g, "Work"))],
              in_folder("Work"), wanted="into Work+outline")
        carry("front-focused-half", [("over the Work heading", lambda g: head_point(g, "Work"))],
              in_folder("Work"), wanted="into Work+outline", front="Left", active="Left")
        carry("front-other-half", [("over the Work heading", lambda g: head_point(g, "Work"))],
              in_folder("Work"), half=1, wanted="into Work+outline", front="Left", active="Right")
        carry("heading-folded", [("over the folded Shut heading", lambda g: head_point(g, "Shut"))],
              in_folder("Shut"), hold=1.4, wanted="into Shut")
        carry("between-folder-rows", [("between Work 1 and Work 2", lambda g: gap(g, "Work 1", "Work 2"))],
              in_folder("Work", after="Work 1", before="Work 2"), wanted="into Work+line")
        carry("nested-heading", [("over the Inner heading, inside Outer", lambda g: head_point(g, "Inner"))],
              in_folder("Inner"), wanted="into Inner+outline")
        carry("hold-on-tab", [("held on Loose C's row", lambda g: row_point(g, "Loose C"))],
              lambda b, w: (w["paired"] and w["folder"] not in ("", None) and set(w["folders"].get(w["folder"], [])) >= {"Loose C", "Left"},
                            "a new folder of Loose C and the pair, still a pair"), hold=1.6)
        carry("live-folder", [("over the News heading", lambda g: head_point(g, "News"))], stays(), wanted="nothing")
        carry("onto-pins", [("over the pins", lambda g: (60, min(r["frame"][1] for r in g["rows"]) - 60))], stays())
        carry("sideways-loose", [("40 points right, on its own row", lambda g: (chip_point(g)[0] + 40, chip_point(g)[1]))],
              lambda b, w: (w["paired"] and w["folder"] not in ("", None), f"a level in, as a tab goes: into {w['folder']}, still a pair"), hold=0)

        carry("into-work-to-stay", [("between Work 1 and Work 2", lambda g: gap(g, "Work 1", "Work 2"))],
              in_folder("Work", after="Work 1"), undo=False)
        carry("folder-reorder", [("above Work 1", lambda g: row_point(g, "Work 1", 0.2))],
              in_folder("Work", before="Work 1"), wanted="into Work before Work 1+line")
        carry("folder-out", [("between Loose B and Loose C", lambda g: gap(g, "Loose B", "Loose C"))],
              loose_between("Loose B", "Loose C"), wanted="loose before Loose C")
        carry("folder-to-folder", [("over the Outer heading", lambda g: head_point(g, "Outer"))],
              in_folder("Outer"), wanted="into Outer+outline")
        carry("sideways-out", [("40 points left, on its own row", lambda g: (chip_point(g)[0] - 40, chip_point(g)[1]))], hold=0, expect=
              (lambda b, w: (w["paired"] and w["folder"] == "", "a level out: loose, still a pair")))
        carry("folder-live", [("over the News heading", lambda g: head_point(g, "News"))], stays(), wanted="nothing")

        carry("back-out", [("between Loose B and Loose C", lambda g: gap(g, "Loose B", "Loose C"))],
              loose_between("Loose B", "Loose C"), undo=False)

        def half_paired(label_half, other_page):
            def check(_, w):
                fine = [label_half, other_page] in w["pairs"] or [other_page, label_half] in w["pairs"]
                return fine, f"{label_half} leaves its pair and is beside {other_page}"
            return check
        carry("tab-to-page-edge", [("over the page's right edge", lambda g: (stage()[2] - 40, (stage()[1] + stage()[3]) / 2))],
              half_paired("Loose B", "Loose A"), press=lambda g: row_point(g, "Loose B"), whole_window=True, undo_checked=False)
        if any("Loose B" in pair for pair in where()["pairs"]):
            sv.sp("detach", id=IDS["Loose B"])
            time.sleep(0.6)
        carry("half-to-page-edge", [("over the page's right edge", lambda g: (stage()[2] - 40, (stage()[1] + stage()[3]) / 2))],
              half_paired("Right", "Loose A"), half=1, whole_window=True, undo_checked=False)
        if not paired():
            sv.sp("detach", id=IDS["Right"])
            sv.sp("pair", id=IDS["Right"], **{"with": IDS["Left"]}, side="right")
            time.sleep(0.8)
        carry("half-onto-other-pair", [("over Other Left's half", lambda g: next((c[0] + c[2] / 2, c[1] + c[3] / 2)
                                                                                   for s in g["splits"] if name(s["left"]) == "Other Left"
                                                                                   for c in s["chips"][:1]))],
              lambda b, w: (w["paired"] and w["folder"] not in ("", None) and {"Left", "Other Left"} <= set(w["folders"].get(w["folder"], [])),
                            "held on another pair's row: a new folder of both pairs, each still a pair"), half=1, hold=1.2)

        def windows(): return cmd(do="windows")["windows"]
        count = len(windows())

        def torn(b, w):
            now = windows()
            new = now[-1]["tabs"] if len(now) == count + 1 else []
            fine = any(u.endswith("/Left") for u in new) and any(u.endswith("/Right") for u in new) and "Left" not in w["items"]
            return fine, "a new window with both halves in it"
        carry("out-of-window", [("far out to the left of the window", lambda g: (-260, chip_point(g)[1] + 40))],
              torn, undo=False, whole_window=True)
        TABLE.append({"case": "windows", "windows": [{"n": x["n"], "tabs": x["tabs"]} for x in windows()]})
        (OUT / "table.json").write_text(json.dumps(TABLE, indent=1, ensure_ascii=False))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

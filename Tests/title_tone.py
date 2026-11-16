#!/usr/bin/env python3
"""Every resting tab title in the sidebar draws in one tone.

Build first (`./build.sh`), then `python3 Tests/title_tone.py [LABEL]`.

Shown, dark look, with the fake grouping engine. A session of seven tabs is
restored, two of them on one subject, and the grouper puts those two in a
folder. The column is then read after each step that has led rows to draw
their titles in two tones: the folder made by subject, the pointer passing
over a row and leaving, a tab chosen and left, a folder made by hand, a fold
and reopen, tabs opened and left, and a relaunch with the folders restored.
Lifted ink is in RowTitleToneTests, as a probe world gives none. For every
row Bench "rowtitles" gives the colour the title is drawn in and the colour
its tone means, and a picture of the probe window gives the brightest pixel
of each title. A resting title must draw what its
tone means, and every resting title must draw alike.
Out: .context/after/title-tone/LABEL/*.png.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402

OUT = ROOT / ".context" / "after" / "title-tone" / LABEL
WIDTH, HEIGHT, COLUMN = 1000, 620, 270
TITLES = {
    "hill": "Hillside walk", "hall": "Lantern hall", "kettle": "Kettle lid",
    "flights": "Lisbon flights", "hotels": "Lisbon hotels",
    "willow": "Willow hill", "halley": "Halley wall",
    "tall": "Tall tile kiln", "bell": "Bell tower",
}
ORDER = ["hill", "hall", "kettle", "flights", "hotels", "willow", "halley"]
LIVE = "willow"


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        name = self.path.strip("/").split("/")[0]
        body = (f"<!doctype html><meta charset=utf-8><title>{TITLES.get(name, name)}</title>"
                f"<body style='background:#2b2d31'>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("title-tone-" + uuid.uuid4().hex[:6])
t = sv.T()
TOOLS = Path(tempfile.mkdtemp(prefix="title-tone-tools-"))
SHOT = TOOLS / "shot"
BRIGHT = TOOLS / "bright"

BRIGHT_SOURCE = r"""
import AppKit
let a = CommandLine.arguments
let rep = NSBitmapImageRep(data: FileManager.default.contents(atPath: a[1])!)!
let k = Double(a[2])!
var p = [Int](repeating: 0, count: 4)
var out: [String] = []
var i = 3
while i + 3 < a.count {
    let x = Int(Double(a[i])! * k), y = Int(Double(a[i + 1])! * k)
    let w = Int(Double(a[i + 2])! * k), h = Int(Double(a[i + 3])! * k)
    var best = 0.0
    for yy in max(0, y)..<min(rep.pixelsHigh, y + h) {
        for xx in max(0, x)..<min(rep.pixelsWide, x + w) {
            rep.getPixel(&p, atX: xx, y: yy)
            best = max(best, 0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2]))
        }
    }
    out.append(String(format: "%.1f", best))
    i += 4
}
print("[" + out.joined(separator: ",") + "]")
"""


def cmd(**r): return sv.cmd(r)
def ai(*args): return sv.cmd({"do": "aigroups", "args": list(args)})


def tools():
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", TOOLS / "WindowShot.swift")
    subprocess.run(["swiftc", "-parse-as-library", "WindowShot.swift", "-o", str(SHOT)], cwd=str(TOOLS), check=True)
    (TOOLS / "bright.swift").write_text(BRIGHT_SOURCE)
    subprocess.run(["swiftc", "-O", "bright.swift", "-o", str(BRIGHT)], cwd=str(TOOLS), check=True)


def wait_for(test, within=10):
    until = time.time() + within
    while time.time() < until:
        value = test()
        if value:
            return value
        time.sleep(0.2)
    return test()


def open_shown():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
    cmd(do="ui", look="dark")
    cmd(do="ui", windowPointer=[900, 560], pointerPhase="move")
    ai("fake", "0.4", "1.0")
    time.sleep(1.0)


def picture(name):
    number = cmd(do="idle", action="unhide")["number"]
    time.sleep(0.8)
    pid = next(iter(sv.holding() & sv.running()))
    drawn = TOOLS / f"{name}.png"
    for _ in range(4):
        subprocess.run([str(SHOT), str(pid), str(number), str(drawn)], cwd=str(TOOLS), capture_output=True, text=True)
        if drawn.exists():
            break
        time.sleep(0.8)
    if not drawn.exists():
        return None, 1
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(drawn)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(width / WIDTH))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(drawn), "-vf",
                    f"crop={COLUMN * k}:{HEIGHT * k}:0:0", str(OUT / f"{name}.png")], check=True)
    return drawn, k


def same(a, b, within=0.004):
    return all(abs(x - y) <= within for x, y in zip(a, b))


def show(rgba):
    return "rgba(" + ", ".join(f"{v:.3f}" for v in rgba) + ")"


def read(name):
    time.sleep(0.8)
    rows = cmd(do="rowtitles")["rows"]
    folders = {id: g["name"] for g in cmd(do="group")["groups"] for id in g["tabs"]}
    drawn, k = picture(name)
    lights = []
    if drawn is not None and rows:
        rects = []
        for r in rows:
            x, y, w, h = r["frame"]
            rects += [x, y, max(1, w - 30), h]
        lights = json.loads(subprocess.run([str(BRIGHT), str(drawn), str(k)] + [str(v) for v in rects],
                                           capture_output=True, text=True).stdout)
    print(f"  {name}:")
    for i, r in enumerate(rows):
        where = f"in {folders[r['id']]}" if r["id"] in folders else "loose"
        state = "current" if r["live"] else "hover" if r["hover"] else "rest"
        light = lights[i] if i < len(lights) else "-"
        print(f"    {r['label']:<16} {where:<18} {state:<8} drawn {show(r['rgba'])}  meant {show(r['meant'])}"
              f"  shown {r['shown']:.2f}  brightest {light}  lift {r['lift']:.2f}")
    resting = [(r, lights[i] if i < len(lights) else None) for i, r in enumerate(rows) if not r["live"] and not r["hover"]]
    t.ok(f"{name}: the column holds rows", len(rows) >= 5, rows)
    wrong = [r["label"] for r in rows if not same(r["rgba"], r["meant"])]
    t.ok(f"{name}: every title draws the colour its tone means", not wrong, wrong)
    first = resting[0][0]["rgba"] if resting else None
    odd = [r["label"] for r, _ in resting if not same(r["rgba"], first)]
    t.ok(f"{name}: every resting title draws alike", not odd, odd)
    dimmed = [r["label"] for r, _ in resting if r["shown"] < 0.99]
    t.ok(f"{name}: no resting title sits under a dimmed layer", not dimmed, dimmed)
    seen = [v for _, v in resting if v is not None]
    if seen:
        t.ok(f"{name}: the brightest pixel of every resting title is within 6 of the others", max(seen) - min(seen) <= 6,
             seen)
    return {r["label"]: r for r in rows}


def tab_ids():
    return {x["title"]: x["id"] for x in sv.sp("state")["tabs"] if x.get("url")}


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    tools()
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "ai": True, "ai.groups": True, "tabs.cards": True,
                                           "layout.cards": True, "start.fresh": False, "split": False,
                                           "welcome.show": False, "tabs.newAtBottom": True})
    os.makedirs(sv.SUPPORT, exist_ok=True)
    tabs = [{"url": f"{BASE}/{name}", "title": TITLES[name]} for name in ORDER]
    json.dump({"tabs": tabs, "active": ORDER.index(LIVE)}, open(f"{sv.SUPPORT}/session.json", "w"))
    try:
        open_shown()
        read("restored")

        ai("regroup")
        folder = wait_for(lambda: next((g for g in ai("state")["groups"] if g["ai"] and len(g["tabs"]) == 2), None), 12)
        t.ok("the two Lisbon tabs share a folder made by subject", folder is not None, ai("state"))
        time.sleep(1.2)
        read("subject-folder")

        ids = tab_ids()
        cmd(do="rowhover", id=ids["Hillside walk"][:8].lower(), on=True)
        time.sleep(0.4)
        cmd(do="rowhover", id=ids["Hillside walk"][:8].lower(), on=False)
        cmd(do="rowhover", id=ids["Lisbon hotels"][:8].lower(), on=True)
        time.sleep(0.4)
        cmd(do="rowhover", id=ids["Lisbon hotels"][:8].lower(), on=False)
        read("hovered-and-left")

        sv.sp("select", id=ids["Lantern hall"])
        time.sleep(0.8)
        sv.sp("select", id=ids["Willow hill"])
        read("chosen-and-left")

        cmd(do="group", id=ids["Kettle lid"][:8].lower(), new=True, name="Workshop")
        cmd(do="group", id=ids["Halley wall"][:8].lower(), name="Workshop")
        time.sleep(1.0)
        read("hand-folder")

        cmd(do="group", name="Workshop", fold=True)
        time.sleep(0.8)
        cmd(do="group", name="Workshop", fold=True)
        time.sleep(0.8)
        read("folded-and-reopened")

        lisbon = next(g["name"] for g in cmd(do="group")["groups"] if ids["Lisbon hotels"][:8].lower() in g["tabs"])
        cmd(do="group", name=lisbon, fold=True)
        time.sleep(0.8)
        cmd(do="group", name=lisbon, fold=True)
        time.sleep(0.8)
        read("touched-folder-folded-and-reopened")

        sv.sp("open", url=f"{BASE}/tall")
        time.sleep(0.8)
        sv.sp("open", url=f"{BASE}/bell")
        time.sleep(0.8)
        sv.sp("select", id=ids["Willow hill"])
        read("opened-more")

        sv.quit()
        time.sleep(1.0)
        open_shown()
        read("relaunched")
    finally:
        t.done()
        sv.finish()
        shutil.rmtree(TOOLS, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

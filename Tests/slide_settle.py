#!/usr/bin/env python3
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv
import world_out as wo

label = sys.argv[1] if len(sys.argv) > 1 else "now"
sv.use("slide-settle-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "slide-settle" / label
TOOLS = ROOT / ".context" / "slide-settle" / "tools"
CAPTURE = TOOLS / "capture"
BARS = TOOLS / "bars"
MAGENTA, CYAN = "ff00ff", "00ffff"
WIDE = ("<meta name=viewport content='width=device-width'><style>"
        "body{margin:0;background:#141414;color:#ddd;font:16px sans-serif}"
        "@media (max-width:700px){body{background:#3a1010}}"
        f".m{{position:fixed;top:0;bottom:0;left:200px;width:6px;background:#{MAGENTA}}}"
        f".c{{position:fixed;top:0;bottom:0;left:60vw;width:6px;background:#{CYAN}}}"
        "</style><div class=m></div><div class=c></div><p style='margin:80px 40px'>wide</p>")
PAGES = {
    "wide": WIDE,
    "left": "<body style='margin:0;background:#1f3b5c'>",
    "right": "<body style='margin:0;background:#5c1f3b'>",
}
BAR_READER = r'''
import AppKit
let a = CommandLine.arguments
let colours: [[Int]] = a[3].split(separator: ",").map { hex in
    let v = Int(hex, radix: 16)!
    return [(v >> 16) & 255, (v >> 8) & 255, v & 255]
}
let row = Int(a[2])!
var out = [[String: Any]]()
let files = try! FileManager.default.contentsOfDirectory(atPath: a[1]).filter { $0.hasSuffix(".png") }.sorted()
for file in files {
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1] + "/" + file)))!
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
    var bars = [Int?]()
    for c in colours {
        var found: Int? = nil
        for x in 0..<w {
            let j = (min(row, h - 1) * w + x) * 4
            let r = Int(px[j]), g = Int(px[j + 1]), b = Int(px[j + 2])
            let hit = c[1] == 0 ? r > 180 && g < 110 && b > 180 : r < 160 && g > 200 && b > 200
            if hit { found = x; break }
        }
        bars.append(found)
    }
    out.append(["file": file, "bars": bars.map { $0 as Any? ?? NSNull() }])
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
'''


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0]
        body = f"<!doctype html><title>{name}</title>{PAGES.get(name, '')}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
server.daemon_threads = True
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    if not CAPTURE.exists() or CAPTURE.stat().st_mtime < (ROOT / "Tests/WindowCapture.swift").stat().st_mtime:
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    source = BARS.with_suffix(".swift")
    if not BARS.exists() or source.read_text() != BAR_READER:
        source.write_text(BAR_READER)
        subprocess.run(["swiftc", "-O", str(source), "-o", str(BARS)], check=True)


def start():
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    return next(iter(sv.holding() & sv.running()))


def number(window=1):
    return sv.cmd({"do": "idle", "action": "unhide", "window": window})["number"]


def space(name):
    before = set(sv.sp("state")["spaceIDs"])
    sv.sp("space", spaceAction="new", name=name)
    time.sleep(1)
    made = next(id for id in sv.sp("state")["spaceIDs"] if id not in before)
    sv.sp("space", spaceAction="go", spaceID=made)
    return made


def index(id):
    return sv.sp("state")["spaceIDs"].index(id)


def geometry(name, to, t):
    folder = OUT / "rides"
    folder.mkdir(parents=True, exist_ok=True)
    shots = sv.cmd({"do": "film", "action": "space", "index": index(to), "path": str(wo.spot(sv, name)),
                    "frames": 50, "every": 0.016, "region": "0,0,8,8"})["frames"]
    (folder / f"{name}.json").write_text(json.dumps(shots, indent=1))
    late = []
    for shot in shots:
        riders = shot.get("riders", [])
        column = [r for r in riders if r["reach"] <= 1.001]
        stage = [r for r in riders if r["reach"] > 1.001]
        if not column or not stage:
            continue
        off_column = max(abs(r["x"] - r["aim"]) for r in column)
        off_stage = max(abs(r["x"] - r["aim"]) for r in stage)
        if off_column <= 1 and off_stage > 1.5:
            late.append((shot["t"], round(off_column, 2), round(off_stage, 2)))
    tails = [(s["t"], [round(abs(r["x"] - r["aim"]), 1) for r in s.get("riders", [])]) for s in shots if s.get("riders")]
    print(f"  {name}: column and page, distance from rest per frame: {tails[:30]}", flush=True)
    t.ok(f"{name}: the page is home when the column is", not late, f"{late[:4]}")
    wrong = []
    for shot in shots:
        for p in shot.get("pictures", []):
            box, image = p["box"], p["image"]
            if abs((box[2] - box[0]) - image[0]) > 1 or abs((box[3] - box[1]) - image[1]) > 1:
                wrong.append((shot["t"], [round(v, 1) for v in box], [round(v, 1) for v in image]))
    pictured = sum(1 for s in shots if s.get("pictures"))
    print(f"  {name}: {pictured} frames with a riding picture, {len(wrong)} at a size other than their frame", flush=True)
    t.ok(f"{name}: riding pictures are the size of the page they stand for", not wrong, f"{wrong[:3]}")
    if name.endswith("to-wide"):
        t.ok(f"{name}: the wide page rides in as a picture", pictured > 3, f"{pictured} frames")


def film(pid, name, act, t, seconds=1.4):
    folder = OUT / "frames" / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number()), "2"], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    if p.poll() is not None:
        print(f"  film {name}: skipped, the screen can't be captured now", flush=True)
        act()
        return
    time.sleep(0.2)
    act()
    print(f"  film {name}: {p.communicate()[0].strip()}", flush=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/4)*2:trunc(ih/4)*2", str(OUT / f"film-{name}.mp4")], check=False)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", "select='not(mod(n\\,2))',scale=420:-1,tile=6x6:padding=4:color=gray", "-frames:v", "1",
                    str(OUT / f"film-{name}-sheet.png")], check=False)
    shots = sorted(folder.glob("0*.png"))
    if not shots:
        print(f"  film {name}: no frames", flush=True)
        return
    high = int(subprocess.run(["sips", "-g", "pixelHeight", str(shots[0])], capture_output=True, text=True).stdout.split()[-1])
    read = json.loads(subprocess.run([str(BARS), str(folder), str(int(high * 0.7)), f"{MAGENTA},{CYAN}"],
                                     capture_output=True, text=True).stdout)
    (OUT / f"film-{name}.json").write_text(json.dumps(read))
    places = [f["bars"] for f in read]
    print(f"  film {name}: bars per frame {places}", flush=True)
    last = places[-1]
    if last[0] is None:
        t.ok(f"film {name}: the wide page is on screen at the end", False, str(last))
        return
    moved_after = []
    for bar in range(2):
        home = [i for i, p in enumerate(places) if p[bar] == last[bar]]
        reached = next(i for i in range(len(places)) if all(p[bar] == last[bar] for p in places[i:]))
        before = [i for i in home if i < reached]
        if before:
            moved_after.append((["magenta", "cyan"][bar], "home at", before[0], "then left it, settled at", reached))
    t.ok(f"film {name}: once a bar reaches its place it stays there", not moved_after, f"{moved_after}")


def arrivals(pid, t, wide, split, case, away):
    for to, back, name in ((wide, split, "to-wide"), (split, wide, "to-split")):
        sv.sp("space", spaceAction="go", spaceID=back)
        time.sleep(1.2)
        away()
        time.sleep(1.2)
        parked = sv.cmd({"do": "parked"})["pages"]
        print(f"  {case}-{name}: parked pages {parked}", flush=True)
        for page in parked:
            if page["picture"]:
                t.ok(f"{case}-{name}: a parked page's picture is taken at its size", page["picture"] == page["size"], str(page))
        geometry(f"{case}-{name}", to, t)
        time.sleep(1.0)
    for to, back, name in ((wide, split, "to-wide"),):
        sv.sp("space", spaceAction="go", spaceID=back)
        time.sleep(1.2)
        away()
        time.sleep(1.2)
        film(pid, f"{case}-{name}", lambda to=to: sv.cmd({"do": "space", "action": "goto", "index": index(to) + 1}), t)
        time.sleep(0.8)


def main():
    tools()
    OUT.mkdir(parents=True, exist_ok=True)
    t = sv.T()
    sv.setup(sidebar=True, splitView=True)
    pid = start()
    try:
        sv.cmd({"do": "ui", "look": "dark"})
        sv.cmd({"do": "resize", "width": 1280, "height": 800, "steps": 1})
        sv.cmd({"do": "ui", "sideWidth": 262.0})
        sv.cmd({"do": "ui", "spaces": True})
        time.sleep(0.5)
        wide = space("wide")
        time.sleep(1)
        sv.sp("open", url=f"{BASE}/wide")
        time.sleep(1.5)
        split = space("split")
        time.sleep(1)
        left = sv.sp("open", url=f"{BASE}/left")["resultID"]
        right = sv.sp("open", url=f"{BASE}/right")["resultID"]
        time.sleep(1)
        sv.sp("pair", id=right, **{"with": left}, side="right")
        time.sleep(1.5)
        sv.sp("space", spaceAction="go", spaceID=wide)
        time.sleep(1.5)
        widths = iter([320.0, 262.0, 300.0, 240.0])
        sizes = iter([(1180, 760), (1320, 820), (1200, 780), (1280, 800)])
        arrivals(pid, t, wide, split, "rest", lambda: None)
        arrivals(pid, t, wide, split, "sidebar", lambda: sv.cmd({"do": "ui", "sideWidth": next(widths)}))

        def resize():
            w, h = next(sizes)
            sv.cmd({"do": "resize", "width": w, "height": h, "steps": 4})
        arrivals(pid, t, wide, split, "resize", resize)
    finally:
        sv.quit()
        sv.wipe()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

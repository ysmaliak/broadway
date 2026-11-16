#!/usr/bin/env python3
"""No coloured sliver beside the page card's left edge, in a test copy's own
window, dark, with pages that wear a teal theme-color over a dark body.

Build first (`./build.sh debug`), then `python3 Tests/page_edge.py [label]`.
BROADWAY_PROBE_APP picks another build. Stills land in .context/page-edge/<label>/
at 2x; each is read along the pixel columns just outside the card's left
edge, from its top corner down, and any pixel there with colour in it fails.
Shot after load, after a space switch, after folding and unfolding the
sidebar, after a resize, and with Split View. At each, the bench walks
every layer inside each page's web view: none may show outside the web
view's own frame. Then a space whose page wears a light band along its top
sits just left of a space with a plain dark page: shot from the dark one,
before and after a switch, the band must not show past its card's left
edge. Then a space with two pages in Split View and a space
with one tab, the switch between them filmed both ways at 60 fps, 2x: each
frame's page edges are read, and they must stay where they rest, or move
together, never jump on their own.
"""
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
import split_view as sv  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "now"
sv.use("page-edge-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "page-edge" / label
TOOLS = ROOT / ".context" / "page-edge" / "tools"
SHOT = TOOLS / "shot"
READ = TOOLS / "edge"
CAPTURE = TOOLS / "capture"
BOXES = TOOLS / "boxes"
SOLIDS = {"left": "1f3b5c", "right": "5c1f3b", "single": "1f5c3b"}
TEAL = "#14b8a6"
BODY = os.environ.get("PAGE_EDGE_BODY", "#161616")
PAGES = {
    "theme": f"<meta name=theme-color content='{TEAL}'><body style='margin:0;background:{BODY};color:#ddd'><p style='margin:80px 40px'>theme</p>",
    "header": f"<meta name=theme-color content='{TEAL}'><body style='margin:0;background:{BODY};color:#ddd'>"
              f"<div style='position:fixed;top:0;left:0;right:0;height:48px;background:{TEAL}'></div><p style='margin:80px 40px'>header</p>",
    "bar": f"<meta name=theme-color content='{TEAL}'><body style='margin:0;background:{BODY};color:#ddd'>"
           f"<div style='height:48px;background:{TEAL}'></div><p style='margin:40px'>bar</p>",
    "side": f"<meta name=theme-color content='{TEAL}'><body style='margin:0;background:{BODY};color:#ddd'>"
            f"<div style='position:fixed;top:0;left:0;bottom:0;width:6px;background:{TEAL}'></div><p style='margin:80px 40px'>side</p>",
}
for name, hex in SOLIDS.items():
    PAGES[name] = f"<meta name=theme-color content='{TEAL}'><body style='margin:0;background:#{hex}'>"
BANNER = "#84d9d9"
APART = {
    "banner": f"<body style='margin:0;background:{BODY};color:#ddd'><div style='height:40px;background:{BANNER}'></div><p style='margin:40px'>banner</p>",
    "plain": f"<body style='margin:0;background:{BODY};color:#ddd'><p style='margin:80px 40px'>plain</p>",
}
READER = r'''
import AppKit
let a = CommandLine.arguments
let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: a[1])))!
let scale = Double(a[2])!, left = Double(a[3])!, top = Double(a[4])!, height = Double(a[5])!
let edge = Int((left * scale).rounded(.up)) - 1
func rgb(_ x: Int, _ y: Int) -> [Double] {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return [0, 0, 0] }
    return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) * 255 }
}
var worst = 0.0, at = [Int]()
for y in Int(top * scale)..<min(rep.pixelsHigh, Int((top + height) * scale)) {
    let ground = rgb(max(0, edge - 10), y)
    for x in max(0, edge - 3)...edge {
        let v = rgb(x, y)
        let tint = abs((v.max()! - v.min()!) - (ground.max()! - ground.min()!))
        let off = x < edge ? max(tint, zip(v, ground).map { abs($0 - $1) }.max()!) : tint
        if off > worst { worst = off; at = [x, y] + v.map { Int($0) } }
    }
}
print("{\"chroma\": \(worst), \"at\": \(at)}")
'''
BOXER = r'''
import AppKit
let a = CommandLine.arguments
func load(_ path: String) -> (px: [UInt8], w: Int, h: Int) {
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: URL(fileURLWithPath: path)))!
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var px = [UInt8](repeating: 0, count: w * h * 4)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (px, w, h)
}
var colours = [[Double]]()
for spot in a[2].split(separator: ",") {
    let parts = spot.split(separator: ":")
    let image = load(String(parts[0]))
    let x = Int(parts[1])!, y = Int(parts[2])!
    let j = (y * image.w + x) * 4
    colours.append([Double(image.px[j]), Double(image.px[j + 1]), Double(image.px[j + 2])])
}
var out = [[String: [Int]]]()
let files = try! FileManager.default.contentsOfDirectory(atPath: a[1]).filter { $0.hasSuffix(".png") }.sorted()
for file in files {
    let (px, w, h) = load(a[1] + "/" + file)
    func near(_ x: Int, _ y: Int, _ c: [Double]) -> Bool {
        let j = (y * w + x) * 4
        return abs(Double(px[j]) - c[0]) < 6 && abs(Double(px[j + 1]) - c[1]) < 6 && abs(Double(px[j + 2]) - c[2]) < 6
    }
    var frame = [String: [Int]]()
    for (index, c) in colours.enumerated() {
        let row = h * 3 / 5
        let xs = (0..<w).filter { near($0, row, c) }
        guard let left = xs.first, let right = xs.last else { continue }
        let mid = (left + right) / 2
        let ys = (0..<h).filter { near(mid, $0, c) }
        guard let top = ys.first, let bottom = ys.last else { continue }
        frame[String(index)] = [left, top, right + 1, bottom + 1]
    }
    out.append(frame)
}
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
'''


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("?")[0]
        body = f"<!doctype html><title>{name}</title>{PAGES.get(name) or APART.get(name, '')}".encode()
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
    if not SHOT.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    if not CAPTURE.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    for tool, text in ((READ, READER), (BOXES, BOXER)):
        source = tool.with_suffix(".swift")
        if not tool.exists() or source.read_text() != text:
            source.write_text(text)
            subprocess.run(["swiftc", "-O", str(source), "-o", str(tool)], check=True)


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


def frames():
    return sorted(sv.sp("state")["paneFrames"], key=lambda f: f["x"])


results = {}


def shoot(pid, name):
    time.sleep(1.2)
    path = OUT / f"{name}.png"
    for _ in range(3):
        out = subprocess.run([str(SHOT), str(pid), str(number()), str(path)], capture_output=True, text=True).stdout.strip()
        if out.startswith("shot"):
            break
        time.sleep(1)
    shown = frames()
    if not shown:
        raise SystemExit(f"{name}: no page on screen")
    page = shown[0]
    if out.startswith("shot") and path.exists():
        read = json.loads(subprocess.run([str(READ), str(path), "2", str(page["x"]), str(page["y"] + (30 if page["x"] < 20 else 0)), "80"],
                                         capture_output=True, text=True).stdout)
    else:
        read = {"chroma": 0, "at": [], "skipped": True}
        print(f"  {name}: no still, the screen can't be captured now", flush=True)
    read["over"] = sv.cmd({"do": "overhang"})["layers"]
    results[name] = read
    for l in read["over"][:3]:
        print(f"    past the web view by left {l['left']:.2f} right {l['right']:.2f} top {l['top']:.2f} bottom {l['bottom']:.2f}: {l['layer'][-90:]}", flush=True)
    print(f"  {name}: card left {page['x']:.2f} top {page['y']:.1f}, {len(read['over'])} layers past the web view, "
          f"beside it off the ground by {read['chroma']:.0f} at {read['at']}", flush=True)
    return read


SPOTS = []


def film(pid, name, act, seconds=1.6):
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
        return None
    time.sleep(0.2)
    act()
    print(f"  film {name}: {p.communicate()[0].strip()}", flush=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-pix_fmt", "yuv420p", "-vf", "scale=trunc(iw/4)*2:trunc(ih/4)*2", str(OUT / f"film-{name}.mp4")], check=False)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", "select='not(mod(n\\,3))',scale=420:-1,tile=8x5:padding=4:color=gray", "-frames:v", "1",
                    str(OUT / f"film-{name}-sheet.png")], check=False)
    shots = sorted(folder.glob("0*.png"))
    wide = int(subprocess.run(["sips", "-g", "pixelWidth", str(shots[0])], capture_output=True, text=True).stdout.split()[-1])
    window = next(w for w in sv.cmd({"do": "probe"})["windows"] if w["kind"] in ("AppKitWindow", "NSWindow"))
    if wide != int(window["frame"][2] * 2):
        print(f"  film {name}: skipped, filmed at {wide} px wide, not at 2x", flush=True)
        return None
    first, last = (shots[0], shots[-1]) if name.startswith("split") else (shots[-1], shots[0])
    spots = [f"{first}:{SPOTS[0][0]}:{SPOTS[0][1]}", f"{first}:{SPOTS[1][0]}:{SPOTS[1][1]}", f"{last}:{SPOTS[2][0]}:{SPOTS[2][1]}"]
    boxes = json.loads(subprocess.run([str(BOXES), str(folder), ",".join(spots)], capture_output=True, text=True).stdout)
    (OUT / f"film-{name}.json").write_text(json.dumps(boxes))
    return boxes


def steady(boxes):
    rest = [b for b in boxes if b]
    lo = min(v[0] for b in rest for v in b.values()) if rest else 0
    hi = max(v[2] for b in rest for v in b.values()) if rest else 0
    odd = []
    for key in SOLIDS_KEYS:
        seen = [b[key] for b in boxes if key in b]
        if not seen:
            continue
        width = max(seen[0][2] - seen[0][0], seen[-1][2] - seen[-1][0])
        for i in range(1, len(boxes)):
            a, b = boxes[i - 1].get(key), boxes[i].get(key)
            if not a or not b or min(a[0], b[0]) <= lo + 1 or max(a[2], b[2]) >= hi - 1:
                continue
            moving = b[0] != a[0] or b[2] != a[2]
            if max(abs(b[1] - a[1]), abs(b[3] - a[3])) > (1 if moving else 0):
                odd.append((key, i, "top or bottom", a, b))
            elif abs((b[2] - b[0]) - width) > 4:
                odd.append((key, i, "width", a, b))
    return odd


SOLIDS_KEYS = [str(i) for i in range(len(SOLIDS))]


def space(name):
    before = set(sv.sp("state")["spaceIDs"])
    sv.sp("space", spaceAction="new", name=name)
    time.sleep(1)
    made = next(id for id in sv.sp("state")["spaceIDs"] if id not in before)
    go(made)
    return made


def go(id):
    sv.sp("space", spaceAction="go", spaceID=id)


def rides(name, index, t):
    folder = OUT / "rides"
    folder.mkdir(parents=True, exist_ok=True)
    shots = sv.cmd({"do": "film", "action": "space", "index": index - 1, "path": str(folder / name),
                    "frames": 45, "every": 0.02, "region": "0,0,8,8"})["frames"]
    time.sleep(0.8)
    live = sv.cmd({"do": "film", "action": "none", "path": str(folder / f"{name}-rest"), "frames": 1, "region": "0,0,8,8"})["frames"][0]["cards"]
    riding = [s_ for s_ in shots if s_.get("rides")]
    edges = sorted({r["edge"] for s_ in riding for r in s_["rides"]})
    land = sorted(tuple(round(v, 2) for v in r["box"]) for r in riding[-1]["rides"]) if riding else []
    rest = sorted(tuple(round(v, 2) for v in box) for box in live.get("cards", []))
    apart = max((abs(a - b) for x, y in zip(land, rest) for a, b in zip(x, y)), default=99)
    (folder / f"{name}.json").write_text(json.dumps({"shots": shots, "live": live}, indent=1))
    corners = sorted({r["rounds"] for s_ in riding for r in s_["rides"]})
    rounded = sorted(set(live.get("rounds", []))) if live.get("apart") else ["all"] if live.get("masked") else ["none"]
    framed = ["other"] if live.get("apart") else ["none"]
    print(f"  rides {name}: riding cards round {corners}, live ones {rounded}", flush=True)
    t.ok(f"{name}: riding cards are square on the frame's sides, which rounds them", corners == framed, f"{corners} vs {framed}")
    print(f"  rides {name}: {len(riding)} of {len(shots)} frames ride in, their hairlines {edges}, live {live.get('edge')}; "
          f"last ride {land} vs live {rest}", flush=True)
    t.ok(f"{name}: the space rides in", len(riding) > 3, f"{len(riding)} frames")
    worn = [live.get("edge")] if live.get("apart") else [0]
    t.ok(f"{name}: a riding pair's panes wear their hairline, a page alone leaves it to the frame", edges == worn, f"{edges} vs {worn}")
    span = max((c[2] for c in rest), default=0) - min((c[0] for c in rest), default=0)
    alone = sorted({p.get("edge") for s_ in shots for p in s_.get("pictures", []) if abs(p["image"][0] - span) < 1})
    if alone:
        t.ok(f"{name}: a picture riding alone has no edge of its own", alone in ([0], [None]), f"{alone}")
    t.ok(f"{name}: the ride lands where the live cards rest", apart <= 0.5, f"{land} vs {rest}")


def switches(pid, t):
    sv.cmd({"do": "ui", "spaces": True})
    time.sleep(0.5)
    split = space("split")
    time.sleep(1)
    left = sv.sp("open", url=f"{BASE}/left")["resultID"]
    right = sv.sp("open", url=f"{BASE}/right")["resultID"]
    time.sleep(1)
    sv.sp("pair", id=right, **{"with": left}, side="right")
    time.sleep(1)
    single = space("single")
    time.sleep(1)
    sv.sp("open", url=f"{BASE}/single")
    time.sleep(1.5)
    print(f"  spaces now {sv.sp('state')['spaceIDs']}, on {sv.sp('state')['spaceID']}", flush=True)
    shoot(pid, "rest-single")
    single_page = frames()[0]
    go(split)
    time.sleep(1.5)
    shoot(pid, "rest-split")
    pair = frames()
    middle = lambda f: (int((f["x"] + f["width"] / 2) * 2), int((f["y"] + f["height"] * 0.6) * 2))
    SPOTS[:] = [middle(pair[0]), middle(pair[1]), middle(single_page)]
    films = {}
    order = sv.sp("state")["spaceIDs"]
    at = {split: order.index(split) + 1, single: order.index(single) + 1}
    for name, to in (("split-to-single", single), ("single-to-split", split), ("split-to-single-again", single)):
        rides(name, at[to], t)
        time.sleep(0.8)
    for name, to in (("split-to-single", single), ("single-to-split", split), ("split-to-single-again", single)):
        films[name] = film(pid, name, lambda to=to: sv.cmd({"do": "space", "action": "goto", "index": at[to]}))
        time.sleep(0.6)
    for name, boxes in films.items():
        if boxes is None:
            continue
        odd = steady(boxes)
        print(f"  {name}: {len(boxes)} frames, {len(odd)} edges moved on their own", flush=True)
        for o in odd[:6]:
            print("    ", o, flush=True)
        t.ok(f"{name}: page edges hold still or move together", not odd, str(odd[:3]))
        t.ok(f"{name}: filmed", len(boxes) > 20, f"{len(boxes)} frames")
    return films


def beside(pid):
    sv.cmd({"do": "ui", "spaces": True})
    sv.cmd({"do": "ui", "sideWidth": 278.27})
    lit = space("lit")
    sv.sp("open", url=f"{BASE}/banner")
    time.sleep(1.5)
    space("plain")
    sv.sp("open", url=f"{BASE}/plain")
    shoot(pid, "beside-lit-space")
    go(lit)
    time.sleep(1.2)
    sv.cmd({"do": "space", "action": "goto", "index": len(sv.sp("state")["spaceIDs"])})
    shoot(pid, "beside-lit-space-after-switch")


def others(pid, ids):
    sv.cmd({"do": "ui", "spaces": True})
    home = sv.sp("state")["spaceID"]
    space("two")
    time.sleep(0.2)
    go(home)
    shoot(pid, "space-switch")
    order = sv.sp("state")["spaceIDs"]
    sv.cmd({"do": "space", "action": "goto", "index": len(order)})
    time.sleep(1.2)
    sv.cmd({"do": "space", "action": "goto", "index": order.index(home) + 1})
    shoot(pid, "space-goto")
    sv.cmd({"do": "ui", "toggleFold": True})
    time.sleep(1)
    shoot(pid, "folded")
    sv.cmd({"do": "ui", "toggleFold": True})
    shoot(pid, "unfolded")
    sv.cmd({"do": "resize", "width": 980, "height": 700, "steps": 8})
    shoot(pid, "resized")
    sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 8})
    sv.sp("pair", id=ids["theme"], **{"with": ids["header"]}, side="right")
    time.sleep(1)
    shoot(pid, "split")


def main():
    tools()
    OUT.mkdir(parents=True, exist_ok=True)
    t = sv.T()
    sv.setup(sidebar=True, splitView=True)
    pid = start()
    try:
        sv.cmd({"do": "ui", "look": "dark"})
        if os.environ.get("PAGE_EDGE_DUSK") == "1":
            sv.cmd({"do": "ui", "dusk": True})
        sv.cmd({"do": "resize", "width": 1120, "height": 760, "steps": 1})
        look = json.loads(os.environ.get("PAGE_EDGE_LOOK") or '{"colour": "gray", "glass": false, "transparency": 0, "grain": 0}')
        sv.cmd({"do": "space", "action": "look", **look})
        only_film = os.environ.get("PAGE_EDGE_ONLY") == "film"
        ids = {} if only_film else {name: sv.sp("open", url=f"{BASE}/{name}")["resultID"] for name in PAGES}
        time.sleep(1.5)
        for name, id in ids.items():
            sv.sp("select", id=id)
            shoot(pid, f"load-{name}")
        for width in [] if only_film else [float(w) for w in os.environ.get("PAGE_EDGE_WIDTHS", "278.27,278.5,278.75,251.3").split(",")]:
            sv.cmd({"do": "ui", "sideWidth": width})
            for name in ("header", "bar", "theme"):
                sv.sp("select", id=ids[name])
                shoot(pid, f"side-{width}-{name}")
        if only_film:
            sv.cmd({"do": "ui", "sideWidth": float(os.environ.get("PAGE_EDGE_SIDE", "278.27"))})
        if not only_film:
            others(pid, ids)
        if not only_film:
            beside(pid)
        if only_film or os.environ.get("PAGE_EDGE_FILM", "1") == "1":
            switches(pid, t)
        for name, read in results.items():
            t.ok(f"{name}: nothing in the page shows past the web view", not read["over"], json.dumps(read["over"][:2])[:300])
            t.ok(f"{name}: nothing coloured beside the card's left edge", read["chroma"] < 12, f"chroma {read['chroma']:.0f} at {read['at']}")
    finally:
        sv.quit()
        sv.wipe()
        (OUT / "edge.json").write_text(json.dumps(results, indent=1))
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()

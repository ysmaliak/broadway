#!/usr/bin/env python3
"""The calendar pin's meeting badge, inside the tile, pictured window-only.

Build first (`./build.sh`), then `python3 Tests/pin_meeting_badge.py`. Each
sidebar width runs a test copy in a world of its own, its window under the
desktop. The calendar is the bench's fixed one, never the Mac's; the calendar
pin is a local page on localhost that the bench counts as a calendar. For each
look (dark, light), each tile state (resting, live, live with a peek) and each
badge (none: the meeting is 2 hours off; 25m; Join; 48m ago, a meeting with no
link that started 48 minutes ago, the widest the time since the start gets), one
still. Last, a meeting whose call this window already has open shows the time
since the start in place of Join. The capsule is
measured twice: the frame SwiftUI gives it, and in the still, as the pixels
that differ from the same tile with no badge. Stills and contact sheets go to
.context/pin-badge.
"""
import os
import struct
import subprocess
import sys
import threading
import time
import uuid
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

sv.use("pin-badge-" + uuid.uuid4().hex[:6])
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
WORK = ROOT / ".context" / "pin-badge"
SHOT = WORK / "shot"
SCALE = [2]
LINK = "https://meet.google.com/abc-defg-hij"
BADGES = {"none": (120, LINK), "25m": (25, LINK), "join": (0.5, LINK), "48m ago": (-48.5, "")}
ICONS = {"calendar": (0.15, 0.42, 0.95), "red": (0.9, 0.16, 0.14), "teal": (0.08, 0.68, 0.7),
         "grey": (0.52, 0.52, 0.52), "orange": (0.98, 0.55, 0.1)}


def png(colour, side=32):
    rows = b""
    for y in range(side):
        rows += b"\0"
        for x in range(side):
            dx, dy = x - side / 2 + 0.5, y - side / 2 + 0.5
            inside = dx * dx + dy * dy <= (side / 2 - 1) ** 2
            r, g, b = (1, 1, 1) if abs(dx) < 3 and abs(dy) < 8 else colour
            rows += bytes([int(r * 255), int(g * 255), int(b * 255), 255 if inside else 0])

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", side, side, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/").split("/")[-1].removesuffix(".png")
        if self.path.startswith("/icon/") and name in ICONS:
            body, kind = png(ICONS[name]), "image/png"
        else:
            body = (f"<!doctype html><title>{name}</title><link rel=icon href='/icon/{name}.png'><p>{name}").encode()
            kind = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
PORT = server.server_port


def read_png(path):
    data = Path(path).read_bytes()
    pos, idat, width, height, kind = 8, b"", 0, 0, 6
    while pos < len(data):
        size, name = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + size]
        pos += 12 + size
        if name == b"IHDR":
            width, height, _, kind = struct.unpack(">IIBB", body[:10])
        elif name == b"IDAT":
            idat += body
    step = {6: 4, 2: 3}[kind]
    raw, stride = zlib.decompress(idat), width * step
    rows, above, at = [], bytearray(stride), 0
    for _ in range(height):
        kind_of, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            a = line[x - step] if x >= step else 0
            b = above[x]
            c = above[x - step] if x >= step else 0
            if kind_of == 1: line[x] = (line[x] + a) & 255
            elif kind_of == 2: line[x] = (line[x] + b) & 255
            elif kind_of == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif kind_of == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        above = line
    return width, height, step, rows


def pixel(picture, x, y):
    _, _, step, rows = picture
    return rows[y][x * step:x * step + 3]


PAD = 6


def crop(still, tile, out):
    SCALE[0] = struct.unpack(">I", Path(still).read_bytes()[16:20])[0] / 1000
    scale = SCALE[0]
    x, y, w, h = tile
    box = f"crop={round((w + 2 * PAD) * scale)}:{round((h + 2 * PAD) * scale)}:{round((x - PAD) * scale)}:{round((y - PAD) * scale)}"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(still), "-vf", box, str(out)], check=True)
    return out


def measure(base, badged, tile):
    """The capsule in the still: pixels that differ from the same tile with no
    badge, below where the centred mark ends. Points from the tile's own top
    left; also how many differing pixels lie outside the tile."""
    one, two = read_png(base), read_png(badged)
    width, height = min(one[0], two[0]), min(one[1], two[1])
    _, _, w, h = tile
    scale = SCALE[0]
    below = (h / 2 + 8 + 1 + PAD) * scale
    xs, ys, outside = [], [], 0
    for y in range(height):
        for x in range(width):
            a, b = pixel(one, x, y), pixel(two, x, y)
            if max(abs(a[i] - b[i]) for i in range(3)) <= 24:
                continue
            px, py = x / scale - PAD, y / scale - PAD
            if px < 0 or py < 0 or px >= w or py >= h:
                outside += 1
            elif y >= below:
                xs.append(px)
                ys.append(py)
    if not ys:
        return None
    return {"left": min(xs), "right": max(xs) + 1 / scale, "bottom": max(ys) + 1 / scale, "outside": outside}


def shoot(pid, number, path):
    out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    if not path.exists():
        raise RuntimeError(out or "no still")


def fixture(minutes, link=LINK, hosts=None):
    event = {"title": "Design sync", "in": minutes, "minutes": 90}
    if link:
        event["link"] = link
    return sv.cmd({"do": "meetalert", "action": "fixture", "on": False, "calendars": ["localhost"],
                   "hosts": hosts or {}, "events": [event]})


def hstack(cuts, out, points=4):
    inputs = sum([["-i", str(c)] for c in cuts], [])
    zoom = points / SCALE[0]
    graph = "".join(f"[{i}:v]scale=iw*{zoom}:ih*{zoom}:flags=neighbor[c{i}];" for i in range(len(cuts)))
    graph += "".join(f"[c{i}]" for i in range(len(cuts))) + f"hstack=inputs={len(cuts)}"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", graph, str(out)], check=True)
    return out


def vstack(rows, out):
    inputs = sum([["-i", str(r)] for r in rows], [])
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex",
                    f"vstack=inputs={len(rows)}", str(out)], check=True)
    return out


def run(t, side, counts, results):
    sv.setup(spaces=True, **{"start.fresh": False, "meetings.next": True})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", str(side)], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 640, "steps": 1})
        fixture(*BADGES["none"])
        ids = {"calendar": sv.sp("open", url=f"http://localhost:{PORT}/calendar")["resultID"]}
        time.sleep(0.6)
        for name in list(ICONS)[1:max(counts)]:
            ids[name] = sv.sp("open", url=f"http://127.0.0.1:{PORT}/{name}")["resultID"]
            time.sleep(0.6)
        loose = sv.page("loose")
        time.sleep(3)
        for name in ids:
            sv.cmd({"do": "pin", "id": ids[name]})
        time.sleep(1)
        for count in sorted(counts, reverse=True):
            for name in list(ids)[count:]:
                if name != "calendar" and ids.get(name):
                    sv.cmd({"do": "pin", "id": ids[name], "off": True})
                    ids[name] = None
            time.sleep(1)
            for dark in (True, False):
                look = "dark" if dark else "light"
                number = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [1000, 640]})["window"]
                time.sleep(1)
                rows = []
                for state in ("resting", "live", "peek"):
                    sv.sp("select", id=loose if state == "resting" else ids["calendar"])
                    time.sleep(0.8)
                    if state == "peek":
                        sv.cmd({"do": "peek", "url": f"http://127.0.0.1:{PORT}/peeked"})
                        time.sleep(1.5)
                    cuts, base = [], None
                    for badge, (minutes, link) in BADGES.items():
                        state_now = fixture(minutes, link)
                        time.sleep(0.8)
                        state_now = sv.cmd({"do": "meetalert", "action": "state"})
                        tile = state_now["tile"]
                        name = f"{side}-{count}up-{look}-{state}-{badge}"
                        still = WORK / "stills" / f"{name}.png"
                        shoot(pid, number, still)
                        cut = crop(still, tile, WORK / "cuts" / f"{name}.png")
                        cuts.append(cut)
                        label = state_now.get("pinLabel", "")
                        frame = state_now.get("badge") or []
                        entry = {"name": name, "tile": tile, "label": label, "frame": frame}
                        if badge == "none":
                            base = cut
                            t.ok(f"{name}: no badge two hours off", label == "" and not frame, label)
                        else:
                            t.ok(f"{name}: the pin says {badge}", label == badge, label)
                            if frame:
                                x, y, w, h = tile
                                fx, fy, fw, fh = frame
                                entry["swift"] = {"top": fy - y, "bottom": y + h - (fy + fh), "left": fx - x,
                                                  "right": x + w - (fx + fw), "height": fh, "width": fw}
                                t.ok(f"{name}: SwiftUI puts the capsule inside the tile",
                                     fy >= y and fy + fh <= y + h and fx >= x and fx + fw <= x + w, (frame, tile))
                            seen = measure(base, cut, tile)
                            entry["pixels"] = seen
                            ok = seen is not None and seen["bottom"] <= tile[3] - 2
                            t.ok(f"{name}: in the still the capsule ends inside the tile", ok, seen)
                        results.append(entry)
                    if state == "peek":
                        sv.cmd({"do": "peek", "url": "close"})
                        time.sleep(0.8)
                    rows.append(hstack(cuts, WORK / "cuts" / f"row-{side}-{count}up-{look}-{state}.png"))
                vstack(rows, WORK / f"sheet-{side}-{count}up-{look}.png")
        call = f"http://127.0.0.1:{PORT}/call-room"
        hosts = {"127.0.0.1": "meet"}
        fixture(-3, call, hosts)
        time.sleep(0.8)
        before = sv.cmd({"do": "meetalert", "action": "state"})
        t.ok(f"{side}: Join while no tab is on the call", before.get("pinLabel") == "join", before.get("pinLabel"))
        sv.sp("open", url=call)
        time.sleep(1.5)
        after = sv.cmd({"do": "meetalert", "action": "state"})
        wide = [(before.get("badge") or [0, 0, 0])[2], (after.get("badge") or [0, 0, 0])[2]]
        t.ok(f"{side}: the drawn capsule turns from Join (34) to 3m ago (35) once a tab is on the call",
             wide == [34, 35], wide)
        t.ok(f"{side}: the time since the start once a tab is on the call", after.get("pinLabel") == "3m ago",
             after.get("pinLabel"))
        t.ok(f"{side}: VoiceOver reads it in full", after.get("pinSaid") == "Started 3 minutes ago, Design sync",
             after.get("pinSaid"))
    finally:
        sv.cmd({"do": "meetalert", "action": "off"})
        sv.finish()


def main():
    t = sv.T()
    for folder in ("stills", "cuts"):
        (WORK / folder).mkdir(parents=True, exist_ok=True)
        for old in (WORK / folder).glob("*.png"):
            old.unlink()
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    results = []
    plan = [(220, [5]), (440, [2])]
    if os.environ.get("ONLY"):
        plan = [p for p in plan if str(p[0]) == os.environ["ONLY"]]
    try:
        for side, counts in plan:
            run(t, side, counts, results)
    finally:
        lines = []
        for r in results:
            x, y, w, h = r["tile"]
            line = f"{r['name']}: tile {w:.1f}x{h:.1f}"
            if "swift" in r:
                s = r["swift"]
                line += (f"; capsule {s['width']:.1f}x{s['height']:.1f}, {s['top']:.1f} from the top, "
                         f"{s['bottom']:.1f} above the bottom, {s['left']:.1f}/{s['right']:.1f} from the sides")
            if r.get("pixels"):
                p = r["pixels"]
                line += (f"; still: bottom {h - p['bottom']:.1f} above the tile's bottom, "
                         f"{p['left']:.1f}..{p['right']:.1f} across, {p['outside']} changed pixels outside")
            lines.append(line)
        (WORK / "measures.txt").write_text("\n".join(lines) + "\n")
        print("\n".join(lines))
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

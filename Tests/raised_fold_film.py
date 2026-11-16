#!/usr/bin/env python3
"""A folder card's light-mode bottom shade stays on the card's edge while it folds.

Build first (`./build.sh`), then `python3 Tests/raised_fold_film.py`. Light,
on a pale ground (F2EEE6), a folder of five tabs above a loose row, folded
and unfolded through the bench while the window is filmed (window-only, 60
fps, 2x). In every frame, down one column of device pixels inside the card,
the only lines darker than the card's fill are its top and bottom hairlines:
no shade left inside the card as it shrinks, none floating on the ground
below as it grows. Frames land in .context/raised-fold/.
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

sv.use("raised-fold-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "raised-fold"
CAPTURE = OUT / "capture"
PIXEL = OUT / "pixel"
PIXEL_SOURCE = r"""
import AppKit
let a = CommandLine.arguments
let x = Int(a[1])!, top = Int(a[2])!, bottom = Int(a[3])!
var out: [String] = []
for path in a.dropFirst(4) {
    guard let rep = NSBitmapImageRep(data: FileManager.default.contents(atPath: path)!) else { continue }
    var p = [Int](repeating: 0, count: 4)
    var column: [String] = []
    for y in top..<min(bottom, rep.pixelsHigh) {
        rep.getPixel(&p, atX: x, y: y)
        column.append(String(p[0]))
    }
    out.append("[" + column.joined(separator: ",") + "]")
}
print("[" + out.joined(separator: ",") + "]")
"""


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        title = self.path.strip("/").replace("%20", " ") or "Page"
        body = f"<!doctype html><title>{title}</title><p>{title}".encode()
        self.send_response(200); self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def film(pid, number, name, act, seconds=1.2):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number), "2"], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None: break
        time.sleep(0.025)
    time.sleep(0.15)
    act()
    print("  ..  ", name, p.communicate()[0].strip(), flush=True)
    return sorted(folder.glob("0*.png"))


def lines(column, fill):
    """Thin runs (one to three device pixels) darker than the card's fill: hairlines and shades."""
    found = [i for i, v in enumerate(column) if v < fill - 2]
    runs = []
    for i in found:
        if runs and i - runs[-1][-1] <= 1:
            runs[-1].append(i)
        else:
            runs.append([i])
    return [r for r in runs if len(r) <= 3]


def main():
    t = sv.T()
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    (OUT / "pixel.swift").write_text(PIXEL_SOURCE)
    subprocess.run(["swiftc", "-O", str(OUT / "pixel.swift"), "-o", str(PIXEL)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 760, "steps": 1})
        sv.cmd({"do": "ui", "groups": True, "cards": True, "look": "light"})
        sv.cmd({"do": "space", "action": "look", "custom": "F2EEE6", "intensity": 1.0, "glass": False, "transparency": 0, "grain": 0})
        members = [sv.sp("open", url=f"{BASE}/Member {n}")["resultID"] for n in range(5)]
        loose = sv.sp("open", url=f"{BASE}/Loose")["resultID"]
        time.sleep(1.5)
        sv.cmd({"do": "group", "id": members[0], "new": True, "name": "Fold"})
        for id in members[1:]:
            sv.cmd({"do": "group", "id": id, "name": "Fold"})
        sv.sp("select", id=loose)
        for blank in [k for k in sv.cmd({"do": "rowframes"})["rows"]
                      if k not in [i[:8].lower() for i in members + [loose]]]:
            try:
                sv.sp("close", id=blank)
            except RuntimeError:
                pass
        time.sleep(1.2)
        rows = sv.cmd({"do": "rowframes"})["rows"]
        first, last = rows[members[0][:8].lower()], rows[members[-1][:8].lower()]
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        report = {}
        for name, fold in [("fold", True), ("unfold", False)]:
            frames = film(pid, number, name, lambda: sv.cmd({"do": "group", "name": "Fold", "fold": fold}))
            t.ok(f"{name}: filmed", len(frames) > 20, len(frames))
            if not frames:
                continue
            width = subprocess.run(["sips", "-g", "pixelWidth", str(frames[0])], capture_output=True, text=True).stdout.split()[-1]
            k = max(1, round(int(width) / 1000))
            x = round((first[0] + first[2] - 48) * k)
            top, bottom = round((first[1] - 60) * k), round((last[1] + last[3] + 60) * k)
            columns = json.loads(subprocess.run([str(PIXEL), str(x), str(top), str(bottom)] + [str(f) for f in frames],
                                                capture_output=True, text=True).stdout)
            fill = columns[0][60 * k - 15 * k]
            counts = [len(lines(c, fill)) for c in columns]
            extra = [i for i, n in enumerate(counts) if n > 2]
            report[name] = {"fill": fill, "counts": counts}
            t.ok(f"{name}: only the card's own top and bottom lines in every frame", not extra,
                 [(i, lines(columns[i], fill)) for i in extra[:3]])
        (OUT / "report.json").write_text(json.dumps(report))
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())

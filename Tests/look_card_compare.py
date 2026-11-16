#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
before = ROOT / ".context" / "look-card" / (sys.argv[1] if len(sys.argv) > 1 else "before") / "migrate"
after = ROOT / ".context" / "look-card" / (sys.argv[2] if len(sys.argv) > 2 else "after") / "migrate"
TOOL = ROOT / ".context" / "look-card-tools" / "pixel-diff"
SOURCE = ROOT / ".context" / "look-card-tools" / "pixel_diff.swift"

SOURCE.parent.mkdir(parents=True, exist_ok=True)
SOURCE.write_text('''
import AppKit

func pixels(_ path: String) -> (Int, Int, [UInt8])? {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let w = cg.width, h = cg.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, data)
}

let args = CommandLine.arguments
guard let a = pixels(args[1]), let b = pixels(args[2]), a.0 == b.0, a.1 == b.1 else { print("{\\"error\\":\\"size\\"}"); exit(0) }
var differ = 0, most = 0
var box = (x0: Int.max, y0: Int.max, x1: -1, y1: -1)
for i in stride(from: 0, to: a.2.count, by: 4) {
    let d = (0..<3).map { abs(Int(a.2[i + $0]) - Int(b.2[i + $0])) }.max() ?? 0
    if d > 0 {
        differ += 1
        let x = (i / 4) % a.0, y = (i / 4) / a.0
        box = (min(box.x0, x), min(box.y0, y), max(box.x1, x), max(box.y1, y))
    }
    most = max(most, d)
}
print("{\\"differ\\":\\(differ),\\"most\\":\\(most),\\"total\\":\\(a.0 * a.1),\\"box\\":[\\(box.x0),\\(box.y0),\\(box.x1),\\(box.y1)]}")
''')
if not TOOL.exists() or TOOL.stat().st_mtime < SOURCE.stat().st_mtime:
    subprocess.run(["swiftc", "-O", str(SOURCE), "-o", str(TOOL)], check=True)

rows = {}
same = 0
for shot in sorted(before.glob("*.png")):
    other = after / shot.name
    if not other.exists():
        rows[shot.stem] = {"error": "missing"}
        continue
    read = json.loads(subprocess.run([str(TOOL), str(shot), str(other)], capture_output=True, text=True).stdout or "{}")
    rows[shot.stem] = read
    if read.get("differ") == 0:
        same += 1
    print(f"{shot.stem:28} {'same' if read.get('differ') == 0 else read}")
print(f"{same} of {len(rows)} identical pixel for pixel")
(after.parent / "compare.json").write_text(json.dumps(rows, indent=1))

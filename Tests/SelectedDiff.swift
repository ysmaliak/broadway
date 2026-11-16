import AppKit

struct Picture {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ path: String) {
        let rep = NSBitmapImageRep(data: FileManager.default.contents(atPath: path)!)!
        let made = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: rep.pixelsWide * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: made)
        rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        width = rep.pixelsWide
        height = rep.pixelsHigh
        bytes = Array(UnsafeBufferPointer(start: made.bitmapData!, count: rep.pixelsWide * rep.pixelsHigh * 4))
    }

    func at(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (min(max(0, y), height - 1) * width + min(max(0, x), width - 1)) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

let a = CommandLine.arguments
switch a[1] {
case "diff":
    let one = Picture(a[2]), two = Picture(a[3])
    let x0 = Int(a[4])!, y0 = Int(a[5])!, w = Int(a[6])!, h = Int(a[7])!
    var most = 0, count = 0
    var box = (Int.max, Int.max, Int.min, Int.min)
    for y in y0..<(y0 + h) {
        for x in x0..<(x0 + w) {
            let p = one.at(x, y), q = two.at(x, y)
            let d = max(abs(p.0 - q.0), abs(p.1 - q.1), abs(p.2 - q.2))
            most = max(most, d)
            if d > 2 {
                count += 1
                box = (min(box.0, x), min(box.1, y), max(box.2, x), max(box.3, y))
            }
        }
    }
    let shown = count > 0 ? "[\(box.0),\(box.1),\(box.2 - box.0 + 1),\(box.3 - box.1 + 1)]" : "null"
    print("{\"max\":\(most),\"count\":\(count),\"box\":\(shown)}")
case "row":
    let one = Picture(a[2])
    let y = Int(a[3])!, x0 = Int(a[4])!, x1 = Int(a[5])!
    print("[" + (x0..<x1).map { x in let p = one.at(x, y); return "[\(p.0),\(p.1),\(p.2)]" }.joined(separator: ",") + "]")
case "column":
    let one = Picture(a[2])
    let x = Int(a[3])!, y0 = Int(a[4])!, y1 = Int(a[5])!
    print("[" + (y0..<y1).map { y in let p = one.at(x, y); return "[\(p.0),\(p.1),\(p.2)]" }.joined(separator: ",") + "]")
default:
    print("usage: diff a b x y w h | row a y x0 x1 | column a x y0 y1")
}

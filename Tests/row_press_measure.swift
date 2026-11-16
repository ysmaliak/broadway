import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Pixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let x = min(max(0, x), width - 1), y = min(max(0, y), height - 1)
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    func distance(_ x: Int, _ y: Int, from c: (Int, Int, Int)) -> Double {
        let p = rgb(x, y)
        return Double(max(abs(p.0 - c.0), abs(p.1 - c.1), abs(p.2 - c.2)))
    }

    func magenta(_ x: Int, _ y: Int) -> Double {
        let p = rgb(x, y)
        let m = Double(min(p.0, p.2) - p.1)
        return max(0, m) / 255
    }
}

func load(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

struct Reading {
    var slab: Double?
    var slabMiddle: Double?
    var strength: Double
    var content: Double?
    var contentY: Double?
    var area: Double
    var change: Double
}

func edge(_ pixels: Pixels, y: Int, from start: Int, to end: Int, background: (Int, Int, Int), level: Double) -> Double? {
    let step = start < end ? 1 : -1
    var previous = pixels.distance(start, y, from: background)
    var x = start + step
    while x != end {
        let here = pixels.distance(x, y, from: background)
        if here >= level {
            let t = here == previous ? 0 : (level - previous) / (here - previous)
            return Double(x - step) + Double(step) * t + (step > 0 ? 0.5 : 0.5)
        }
        previous = here
        x += step
    }
    return nil
}

func read(_ pixels: Pixels, row: CGRect, previous: Pixels?) -> Reading {
    let x0 = Int(row.minX), x1 = Int(row.maxX), y0 = Int(row.minY), y1 = Int(row.maxY)
    let mid = (y0 + y1) / 2
    let background = pixels.rgb(x0 - 3, mid)
    let probe = x0 + Int(Double(x1 - x0) * 0.78)
    var strength = 0.0
    for dy in -2...2 { strength += pixels.distance(probe, mid + dy, from: background) }
    strength /= 5
    var reading = Reading(slab: nil, slabMiddle: nil, strength: strength, content: nil, contentY: nil, area: 0, change: 0)
    if strength >= 5 {
        let level = strength / 2
        if let left = edge(pixels, y: mid, from: x0 - 3, to: x0 + 12, background: background, level: level),
           let right = edge(pixels, y: mid, from: x1 + 2, to: x1 - 12, background: background, level: level) {
            reading.slab = (right - left) / Double(x1 - x0)
            reading.slabMiddle = (left + right) / 2 - row.midX
        }
    }
    var weight = 0.0, sx = 0.0, sy = 0.0
    for y in y0..<y1 {
        for x in x0..<x1 {
            let m = pixels.magenta(x, y)
            guard m > 0.25 else { continue }
            weight += m
            sx += m * (Double(x) + 0.5)
            sy += m * (Double(y) + 0.5)
        }
    }
    reading.area = weight
    if weight > 20 {
        reading.content = sx / weight
        reading.contentY = sy / weight
    }
    if let previous {
        var total = 0.0, count = 0.0
        for y in stride(from: y0 - 4, to: y1 + 4, by: 2) {
            for x in stride(from: x0 - 4, to: x1 + 4, by: 2) {
                let a = pixels.rgb(x, y), b = previous.rgb(x, y)
                total += Double(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2))
                count += 1
            }
        }
        reading.change = total / max(1, count)
    }
    return reading
}

func strip(_ cuts: [CGImage], labels: [String], marked: [Bool], columns: Int, zoom: Int) -> CGImage? {
    guard let first = cuts.first else { return nil }
    let columns = max(1, min(columns, cuts.count))
    let rows = (cuts.count + columns - 1) / columns
    let gap = 8, band = 18
    let w = first.width * zoom, h = first.height * zoom
    let width = columns * w + (columns + 1) * gap
    let height = rows * (h + band) + (rows + 1) * gap
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .none
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (index, cut) in cuts.enumerated() {
        let x = gap + (index % columns) * (w + gap)
        let y = height - (index / columns + 1) * (h + band + gap)
        if marked[index] {
            context.setFillColor(CGColor(red: 1, green: 0.15, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: x - 4, y: y - 4, width: w + 8, height: h + 8))
        }
        context.draw(cut, in: CGRect(x: x, y: y, width: w, height: h))
        NSAttributedString(string: labels[index], attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: marked[index] ? NSColor(red: 1, green: 0.75, blue: 0.7, alpha: 1) : NSColor.white,
        ]).draw(at: NSPoint(x: x + 2, y: y + h + 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

@main struct Run {
    static func main() throws {
        let args = CommandLine.arguments
        let folder = URL(fileURLWithPath: args[1], isDirectory: true)
        let points = args[2].split(separator: ",").compactMap { Double($0) }
        let title = args.count > 3 ? args[3] : folder.lastPathComponent
        let arrives = title.hasSuffix("keyboard")
        let times = (try? JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("frames.json")))) as? [String: Any]
        let stamps = (times?["frames"] as? [[String: Any]])?.compactMap { $0["t"] as? Double } ?? []
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}\.png$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var scale = 2.0
        if let first = files.first.flatMap(load) {
            let pixels = Pixels(first)
            let below = stride(from: pixels.height / 2 + 4, to: pixels.height, by: 7).allSatisfy { y in
                stride(from: 0, to: pixels.width, by: 9).allSatisfy { x in let p = pixels.rgb(x, y); return p.0 + p.1 + p.2 == 0 }
            }
            if below { scale = 1 }
        }
        let row = CGRect(x: points[0] * scale, y: points[1] * scale, width: points[2] * scale, height: points[3] * scale)
        var readings: [Reading] = []
        var images: [CGImage] = []
        var last: Pixels?
        for file in files {
            guard let image = load(file) else { continue }
            let pixels = Pixels(image)
            readings.append(read(pixels, row: row, previous: last))
            images.append(image)
            last = pixels
        }
        guard !readings.isEmpty else { print("no frames"); return }
        let restX = readings.prefix(3).compactMap(\.content).first
        let restY = readings.prefix(3).compactMap(\.contentY).first
        let restArea = readings.prefix(3).map(\.area).first { $0 > 20 }
        let restSlab = readings.prefix(3).compactMap(\.slab).first
        let restMiddle = readings.prefix(3).compactMap(\.slabMiddle).first ?? 0
        let tolerance = scale == 1 ? 0.011 : 0.006
        let moving = readings.indices.filter { readings[$0].change > 0.4 }
        let start = max(0, (moving.first ?? 0) - 2)
        let end = min(readings.count - 1, (moving.last ?? 0) + 3)
        var rows: [[String: Any]] = []
        var cuts: [CGImage] = []
        var labels: [String] = []
        var marked: [Bool] = []
        var glitches: [String] = []
        let base = stamps.indices.contains(moving.first ?? 0) ? stamps[moving.first ?? 0] : 0
        var lastSlab: Double?
        for index in start...end {
            let r = readings[index]
            var contentScale: Double?
            if let x = r.content, let restX, abs(row.midX - restX) > 40 {
                contentScale = (row.midX - x) / (row.midX - restX)
            } else if let restArea, r.area > 20 {
                contentScale = (r.area / restArea).squareRoot()
            }
            var contentDrop: Double?
            if let y = r.contentY, let restY { contentDrop = y - restY }
            var why: [String] = []
            let slabScale = r.slab.map { $0 / (restSlab ?? 1) }
            if !arrives, let slab = slabScale, let contentScale, abs(slab - contentScale) > tolerance {
                why.append(String(format: "slab %.3f vs row %.3f", slab, contentScale))
            }
            if let middle = r.slabMiddle, abs(middle - restMiddle) > 1.6 { why.append(String(format: "slab off centre %.1fpx", middle - restMiddle)) }
            if let slab = slabScale, let lastSlab, abs(slab - lastSlab) > 0.016 { why.append(String(format: "slab jumps %.3f", slab - lastSlab)) }
            lastSlab = slabScale ?? lastSlab
            let t = stamps.indices.contains(index) ? stamps[index] - base : Double(index - start) * 8.33
            rows.append(["frame": index, "t": t, "slab": slabScale as Any, "slabMiddle": r.slabMiddle as Any, "strength": r.strength,
                         "row": contentScale as Any, "rowDrop": contentDrop as Any, "change": r.change, "glitch": why])
            if !why.isEmpty { glitches.append(String(format: "%04d (%+.0f ms): ", index, t) + why.joined(separator: "; ")) }
            let box = row.insetBy(dx: -10 * scale, dy: -5 * scale)
            if let cut = images[index].cropping(to: box) { cuts.append(cut) }
            labels.append(String(format: "%+4.0fms #%d s %@ r %@", t, index,
                                 slabScale.map { String(format: "%.3f", $0) } ?? " -  ",
                                 contentScale.map { String(format: "%.3f", $0) } ?? " - "))
            marked.append(!why.isEmpty)
        }
        if let made = strip(cuts, labels: labels, marked: marked, columns: 3, zoom: scale == 1 ? 3 : 2) {
            write(made, to: folder.appendingPathComponent("strip.png"))
        }
        let summary: [String: Any] = ["title": title, "frames": rows, "glitches": glitches]
        let json = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys, .prettyPrinted])
        try json.write(to: folder.appendingPathComponent("measure.json"))
        print("\(title): \(rows.count) frames, \(glitches.count) glitch frames")
        for g in glitches.prefix(12) { print("   " + g) }
    }
}

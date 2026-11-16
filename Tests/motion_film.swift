import AppKit
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct Options {
    var pid: pid_t = 0
    var seconds = 2.0
    var out = "film"
    var crop: CGRect?
    var columns = 6
    var most = 24
    var scale: CGFloat = 1
    var fps = 60
    var display = false
    var center: CGSize?
    var regions: [(String, CGRect)] = []
    var tracks: [Track] = []
    var frames: String?
}

struct Track {
    let name: String
    let rect: CGRect
    let period: CGFloat
    let incoming: Bool
}

func options() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        let value = args.isEmpty ? "" : args.removeFirst()
        switch key {
        case "--pid": o.pid = pid_t(value) ?? 0
        case "--seconds": o.seconds = Double(value) ?? o.seconds
        case "--out": o.out = value
        case "--columns": o.columns = Int(value) ?? o.columns
        case "--most": o.most = Int(value) ?? o.most
        case "--scale": o.scale = CGFloat(Double(value) ?? 1)
        case "--fps": o.fps = Int(value) ?? o.fps
        case "--display": o.display = value == "1"
        case "--center":
            let n = value.split(separator: ",").compactMap { Double($0) }
            if n.count == 2 { o.center = CGSize(width: n[0], height: n[1]) }
        case "--regions":
            for part in value.split(separator: ";") {
                let pair = part.split(separator: ":")
                let n = pair.count == 2 ? pair[1].split(separator: ",").compactMap { Double($0) } : []
                if n.count == 4 { o.regions.append((String(pair[0]), CGRect(x: n[0], y: n[1], width: n[2], height: n[3]))) }
            }
        case "--frames": o.frames = value
        case "--track":
            for part in value.split(separator: ";") {
                let pair = part.split(separator: ":")
                let n = pair.count == 2 ? pair[1].split(separator: ",").compactMap { Double($0) } : []
                if n.count == 6 {
                    o.tracks.append(Track(name: String(pair[0]), rect: CGRect(x: n[0], y: n[1], width: n[2], height: n[3]),
                                          period: CGFloat(n[4]), incoming: n[5] != 0))
                }
            }
        case "--crop":
            let n = value.split(separator: ",").compactMap { Double($0) }
            if n.count == 4 { o.crop = CGRect(x: n[0], y: n[1], width: n[2], height: n[3]) }
        default: break
        }
    }
    return o
}

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame { let time: Double; let image: CGImage; let thumb: [UInt8]; let bands: [Band] }

    let lock = NSLock()
    var frames: [Frame] = []
    var started: Double?
    let context = CIContext()
    var tracks: [Track] = []
    var scale: CGFloat = 1
    var keep: CGFloat = 1

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer
        else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let picture = context.createCGImage(image, from: image.extent) else { return }
        let time = buffer.presentationTimeStamp.seconds
        let thumb = Recorder.thumb(picture)
        let bands = tracks.map { Band(picture, $0.rect, scale: scale) }
        let kept = keep < 1 ? context.createCGImage(image.transformed(by: CGAffineTransform(scaleX: keep, y: keep)),
                                                     from: image.extent.applying(CGAffineTransform(scaleX: keep, y: keep)).integral) ?? picture : picture
        lock.lock()
        if started == nil { started = time }
        frames.append(Frame(time: time - (started ?? time), image: kept, thumb: thumb, bands: bands))
        lock.unlock()
    }

    static let thumbWidth = 200

    static func thumb(_ image: CGImage) -> [UInt8] {
        let width = thumbWidth
        let height = max(1, Int(Double(image.height) * Double(width) / Double(image.width)))
        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }
}

struct Band {
    let width: Int
    let height: Int
    let gray: [Int16]

    init(_ image: CGImage, _ rect: CGRect, scale: CGFloat) {
        let box = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let part = image.cropping(to: box) else { width = 0; height = 0; gray = []; return }
        let w = part.width, h = part.height / 2
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .low
            context.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        var soft = [Int16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0
                var weight = 0
                for dy in -1...1 {
                    let yy = y + dy
                    guard yy >= 0, yy < h else { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        guard xx >= 0, xx < w else { continue }
                        let k = (dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1)
                        sum += Int(bytes[yy * w + xx]) * k
                        weight += k
                    }
                }
                soft[y * w + x] = Int16(sum / weight)
            }
        }
        gray = soft
    }

    func at(_ x: Int, _ y: Int) -> Int16 { gray[y * width + x] }
}

struct Fit {
    let shift: Double
    let residual: Double
    let ink: Double
}

func cost(_ frame: Band, _ out: Band, _ into: Band?, shift s: Int, period: Int, every: Int, rows: Int, gradient: Bool) -> (Double, Int) {
    let w = frame.width, h = frame.height
    guard w > 2, h > 2, out.width == w, out.height == h else { return (.infinity, 0) }
    var total = 0
    var count = 0
    var y = 1
    while y < h - 1 {
        var x = 0
        while x < w - 1 {
            var source: Band?
            var sx = x - s
            if sx >= 0 && sx < w - 1 {
                source = out
            } else if let into {
                sx = s < 0 ? x - s - period : x - s + period
                if sx >= 0 && sx < w - 1 { source = into }
            }
            if let source {
                if gradient {
                    let fx = Int(frame.at(x + 1, y)) - Int(frame.at(x, y))
                    let fy = Int(frame.at(x, y + 1)) - Int(frame.at(x, y))
                    let mx = Int(source.at(sx + 1, y)) - Int(source.at(sx, y))
                    let my = Int(source.at(sx, y + 1)) - Int(source.at(sx, y))
                    total += abs(fx - mx) + abs(fy - my)
                } else {
                    total += abs(Int(frame.at(x, y)) - Int(source.at(sx, y)))
                }
                count += 1
            }
            x += every
        }
        y += rows
    }
    return (count > 0 ? Double(total) / Double(count) : .infinity, count)
}

func fit(_ frame: Band, _ out: Band, _ into: Band?, period: Int, near: Int?) -> Fit {
    let w = frame.width
    let least = w / 6
    func scored(_ s: Int, every: Int, rows: Int) -> Double {
        let (c, n) = cost(frame, out, into, shift: s, period: period, every: every, rows: rows, gradient: true)
        return n * every * rows < least * frame.height / 2 ? .infinity : c
    }
    var best = 0
    var bestCost = Double.infinity
    let reach = into == nil ? w - least : max(w, period)
    for s in stride(from: -reach, through: reach, by: 3) {
        let c = scored(s, every: 3, rows: 4)
        if c < bestCost { bestCost = c; best = s }
    }
    if let near {
        var local = near
        var localCost = Double.infinity
        for s in max(-reach, near - 40)...min(reach, near + 40) {
            let c = scored(s, every: 3, rows: 4)
            if c < localCost { localCost = c; local = s }
        }
        if localCost <= bestCost * 1.5 { best = local; bestCost = localCost }
    }
    var fine = best
    var fineCost = Double.infinity
    var costs: [Int: Double] = [:]
    for s in (best - 4)...(best + 4) {
        let c = scored(s, every: 1, rows: 1)
        costs[s] = c
        if c < fineCost { fineCost = c; fine = s }
    }
    var shift = Double(fine)
    if let l = costs[fine - 1], let r = costs[fine + 1], l.isFinite, r.isFinite {
        let bend = l - 2 * fineCost + r
        if bend > 0 { shift += max(-0.5, min(0.5, (l - r) / (2 * bend))) }
    }
    let ink = cost(frame, out, into, shift: fine, period: period, every: 1, rows: 1, gradient: false).0
    return Fit(shift: shift, residual: fineCost, ink: ink)
}

func sample(_ image: CGImage, _ unit: CGRect) -> [Double] {
    let rect = CGRect(x: unit.minX * Double(image.width), y: unit.minY * Double(image.height),
                      width: unit.width * Double(image.width), height: unit.height * Double(image.height)).integral
    guard let part = image.cropping(to: rect) else { return [0, 0, 0, 0, 0] }
    let width = part.width, height = part.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn, width * height > 0 else { return [0, 0, 0, 0, 0] }
    var r = 0.0, g = 0.0, b = 0.0, sum = 0.0, squares = 0.0
    let count = Double(width * height)
    for i in stride(from: 0, to: bytes.count, by: 4) {
        let pr = Double(bytes[i]), pg = Double(bytes[i + 1]), pb = Double(bytes[i + 2])
        let y = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
        r += pr; g += pg; b += pb; sum += y; squares += y * y
    }
    let mean = sum / count
    let deviation = max(0, squares / count - mean * mean).squareRoot()
    return [mean, deviation, r / count, g / count, b / count].map { ($0 * 10).rounded() / 10 }
}

func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var total = 0
    for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
    return Double(total) / Double(a.count)
}

func write(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func sheet(_ pictures: [CGImage], labels: [String], columns: Int) -> CGImage? {
    guard let first = pictures.first else { return nil }
    let columns = max(1, min(columns, pictures.count))
    let rows = (pictures.count + columns - 1) / columns
    let gap = 4
    let band = 18
    let cell = CGSize(width: first.width, height: first.height + band)
    let width = columns * Int(cell.width) + (columns + 1) * gap
    let height = rows * Int(cell.height) + (rows + 1) * gap
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    for (index, picture) in pictures.enumerated() {
        let column = index % columns
        let row = index / columns
        let x = gap + column * (Int(cell.width) + gap)
        let y = height - (row + 1) * (Int(cell.height) + gap)
        context.draw(picture, in: CGRect(x: x, y: y, width: picture.width, height: picture.height))
        let label = NSAttributedString(string: labels[index], attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        label.draw(at: NSPoint(x: x + 4, y: y + picture.height + 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

@MainActor
func run() async throws {
    let o = options()
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let windows = content.windows.filter { $0.owningApplication?.processID == o.pid && $0.windowLayer == 0 && $0.frame.width > 300 }
    guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })
    else { throw NSError(domain: "film", code: 1, userInfo: [NSLocalizedDescriptionKey: "no window for pid \(o.pid)"]) }
    let display = content.displays.first { $0.frame.intersects(window.frame) } ?? content.displays[0]
    let ours = content.windows.filter { $0.owningApplication?.processID == o.pid && $0.isOnScreen }
    let filter = SCContentFilter(display: display, including: ours)
    let config = SCStreamConfiguration()
    var source = o.display ? CGRect(origin: .zero, size: display.frame.size)
        : window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    if let center = o.center {
        source = CGRect(x: (display.frame.width - center.width) / 2, y: (display.frame.height - center.height) / 2,
                        width: center.width, height: center.height)
    } else if let crop = o.crop {
        source = CGRect(x: source.minX + crop.minX, y: source.minY + crop.minY, width: crop.width, height: crop.height)
    }
    config.sourceRect = source
    config.width = Int(source.width * o.scale)
    config.height = Int(source.height * o.scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
    config.showsCursor = false
    config.queueDepth = 8
    config.capturesShadowsOnly = false
    let recorder = Recorder()
    recorder.tracks = o.tracks
    recorder.scale = o.scale
    recorder.keep = o.tracks.isEmpty || o.scale <= 0.5 ? 1 : 0.5 / o.scale
    let stream = SCStream(filter: filter, configuration: config, delegate: nil)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "film"))
    try await stream.startCapture()
    try await Task.sleep(for: .milliseconds(150))
    print("ready \(Int(window.windowID))")
    fflush(stdout)
    var known = Set(ours.map(\.windowID))
    let end = Date().addingTimeInterval(o.seconds)
    while Date() < end {
        try await Task.sleep(for: .milliseconds(100))
        let now = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let mine = now.windows.filter { $0.owningApplication?.processID == o.pid }
        let ids = Set(mine.map(\.windowID))
        if !ids.isSubset(of: known) {
            known.formUnion(ids)
            try await stream.updateContentFilter(SCContentFilter(display: display, including: mine))
        }
    }
    try await stream.stopCapture()
    let (frames, origin) = recorder.lock.withLock { (recorder.frames, recorder.started ?? 0) }
    guard frames.count > 1 else { throw NSError(domain: "film", code: 2, userInfo: [NSLocalizedDescriptionKey: "only \(frames.count) frames came"]) }
    var diffs: [Double] = [0]
    for i in 1..<frames.count { diffs.append(difference(frames[i - 1].thumb, frames[i].thumb)) }
    let total = diffs.reduce(0, +)
    let moving = diffs.indices.filter { diffs[$0] > 0.15 }
    let first = moving.first ?? 0
    let last = moving.last ?? frames.count - 1
    let lo = max(0, first - 2)
    let hi = min(frames.count - 1, last + 2)
    let span = Array(lo...hi)
    let step = max(1, Int((Double(span.count) / Double(o.most)).rounded(.up)))
    var picks = stride(from: 0, to: span.count, by: step).map { span[$0] }
    if picks.last != hi { picks.append(hi) }
    let base = frames[first].time
    let labels = picks.map { String(format: "%+.0f ms  Δ%.1f", (frames[$0].time - base) * 1000, diffs[$0]) }
    if let made = sheet(picks.map { frames[$0].image }, labels: labels, columns: o.columns) {
        write(made, to: o.out + ".png")
    }
    write(frames[0].image, to: o.out + "-first.png")
    write(frames[frames.count - 1].image, to: o.out + "-last.png")
    let gaps = zip(frames.dropFirst(), frames).map { ($0.time - $1.time) * 1000 }
    var report: [String: Any] = [
        "frames": frames.count,
        "fps": o.fps,
        "firstHost": moving.isEmpty ? 0 : origin + frames[first].time,
        "lastHost": moving.isEmpty ? 0 : origin + frames[last].time,
        "delivered": moving.isEmpty ? 0 : last - first + 1,
        "deliveredFps": moving.isEmpty || last == first ? 0 : (Double(last - first) / (frames[last].time - frames[first].time) * 10).rounded() / 10,
        "times": moving.isEmpty ? [] : (lo...hi).map { ((frames[$0].time - base) * 10000).rounded() / 10 },
        "window": [window.frame.width, window.frame.height],
        "changing": moving.count,
        "motionMs": moving.isEmpty ? 0 : ((frames[last].time - frames[first].time) * 1000).rounded(),
        "biggestShare": total > 0 ? ((diffs.max() ?? 0) / total * 100).rounded() / 100 : 0,
        "worstGapMs": (gaps.max() ?? 0).rounded(),
        "longGaps": gaps.filter { $0 > 25 }.count,
        "motionGaps": moving.isEmpty ? [] : Array(gaps[max(0, first - 1)..<min(gaps.count, last)]).map { $0.rounded() },
        "regions": Dictionary(uniqueKeysWithValues: o.regions.map { region in
            (region.0, frames.map { frame in [((frame.time - frames[first].time) * 1000).rounded()] + sample(frame.image, region.1) })
        }),
        "curve": moving.isEmpty ? [] : (first...last).map { ["t": ((frames[$0].time - base) * 1000).rounded(), "d": (diffs[$0] * 10).rounded() / 10] },
    ]
    report["hosts"] = frames.map { ((origin + $0.time) * 1_000_000).rounded() / 1_000_000 }
    var fits: [String: Any] = [:]
    for (index, track) in o.tracks.enumerated() {
        let out = frames[0].bands[index]
        let into = track.incoming ? frames[frames.count - 1].bands[index] : nil
        let period = Int((track.period * o.scale).rounded())
        var near: Int?
        var rows: [[Double]] = []
        for frame in frames {
            let f = fit(frame.bands[index], out, into, period: period, near: near)
            near = Int(f.shift.rounded())
            rows.append([(f.shift / Double(o.scale) * 100).rounded() / 100, (f.residual * 100).rounded() / 100, (f.ink * 100).rounded() / 100])
        }
        fits[track.name] = rows
    }
    report["tracks"] = fits
    if let folder = o.frames {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for index in lo...hi {
            write(frames[index].image, to: folder + String(format: "/%03d.png", index))
        }
    }
    let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    try json.write(to: URL(fileURLWithPath: o.out + ".json"))
    print(String(data: json, encoding: .utf8) ?? "")
}

Task { @MainActor in
    do { try await run() } catch { FileHandle.standardError.write("film: \(error.localizedDescription)\n".data(using: .utf8)!); exit(1) }
    exit(0)
}
dispatchMain()

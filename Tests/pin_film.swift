import AppKit
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "pin-film")
    let context = CIContext()
    var times: [Double] = []
    var first: Double?
    var frames: [CGImage] = []

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer else { return }
        let time = buffer.presentationTimeStamp.seconds
        if first == nil { first = time }
        let ci = CIImage(cvPixelBuffer: pixels)
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return }
        frames.append(cg)
        times.append(time - first!)
    }
}

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

    func key(_ x: Int, _ y: Int) -> Bool {
        let i = (y * width + x) * 4
        let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
        return r > 190 && b > 190 && g < 90
    }
}

func blobs(_ pixels: Pixels, scale: Double) -> [[String: Double]] {
    let cell = 3
    let across = pixels.width / cell, down = pixels.height / cell
    var lit = [Int](repeating: 0, count: across * down)
    for cy in 0..<down {
        for cx in 0..<across {
            var n = 0
            for y in (cy * cell)..<(cy * cell + cell) {
                for x in (cx * cell)..<(cx * cell + cell) where pixels.key(x, y) { n += 1 }
            }
            lit[cy * across + cx] = n
        }
    }
    var seen = [Bool](repeating: false, count: across * down)
    var found: [[String: Double]] = []
    for start in 0..<(across * down) where lit[start] >= 2 && !seen[start] {
        var stack = [start]
        seen[start] = true
        var minX = Int.max, minY = Int.max, maxX = 0, maxY = 0, count = 0, sumX = 0, sumY = 0
        while let at = stack.popLast() {
            let x = at % across, y = at / across
            count += lit[at]
            sumX += x * lit[at]
            sumY += y * lit[at]
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < across, ny < down else { continue }
                let next = ny * across + nx
                if !seen[next] && lit[next] >= 2 { seen[next] = true; stack.append(next) }
            }
        }
        guard count >= 40 else { continue }
        let unit = Double(cell) / scale
        found.append(["x": (Double(sumX) / Double(count) + 0.5) * unit, "y": (Double(sumY) / Double(count) + 0.5) * unit,
                      "w": Double(maxX - minX + 1) * unit, "h": Double(maxY - minY + 1) * unit, "n": Double(count)])
    }
    return found
}

func thumb(_ pixels: Pixels) -> [UInt8] {
    var out: [UInt8] = []
    for y in stride(from: 0, to: pixels.height, by: 6) {
        for x in stride(from: 0, to: pixels.width, by: 6) {
            let i = (y * pixels.width + x) * 4
            out.append(UInt8((Int(pixels.bytes[i]) + Int(pixels.bytes[i + 1]) + Int(pixels.bytes[i + 2])) / 3))
        }
    }
    return out
}

func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var total = 0
    for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
    return Double(total) / Double(a.count)
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

func sheet(_ pictures: [CGImage], labels: [String], columns: Int, shrink: Double) -> CGImage? {
    guard let first = pictures.first else { return nil }
    let columns = max(1, min(columns, pictures.count))
    let rows = (pictures.count + columns - 1) / columns
    let gap = 6, band = 20
    let w = Int(Double(first.width) * shrink), h = Int(Double(first.height) * shrink)
    let width = columns * w + (columns + 1) * gap
    let height = rows * (h + band) + (rows + 1) * gap
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    for (index, picture) in pictures.enumerated() {
        let x = gap + (index % columns) * (w + gap)
        let y = height - (index / columns + 1) * (h + band + gap)
        context.draw(picture, in: CGRect(x: x, y: y, width: w, height: h))
        NSAttributedString(string: labels[index], attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white,
        ]).draw(at: NSPoint(x: x + 2, y: y + h + 3))
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let number = UInt32(args[2])!
        let folder = URL(fileURLWithPath: args[3], isDirectory: true)
        let seconds = Double(args[4])!
        let crop = args[5].split(separator: ",").compactMap { Double($0) }
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowID == number }) else {
            print("SKIP: no test window"); return
        }
        let scale = 2.0
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 8
        let capture = Capture()
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        try await stream.startCapture()
        for _ in 0..<100 {
            if capture.queue.sync(execute: { !capture.frames.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("ready")
        fflush(stdout)
        try await Task.sleep(for: .seconds(seconds))
        try? await stream.stopCapture()
        capture.queue.sync {}
        let box = CGRect(x: crop[0] * scale, y: crop[1] * scale, width: crop[2] * scale, height: crop[3] * scale)
        var cuts: [CGImage] = []
        var report: [[String: Any]] = []
        var thumbs: [[UInt8]] = []
        for (index, frame) in capture.frames.enumerated() {
            guard let cut = frame.cropping(to: box) else { continue }
            let pixels = Pixels(cut)
            cuts.append(cut)
            thumbs.append(thumb(pixels))
            report.append(["t": capture.times[index] * 1000, "blobs": blobs(pixels, scale: scale)])
        }
        var change: [Double] = [0]
        for i in 1..<max(1, thumbs.count) { change.append(difference(thumbs[i - 1], thumbs[i])) }
        for i in report.indices { report[i]["change"] = change[i] }
        for (index, cut) in cuts.enumerated() {
            write(cut, to: folder.appendingPathComponent(String(format: "%04d.png", index)))
        }
        let moving = change.indices.filter { change[$0] > 0.15 }
        if let start = moving.first, let end = moving.last {
            let from = max(0, start - 1), to = min(cuts.count - 1, end + 1)
            let picks = Array(from...to)
            let step = max(1, Int((Double(picks.count) / 30).rounded(.up)))
            let shown = stride(from: 0, to: picks.count, by: step).map { picks[$0] } + (picks.count % step == 1 || step == 1 ? [] : [picks.last!])
            let base = capture.times[start]
            let labels = shown.map { i in
                String(format: "%+.0f ms  %d", (capture.times[i] - base) * 1000, (report[i]["blobs"] as? [Any])?.count ?? 0)
            }
            if let made = sheet(shown.map { cuts[$0] }, labels: labels, columns: 10, shrink: 0.5) {
                write(made, to: folder.appendingPathComponent("sheet.png"))
            }
        }
        let json = try JSONSerialization.data(withJSONObject: ["frames": report, "scale": scale], options: [.sortedKeys])
        try json.write(to: folder.appendingPathComponent("frames.json"))
        print("filmed \(cuts.count) frames, \(moving.count) changing")
    }
}

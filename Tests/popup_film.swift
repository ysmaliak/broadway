import AppKit
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "popup-film")
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

func write(_ image: CGImage, to url: URL) {
    guard let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(target, image, nil)
    CGImageDestinationFinalize(target)
}

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let number = UInt32(args[2])!
        let folder = URL(fileURLWithPath: args[3], isDirectory: true)
        let seconds = Double(args[4])!
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowID == number }) else {
            print("SKIP: no test window"); return
        }
        let own = content.windows.filter { $0.owningApplication?.processID == pid }
        guard let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) ?? content.displays.first else {
            print("SKIP: no display"); return
        }
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }
        let rate = max(30, screen?.maximumFramesPerSecond ?? 60)
        let scale = screen?.backingScaleFactor ?? 2
        let room = window.frame.insetBy(dx: -40, dy: -40).intersection(display.frame)
        let config = SCStreamConfiguration()
        config.sourceRect = room.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(room.width * scale)
        config.height = Int(room.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
        config.showsCursor = false
        config.queueDepth = 8
        let capture = Capture()
        let filter = SCContentFilter(display: display, including: own)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        try await stream.startCapture()
        let watch = Task {
            var seen = Set(own.map(\.windowID))
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(30))
                guard let now = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { continue }
                let mine = now.windows.filter { $0.owningApplication?.processID == pid }
                let ids = Set(mine.map(\.windowID))
                guard ids != seen else { continue }
                seen = ids
                try? await stream.updateContentFilter(SCContentFilter(display: display, including: mine))
            }
        }
        for _ in 0..<100 {
            if capture.queue.sync(execute: { !capture.frames.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        print("ready")
        fflush(stdout)
        try await Task.sleep(for: .seconds(seconds))
        watch.cancel()
        try? await stream.stopCapture()
        capture.queue.sync {}
        var lines: [String] = []
        for (index, frame) in capture.frames.enumerated() {
            write(frame, to: folder.appendingPathComponent(String(format: "%04d.png", index)))
            lines.append(String(format: "%04d %.1f", index, capture.times[index] * 1000))
        }
        try lines.joined(separator: "\n").write(to: folder.appendingPathComponent("times.txt"), atomically: true, encoding: .utf8)
        print("\(capture.frames.count) frames at up to \(rate) Hz")
    }
}

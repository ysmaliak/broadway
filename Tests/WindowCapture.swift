import AppKit
import ScreenCaptureKit
import CoreImage
import CoreMedia

final class Capture: NSObject, SCStreamOutput, @unchecked Sendable {
    let folder: URL
    let queue = DispatchQueue(label: "window-film")
    let context = CIContext()
    var times: [Double] = []
    var first: Double?
    var frames: [CGImage] = []
    init(_ folder: URL) { self.folder = folder }
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
        if frames.count == 1 { try? Data().write(to: folder.appendingPathComponent("ready")) }
    }
}

@main struct Run {
    static func main() async throws {
        guard CGPreflightScreenCaptureAccess() else { print("SKIP: screen recording permission unavailable"); return }
        let args = CommandLine.arguments
        let pid = Int32(args[1])!
        let folder = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowID == UInt32(args[4])! }) else { print("SKIP: no test window"); return }
        let config = SCStreamConfiguration()
        let scale = args.count > 5 ? Double(args[5]) ?? 1 : 1
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: args.count > 6 ? Int32(args[6]) ?? 60 : 60)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 8
        let capture = Capture(folder)
        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
        try await stream.startCapture()
        for _ in 0..<100 {
            if capture.queue.sync(execute: { !capture.frames.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard capture.queue.sync(execute: { !capture.frames.isEmpty }) else {
            try? await stream.stopCapture()
            print("SKIP: no complete test-window frame")
            return
        }
        try await Task.sleep(for: .seconds(Double(args[3])!))
        try? await stream.stopCapture()
        capture.queue.sync {}
        for (index, frame) in capture.frames.enumerated() {
            let rep = NSBitmapImageRep(cgImage: frame)
            try rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "%04d.png", index)))
        }
        try JSONSerialization.data(withJSONObject: capture.times).write(to: folder.appendingPathComponent("times.json"))
        print("Captured \(capture.times.count) frames of test window \(window.windowID)")
    }
}

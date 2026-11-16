import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit
import Testing

final class WindowFilm: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame { let time: Double; let image: CGImage }

    private let windowID: CGWindowID
    private let size: CGSize
    private let scale: CGFloat
    private var stream: SCStream?
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var started: Double?
    private let queue = DispatchQueue(label: "film")

    @MainActor init(window: NSWindow) {
        windowID = CGWindowID(window.windowNumber)
        size = window.frame.size
        scale = window.backingScaleFactor
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let window = try #require(content.windows.first { $0.windowID == windowID }, "the film finds its window")
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(size.width * scale)
        config.height = Int(size.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.queueDepth = 8
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func peek() async throws -> [Frame] {
        lock.withLock { frames }
    }

    func stop() async throws -> [Frame] {
        try await stream?.stopCapture()
        return lock.withLock { frames }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let pixels = buffer.imageBuffer
        else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let picture = CIContext().createCGImage(image, from: image.extent) else { return }
        let time = buffer.presentationTimeStamp.seconds
        lock.lock()
        if started == nil { started = time }
        frames.append(Frame(time: time - (started ?? time), image: picture))
        lock.unlock()
    }

    @MainActor static func write(_ frames: [Frame], crop: CGRect, window: NSWindow, to base: URL, columns: Int = 4) throws {
        let scale = window.backingScaleFactor
        let cut = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
        let pieces = frames.compactMap { $0.image.cropping(to: cut) }
        guard let first = pieces.first else { try Test.cancel("no frames came") }
        let rows = (pieces.count + columns - 1) / columns
        let width = first.width * columns
        let height = first.height * rows
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        for (index, piece) in pieces.enumerated() {
            let x = (index % columns) * first.width
            let y = height - (index / columns + 1) * first.height
            context.draw(piece, in: CGRect(x: x, y: y, width: first.width, height: first.height))
        }
        if let sheet = context.makeImage() {
            let rep = NSBitmapImageRep(cgImage: sheet)
            try rep.representation(using: .png, properties: [:])?.write(to: base.appendingPathExtension("png"))
        }
        let times = frames.map { String(format: "%.0f", $0.time * 1000) }.joined(separator: " ")
        try times.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }
}

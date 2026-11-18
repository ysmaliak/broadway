import AppKit
import QuartzCore

@MainActor
final class LiveLoadingStrip {
    private static var running: LiveLoadingStrip?

    private let heading: GroupHeadingView
    private let folder: String
    private let seconds: Double
    private let scale: CGFloat
    private let answer: ([String: Any]) -> Void
    private var frames: [[String: Any]] = []
    private var timer: Timer?
    private var start: CFTimeInterval = 0

    static func take(_ heading: GroupHeadingView, to folder: String, seconds: Double, fps: Double, scale: CGFloat,
                     begin: () -> Void, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing, running == nil else { answer(["error": "a strip is being taken"]); return }
        let made = LiveLoadingStrip(heading: heading, folder: folder, seconds: seconds, scale: scale, answer: answer)
        running = made
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        made.start = CACurrentMediaTime()
        begin()
        made.shoot()
        let timer = Timer(timeInterval: 1 / max(1, fps), repeats: true) { _ in
            MainActor.assumeIsolated { LiveLoadingStrip.running?.shoot() }
        }
        RunLoop.main.add(timer, forMode: .common)
        made.timer = timer
    }

    private init(heading: GroupHeadingView, folder: String, seconds: Double, scale: CGFloat, answer: @escaping ([String: Any]) -> Void) {
        self.heading = heading
        self.folder = folder
        self.seconds = seconds
        self.scale = scale
        self.answer = answer
    }

    private func shoot() {
        let now = CACurrentMediaTime() - start
        let status = heading.status as? LiveStatusView
        let ring = heading.liveRing
        var said: [String: Any] = ["t": (now * 1000).rounded() / 1000, "ring": ring != nil, "loading": status?.loads == true,
                                   "opacity": Double(ring?.shownOpacity ?? 0), "turn": ring?.shownTurn ?? 0, "count": heading.showsCount,
                                   "nameEnd": heading.nameHost.frame.maxX, "chevron": heading.benchParts["chevron"]?.frame.minX ?? 0]
        if let name = draw(index: frames.count) { said["file"] = name }
        frames.append(said)
        guard now >= seconds else { return }
        timer?.invalidate()
        timer = nil
        LiveLoadingStrip.running = nil
        answer(["frames": frames, "folder": folder, "scale": Double(scale)])
    }

    private func draw(index: Int) -> String? {
        guard let window = heading.window, let frame = window.contentView?.superview, let root = frame.layer else { return nil }
        let rect = heading.convert(heading.bounds, to: frame).insetBy(dx: 0, dy: -4)
        let wide = Int((rect.width * scale).rounded()), tall = Int((rect.height * scale).rounded())
        guard wide > 0, tall > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: tall, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let pen = context.cgContext
        let ground = (window.backgroundColor ?? .windowBackgroundColor).kitResolved(dark: heading.kitDark).usingColorSpace(.deviceRGB) ?? .white
        pen.setFillColor(red: ground.redComponent, green: ground.greenComponent, blue: ground.blueComponent, alpha: 1)
        pen.fill(CGRect(x: 0, y: 0, width: wide, height: tall))
        pen.scaleBy(x: scale, y: scale)
        pen.translateBy(x: -rect.minX, y: -rect.minY)
        (root.presentation() ?? root).render(in: pen)
        let name = String(format: "%03d.png", index)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        return name
    }
}

import AppKit
import CoreGraphics
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FloatFilmTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names the destination"))
    func filmsControlsInLightAndDark() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SEARCH_FILM"])
        guard CGPreflightScreenCaptureAccess() else { try Test.cancel("screen capture permission is unavailable") }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for dark in [false, true] {
            let float = Float()
            Float.benchAway = NSPoint(x: -20000, y: -20000)
            let page = FilmGround(dark: dark)
            var rate = 1.0
            var through = 0.35
            float.onProgress = { answer in
                var state = FloatMediaState()
                state.current = through * 120
                state.playing = true
                state.rate = rate
                state.timeline = FloatTimeline(ranges: [[0, 120]])
                answer(state)
            }
            float.onSkip = { seconds in through = FloatTime.clamp(through + seconds / 120) }
            float.onSeek = { through = $0 }
            float.onRate = { value, answer in rate = value; answer(value) }
            float.lift(page)
            let number = float.bench("chrome", nil)["window"] as? Int ?? 0
            let window = try #require(NSApp.window(withWindowNumber: number))
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.ignoresMouseEvents = true
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrameOrigin(NSPoint(x: 80, y: 80))
            defer { float.drop(); Float.benchAway = nil }
            _ = float.bench("hover", "on")
            try await Task.sleep(for: .milliseconds(450))
            let film = WindowFilm(window: window)

            try await film.start()
            try await Task.sleep(for: .milliseconds(250))
            _ = float.bench("rate", "1.5")
            try await Task.sleep(for: .milliseconds(650))
            _ = float.bench("press", "forward")
            try await Task.sleep(for: .milliseconds(1350))
            _ = float.bench("hover", "off")
            try await Task.sleep(for: .milliseconds(1100))
            let frames = try await film.stop()

            #expect(frames.count > 10)
            #expect((float.bench("chrome", nil)["rate"] as? Double) == 1.5)
            let name = dark ? "float-dark" : "float-light"
            let chosen = stride(from: 0, to: frames.count, by: max(1, frames.count / 12)).map { frames[$0] }
            try WindowFilm.write(chosen, crop: CGRect(origin: .zero, size: window.frame.size), window: window,
                                 to: destination.appendingPathComponent(name), columns: 4)
            try writeMovie(frames, to: destination.appendingPathComponent(name))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names the destination"))
    func filmsExtrasAtNormalAndMinimumSize() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SEARCH_FILM"])
        guard CGPreflightScreenCaptureAccess() else { try Test.cancel("screen capture permission is unavailable") }
        let destination = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = NSApplication.shared
        for width in [440.0, 260.0] {
            let float = Float()
            Float.benchAway = NSPoint(x: -20000, y: -20000)
            let page = FilmGround(dark: true)
            var state = FloatMediaState()
            state.current = 125
            state.playing = true
            state.rate = 1
            state.timeline = FloatTimeline(ranges: [[100, 220]], live: true)
            state.captions = [FloatCaption(id: 0, name: "English", selected: true), FloatCaption(id: 1, name: "Polski", selected: false)]
            state.chapters = [FloatChapter(start: 100, end: 140, name: "Opening"), FloatChapter(start: 140, end: 220, name: "Middle")]
            state.waiting = true
            float.onProgress = { $0(state) }
            float.lift(page)
            let number = float.bench("chrome", nil)["window"] as? Int ?? 0
            let window = try #require(NSApp.window(withWindowNumber: number))
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.ignoresMouseEvents = true
            window.setFrame(NSRect(x: 80, y: 80, width: width, height: width * 247 / 440), display: false)
            defer { float.drop(); Float.benchAway = nil }
            _ = float.bench("hover", "on")
            try await Task.sleep(for: .milliseconds(500))
            let film = WindowFilm(window: window)

            try await film.start()
            try await Task.sleep(for: .milliseconds(400))
            let frames = try await film.stop()

            #expect(!frames.isEmpty)
            #expect((float.bench("chrome", nil)["live"] as? Bool) == true)
            try WindowFilm.write(Array(frames.prefix(1)), crop: CGRect(origin: .zero, size: window.frame.size), window: window,
                                 to: destination.appendingPathComponent("float-extras-\(Int(width))"), columns: 1)
        }
    }

    private func writeMovie(_ frames: [WindowFilm.Frame], to base: URL) throws {
        let images = base.appendingPathExtension("frames")
        if FileManager.default.fileExists(atPath: images.path) { try FileManager.default.removeItem(at: images) }
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        var last = -1
        for frame in frames {
            let index = Int((frame.time * 30).rounded())
            guard index > last else { continue }
            let data = try #require(NSBitmapImageRep(cgImage: frame.image).representation(using: .png, properties: [:]))
            for missing in (last + 1)...index {
                try data.write(to: images.appendingPathComponent(String(format: "%04d.png", missing)))
            }
            last = index
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["ffmpeg", "-loglevel", "error", "-y", "-framerate", "30", "-i",
                          images.appendingPathComponent("%04d.png").path, "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                          "-c:v", "libx264", "-pix_fmt", "yuv420p", base.appendingPathExtension("mp4").path]
        try task.run()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
    }
}

private final class FilmGround: NSView {
    init(dark: Bool) {
        super.init(frame: .zero)
        wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.colors = dark ? [NSColor.black.cgColor, NSColor.systemIndigo.withAlphaComponent(0.7).cgColor]
            : [NSColor.white.cgColor, NSColor.cyan.withAlphaComponent(0.4).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(gradient)
        for (colour, side, x, y, blur) in [(NSColor.orange.withAlphaComponent(0.6), 130.0, 110.0, -40.0, 0.0),
                                           (NSColor.blue.withAlphaComponent(0.5), 220.0, -150.0, 100.0, 20.0)] {
            let dot = CALayer()
            dot.backgroundColor = colour.cgColor
            dot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            dot.cornerRadius = side / 2
            dot.name = "\(x),\(y)"
            if blur > 0 { dot.filters = [CIFilter(name: "CIGaussianBlur", parameters: ["inputRadius": blur])].compactMap { $0 } }
            layer?.addSublayer(dot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.sublayers?.first?.frame = bounds
        for dot in layer?.sublayers?.dropFirst() ?? [] {
            let parts = (dot.name ?? "0,0").split(separator: ",").compactMap { Double($0) }
            dot.position = CGPoint(x: bounds.midX + parts[0], y: bounds.midY - parts[1])
        }
    }
}

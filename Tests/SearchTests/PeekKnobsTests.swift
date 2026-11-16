import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PeekKnobsTests {
    private var windows: [NSWindow] = []

    init() {
        addTeardownBlock { try await self.tearDown() }
    }

    private func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func knobsAreSeparateCirclesThatStillAct() async throws {
        let box = Pressed()
        let stage = KnobStage(box: box, page: .white)
        let window = makeWindow(stage)
        try await Task.sleep(for: .milliseconds(400))
        let knobs = stage.knobFrame(in: window)

        #expect(abs(knobs.width - 28) <= 0.5)
        #expect(abs(knobs.height - (28 * 3 + 8 * 2)) <= 0.5)

        for (index, wanted) in ["close", "open", "beside"].enumerated() {
            let y = knobs.minY + 14 + CGFloat(index) * 36
            let point = NSPoint(x: knobs.midX, y: window.frame.height - y)
            try await send(.leftMouseDown, at: point, in: window)
            try await send(.leftMouseUp, at: point, in: window)
            try await Task.sleep(for: .milliseconds(150))

            #expect(box.last == wanted)
        }
    }

    @Test func withoutSplitViewThereAreTwoKnobs() {
        let knobs = PeekKnobsView(split: false, close: {}, open: {}, beside: {})

        #expect(knobs.intrinsicContentSize == NSSize(width: 28, height: 28 * 2 + 8))

        knobs.split = true

        #expect(knobs.intrinsicContentSize == NSSize(width: 28, height: 28 * 3 + 8 * 2))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder to film the knobs into"))
    func filmsTheKnobsOverPages() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SEARCH_FILM"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [true, false] {
            for page in KnobStage.Page.allCases {
                let box = Pressed()
                let window = makeWindow(KnobStage(box: box, page: page), dark: dark, filmed: true)
                try await Task.sleep(for: .milliseconds(400))
                let film = WindowFilm(window: window)
                try await film.start()
                try await Task.sleep(for: .milliseconds(300))
                let frames = try await film.stop()
                let last = try #require(frames.last)
                try WindowFilm.write([last], crop: CGRect(origin: .zero, size: window.frame.size), window: window,
                                     to: folder.appendingPathComponent("peek-\(page)-\(dark ? "dark" : "light")"), columns: 1)
            }
        }
    }

    private func makeWindow(_ root: NSView, dark: Bool = true, filmed: Bool = false) -> NSWindow {
        _ = NSApplication.shared
        let place = filmed ? NSPoint(x: 80, y: 80) : NSPoint(x: -20_000, y: -20_000)
        let window = NSWindow(contentRect: NSRect(origin: place, size: CGSize(width: 200, height: 180)),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if filmed {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            window.ignoresMouseEvents = true
        }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = root
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }
}

@MainActor
private final class Pressed {
    var last: String?
}

@MainActor
private final class KnobStage: NSView {
    enum Page: String, CaseIterable, CustomStringConvertible {
        case white, black, colour
        var description: String { rawValue }
    }

    private let knobs: PeekKnobsView
    private let dim = NSView()

    init(box: Pressed, page: Page) {
        knobs = PeekKnobsView(split: true,
                              close: { box.last = "close" },
                              open: { box.last = "open" },
                              beside: { box.last = "beside" })
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 180))
        wantsLayer = true
        switch page {
        case .white, .black:
            layer?.backgroundColor = (page == .white ? NSColor.white : NSColor.black).cgColor
            for line in 0..<9 {
                let text = NSTextField(labelWithString: "Some page text, line \(line + 1)")
                text.font = .systemFont(ofSize: 13)
                text.textColor = page == .white ? .black : .white
                text.frame = NSRect(x: 30, y: 8 + CGFloat(line) * 19, width: 170, height: 17)
                addSubview(text)
            }
        case .colour:
            let gradient = CAGradientLayer()
            gradient.colors = [NSColor.orange.cgColor, NSColor.systemPink.cgColor, NSColor.blue.cgColor]
            gradient.startPoint = CGPoint(x: 0, y: 0)
            gradient.endPoint = CGPoint(x: 1, y: 1)
            gradient.frame = bounds
            gradient.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer?.addSublayer(gradient)
        }
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        addSubview(dim)
        addSubview(knobs)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        dim.frame = bounds
        let size = knobs.intrinsicContentSize
        knobs.frame = NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                             width: size.width, height: size.height)
    }

    func knobFrame(in window: NSWindow) -> CGRect {
        let inWindow = knobs.convert(knobs.bounds, to: nil)
        return CGRect(x: inWindow.minX, y: window.frame.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }
}

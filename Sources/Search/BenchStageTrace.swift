import AppKit
import WebKit

@MainActor
final class StageTrace: NSObject {
    static let shared = StageTrace()
    private var timer: Timer?
    private var observer: CFRunLoopObserver?
    private var due = false
    private var started: CFTimeInterval = 0
    private var samples: [[String: Any]] = []
    private weak var browser: Browser?
    private var film: (path: String, paint: [String: String], frames: [NSBitmapImageRep])?

    static func run(_ ask: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch ask["action"] as? String {
        case "start":
            guard let window = browser.window else { answer(["error": "stagetrace needs a window"]); return }
            if ask["forget"] as? Bool == true { browser.spacePictures.clear() }
            shared.film = (ask["film"] as? String).map { ($0, ask["paint"] as? [String: String] ?? [:], []) }
            shared.start(window, browser: browser)
            answer(["ok": true, "stage": stage(browser) != nil])
        case "stop":
            answer(shared.stop())
        default:
            answer(["error": "stagetrace takes start or stop"])
        }
    }

    static func stage(_ browser: Browser) -> SpaceStageView? {
        browser.window?.contentView?.superview?.kitSubviews(of: SpaceStageView.self).first
    }

    private func start(_ window: NSWindow, browser: Browser) {
        timer?.invalidate()
        samples = []
        self.browser = browser
        started = CACurrentMediaTime()
        let made = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.due = true }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
        LayoutWatch.laid = { [weak self] laid in
            guard let self, laid === self.browser?.window, let root = laid.contentView?.superview, !Self.unlaid(root) else { return }
            self.sample(cycle: true)
        }
        if observer == nil {
            let watching = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_001) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.due, self.timer != nil else { return }
                    self.due = false
                    self.sample()
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), watching, .commonModes)
            observer = watching
        }
        sample()
    }

    private func stop() -> [String: Any] {
        sample()
        timer?.invalidate()
        timer = nil
        LayoutWatch.laid = nil
        var files: [String] = []
        if let film {
            for (index, frame) in film.frames.enumerated() {
                let file = film.path + String(format: "-%03d.png", index)
                if let data = frame.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: file))) != nil {
                    files.append(file)
                }
            }
        }
        film = nil
        return ["samples": samples, "files": files]
    }

    private static func unlaid(_ view: NSView) -> Bool {
        view.needsLayout || view.subviews.contains(where: unlaid)
    }

    private func sample(cycle: Bool = false) {
        guard let browser else { return }
        var shot: [String: Any] = ["t": (CACurrentMediaTime() - started) * 1000, "cycle": cycle,
                                   "space": browser.spaceID.uuidString, "active": browser.active.map(Bench.short) ?? "",
                                   "next": browser.spaceNext ?? -1, "offset": Double(browser.spaceMotion.offset),
                                   "scrolled": Double(StackedProbe.scrolled), "announced": browser.announcement ?? "",
                                   "heads": Dictionary(uniqueKeysWithValues: StackedProbe.headers.map { ($0.key.uuidString, Double($0.value.minY)) })]
        if let stage = Self.stage(browser) {
            shot.merge(stage.traceReport()) { _, new in new }
            let all = browser.tabs + browser.parked.values.flatMap(\.tabs)
            func webs(in view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webs) }
            shot["webs"] = webs(in: stage.content).filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.01 && $0.frame.width > 0 }
                .compactMap { web in all.first { $0.built === web }.map(Bench.short) }
        }
        samples.append(shot)
        if film != nil, !cycle, let frame = render(browser) { film?.frames.append(frame) }
    }

    private func render(_ browser: Browser) -> NSBitmapImageRep? {
        guard let film, film.frames.count < 120, let window = browser.window, let root = window.contentView?.superview?.layer else { return nil }
        guard let frameView = window.contentView?.superview, let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let drawn = root.presentation() ?? root
        let size = root.bounds.size
        let cg = context.cgContext
        let all = browser.tabs + browser.parked.values.flatMap(\.tabs)
        func webs(in view: NSView) -> [WKWebView] { (view as? WKWebView).map { [$0] } ?? view.subviews.flatMap(webs) }
        guard let content = window.contentView else { return rep }
        for web in webs(in: content) where !web.isHiddenOrHasHiddenAncestor {
            guard let tab = all.first(where: { $0.built === web }), let layer = web.layer else { continue }
            let shown = layer.presentation() ?? layer
            var rect = shown.convert(shown.bounds, to: drawn)
            var opacity: CGFloat = 1
            var up: CALayer? = shown
            while let at = up { opacity *= CGFloat(at.opacity); up = at.superlayer }
            if root.isGeometryFlipped { rect.origin.y = size.height - rect.maxY }
            let hex = film.paint[Bench.short(tab)].flatMap { Int($0, radix: 16) } ?? 0x808080
            let colour = NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: opacity)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            if root.isGeometryFlipped { cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1) }
            var clip = CGRect(origin: .zero, size: size)
            var holder: CALayer? = shown.superlayer
            while let at = holder {
                if at.masksToBounds || at.mask != nil { clip = clip.intersection(at.convert(at.bounds, to: drawn)) }
                holder = at.superlayer
            }
            if root.isGeometryFlipped { clip.origin.y = size.height - clip.maxY }
            cg.clip(to: clip)
            colour.setFill()
            rect.fill()
            let title = NSAttributedString(string: tab.title, attributes: [.font: NSFont.systemFont(ofSize: 34, weight: .semibold),
                                                                          .foregroundColor: NSColor.white.withAlphaComponent(opacity)])
            title.draw(at: NSPoint(x: rect.minX + 40, y: rect.maxY - 90))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep
    }
}

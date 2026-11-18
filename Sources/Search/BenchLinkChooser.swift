import AppKit
import QuartzCore

@MainActor
enum BenchLinkChooser {
    static let names = ["link-chooser"]

    static let spaces: [(name: String, symbol: String, colour: String)] = [
        ("Home", "house", "peach"), ("Work", "briefcase", "sky"), ("Sun", "sun.max", "F5D21F"), ("Reading", "book", "sage"),
        ("Travel", "airplane", "sunset"), ("Money", "creditcard", "lagoon"), ("Music", "music.note", "lavender"),
        ("Garden", "leaf", "rose"), ("Night", "moon", "midnight"), ("Plain", "circle", "gray"), ("Ink", "pencil", "onyx"),
        ("Sea", "drop", "cobalt"),
    ]

    static func look(_ colour: String) -> SpaceLook {
        if let swatch = SpaceLook.swatches.first(where: { $0.id == colour }) { return SpaceLook(tone: swatch.tone) }
        return SpaceLook(colours: [colour], intensity: SpaceLook.bold)
    }

    static func make(_ request: [String: Any]) -> NSView? {
        let count = max(0, min(spaces.count, request["spaces"] as? Int ?? 2))
        let address = request["url"] as? String ?? "https://linear.example/team/issue/RDR-214"
        guard let url = URL(string: address) else { return nil }
        var rows: [LinkChooser.Row] = []
        var marks: [UUID: LinkChooserView.Mark] = [:]
        for space in spaces.prefix(count) {
            let id = UUID()
            rows.append(.space(id, name: space.name))
            marks[id] = LinkChooserView.Mark(icon: TabIcon(symbol: space.symbol), look: look(space.colour))
        }
        rows.append(.window)
        if request["peek"] as? Bool ?? true { rows.append(.peek) }
        let view = LinkChooserView(rows: rows, url: url, site: LinkRouter.site(of: url), marks: marks)
        view.lit = request["lit"] as? Int ?? 0
        view.faint = request["faint"] as? Bool ?? false
        view.always = request["always"] as? Bool ?? false
        var size = view.intrinsicContentSize
        if let width = request["width"] as? Double { size.width = CGFloat(width) }
        view.setFrameSize(size)
        view.reveal(view.lit)
        return BenchFloating.sized(view, size)
    }

    private(set) static var motion: [[Double]] = []
    private static var watching: Timer?
    private static var awake: NSObjectProtocol?

    private static func rest() {
        if let awake { ProcessInfo.processInfo.endActivity(awake) }
        awake = nil
    }

    static var card: LinkChooserView? {
        let found = NSApp.windows.filter { $0.contentView is LinkChooserStage }
        return (found.first(where: \.isVisible) ?? found.last)?.contentView?.subviews.first as? LinkChooserView
    }

    static func watch(for seconds: Double) {
        watching?.invalidate()
        rest()
        motion = []
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Reading how the chooser moves")
        let began = CACurrentMediaTime()
        watching = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime() - began
                guard now <= seconds else {
                    timer.invalidate()
                    return rest()
                }
                guard let layer = card?.layer else { return }
                let shown = layer.presentation() ?? layer
                motion.append([(now * 1000).rounded(), (Double(shown.opacity) * 1000).rounded() / 1000,
                               (Double(shown.transform.m11) * 1000).rounded() / 1000])
            }
        }
    }

    static func picture(of browser: Browser, to path: String) -> Bool {
        guard let window = browser.window, let content = window.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        CATransaction.flush()
        let scale: CGFloat = 2
        let size = content.bounds.size
        guard size.width >= 1, size.height >= 1,
              let whole = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: whole) else { return false }
        let pen = context.cgContext
        pen.scaleBy(x: scale, y: scale)
        let ground = Palette.NS.ground.kitResolved(dark: content.kitDark).usingColorSpace(.deviceRGB) ?? .white
        pen.setFillColor(red: ground.redComponent, green: ground.greenComponent, blue: ground.blueComponent, alpha: 1)
        pen.fill(CGRect(origin: .zero, size: size))
        BenchSurfaces.paint(content, into: pen, size: size)
        if let card, let panel = card.window, let stage = panel.contentView {
            stage.layoutSubtreeIfNeeded()
            let inside = content.convert(window.convertFromScreen(panel.frame), from: nil)
            let low = content.isFlipped ? size.height - inside.maxY : inside.minY
            pen.saveGState()
            pen.translateBy(x: inside.minX, y: low)
            BenchSurfaces.paint(stage, into: pen, size: inside.size)
            pen.restoreGState()
        }
        guard let png = whole.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    static func frames(in browser: Browser) -> [String: [Double]] {
        guard let window = browser.window, let content = window.contentView else { return [:] }
        func box(_ rect: NSRect) -> [Double] {
            let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
            return [rect.minX, top, rect.width, rect.height].map { Double($0) }
        }
        var found: [String: [Double]] = ["content": [Double(content.bounds.width), Double(content.bounds.height)]]
        if let card, let panel = card.window {
            let onScreen = panel.convertToScreen(card.convert(card.bounds, to: nil))
            found["chooser"] = box(content.convert(window.convertFromScreen(onScreen), from: nil))
        }
        if let field = content.kitSubviews(of: OmniboxView.self).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
           let glass = field.kitSubviews(of: KitGlass.self).first {
            found["field"] = box(glass.convert(glass.bounds, to: content))
        }
        return found
    }
}

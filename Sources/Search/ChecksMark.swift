import AppKit

enum ChecksTint {
    typealias RGB = (r: Double, g: Double, b: Double)

    enum Pill: Equatable { case none, hover, picked, live, pickedLive }

    static let minimum = 3.0

    static func merged(dark: Bool) -> String { dark ? "A371F7" : "8250DF" }

    static func primer(_ checks: LiveChecks, dark: Bool, merged: Bool = false) -> String {
        if merged { return self.merged(dark: dark) }
        switch (checks, dark) {
        case (.passing, false): return "1A7F37"
        case (.passing, true): return "3FB950"
        case (.failing, false): return "D1242F"
        case (.failing, true): return "F85149"
        case (.pending, false): return "9A6700"
        case (.pending, true): return "D29922"
        }
    }

    static func rgb(_ colour: Oklch) -> RGB {
        let v = colour.inGamut ? colour.rgb : colour.extended
        return (min(1, max(0, v.r)), min(1, max(0, v.g)), min(1, max(0, v.b)))
    }

    static func over(_ ground: RGB, white: Double, alpha: Double) -> RGB {
        let a = min(1, max(0, alpha))
        return (ground.r + (white - ground.r) * a, ground.g + (white - ground.g) * a, ground.b + (white - ground.b) * a)
    }

    static func layers(_ pill: Pill, frame: Bool, dark: Bool, lift: Double) -> [(white: Double, alpha: Double)] {
        let gain = 1 + 0.8 * lift
        func side(_ light: (Double, Double), _ night: (Double, Double)) -> (white: Double, alpha: Double) {
            let pick = dark ? night : light
            return (pick.0, min(1, pick.1 * gain))
        }
        func flat(_ light: Double, _ night: Double, alpha: Double = 1) -> (white: Double, alpha: Double) {
            (dark ? night : light, alpha)
        }
        let tile = frame ? side((0, 0.03), (1, 0.05)) : flat(0.937, 0.30, alpha: 0.55)
        let hover = frame ? side((0, 0.035), (1, 0.06)) : flat(0.965, 0.265)
        let picked = frame ? side((1, 0.28), (1, 0.08)) : flat(0.952, 0.272)
        let wash = frame ? side((1, 0.5), (1, 0.11)) : flat(0.937, 0.30)
        switch pill {
        case .none: return [tile]
        case .hover: return [tile, hover]
        case .picked: return [tile, picked]
        case .live: return [tile, wash]
        case .pickedLive: return [tile, picked, wash]
        }
    }

    static func ground(_ stop: Oklch?, pill: Pill, frame: Bool, dark: Bool, lift: Double) -> RGB {
        let base: RGB = stop.map(rgb) ?? (dark ? (0.22, 0.22, 0.22) : (1, 1, 1))
        return layers(pill, frame: frame && stop != nil, dark: dark, lift: lift).reduce(base) { over($0, white: $1.white, alpha: $1.alpha) }
    }

    static func grounds(_ stops: [Oklch]?, frame: Bool, dark: Bool, lift: Double) -> [RGB] {
        let shown: [Oklch?] = stops?.isEmpty == false ? stops! : [nil]
        let pills: [Pill] = [.none, .hover, .picked, .live, .pickedLive]
        return shown.flatMap { stop in pills.map { ground(stop, pill: $0, frame: frame, dark: dark, lift: lift) } }
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        Paint.ratio(Paint.luminance(a), Paint.luminance(b))
    }

    static func worst(_ mark: Oklch, on grounds: [RGB]) -> Double {
        let colour = rgb(mark)
        return grounds.map { contrast(colour, $0) }.min() ?? 21
    }

    @MainActor private static var memo: [String: Oklch] = [:]

    @MainActor
    static func made(_ checks: LiveChecks, merged: Bool = false, dark: Bool, stops: [Oklch]?, frame: Bool, lift: Double) -> Oklch {
        let key = "\(merged ? "merged" : checks.rawValue)|\(dark)|\(frame)|\(lift)|" + (stops ?? []).map { "\($0.l),\($0.c),\($0.h)" }.joined(separator: ";")
        if let known = memo[key] { return known }
        if memo.count > 256 { memo.removeAll() }
        let made = colour(checks, merged: merged, dark: dark, stops: stops, frame: frame, lift: lift)
        memo[key] = made
        return made
    }

    static func colour(_ checks: LiveChecks, merged: Bool = false, dark: Bool, stops: [Oklch]?, frame: Bool, lift: Double) -> Oklch {
        let start = Oklch(hex: primer(checks, dark: dark, merged: merged))
        let all = grounds(stops, frame: frame, dark: dark, lift: lift)
        var out = start
        var step = 0
        while worst(out, on: all) < minimum, step < 80 {
            step += 1
            let l = min(1, max(0, start.l + Double(step) * (dark ? 0.01 : -0.01)))
            out = Paint.gamut(Oklch(l: l, c: start.c, h: start.h))
            if l <= 0 || l >= 1 { break }
        }
        return out
    }
}

final class ChecksMarkView: NSView {
    static let side: CGFloat = 8
    static let ring: CGFloat = 1

    static func frame(on mark: NSRect) -> NSRect {
        NSRect(x: mark.maxX - side + 1, y: mark.maxY - side + 1, width: side, height: side)
    }

    private let halo = CAShapeLayer()
    private let glyph = CAShapeLayer()
    private(set) var checks: LiveChecks?
    private(set) var merged = false
    private(set) var glyphColour: NSColor?
    private var haloColour: NSColor?
    var tab: Tab.ID? {
        didSet {
            guard tab != oldValue else { return }
            if let oldValue { Bench.checkMarks[oldValue] = nil }
            register()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layerContentsRedrawPolicy = .never
        for shape in [halo, glyph] {
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(shape)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ checks: LiveChecks, merged: Bool = false, glyph: NSColor, halo: NSColor) {
        let changed = checks != self.checks || merged != self.merged
        guard changed || glyph != glyphColour || halo != haloColour else { return }
        if changed, self.checks != nil, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "checks")
        }
        self.checks = checks
        self.merged = merged
        glyphColour = glyph
        haloColour = halo
        setAccessibilityLabel(merged ? PullState.merged : "Checks: \(checks.rawValue)")
        draw()
    }

    override func layout() {
        super.layout()
        draw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for shape in [halo, glyph] { shape.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeBackingProperties()
        register()
    }

    private func register() {
        guard let tab, Store.testing else { return }
        Bench.checkMarks[tab] = { [weak self] in self?.placed() }
    }

    private func placed() -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let rect = convert(bounds, to: nil)
        return CGRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func path(_ checks: LiveChecks, in box: CGRect) -> CGPath {
        let path = CGMutablePath()
        let s = box.width / 9
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * s, y: box.minY + y * s) }
        switch checks {
        case .passing:
            path.move(to: p(1.6, 4.8))
            path.addLine(to: p(3.7, 6.9))
            path.addLine(to: p(7.5, 2.3))
        case .failing:
            path.move(to: p(2.1, 2.1))
            path.addLine(to: p(6.9, 6.9))
            path.move(to: p(6.9, 2.1))
            path.addLine(to: p(2.1, 6.9))
        case .pending:
            path.addEllipse(in: CGRect(x: box.midX - box.width * 0.3125, y: box.midY - box.width * 0.3125,
                                       width: box.width * 0.625, height: box.width * 0.625))
        }
        return path
    }

    private func draw() {
        guard let checks, let glyphColour, let haloColour else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = bounds
        let line: CGFloat = checks == .failing ? 1.5 : 1.6
        let cgGlyph = glyphColour.cgColor
        let cgHalo = haloColour.cgColor
        for shape in [halo, glyph] { shape.frame = box }
        glyph.path = Self.path(checks, in: box)
        halo.path = CGPath(ellipseIn: box.insetBy(dx: -Self.ring, dy: -Self.ring), transform: nil)
        halo.fillColor = cgHalo
        halo.strokeColor = nil
        halo.lineWidth = 0
        if checks == .pending {
            glyph.fillColor = cgGlyph
            glyph.strokeColor = nil
            glyph.lineWidth = 0
        } else {
            glyph.fillColor = nil
            glyph.strokeColor = cgGlyph
            glyph.lineWidth = line
        }
        CATransaction.commit()
    }
}

extension NSColor {
    static func checks(_ rgb: ChecksTint.RGB) -> NSColor {
        NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }
}

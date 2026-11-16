import AppKit

struct PageGround: Equatable {
    static let lightSoft = 0.5
    static let lightChroma = 0.6
    static let darkStep = 0.05
    static let darkFloor = 0.2
    static let darkCeiling = 0.34
    static let darkChroma = 0.75
    static let accentContrast = 3.0
    static let accentChroma = 0.04

    var stops: [Oklch]
    var dark: Bool
    var accent: Oklch
    var accentInkLight: Bool

    var average: Oklch { Paint.Ground(stops: stops, lightInk: dark).average }
    var colours: [NSColor] { LookBlend.three(Paint.Ground(stops: stops, lightInk: dark)) }
    var flat: NSColor { average.color }
    var accentColour: NSColor { accent.color }
    var accentInk: NSColor { accentInkLight ? .white : KitBrand.night }
    var appearance: NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }

    static func soften(_ stop: Oklch, dark: Bool) -> Oklch {
        let soft = dark
            ? Oklch(l: min(max(stop.l + darkStep, darkFloor), darkCeiling), c: stop.c * darkChroma, h: stop.h)
            : Oklch(l: stop.l + (1 - stop.l) * lightSoft, c: stop.c * lightChroma, h: stop.h)
        return Paint.settled(Paint.gamut(soft, wide: !stop.inGamut), lightInk: dark)
    }

    static func accent(for look: SpaceLook.Tone, on ground: Oklch, dark: Bool) -> Oklch {
        let base: Oklch
        if let preset = look.preset, preset.swatch == 0 {
            base = Oklch(hex: KitBrand.blue.hexString)
        } else if let vivid = look.picked.map({ Oklch(hex: $0) }).max(by: { $0.c < $1.c }), vivid.c >= accentChroma {
            base = vivid
        } else {
            base = Oklch(l: dark ? Paint.lightInk : 0.25, c: 0, h: 0)
        }
        return readable(base, on: ground, dark: dark)
    }

    static func readable(_ colour: Oklch, on ground: Oklch, dark: Bool) -> Oklch {
        var out = colour
        for _ in 0..<120 where contrast(out, ground) < accentContrast {
            out = Paint.gamut(Oklch(l: min(1, max(0, out.l + (dark ? 0.01 : -0.01))), c: colour.c, h: colour.h), wide: !colour.inGamut)
        }
        return out
    }

    static func contrast(_ a: Oklch, _ b: Oklch) -> Double {
        Paint.ratio(Paint.luminance(a.inGamut ? a.rgb : a.extended), Paint.luminance(b.inGamut ? b.rgb : b.extended))
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: PageGround] = [:]

    static func made(_ look: SpaceLook, dark: Bool) -> PageGround {
        let tone = look.side(dark: dark)
        let shade = look.shade(dark: dark)
        let key = "\(tone.colour)|\(tone.custom ?? "")|\(tone.colours ?? [])|\(tone.strength)|\(shade)"
        lock.lock()
        if let known = cache[key] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let ground = tone.ground(dark: shade)
        let pageDark = ground.lightInk
        let stops = ground.stops.map { soften($0, dark: pageDark) }
        let average = Paint.Ground(stops: stops, lightInk: pageDark).average
        let accent = accent(for: tone, on: average, dark: pageDark)
        let white = contrast(accent, Oklch(l: 1, c: 0, h: 0))
        let night = contrast(accent, Oklch(hex: KitBrand.night.hexString))
        let made = PageGround(stops: stops, dark: pageDark, accent: accent, accentInkLight: white >= night)
        lock.lock()
        if cache.count > 256 { cache.removeAll() }
        cache[key] = made
        lock.unlock()
        return made
    }
}

extension SpaceLook {
    func page(dark: Bool) -> PageGround {
        PageGround.made(self, dark: dark)
    }
}

extension Browser {
    func pageLook(in space: UUID?) -> SpaceLook {
        if isPrivate { return self.space.look ?? SpaceLook.onyx }
        guard let space, space != spaceID else { return makingSpace ? draftLook : self.space.look ?? SpaceLook() }
        return spaces.first { $0.id == space }?.look ?? SpaceLook()
    }
}

extension NSView {
    var groundCanvas: (frame: CGRect, size: CGSize)? {
        guard let content = window?.contentView else { return nil }
        let size = content.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        let frame = convert(bounds, to: content)
        let top = content.isFlipped ? frame.minY : size.height - frame.maxY
        return (CGRect(x: frame.minX, y: top, width: frame.width, height: frame.height), size)
    }
}

final class PageGroundView: NSView {
    private let paint = GroundPaintView()
    private(set) var shown: PageGround?

    var corner: CGFloat = 0 {
        didSet {
            guard corner != oldValue else { return }
            layer?.cornerRadius = corner
            layer?.masksToBounds = corner > 0
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        addSubview(paint)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ ground: PageGround) {
        guard ground != shown else { return }
        shown = ground
        render()
    }

    override func layout() {
        super.layout()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        render()
    }

    private func render() {
        guard let shown else { return }
        Still.set {
            paint.frame = bounds
            paint.show(shown.colours, canvas: groundCanvas)
        }
    }
}

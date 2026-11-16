import AppKit
import QuartzCore

struct KitTint: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var boost: Double
    var saturation: Double = 0

    static func of(_ stops: [Oklch]?) -> KitTint? {
        guard let stops, !stops.isEmpty else { return nil }
        let rgb = stops.map(\.rgb)
        let n = Double(rgb.count)
        let ground = NSColor(srgbRed: rgb.map(\.r).reduce(0, +) / n, green: rgb.map(\.g).reduce(0, +) / n,
                             blue: rgb.map(\.b).reduce(0, +) / n, alpha: 1)
        let saturation = Double(ground.saturationComponent)
        guard saturation >= 0.08 else { return nil }
        let hue = NSColor(hue: ground.hueComponent, saturation: CGFloat(min(0.8, saturation)), brightness: 1, alpha: 1)
            .usingColorSpace(.sRGB) ?? .white
        let mix = 0.7 * saturation
        func toward(_ v: CGFloat) -> Double { 1 - mix + mix * Double(v) }
        return KitTint(red: toward(hue.redComponent), green: toward(hue.greenComponent), blue: toward(hue.blueComponent),
                       boost: 1 + 0.6 * saturation, saturation: saturation)
    }

    func gained(_ gain: Double) -> KitTint {
        var made = self
        made.boost *= 1 + gain * saturation
        return made
    }
}

struct KitTone: Equatable {
    var base: NSColor
    var kind: KitInk.Kind = .plain
    var opacity: Double = 1
    var tint: KitTint?

    func resolved(_ ink: KitInk, dark: Bool) -> NSColor {
        let made = ink.color(base, kind, opacity: opacity, dark: dark)
        guard let tint, let plain = made.usingColorSpace(.sRGB), plain.redComponent > 0.9, plain.greenComponent > 0.9,
              plain.blueComponent > 0.9 else { return made }
        return NSColor(srgbRed: tint.red, green: tint.green, blue: tint.blue, alpha: min(1, plain.alphaComponent * tint.boost))
    }

    func opacity(_ value: Double) -> KitTone {
        KitTone(base: base, kind: kind, opacity: opacity * value, tint: tint)
    }

    static let clear = KitTone(base: .clear)
    static let ink = KitTone(base: Palette.NS.ink, kind: .ink)
    static let strong = KitTone(base: Palette.NS.inkStrong, kind: .ink)
    static let title = KitTone(base: KitColor.title, kind: .title)
    static let muted = KitTone(base: Palette.NS.muted, kind: .quiet)
    static let faint = KitTone(base: Palette.NS.faint, kind: .stronger(0.6))
    static let hairline = KitTone(base: Palette.NS.hairline, kind: .stronger(0.6))
    static let ground = KitTone(base: Palette.NS.ground)
    static let unsafe = KitTone(base: Palette.NS.unsafe)
}

struct KitGreys: Equatable {
    var wash: KitTone
    let hover: KitTone
    let picked: KitTone
    let tile: KitTone
    let pinLive: KitTone
    let edge: KitTone
    var raised: KitTone
    var raisedFoot: KitTone
    var raisedEdge: KitTone
    var raisedRim: KitTone
    var raisedRamp: KitTone = .clear
    var card: KitTone
    var cardEdge: KitTone
    var slabEdge: KitTone = .hairline
    var well: KitTone = KitTone(base: Palette.NS.wash)
    var wellRim: KitTone = .clear
    var dot: KitTone = KitTone(base: .controlAccentColor)
    var onFrame = false

    private static func side(_ color: NSColor) -> KitTone { KitTone(base: color, kind: .stronger(0.8)) }

    static let white = KitGreys(wash: KitTone(base: Palette.NS.wash), hover: KitTone(base: Palette.NS.hover),
                                picked: KitTone(base: Palette.NS.picked), tile: KitTone(base: Palette.NS.wash, opacity: 0.55),
                                pinLive: KitTone(base: Palette.NS.pinLive), edge: .hairline,
                                raised: KitTone(base: Palette.NS.wash, opacity: 0.6),
                                raisedFoot: KitTone(base: Palette.NS.wash, opacity: 0.42), raisedEdge: KitTone(base: Palette.NS.panelRaisedEdge),
                                raisedRim: KitTone(base: Palette.NS.raisedRim), card: KitTone(base: Palette.NS.wash, opacity: 0.55),
                                cardEdge: KitTone(base: Palette.NS.panelRaisedEdge))
    static let frame = KitGreys(wash: side(Palette.NS.sideWash), hover: side(Palette.NS.sideHover),
                                picked: side(Palette.NS.sidePicked), tile: side(Palette.NS.sideTile),
                                pinLive: side(Palette.NS.sidePinLive), edge: side(Palette.NS.sideEdge),
                                raised: side(Palette.NS.sideRaised),
                                raisedFoot: side(Palette.NS.sideRaised), raisedEdge: side(Palette.NS.sideTileEdge),
                                raisedRim: side(Palette.NS.sideRaisedRim), card: side(Palette.NS.sideCard),
                                cardEdge: side(Palette.NS.sideCardEdge), slabEdge: side(Palette.NS.sideSlabEdge),
                                well: side(Palette.NS.sideWell), wellRim: side(Palette.NS.sideWellRim),
                                dot: KitTone(base: Palette.NS.sideDot), onFrame: true)

    func card(_ plate: KitPlate) {
        plate.fill = onFrame ? nil : card
        plate.foot = nil
        plate.stroke = onFrame ? nil : cardEdge
        plate.rim = nil
        plate.ramp = nil
    }

    func lit(by stops: [Oklch]?) -> KitGreys {
        guard onFrame, let tint = KitTint.of(stops) else { return self }
        var made = self
        for path in [\KitGreys.wash, \.raised, \.raisedFoot, \.raisedEdge, \.raisedRim, \.raisedRamp, \.card, \.cardEdge, \.slabEdge,
                     \.well, \.wellRim]
            as [WritableKeyPath<KitGreys, KitTone>] {
            made[keyPath: path].tint = tint
        }
        made.wash.tint = tint.gained(SideLook.slabVivid)
        made.well.tint = tint.gained(SideLook.slabVivid)
        var rim = tint.gained(SideLook.slabVivid)
        rim.boost = min(rim.boost, tint.boost * 1.25)
        made.slabEdge.tint = rim
        made.wellRim.tint = rim
        return made
    }

    static func on(frame: Bool) -> KitGreys { frame ? .frame : .white }

    func hover(_ ink: KitInk, dark: Bool) -> NSColor {
        onFrame ? ink.color(Palette.NS.sideHover, .stronger(0.8), dark: dark) : Palette.NS.hover.kitResolved(dark: dark)
    }

    func tile(_ ink: KitInk, dark: Bool) -> NSColor {
        onFrame ? ink.color(Palette.NS.sideTile, .stronger(0.8), dark: dark) : Palette.NS.wash.kitResolved(dark: dark).withAlphaComponent(0.55)
    }
}

final class KitRimLayer: CAGradientLayer {
    private let ring = CAShapeLayer()

    override init() {
        super.init()
        ring.fillColor = nil
        ring.strokeColor = NSColor.black.cgColor
        mask = ring
        quiet()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func quiet() {
        let none: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull(),
                                        "hidden": NSNull(), "path": NSNull(), "lineWidth": NSNull(), "frame": NSNull()]
        actions = none
        ring.actions = none
    }

    func place(_ box: CGRect, radius: CGFloat, hair: CGFloat, carried: CAAnimation? = nil) {
        frame = box
        ring.frame = CGRect(origin: .zero, size: box.size)
        ring.lineWidth = hair
        ring.path = Self.outline(box.size, radius: radius, hair: hair)
        locations = Self.reach(box.size, radius: radius)
        guard let carried = carried as? CABasicAnimation, let from = (carried.fromValue as? NSValue)?.sizeValue,
              from != box.size else { return }
        func follow(_ key: String, on target: CALayer, from start: Any?, to end: Any?) {
            guard let made = carried.copy() as? CABasicAnimation else { return }
            made.keyPath = key
            made.fromValue = start
            made.toValue = end
            target.add(made, forKey: key)
        }
        let centre = { (size: CGSize, origin: CGPoint) in CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2) }
        Self.follow(carried, on: self, from: from, to: box.size, origin: box.origin)
        follow("bounds.size", on: ring, from: NSValue(size: from), to: NSValue(size: box.size))
        follow("position", on: ring, from: NSValue(point: centre(from, .zero)), to: NSValue(point: centre(box.size, .zero)))
        follow("path", on: ring, from: Self.outline(from, radius: radius, hair: hair), to: ring.path)
        follow("locations", on: self, from: Self.reach(from, radius: radius), to: locations)
    }

    static func follow(_ carried: CABasicAnimation, on target: CALayer, from: CGSize, to: CGSize, origin: CGPoint) {
        let centre = { (size: CGSize) in CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2) }
        for (key, start, end) in [("bounds.size", NSValue(size: from), NSValue(size: to)),
                                  ("position", NSValue(point: centre(from)), NSValue(point: centre(to)))] {
            guard let made = carried.copy() as? CABasicAnimation else { continue }
            made.keyPath = key
            made.fromValue = start
            made.toValue = end
            target.add(made, forKey: key)
        }
    }

    private static func outline(_ size: CGSize, radius: CGFloat, hair: CGFloat) -> CGPath? {
        let inset = CGRect(origin: .zero, size: size).insetBy(dx: hair / 2, dy: hair / 2)
        guard inset.width > 0, inset.height > 0 else { return nil }
        let r = max(0, min(radius - hair / 2, min(inset.width, inset.height) / 2))
        return CGPath(roundedRect: inset, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    private static func reach(_ size: CGSize, radius: CGFloat) -> [NSNumber] {
        let corner = size.height > 0 ? min(0.999, (radius + 2) / size.height) : 0.999
        return [0, NSNumber(value: Double(corner)), 1]
    }

    func paint(_ colour: NSColor?, ramp: NSColor? = nil, fromTop: Bool) {
        let lift = ramp.flatMap { $0.alphaComponent > 0 ? $0 : nil }
        guard let colour, colour.alphaComponent > 0 || lift != nil else {
            isHidden = true
            return
        }
        isHidden = false
        startPoint = CGPoint(x: 0.5, y: fromTop ? 0 : 1)
        endPoint = CGPoint(x: 0.5, y: fromTop ? 1 : 0)
        let corner = CGFloat((locations?.dropFirst().first)?.doubleValue ?? 0.25)
        let ramped = lift?.alphaComponent ?? 0
        let top = 1 - (1 - colour.alphaComponent) * (1 - ramped)
        let tone = colour.alphaComponent > 0 ? colour : lift ?? colour
        colors = [tone.withAlphaComponent(top).cgColor, tone.withAlphaComponent(ramped * (1 - corner)).cgColor,
                  tone.withAlphaComponent(0).cgColor]
    }
}

final class KitPlate: NSView {
    var fill: KitTone? { didSet { if fill != oldValue { needsDisplay = true } } }
    var foot: KitTone? { didSet { if foot != oldValue { needsDisplay = true } } }
    var stroke: KitTone? { didSet { if stroke != oldValue { needsDisplay = true } } }
    var rim: KitTone? { didSet { if rim != oldValue { needsDisplay = true; needsLayout = true } } }
    var ramp: KitTone? { didSet { if ramp != oldValue { needsDisplay = true } } }
    var hairline = false { didSet { if hairline != oldValue { needsDisplay = true } } }
    var strokeWidth: CGFloat = 1 { didSet { if strokeWidth != oldValue { needsDisplay = true } } }
    var radius: CGFloat = 0 { didSet { if radius != oldValue { needsDisplay = true } } }
    var corners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] {
        didSet { if corners != oldValue { needsDisplay = true } }
    }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }
    var lift: KitShadow? { didSet { if lift != oldValue { clipsToBounds = lift == nil; needsDisplay = true; needsLayout = true } } }

    init(fill: KitTone? = nil, stroke: KitTone? = nil, radius: CGFloat = 0) {
        self.fill = fill
        self.stroke = stroke
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        let dark = kitDark
        if let foot, let fill {
            layer.backgroundColor = nil
            let shade = fillLayer ?? {
                let made = CAGradientLayer()
                made.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "hidden": NSNull(),
                                "cornerRadius": NSNull(), "maskedCorners": NSNull(), "frame": NSNull()]
                made.startPoint = CGPoint(x: 0.5, y: 0)
                made.endPoint = CGPoint(x: 0.5, y: 1)
                made.cornerCurve = .continuous
                layer.insertSublayer(made, at: 0)
                fillLayer = made
                return made
            }()
            shade.isHidden = false
            shade.colors = [fill.resolved(ink, dark: dark).cgColor, foot.resolved(ink, dark: dark).cgColor]
            shade.frame = bounds
            shade.cornerRadius = min(radius, min(bounds.width, bounds.height) / 2)
            shade.maskedCorners = corners
        } else {
            fillLayer?.isHidden = true
            layer.backgroundColor = fill?.resolved(ink, dark: dark).cgColor
        }
        layer.borderColor = stroke?.resolved(ink, dark: dark).cgColor
        let scale = window?.backingScaleFactor ?? 2
        layer.borderWidth = stroke == nil ? 0 : hairline ? 1 / max(1, scale) : strokeWidth
        layer.cornerRadius = min(radius, min(bounds.width, bounds.height) / 2)
        layer.cornerCurve = .continuous
        layer.maskedCorners = corners
        cast(lift, on: layer, dark: dark)
        if let rim {
            let shine = rimLayer ?? {
                let made = KitRimLayer()
                layer.addSublayer(made)
                rimLayer = made
                return made
            }()
            shine.place(bounds, radius: layer.cornerRadius, hair: ring(scale))
            shine.paint(rim.resolved(ink, dark: dark), ramp: ramp?.resolved(ink, dark: dark), fromTop: dark)
        } else {
            rimLayer?.isHidden = true
        }
    }

    private func ring(_ scale: CGFloat) -> CGFloat {
        stroke == nil || hairline ? 1 / max(1, scale) : strokeWidth
    }

    private var rimLayer: KitRimLayer?
    private var fillLayer: CAGradientLayer?

    private func cast(_ shadow: KitShadow?, on layer: CALayer, dark: Bool) {
        let opacity = shadow.map { dark ? $0.dark : $0.light } ?? 0
        guard let shadow, opacity > 0 else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
            return
        }
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = shadow.radius
        layer.shadowOffset = CGSize(width: 0, height: shadow.y)
        shape(layer)
    }

    private func shape(_ layer: CALayer) {
        guard layer.shadowOpacity > 0 else { return }
        let r = min(radius, min(bounds.width, bounds.height) / 2)
        let path = KitPath.continuous(bounds, radius: r)
        guard layer.shadowPath != path else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.shadowPath = path
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        guard let layer else { return }
        let wanted = min(radius, min(bounds.width, bounds.height) / 2)
        if layer.cornerRadius != wanted {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.cornerRadius = wanted
            CATransaction.commit()
        }
        shape(layer)
        let rim = rimLayer.flatMap { $0.isHidden ? nil : $0 }
        let shade = fillLayer.flatMap { $0.isHidden ? nil : $0 }
        if rim != nil || shade != nil {
            let moving = layer.animation(forKey: "bounds.size") as? CABasicAnimation
            let seen = moving.map { [$0.fromValue as? NSValue, $0.toValue as? NSValue, NSValue(size: CGSize(width: $0.duration, height: 0))] }
            let fresh = seen != nil && seen != carried ? moving : nil
            carried = seen
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            rim?.place(bounds, radius: wanted, hair: ring(window?.backingScaleFactor ?? 2), carried: fresh)
            if let shade {
                let from = shade.bounds.size
                shade.frame = bounds
                shade.cornerRadius = wanted
                if let fresh, let start = (fresh.fromValue as? NSValue)?.sizeValue, start != bounds.size {
                    KitRimLayer.follow(fresh, on: shade, from: start, to: bounds.size, origin: bounds.origin)
                } else if from != bounds.size {
                    shade.removeAllAnimations()
                }
            }
            CATransaction.commit()
        }
    }

    private var carried: [NSValue?]?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsLayout = true }
    }
}

extension NSView {
    func kitSetFrame(_ frame: NSRect) {
        let snapped = kitSnapped(frame)
        guard self.frame != snapped else { return }
        self.frame = snapped
    }

    func kitSnapped(_ rect: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded(.toNearestOrAwayFromZero) / scale }
        return NSRect(x: snap(rect.minX), y: snap(rect.minY), width: snap(rect.width), height: snap(rect.height))
    }
}

extension NSView {
    func kitScale(_ scale: CGFloat, curve: KitCurve, around anchor: CGPoint? = nil) {
        guard let layer else { return }
        let point = anchor ?? CGPoint(x: bounds.midX, y: bounds.midY)
        var matrix = CATransform3DMakeTranslation(point.x, point.y, 0)
        matrix = CATransform3DScale(matrix, scale, scale, 1)
        matrix = CATransform3DTranslate(matrix, -point.x, -point.y, 0)
        layer.kitAnimate("transform", to: NSValue(caTransform3D: matrix), curve: curve)
    }
}

import AppKit
import QuartzCore

final class SpaceLookBackdrop: NSView {
    private let wash = CAGradientLayer()
    private let warm = CAGradientLayer()
    private let cool = CAGradientLayer()
    private let focus: CGPoint
    private let echo: CGPoint?
    private let spread: CGFloat
    var bright: Bool { didSet { if bright != oldValue { paint() } } }

    init(focus: CGPoint, echo: CGPoint? = nil, spread: CGFloat = 0.8, bright: Bool = false) {
        self.focus = focus
        self.echo = echo
        self.spread = spread
        self.bright = bright
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(wash)
        layer?.addSublayer(cool)
        layer?.addSublayer(warm)
        wash.locations = [0, 0.55, 1]
        wash.startPoint = CGPoint(x: 1 - focus.x, y: 1 - focus.y)
        wash.endPoint = focus
        warm.type = .radial
        warm.locations = [0, 0.3, 0.65, 1]
        cool.type = .radial
        cool.locations = [0, 0.4, 1]
        cool.isHidden = echo == nil
        paint()
        setAccessibilityElement(false)
    }

    private func paint() {
        let colour = OnboardingSceneView.colour
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.colors = (bright ? [0x1B1F52, 0x4B3FA8, 0x8A5BD6] : [0x07080F, 0x131830, 0x2A2E55]).map { colour($0, 1) }
        warm.colors = bright
            ? [colour(0xFFF0F6, 1), colour(0xFF7AB8, 0.9), colour(0xB45CFF, 0.4), colour(0xB45CFF, 0)]
            : [colour(0xFFF1DE, 0.95), colour(0xFF9A6B, 0.7), colour(0xF0508C, 0.28), colour(0xF0508C, 0)]
        cool.colors = bright
            ? [colour(0xD6FBFF, 1), colour(0x35C8F0, 0.85), colour(0x2F7BFF, 0)]
            : [colour(0xC9F1FF, 0.9), colour(0x5C8DFF, 0.55), colour(0x5C8DFF, 0)]
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        wash.frame = bounds
        warm.frame = bounds
        cool.frame = bounds
        let reach = max(bounds.height, 1) * spread
        let across = reach / max(bounds.width, 1)
        let down = reach / max(bounds.height, 1)
        warm.startPoint = focus
        warm.endPoint = CGPoint(x: focus.x + across, y: focus.y + down)
        if let echo {
            cool.startPoint = echo
            cool.endPoint = CGPoint(x: echo.x + across * 0.85, y: echo.y + down * 0.85)
        }
        CATransaction.commit()
    }
}

final class SpaceLookWindow: KitFlippedView {
    static let size = CGSize(width: 280, height: 168)

    private(set) var look: SpaceLook
    private let shade = CALayer()
    private let shadeHole = CAShapeLayer()
    private let body = KitFlippedView()
    private let backdrop = SpaceLookBackdrop(focus: CGPoint(x: 0.08, y: 0.95))
    private let ground: SpaceGroundView
    private let face = KitFlippedView()
    private let rim = CALayer()
    private let pageShade = CALayer()
    private let page = CALayer()
    private let lights: [CALayer] = (0..<3).map { _ in CALayer() }
    private let rows: [CALayer] = (0..<4).map { _ in CALayer() }

    init(look: SpaceLook = SpaceLook()) {
        self.look = look
        ground = SpaceGroundView(look: look)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        ground.spansWindow = false
        ground.staged = true
        body.wantsLayer = true
        face.wantsLayer = true
        layer?.addSublayer(shade)
        shade.mask = shadeHole
        shadeHole.fillRule = .evenOdd
        addSubview(body)
        body.addSubview(backdrop)
        body.addSubview(ground)
        body.addSubview(face)
        backdrop.isHidden = !look.showsThrough
        backdrop.bright = look.glass
        for part in lights + rows + [pageShade, page] { face.layer?.addSublayer(part) }
        layer?.addSublayer(rim)
        rim.zPosition = 1
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func show(_ wanted: SpaceLook, animated: Bool = true) {
        guard wanted != look else { return }
        look = wanted
        if animated, !Motion.reduced, window != nil { body.layer?.kitTransition(.easeOut(0.28)) }
        backdrop.isHidden = !wanted.showsThrough
        backdrop.bright = wanted.glass
        ground.blend = LookBlend(from: wanted)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let scale = min(bounds.width / Self.size.width, bounds.height / Self.size.height)
        let box = CGRect(x: (bounds.width - Self.size.width * scale) / 2, y: (bounds.height - Self.size.height * scale) / 2,
                         width: Self.size.width * scale, height: Self.size.height * scale)
        let corner = 14 * scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let outline = CGPath(roundedRect: box, cornerWidth: corner, cornerHeight: corner, transform: nil)
        shade.frame = bounds
        WelcomeShadow.apply(shade, opacity: 0.32, radius: 18 * scale, y: 10 * scale, path: outline)
        let hole = CGMutablePath()
        hole.addRect(bounds.insetBy(dx: -80, dy: -80))
        hole.addPath(outline)
        shadeHole.frame = bounds
        shadeHole.path = hole
        body.frame = box
        body.layer?.cornerRadius = corner
        body.layer?.cornerCurve = .continuous
        body.layer?.masksToBounds = true
        backdrop.frame = body.bounds
        ground.frame = body.bounds
        face.frame = body.bounds
        rim.frame = box
        rim.cornerRadius = corner
        rim.cornerCurve = .continuous
        rim.borderWidth = 1
        for (index, light) in lights.enumerated() {
            light.frame = CGRect(x: (10 + CGFloat(index) * 10) * scale, y: 10 * scale, width: 6 * scale, height: 6 * scale)
            light.cornerRadius = 3 * scale
        }
        for (index, row) in rows.enumerated() {
            let width: CGFloat = index == 1 ? 58 : 50 - CGFloat(index * 6)
            row.frame = CGRect(x: 10 * scale, y: (26 + CGFloat(index) * 15) * scale, width: width * scale, height: 9 * scale)
            row.cornerRadius = 4.5 * scale
        }
        let sheet = CGRect(x: 84 * scale, y: 10 * scale, width: 186 * scale, height: 148 * scale)
        page.frame = sheet
        page.cornerRadius = 8 * scale
        page.cornerCurve = .continuous
        pageShade.frame = sheet
        WelcomeShadow.apply(pageShade, opacity: 0.18, radius: 6 * scale, y: 2 * scale,
                            path: CGPath(roundedRect: CGRect(origin: .zero, size: sheet.size), cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil))
        CATransaction.commit()
    }

    override func updateLayer() {
        let dark = kitDark
        let lightInk = look.inkLight(dark: dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (light, colour) in zip(lights, [NSColor.systemRed, .systemYellow, .systemGreen]) {
            light.backgroundColor = colour.withAlphaComponent(0.85).kitResolved(dark: dark).cgColor
        }
        for (index, row) in rows.enumerated() {
            row.backgroundColor = NSColor(white: lightInk ? 1 : 0, alpha: index == 1 ? 0.55 : 0.22).cgColor
        }
        page.backgroundColor = NSColor.white.cgColor
        rim.borderColor = NSColor(white: lightInk ? 1 : 0, alpha: lightInk ? 0.14 : 0.1).cgColor
        CATransaction.commit()
    }
}

final class SpaceLookTile: KitHoverView {
    let offer: SpaceLook.Offer
    var picked: Bool { didSet { if picked != oldValue { restyle(animated: true) } } }
    var ring: NSColor { didSet { needsDisplay = true } }
    var action: () -> Void

    private let body = KitFlippedView()
    private let clip = KitFlippedView()
    private let ground: SpaceGroundView
    private let label: KitLabel
    private let edge = CALayer()
    private let halo = CALayer()
    private let gloss = CAGradientLayer()
    private let rim = CAGradientLayer()
    private let rimLine = CAShapeLayer()

    static let corner: CGFloat = 10
    static let reach: CGFloat = 4

    var name: String { offer.name }
    var look: SpaceLook { offer.look }
    var glazed: Bool { offer.look.glass && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    init(offer: SpaceLook.Offer, picked: Bool, ring: NSColor = KitColor.ink, action: @escaping () -> Void) {
        self.offer = offer
        self.picked = picked
        self.ring = ring
        self.action = action
        ground = SpaceGroundView(look: offer.look)
        label = KitLabel(offer.name, font: .systemFont(ofSize: 11, weight: .semibold))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        ground.spansWindow = false
        ground.staged = true
        body.wantsLayer = true
        clip.wantsLayer = true
        addSubview(body)
        body.addSubview(clip)
        if offer.look.showsThrough {
            let backdrop = offer.look.glass
                ? SpaceLookBackdrop(focus: CGPoint(x: 0.8, y: 0.12), echo: CGPoint(x: 0.1, y: 0.95), spread: 1.25, bright: true)
                : SpaceLookBackdrop(focus: CGPoint(x: 0.97, y: 0.03), spread: 0.7)
            backdrop.autoresizingMask = [.width, .height]
            clip.addSubview(backdrop)
        }
        ground.glassCorner = Self.corner
        clip.addSubview(ground)
        clip.addSubview(label)
        if offer.look.glass {
            clip.layer?.addSublayer(gloss)
            clip.layer?.addSublayer(rim)
            rim.mask = rimLine
            rimLine.fillColor = nil
            rimLine.strokeColor = CGColor(gray: 1, alpha: 1)
            rimLine.lineWidth = 2
            gloss.zPosition = 1
            rim.zPosition = 1
            gloss.startPoint = CGPoint(x: 0.5, y: 0)
            gloss.endPoint = CGPoint(x: 0.5, y: 1)
            gloss.locations = [0, 0.55]
            rim.startPoint = CGPoint(x: 0, y: 0)
            rim.endPoint = CGPoint(x: 1, y: 1)
            rim.locations = [0, 0.45, 0.7, 1]
        }
        label.setAccessibilityElement(false)
        body.layer?.addSublayer(edge)
        body.layer?.addSublayer(halo)
        edge.borderWidth = 1
        halo.borderWidth = 2
        kitAccess(id: "look.\(offer.id)", label: offer.name, role: .radioButton)
        restyle(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func hoverChanged() { restyle(animated: true) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.frame = bounds
        clip.frame = bounds
        clip.layer?.cornerRadius = Self.corner
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        ground.frame = clip.bounds
        gloss.frame = clip.bounds
        rim.frame = clip.bounds
        rimLine.frame = clip.bounds
        rimLine.path = CGPath(roundedRect: clip.bounds, cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil)
        gloss.isHidden = !glazed
        rim.isHidden = !glazed
        edge.frame = bounds
        edge.cornerRadius = Self.corner
        edge.cornerCurve = .continuous
        halo.frame = bounds.insetBy(dx: -Self.reach, dy: -Self.reach)
        halo.cornerRadius = Self.corner + Self.reach
        halo.cornerCurve = .continuous
        CATransaction.commit()
        let text = label.intrinsicContentSize
        label.frame = NSRect(x: 9, y: bounds.height - 7 - text.height, width: min(text.width, bounds.width - 18), height: text.height)
        restyle(animated: false)
    }

    override func updateLayer() {
        let dark = kitDark
        let lightInk = offer.look.inkLight(dark: dark)
        label.color = NSColor(white: lightInk ? 1 : 0, alpha: lightInk ? 0.92 : 0.8)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.borderColor = NSColor(white: lightInk ? 1 : 0, alpha: lightInk ? 0.16 : 0.1).cgColor
        gloss.colors = [CGColor(gray: 1, alpha: dark ? 0.16 : 0.45), CGColor(gray: 1, alpha: 0)]
        rim.colors = [dark ? 0.6 : 0.95, dark ? 0.1 : 0.3, 0, dark ? 0.22 : 0.5].map { CGColor(gray: 1, alpha: $0) }
        halo.borderColor = ring.kitResolved(dark: dark).cgColor
        CATransaction.commit()
    }

    private func restyle(animated: Bool) {
        setAccessibilityValue(picked ? 1 : 0)
        let moves = animated && !Motion.reduced
        halo.kitAnimate("opacity", to: picked ? 1 : 0, curve: moves ? .spring(KitSpring(response: 0.3, damping: 0.72)) : .none)
        guard let layer = body.layer else { return }
        let grow: CGFloat = hovering && !picked ? 1.04 : 1
        layer.kitAnimate("transform", to: NSValue(caTransform3D: LookInk.scale(grow, in: body.bounds)),
                         curve: moves ? .spring(KitSpring(response: 0.25, damping: 0.7)) : .none)
    }
}

final class SpaceLookPicker: KitFlippedView {
    static let tile = CGSize(width: 90, height: 50)
    static let gap = CGSize(width: 8, height: 9)

    let columns: Int
    let tile: CGSize
    let gap: CGSize
    var picked: String { didSet { if picked != oldValue { mark() } } }
    var pick: (String) -> Void
    private(set) var tiles: [SpaceLookTile] = []

    init(offers: [SpaceLook.Offer] = SpaceLook.offers, picked: String, columns: Int = 3, tile: CGSize = SpaceLookPicker.tile,
         gap: CGSize = SpaceLookPicker.gap, ring: NSColor = KitColor.ink, pick: @escaping (String) -> Void) {
        self.columns = max(1, columns)
        self.tile = tile
        self.gap = gap
        self.picked = picked
        self.pick = pick
        super.init(frame: .zero)
        for offer in offers {
            let made = SpaceLookTile(offer: offer, picked: offer.id == picked, ring: ring) { [weak self] in
                guard let self else { return }
                self.picked = offer.id
                self.pick(offer.id)
            }
            tiles.append(made)
            addSubview(made)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Look")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var look: SpaceLook? { SpaceLook.offered(picked) }

    override var intrinsicContentSize: NSSize {
        let rows = (tiles.count + columns - 1) / columns
        let across = min(columns, max(tiles.count, 1))
        return NSSize(width: CGFloat(across) * tile.width + CGFloat(across - 1) * gap.width,
                      height: CGFloat(rows) * tile.height + CGFloat(max(rows - 1, 0)) * gap.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        for (index, made) in tiles.enumerated() {
            made.frame = NSRect(x: CGFloat(index % columns) * (tile.width + gap.width), y: CGFloat(index / columns) * (tile.height + gap.height),
                                width: tile.width, height: tile.height)
        }
    }

    private func mark() {
        for made in tiles { made.picked = made.offer.id == picked }
    }
}

final class SpaceLookChooser: KitFlippedView {
    static let gap: CGFloat = 20

    let preview: SpaceLookWindow
    let picker: SpaceLookPicker
    private var custom: SpaceLook

    init(picked: String, custom: SpaceLook = SpaceLook(), ring: NSColor = KitColor.ink, pick: @escaping (String) -> Void) {
        self.custom = custom
        preview = SpaceLookWindow(look: SpaceLook.offered(picked) ?? custom)
        picker = SpaceLookPicker(picked: picked, columns: 2, ring: ring, pick: pick)
        super.init(frame: .zero)
        addSubview(preview)
        addSubview(picker)
        let chosen = picker.pick
        picker.pick = { [weak self] id in
            self?.show(picked: id)
            chosen(id)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var picked: String { picker.picked }
    var look: SpaceLook { preview.look }

    func show(picked: String, custom: SpaceLook? = nil, animated: Bool = true) {
        if let custom { self.custom = custom }
        picker.picked = picked
        preview.show(SpaceLook.offered(picked) ?? self.custom, animated: animated)
    }

    override var intrinsicContentSize: NSSize {
        let tiles = picker.intrinsicContentSize
        return NSSize(width: SpaceLookWindow.size.width + Self.gap + tiles.width, height: max(SpaceLookWindow.size.height, tiles.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        let tiles = picker.intrinsicContentSize
        preview.frame = NSRect(x: 0, y: (bounds.height - SpaceLookWindow.size.height) / 2, width: SpaceLookWindow.size.width, height: SpaceLookWindow.size.height)
        picker.frame = NSRect(x: preview.frame.maxX + Self.gap, y: (bounds.height - tiles.height) / 2, width: tiles.width, height: tiles.height)
    }
}

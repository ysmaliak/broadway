import AppKit

struct WindowScene: Equatable {
    var dark: Bool? = nil
    var auto = false
    var right = false
    var card = true
    var tint: SpaceLook? = nil
    var newTabPage = false
    var floatingField = false
    var stacked: Bool? = nil

    @MainActor static func live(_ prefs: Preferences, _ look: SpaceLook?) -> WindowScene {
        var scene = WindowScene()
        scene.right = prefs.tabsLayout == .right
        scene.card = prefs.cards
        scene.tint = look
        return scene
    }
}

enum PictureScene: Equatable {
    case window(WindowScene)
    case appIcon(String)
}

struct PictureTones {
    let dark: Bool
    let tint: SpaceLook?

    private var ground: Paint.Ground { (tint ?? SpaceLook()).ground(dark: dark) }
    var lightInk: Bool { ground.lightInk }
    var ink: NSColor { NSColor(white: lightInk ? Paint.lightInk : Paint.darkInk, alpha: 1) }
    var frame: [NSColor] { LookBlend.three(ground).map { $0.kitResolved(dark: dark) } }
    var page: NSColor { Palette.NS.ground.kitResolved(dark: dark) }
    var pageInk: NSColor { Palette.NS.ink.kitResolved(dark: dark) }
    var raised: NSColor { Palette.NS.sidePicked.kitResolved(dark: lightInk) }
    var well: NSColor { ink.withAlphaComponent(lightInk ? 0.1 : 0.07) }
    var floating: NSColor { Palette.NS.fieldPanel.kitResolved(dark: dark) }
    var edge: NSColor { Palette.NS.pictureEdge.kitResolved(dark: dark) }
}

enum PictureArt {
    static let sites: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.33, blue: 0.3, alpha: 1),
        NSColor(srgbRed: 0.26, green: 0.52, blue: 0.96, alpha: 1),
        NSColor(srgbRed: 0.2, green: 0.72, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.65, blue: 0.2, alpha: 1),
        NSColor(srgbRed: 0.6, green: 0.42, blue: 0.95, alpha: 1),
    ]
    static let hero = [NSColor(srgbRed: 0.55, green: 0.72, blue: 0.98, alpha: 1), NSColor(srgbRed: 0.75, green: 0.6, blue: 0.95, alpha: 1)]
    static let alert = NSColor(srgbRed: 0.95, green: 0.33, blue: 0.3, alpha: 1)

    static func fill(_ context: CGContext, _ rect: CGRect, _ color: NSColor, radius: CGFloat = 0) {
        context.setFillColor(color.cgColor)
        if radius <= 0 {
            context.fill(rect)
            return
        }
        context.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        context.fillPath()
    }

    static func capsule(_ context: CGContext, _ rect: CGRect, _ color: NSColor) {
        fill(context, rect, color, radius: min(rect.width, rect.height) / 2)
    }

    static func dot(_ context: CGContext, center: CGPoint, side: CGFloat, _ color: NSColor) {
        context.setFillColor(color.cgColor)
        context.fillEllipse(in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
    }

    static func ring(_ context: CGContext, center: CGPoint, side: CGFloat, width: CGFloat, _ color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.strokeEllipse(in: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
    }

    static func stroke(_ context: CGContext, _ rect: CGRect, radius: CGFloat, width: CGFloat, _ color: NSColor) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        let inset = rect.insetBy(dx: width / 2, dy: width / 2)
        context.addPath(CGPath(roundedRect: inset, cornerWidth: max(0, min(radius - width / 2, inset.width / 2)),
                               cornerHeight: max(0, min(radius - width / 2, inset.height / 2)), transform: nil))
        context.strokePath()
    }

    static func gradient(_ context: CGContext, _ rect: CGRect, _ colors: [NSColor]) {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cg = colors.map { ($0.usingColorSpace(.sRGB) ?? $0).cgColor } as CFArray
        guard let made = CGGradient(colorsSpace: space, colors: cg, locations: nil) else { return }
        context.saveGState()
        context.clip(to: rect)
        context.drawLinearGradient(made, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
        context.restoreGState()
    }

    static func clip(_ context: CGContext, _ rect: CGRect, radius: CGFloat) {
        context.addPath(CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2), transform: nil))
        context.clip()
    }

    static func text(_ string: String, font: NSFont, color: NSColor, center: CGPoint) {
        let words = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = words.size()
        words.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
    }

    static func text(_ string: String, font: NSFont, color: NSColor, left: CGFloat, middle: CGFloat) -> CGFloat {
        let words = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color])
        let size = words.size()
        words.draw(at: NSPoint(x: left, y: middle - size.height / 2))
        return size.width
    }
}

enum MiniWindow {
    static func draw(_ scene: WindowScene, in rect: CGRect, dark: Bool, context: CGContext) {
        if scene.auto {
            frame(scene, in: rect, tones: PictureTones(dark: false, tint: scene.tint), context: context)
            context.saveGState()
            context.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            context.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            context.closePath()
            context.clip()
            frame(scene, in: rect, tones: PictureTones(dark: true, tint: scene.tint), context: context)
            context.restoreGState()
        } else {
            frame(scene, in: rect, tones: PictureTones(dark: scene.dark ?? dark, tint: scene.tint), context: context)
        }
    }

    private static func frame(_ scene: WindowScene, in rect: CGRect, tones: PictureTones, context: CGContext) {
        let u = rect.height / 60
        PictureArt.gradient(context, rect, tones.frame)
        let width = 26 * u
        let column = CGRect(x: scene.right ? rect.maxX - width : rect.minX, y: rect.minY, width: width, height: rect.height)
        let rest = CGRect(x: scene.right ? rect.minX : rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height)
        drawColumn(scene, in: column, u: u, tones: tones, context: context)
        drawPage(scene, in: rest, u: u, tones: tones, context: context)
        for index in 0..<3 {
            let center = CGPoint(x: rect.minX + 3 * u + 1.2 * u + CGFloat(index) * 3.8 * u, y: rect.minY + 3.2 * u + 1.2 * u)
            PictureArt.dot(context, center: center, side: 2.4 * u, tones.ink.withAlphaComponent(0.22))
        }
    }

    private static func drawColumn(_ scene: WindowScene, in column: CGRect, u: CGFloat, tones: PictureTones, context: CGContext) {
        let left = column.minX + 2 * u
        let inner = column.width - 4 * u
        var y = column.minY + (scene.right ? 2 : 6) * u + 2 * u
        let pill = CGRect(x: left, y: y, width: inner, height: 4.6 * u)
        PictureArt.capsule(context, pill, tones.well)
        PictureArt.dot(context, center: CGPoint(x: pill.minX + 1.6 * u + 0.8 * u, y: pill.midY), side: 1.6 * u, tones.ink.withAlphaComponent(0.35))
        PictureArt.capsule(context, CGRect(x: pill.minX + 4.2 * u, y: pill.midY - 0.8 * u, width: 7 * u, height: 1.6 * u),
                           tones.ink.withAlphaComponent(0.45))
        y = pill.maxY + 2 * u
        if let stacked = scene.stacked {
            spaces(stacked: stacked, left: left, inner: inner, top: y, bottom: column.maxY, u: u, tones: tones, context: context)
            return
        }
        let lengths: [CGFloat] = [11, 9, 12, 7]
        for index in 0..<4 {
            let row = CGRect(x: left, y: y, width: inner, height: 5.4 * u)
            if index == 0 { PictureArt.fill(context, row, tones.raised, radius: 1.6 * u) }
            let glyph = CGRect(x: row.minX + 1.4 * u, y: row.minY + 1 * u, width: 3.4 * u, height: 3.4 * u)
            PictureArt.fill(context, glyph, PictureArt.sites[index], radius: 0.9 * u)
            PictureArt.capsule(context, CGRect(x: glyph.maxX + 1.6 * u, y: row.midY - 0.9 * u, width: lengths[index] * u, height: 1.8 * u),
                               tones.ink.withAlphaComponent(index == 0 ? 0.55 : 0.25))
            y = row.maxY + 2 * u
        }
    }

    private static func spaces(stacked: Bool, left: CGFloat, inner: CGFloat, top: CGFloat, bottom: CGFloat, u: CGFloat,
                               tones: PictureTones, context: CGContext) {
        var y = top
        let marks = [PictureArt.sites[1], PictureArt.sites[3], PictureArt.sites[2]]
        let lengths: [[CGFloat]] = [[11, 8], [10, 12], [9, 7]]
        for space in 0..<(stacked ? 3 : 1) {
            let strong = space == 0
            PictureArt.dot(context, center: CGPoint(x: left + 2 * u, y: y + 1.6 * u), side: 2.6 * u, marks[space].withAlphaComponent(strong ? 1 : 0.6))
            PictureArt.capsule(context, CGRect(x: left + 4.8 * u, y: y + 0.6 * u, width: (strong ? 9 : 7) * u, height: 2 * u),
                               tones.ink.withAlphaComponent(strong ? 0.7 : 0.32))
            y += 5 * u
            for index in 0..<(stacked ? 2 : 5) {
                let row = CGRect(x: left, y: y, width: inner, height: 4.6 * u)
                guard row.maxY < bottom - (stacked ? 0 : 6 * u) else { break }
                if strong, index == 0 { PictureArt.fill(context, row, tones.raised, radius: 1.5 * u) }
                let glyph = CGRect(x: row.minX + 1.4 * u, y: row.minY + 0.9 * u, width: 2.8 * u, height: 2.8 * u)
                PictureArt.fill(context, glyph, PictureArt.sites[(space * 2 + index) % PictureArt.sites.count], radius: 0.8 * u)
                let length = lengths[space][index % 2] + (index > 1 ? 1 : 0)
                PictureArt.capsule(context, CGRect(x: glyph.maxX + 1.6 * u, y: row.midY - 0.8 * u, width: length * u, height: 1.6 * u),
                                   tones.ink.withAlphaComponent(strong && index == 0 ? 0.55 : 0.25))
                y = row.maxY + 1.2 * u
            }
            y += 1.6 * u
        }
        guard !stacked else { return }
        let dots = bottom - 4 * u
        for index in 0..<3 {
            PictureArt.dot(context, center: CGPoint(x: left + inner / 2 + CGFloat(index - 1) * 4 * u, y: dots), side: 2.2 * u,
                           marks[index].withAlphaComponent(index == 0 ? 1 : 0.45))
        }
    }

    private static func drawPage(_ scene: WindowScene, in rest: CGRect, u: CGFloat, tones: PictureTones, context: CGContext) {
        let inset = scene.card ? 2.4 * u : 0
        let radius = scene.card ? 3 * u : 0
        let page = rest.insetBy(dx: inset, dy: inset)
        if scene.card {
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: 0.3 * u), blur: 1.6 * u, color: NSColor(white: 0, alpha: 0.1).cgColor)
            PictureArt.fill(context, page, tones.page, radius: radius)
            context.restoreGState()
        }
        context.saveGState()
        PictureArt.clip(context, page, radius: radius)
        PictureArt.fill(context, page, tones.page)
        let ink = tones.pageInk
        if scene.newTabPage {
            newTab(in: page, u: u, ink: ink, context: context)
        } else {
            article(in: page, u: u, ink: ink, context: context)
        }
        if scene.floatingField {
            PictureArt.fill(context, page, NSColor(white: 0, alpha: 0.12))
            floatingField(in: page, u: u, tones: tones, context: context)
        }
        context.restoreGState()
        if scene.card {
            PictureArt.stroke(context, page, radius: radius, width: 0.5, tones.ink.withAlphaComponent(0.08))
        } else {
            let x = scene.right ? rest.maxX - 0.3 * u : rest.minX
            PictureArt.fill(context, CGRect(x: x, y: rest.minY, width: max(0.5, 0.3 * u), height: rest.height), tones.ink.withAlphaComponent(0.1))
        }
    }

    private static func article(in page: CGRect, u: CGFloat, ink: NSColor, context: CGContext) {
        let left = page.minX + 4 * u
        var y = page.minY + 4 * u
        PictureArt.capsule(context, CGRect(x: left, y: y, width: 16 * u, height: 2.4 * u), ink.withAlphaComponent(0.7))
        y += 2.4 * u + 2 * u
        let hero = CGRect(x: left, y: y, width: page.width - 8 * u, height: 12 * u)
        context.saveGState()
        PictureArt.clip(context, hero, radius: 1.6 * u)
        context.setAlpha(0.9)
        PictureArt.gradient(context, hero, PictureArt.hero)
        context.restoreGState()
        y = hero.maxY + 2 * u
        for width in [34, 30, 36, 22] as [CGFloat] {
            PictureArt.capsule(context, CGRect(x: left, y: y, width: min(width * u, page.width - 8 * u), height: 1.5 * u), ink.withAlphaComponent(0.18))
            y += 1.5 * u + 2 * u
        }
    }

    private static func newTab(in page: CGRect, u: CGFloat, ink: NSColor, context: CGContext) {
        let total = 4.6 * u + 3 * u + 4 * u
        let top = page.midY - total / 2
        let field = CGRect(x: page.midX - 15 * u, y: top, width: 30 * u, height: 4.6 * u)
        PictureArt.capsule(context, field, ink.withAlphaComponent(0.08))
        PictureArt.ring(context, center: CGPoint(x: field.minX + 1.6 * u + 1 * u, y: field.midY), side: 2 * u,
                        width: max(0.5, 0.3 * u), ink.withAlphaComponent(0.4))
        let row = 4 * 4 * u + 3 * 2 * u
        for index in 0..<4 {
            let tile = CGRect(x: page.midX - row / 2 + CGFloat(index) * 6 * u, y: field.maxY + 3 * u, width: 4 * u, height: 4 * u)
            PictureArt.fill(context, tile, PictureArt.sites[index], radius: 1.2 * u)
        }
    }

    private static func floatingField(in page: CGRect, u: CGFloat, tones: PictureTones, context: CGContext) {
        let height = 2.4 * u * 2 + 2.2 * u + 3 * (1.8 * u + 2.2 * u)
        let card = CGRect(x: page.midX - 15 * u, y: page.midY - 4 * u - height / 2, width: 30 * u, height: height)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 0.8 * u), blur: 4 * u, color: NSColor(white: 0, alpha: 0.25).cgColor)
        PictureArt.fill(context, card, tones.floating, radius: 2.6 * u)
        context.restoreGState()
        let ink = tones.pageInk
        let left = card.minX + 2.4 * u
        var y = card.minY + 2.4 * u
        PictureArt.ring(context, center: CGPoint(x: left + 1.1 * u, y: y + 1.1 * u), side: 2.2 * u, width: max(0.5, 0.3 * u), ink.withAlphaComponent(0.5))
        PictureArt.capsule(context, CGRect(x: left + 3.4 * u, y: y + 0.3 * u, width: 10 * u, height: 1.6 * u), ink.withAlphaComponent(0.5))
        y += 2.2 * u
        for (index, width) in ([16, 12, 14] as [CGFloat]).enumerated() {
            y += 1.8 * u
            PictureArt.fill(context, CGRect(x: left, y: y, width: 2.2 * u, height: 2.2 * u), PictureArt.sites[index], radius: 0.6 * u)
            PictureArt.capsule(context, CGRect(x: left + 3.4 * u, y: y + 0.4 * u, width: width * u, height: 1.4 * u), ink.withAlphaComponent(0.22))
            y += 2.2 * u
        }
    }
}

enum RowArt {
    static func draw(_ scene: PictureScene, in rect: CGRect, dark: Bool, context: CGContext) {
        switch scene {
        case .window(let window): MiniWindow.draw(window, in: rect, dark: dark, context: context)
        case .appIcon(let name): appIcon(AppIcon.named(name), tones: PictureTones(dark: dark, tint: nil), in: rect, context: context)
        }
    }

    private static func appIcon(_ icon: AppIcon, tones: PictureTones, in rect: CGRect, context: CGContext) {
        PictureArt.gradient(context, rect, tones.frame)
        guard let picture = MainActor.assumeIsolated({ AppIconShown.picture(icon) }) else { return }
        let side = min(rect.height, rect.width) - 4
        let frame = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        picture.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                     hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }
}

final class SettingsPictureView: NSView {
    static let fadeKey = kCATransition
    static let fade: CFTimeInterval = 0.15

    let radius: CGFloat
    private(set) var scene: PictureScene

    init(_ scene: PictureScene, radius: CGFloat = 7) {
        self.scene = scene
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ next: PictureScene) {
        guard next != scene else { return }
        scene = next
        if window != nil, !Motion.reduced, let layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Self.fade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            display()
            layer.add(fade, forKey: Self.fadeKey)
        } else {
            needsDisplay = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = kitDark
        context.saveGState()
        PictureArt.clip(context, bounds, radius: radius)
        RowArt.draw(scene, in: bounds, dark: dark, context: context)
        context.restoreGState()
        PictureArt.stroke(context, bounds, radius: radius, width: 1 / max(window?.backingScaleFactor ?? 2, 1),
                          Palette.NS.pictureEdge.kitResolved(dark: dark))
    }
}

final class SettingsPictureChoice: NSView {
    struct Option: Equatable {
        let title: String
        var picture: PictureScene

        init(title: String, scene: WindowScene) {
            self.title = title
            picture = .window(scene)
        }

        init(title: String, picture: PictureScene) {
            self.title = title
            self.picture = picture
        }

        var scene: WindowScene? {
            guard case .window(let scene) = picture else { return nil }
            return scene
        }
    }

    static let picture = NSSize(width: 108, height: 72)
    static let radius: CGFloat = 10
    static let spacing: CGFloat = 10
    static let nameGap: CGFloat = 6
    static let ringWidth: CGFloat = 2
    static let ringGap: CGFloat = 3
    static let font = NSFont.systemFont(ofSize: 11)

    private(set) var options: [Option]
    var picked: Int { didSet { if picked != oldValue { paint(animated: true) } } }
    private(set) var focused: Int
    var pick: ((Int) -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }

    private(set) var cards: [Card] = []
    private var pressed: Int?
    private var keyed = false

    init(_ label: String, options: [Option], picked: Int, pick: ((Int) -> Void)? = nil) {
        self.options = options
        self.picked = picked
        focused = picked
        self.pick = pick
        super.init(frame: .zero)
        cards = options.enumerated().map { index, option in
            let card = Card(option, owner: self, index: index)
            addSubview(card)
            return card
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(label)
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { KitFocus.takes(isEnabled) }
    override var focusRingType: NSFocusRingType { get { .none } set {} }

    override var intrinsicContentSize: NSSize {
        let count = CGFloat(cards.count)
        let name = ceil(Self.font.ascender - Self.font.descender + Self.font.leading) + 2
        return NSSize(width: count * Self.picture.width + max(0, count - 1) * Self.spacing,
                      height: Self.picture.height + Self.nameGap + name)
    }

    override func layout() {
        super.layout()
        for (index, card) in cards.enumerated() {
            let x = CGFloat(index) * (Self.picture.width + Self.spacing)
            card.frame = NSRect(x: x, y: 0, width: Self.picture.width, height: bounds.height)
        }
    }

    func show(scenes: [WindowScene]) {
        for (index, scene) in scenes.enumerated() where cards.indices.contains(index) {
            options[index].picture = .window(scene)
            cards[index].picture.show(.window(scene))
        }
    }

    override func becomeFirstResponder() -> Bool {
        keyed = true
        focused = picked
        paint(animated: false)
        return true
    }

    override func resignFirstResponder() -> Bool {
        keyed = false
        paint(animated: false)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 123, 126: move(to: focused - 1)
        case 124, 125: move(to: focused + 1)
        default:
            if KitFocus.presses(event) {
                choose(focused)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = index(at: event)
        paint(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            paint(animated: false)
        }
        guard isEnabled, let at = index(at: event), at == pressed else { return }
        focused = at
        choose(at)
    }

    override func accessibilityChildren() -> [Any]? { cards }

    func choose(_ at: Int) {
        guard cards.indices.contains(at), at != picked else { return }
        picked = at
        pick?(at)
    }

    private func move(to at: Int) {
        guard cards.indices.contains(at), at != focused else { return }
        focused = at
        paint(animated: false)
        if let card = cards.first(where: { $0.index == at }) {
            NSAccessibility.post(element: card, notification: .focusedUIElementChanged)
        }
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return cards.firstIndex { $0.frame.contains(point) }
    }

    private func paint(animated: Bool) {
        for (index, card) in cards.enumerated() {
            card.show(on: index == picked, focused: keyed && index == focused && index != picked, pressed: pressed == index,
                      animated: animated && window != nil && !Motion.reduced)
        }
    }

    final class Card: NSView {
        let picture: SettingsPictureView
        let name: SettingsText
        let index: Int
        private let ring = KitBox(fill: nil, stroke: LookInk.primary(0.85),
                                  corners: .radius(SettingsPictureChoice.radius + SettingsPictureChoice.ringGap))
        private let focus = KitBox(fill: nil, stroke: LookInk.softRing,
                                   corners: .radius(SettingsPictureChoice.radius + SettingsPictureChoice.ringGap))
        private let title: String
        private weak var owner: SettingsPictureChoice?

        init(_ option: Option, owner: SettingsPictureChoice, index: Int) {
            picture = SettingsPictureView(option.picture, radius: SettingsPictureChoice.radius)
            name = SettingsText(option.title, font: SettingsPictureChoice.font, color: .secondaryLabelColor)
            name.alignment = .center
            name.translatesAutoresizingMaskIntoConstraints = true
            title = option.title
            self.owner = owner
            self.index = index
            super.init(frame: .zero)
            for box in [ring, focus] {
                box.strokeWidth = SettingsPictureChoice.ringWidth
                box.alphaValue = 0
                addSubview(box)
            }
            addSubview(picture)
            addSubview(name)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            let size = SettingsPictureChoice.picture
            picture.frame = NSRect(origin: .zero, size: size)
            let outset = SettingsPictureChoice.ringGap + SettingsPictureChoice.ringWidth
            ring.frame = picture.frame.insetBy(dx: -outset, dy: -outset)
            focus.frame = ring.frame
            let top = size.height + SettingsPictureChoice.nameGap
            name.frame = NSRect(x: -SettingsPictureChoice.spacing / 2, y: top,
                                width: size.width + SettingsPictureChoice.spacing, height: max(0, bounds.height - top))
        }

        func show(on: Bool, focused: Bool, pressed: Bool, animated: Bool) {
            name.textColor = on ? .labelColor : .secondaryLabelColor
            name.font = .systemFont(ofSize: SettingsPictureChoice.font.pointSize, weight: on ? .semibold : .regular)
            focus.alphaValue = focused ? 1 : 0
            picture.alphaValue = pressed && !on ? 0.85 : 1
            let alpha: CGFloat = on ? 1 : 0
            guard ring.alphaValue != alpha else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = SettingsPictureView.fade
                    ring.animator().alphaValue = alpha
                }
            } else {
                ring.alphaValue = alpha
            }
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
        override func accessibilityLabel() -> String? { title }
        override func accessibilityValue() -> Any? { owner?.picked == index ? 1 : 0 }
        override func accessibilityParent() -> Any? { owner }
        override func accessibilityPerformPress() -> Bool {
            guard let owner, owner.isEnabled, owner.picked != index else { return false }
            owner.choose(index)
            return true
        }
    }
}

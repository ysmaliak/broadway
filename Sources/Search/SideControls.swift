import AppKit
import QuartzCore

final class CloseMarkView: NSView {
    var symbol = "xmark" { didSet { if symbol != oldValue { symbolChanged(oldValue) } } }
    var side: CGFloat = Metrics.closeSide { didSet { if side != oldValue { restyle() } } }
    var over = false { didSet { if over != oldValue { paint(curve: Motion.kitQuick) } } }
    var pressed = false { didSet { if pressed != oldValue { press() } } }
    var swaps = false
    var ink: KitInk = .flat { didSet { if ink != oldValue { paint(curve: .none) } } }
    var face: KitSymbol.Style? { didSet { if face != oldValue { restyle() } } }

    private let ground = KitPlate()
    private let mark = KitSymbol("xmark")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(ground)
        addSubview(mark)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    private static func glyph(_ side: CGFloat) -> CGFloat { min(13.5, max(9, side * 0.44)) }

    static func style(side: CGFloat) -> KitSymbol.Style {
        KitSymbol.Style(size: glyph(side), weight: side >= 24 ? IconLook.weight : IconLook.control)
    }

    private static var inks: [CGFloat: CGFloat] = [:]

    static func ink(side: CGFloat) -> CGFloat {
        if let known = inks[side] { return known }
        let style = style(side: side)
        let width = KitGlyph.image("xmark", style).map { KitGlyph.ink(of: $0).width } ?? style.size
        inks[side] = width
        return width
    }

    private func restyle() {
        mark.style = face ?? Self.style(side: side)
        ground.radius = Metrics.closeCorner(side)
        invalidateIntrinsicContentSize()
        needsLayout = true
        paint(curve: .none)
    }

    private func symbolChanged(_ old: String) {
        if swaps { mark.swap(to: symbol, curve: isHiddenOrHasHiddenAncestor ? .none : Motion.kitQuick) } else { mark.name = symbol }
    }

    private func paint(curve: KitCurve) {
        if curve.animates {
            ground.layer?.kitTransition(curve)
            mark.layer?.kitTransition(curve)
        }
        mark.ink = ink
        mark.tint = Palette.NS.ink
        mark.opacity = over ? 0.96 : 0.62
        ground.ink = ink
        ground.fill = KitTone.ink.opacity(over ? (pressed ? 0.2 : 0.13) : 0)
    }

    private func press() {
        paint(curve: Motion.kitQuick)
        kitScale(pressed && !Motion.reduced ? 0.92 : 1, curve: pressed ? Motion.kitQuick : Motion.kitSettle)
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        ground.kitSetFrame(box)
        mark.kitSetFrame(box)
    }
}

class CloseSpotView: NSView {
    var symbol: String {
        get { mark.symbol }
        set { mark.symbol = newValue }
    }
    var side: CGFloat {
        get { mark.side }
        set { mark.side = newValue; invalidateIntrinsicContentSize(); needsLayout = true }
    }
    var armed = true { didSet { if !armed { mark.over = false } else { mark.over = inside } } }
    var label = "Close Tab" { didSet { setAccessibilityLabel(label) } }
    var swaps: Bool {
        get { mark.swaps }
        set { mark.swaps = newValue }
    }
    var ink: KitInk {
        get { mark.ink }
        set { mark.ink = newValue }
    }
    var face: KitSymbol.Style? {
        get { mark.face }
        set { mark.face = newValue }
    }
    var act: () -> Void = {}
    var ready: () -> Bool = { true }
    var onHover: ((Bool) -> Void)?

    let mark = CloseMarkView()
    private var pressing = false { didSet { mark.pressed = pressing } }
    private var inside = false {
        didSet {
            guard inside != oldValue else { return }
            mark.over = inside && armed
            onHover?(inside)
        }
    }

    init(symbol: String = "xmark", side: CGFloat = Metrics.closeSide, label: String = "Close Tab", swaps: Bool = false,
         act: @escaping () -> Void = {}) {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(mark)
        mark.symbol = symbol
        mark.side = side
        mark.swaps = swaps
        self.label = label
        self.act = act
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: mark.side, height: mark.side) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }

    override func layout() {
        super.layout()
        mark.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        settle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.settle() }
    }

    func settle() {
        guard let window, !isHiddenOrHasHiddenAncestor else {
            inside = false
            return
        }
        inside = bounds.contains(convert(KitHoverView.pointer(in: window), from: nil))
    }

    override func mouseEntered(with event: NSEvent) { inside = true }
    override func mouseExited(with event: NSEvent) {
        inside = false
        pressing = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard armed, let event = NSApp.currentEvent else { return nil }
        let left = event.type == .leftMouseDown || event.type == .leftMouseUp || event.type == .leftMouseDragged
        guard left, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { pressing = ready() }

    override func mouseDragged(with event: NSEvent) {
        mark.pressed = pressing && bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard pressing else { return }
        pressing = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
    }
}

final class TalkMarkView: NSView {
    static let gap: CGFloat = 1.5

    var thing: AnyHashable?
    var count = 0 { didSet { if count != oldValue { changed() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { glyph.ink = ink; number.ink = ink } } }

    private let glyph = KitSymbol("bubble.left", style: KitSymbol.Style(size: Metrics.liveLine - 0.5), tint: Palette.NS.muted)
    private let number = KitLabel("", font: .monospacedDigitSystemFont(ofSize: Metrics.liveLine, weight: .medium), color: Palette.NS.muted)
    private var carried: (NSRect, NSRect)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        glyph.opacity = SideLook.bylineTone
        number.opacity = SideLook.bylineTone
        number.isHidden = true
        number.setAccessibilityElement(false)
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        addSubview(number)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var glyphSize: NSSize {
        let size = glyph.intrinsicContentSize
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    override var intrinsicContentSize: NSSize {
        let digits = number.isHidden ? 0 : Self.gap + ceil(number.intrinsicContentSize.width)
        return NSSize(width: glyphSize.width + digits, height: max(glyphSize.height, ceil(number.intrinsicContentSize.height)))
    }

    private func changed() {
        let was = glyph.window == nil ? nil : (glyph.convert(glyph.bounds, to: nil), glyph.frame)
        number.roll(count > 1 ? "\(count)" : "", for: thing)
        carried = number.rolled?.busy == true ? was : nil
        number.isHidden = count < 2
        let said = count == 1 ? "1 unanswered comment" : "\(count) unanswered comments"
        setAccessibilityLabel(said)
        toolTip = said.prefix(1).uppercased() + said.dropFirst()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = glyphSize
        glyph.frame = NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
        let text = number.intrinsicContentSize
        number.frame = NSRect(x: size.width + Self.gap, y: (bounds.height - text.height) / 2, width: ceil(text.width), height: ceil(text.height))
        if let was = carried, abs(bounds.width - ceil(intrinsicContentSize.width)) < 0.5 {
            carried = nil
            number.rollCarry(glyph, from: was.0, or: was.1)
        }
    }
}

final class UnseenDotView: NSView {
    var tone = KitGreys.white.dot { didSet { if tone != oldValue { needsDisplay = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("New activity")
        toolTip = "New activity since you last opened it"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rounded()
    }

    override func layout() {
        super.layout()
        rounded()
    }

    override func updateLayer() {
        layer?.backgroundColor = tone.resolved(ink, dark: kitDark).cgColor
        rounded()
    }

    private func rounded() {
        let radius = min(bounds.width, bounds.height) / 2
        guard let layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }
}

class DoorView: KitHoverView {
    var icon: String { didSet { if icon != oldValue { symbol.swap(to: icon) } } }
    var on = false { didSet { if on != oldValue { paint(animated: true) } } }
    var confirmed = false { didSet { if confirmed != oldValue { paint(animated: true) } } }
    var help = "" { didSet { toolTip = help.isEmpty ? nil : help } }
    var size: CGFloat = 12 { didSet { restyle() } }
    var weight: NSFont.Weight = IconLook.control { didSet { restyle() } }
    var box: CGFloat = 26 { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    var held: (() -> NSMenu?)?
    var greys = KitGreys.white { didSet { if greys != oldValue { paint(animated: false) } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { paint(animated: false) } } }
    var act: () -> Void

    private let ground = KitPlate(radius: 8)
    private let symbol: KitSymbol
    private var pressed = false
    private var opened = false
    private var holdTimer: Timer?

    init(icon: String, help: String = "", act: @escaping () -> Void) {
        self.icon = icon
        self.act = act
        symbol = KitSymbol(icon)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(ground)
        addSubview(symbol)
        self.help = help
        toolTip = help.isEmpty ? nil : help
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(help.components(separatedBy: "   ").first ?? help)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: box, height: box) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }

    private func restyle() {
        symbol.style = KitSymbol.Style(size: size, weight: weight)
        paint(animated: false)
    }

    override func hoverChanged() { paint(animated: true) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }

    private func paint(animated: Bool) {
        if animated {
            ground.layer?.kitTransition(Motion.kitQuick)
            symbol.layer?.kitTransition(Motion.kitQuick)
        }
        symbol.ink = ink
        symbol.tint = on || hovering || confirmed ? Palette.NS.ink : Palette.NS.muted
        ground.ink = ink
        ground.fill = on ? greys.wash : hovering ? greys.hover : nil
    }

    override func layout() {
        super.layout()
        let square = NSRect(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2, width: box, height: box)
        ground.kitSetFrame(square)
        symbol.centreInk(in: kitSnapped(square))
    }

    private func give(_ down: Bool) {
        pressed = down
        kitScale(down && !Motion.reduced ? 0.9 : 1, curve: down ? Motion.kitQuick : Motion.kitSettle)
    }

    override func mouseDown(with event: NSEvent) {
        give(true)
        opened = false
        guard held != nil else { return }
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.pressed, let menu = self.held?() else { return }
                self.opened = true
                self.give(false)
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                DispatchQueue.main.async { self.opened = false }
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        let wasPressed = pressed
        give(false)
        guard wasPressed, !opened, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            opened = false
            return
        }
        act()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = held?() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func kick(_ kind: Kick?) {
        guard kind != nil, !Motion.reduced, let layer = symbol.layer else { return }
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [1, 1.18, 0.94, 1]
        bounce.keyTimes = [0, 0.3, 0.65, 1]
        bounce.duration = 0.35
        layer.add(bounce, forKey: "kick")
    }
}

final class QuietRowView: KitHoverView {
    var icon: String { didSet { if icon != oldValue { symbol.name = icon } } }
    var title: String { didSet { if title != oldValue { label.text = title; label.isHidden = title.isEmpty } } }
    var height: CGFloat = 28 { didSet { if height != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }
    var size: CGFloat = 13 { didSet { if size != oldValue { label.font = .systemFont(ofSize: size) } } }
    var greys = KitGreys.white { didSet { if greys != oldValue { paint(animated: false) } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { paint(animated: false) } } }
    var act: () -> Void

    private let ground = KitPlate(radius: Metrics.sideRadius)
    private let symbol: KitSymbol
    private let label: KitLabel

    init(icon: String, title: String, height: CGFloat = 28, size: CGFloat = 13, act: @escaping () -> Void) {
        self.icon = icon
        self.title = title
        self.height = height
        self.size = size
        self.act = act
        symbol = KitSymbol(icon, style: KitSymbol.Style(size: 12, weight: IconLook.control))
        label = KitLabel(title, font: .systemFont(ofSize: size))
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(ground)
        addSubview(symbol)
        addSubview(label)
        label.isHidden = title.isEmpty
        label.setAccessibilityElement(false)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title.isEmpty ? icon : title)
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }

    override func hoverChanged() { paint(animated: true) }

    private func paint(animated: Bool) {
        if animated {
            ground.layer?.kitTransition(Motion.kitQuick)
            symbol.layer?.kitTransition(Motion.kitQuick)
            label.layer?.kitTransition(Motion.kitQuick)
        }
        let tone = hovering ? KitTone.ink.opacity(0.8) : KitTone.muted
        let words = hovering ? tone : tone.opacity(SideLook.bylineTone)
        symbol.ink = ink
        symbol.tint = tone.base
        symbol.opacity = tone.opacity
        label.ink = ink
        label.color = words.base
        label.opacity = words.opacity
        ground.ink = ink
        ground.fill = hovering ? greys.hover : nil
    }

    override func layout() {
        super.layout()
        ground.kitSetFrame(bounds)
        let row = bounds.height
        symbol.kitSetFrame(NSRect(x: SideLook.rowLead, y: 0, width: SideLook.rowMark, height: row))
        let text = label.intrinsicContentSize
        let x = SideLook.rowLead + SideLook.rowMark + SideLook.markGap
        label.kitSetFrame(NSRect(x: x, y: (row - text.height) / 2, width: max(0, bounds.width - x), height: text.height))
    }

    private var down = false

    override func mouseDown(with event: NSEvent) { down = true }

    override func mouseUp(with event: NSEvent) {
        guard down else { return }
        down = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
    }
}

final class SpeakerView: KitHoverView {
    weak var tab: Tab? { didSet { refresh() } }
    var box: CGFloat = 15 { didSet { needsLayout = true; invalidateIntrinsicContentSize() } }
    var size: CGFloat = 10 { didSet { refresh() } }
    var ink: KitInk = .flat { didSet { refresh() } }

    private let ground = KitPlate()
    private let symbol = KitSymbol("speaker.wave.2")
    private lazy var reads = KitReads { [weak self] in self?.refresh() }
    private var down = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(ground)
        addSubview(symbol)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: box, height: box) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hoverChanged() {
        ground.layer?.kitTransition(Motion.kitQuick)
        refresh()
    }

    private func refresh() {
        reads.track { paint() }
    }

    private func paint() {
        guard let tab else { return }
        let name = tab.speakerSymbol + ".fill"
        if symbol.name != name { symbol.swap(to: name) }
        symbol.style = KitSymbol.Style(size: size, weight: .medium)
        symbol.ink = ink
        symbol.tint = tab.muted ? Palette.NS.muted : Palette.NS.ink
        symbol.opacity = tab.muted ? 1 : 0.85
        ground.ink = ink
        ground.fill = KitTone.ink.opacity(hovering ? 0.1 : 0)
        let said = tab.muted ? "Unmute Tab" : "Mute Tab"
        toolTip = said
        setAccessibilityLabel(said)
    }

    override func layout() {
        super.layout()
        let square = NSRect(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2, width: box, height: box)
        ground.radius = box / 2
        ground.kitSetFrame(square)
        symbol.kitSetFrame(square)
    }

    override func accessibilityPerformPress() -> Bool {
        tab?.toggleMute()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        down = true
        if !Motion.reduced { layer?.kitAnimate("opacity", to: 0.82, curve: Motion.kitQuick) }
    }

    override func mouseUp(with event: NSEvent) {
        layer?.kitAnimate("opacity", to: 1, curve: Motion.kitSettle)
        guard down else { return }
        down = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { tab?.toggleMute() }
    }
}

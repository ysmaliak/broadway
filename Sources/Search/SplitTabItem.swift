import AppKit
import Combine

@MainActor
final class SplitTabItemView: KitHoverView {
    struct Setup: Equatable {
        var height: CGFloat = Metrics.sideRowHeight
        var live = false
        var focusedID: Tab.ID?
        var interactive = true
        var onFrame = false
        var ink: KitInk = .flat
        var greys: KitGreys = .white
        var numbers: [UUID: Int] = [:]
    }

    let browser: Browser
    private(set) var left: Tab
    private(set) var right: Tab
    private(set) var setup = Setup()
    var onChips: (([Tab.ID: CGRect]) -> Void)?

    let rest = KitBox(fill: nil, corners: .radius(Metrics.sideRadius))
    var radius = Metrics.sideRadius {
        didSet {
            guard radius != oldValue else { return }
            rest.corners = .radius(radius)
        }
    }
    let chips: [SplitChipView]
    private let close = SplitClose(label: "Close Split View")
    private lazy var reads = KitReads { [weak self] in self?.refresh(animated: true) }
    private var wasLive = false
    private var told: [Tab.ID: CGRect] = [:]
    private var closing = false
    private var configured = false

    init(browser: Browser, left: Tab, right: Tab) {
        self.browser = browser
        self.left = left
        self.right = right
        chips = [SplitChipView(browser: browser, tab: left), SplitChipView(browser: browser, tab: right)]
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Metrics.sideRowHeight))
        wantsLayer = true
        addSubview(rest)
        for chip in chips { addSubview(chip) }
        addSubview(close)
        close.act = { [weak self] in
            guard let self else { return }
            browser.detachSplit(self.left)
        }
        close.layer?.opacity = 0
        for chip in chips {
            chip.hoverMoved = { [weak self] in self?.paint(animated: false) }
        }
        kitAccess(label: "Split tabs", role: .group)
        refresh(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: setup.height) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === rest ? nil : hit
    }

    func update(left: Tab, right: Tab, setup: Setup) {
        let moved = left !== self.left || right !== self.right
        if moved {
            self.left = left
            self.right = right
            chips[0].tab = left
            chips[1].tab = right
        }
        let grew = setup.height != self.setup.height
        self.setup = setup
        if grew { invalidateIntrinsicContentSize() }
        refresh(animated: !moved && configured)
        configured = true
    }

    private func refresh(animated: Bool) {
        reads.track { refreshNow(animated: animated) }
    }

    private func refreshNow(animated: Bool) {
        let ids: Set<Tab.ID> = [left.id, right.id]
        let lit = RowRun.lit(picked: browser.selectedTabIDs, active: browser.activeID)
        let asking = Set(browser.paneQuestions.map(\.tab))
        let focused = setup.live ? (setup.focusedID ?? browser.activeID) : nil
        let editing = browser.editingTab.flatMap { ids.contains($0) ? $0 : nil }
        let arriving = setup.live && !wasLive && animated
            && SwitchFade.within(from: browser.pageBefore, to: [left.id, right.id], among: browser.tabs.map(\.id))
        wasLive = setup.live
        rest.isHidden = setup.live
        for chip in chips {
            chip.show(SplitChipView.State(focused: focused == chip.tab.id, interactive: setup.interactive,
                                          editing: editing == chip.tab.id, picked: lit.contains(chip.tab.id),
                                          asking: asking.contains(chip.tab.id), icons: true,
                                          title: browser.prefs.sideTitle - 1, number: setup.interactive ? setup.numbers[chip.tab.id] : nil,
                                          onFrame: setup.onFrame, ink: setup.ink, greys: setup.greys,
                                          zone: setup.interactive && browser.prefs.splitView),
                      animated: animated, arriving: arriving)
        }
        close.ink = setup.ink
        paint(animated: false)
        needsLayout = true
    }

    override func hoverChanged() {
        let wanted = hovering && setup.interactive
        if wanted != closing {
            closing = wanted
            close.armed = wanted
            let pointer = NSApp.currentEvent.map { [.mouseEntered, .mouseExited].contains($0.type) } ?? false
            let animated = pointer && window != nil && !inLiveResize && !Motion.reduced
            close.layer?.kitAnimate("opacity", to: Swift.Float(wanted ? 1 : 0), curve: animated ? Motion.kitQuick : .none, key: "shown")
            needsLayout = true
            if animated {
                NSAnimationContext.kit(Motion.kitQuick, implicit: true) {
                    layoutSubtreeIfNeeded()
                }
            }
        }
        paint(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }

    private func paint(animated: Bool) {
        let dark = kitDark
        let greys = SplitGreys(onFrame: setup.onFrame, ink: setup.ink, dark: dark)
        let fill = hovering ? greys.hover : greys.tile
        if fill != rest.fill {
            if animated { rest.layer?.kitTransition(Motion.kitQuick) }
            rest.fill = fill
        }
    }

    override func layout() {
        super.layout()
        rest.frame = bounds
        let height = setup.height
        let side = Metrics.closeSquare(height)
        let inset = Metrics.closeInset(height)
        let lead = SideGrid.pad
        let between = lead
        let room = max(0, bounds.width - lead * 2)
        let closeRoom = closing ? side + inset - lead + between : 0
        let each = max(0, (room - between - closeRoom) / 2)
        let chipHeight = SplitChipView.height
        let y = (bounds.height - chipHeight) / 2
        chips[0].frame = kitSnap(NSRect(x: lead, y: y, width: each, height: chipHeight))
        chips[1].frame = kitSnap(NSRect(x: lead + each + between, y: y, width: each, height: chipHeight))
        close.frame = kitSnap(NSRect(x: bounds.width - inset - side, y: (bounds.height - side) / 2, width: side, height: side))
        let now: [Tab.ID: CGRect] = [left.id: chips[0].frame, right.id: chips[1].frame]
        if now != told {
            told = now
            DispatchQueue.main.async { [weak self] in self?.onChips?(now) }
        }
    }
}

struct SplitGreys {
    let hover: NSColor
    let picked: NSColor
    let tile: NSColor
    let edge: NSColor

    init(onFrame: Bool, ink: KitInk, dark: Bool) {
        func side(_ base: NSColor) -> NSColor { ink.color(base, .stronger(0.8), dark: dark) }
        func plain(_ base: NSColor) -> NSColor { base.kitResolved(dark: dark) }
        if onFrame {
            hover = side(Palette.NS.sideHover)
            picked = side(Palette.NS.sidePicked)
            tile = side(Palette.NS.sideTile)
            edge = side(Palette.NS.sideSlabEdge)
        } else {
            hover = plain(Palette.NS.hover)
            picked = plain(Palette.NS.picked)
            let washed = plain(Palette.NS.wash)
            tile = washed.withAlphaComponent(washed.alphaComponent * 0.55)
            edge = ink.color(KitColor.hairline, .stronger(0.6), dark: dark)
        }
    }
}

@MainActor
final class SplitChipView: KitHoverView {
    static let height: CGFloat = SideGrid.bar

    struct State: Equatable {
        var focused = false
        var interactive = true
        var editing = false
        var picked = false
        var asking = false
        var icons = true
        var title: CGFloat = 12
        var number: Int?
        var onFrame = false
        var ink: KitInk = .flat
        var greys: KitGreys = .white
        var zone = false
    }

    let browser: Browser
    var tab: Tab {
        didSet {
            guard tab !== oldValue else { return }
            if window != nil {
                Bench.chipDisappeared(oldValue.id)
                benchHover()
            }
            zone.tab = tab
            popup = nil
            translate = nil
            speaker = nil
        }
    }
    var hoverMoved: (() -> Void)?

    private(set) var state = State()
    let slab = KitPlate(radius: 7)
    let fill = KitBox(fill: nil, corners: .radius(7))
    private var lit = false
    private let ring = RingView()
    private let mark = KitMark(icon: nil, letter: "", side: SideGrid.mark)
    private let dot = KitBox(fill: KitColor.muted, corners: .capsule)
    private let title = KitLabel("", font: .systemFont(ofSize: 12))
    private let number = ShortcutNumberView(number: 1)
    private let middle = SplitMiddleCatch()
    private let zone = SplitDropMarker()
    private var popup: NSView? { didSet { swap(oldValue, popup) } }
    private var translate: NSView? { didSet { swap(oldValue, translate) } }
    private var speaker: NSView? { didSet { swap(oldValue, speaker) } }
    private var field: NSView? { didSet { swap(oldValue, field) } }
    private var zoned = false

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        super.init(frame: NSRect(x: 0, y: 0, width: 100, height: Self.height))
        wantsLayer = true
        zone.browser = browser
        zone.tab = tab
        zone.kind = .strip
        title.overflow = .fade(RowTitleFade.width)
        title.setAccessibilityElement(false)
        number.setAccessibilityElement(false)
        slab.layer?.opacity = 0
        for view in [zone, slab, fill, ring, mark, dot, title, number, middle] as [NSView] { addSubview(view) }
        dot.kitAccess(label: "Asking a question")
        middle.act = { [weak self] in
            guard let self, state.interactive else { return }
            browser.hints.closedByPointer()
            browser.closeTab(self.tab)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === fill || hit === title || hit === mark || hit === number || hit === dot ? nil : hit
    }

    override func hoverChanged() {
        paint(animated: false)
        hoverMoved?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { benchHover() } else { Bench.chipDisappeared(tab.id) }
    }

    private func benchHover() {
        Bench.chipAppeared(tab.id) { [weak self] on in
            (self?.superview as? KitHoverView)?.benchPillHover(on)
            self?.benchPillHover(on)
        }
    }

    private func swap(_ old: NSView?, _ new: NSView?) {
        guard old !== new else { return }
        old?.removeFromSuperview()
        if let new { addSubview(new, positioned: .below, relativeTo: middle) }
        needsLayout = true
    }

    private var playing: Bool { !tab.loading && (tab.noisy || tab.muted) }
    private var name: String { tab.label.isEmpty ? "New Tab" : tab.label }

    func show(_ now: State, animated: Bool, arriving: Bool = false) {
        let turned = now.focused != state.focused
        state = now
        light(animated: animated, arriving: arriving)
        if now.zone != zoned {
            zoned = now.zone
            if now.zone { TabDrag.shared.register(zone) } else { TabDrag.shared.unregister(zone) }
        }
        if now.editing, field == nil {
            field = SideSigns.tabAddressField(browser: browser)
        } else if !now.editing, field != nil {
            field = nil
        }
        if !tab.blockedPopups.isEmpty, popup == nil { popup = PopupSignView(browser: browser, tab: tab) }
        (popup as? SignView)?.ink = now.ink
        if tab.translation != nil, translate == nil { translate = TranslateSignView(tab: tab) }
        (translate as? SignView)?.ink = now.ink
        (popup as? SignView)?.refresh()
        (translate as? SignView)?.refresh()
        if playing, speaker == nil {
            let made = SpeakerView()
            made.tab = tab
            speaker = made
        }
        (speaker as? SpeakerView)?.ink = now.ink
        mark.icon = tab.icon
        mark.letter = tab.monogram
        mark.ink = now.ink
        mark.alphaValue = 1
        dot.ink = now.ink
        title.text = name
        title.font = .systemFont(ofSize: now.title)
        title.ink = now.ink
        number.ink = now.ink
        if let value = now.number { number.number = value }
        middle.isHidden = !now.interactive
        setAccessibilityLabel(name)
        setAccessibilityValue(now.focused ? "Focused page" : "")
        setAccessibilityHelp(now.interactive ? "Click to focus this page, right-click for tab actions" : "")
        var actions = [NSAccessibilityCustomAction(name: "Focus Page") { [weak self] in
            guard let self else { return false }
            browser.focusPane(tab)
            return true
        }]
        actions.append(NSAccessibilityCustomAction(name: "Close Tab") { [weak self] in
            guard let self else { return false }
            if state.interactive { browser.closeTab(tab) }
            return true
        })
        setAccessibilityCustomActions(actions)
        paint(animated: animated && turned)
        needsLayout = true
    }

    override func accessibilityPerformPress() -> Bool {
        browser.focusPane(tab)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }

    private func light(animated: Bool, arriving: Bool) {
        SelectedLook.dress(slab, greys: state.greys, ink: state.ink, picked: state.picked)
        guard state.focused != lit, let layer = slab.layer else { return }
        lit = state.focused
        if lit, arriving, !Motion.calm {
            layer.kitAnimate("opacity", to: Swift.Float(1), curve: Motion.kitQuick, key: "live")
            if let scale = Motion.kitQuick.animation("transform", from: NSValue(caTransform3D: centred(layer, 0.98)), to: NSValue(caTransform3D: CATransform3DIdentity)) {
                layer.add(scale, forKey: "liveScale")
            }
        } else if lit {
            let curve: KitCurve = arriving && !Motion.reduced ? .easeOut(0.14) : animated ? Motion.kitQuick : .none
            layer.kitAnimate("opacity", to: Swift.Float(1), curve: curve, key: "live")
        } else {
            layer.kitAnimate("opacity", to: Swift.Float(0), curve: animated && !Motion.reduced ? .easeOut(0.08) : .none, key: "live")
        }
    }

    private func centred(_ layer: CALayer, _ scale: CGFloat) -> CATransform3D {
        let bounds = layer.bounds
        let anchor = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let fix = CGPoint(x: (bounds.midX - anchor.x) * (1 - scale), y: (bounds.midY - anchor.y) * (1 - scale))
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(fix.x, fix.y, 0))
    }

    private func paint(animated: Bool) {
        let greys = SplitGreys(onFrame: state.onFrame, ink: state.ink, dark: kitDark)
        let wanted: NSColor? = state.focused ? nil : state.picked ? greys.picked : hovering ? greys.hover : nil
        if wanted != fill.fill {
            if animated { fill.layer?.kitTransition(Motion.kitQuick) }
            fill.fill = wanted
        }
        let color = KitColor.ink
        let opacity = 1.0
        if color != title.color || opacity != title.opacity {
            if animated { title.layer?.kitTransition(Motion.kitQuick) }
            title.color = color
            title.opacity = opacity
        }
    }

    override func layout() {
        super.layout()
        slab.frame = bounds
        fill.frame = bounds
        zone.frame = bounds
        middle.frame = bounds
        let mid = bounds.height / 2
        func place(_ view: NSView, x: CGFloat, size: NSSize) {
            view.frame = kitSnap(NSRect(x: x, y: mid - size.height / 2, width: size.width, height: size.height))
        }
        let editing = state.editing
        let lead = SideGrid.lead - SideGrid.pad
        if let field {
            place(field, x: lead, size: NSSize(width: max(0, bounds.width - 2 * lead), height: 16))
        }
        var x = lead
        let gap = SideGrid.gap
        let side = SideGrid.mark
        let loading = tab.loading
        ring.isHidden = editing || !loading
        mark.isHidden = editing || loading || !state.icons
        if !ring.isHidden {
            place(ring, x: x + (side - 11) / 2, size: NSSize(width: 11, height: 11))
            x += side + gap
        } else if !mark.isHidden {
            place(mark, x: x, size: NSSize(width: side, height: side))
            x += side + gap
        }
        let popupOn = !editing && !tab.blockedPopups.isEmpty
        popup?.isHidden = !popupOn
        if let popup, popupOn {
            place(popup, x: x, size: NSSize(width: 17, height: 15))
            x += 17 + gap
        }
        let translateOn = !editing && tab.translation != nil
        translate?.isHidden = !translateOn
        if let translate, translateOn {
            place(translate, x: x, size: NSSize(width: 17, height: 15))
            x += 17 + gap
        }
        dot.isHidden = editing || !state.asking
        if !dot.isHidden {
            place(dot, x: x, size: NSSize(width: 5, height: 5))
            x += 5 + gap
        }
        var end = bounds.width - lead
        let speakerOn = !editing && playing
        speaker?.isHidden = !speakerOn
        if let speaker, speakerOn {
            end -= 15
            place(speaker, x: end, size: NSSize(width: 15, height: 15))
            end -= gap
        }
        number.isHidden = editing || state.number == nil
        if !number.isHidden {
            end -= ShortcutNumberView.side
            place(number, x: end, size: NSSize(width: ShortcutNumberView.side, height: ShortcutNumberView.side))
            end -= gap
        }
        title.isHidden = editing
        let height = title.intrinsicContentSize.height
        place(title, x: x, size: NSSize(width: max(0, end - x), height: height))
    }
}

private final class SplitMiddleCatch: NSView {
    var act: () -> Void = {}
    private var pressed = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown || event.type == .otherMouseUp,
              event.buttonNumber == 2
        else { return nil }
        return super.hitTest(point)
    }

    override func otherMouseDown(with event: NSEvent) {
        pressed = true
    }

    override func otherMouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
    }
}

@MainActor
private final class SplitClose: KitHoverView {
    var act: () -> Void = {}
    var armed = false { didSet { if armed != oldValue { setAccessibilityElement(armed); paint(animated: true) } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { symbol.ink = ink; box.ink = ink } } }

    private let box = KitBox(fill: nil)
    private let symbol = KitSymbol("xmark", style: .init(size: 12), tint: KitColor.ink)
    private var pressed = false { didSet { if pressed != oldValue { press() } } }

    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(box)
        addSubview(symbol)
        symbol.setAccessibilityElement(false)
        kitAccess(label: label, role: .button)
        setAccessibilityHelp(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard armed, let event = NSApp.currentEvent,
              event.type == .leftMouseDown, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              frame.contains(point)
        else { return nil }
        return self
    }

    override func hoverChanged() { paint(animated: true) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != pressed { pressed = inside }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        pressed = false
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if fire { act() }
    }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }

    private func press() {
        paint(animated: true)
        guard let layer else { return }
        let scale: CGFloat = pressed && !Motion.reduced ? 0.92 : 1
        let bounds = layer.bounds
        let anchor = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let fix = CGPoint(x: (bounds.midX - anchor.x) * (1 - scale), y: (bounds.midY - anchor.y) * (1 - scale))
        let transform = scale == 1 ? CATransform3DIdentity
            : CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(fix.x, fix.y, 0))
        layer.kitAnimate("transform", to: NSValue(caTransform3D: transform), curve: pressed ? Motion.kitQuick : Motion.kitSettle, key: "press")
    }

    private func paint(animated: Bool) {
        let over = hovering && armed
        let side = bounds.width
        let glyph = min(13.5, max(9, side * 0.44))
        symbol.style = .init(size: glyph, weight: side >= 24 ? .light : .regular)
        symbol.opacity = over ? 0.96 : 0.62
        box.corners = .radius(min(8, side * 0.27))
        let fill: NSColor? = over ? KitColor.ink.withAlphaComponent(pressed ? 0.2 : 0.13) : nil
        if fill != box.fill {
            if animated { box.layer?.kitTransition(Motion.kitQuick) }
            box.fill = fill
        }
    }

    override func layout() {
        super.layout()
        box.frame = bounds
        paint(animated: false)
        let size = symbol.intrinsicContentSize
        symbol.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                      width: size.width, height: size.height))
    }
}

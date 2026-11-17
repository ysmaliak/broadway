import AppKit
import QuartzCore

final class PinFaceView: NSView {
    var tint = PinTint.neutral { didSet { if tint != oldValue { needsDisplay = true } } }
    var state = PinLook.State.resting { didSet { if state != oldValue { needsDisplay = true } } }
    var overResting = false { didSet { if overResting != oldValue { needsDisplay = true } } }
    var radius: CGFloat = PinPlaces.radius { didSet { if radius != oldValue { needsLayout = true } } }
    var greys = KitGreys.white { didSet { if greys != oldValue { needsDisplay = true } } }
    var ink = KitInk.flat { didSet { if ink != oldValue { needsDisplay = true } } }

    private let fill = CAGradientLayer()
    private let edge = CAShapeLayer()
    private let rim = KitRimLayer()
    private let mesh = CALayer()
    private let inner = CAGradientLayer()
    private let outer = CAGradientLayer()
    private let innerMask = CAShapeLayer()
    private let outerMask = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for layer in [fill, mesh, inner, outer] as [CALayer] {
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "backgroundColor": NSNull(),
                             "hidden": NSNull(), "colors": NSNull(), "path": NSNull()]
            self.layer?.addSublayer(layer)
        }
        edge.actions = ["path": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "lineWidth": NSNull()]
        layer?.addSublayer(edge)
        edge.fillColor = nil
        layer?.addSublayer(rim)
        mesh.contentsGravity = .resize
        mesh.minificationFilter = .linear
        mesh.magnificationFilter = .linear
        mesh.cornerCurve = .continuous
        mesh.masksToBounds = true
        fill.cornerCurve = .continuous
        fill.masksToBounds = true
        for gradient in [inner, outer] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        }
        for mask in [innerMask, outerMask] {
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
        inner.mask = innerMask
        outer.mask = outerMask
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
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = bounds
        for layer in [fill, mesh, inner, outer, edge] as [CALayer] { layer.frame = box }
        fill.cornerRadius = min(radius, min(box.width, box.height) / 2)
        mesh.cornerRadius = fill.cornerRadius
        let scale = window?.backingScaleFactor ?? 2
        let hair = 1 / max(1, scale)
        edge.lineWidth = hair
        edge.path = Self.rounded(box.insetBy(dx: hair / 2, dy: hair / 2), radius: max(0, fill.cornerRadius - hair / 2))
        rim.place(box, radius: fill.cornerRadius, hair: hair)
        innerMask.frame = box
        outerMask.frame = box
        innerMask.lineWidth = PinLook.ring
        innerMask.path = Self.rounded(box.insetBy(dx: PinLook.ring / 2, dy: PinLook.ring / 2), radius: max(0, fill.cornerRadius - PinLook.ring / 2))
        outerMask.lineWidth = PinLook.ring / 2
        outerMask.path = Self.rounded(box.insetBy(dx: PinLook.ring / 4, dy: PinLook.ring / 4), radius: max(0, fill.cornerRadius - PinLook.ring / 4))
        lift()
        CATransaction.commit()
    }

    private func lift() {
        guard let layer else { return }
        if PinLook.hued(state) {
            SelectedLook.cast(on: layer, dark: kitDark, path: KitPath.continuous(bounds, radius: fill.cornerRadius))
        } else {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
        }
    }

    static func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        guard rect.width > 0, rect.height > 0 else { return CGPath(rect: .zero, transform: nil) }
        let r = min(radius, min(rect.width, rect.height) / 2)
        return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    }

    override func updateLayer() {
        let dark = kitDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hued = PinLook.hued(state)
        lift()
        fill.isHidden = hued
        edge.isHidden = hued
        if hued { rim.isHidden = true }
        mesh.isHidden = !hued
        inner.isHidden = !hued
        outer.isHidden = !hued
        if hued {
            mesh.contents = PinLook.mesh(tint, dark: dark)
            inner.colors = Self.ringColours(tint, .inner, dark: dark)
            inner.locations = Self.ringLocations
            outer.colors = Self.ringColours(tint, .outer, dark: dark)
            outer.locations = Self.ringLocations
            for gradient in [inner, outer] { gradient.endPoint = Self.hotEnd }
        } else {
            func shown(_ face: NSColor, _ resting: NSColor) -> CGColor {
                (overResting ? face.withAlphaComponent(PinLook.over(face.alphaComponent, resting: resting.alphaComponent)) : face).cgColor
            }
            let top = shown(PinLook.colour(greys, ink, part: .fill, state: state, dark: dark),
                            PinLook.colour(greys, ink, part: .fill, state: .resting, dark: dark))
            let foot = shown(PinLook.foot(greys, ink, state: state, dark: dark), PinLook.foot(greys, ink, state: .resting, dark: dark))
            fill.backgroundColor = nil
            fill.colors = [top, foot]
            fill.startPoint = CGPoint(x: 0.5, y: 0)
            fill.endPoint = CGPoint(x: 0.5, y: 1)
            edge.strokeColor = PinLook.colour(greys, ink, part: .edge, state: state, dark: dark).cgColor
            rim.paint(overResting ? nil : PinLook.rim(greys, ink, state: state, dark: dark),
                      ramp: PinLook.ramp(greys, ink, state: state, dark: dark), fromTop: dark)
        }
        CATransaction.commit()
    }

    private static let ringLocations: [NSNumber] = [0, 0.13, 0.36, 0.64, 0.87, 1]

    private static var hotEnd: CGPoint {
        let angle = 225 * CGFloat.pi / 180
        return CGPoint(x: 0.5 + cos(angle), y: 0.5 + sin(angle))
    }

    static func ringColours(_ tint: PinTint, _ band: PinLook.Band, dark: Bool) -> [CGColor] {
        let neutral = NSColor(white: dark ? 1 : 0, alpha: PinLook.neutralRing(dark: dark, band: band) * 0.55)
        let hues = tint.hues
        let lit: [NSColor]
        if hues.isEmpty {
            let bright = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.92 : 0.6)
            let mid = NSColor(white: dark ? 0.86 : 0.18, alpha: dark ? 0.72 : 0.42)
            lit = [bright, mid, mid]
        } else {
            let colours = hues.map { PinLook.ringNS($0.hue, $0.saturation, band, dark: dark) }
            lit = [colours[0], colours[min(1, colours.count - 1)], colours[min(2, colours.count - 1)]]
        }
        return [lit[0], lit[1], neutral, neutral, lit[2].withAlphaComponent(lit[2].alphaComponent * 0.7), lit[0]].map(\.cgColor)
    }
}

protocol HoverColumnSpace: NSView {}

final class PinSquareView: KitHoverView {
    private(set) weak var tab: Tab?
    private(set) weak var browser: Browser?
    var state = RowState() { didSet { if state != oldValue { stateChanged(from: oldValue) } } }
    weak var host: TabRowHost?
    var close: () -> Void = {}

    private let shadowHolder = NSView()
    private let face = PinFaceView()
    let liveFace = PinFaceView()
    private let mark = RowMarkView()
    private let second = RowMarkView()
    private var partner: (tab: Tab, axis: TabSplit.Axis)?
    private weak var shownSecond: NSImage?
    private var shortcut: ShortcutNumberView?
    private var field: NSView?
    private var peekBadge: NSView?
    private var meeting: NSView?
    private var pressedDown = false
    private var selectedOnPress = false
    private var benchShown = false
    private var benchHovering: Bool?
    private var under = PinLook.State.resting

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        shadowHolder.wantsLayer = true
        shadowHolder.layer?.masksToBounds = false
        addSubview(shadowHolder)
        shadowHolder.addSubview(face)
        addSubview(liveFace)
        liveFace.state = .live
        liveFace.overResting = true
        liveFace.isHidden = true
        addSubview(mark)
        mark.size = PinPlaces.mark
        mark.letterSize = 12
        mark.tiled = false
        addSubview(second)
        second.size = PinPlaces.pairMark
        second.letterSize = 11
        second.tiled = false
        second.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var isHovering: Bool { benchHovering ?? hovering }

    func show(_ tab: Tab, in browser: Browser, state: RowState) {
        let changed = self.tab !== tab
        if changed {
            if let old = self.tab {
                if benchShown { Bench.rowDisappeared(old.id) }
                benchShown = false
            }
            self.tab = tab
            self.browser = browser
        }
        self.state = state
        let icon = tab.icon
        let other = browser.pinPartner(of: tab)
        let moved = other?.tab !== partner?.tab || other?.axis != partner?.axis || other?.tab.icon !== shownSecond
        if changed || moved || icon !== shownIcon { refresh(animated: false) }
        registerBench()
    }

    func noteBench() {
        guard Store.testing, let tab, let frame = benchFrame() else { return }
        Bench.rowFrames[tab.id] = frame
    }

    func forget() {
        if let tab {
            if benchShown { Bench.rowDisappeared(tab.id) }
            Bench.rowFrames[tab.id] = nil
            browser?.hoverCards.leave(.tab(tab.id))
        }
        benchShown = false
        tab = nil
    }

    private func registerBench() {
        guard Store.testing, let tab, window != nil else { return }
        Bench.rowPress(tab.id) { [weak self] down in self?.give(down) }
        Bench.rowLayers(tab.id) { [weak self] in
            guard let self else { return [:] }
            let named: [String: CALayer?] = ["face": shadowHolder.layer, "content": mark.layer, "live": liveFace.layer]
            return named.compactMapValues { $0 }
        }
        guard !benchShown else { return }
        benchShown = true
        Bench.rowAppeared(tab.id) { [weak self] over in self?.benchHover(over) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { registerBench() }
    }

    private func stateChanged(from old: RowState) {
        if old.ground != state.ground { applyInk() }
        if old.live != state.live { liveChanged(from: old) }
        refresh(animated: old.live == state.live)
    }

    private func applyInk() {
        for made in [face, liveFace] {
            made.greys = state.ground.greys
            made.ink = state.ground.ink
        }
        mark.ink = state.ground.ink
        shortcut?.ink = state.ground.ink
    }

    private func liveChanged(from old: RowState) {
        guard let browser, let tab else { return }
        if state.live {
            liveFace.layer?.removeAnimation(forKey: "leave")
            liveFace.isHidden = false
            liveFace.alphaValue = 1
            if SwitchFade.within(from: state.before, to: [tab.id], among: browser.tabs.map(\.id)) {
                if Motion.calm {
                    liveFace.layer?.add(Self.fade(from: 0, to: 1, duration: 0.14), forKey: "arrive")
                } else {
                    liveFace.layer?.add(Self.fade(from: 0, to: 1, duration: 0.12), forKey: "arrive")
                }
            }
        } else if old.live {
            guard !Motion.reduced else { liveFace.isHidden = true; return }
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, !self.state.live else { return }
                self.liveFace.isHidden = true
                self.liveFace.layer?.removeAnimation(forKey: "leave")
            }
            liveFace.layer?.removeAnimation(forKey: "arrive")
            liveFace.layer?.add(Self.fade(from: 1, to: 0, duration: 0.08), forKey: "leave")
            CATransaction.commit()
        }
    }

    private static func fade(from: Double, to: Double, duration: Double) -> CAAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        if to == 0 {
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
        }
        return fade
    }

    override func hoverChanged() {
        if !hovering { benchHovering = nil }
        hoverMoved()
    }

    private func hoverMoved() {
        refresh(animated: true)
        guard let tab, let browser else { return }
        if isHovering, state.hoverCards, !state.editing {
            browser.hoverCards.enter(.tab(tab.id), frame: cardSpot())
        } else {
            browser.hoverCards.leave(.tab(tab.id))
        }
    }

    func benchHover(_ over: Bool) {
        benchHovering = over
        hoverMoved()
    }

    func cardSpot() -> CGRect {
        guard let window, let content = window.contentView else { return .zero }
        let row = convert(bounds, to: nil)
        let top = content.bounds.height
        guard let column = ColumnSpace.column(of: self) else {
            return CGRect(x: row.minX, y: top - row.maxY, width: row.width, height: row.height)
        }
        let side = column.convert(column.bounds, to: nil)
        return CGRect(x: side.minX, y: top - row.maxY, width: side.width, height: row.height)
    }

    override func layout() {
        super.layout()
        refresh(animated: false)
    }

    private var tint = PinTint.neutral
    private weak var shownIcon: NSImage?
    private var lift: CGFloat = 0

    func refresh(animated: Bool) {
        guard let tab, let browser else { return }
        let dark = state.ground.dark
        shownIcon = tab.icon
        let shown = state.icons || tab.customIcon != nil ? tab.icon : nil
        tint = PinTint.of(shown).seeded((tab.home ?? tab.address)?.absoluteString ?? tab.pin ?? "")
        let glyph = tint.dress(dark: dark) == .ink
        let editing = state.editing
        let number = state.interactive && !editing ? state.number : nil
        let picked = state.interactive && state.picked
        let hovering = isHovering
        let nowUnder: PinLook.State = picked && !state.live ? .picked : hovering && !state.live ? .hovered : .resting
        if nowUnder != under, animated, Motion.kitQuick.animates {
            face.layer?.kitTransition(Motion.kitQuick)
        }
        under = nowUnder
        face.tint = tint
        face.state = nowUnder
        liveFace.tint = tint
        if state.live { liveFace.isHidden = false }

        mark.isHidden = editing || number != nil
        mark.icon = shown
        mark.letter = tab.pin ?? ""
        mark.letterTone = state.live ? .ink : .muted
        mark.glyph = glyph
        partner = browser.pinPartner(of: tab)
        mark.size = partner == nil ? PinPlaces.mark : PinPlaces.pairMark
        mark.letterSize = partner == nil ? 12 : 11
        second.isHidden = partner == nil || mark.isHidden
        if let other = partner?.tab {
            shownSecond = other.icon
            second.icon = state.icons || other.customIcon != nil ? other.icon : nil
            second.letter = other.pin ?? ""
            second.letterTone = mark.letterTone
            second.glyph = glyph
        } else {
            shownSecond = nil
        }

        if let number {
            let made = shortcut ?? ShortcutNumberView(number: number)
            if shortcut == nil { addSubview(made); shortcut = made; made.ink = state.ground.ink }
            made.number = number
        } else if let made = shortcut {
            made.removeFromSuperview()
            shortcut = nil
        }

        if editing {
            let made = field ?? SideSigns.pinField(browser: browser, tab: tab)
            if field == nil { addSubview(made); field = made }
        } else if let made = field {
            made.removeFromSuperview()
            field = nil
        }

        let scale = min(bounds.width, bounds.height)
        if let peek = state.peek, let page = browser.peekTab, ObjectIdentifier(page) == peek {
            let badge = peekBadge ?? SideSigns.peekBadge(page: page, size: scale * 16 / 34)
            if peekBadge == nil { addSubview(badge); peekBadge = badge }
        } else if let badge = peekBadge {
            badge.removeFromSuperview()
            peekBadge = nil
        }

        if state.nextMeeting, Meetings.isCalendar(tab.address) {
            let made = meeting ?? SideSigns.pinMeeting(browser: browser, address: tab.address, editing: editing)
            if meeting == nil {
                addSubview(made, positioned: .above, relativeTo: mark)
                meeting = made
            }
            SideSigns.update(meeting: made, address: tab.address, editing: editing, width: bounds.width, height: bounds.height)
            lift = editing || Meetings.shared.next?.pinLabel(at: Meetings.shared.clock) == nil ? 0 : PinMeetingPlaces.lift(in: bounds.height)
        } else if let made = meeting {
            made.removeFromSuperview()
            meeting = nil
            lift = 0
        }

        let label = partner.map { "\(tab.label) and \($0.tab.label)" } ?? tab.label
        setAccessibilityLabel(label)
        toolTip = state.hoverCards ? nil : label
        place()
        if Store.testing, let frame = benchFrame() { Bench.rowFrames[tab.id] = frame }
    }

    func benchFrame() -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let row = convert(bounds, to: content)
        return CGRect(x: row.minX, y: content.isFlipped ? row.minY : content.bounds.height - row.maxY, width: row.width, height: row.height)
    }

    private func place() {
        let box = bounds
        shadowHolder.kitSetFrame(box)
        face.kitSetFrame(shadowHolder.bounds)
        liveFace.kitSetFrame(box)
        let side = PinPlaces.mark
        let middle = NSRect(x: (box.width - side) / 2, y: (box.height - side) / 2 - lift, width: side, height: side)
        if let partner {
            let pair = PinPlaces.pair(in: box, axis: partner.axis, lift: lift)
            mark.kitSetFrame(pair.first)
            second.kitSetFrame(pair.second)
        } else {
            mark.kitSetFrame(middle)
        }
        if let shortcut {
            let s = ShortcutNumberView.side
            shortcut.kitSetFrame(NSRect(x: (box.width - s) / 2, y: (box.height - s) / 2, width: s, height: s))
        }
        field?.kitSetFrame(middle.insetBy(dx: -max(0, (box.width - 8 - side) / 2), dy: 0))
        if let peekBadge {
            let scale = min(box.width, box.height)
            let size = scale * 16 / 34
            peekBadge.kitSetFrame(NSRect(x: box.width - size + scale * 4 / 34, y: -scale * 4 / 34, width: size, height: size))
        }
        meeting?.kitSetFrame(box)
    }

    func releasePress() {
        guard pressedDown else { return }
        give(false)
    }

    private func give(_ down: Bool) {
        let sink = RowRun.sink(pressed: down, gives: state.tabsGive, calm: Motion.calm)
        let curve = sink < 1 ? Motion.kitQuick : Motion.kitSettle
        for view in [shadowHolder, liveFace, mark, second] as [NSView] {
            view.kitScale(sink, curve: curve, around: CGPoint(x: bounds.midX - view.frame.minX, y: bounds.midY - view.frame.minY))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard state.interactive, let tab, let browser else { return }
        if host?.rowPressed(self, event: event) == true { return }
        pressedDown = true
        give(true)
        selectedOnPress = false
        let mods = event.modifierFlags
        guard !state.editing, mods.intersection([.command, .control, .shift]).isEmpty else { return }
        selectedOnPress = !state.live
        TabPress.brought = !state.live
        if selectedOnPress {
            browser.clearTabSelection()
            browser.select(browser.pinTarget(tab))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard state.interactive else { return }
        host?.rowDragged(self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard state.interactive, let tab, let browser else { return }
        give(false)
        let wasDown = pressedDown
        pressedDown = false
        if host?.rowReleased(self, event: event) == true {
            selectedOnPress = false
            return
        }
        guard wasDown, !state.editing else { return }
        let mods = event.modifierFlags
        if !mods.intersection([.command, .shift]).isEmpty {
            browser.extendTabSelection(to: tab, modifiers: mods)
            selectedOnPress = false
            return
        }
        defer { selectedOnPress = false }
        guard !selectedOnPress else { return }
        if state.live {
            guard event.clickCount >= 2 else { return }
            browser.clearTabSelection()
            browser.goHome(browser.pinTarget(tab))
        } else {
            browser.clearTabSelection()
            browser.select(browser.pinTarget(tab))
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, state.interactive, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.otherMouseUp(with: event)
        }
        guard let tab, let browser else { return }
        browser.hints.closedByPointer()
        browser.closeAsking(tab)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard state.interactive else { return nil }
        return host?.rowMenu(self, event: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let tab, let browser else { return false }
        browser.select(browser.pinTarget(tab))
        return true
    }
}

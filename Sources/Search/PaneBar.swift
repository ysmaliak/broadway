import AppKit
import Combine

@MainActor
final class PaneBarView: NSView {
    let browser: Browser
    private(set) var tab: Tab
    private(set) var focused = false
    private(set) var carrying = false
    private(set) var corner: CGFloat = 0
    private(set) var look: SpaceLook?
    var registers = true

    let ground = PaneBarGround()
    private let title = PaneTitle()
    private let back = PaneDoor("arrow.left", help: "Back", kick: .left)
    private let forward = PaneDoor("arrow.right", help: "Forward", kick: .right)
    private let reload = PaneReload()
    private let site = PaneDoor(SideLook.siteIcon, help: "Site Controls")
    private let close = PaneDoor("xmark", help: "Close Split View")
    private var watch: AnyCancellable?
    private var kicks: Tab.Kicks
    private var settled = false

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        kicks = tab.kicks
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Metrics.paneBar))
        wantsLayer = true
        addSubview(ground)
        addSubview(title)
        for door in [back, forward, reload, site, close] as [NSView] { addSubview(door) }
        back.action = { [weak self] in
            guard let self else { return }
            browser.back(self.tab)
        }
        forward.action = { [weak self] in self?.tab.forward() }
        reload.onReload = { [weak self] in
            guard let self else { return }
            browser.reload(self.tab)
        }
        site.action = { [weak self] in
            guard let self else { return }
            SiteCardPanel.toggle(browser)
        }
        close.action = { [weak self] in
            guard let self else { return }
            browser.leaveSplit(self.tab)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Swap Pages") { [weak self] in
            self?.browser.swapSplit()
            return true
        }])
        rewatch()
        refresh(animated: false)
        settled = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Metrics.paneBar) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === ground || hit === title ? nil : hit
    }

    func show(tab: Tab, focused: Bool, carrying: Bool, corner: CGFloat, look: SpaceLook?) {
        let moved = tab !== self.tab
        let turned = focused != self.focused
        guard moved || turned || carrying != self.carrying || corner != self.corner || look != self.look else { return }
        self.tab = tab
        self.focused = focused
        self.carrying = carrying
        self.corner = corner
        self.look = look
        if moved {
            kicks = tab.kicks
            title.forget()
            rewatch()
        }
        refresh(animated: turned && !moved, moving: moved)
    }

    private func rewatch() {
        let tab = tab
        watch = kitObserve(initial: false, { [weak tab] in
            tab.map { ($0.kicks, $0.isBlank, $0.canGoBack, $0.canGoForward, $0.isWeb, $0.loading, $0.label, $0.address) }
        }) { [weak self] _ in self?.refresh(animated: false) }
    }

    var surface: PaneBarLook {
        PaneBarLook.made((look ?? SpaceLook()).page(dark: kitDark), strong: focused || carrying)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dress(animated: false)
    }

    private func dress(animated: Bool) {
        let surface = surface
        let appearance = NSAppearance(named: surface.dark ? .darkAqua : .aqua)
        for view in [title, back, forward, reload, site, close] as [NSView] where view.appearance?.name != appearance?.name {
            view.appearance = appearance
        }
        ground.corner = corner
        ground.show(surface, backed: carrying, outlined: focused && !carrying, animated: animated)
    }

    private var host: String {
        guard let host = tab.address?.host(), !tab.isBlank else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func refresh(animated: Bool, moving: Bool = false) {
        let now = tab.kicks
        if settled, now.back != kicks.back { back.kickNow() }
        if settled, now.forward != kicks.forward { forward.kickNow() }
        kicks = now
        back.on = !tab.isBlank && tab.canGoBack
        forward.on = !tab.isBlank && tab.canGoForward
        site.on = tab.isWeb
        reload.see(tab)
        reload.present(focused, animated: animated)
        site.present(focused, animated: animated)
        title.show(host, back: tab.goingBack, animated: settled && !moving)
        title.present(focused, animated: animated)
        if focused, registers { SiteCardPanel.register(site, for: browser) }
        dress(animated: animated)
        setAccessibilityLabel("Page controls for \(tab.label)")
        needsLayout = true
    }

    static let inset: CGFloat = 3
    static let gap: CGFloat = 2

    override func layout() {
        super.layout()
        let inset = Self.inset
        let gap = Self.gap
        let box = bounds.height - inset * 2
        let radius = min(box / 2, max(6, corner - inset))
        ground.frame = bounds
        back.frame = NSRect(x: inset, y: inset, width: box, height: box)
        forward.frame = NSRect(x: inset + box + gap, y: inset, width: box, height: box)
        reload.frame = NSRect(x: inset + (box + gap) * 2, y: inset, width: box, height: box)
        close.frame = NSRect(x: bounds.width - inset - box, y: inset, width: box, height: box)
        site.frame = NSRect(x: bounds.width - inset - box * 2 - gap, y: inset, width: box, height: box)
        for door in [back, forward, reload, site, close] as [PaneDoorBase] { door.wash.corners = .radius(radius) }
        let side = inset + (box + gap) * 3 + 8
        title.frame = NSRect(x: side, y: 0, width: max(0, bounds.width - side * 2), height: bounds.height)
    }
}

struct PaneBarLook: Equatable {
    var fill: NSColor
    var line: NSColor
    var dark: Bool

    static func made(_ ground: PageGround, strong: Bool) -> PaneBarLook {
        let fill = ground.flat
        let share: CGFloat = ground.dark ? (strong ? 0.16 : 0.10) : (strong ? 0.15 : 0.09)
        return PaneBarLook(fill: fill, line: line(on: fill, stops: ground.stops, lightInk: ground.dark, share: share), dark: ground.dark)
    }

    static func line(on fill: NSColor, stops: [Oklch], lightInk: Bool, share: CGFloat) -> NSColor {
        let tint = lightInk ? KitTint.of(stops) : nil
        let ink = lightInk
            ? NSColor(srgbRed: tint?.red ?? 1, green: tint?.green ?? 1, blue: tint?.blue ?? 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return LookBlend.mix(fill, ink, min(1, lightInk ? share * (tint?.boost ?? 1) : share))
    }
}

final class PaneBarGround: NSView {
    var corner: CGFloat = 0 { didSet { if corner != oldValue { needsLayout = true } } }
    private(set) var shown: PaneBarLook?
    private(set) var backed = false
    private(set) var outlined = false
    let base = CAShapeLayer()
    let line = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let still: [String: CAAction] = ["path": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                         "backgroundColor": NSNull(), "hidden": NSNull()]
        for part in [base, line] as [CALayer] { part.actions = still }
        base.isHidden = true
        for part in [base, line] as [CALayer] { layer?.addSublayer(part) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func show(_ look: PaneBarLook, backed: Bool, outlined: Bool, animated: Bool) {
        guard look != shown || backed != self.backed || outlined != self.outlined else { return }
        if animated, shown != nil { layer?.kitTransition(Motion.kitQuick) }
        shown = look
        self.backed = backed
        if outlined != self.outlined {
            self.outlined = outlined
            needsLayout = true
        }
        paint()
    }

    private func paint() {
        guard let shown else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.fillColor = shown.fill.cgColor
        base.isHidden = !backed
        line.backgroundColor = shown.line.cgColor
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let hair = 1 / max(1, window?.backingScaleFactor ?? 2)
        let side = outlined ? FocusCue.width : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        base.path = KitPath.continuous(bounds, topLeft: corner, topRight: corner, bottomLeft: 0, bottomRight: 0)
        line.frame = CGRect(x: side, y: bounds.height, width: max(0, bounds.width - side * 2), height: hair)
        CATransaction.commit()
    }
}

@MainActor
class PaneDoorBase: KitButton {
    var on = true {
        didSet {
            guard on != oldValue else { return }
            isEnabled = on
            alphaValue = 1
            fade(animated: false)
            paintDoor()
        }
    }
    private(set) var shown = true
    let wash = KitBox(fill: nil, corners: .radius(8))

    init(label: String) {
        super.init(.plain(press: 0.9), label: label)
        addSubview(wash, positioned: .below, relativeTo: nil)
        onHover = { [weak self] _ in self?.paintDoor(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        wash.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown, !isHidden, frame.contains(point) else { return nil }
        return self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintDoor()
    }

    func present(_ now: Bool, animated: Bool) {
        guard now != shown else { return }
        shown = now
        setAccessibilityElement(now)
        fade(animated: animated)
        paintDoor()
    }

    private func fade(animated: Bool) {
        wantsLayer = true
        let target = Swift.Float((on ? 1 : 0.3) * (shown ? 1 : 0))
        layer?.kitAnimate("opacity", to: target, curve: animated ? Motion.kitQuick : .none, key: "shown")
    }

    var lit: Bool { hovering && on && shown }

    func paintDoor(animated: Bool = false) {
        let fill: NSColor? = lit ? Palette.NS.hover : nil
        if fill != wash.fill {
            if animated { wash.layer?.kitTransition(Motion.kitQuick) }
            wash.fill = fill
        }
    }
}

@MainActor
final class PaneDoor: PaneDoorBase {
    private let symbol: KitSymbol
    private let kick: Kick?

    init(_ icon: String, help: String, kick: Kick? = nil) {
        symbol = KitSymbol(icon, style: .init(size: 13), tint: KitColor.muted)
        self.kick = kick
        super.init(label: help)
        symbol.wantsLayer = true
        content = symbol
        kitAccess(label: help, role: .button, help: help)
        paintDoor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func paintDoor(animated: Bool = false) {
        super.paintDoor(animated: animated)
        let tint = lit ? KitColor.ink : KitColor.muted
        if tint != symbol.tint {
            if animated { symbol.layer?.kitTransition(Motion.kitQuick) }
            symbol.tint = tint
        }
    }

    func kickNow() {
        guard let kick, !Motion.reduced, let layer = symbol.layer else { return }
        let reach: CGFloat = kick == .left ? -3.5 : kick == .right ? 3.5 : 0
        let lift: CGFloat = kick == .lift ? -2.5 : 0
        for (path, value) in [("transform.translation.x", reach), ("transform.translation.y", lift)] where value != 0 {
            let move = CAKeyframeAnimation(keyPath: path)
            move.values = [0, value, 0]
            move.keyTimes = [0, 0.3, 1]
            move.duration = 0.23
            move.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
            move.isAdditive = true
            layer.add(move, forKey: "kick")
        }
    }
}

@MainActor
private final class PaneReload: PaneDoorBase {
    var onReload: (() -> Void)?
    private let glyph = ReloadGlyph(size: 13, stop: false, turns: 0, lit: false)
    private var face = ReloadFace(loading: false)
    private var seen: (loading: Bool, reloads: Int, stops: Int)?
    private weak var tab: Tab?
    private var wait = 0

    init() {
        super.init(label: "Reload")
        content = glyph
        action = { [weak self] in self?.press() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func press() {
        switch face.press {
        case .stop: tab?.stop()
        case .reload: onReload?()
        }
    }

    func see(_ tab: Tab) {
        let now = (loading: tab.loading, reloads: tab.kicks.reload, stops: tab.kicks.stop)
        if self.tab !== tab || seen == nil {
            self.tab = tab
            face = ReloadFace(loading: now.loading, reloads: now.reloads, stops: now.stops)
            seen = now
            wait += 1
        } else if let seen, seen != now {
            self.seen = now
            face.see(loading: now.loading, reloads: now.reloads, stops: now.stops)
            wait += 1
            if face.phase == .starting {
                let ticket = wait
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
                    guard let self, ticket == wait else { return }
                    face.waited()
                    paintDoor()
                }
            }
        }
        paintDoor()
    }

    override func paintDoor(animated: Bool = false) {
        super.paintDoor(animated: animated)
        glyph.show(stop: face.showsStop, turns: tab?.kicks.reload ?? 0, lit: lit)
        kitAccess(label: face.label, role: .button, help: face.help)
    }
}

private final class PaneTitle: NSView {
    private var label = PaneTitle.make("")
    private var leaving: KitLabel?
    private var text = ""
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
        layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static func make(_ text: String) -> KitLabel {
        let made = KitLabel(text, font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ink)
        made.overflow = .middle
        made.alignment = .center
        made.wantsLayer = true
        return made
    }

    func forget() {
        leaving?.removeFromSuperview()
        leaving = nil
        text = ""
        label.text = ""
    }

    func present(_ now: Bool, animated: Bool) {
        guard now != shown else { return }
        shown = now
        setAccessibilityElement(false)
        label.setAccessibilityElement(now)
        layer?.kitAnimate("opacity", to: Swift.Float(now ? 1 : 0), curve: animated ? Motion.kitQuick : .none, key: "shown")
    }

    func show(_ next: String, back: Bool, animated: Bool) {
        guard next != text else { return }
        let before = text
        text = next
        let move = animated ? AddressMove.between(before, next, cause: .navigation(back: back),
                                                  reduced: Motion.reduced) : .still
        leaving?.removeFromSuperview()
        leaving = nil
        guard move != .still else {
            label.text = next
            label.setAccessibilityValue(next)
            return
        }
        let old = label
        let made = Self.make(next)
        addSubview(made)
        label = made
        leaving = old
        old.setAccessibilityElement(false)
        layoutLabels()
        let shift: CGFloat = if case let .slide(back) = move { back ? -20 : 20 } else { 0 }
        let curve: KitCurve = Motion.kitRoll
        let times: (leave: Double, start: Double, end: Double) = (0.077, 0.039, 0.129)
        let length: Double = 0.3
        if shift != 0 {
            if let arrive = curve.animation("transform.translation.x", from: shift, to: 0) { made.layer?.add(arrive, forKey: "slide") }
            if let go = curve.animation("transform.translation.x", from: 0, to: -shift) {
                go.fillMode = .forwards
                go.isRemovedOnCompletion = false
                old.layer?.add(go, forKey: "slide")
            }
        }
        let fadeIn = CAKeyframeAnimation(keyPath: "opacity")
        fadeIn.values = [0, 0, 1, 1]
        fadeIn.keyTimes = [0, NSNumber(value: times.start / length), NSNumber(value: times.end / length), 1]
        fadeIn.duration = length
        made.layer?.add(fadeIn, forKey: "fade")
        let fadeOut = CAKeyframeAnimation(keyPath: "opacity")
        fadeOut.values = [1, 0, 0]
        fadeOut.keyTimes = [0, NSNumber(value: times.leave / length), 1]
        fadeOut.duration = length
        fadeOut.fillMode = .forwards
        fadeOut.isRemovedOnCompletion = false
        old.layer?.add(fadeOut, forKey: "fade")
        DispatchQueue.main.asyncAfter(deadline: .now() + length) { [weak self, weak old] in
            guard let self, let old, leaving === old else { return }
            old.removeFromSuperview()
            leaving = nil
        }
    }

    override func layout() {
        super.layout()
        layoutLabels()
    }

    private func layoutLabels() {
        for view in [label, leaving].compactMap({ $0 }) { view.frame = bounds }
    }
}

@MainActor
enum PaneGrip {
    enum Step: Equatable {
        case began
        case moved(CGFloat)
        case ended
        case cancelled
    }

    final class Grip: NSView {
        var focus: () -> Void = {}
        var step: (Step) -> Void = { _ in }
        private var pressed: NSEvent?
        private var carrying = false
        private var over = false
        private var keys: Any?
        private static weak var carrier: Grip?

        static func escape(_ event: NSEvent) -> Bool {
            guard let carrier else { return false }
            return carrier.key(event) == nil
        }

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func isAccessibilityElement() -> Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            hover(false)
            if carrying { finish(.cancelled) }
            super.viewWillMove(toWindow: newWindow)
        }

        private func hover(_ on: Bool) {
            guard let window, on != over else { return }
            over = on
            WindowHold.hover(window, on)
        }

        override func mouseDown(with event: NSEvent) {
            pressed = event
            carrying = false
            if event.clickCount == 1 { focus() }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let pressed else { return }
            let dx = event.locationInWindow.x - pressed.locationInWindow.x
            let dy = event.locationInWindow.y - pressed.locationInWindow.y
            if !carrying {
                guard abs(dx) >= 3 || abs(dy) >= 3 else { return }
                carrying = true
                Self.carrier = self
                watchKeys()
                step(.began)
            }
            step(.moved(dx))
        }

        override func mouseUp(with event: NSEvent) {
            defer { pressed = nil }
            if carrying { return finish(.ended) }
            guard pressed != nil, event.clickCount == 2, let window else { return }
            WindowHold.doubleClick(window)
        }

        private func finish(_ last: Step) {
            if Self.carrier === self { Self.carrier = nil }
            carrying = false
            pressed = nil
            if let keys { NSEvent.removeMonitor(keys) }
            keys = nil
            step(last)
        }

        private func watchKeys() {
            guard keys == nil else { return }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.key(event) ?? event
            }
        }

        private func key(_ event: NSEvent) -> NSEvent? {
            guard carrying, event.keyCode == 53 else { return event }
            finish(.cancelled)
            return nil
        }
    }
}

@MainActor
final class CarriedCardView: NSView {
    static let height: CGFloat = 36
    private let shade = NSView()
    private let glass = KitGlass(radius: Metrics.sideRadius, tint: Palette.NS.glassTint)
    private let edge = KitBox(fill: nil, stroke: NSColor.controlAccentColor.withAlphaComponent(0.8), corners: .radius(Metrics.sideRadius))
    private let mark = KitMark(icon: nil, letter: "", side: 15)
    private let title = KitLabel("", font: .systemFont(ofSize: 13, weight: .medium), color: KitColor.ink)
    private var watch: AnyCancellable?
    private weak var tab: Tab?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.wantsLayer = true
        addSubview(shade)
        addSubview(glass)
        addSubview(mark)
        addSubview(title)
        addSubview(edge)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ tab: Tab) {
        if self.tab !== tab {
            self.tab = tab
            watch = kitObserve(initial: false, { [weak tab] in tab.map { ($0.icon, $0.monogram, $0.label) } }) { [weak self] _ in
                self?.refresh()
            }
        }
        refresh()
    }

    private func refresh() {
        guard let tab else { return }
        mark.icon = tab.icon
        mark.letter = tab.monogram
        title.text = tab.label.isEmpty ? "New Tab" : tab.label
        let width = min(190, ceil(10 + 15 + 7 + title.intrinsicContentSize.width + 10))
        setFrameSize(NSSize(width: width, height: Self.height))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        shade.frame = bounds
        if let layer = shade.layer {
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.28
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: 5)
            layer.shadowPath = KitPath.continuous(bounds, radius: Metrics.sideRadius)
        }
        glass.frame = bounds
        edge.frame = bounds
        mark.frame = kitSnap(NSRect(x: 10, y: (bounds.height - 15) / 2, width: 15, height: 15))
        let left: CGFloat = 10 + 15 + 7
        let height = title.intrinsicContentSize.height
        title.frame = kitSnap(NSRect(x: left, y: (bounds.height - height) / 2, width: max(0, bounds.width - left - 10), height: height))
    }
}

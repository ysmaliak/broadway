import AppKit

enum PopupEdge: Equatable {
    case auto, page, right, left, below, above

    var opposite: PopupEdge {
        switch self {
        case .auto: .auto
        case .page: .page
        case .right: .left
        case .left: .right
        case .below: .above
        case .above: .below
        }
    }

    var sideways: Bool { self == .right || self == .left }
}

struct PopupPlacement: Equatable {
    var frame: CGRect
    var edge: PopupEdge
}

enum PopupPress: Equatable {
    case inside, anchor, margin, outside
}

struct PopupAnswer: Equatable {
    var closes: Bool
    var eats: Bool
}

@MainActor
final class KitPopup {
    static let willShow = Notification.Name("KitPopup.willShow")
    static var sideOnRight: (NSWindow) -> Bool = { _ in false }
    static var inSidebar: (NSView) -> Bool = { _ in false }

    nonisolated static func place(anchor: CGRect, size: CGSize, edge wanted: PopupEdge, sideOnRight: Bool,
                                  screen: CGRect, window: CGRect? = nil) -> PopupPlacement {
        let room = screen.insetBy(dx: PopupLook.margin, dy: PopupLook.margin)
        let gap = PopupLook.gap
        let preferred = wanted == .page ? (sideOnRight ? PopupEdge.left : .right) : wanted == .auto ? .below : wanted
        func space(_ edge: PopupEdge) -> CGFloat {
            switch edge {
            case .right, .page: room.maxX - (anchor.maxX + gap)
            case .left: anchor.minX - gap - room.minX
            case .below, .auto: anchor.minY - gap - room.minY
            case .above: room.maxY - (anchor.maxY + gap)
            }
        }
        let need = preferred.sideways ? size.width : size.height
        var edge = preferred
        if space(preferred) < need {
            let other = preferred.opposite
            if space(other) >= need || space(other) > space(preferred) { edge = other }
        }
        let width = min(size.width, room.width)
        var height = min(size.height, room.height)
        var frame = CGRect.zero
        switch edge {
        case .right, .left, .page:
            let x = edge == .left ? anchor.minX - gap - width : anchor.maxX + gap
            let y = anchor.maxY - height
            frame = CGRect(x: x, y: y, width: width, height: height)
        case .below, .auto:
            height = min(height, max(0, space(.below)))
            frame = CGRect(x: anchor.minX, y: anchor.minY - gap - height, width: width, height: height)
        case .above:
            height = min(height, max(0, space(.above)))
            frame = CGRect(x: anchor.minX, y: anchor.maxY + gap, width: width, height: height)
        }
        if edge.sideways, let window, frame.height <= window.height - PopupLook.margin * 2 {
            frame.origin.y = min(max(frame.minY, window.minY + PopupLook.margin), window.maxY - PopupLook.margin - frame.height)
        }
        frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, room.minY), room.maxY - frame.height)
        return PopupPlacement(frame: frame, edge: edge)
    }

    nonisolated static func growth(anchor: CGRect, frame: CGRect, edge: PopupEdge) -> CGPoint {
        let x = min(max(anchor.midX, frame.minX), frame.maxX) - frame.minX
        let y = min(max(anchor.midY, frame.minY), frame.maxY) - frame.minY
        switch edge {
        case .right, .page: return CGPoint(x: 0, y: y)
        case .left: return CGPoint(x: frame.width, y: y)
        case .below, .auto: return CGPoint(x: x, y: frame.height)
        case .above: return CGPoint(x: x, y: 0)
        }
    }

    nonisolated static func scale(_ scale: CGFloat, around point: CGPoint, anchorPoint: CGPoint, size: CGSize) -> CATransform3D {
        let dx = point.x - anchorPoint.x * size.width
        let dy = point.y - anchorPoint.y * size.height
        var made = CATransform3DMakeTranslation(dx, dy, 0)
        made = CATransform3DScale(made, scale, scale, 1)
        return CATransform3DTranslate(made, -dx, -dy, 0)
    }

    nonisolated static func press(onPanel: Bool, inSurface: Bool, inAnchor: Bool) -> PopupPress {
        if onPanel { return inSurface ? .inside : .margin }
        return inAnchor ? .anchor : .outside
    }

    nonisolated static func answer(_ press: PopupPress, follows: Bool) -> PopupAnswer {
        switch press {
        case .inside: PopupAnswer(closes: false, eats: false)
        case .margin: PopupAnswer(closes: true, eats: true)
        case .anchor: follows ? PopupAnswer(closes: false, eats: false) : PopupAnswer(closes: true, eats: true)
        case .outside: PopupAnswer(closes: true, eats: false)
        }
    }

    nonisolated static func answer(key code: UInt16, follows: Bool) -> PopupAnswer {
        code == 53 && !follows ? PopupAnswer(closes: true, eats: true) : PopupAnswer(closes: false, eats: false)
    }

    private(set) static var shown: [ObjectIdentifier: KitPopup] = [:]
    private static var leaving: [ObjectIdentifier: KitPopup] = [:]
    private static var monitor: Any?
    private static var eatsUp = false

    var content: NSView { stage.surface.content }
    let focus: Bool
    let follows: Bool
    var passive = false { didSet { panel?.ignoresMouseEvents = passive } }
    private(set) weak var anchor: NSView?
    private(set) var spot: NSRect
    private(set) var size: NSSize
    private(set) var edge: PopupEdge
    private(set) var placement: PopupPlacement?
    private(set) var panel: KitPopupPanel?
    private(set) var closing = false
    let stage: KitPopupStage
    private var onClose: (() -> Void)?
    private weak var parent: NSWindow?
    private var glides = 0
    private(set) var gliding = false { didSet { stage.holds = gliding } }
    private var watching: [NSObjectProtocol] = []

    var isShown: Bool { panel != nil && !closing }

    private init(content: NSView, size: NSSize, spot: NSRect, anchor: NSView, edge: PopupEdge, focus: Bool,
                 follows: Bool, onClose: (() -> Void)?) {
        self.follows = follows
        self.edge = edge
        self.size = size
        self.spot = spot
        self.anchor = anchor
        self.focus = focus
        self.onClose = onClose
        stage = KitPopupStage(content)
    }

    static func current(in window: NSWindow?) -> KitPopup? {
        guard let window else { return nil }
        return shown[ObjectIdentifier(window)]
    }

    @discardableResult
    static func show(_ content: NSView, size: NSSize, from rect: NSRect, of view: NSView, edge: PopupEdge = .below,
                     focus: Bool = false, follows: Bool = false, bleeds: Bool = false, passive: Bool = false,
                     onClose: (() -> Void)? = nil) -> KitPopup? {
        guard let window = view.window else { return nil }
        NotificationCenter.default.post(name: willShow, object: window)
        current(in: window)?.close(animated: false)
        let key = ObjectIdentifier(window)
        var start: (opacity: Swift.Float, scale: CGFloat)?
        if let old = leaving[key] {
            if old.anchor === view { start = old.now }
            old.drop()
        }
        let popup = KitPopup(content: content, size: size, spot: rect, anchor: view, edge: edge, focus: focus, follows: follows,
                             onClose: onClose)
        popup.stage.surface.inset = bleeds ? 0 : PopupLook.inset
        popup.passive = passive
        popup.open(in: window, from: start)
        return popup
    }

    private func open(in window: NSWindow, from start: (opacity: Swift.Float, scale: CGFloat)?) {
        let panel = KitPopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.takesKey = focus
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = !focus
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = stage
        panel.ignoresMouseEvents = passive
        self.panel = panel
        parent = window
        Self.shown[ObjectIdentifier(window)] = self
        place()
        stage.layoutSubtreeIfNeeded()
        enter(from: start)
        window.addChildWindow(panel, ordered: .above)
        if focus { panel.makeKey() }
        observe(window, panel)
        Self.watch()
        NSAccessibility.post(element: stage.surface, notification: .created)
        NSAccessibility.post(element: stage.surface, notification: .layoutChanged, userInfo: [.uiElements: [stage.surface]])
    }

    static func closeAll(in window: NSWindow?) {
        current(in: window)?.close()
    }

    private func observe(_ window: NSWindow, _ panel: NSPanel) {
        let center = NotificationCenter.default
        let gone: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.close(animated: false) }
        }
        let resigned: (Notification) -> Void = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let panel = self.panel else { return }
                let key = NSApp.keyWindow
                if key !== panel, key !== self.parent { self.close() }
            }
        }
        watching = [
            center.addObserver(forName: NSWindow.willMoveNotification, object: window, queue: .main, using: gone),
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: gone),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: resigned),
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main, using: resigned),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: gone),
        ]
    }

    private static func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .keyDown]) { event in
            MainActor.assumeIsolated { heard(event) } ? nil : event
        }
    }

    private static func unwatch() {
        guard shown.isEmpty, !eatsUp, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    static func heard(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseUp:
            guard eatsUp else { return false }
            eatsUp = false
            DispatchQueue.main.async { unwatch() }
            return true
        case .keyDown:
            guard let popup = shown.values.first(where: { $0.owns(event.window) }) else { return false }
            let answer = answer(key: event.keyCode, follows: popup.follows)
            if answer.closes { popup.close() }
            return answer.eats
        default:
            var eats = false
            for popup in Array(shown.values) {
                let answer = answer(popup.press(event), follows: popup.follows)
                if answer.closes { popup.close() }
                eats = eats || answer.eats
            }
            if eats, event.type == .leftMouseDown { eatsUp = true }
            return eats
        }
    }

    private func owns(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === panel || window === parent
    }

    func press(_ event: NSEvent) -> PopupPress {
        let onPanel = event.window != nil && event.window === panel
        let inSurface = onPanel && stage.surface.frame.contains(stage.convert(event.locationInWindow, from: nil))
        var inAnchor = false
        if !onPanel, let anchor, event.window != nil, event.window === anchor.window {
            inAnchor = spot.contains(anchor.convert(event.locationInWindow, from: nil))
        }
        return Self.press(onPanel: onPanel, inSurface: inSurface, inAnchor: inAnchor)
    }

    private var anchorRect: NSRect? {
        guard let anchor, let window = anchor.window else { return nil }
        return window.convertToScreen(anchor.convert(spot, to: nil))
    }

    private func place() {
        guard let panel, let anchor = anchorRect, let window = self.anchor?.window else { return }
        let screen = window.screen?.visibleFrame ?? window.frame.insetBy(dx: -10_000, dy: -10_000)
        let wanted = edge == .auto ? (self.anchor.map(Self.inSidebar) == true ? PopupEdge.page : .below) : edge
        let placed = Self.place(anchor: anchor, size: PopupLook.surface(for: size, inset: stage.surface.inset), edge: wanted,
                                sideOnRight: Self.sideOnRight(window), screen: screen, window: window.frame)
        placement = placed
        stage.surface.contentSize = size
        let outer = placed.frame.insetBy(dx: -PopupLook.room, dy: -PopupLook.room)
        guard gliding else {
            panel.setFrame(outer, display: true)
            return
        }
        let whole = panel.frame.union(outer)
        if whole != panel.frame { panel.setFrame(whole, display: false) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.surface.frame = placed.frame.offsetBy(dx: -whole.minX, dy: -whole.minY)
        CATransaction.commit()
    }

    var growthPoint: CGPoint {
        guard let placement, let anchor = anchorRect else { return .zero }
        return Self.growth(anchor: anchor, frame: placement.frame, edge: placement.edge)
    }

    private func scaled(_ scale: CGFloat) -> CATransform3D {
        guard let layer = stage.surface.layer else { return CATransform3DIdentity }
        return Self.scale(scale, around: growthPoint, anchorPoint: layer.anchorPoint, size: layer.bounds.size)
    }

    private var now: (opacity: Swift.Float, scale: CGFloat)? {
        guard let layer = stage.surface.layer else { return nil }
        let shown = layer.presentation() ?? layer
        return (opacity: shown.opacity, scale: CGFloat(shown.transform.m11))
    }

    private func enter(from start: (opacity: Swift.Float, scale: CGFloat)?) {
        guard let layer = stage.surface.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        layer.removeAnimation(forKey: "popup.fade")
        layer.removeAnimation(forKey: "popup.grow")
        guard !Motion.reduced else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = start?.opacity ?? 0
        fade.toValue = Swift.Float(1)
        fade.duration = PopupLook.fadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "popup.fade")
        let from = NSValue(caTransform3D: scaled(start?.scale ?? PopupLook.fromScale))
        layer.add(PopupLook.grow.animation("transform", from: from, to: NSValue(caTransform3D: CATransform3DIdentity)),
                  forKey: "popup.grow")
    }

    func resize(to next: NSSize) {
        guard next.width > 0, next.height > 0, next != size, !closing else { return }
        size = next
        place()
    }

    func hold(_ next: NSView, size wanted: NSSize) {
        guard !closing else { return }
        stage.surface.hold(next)
        size = wanted
        place()
    }

    func move(to rect: NSRect, of view: NSView) {
        guard panel != nil, !closing, view.window === anchor?.window else { return }
        let before = placement?.frame
        spot = rect
        anchor = view
        place()
        guard let panel, let before, let after = placement?.frame, before != after, !Motion.calm,
              let layer = stage.surface.layer else { return }
        let room = PopupLook.room
        let whole = before.union(after).insetBy(dx: -room, dy: -room)
        panel.setFrame(whole, display: false)
        glides += 1
        gliding = true
        let glide = glides
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stage.surface.frame = after.offsetBy(dx: -whole.minX, dy: -whole.minY)
        CATransaction.commit()
        let shift = NSValue(size: NSSize(width: before.minX - after.minX, height: before.minY - after.minY))
        let slide = KitSpring(response: 0.3, damping: 0.84).animation("transform.translation", from: shift,
                                                                       to: NSValue(size: .zero))
        slide.isAdditive = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.glides == glide, self.panel != nil, !self.closing else { return }
                self.gliding = false
                self.place()
                self.stage.needsLayout = true
            }
        }
        layer.add(slide, forKey: "glide")
        CATransaction.commit()
    }

    func close(animated: Bool = true) {
        guard let panel, !closing else { return }
        if let parent, Self.shown[ObjectIdentifier(parent)] === self { Self.shown[ObjectIdentifier(parent)] = nil }
        watching.forEach { NotificationCenter.default.removeObserver($0) }
        watching = []
        let done = onClose
        onClose = nil
        guard animated, !Motion.reduced, let layer = stage.surface.layer, let parent else {
            drop()
            done?()
            return
        }
        closing = true
        panel.ignoresMouseEvents = true
        if panel.isKeyWindow { parent.makeKey() }
        Self.leaving[ObjectIdentifier(parent)] = self
        let from = now
        let goal = scaled(PopupLook.toScale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = 0
        layer.transform = goal
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.closing else { return }
                self.drop()
            }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from?.opacity ?? 1
        fade.toValue = Swift.Float(0)
        fade.duration = PopupLook.fadeOut
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "popup.fade")
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: layer.presentation()?.transform ?? CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: goal)
        shrink.duration = PopupLook.fadeOut
        shrink.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(shrink, forKey: "popup.grow")
        CATransaction.commit()
        done?()
    }

    private func drop() {
        closing = false
        watching.forEach { NotificationCenter.default.removeObserver($0) }
        watching = []
        if let parent {
            let key = ObjectIdentifier(parent)
            if Self.shown[key] === self { Self.shown[key] = nil }
            if Self.leaving[key] === self { Self.leaving[key] = nil }
        }
        guard let panel else { return }
        self.panel = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        Self.unwatch()
    }
}

final class KitPopupPanel: NSPanel {
    var takesKey = false

    override var canBecomeKey: Bool { takesKey }
    override var canBecomeMain: Bool { false }
}

final class KitPopupStage: NSView {
    let surface: KitPopupSurface

    init(_ content: NSView) {
        surface = KitPopupSurface(content)
        super.init(frame: .zero)
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var surfaceFrame: NSRect { bounds.insetBy(dx: PopupLook.room, dy: PopupLook.room) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard surface.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    var holds = false

    override func layout() {
        super.layout()
        if !holds { surface.frame = surfaceFrame }
    }
}

final class KitPopupSurface: NSView {
    private(set) var content: NSView
    let clip = NSView()
    let scroll = NSScrollView()
    private let document = KitFlippedView()

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        scroll.documentView = document
        document.addSubview(content)
        clip.addSubview(scroll)
        addSubview(clip)
        setAccessibilityElement(true)
        setAccessibilityRole(.popover)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override var wantsUpdateLayer: Bool { true }

    var contentSize = NSSize.zero { didSet { if contentSize != oldValue { needsLayout = true } } }

    func hold(_ next: NSView) {
        guard next !== content else { return }
        content.removeFromSuperview()
        content = next
        document.addSubview(next)
        needsLayout = true
    }
    var inset = PopupLook.inset { didSet { if inset != oldValue { needsLayout = true } } }

    override func layout() {
        super.layout()
        clip.frame = bounds
        let inner = bounds.insetBy(dx: inset, dy: inset)
        scroll.frame = inner
        let size = NSSize(width: inner.width, height: max(inner.height, contentSize.height))
        if document.frame.size != size {
            document.frame = NSRect(origin: .zero, size: size)
            scroll.documentView?.scroll(.zero)
        }
        if content.frame.size != size { content.frame = NSRect(origin: .zero, size: size) }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer, let clipLayer = clip.layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var ground = PopupLook.ground.cgColor
        var edge = PopupLook.edge.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ground = PopupLook.ground.cgColor
            edge = PopupLook.edge.cgColor
        }
        clipLayer.backgroundColor = ground
        clipLayer.cornerRadius = PopupLook.corner
        clipLayer.cornerCurve = .continuous
        clipLayer.masksToBounds = true
        clipLayer.borderColor = edge
        clipLayer.borderWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
        let shadow = PopupLook.shadow
        layer.masksToBounds = false
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = dark ? shadow.dark : shadow.light
        layer.shadowRadius = shadow.radius
        layer.shadowOffset = CGSize(width: 0, height: -shadow.y)
        layer.shadowPath = KitPath.continuous(bounds, radius: PopupLook.corner)
    }
}

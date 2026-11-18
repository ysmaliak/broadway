import AppKit

@MainActor
final class TearOff {
    static let shared = TearOff()

    private(set) var out = false
    private(set) var tabID: Tab.ID?
    private(set) var point: NSPoint = .zero
    private(set) weak var target: Browser?
    private(set) var place: ListDrop?
    private weak var source: Browser?
    private weak var page: SidePageView?
    private weak var aimed: SidePageView?
    private var state = TearRules.State()
    private var last: NSPoint?
    private var refused = false
    let ghost = TearGhost()

    private init() {}

    static func facts(_ tab: Tab, in browser: Browser) -> TearRules.Facts {
        let live = tab.liveKey != nil || tab.groupID.map { id in browser.tabGroups.contains { $0.id == id && $0.live } } == true
        return TearRules.Facts(pin: tab.pin != nil, bench: tab.bench, live: live, agent: tab.agent)
    }

    static func mayLeave(_ tab: Tab, in browser: Browser) -> Bool { TearRules.mayLeave(facts(tab, in: browser)) }

    static func newWindow(at point: NSPoint, leaving window: NSWindow?) -> NSRect {
        let zoomed = window.map { window in
            window.isZoomed || window.screen.map { TearRules.fills(window.frame, $0.visibleFrame) } == true
        } ?? false
        let visible = (NSScreen.screens.first { TearRules.inside(point, $0.frame) } ?? window?.screen)?.visibleFrame
        return TearRules.newWindow(at: point, leaving: window?.frame.size, zoomed: zoomed, visible: visible)
    }

    static func taker(for browser: Browser, at point: NSPoint) -> Browser? {
        Browsers.all.first { other in
            other !== browser && other.isOpen
                && TearRules.takes(sourcePrivate: browser.isPrivate, targetPrivate: other.isPrivate, targetPopup: other.isPopup)
                && other.window?.frame.contains(point) == true
        }
    }

    static func page(of browser: Browser, at point: NSPoint) -> SidePageView? {
        guard let window = browser.window, let content = window.contentView else { return nil }
        let local = window.convertPoint(fromScreen: point)
        return content.kitSubviews(of: SidePageView.self).first { view in
            view.preview == nil && !view.isHiddenOrHasHiddenAncestor && view.window === window
                && view.bounds.contains(view.convert(local, from: nil))
        }
    }

    static func mayLeave(_ tab: Tab, in browser: Browser, whole: Bool) -> Bool {
        guard whole, let pair = browser.split(for: tab) else { return mayLeave(tab, in: browser) }
        let halves = browser.tabs.filter { pair.contains($0.id) }
        return halves.count == pair.tabs.count && halves.allSatisfy { mayLeave($0, in: browser) }
    }

    func drag(_ page: SidePageView, tab: Tab, at point: NSPoint, moved: CGVector?, whole: Bool = false) -> Bool {
        let browser = page.browser
        if tabID != tab.id || self.page !== page { begin(page, tab) }
        guard !refused, Self.mayLeave(tab, in: browser, whole: whole), let window = browser.window else { return false }
        let delta = moved ?? last.map { CGVector(dx: point.x - $0.x, dy: point.y - $0.y) } ?? .zero
        let screen = window.screen.map { TearRules.Screen(frame: $0.frame, visible: $0.visibleFrame) }
        state = TearRules.step(state, from: last, point: point, moved: delta, window: window.frame, screen: screen)
        last = point
        self.point = point
        out = state.out
        if out {
            aim(browser, tab, at: point)
            ghost.show(tab, in: browser, ground: page.ground, at: point)
            watch()
        } else {
            unaim()
            ghost.hide()
        }
        return out
    }

    func letGo(_ page: SidePageView, _ tab: Tab, whole: Bool = false) -> Bool {
        defer { end() }
        let browser = page.browser
        guard out, !refused, self.page === page, Self.mayLeave(tab, in: browser, whole: whole),
              browser.tabs.contains(where: { $0.id == tab.id }) else { return false }
        let over = target
        let place = over == nil ? nil : self.place
        let point = self.point
        let going = whole ? browser.split(for: tab)?.tabs.count ?? 1 : 1
        guard over != nil || browser.tabs.count > going else { return true }
        DispatchQueue.main.async { [weak browser, weak over] in
            guard let browser else { return }
            if whole { browser.moveToWindow(pairOf: tab, over, at: point) } else { browser.moveToWindow(tab, over, at: point) }
            if let over, let place, over.tabs.contains(where: { $0.id == tab.id }) { over.placeTorn(tab, place) }
        }
        return true
    }

    func cancelled() {
        guard tabID != nil else { return }
        refused = true
        out = false
        unaim()
        ghost.hide()
    }

    func end(_ page: SidePageView? = nil) {
        if let page, self.page !== page { return }
        unaim()
        ghost.hide()
        tabID = nil
        source = nil
        self.page = nil
        state = TearRules.State()
        last = nil
        out = false
        refused = false
    }

    private func begin(_ page: SidePageView, _ tab: Tab) {
        end()
        tabID = tab.id
        source = page.browser
        self.page = page
    }

    private func watch() {
        guard !Store.testing else { return }
        let id = tabID
        let at = point
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.tabID == id, self.point == at, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.end()
        }
    }

    private func aim(_ browser: Browser, _ tab: Tab, at point: NSPoint) {
        let leaving = browser.window.map { TearRules.aims(point, leaving: $0.frame) } ?? true
        let over = leaving ? Self.taker(for: browser, at: point) : nil
        let side = over.flatMap { Self.page(of: $0, at: point) }
        if aimed !== side { aimed?.tearAim(tab, at: nil) }
        aimed = side
        target = over
        if let side, let window = side.window {
            place = side.tearAim(tab, at: side.convert(window.convertPoint(fromScreen: point), from: nil))
        } else {
            place = nil
        }
    }

    private func unaim() {
        aimed?.tearAim(nil, at: nil)
        aimed = nil
        target = nil
        place = nil
    }
}

extension Browser {
    func placeTorn(_ tab: Tab, _ place: ListDrop) {
        switch place {
        case .folder(let target): move(tab, toGroup: target)
        case .loose(let loose):
            if prefs.usesTabGroups, group(of: tab) != nil {
                moveOut(tab, before: loose.before)
            } else {
                moveLoose(tab, before: loose.before)
            }
        }
    }
}

@MainActor
final class TearGhost {
    private var panel: NSPanel?
    private let plate = TearGhostView()
    private(set) var up = false
    private(set) var picture: NSImage?
    private var shownID: Tab.ID?
    private var asked: UUID?

    var frame: NSRect { panel?.frame ?? .zero }
    var number: Int { panel?.windowNumber ?? 0 }
    var shown: Bool { panel?.isVisible ?? false }
    var moving: [String] { ([plate.layer] + (plate.layer?.sublayers ?? [])).compactMap { $0?.animationKeys() }.flatMap { $0 } }

    func show(_ tab: Tab, in browser: Browser, ground: RowGround, at point: NSPoint) {
        let panel = self.panel ?? make()
        if shownID != tab.id || !up {
            shownID = tab.id
            let cached = browser.tabSwitcher.preview(for: tab.id, address: tab.address)
                ?? (browser.hoverCards.kind == .tab(tab.id) ? browser.hoverCards.picture : nil)
            picture = cached
            plate.dress(picture: cached, tab: tab, ground: ground)
            if cached == nil { fetch(tab, ground: ground) }
        }
        place(panel, at: point)
        guard !up else { return }
        up = true
        if !(Store.testing && NSApp.isHidden) { panel.orderFrontRegardless() }
        plate.appear()
    }

    func hide() {
        guard up else { return }
        up = false
        shownID = nil
        asked = nil
        plate.disappear { [weak self] in
            guard let self, !self.up else { return }
            self.panel?.orderOut(nil)
        }
    }

    private func fetch(_ tab: Tab, ground: RowGround) {
        let request = UUID()
        asked = request
        let id = tab.id
        tab.preview(width: TearLook.width * 2) { [weak self, weak tab] image in
            MainActor.assumeIsolated {
                guard let self, let tab, let image, self.asked == request, self.shownID == id else { return }
                self.picture = image
                self.plate.dress(picture: image, tab: tab, ground: ground)
                if let panel = self.panel { self.place(panel, at: TearOff.shared.point) }
            }
        }
    }

    private func make() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.animationBehavior = .none
        panel.contentView = plate
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel, at point: NSPoint) {
        let size = plate.size
        let room = TearLook.room
        let frame = NSRect(x: point.x - TearLook.grab.width - room, y: point.y + TearLook.grab.height + room - size.height - 2 * room,
                           width: size.width + 2 * room, height: size.height + 2 * room)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }
}

final class TearGhostView: NSView {
    private let shadowLayer = CALayer()
    private let clip = CALayer()
    private let image = CALayer()
    private let icon = CALayer()
    private let iconShape = CALayer()
    private let title = CATextLayer()
    private(set) var size = NSSize(width: TearLook.width, height: TearLook.cardHeight)
    private var ground = NSColor.windowBackgroundColor
    private var ink = NSColor.labelColor

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.addSublayer(shadowLayer)
        layer?.addSublayer(clip)
        clip.masksToBounds = true
        clip.cornerRadius = TearLook.corner
        clip.cornerCurve = .continuous
        clip.addSublayer(image)
        clip.addSublayer(icon)
        clip.addSublayer(title)
        image.contentsGravity = .resizeAspectFill
        icon.contentsGravity = .resizeAspect
        iconShape.contentsGravity = .resizeAspect
        title.truncationMode = .end
        title.isWrapped = false
        title.fontSize = TearLook.titleSize
        title.font = NSFont.systemFont(ofSize: TearLook.titleSize, weight: .medium)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func cropped(_ picture: NSImage) -> (image: CGImage, size: NSSize)? {
        guard let cg = picture.cgImage(forProposedRect: nil, context: nil, hints: nil), cg.width > 0, cg.height > 0 else { return nil }
        let full = CGFloat(cg.height) / CGFloat(cg.width)
        let ratio = min(full, TearLook.aspect)
        let rows = max(1, Int((CGFloat(cg.width) * ratio).rounded()))
        let kept = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: min(cg.height, rows))) ?? cg
        return (kept, NSSize(width: TearLook.width, height: (TearLook.width * ratio).rounded()))
    }

    func dress(picture: NSImage?, tab: Tab, ground row: RowGround) {
        let average = row.stops.map { Paint.Ground(stops: $0, lightInk: row.dark).average.rgb }
        ground = average.map { NSColor(srgbRed: $0.r, green: $0.g, blue: $0.b, alpha: 1) } ?? .windowBackgroundColor
        ink = row.stops == nil ? .labelColor : row.dark ? .white : .black
        if let picture, let cut = Self.cropped(picture) {
            size = cut.size
            image.contents = cut.image
            image.isHidden = false
            icon.isHidden = true
            title.isHidden = true
        } else {
            size = NSSize(width: TearLook.width, height: TearLook.cardHeight)
            image.contents = nil
            image.isHidden = true
            icon.isHidden = false
            title.isHidden = false
            let shape = tab.icon?.isTemplate == true
            icon.contents = shape ? nil : tab.icon
            iconShape.contents = shape ? tab.icon : nil
            icon.mask = shape ? iconShape : nil
            title.string = tab.label
        }
        needsLayout = true
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var edge = TearLook.edge.cgColor
        var fill = ground.cgColor
        var text = ink.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            edge = TearLook.edge.cgColor
            fill = self.ground.cgColor
            text = self.ink.cgColor
        }
        clip.backgroundColor = fill
        clip.borderColor = edge
        clip.borderWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
        title.foregroundColor = text
        icon.backgroundColor = icon.mask == nil ? nil : text
        title.contentsScale = window?.backingScaleFactor ?? 2
        let shadow = TearLook.shadow
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = dark ? shadow.dark : shadow.light
        shadowLayer.shadowRadius = shadow.radius
        shadowLayer.shadowOffset = CGSize(width: 0, height: shadow.y)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let room = TearLook.room
        let card = CGRect(x: room, y: room, width: size.width, height: size.height)
        shadowLayer.frame = card
        shadowLayer.shadowPath = KitPath.continuous(CGRect(origin: .zero, size: card.size), radius: TearLook.corner)
        clip.frame = card
        image.frame = CGRect(origin: .zero, size: card.size)
        let pad = TearLook.pad
        icon.frame = CGRect(x: pad, y: pad, width: TearLook.icon, height: TearLook.icon)
        iconShape.frame = icon.bounds
        title.frame = CGRect(x: pad, y: pad + TearLook.icon + 8, width: card.width - 2 * pad, height: TearLook.titleSize + 4)
        let grab = CGPoint(x: room + TearLook.grab.width, y: room + TearLook.grab.height)
        for part in [shadowLayer, clip] {
            let frame = part.frame
            part.anchorPoint = CGPoint(x: (grab.x - frame.minX) / frame.width, y: (grab.y - frame.minY) / frame.height)
            part.frame = frame
        }
        CATransaction.commit()
    }

    func appear() {
        layoutSubtreeIfNeeded()
        guard let layer else { return }
        layer.removeAllAnimations()
        for part in [shadowLayer, clip] { part.removeAllAnimations() }
        layer.opacity = 1
        guard !Motion.reduced else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = TearLook.fadeIn
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "tear.in")
        for part in [shadowLayer, clip] {
            part.add(TearLook.grow.animation("transform.scale", from: TearLook.fromScale, to: 1), forKey: "tear.grow")
        }
    }

    func disappear(_ done: @escaping @MainActor () -> Void) {
        guard let layer else { return done() }
        guard !Motion.reduced else {
            layer.opacity = 0
            return done()
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        layer.opacity = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = 0
        fade.duration = TearLook.fadeOut
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "tear.in")
        DispatchQueue.main.asyncAfter(deadline: .now() + TearLook.fadeOut) { done() }
    }
}

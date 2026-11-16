import AppKit
import Combine

@MainActor
final class ContentView: NSView {
    let browser: Browser

    private let groundHost: ShellGroundLayer
    private let stageHost: ShellStageLayer
    private let panelHost: ShellPanelLayer
    static var seenWhenCovered = false
    private let column: SideColumnView
    private var columnAway: CGFloat?
    private let bar: BookmarksBar
    private var barShown: Bool?
    private let foldHost: Fold
    private let lowerHost: ShellLowerLayer
    private let peek: PeekView
    private let field: FieldHost.Layer
    private let upperHost: ShellUpperLayer
    private let switcher: TabSwitcherView
    private let topHost: ShellTopLayer

    private var watching: [AnyCancellable] = []
    private var immersions: [AnyCancellable] = []
    private var immersionTabs: [Tab.ID] = []
    private var titled: AnyCancellable?
    private var titledTab: Tab.ID?
    private var arrived = false
    private var pending = false
    private var seen: Seen?
    private var shape: Shape?
    private var stageTween: ShellTween?
    private var pageHold: CGSize?
    private var holdTicket = 0
    private var inputs: Inputs?

    struct Shape: Equatable {
        var size: CGSize
        var chrome: CGSize
        var farGap: CGFloat
        var panelRoom: CGFloat
        var panelWidth: CGFloat
        var panelUp: Bool
        var right: Bool
        var cards: Bool
        var barShown: Bool
        var folded: Bool

        var stage: CGRect {
            let lead = right ? farGap + panelRoom : chrome.width
            let trail = right ? chrome.width : farGap + panelRoom
            return CGRect(x: lead, y: chrome.height, width: max(0, size.width - lead - trail),
                          height: max(0, size.height - chrome.height - farGap))
        }

        var peek: CGRect {
            CGRect(x: right ? 0 : chrome.width, y: chrome.height,
                   width: max(0, size.width - chrome.width), height: max(0, size.height - chrome.height))
        }
    }

    private struct Seen: Equatable {
        var fieldShowing: Bool
        var activeID: Tab.ID?
        var groundOpaque: Bool
        var right: Bool
        var columnWidth: CGFloat
    }

    private struct FieldAsk: Equatable {
        var showing: Bool
        var shown: Bool
    }

    private var fieldAsked: FieldAsk?

    private struct Inputs: Equatable {
        var hold: CGSize?
        var panel: ShellPanelLayer.Panel
        var immersed: Bool
    }

    init(browser: Browser) {
        self.browser = browser
        groundHost = ShellGroundLayer(browser: browser)
        stageHost = ShellStageLayer(browser: browser)
        panelHost = ShellPanelLayer(browser: browser)
        column = SideColumnView(browser: browser)
        column.inksItself = true
        bar = BookmarksBar(browser: browser)
        foldHost = Fold(browser: browser)
        lowerHost = ShellLowerLayer(browser: browser)
        peek = PeekView(browser: browser)
        field = FieldHost.Layer(browser: browser)
        upperHost = ShellUpperLayer(browser: browser)
        switcher = TabSwitcherView(browser: browser)
        topHost = ShellTopLayer(browser: browser)
        super.init(frame: NSRect(x: 0, y: 0, width: 1180, height: 780))
        wantsLayer = true
        for view in [groundHost, stageHost, panelHost, column, bar, foldHost, lowerHost, peek, field,
                     upperHost, switcher, topHost] as [NSView] {
            addSubview(view)
        }
        field.set(fieldShown, animated: false)
        lowerHost.paneSpot = { [weak self] in
            guard let self, let spot = stageHost.paneSpot else { return nil }
            return stageHost.convert(spot, to: lowerHost)
        }
        lowerHost.agentCard = { [weak self] in
            guard let self, let card = stageHost.agentCard else { return nil }
            return stageHost.convert(card, to: lowerHost)
        }
        stageHost.onSpot = { [weak self] in self?.lowerHost.needsLayout = true }
        watch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var fieldShown: Bool { browser.fieldShowing && !browser.newTabPageShown }

    private func watch() {
        kitObserve(initial: false, { [weak self] in self?.heard() }) { [weak self] _ in self?.changed() }
            .store(in: &watching)
        let center = NotificationCenter.default
        let mine: (Notification) -> Bool = { [weak self] note in
            guard let window = self?.window else { return false }
            return (note.object as? NSWindow) === window
        }
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in self?.ground() }
            .store(in: &watching)
        center.publisher(for: NSApplication.didResignActiveNotification)
            .sink { [weak self] _ in
                guard let browser = self?.browser else { return }
                browser.tabSwitcher.cancel()
                if browser.commandHeld { browser.commandHeld = false }
                browser.appLeft()
            }
            .store(in: &watching)
        center.publisher(for: NSWindow.didChangeOcclusionStateNotification)
            .filter(mine)
            .sink { [weak self] _ in self?.browser.sightChanged() }
            .store(in: &watching)
        center.publisher(for: NSWindow.didBecomeKeyNotification)
            .filter(mine)
            .sink { [weak self] _ in
                guard let browser = self?.browser else { return }
                Browsers.becameKey(browser)
            }
            .store(in: &watching)
        center.publisher(for: NSWindow.didResignKeyNotification)
            .filter(mine)
            .sink { [weak self] _ in
                guard let browser = self?.browser else { return }
                browser.tabSwitcher.cancel()
                if browser.commandHeld { browser.commandHeld = false }
            }
            .store(in: &watching)
        center.publisher(for: NSWindow.willEnterFullScreenNotification)
            .filter(mine)
            .sink { [weak self] _ in self?.browser.fullScreen = true }
            .store(in: &watching)
        center.publisher(for: NSWindow.willExitFullScreenNotification)
            .filter(mine)
            .sink { [weak self] _ in self?.browser.fullScreen = false }
            .store(in: &watching)
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            center.publisher(for: name)
                .filter(mine)
                .sink { [weak self] _ in
                    guard let self, let window else { return }
                    browser.fullScreen = window.styleMask.contains(.fullScreen)
                }
                .store(in: &watching)
        }
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let browser = self?.browser else { return }
                browser.appBack()
                browser.noticeClipboard()
            }
            .store(in: &watching)
    }

    private func heard() {
        _ = (browser.fieldShowing, browser.activeID, browser.groundOpaque, browser.prefs.sidePosition, browser.prefs.columnWidth,
             fieldShown, shownTabs.map(\.id))
    }

    private func changing() {
        needsLayout = true
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pending = false
            changed()
        }
    }

    private func changed() {
        let now = Seen(fieldShowing: browser.fieldShowing, activeID: browser.activeID, groundOpaque: browser.groundOpaque,
                       right: browser.prefs.sidePosition == .right, columnWidth: browser.prefs.columnWidth)
        let was = seen
        seen = now
        field.set(fieldShown, animated: true)
        watchImmersion()
        watchTitle()
        needsLayout = true
        guard let was else { return }
        if was.fieldShowing != now.fieldShowing {
            if now.fieldShowing {
                browser.fieldRose()
                DispatchQueue.main.async { [browser] in
                    if CACurrentMediaTime() - browser.focusRequestedAt > 0.25 { browser.askFocus() }
                }
            } else {
                handBack()
            }
        }
        if was.activeID != now.activeID { handBack() }
        if was.groundOpaque != now.groundOpaque { ground() }
        if was.right != now.right || was.columnWidth != now.columnWidth {
            DispatchQueue.main.async { [weak self] in Lights.refresh(self?.window) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self] in self?.setUp(window) }
        guard !arrived else { return }
        arrived = true
        changed()
        if browser.prefs.nextMeeting { _ = Meetings.shared }
        MeetingAlerts.shared.sync()
        watchKeys()
        browser.askFocus()
        Links.hand(to: browser)
        BookmarkMenu.shared.start(for: browser)
        Browsers.watchFrames()
        Delight.markExisting(pins: browser.pinnedCount, spaces: browser.spaces.count)
    }

    private func currentShape() -> Shape {
        let prefs = browser.prefs
        let cards = browser.asCards
        let sidebar = !browser.folded
        let barShown = prefs.bookmarksBar && !browser.bookmarks.isEmpty && !browser.folded
        let bar = barShown ? BookmarksBar.height : 0
        let chrome = cards
            ? CGSize(width: sidebar ? prefs.columnWidth : Metrics.cardGap, height: barShown ? bar : Metrics.cardGap)
            : CGSize(width: sidebar ? prefs.columnWidth : 0, height: bar)
        let farGap = cards ? Metrics.cardGap : 0
        let panelUp = browser.sidePanelShown && browser.sidePanel != nil && !browser.sidePanelHeld
        let across = bounds.width
        let asked = prefs.sidePanelWidth
        let panelWidth = across > 0 ? max(240, min(asked, across - chrome.width - farGap * 2 - 320)) : asked
        let panelRoom = panelUp ? panelWidth + (cards ? Metrics.cardGap : 1) : 0
        return Shape(size: bounds.size, chrome: chrome, farGap: farGap, panelRoom: panelRoom, panelWidth: panelWidth,
                     panelUp: panelUp, right: prefs.sidePosition == .right, cards: cards, barShown: barShown,
                     folded: browser.folded)
    }

    private var fullscreenTab: Tab? {
        guard browser.prefs.splitView else { return browser.active?.immersed == true ? browser.active : nil }
        if let split = browser.activeSplit,
           let immersed = browser.tabs.first(where: { split.contains($0.id) && $0.immersed }) {
            return immersed
        }
        return browser.active?.immersed == true ? browser.active : nil
    }

    private var shownTabs: [Tab] {
        if browser.prefs.splitView, let split = browser.activeSplit {
            return [split.left, split.right].compactMap { id in browser.tabs.first { $0.id == id } }
        }
        return browser.active.map { [$0] } ?? []
    }

    private func watchTitle() {
        guard let tab = browser.active else {
            titled = nil
            titledTab = nil
            return
        }
        if titledTab != tab.id {
            titledTab = tab.id
            titled = kitObserve(initial: false, distinct: true, { [weak tab] in tab.map(WindowTitle.title) ?? "" }) { [weak self, weak tab] _ in
                guard let self, let tab, let window else { return }
                WindowTitle.set(tab, in: window)
            }
        }
        if let window { WindowTitle.set(tab, in: window) }
    }

    private func watchImmersion() {
        let tabs = shownTabs
        let ids = tabs.map(\.id)
        guard ids != immersionTabs else { return }
        immersionTabs = ids
        immersions = tabs.map { tab in
            kitObserve(initial: false, distinct: true, { [weak tab] in tab?.immersed ?? false }) { [weak self] _ in self?.immersing() }
        }
    }

    private func immersing() {
        holdTicket += 1
        pageHold = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let asked = FieldAsk(showing: browser.fieldShowing, shown: fieldShown)
        if asked != fieldAsked {
            fieldAsked = asked
            if seen.map({ $0.fieldShowing != asked.showing }) ?? false { changing() } else { field.set(asked.shown, animated: true) }
        }
        let now = currentShape()
        let was = shape
        shape = now
        if let was, was.size == now.size, fullscreenTab == nil {
            holdPage(from: was.chrome, to: now.chrome)
        }
        place(now, was: was)
        feed(now)
    }

    private func place(_ now: Shape, was: Shape?) {
        let whole = bounds
        for view in [groundHost, panelHost, foldHost, lowerHost, field, upperHost, switcher, topHost] as [NSView] {
            if view.frame != whole { view.frame = whole }
        }
        if peek.frame != now.peek { peek.frame = now.peek }
        placeBar(now)
        let target = now.stage
        switcher.stage = target
        let seen = Self.seenWhenCovered || window?.occlusionState.contains(.visible) == true
        placeColumn(now, was: was, seen: seen)
        guard seen, let was, was.size == now.size, let curve = curve(from: was, to: now), stageHost.frame != target else {
            if !seen {
                stageTween?.stop()
                stageTween = nil
                if stageHost.frame != target { stageHost.frame = target }
                return
            }
            if stageTween == nil || was?.size != now.size {
                stageTween?.stop()
                stageTween = nil
                if stageHost.frame != target { stageHost.frame = target }
            } else {
                stageTween?.retarget(target)
            }
            return
        }
        let from = stageTween?.current ?? stageHost.frame
        stageTween?.stop()
        stageTween = ShellTween(view: stageHost, from: from, to: target, curve: curve) { [weak self] tween in
            if self?.stageTween === tween { self?.stageTween = nil }
        }
    }

    private func placeColumn(_ now: Shape, was: Shape?, seen: Bool) {
        let width = browser.prefs.columnWidth
        let frame = NSRect(x: now.right ? now.size.width - width : 0, y: 0, width: width, height: now.size.height)
        let away: CGFloat = now.folded ? (now.right ? width : -width) : 0
        let from = column.frame.minX
        let crossed = was.map { $0.right != now.right } ?? false
        if column.frame != frame { column.frame = frame }
        guard columnAway != away || crossed, let layer = column.layer else { return }
        let first = columnAway == nil
        columnAway = away
        let docking = browser.columnPeek.docking
        browser.columnPeek.docking = false
        let folding = !first && was.map { $0.folded != now.folded } ?? false
        let curve: KitCurve
        if first || !seen || (docking && !now.folded) {
            curve = .none
        } else if folding {
            curve = Motion.kitFold(out: !now.folded)
        } else if crossed {
            curve = Motion.kitGlide
        } else {
            curve = .none
        }
        if !now.folded { column.isHidden = false }
        let path = "transform.translation.x"
        let shown = (layer.presentation()?.value(forKeyPath: path) as? CGFloat) ?? (layer.value(forKeyPath: path) as? CGFloat) ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(curve == .none ? away : shown + from - frame.minX, forKeyPath: path)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, browser.folded, columnAway == away else { return }
            column.isHidden = true
        }
        layer.kitAnimate(path, to: away, curve: curve)
        if folding, let window, !window.styleMask.contains(.fullScreen),
           let bar = window.standardWindowButton(.closeButton)?.superview {
            Fold.ride(bar, with: layer.animation(forKey: path), off: now.folded && !browser.peeking)
        }
        CATransaction.commit()
    }

    private func placeBar(_ now: Shape) {
        let lead = now.right ? now.farGap : now.chrome.width
        let trail = now.right ? now.chrome.width : now.farGap
        let frame = NSRect(x: lead, y: 0, width: max(0, now.size.width - lead - trail), height: BookmarksBar.height)
        if now.barShown || bar.frame.width == 0 { bar.frame = frame }
        bar.onFrame = now.cards
        bar.refresh()
        guard barShown != now.barShown else { return }
        let first = barShown == nil
        barShown = now.barShown
        bar.wantsLayer = true
        guard let layer = bar.layer else { return }
        if now.barShown { bar.isHidden = false }
        let curve: KitCurve = first ? .none : Motion.kitGlide
        let shown = now.barShown
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, barShown == false, !shown else { return }
            bar.isHidden = true
        }
        layer.kitAnimate("opacity", to: shown ? 1 : 0, curve: curve)
        CATransaction.commit()
    }

    private func curve(from was: Shape, to now: Shape) -> ShellTween.Curve? {
        guard !Motion.reduced else { return nil }
        if was.folded != now.folded {
            let spring = Motion.fold(out: !now.folded)
            return .spring(response: spring.response, damping: spring.damping)
        }
        if was.right != now.right || was.barShown != now.barShown {
            return .spring(response: KitSpring.glide.response, damping: KitSpring.glide.damping)
        }
        return nil
    }

    private func feed(_ now: Shape) {
        let wanted = Inputs(
            hold: pageHold,
            panel: ShellPanelLayer.Panel(up: now.panelUp, top: now.chrome.height, gap: now.farGap, width: now.panelWidth),
            immersed: fullscreenTab != nil
        )
        guard wanted != inputs else { return }
        inputs = wanted
        stageHost.hold = wanted.hold
        panelHost.panel = wanted.panel
        lowerHost.immersed = wanted.immersed
    }

    private func holdPage(from old: CGSize, to new: CGSize) {
        let floor = Metrics.cardGap
        let turned = (old.width <= floor) != (new.width <= floor) || (old.height <= floor) != (new.height <= floor)
        guard turned, !Motion.reduced else { return }
        holdTicket += 1
        let ticket = holdTicket
        pageHold = CGSize(width: old.width - new.width, height: old.height - new.height)
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.foldSettles) { [weak self] in
            guard let self, ticket == holdTicket else { return }
            pageHold = nil
            needsLayout = true
        }
    }

    private func handBack() {
        guard !browser.fieldShowing, browser.editingTab == nil else { return }
        field.layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [browser] in
            guard !browser.fieldShowing, browser.editingTab == nil else { return }
            guard browser.active?.page == nil, let web = browser.active?.web, let window = web.window else { return }
            if let responder = window.firstResponder as? NSView,
               responder === web || responder.isDescendant(of: web) { return }
            window.makeFirstResponder(web)
        }
    }

    private func setUp(_ window: NSWindow) {
        dress(window)
        if let tab = browser.active { WindowTitle.set(tab, in: window) }
    }

    private func ground() {
        guard let window else { return }
        let opaque = browser.groundOpaque
        window.isOpaque = opaque
        window.backgroundColor = opaque ? Palette.NS.ground : .clear
    }

    private func dress(_ window: NSWindow) {
        browser.window = window
        window.tabbingMode = .disallowed
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        browser.fullScreen = window.styleMask.contains(.fullScreen)
        ground()
        window.isMovableByWindowBackground = false
        window.isMovable = true
        Lights.keep(window, centreX: { [browser] window in
            browser.prefs.sidePosition == .right
                ? window.frame.width - browser.prefs.columnWidth + Lights.centre.x
                : Lights.centre.x
        })
        DispatchQueue.main.async {
            guard let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview,
                  let content = window.contentView,
                  let frame = content.superview
            else { return }
            if container.superview === frame {
                frame.addSubview(container, positioned: .above, relativeTo: content)
            }
            container.wantsLayer = true
            container.layer?.zPosition = 10
        }
    }
}

@MainActor
final class ShellTween {
    enum Curve {
        case spring(response: Double, damping: Double)
    }

    private weak var view: NSView?
    private var from: CGRect
    private var to: CGRect
    private let curve: Curve
    private var start = CACurrentMediaTime()
    private var link: CADisplayLink?
    private var turn = 0
    private let done: (ShellTween) -> Void
    private(set) var current: CGRect

    init(view: NSView, from: CGRect, to: CGRect, curve: Curve, done: @escaping (ShellTween) -> Void) {
        self.view = view
        self.from = from
        self.to = to
        self.curve = curve
        self.done = done
        current = from
        view.frame = from
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        backstop()
    }

    private func backstop() {
        turn += 1
        let ticket = turn
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, ticket == turn, link != nil else { return }
            land()
        }
    }

    private func land() {
        current = to
        view?.frame = to
        stop()
        done(self)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    func retarget(_ target: CGRect) {
        guard target != to else { return }
        from = current
        to = target
        start = CACurrentMediaTime()
        backstop()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t = max(0, link.targetTimestamp - start)
        let (value, settled) = progress(t)
        current = CGRect(x: from.minX + (to.minX - from.minX) * value, y: from.minY + (to.minY - from.minY) * value,
                         width: from.width + (to.width - from.width) * value,
                         height: from.height + (to.height - from.height) * value)
        guard !settled, view != nil else { return land() }
        view?.frame = current
    }

    private func progress(_ t: Double) -> (CGFloat, Bool) {
        switch curve {
        case .spring(let response, let damping):
            let omega = 2 * Double.pi / response
            let value: Double
            if damping >= 1 {
                value = 1 - (1 + omega * t) * exp(-omega * t)
            } else {
                let decay = damping * omega
                let wd = omega * (1 - damping * damping).squareRoot()
                value = 1 - exp(-decay * t) * (cos(wd * t) + decay / wd * sin(wd * t))
            }
            let settled = t > 0.05 && abs(1 - value) < 0.001 && t > response
            return (CGFloat(value), settled || t > 2)
        }
    }
}

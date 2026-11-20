import AppKit
import Combine

@MainActor
final class FullScreenSide {
    static let shared = FullScreenSide()
    static let edge: CGFloat = 6
    static let dwell: TimeInterval = 0.15
    static let grace: TimeInterval = 0.065

    private weak var browser: Browser?
    private weak var tab: Tab?
    private var local: Any?
    private var arriving: DispatchWorkItem?
    private var leaving: DispatchWorkItem?
    private(set) var panel: FullScreenSidePanel?
    private var sentAway = false
    private var watch: AnyCancellable?
    private var fullScreenWatch: NSKeyValueObservation?
    private var turn = 0
    private weak var moving: NSWindow?
    private var movedBefore = false
    private(set) var out = false
    var standIn: NSWindow?

    func follow(_ browser: Browser, tab: Tab?) {
        guard let tab, tab.immersed else {
            if self.browser === browser || self.browser == nil { stop() }
            return
        }
        guard self.browser !== browser || self.tab !== tab else { return }
        stop()
        self.browser = browser
        self.tab = tab
        let id = tab.id
        watch = kitObserve(initial: false, distinct: true, { [weak browser] in browser?.activeID }) { [weak self] active in
            guard let self, out, active != id else { return }
            leaveFullScreen()
        }
        guard local == nil else { return }
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.moved() }
            return event
        }
        fullScreenWatch = tab.built?.observe(\.fullscreenState, options: [.initial, .new]) { [weak self] page, _ in
            MainActor.assumeIsolated {
                guard let self, page.fullscreenState == .inFullscreen, let window = page.window, window !== self.browser?.window else { return }
                self.hear(window)
            }
        }
    }

    private func hear(_ window: NSWindow) {
        guard moving !== window else { return }
        unhear()
        moving = window
        movedBefore = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
    }

    private func unhear() {
        moving?.acceptsMouseMovedEvents = movedBefore
        moving = nil
    }

    func stop() {
        if let local { NSEvent.removeMonitor(local) }
        local = nil
        unhear()
        watch = nil
        fullScreenWatch = nil
        arriving?.cancel()
        arriving = nil
        leaving?.cancel()
        leaving = nil
        sentAway = false
        hide(animated: false)
        browser = nil
        tab = nil
    }

    func shown(for browser: Browser) -> Bool { out && self.browser === browser }

    var host: NSWindow? {
        if let standIn { return standIn }
        guard let browser, let page = tab?.built, let window = page.window, window !== browser.window,
              page.fullscreenState == .inFullscreen else { return nil }
        return window
    }

    static func atEdge(_ point: NSPoint, in frame: NSRect, right: Bool) -> Bool {
        guard frame.contains(point) else { return false }
        let distance = right ? frame.maxX - point.x : point.x - frame.minX
        return distance < edge && frame.maxY - point.y >= Fold.fullScreenCorner
    }

    static func within(_ point: NSPoint, in frame: NSRect, right: Bool, reach: CGFloat) -> Bool {
        guard point.y >= frame.minY, point.y < frame.maxY else { return false }
        let distance = right ? frame.maxX - point.x : point.x - frame.minX
        return distance < reach
    }

    private var holding: Bool {
        guard let browser else { return false }
        return browser.editingTab != nil || browser.bookmarksOpen || browser.downloadsOpen || Extensions.shared.menuOpen
    }

    func moved(at point: NSPoint = NSEvent.mouseLocation) {
        guard let browser, let host else {
            if out { hide() }
            return
        }
        if host !== standIn { hear(host) }
        let right = browser.prefs.sidePosition == .right
        if out {
            let reach = browser.prefs.columnWidth + 2 * Metrics.floatGap
            if holding || Self.within(point, in: host.frame, right: right, reach: reach) {
                leaving?.cancel()
                leaving = nil
            } else if leaving == nil {
                let going = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    leaving = nil
                    guard !holding else { return }
                    hide()
                }
                leaving = going
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: going)
            }
        } else if Self.atEdge(point, in: host.frame, right: right) {
            guard !sentAway, arriving == nil else { return }
            let coming = DispatchWorkItem { [weak self] in
                self?.arriving = nil
                self?.show()
            }
            arriving = coming
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: coming)
        } else {
            sentAway = false
            arriving?.cancel()
            arriving = nil
        }
    }

    private var gone: CGFloat {
        guard let browser else { return 0 }
        let width = browser.prefs.columnWidth + 2 * Metrics.floatGap + 48
        return browser.prefs.sidePosition == .right ? width : -width
    }

    func show() {
        guard let browser, let host, !out else { return }
        turn += 1
        let made = panel ?? FullScreenSidePanel(browser: browser)
        panel = made
        made.place(over: host, width: browser.prefs.columnWidth, right: browser.prefs.sidePosition == .right)
        if made.parent !== host {
            made.parent?.removeChildWindow(made)
            host.addChildWindow(made, ordered: .above)
        }
        made.orderFront(nil)
        made.peek.out = true
        made.card.place(out: false, gone: gone, animated: false)
        made.card.place(out: true, gone: gone, animated: true)
        out = true
    }

    func hide(animated: Bool = true) {
        guard out, let panel else { return }
        out = false
        panel.peek.out = false
        panel.card.place(out: false, gone: gone, animated: animated)
        turn += 1
        let mine = turn
        let done = { [weak self, weak panel] in
            guard let self, let panel, turn == mine else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.card.removeFromSuperview()
            if self.panel === panel { self.panel = nil }
        }
        guard animated, !Motion.reduced else { return done() }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.foldSettles) { done() }
    }

    func sendAway() {
        sentAway = true
        leaving?.cancel()
        leaving = nil
        hide()
    }

    private func leaveFullScreen() {
        hide(animated: false)
        tab?.built?.closeAllMediaPresentations(completionHandler: nil)
    }
}

final class FullScreenSidePanel: KitLitPanel {
    let peek = ColumnPeek()
    let card: PeekCardView

    init(browser: Browser) {
        card = PeekCardView(host: FoldColumnCardView(browser: browser, peek: peek))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .transient]
        let content = KitFlippedView()
        content.addSubview(card)
        contentView = content
    }

    override var canBecomeMain: Bool { false }

    func place(over window: NSWindow, width: CGFloat, right: Bool) {
        let gap = Metrics.floatGap
        let over = window.frame
        let whole = width + 2 * gap
        setFrame(NSRect(x: right ? over.maxX - whole : over.minX, y: over.minY, width: whole, height: over.height), display: false)
        card.frame = NSRect(x: gap, y: gap, width: width, height: max(0, over.height - 2 * gap))
    }
}

extension Browser {
    func sendSideAway() -> Bool {
        guard folded, peeking else { return false }
        columnPeek.sentAway = true
        peek(false)
        return true
    }

    func escapesSide(_ event: NSEvent) -> Bool {
        guard editingTab == nil, !editing, !bookmarksOpen, !downloadsOpen else { return false }
        if FullScreenSide.shared.shown(for: self) {
            if !event.isARepeat { FullScreenSide.shared.sendAway() }
            FullScreenEscape.shared.keepUp()
            return true
        }
        guard fullScreen || window?.styleMask.contains(.fullScreen) == true, folded, peeking else { return false }
        if !event.isARepeat { _ = sendSideAway() }
        FullScreenEscape.shared.keepUp()
        return true
    }
}

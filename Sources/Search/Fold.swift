import AppKit
import Combine
import Observation

extension Browser {
    func toggleFold() {
        columnPeek.docking = folded && peeking
        peeking = false
        folded.toggle()
    }

    func closeColumnFromEdge(restoring width: CGFloat) {
        guard !folded else {
            prefs.sideWidth = width
            return
        }
        toggleFold()
        let prefs = prefs
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduced ? 0 : 0.5)) { prefs.sideWidth = width }
    }

    func peek(_ out: Bool) {
        columnPeek.moving = !Motion.reduced
        peeking = out
        columnPeek.moving = false
    }

    func covers(_ page: NSView, at point: NSPoint) -> Bool {
        guard let window, page.window === window else { return false }
        if let peek = peekTab, peek.built !== page { return true }
        guard folded, peeking, let size = window.contentView?.bounds.size else { return false }
        let reach = prefs.columnWidth + Metrics.floatGap
        return prefs.sidePosition == .right ? point.x >= size.width - reach : point.x <= reach
    }
}

@MainActor
@Observable
final class ColumnPeek {
    var out = false {
        didSet { movedOut = moving }
    }
    @ObservationIgnored var moving = false
    @ObservationIgnored var docking = false
    @ObservationIgnored private(set) var movedOut = false
}

@MainActor
protocol FoldCard: NSView {
    var isOut: Bool { get }
    func reach(_ gone: CGFloat)
    @discardableResult
    func place(out: Bool, gone: CGFloat, animated: Bool) -> CAAnimation?
}

@MainActor
final class Fold: NSView {
    let browser: Browser

    private let strip = DragStripView()
    private var card: FoldCard?
    private var leaving: DispatchWorkItem?
    private var arriving: DispatchWorkItem?
    private var inside = false
    private let pointer = Pointer()
    private var watched: [AnyCancellable] = []
    private var seen: Seen?
    private var notes: [NSObjectProtocol] = []

    private static let edge: CGFloat = 6
    private static let overshoot: CGFloat = 48
    private static let grace: TimeInterval = 0.065
    static let fullScreenCorner: CGFloat = 60
    private static let top: CGFloat = 8
    private static let dwell: TimeInterval = 0.15
    static var pointerIgnored = false

    private struct Seen: Equatable {
        var folded: Bool
        var out: Bool
        var right: Bool
        var columnWidth: CGFloat
        var sideHides: Bool
        var editing: Tab.ID?
        var bookmarksOpen: Bool
    }

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        addSubview(strip)
        let peek = browser.columnPeek
        watched = [
            kitObserve(initial: false, distinct: true, { [weak self] in self?.current }) { [weak self] _ in self?.changed() },
            kitObserve(initial: false, { [weak peek] in peek?.out ?? false }) { [weak self] _ in self?.changed() },
        ]
        let center = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            notes.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSWindow) === self.browser.window else { return }
                    self.hideLights()
                }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            resetPending()
            pointer.stop()
            return
        }
        window.standardWindowButton(.closeButton)?.superview?.isHidden = lightsOff && !window.styleMask.contains(.fullScreen)
        pointer.window = window
        hideLights()
        changed()
        watch()
    }

    override func layout() {
        super.layout()
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.top)
        if let card {
            let width = browser.prefs.columnWidth
            let gap = Metrics.floatGap
            card.frame = NSRect(x: onRight ? bounds.width - gap - width : gap, y: gap,
                                width: width, height: max(0, bounds.height - 2 * gap))
            card.reach(gone)
        }
    }

    private var current: Seen {
        let prefs = browser.prefs
        return Seen(folded: browser.folded, out: browser.columnPeek.out, right: prefs.sidePosition == .right,
                    columnWidth: prefs.columnWidth, sideHides: prefs.sideHides,
                    editing: browser.editingTab, bookmarksOpen: browser.bookmarksOpen)
    }

    private func changed() {
        let now = current
        let was = seen
        seen = now
        guard let was else {
            showCard(now.folded)
            return
        }
        if was == now { return }
        if was.folded, now.folded, was.out != now.out { ride(now.out) }
        if was.folded != now.folded {
            showCard(now.folded)
            resetPending()
            watch()
        }
        if was.right != now.right {
            resetPending()
            browser.peeking = false
            if let window = browser.window, let bar = window.standardWindowButton(.closeButton)?.superview {
                Self.reset(bar, hidden: lightsOff && !window.styleMask.contains(.fullScreen))
            }
            needsLayout = true
        }
        if was.columnWidth != now.columnWidth {
            if browser.folded { hideLights() }
            needsLayout = true
        }
        if was.sideHides != now.sideHides {
            resetPending()
            let hides = now.sideHides
            browser.columnPeek.docking = browser.folded && browser.peeking && !hides
            browser.peeking = false
            browser.folded = hides
        }
        if was.editing != nil, now.editing == nil, !inside, browser.peeking { peek(false) }
        if was.bookmarksOpen, !now.bookmarksOpen, !inside, browser.peeking { peek(false) }
    }

    private func showCard(_ folded: Bool) {
        if folded {
            guard card == nil else { return }
            subviews.filter { $0 is FoldCard }.forEach { $0.removeFromSuperview() }
            let made: FoldCard = PeekCardView(host: FoldColumnCardView(browser: browser))
            made.place(out: browser.columnPeek.out, gone: gone, animated: false)
            card = made
            addSubview(made)
            needsLayout = true
            return
        }
        card?.removeFromSuperview()
        card = nil
    }

    private var holding: Bool {
        if browser.bookmarksOpen || browser.downloadsOpen { return true }
        if Extensions.shared.menuOpen { return true }
        return false
    }

    private var gone: CGFloat {
        let width = browser.prefs.columnWidth + 2 * Metrics.floatGap + 48
        return onRight ? width : -width
    }

    private var lightsOff: Bool {
        browser.folded && !browser.columnPeek.out
    }

    private var onRight: Bool {
        browser.prefs.sidePosition == .right
    }

    private func resetPending() {
        arriving?.cancel()
        arriving = nil
        leaving?.cancel()
        leaving = nil
        inside = false
    }

    private func watch() {
        if browser.folded {
            pointer.start { [weak self] in self?.follow() }
        } else {
            pointer.stop()
        }
    }

    private func follow() {
        guard !Self.pointerIgnored else { return }
        guard browser.folded, let window = pointer.window, window.isVisible else { return pass() }
        let screen = NSEvent.mouseLocation
        let point = window.convertPoint(fromScreen: screen)
        let size = window.frame.size
        let inWindow = point.x >= 0 && point.x < size.width && point.y >= 0 && point.y < size.height
        let distance = onRight ? size.width - point.x : point.x
        let past = onRight ? point.x - size.width : -point.x
        let beside = past > 0 && past < Self.overshoot
            && point.y >= 0 && point.y < size.height
        let overshot = beside && pointer.crossing
            && NSScreen.screens.contains { $0.visibleFrame.contains(screen) }
        pointer.crossing = inWindow || overshot
        if browser.peeking {
            pass()
            let top = NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0)
            let onWindow = top == window.windowNumber
            let onOwnPanel = !onWindow && NSApp.windows.contains { $0.windowNumber == top }
            let reach = browser.prefs.columnWidth + 2 * Metrics.floatGap
            let popup = ExtensionPopup.shared.isUp
            let over = onOwnPanel || popup || holding || overshot || (onWindow && inWindow && distance < reach)
            if over != inside { inside = over }
            peek(over)
        } else if inWindow, distance < Self.edge,
                  !(window.styleMask.contains(.fullScreen) && size.height - point.y < Self.fullScreenCorner) {
            guard NSWindow.windowNumber(at: screen, belowWindowWithWindowNumber: 0) == window.windowNumber
            else { return pass() }
            if arriving == nil { arrive() }
        } else if overshot {
            arrive(resting: true)
        } else {
            pass()
        }
    }

    private func arrive(resting: Bool = false) {
        guard resting || browser.prefs.sideHides else { return peek(true) }
        pass()
        let coming = DispatchWorkItem { [weak self] in
            self?.arriving = nil
            self?.peek(true)
        }
        arriving = coming
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dwell, execute: coming)
    }

    private func pass() {
        guard let arriving else { return }
        arriving.cancel()
        self.arriving = nil
    }

    private func peek(_ out: Bool) {
        if out {
            if let leaving {
                leaving.cancel()
                self.leaving = nil
            }
            guard !browser.peeking else { return }
            browser.peek(true)
        } else {
            guard leaving == nil else { return }
            let going = DispatchWorkItem { [weak self] in
                guard let self else { return }
                leaving = nil
                guard browser.editingTab == nil, !holding else { return }
                browser.peek(false)
            }
            leaving = going
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.grace, execute: going)
        }
    }

    private func ride(_ out: Bool) {
        CATransaction.begin()
        defer { CATransaction.commit() }
        let spring = card?.place(out: out, gone: gone, animated: browser.columnPeek.movedOut)
        guard let window = browser.window, let bar = window.standardWindowButton(.closeButton)?.superview else { return }
        guard !window.styleMask.contains(.fullScreen) else { return hideLights() }
        Self.ride(bar, with: spring, off: !out)
    }

    private func hideLights() {
        guard let bar = browser.window?.standardWindowButton(.closeButton)?.superview else { return }
        if browser.window?.styleMask.contains(.fullScreen) == true {
            bar.layer?.removeAnimation(forKey: "fold")
            bar.isHidden = false
            return
        }
        Self.slide(bar, off: lightsOff, by: browser.prefs.columnWidth, right: onRight)
    }

    static var titlebar: NSView? {
        Links.window?.standardWindowButton(.closeButton)?.superview
    }

    private static var slides = 0

    static func reset(_ bar: NSView, hidden: Bool) {
        slides += 1
        bar.layer?.removeAnimation(forKey: "fold")
        bar.isHidden = hidden
    }

    static func ride(_ bar: NSView, with motion: CAAnimation?, off: Bool) {
        guard let motion, !Motion.reduced, let layer = bar.layer, let spring = motion.copy() as? CAAnimation
        else { return reset(bar, hidden: off) }
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        slides += 1
        let turn = slides
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard turn == slides else { return }
                layer.removeAnimation(forKey: "fold")
                bar.isHidden = off
            }
        }
        layer.add(spring, forKey: "fold")
        CATransaction.commit()
    }

    static func slide(_ bar: NSView, off: Bool, by width: CGFloat, right: Bool = false) {
        slides += 1
        let turn = slides
        guard let layer = bar.layer else {
            bar.isHidden = off
            return
        }
        if Motion.reduced {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        let path = "transform.translation.x"
        let gone: CGFloat = right ? width : -width
        let still = layer.animation(forKey: "fold") != nil
        let from = still
            ? (layer.presentation()?.value(forKeyPath: path) as? CGFloat ?? 0)
            : (bar.isHidden ? gone : 0)
        let to: CGFloat = off ? gone : 0
        guard from != to else {
            layer.removeAnimation(forKey: "fold")
            bar.isHidden = off
            return
        }
        let fold = Motion.fold(out: !off)
        let spring = CASpringAnimation(keyPath: path)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / fold.response, 2)
        spring.damping = 4 * .pi * fold.damping / fold.response
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        bar.isHidden = false
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                guard turn == slides else { return }
                layer.removeAnimation(forKey: "fold")
                bar.isHidden = off
            }
        }
        layer.add(spring, forKey: "fold")
        CATransaction.commit()
    }
}

@MainActor
private final class Pointer {
    weak var window: NSWindow?
    var crossing = false
    private var local: Any?
    private var global: Any?
    private var accepted = false

    func start(_ moved: @escaping @MainActor () -> Void) {
        guard local == nil, let window else { return }
        crossing = false
        accepted = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            MainActor.assumeIsolated { moved() }
            return event
        }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { moved() }
        }
    }

    func stop() {
        guard local != nil || global != nil else { return }
        if let local { NSEvent.removeMonitor(local) }
        if let global { NSEvent.removeMonitor(global) }
        local = nil
        global = nil
        window?.acceptsMouseMovedEvents = accepted
    }
}

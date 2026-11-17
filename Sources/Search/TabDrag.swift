import AppKit
import Observation
import Combine

enum SplitDropKind: Equatable { case stage, strip }

final class SplitDropMarker: NSView {
    weak var browser: Browser?
    weak var tab: Tab?
    var kind: SplitDropKind = .strip

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Only the Stage observes `preview`; the browser's tab row stays still while
/// the pointer moves across a page. A marker is weakly kept and checked in
/// the source window before it can become a target.
@MainActor
@Observable
final class TabDrag {
    static let shared = TabDrag()

    enum Side: Equatable { case left, right, centre }

    struct Preview: Equatable {
        let browserID: ObjectIdentifier
        let targetID: Tab.ID
        let side: Side
        /// The tab being carried, to name it in the half it would take.
        var sourceID: Tab.ID? = nil
    }

    enum Drop {
        case stage(Tab, onLeft: Bool)
        case replace(Tab)
        case strip(Tab?)
        case outside
        case cancelled
    }

    private(set) var preview: Preview?
    private(set) var cancelledID: Tab.ID?
    private(set) var carried: Carried?

    struct Carried: Equatable {
        let id: Tab.ID
        let point: CGPoint
    }

    private final class WeakMarker {
        weak var view: SplitDropMarker?
        init(_ view: SplitDropMarker) { self.view = view }
    }

    @ObservationIgnored private var markers: [ObjectIdentifier: WeakMarker] = [:]
    @ObservationIgnored private weak var sourceBrowser: Browser?
    @ObservationIgnored private weak var gestureTab: Tab?
    @ObservationIgnored private weak var sourceTab: Tab?
    @ObservationIgnored private var lent: Tab.ID?
    @ObservationIgnored private var target: Drop = .outside
    @ObservationIgnored private var escapeMonitor: Any?

    /// Only a page's edges split it, a band of either side about a quarter
    /// of its width, and no narrower than this: carried across the middle
    /// of a page on its way elsewhere, a tab splits nothing.
    static let band: CGFloat = 120
    static let bandShare: CGFloat = 0.33
    /// How far out of the band the pointer goes before a shown split lets go.
    static let slack: CGFloat = 20
    /// The pointer at rest in a band — moved less than this in `still` — is
    /// what shows the split. No fixed wait, and no flicker from a tab
    /// carried straight across.
    static let settle: CGFloat = 6
    static let still: TimeInterval = 0.09

    /// Where the pointer has been lately, for whether it has settled.
    @ObservationIgnored private var trail: [(point: NSPoint, at: TimeInterval)] = []
    /// A look again once the pointer may have come to rest.
    @ObservationIgnored private var recheck: DispatchWorkItem?
    @ObservationIgnored private var last: NSPoint?

    private init() {}

    func register(_ view: SplitDropMarker) {
        markers[ObjectIdentifier(view)] = WeakMarker(view)
    }

    func unregister(_ view: SplitDropMarker) {
        markers[ObjectIdentifier(view)] = nil
    }

    func update(browser: Browser, tab: Tab, translation: CGSize, event: NSEvent? = nil) -> Bool {
        guard browser.prefs.splitView else { return false }
        if sourceBrowser !== browser || gestureTab !== tab {
            let pointer = pointer(in: browser, event: event)
            let origin = NSPoint(x: pointer.x - translation.width, y: pointer.y + translation.height)
            begin(browser: browser, tab: tab, at: origin)
        }
        guard cancelledID != tab.id else { return true }
        guard sourceTab != nil else { return false }
        let point = pointer(in: browser, event: event)
        last = point
        let now = ProcessInfo.processInfo.systemUptime
        trail.append((point, now))
        trail.removeAll { now - $0.at > 0.5 }
        givePageBack(browser: browser, at: point)
        return look(browser: browser, at: point)
    }

    /// The split under the pointer, shown once the pointer has settled in an
    /// edge band, or kept while it is still near the one shown.
    @discardableResult
    private func look(browser: Browser, at point: NSPoint) -> Bool {
        guard let sourceTab else { return false }
        let matched = match(browser: browser, source: sourceTab, at: point)
        target = matched
        guard let wanted = shown(matched, browser: browser, source: sourceTab) else {
            recheck?.cancel()
            if preview != nil { preview = nil }
            if carried != nil { carried = nil }
            return false
        }
        if let window = browser.window {
            let inside = window.convertPoint(fromScreen: point)
            carried = Carried(id: sourceTab.id, point: CGPoint(x: inside.x, y: window.frame.height - inside.y))
        }
        if preview == wanted { return true }
        guard settled(at: point) else {
            // Look again once it may have stopped: a hand at rest sends
            // nothing more to look at.
            recheck?.cancel()
            let work = DispatchWorkItem { [weak self, weak browser] in
                guard let self, let browser, self.sourceBrowser === browser else { return }
                self.look(browser: browser, at: self.last ?? self.pointer(in: browser))
            }
            recheck = work
            DispatchQueue.main.asyncAfter(deadline: .now() + TabDrag.still, execute: work)
            return true
        }
        preview = wanted
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        return true
    }

    private func givePageBack(browser: Browser, at point: NSPoint) {
        guard TabPress.brought, lent == nil, let sourceTab, sourceTab.id == browser.activeID, let window = browser.window,
              let page = browser.tabs.first(where: { $0.id == browser.pageBefore }), browser.canSplit(sourceTab, with: page),
              markers.values.compactMap(\.view).contains(where: { view in
                  view.kind == .stage && view.window === window
                      && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
              }) else { return }
        TabPress.brought = false
        lent = sourceTab.id
        browser.select(page)
    }

    private func takePageBack(browser: Browser, after drop: Drop) {
        defer { lent = nil }
        switch drop {
        case .stage, .replace: return
        default:
            if let tab = browser.tabs.first(where: { $0.id == lent }) { browser.select(tab) }
        }
    }

    func aim(browser: Browser, source: Tab, target: Tab?, side: Side) {
        preview = target.map {
            Preview(browserID: ObjectIdentifier(browser), targetID: $0.id, side: side, sourceID: source.id)
        }
    }

    private func shown(_ drop: Drop, browser: Browser, source: Tab) -> Preview? {
        switch drop {
        case .stage(let page, let onLeft):
            return Preview(browserID: ObjectIdentifier(browser), targetID: page.id, side: onLeft ? .left : .right, sourceID: source.id)
        case .replace(let page):
            return Preview(browserID: ObjectIdentifier(browser), targetID: page.id, side: .centre, sourceID: source.id)
        default:
            return nil
        }
    }

    private func settled(at point: NSPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = trail.filter { now - $0.at <= TabDrag.still }
        // Nothing new for a while: at rest.
        guard let first = recent.first else { return true }
        return recent.allSatisfy { hypot($0.point.x - point.x, $0.point.y - point.y) < TabDrag.settle }
            && hypot(first.point.x - point.x, first.point.y - point.y) < TabDrag.settle
    }

    func finish(browser: Browser, tab: Tab, event: NSEvent? = nil) -> (source: Tab, drop: Drop, point: NSPoint) {
        let source = sourceTab ?? tab
        let point = pointer(in: browser, event: event)
        var result: Drop
        if cancelledID == tab.id {
            result = .cancelled
        } else if sourceBrowser === browser && gestureTab === tab {
            result = match(browser: browser, source: source, at: point)
            // A split only where one was shown.
            if let wanted = shown(result, browser: browser, source: source), preview != wanted {
                result = .outside
            }
        } else {
            result = .outside
        }
        clear()
        takePageBack(browser: browser, after: result)
        return (source, result, point)
    }

    /// The drag callback is delivered with a window-local NSEvent. Use that
    /// event as the source of truth: synthesized drags need not move macOS's
    /// global mouse location at the same time.
    private func pointer(in browser: Browser, event given: NSEvent? = nil) -> NSPoint {
        if let window = browser.window, let event = given ?? NSApp.currentEvent,
           event.window === window,
           event.type == .leftMouseDragged || event.type == .leftMouseUp {
            return window.convertToScreen(NSRect(origin: event.locationInWindow, size: .zero)).origin
        }
        return NSEvent.mouseLocation
    }

    private func begin(browser: Browser, tab: Tab, at origin: NSPoint) {
        clear()
        cancelledID = nil
        sourceBrowser = browser
        gestureTab = tab
        sourceTab = sourceHalf(browser: browser, gesture: tab, at: origin)
        // Escape is the drag's only while the button is down. A gesture
        // taken away mid-drag never says it ended, and its monitor stayed
        // to eat the next Escape anywhere, one meant for a video's full
        // screen too, which then took two.
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, NSEvent.pressedMouseButtons & 1 != 0,
                  let self, self.gestureTab != nil else { return event }
            self.cancel()
            return nil
        }
    }

    func benchCancel() {
        guard Store.testing else { return }
        cancel()
    }

    private func cancel() {
        // The monitor goes first: a drag whose tab has gone has nothing to
        // cancel, and kept, its monitor would go on asking.
        removeMonitor()
        guard let gestureTab else { return }
        TearOff.shared.cancelled()
        cancelledID = gestureTab.id
        preview = nil
        carried = nil
        target = .cancelled
        removeMonitor()
    }

    private func clear() {
        recheck?.cancel()
        recheck = nil
        trail = []
        last = nil
        preview = nil
        carried = nil
        sourceBrowser = nil
        gestureTab = nil
        sourceTab = nil
        target = .outside
        removeMonitor()
    }

    private func removeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func match(browser: Browser, source: Tab, at point: NSPoint) -> Drop {
        guard let window = browser.window else { return .outside }
        markers = markers.filter { $0.value.view != nil }
        let candidates = markers.values.compactMap(\.view).filter { view in
            view.browser === browser && view.window === window && !view.isHiddenOrHasHiddenAncestor
                && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }
        if let stage = candidates.first(where: { view in
            view.kind == .stage && view.tab.map { browser.canSplit(source, with: $0) } == true
        }), let page = stage.tab {
            let pair = browser.split(for: source)
            if browser.split(for: page) != nil, pair?.contains(page.id) != true { return .replace(page) }
            let frame = window.convertToScreen(stage.convert(stage.bounds, to: nil))
            let band = max(TabDrag.band, frame.width * TabDrag.bandShare)
            // The side shown keeps a little more room before it lets go.
            let shown = preview?.targetID == page.id ? preview?.side : nil
            let left = band + (shown == .left ? TabDrag.slack : 0)
            let right = band + (shown == .right ? TabDrag.slack : 0)
            if point.x <= frame.minX + left { return .stage(page, onLeft: true) }
            if point.x >= frame.maxX - right { return .stage(page, onLeft: false) }
            if pair == nil { return .replace(page) }
        }
        guard browser.split(for: source) != nil else { return .outside }
        let pair = browser.split(for: source)
        if let stripTab = candidates.first(where: { view in
            view.kind == .strip && view.tab.map { pair?.contains($0.id) == false } == true
        }), let page = stripTab.tab {
            return .strip(page)
        }
        if candidates.contains(where: { view in
            view.kind == .strip && view.tab.map { pair?.contains($0.id) == true } == true
        }) { return .outside }
        if candidates.contains(where: { $0.kind == .strip && $0.tab == nil }) { return .strip(nil) }
        return .outside
    }

    private func sourceHalf(browser: Browser, gesture: Tab, at point: NSPoint) -> Tab {
        guard let pair = browser.split(for: gesture), let window = browser.window else { return gesture }
        markers = markers.filter { $0.value.view != nil }
        return markers.values.compactMap(\.view).first { view in
            view.kind == .strip && view.browser === browser && view.window === window
                && view.tab.map({ pair.contains($0.id) }) == true
                && window.convertToScreen(view.convert(view.bounds, to: nil)).contains(point)
        }?.tab ?? gesture
    }
}

enum PinCarried {
    static func offset(travel: CGSize, from: Int, index: Int, cells: [CGRect]) -> CGSize {
        guard cells.indices.contains(from), cells.indices.contains(index) else { return .zero }
        let start = cells[from], now = cells[index]
        return CGSize(width: travel.width - (now.midX - start.midX), height: travel.height - (now.midY - start.midY))
    }

    static func target(travel: CGSize, from: Int, cells: [CGRect]) -> Int {
        guard cells.indices.contains(from) else { return 0 }
        let start = cells[from]
        let point = CGPoint(x: start.midX + travel.width, y: start.midY + travel.height)
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? from
    }
}

enum DragOutToKeep {
    static func leftFolder(_ travel: CGSize, reach: CGFloat) -> Bool {
        abs(travel.height) > reach || abs(travel.width) > 60
    }
}

@MainActor
enum TabPress {
    static var brought = false
}

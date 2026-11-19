import AppKit

enum NoticeKind: String, CaseIterable {
    case note, action, error, offer, question, progress

    var seconds: TimeInterval? {
        switch self {
        case .note: 4
        case .action: 8
        case .error: 10
        case .offer: 30
        case .question: nil
        case .progress: 3
        }
    }
}

enum NoticeMotion {
    static let arrival = KitArrival.rise(by: 18)
    static var leaveTime: TimeInterval { Motion.calm ? 0.16 : 0.3 }
    static var changeCurve: KitCurve { .easeOut(0.15) }
    static var waitTime: TimeInterval { KitArrival.fadeCurve(false).duration }

    static func show(_ view: NSView, _ shown: Bool, animated: Bool = true) {
        view.kitArrive(shown, arrival, animated: animated)
    }

    static func enter(_ view: NSView) {
        show(view, false, animated: false)
        show(view, true)
    }

    static func change(_ view: NSView) {
        guard view.window != nil else { return }
        view.wantsLayer = true
        view.layer?.kitTransition(changeCurve)
    }

    static func pose(_ view: NSView, share: CGFloat, leaving: Bool) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let up = !(view.superview?.isFlipped ?? false)
        let hidden = Motion.calm ? CATransform3DIdentity : arrival.transform(in: view.bounds, shown: false, up: up)
        let away = leaving ? hidden : {
            var coming = arrival
            coming.leaveScale = nil
            coming.leaveTravel = nil
            return Motion.calm ? CATransform3DIdentity : coming.transform(in: view.bounds, shown: false, up: up)
        }()
        let gone = 1 - min(1, max(0, share))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * gone }
        var made = CATransform3DIdentity
        made.m11 = mix(1, away.m11)
        made.m22 = mix(1, away.m22)
        made.m41 = mix(0, away.m41)
        made.m42 = mix(0, away.m42)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "arrive")
        layer.removeAnimation(forKey: "arrive.fade")
        layer.transform = made
        layer.opacity = Swift.Float(share)
        CATransaction.commit()
    }
}

extension KitCurve {
    var duration: TimeInterval {
        switch self {
        case .none: 0
        case .spring(let spring): spring.animation("opacity", from: 0, to: 1).settlingDuration
        case .easeOut(let time), .easeInOut(let time): time
        }
    }
}

struct NoticeCountdown: Equatable {
    var left: TimeInterval
    var anchor: Date
    var running: Bool

    init(_ seconds: TimeInterval, at now: Date, running: Bool = true) {
        left = seconds
        anchor = now
        self.running = running
    }

    func remaining(at now: Date) -> TimeInterval {
        running ? max(0, left - now.timeIntervalSince(anchor)) : left
    }

    mutating func hold(_ held: Bool, at now: Date) {
        guard held == running else { return }
        left = remaining(at: now)
        anchor = now
        running = !held
    }

    func due(at now: Date) -> Bool { running && remaining(at: now) <= 0 }
}

@MainActor
final class NoticeClock {
    enum Hold: String { case pointer, focus, away }

    let kind: NoticeKind
    private(set) var countdown: NoticeCountdown?
    private(set) var holds: [Hold] = []
    weak var view: NSView?
    private let window: () -> NSWindow?
    private let page: (() -> String?)?
    private let startPage: String?
    private var fire: (() -> Void)?

    static var now: @MainActor () -> Date = { Date() }
    static var looks: @MainActor (NSView?, NSWindow?) -> [Hold] = { NoticeClock.seen($0, $1) }
    static weak var pointerStandIn: NSView?

    init(_ kind: NoticeKind, window: @escaping () -> NSWindow? = { nil }, page: (() -> String?)? = nil,
         fire: @escaping () -> Void) {
        let now = Self.now()
        self.kind = kind
        self.window = window
        self.page = page
        startPage = page?()
        self.fire = fire
        countdown = kind.seconds.map { NoticeCountdown($0, at: now) }
        NoticeClocks.add(self)
    }

    var live: Bool { fire != nil }

    var pageChanged: Bool { page.map { $0() != startPage } ?? false }

    func remaining(at time: Date? = nil) -> TimeInterval? { countdown?.remaining(at: time ?? Self.now()) }

    func tick(at time: Date? = nil) {
        let now = time ?? Self.now()
        guard fire != nil else { return }
        if let page, page() != startPage { return finish() }
        holds = Self.looks(view, window())
        guard var countdown else { return }
        countdown.hold(!holds.isEmpty, at: now)
        self.countdown = countdown
        if countdown.due(at: now) { finish() }
    }

    func finish() {
        guard let fire else { return }
        self.fire = nil
        NoticeClocks.drop(self)
        fire()
    }

    func cancel() {
        fire = nil
        NoticeClocks.drop(self)
    }

    static func seen(_ view: NSView?, _ window: NSWindow?) -> [Hold] {
        var out: [Hold] = []
        if away(view?.window ?? window) { out.append(.away) }
        guard let view else { return out }
        guard let shown = view.window, !view.isHiddenOrHasHiddenAncestor else {
            if !out.contains(.away) { out.append(.away) }
            return out
        }
        if pointed(view, in: shown) { out.append(.pointer) }
        if let responder = shown.firstResponder as? NSView, responder.isDescendant(of: view) { out.append(.focus) }
        return out
    }

    static func away(_ window: NSWindow?) -> Bool {
        if Store.testing { return Store.settings.bool(forKey: "notice.testAway") }
        guard let window else { return !(NSApp?.isActive ?? false) }
        guard let app = NSApp, app.isActive, !app.isHidden else { return true }
        return !window.isVisible || window.isMiniaturized || !window.occlusionState.contains(.visible)
            || !(window.isKeyWindow || window.isMainWindow || window.childWindows?.contains(where: \.isKeyWindow) == true)
    }

    static func pointed(_ view: NSView, in window: NSWindow) -> Bool {
        if Store.testing { return pointerStandIn.map { $0 === view || $0.isDescendant(of: view) } ?? false }
        let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return view.bounds.contains(point)
    }
}

@MainActor
enum NoticeClocks {
    private final class Held {
        weak var clock: NoticeClock?
        init(_ clock: NoticeClock) { self.clock = clock }
    }

    static let beat: TimeInterval = 0.25
    private static var held: [ObjectIdentifier: Held] = [:]
    private static var timer: Timer?

    static var live: [NoticeClock] { held.values.compactMap(\.clock).filter(\.live) }

    static func add(_ clock: NoticeClock) {
        held[ObjectIdentifier(clock)] = Held(clock)
        run()
    }

    static func drop(_ clock: NoticeClock) {
        held[ObjectIdentifier(clock)] = nil
    }

    static func tick(at time: Date? = nil) {
        let now = time ?? NoticeClock.now()
        for (key, entry) in held where entry.clock == nil { held[key] = nil }
        for clock in live { clock.tick(at: now) }
        if held.isEmpty { stop() }
    }

    private static func run() {
        guard timer == nil, !Store.unitTests else { return }
        let made = Timer(timeInterval: beat, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private static func stop() {
        timer?.invalidate()
        timer = nil
    }
}

@MainActor
final class NoticeBook {
    private var clocks: [String: NoticeClock] = [:]
    private var seen: Set<String> = []

    func clock(_ key: String, _ kind: NoticeKind, view: NSView?, window: @escaping () -> NSWindow?,
               page: (() -> String?)? = nil, fire: @escaping () -> Void) -> NoticeClock {
        seen.insert(key)
        if let kept = clocks[key] {
            if let view { kept.view = view }
            return kept
        }
        let made = NoticeClock(kind, window: window, page: page, fire: fire)
        made.view = view
        clocks[key] = made
        return made
    }

    func begin() { seen = [] }

    func end() {
        for (key, clock) in clocks where !seen.contains(key) {
            clocks[key] = nil
            guard clock.live, clock.pageChanged else {
                clock.cancel()
                continue
            }
            DispatchQueue.main.async { clock.finish() }
        }
    }
}

@MainActor
enum NoticeOffers {
    private static func window(_ browser: Browser) -> () -> NSWindow? { { [weak browser] in browser?.window } }

    static func page(_ tab: Tab?) -> () -> String? {
        { [weak tab] in
            guard let tab else { return nil }
            return tab.id.uuidString + "|" + (tab.pageAddress?.absoluteString ?? "")
        }
    }

    static func alive(_ browser: Browser, _ tab: Tab.ID?) -> () -> String? {
        { [weak browser] in
            guard let tab, let browser else { return nil }
            let here = browser.tabs.contains { $0.id == tab } || browser.parked.values.contains { $0.tabs.contains { $0.id == tab } }
            return here ? tab.uuidString : nil
        }
    }

    static func password(_ book: NoticeBook, _ browser: Browser, _ offer: Browser.Offer, _ view: NSView) -> NoticeClock {
        book.clock("password|" + offer.login.host + "|" + offer.login.user, .offer, view: view, window: window(browser),
                   page: alive(browser, browser.offeringTab)) { [weak browser] in
            guard browser?.offering == offer else { return }
            browser?.dropOffer()
        }
    }

    static func store(_ book: NoticeBook, _ browser: Browser, _ id: String, _ view: NSView) -> NoticeClock {
        let tab = browser.active
        return book.clock("store|" + id, .offer, view: view, window: window(browser), page: page(tab)) { [weak tab] in
            tab?.storePlaced = id
        }
    }

    static func fill(_ book: NoticeBook, _ browser: Browser, _ up: FormFill.Preview, _ view: NSView) -> NoticeClock {
        let forms = browser.forms
        let tab = browser.tabs.first { $0.id == up.tab }
        return book.clock("fill|" + up.tab.uuidString, .offer, view: view, window: window(browser), page: page(tab)) { [weak forms] in
            guard forms?.preview?.tab == up.tab else { return }
            forms?.cancel()
        }
    }

    static func filled(_ book: NoticeBook, _ browser: Browser, _ up: FormFill.Done, _ view: NSView) -> NoticeClock {
        let forms = browser.forms
        return book.clock("filled|" + up.tab.uuidString + "|\(up.filled)|\(up.stays)", .action, view: view, window: window(browser)) { [weak forms] in
            guard forms?.done == up else { return }
            forms?.dismissDone()
        }
    }

    static func save(_ book: NoticeBook, _ browser: Browser, _ up: FormFill.Offer, _ view: NSView) -> NoticeClock {
        let forms = browser.forms
        return book.clock("save|" + up.tab.uuidString, .offer, view: view, window: window(browser), page: alive(browser, up.tab)) { [weak forms] in
            guard forms?.offer == up else { return }
            forms?.dropOffer()
        }
    }

    static func shield(_ book: NoticeBook, _ browser: Browser, _ host: String, _ view: NSView) -> NoticeClock {
        let tab = browser.active
        let curtain = browser.curtain
        return book.clock("shield|" + host, .offer, view: view, window: window(browser), page: { [weak tab] in curtain.host(of: tab?.address) }) {
            if Shield.shared.offer == host { Shield.shared.offer = nil }
        }
    }

    static func developer(_ book: NoticeBook, _ browser: Browser, _ key: String, _ view: NSView, notNow: @escaping () -> Void) -> NoticeClock {
        let tab = browser.active
        return book.clock("developer|" + key, .offer, view: view, window: window(browser),
                          page: { [weak tab] in LocalServer.key(tab?.pageAddress) }) {
            guard Developer.shared.offer == key else { return }
            notNow()
        }
    }
}

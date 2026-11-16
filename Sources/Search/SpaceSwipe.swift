import AppKit

// Spaces, paged through: in the column, two fingers sideways go from one to
// the next, the rows following them, as in Arc; in the bar across the top,
// the same up and down, the row of tabs following them — or a mouse wheel's
// notch, one space at a time, or the mouse's back and forward buttons with
// the pointer over the tabs. The space's icon turns over as it goes (see SpaceDot).

/// The swipe between spaces. It reads the trackpad's own scroll events
/// before anything else sees them, and takes only a gesture that starts over
/// the tabs and sets off clearly along the spaces' axis — sideways in the
/// column, up or down in the bar; everything else (scrolling the tabs, a
/// long row of them sideways) goes on as it would have.
@MainActor
final class SpaceSwipe {
    static let shared = SpaceSwipe()

    private weak var browser: Browser?
    private var monitor: Any?
    private var buttons: Any?
    private enum Axis { case undecided, across, along }
    private var axis = Axis.undecided
    private var tracking = false
    /// The glide after a swipe that was taken, which is taken too.
    private var gliding = false
    private var gathered = CGSize.zero
    private var trail: [(time: CFTimeInterval, travel: CGFloat)] = []
    private var stamp: CFTimeInterval?
    private var finish: (() -> Void)?
    private var heading: Int?
    var held = false

    func target(of browser: Browser) -> Int? {
        guard self.browser === browser, let heading, browser.spaces.indices.contains(heading) else { return nil }
        return heading
    }
    /// When the wheel last turned over the bar, whether a space came of it
    /// or not. A spin of the wheel is a run of notches close together, and
    /// it brings one space: the next waits for the wheel to have rested.
    private var notched = Date.distantPast
    /// Until when a new gesture is let go by: the hand that just brought a
    /// space is often still moving, and its next stroke would take one more.
    private var resting = Date.distantPast
    /// A gesture let go by while resting, kept whole, glide included.
    private var ignoring = false

    /// How long after a space comes before another can.
    static let rest: TimeInterval = 0.4

    nonisolated static let enough: CGFloat = 50
    nonisolated static let flick: CGFloat = 500

    func start(for browser: Browser) {
        self.browser = browser
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { SpaceSwipe.shared.takes(event) } ? nil : event
        }
        buttons = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe]) { event in
            MainActor.assumeIsolated { SpaceSwipe.shared.pressed(event) } ? nil : event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { SpaceSwipe.shared.cancel() }
        }
    }

    /// The mouse's back and forward buttons over the tabs: the space before,
    /// or the one after. Over the page they stay the page's back and forward
    /// (PageView.otherMouseDown).
    ///
    /// Most mice send them as buttons 3 and 4. A Logitech mouse set up with
    /// Logi Options+, Logitech's own driver, doesn't: it turns them into the
    /// swipe a trackpad sends for going back or forward a page — deltaX 1
    /// for back, -1 for forward, which is how Safari reads it. A swipe of
    /// that kind over the tabs is taken the same way, whoever sends it.
    private func pressed(_ event: NSEvent) -> Bool {
        let step: Int
        switch event.type {
        case .otherMouseDown where event.buttonNumber == 3: step = -1
        case .otherMouseDown where event.buttonNumber == 4: step = 1
        case .swipe where event.deltaX != 0: step = event.deltaX > 0 ? -1 : 1
        default: return false
        }
        guard let browser = Browsers.browser(for: event.window), !browser.keepsNothing, browser.showsSpaces,
              !browser.prefs.stacksSpaces, !browser.folded || browser.peeking, overTabs(event, in: browser) else { return false }
        self.browser = browser
        go(browser, by: step)
        return true
    }

    private func go(_ browser: Browser, by step: Int) {
        browser.hoverCards.quiet()
        let reach = reach(of: browser)
        if let target = reach.step(step) {
            slide(browser, to: target, from: reach.here)
        } else if finish == nil {
            browser.spaceMotion.bump(step > 0 ? -1 : 1, width: browser.prefs.columnWidth)
        }
    }

    private func overTabs(_ event: NSEvent, in browser: Browser) -> Bool {
        guard let window = event.window, window === browser.window else { return false }
        return browser.prefs.sidePosition == .right
            ? event.locationInWindow.x >= window.frame.width - browser.prefs.columnWidth
            : event.locationInWindow.x < browser.prefs.columnWidth
    }

    private weak var panned: SpaceFootView?

    func foot(at point: NSPoint, in browser: Browser, window: NSWindow?) -> SpaceFootView? {
        guard let window else { return nil }
        return browser.spaceFeet.allObjects.first { foot in
            foot.window === window && foot.pans && foot.bounds.contains(foot.convert(point, from: nil))
        }
    }

    func pan(_ scroll: Scroll, at point: NSPoint, in browser: Browser, window: NSWindow?) -> Bool {
        let fresh = scroll.phase == .began || scroll.phase == .mayBegin || (scroll.phase.isEmpty && scroll.momentum.isEmpty)
        if fresh { panned = busy ? nil : foot(at: point, in: browser, window: window) }
        guard let foot = panned else { return false }
        guard foot.pans else {
            panned = nil
            return false
        }
        foot.wheel(dx: scroll.dx, dy: scroll.dy, precise: scroll.precise)
        if scroll.phase == .cancelled || scroll.momentum == .ended || scroll.momentum == .cancelled { panned = nil }
        return true
    }

    struct Scroll {
        var phase: NSEvent.Phase = []
        var momentum: NSEvent.Phase = []
        var precise = true
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var time: CFTimeInterval?
    }

    var busy: Bool { tracking || gliding }
    var touching: Bool { tracking }

    private func takes(_ event: NSEvent) -> Bool {
        guard !held || busy else { return false }
        if event.phase == .began || (!tracking && !event.hasPreciseScrollingDeltas), let over = Browsers.browser(for: event.window) {
            browser = over
        }
        guard let browser else { return false }
        let scroll = Scroll(phase: event.phase, momentum: event.momentumPhase, precise: event.hasPreciseScrollingDeltas,
                            dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, time: event.timestamp)
        if pan(scroll, at: event.locationInWindow, in: browser, window: event.window) { return true }
        return take(scroll, over: overTabs(event, in: browser))
    }

    func take(_ scroll: Scroll, over: Bool) -> Bool {
        guard !held || busy, let browser, browser.showsSpaces, !browser.prefs.stacksSpaces,
              !browser.folded || browser.peeking else { return false }
        if !scroll.precise {
            let step = abs(scroll.dx) > abs(scroll.dy) ? scroll.dx : 0
            guard step != 0, over else { return false }
            let now = Date()
            let rested = now.timeIntervalSince(notched) > 0.3 && now > resting
            notched = now
            guard rested else { return true }
            go(browser, by: step < 0 ? 1 : -1)
            return true
        }
        if !scroll.momentum.isEmpty { return gliding }
        stamp = scroll.time
        defer { stamp = nil }
        switch scroll.phase {
        case .began:
            gliding = false
            ignoring = false
            guard over else {
                tracking = false
                return false
            }
            began()
            if ignoring { return true }
            return moved(dx: scroll.dx, dy: scroll.dy)
        case .changed:
            if ignoring { return true }
            guard tracking else { return false }
            return moved(dx: scroll.dx, dy: scroll.dy)
        case .ended, .cancelled:
            if ignoring {
                ignoring = false
                gliding = true
                return true
            }
            guard tracking else { return false }
            let taken = axis == .across
            ended(cancelled: scroll.phase == .cancelled)
            gliding = taken
            return taken
        default:
            return false
        }
    }

    // MARK: - the gesture, apart from where its events come from (the bench drives these)

    func began() {
        if tracking { ended(cancelled: true) }
        axis = .undecided
        gathered = .zero
        trail = []
        ignoring = false
        tracking = browser.map { $0.showsSpaces && !$0.prefs.stacksSpaces } ?? false
    }

    @discardableResult
    func moved(dx: CGFloat, dy: CGFloat) -> Bool {
        guard tracking, let browser else { return false }
        gathered.width += dx
        gathered.height += dy
        if axis == .undecided {
            guard abs(gathered.width) + abs(gathered.height) > 6 else { return false }
            axis = abs(gathered.width) > abs(gathered.height) * 1.5 ? .across : .along
            if axis == .across {
                browser.hoverCards.quiet()
                browser.preloadSpaces()
                catchUp(browser)
            }
        }
        guard axis == .across else { return false }
        let now = stamp ?? CACurrentMediaTime()
        trail.append((now, gathered.width))
        trail.removeAll { now - $0.time > 0.08 }
        guard tracking else { return ignoring }
        let width = browser.prefs.columnWidth
        let reach = reach(of: browser)
        let shown = reach.resisted(gathered.width, width: width)
        let wanted = reach.neighbour(for: shown)
        if browser.spaceNext != wanted { browser.spaceNext = wanted }
        browser.spaceMotion.follow(shown + browser.spaceMotion.base, width: width)
        return true
    }

    private func catchUp(_ browser: Browser) {
        guard browser.spaceMotion.moving else { return }
        if let heading, !reach(of: browser).holds(heading) {
            tracking = false
            ignoring = true
            return
        }
        browser.spaceMotion.halt()
        let width = browser.prefs.columnWidth
        let caught = SpaceReach.caught(browser.spaceMotion.local, width: width)
        if let heading, finish != nil, caught.lands, abs(heading - browser.spaceSeen) > 1 {
            finish = nil
            self.heading = nil
            SpaceSwipe.land(browser, on: heading)
            gathered.width += caught.offset
        } else if let heading, finish != nil, caught.lands {
            let real = browser.spaceAt
            browser.spaceShown = heading == real ? nil : heading
            browser.spaceMotion.base = -SpaceLane.place(heading, real: real, seen: heading, next: nil) * width
            gathered.width += browser.spaceMotion.local
        } else {
            gathered.width += browser.spaceMotion.local
        }
        finish = nil
        heading = nil
        browser.preloadSpaces()
    }

    private func reach(of browser: Browser) -> SpaceReach {
        SpaceReach(count: browser.spaces.count, here: browser.spaceSeen, making: browser.makingSpace)
    }

    private var speed: CGFloat {
        Self.releaseSpeed(trail, at: stamp ?? CACurrentMediaTime())
    }

    nonisolated static func releaseSpeed(_ trail: [(time: CFTimeInterval, travel: CGFloat)], at now: CFTimeInterval) -> CGFloat {
        guard let first = trail.first, let last = trail.last, last.time > first.time, now - last.time <= 0.08 else { return 0 }
        return (last.travel - first.travel) / CGFloat(last.time - first.time)
    }

    func ended(cancelled: Bool = false) {
        defer { tracking = false }
        guard let browser else { return }
        guard axis == .across else { return settle(browser) }
        browser.spaceMotion.window = browser.window
        let travel = gathered.width
        let reach = reach(of: browser)
        let leaving = speed
        guard let target = reach.landing(travel: travel, speed: leaving, cancelled: cancelled) else {
            let width = browser.prefs.columnWidth
            let give = travel == 0 ? 1 : reach.resisted(travel, width: width) / travel
            browser.spaceMotion.carry(to: browser.spaceMotion.base, width: width, velocity: leaving * give) {
                SpaceSwipe.back(browser)
            }
            return
        }
        slide(browser, to: target, from: reach.here, velocity: leaving)
    }

    func settle(_ browser: Browser) {
        guard !tracking, finish == nil, !browser.spaceMotion.moving,
              browser.spaceMotion.offset != 0 || browser.spaceNext != nil else { return }
        browser.spaceMotion.window = browser.window
        browser.spaceMotion.carry(to: browser.spaceMotion.base, width: browser.prefs.columnWidth) { [weak browser] in
            guard let browser else { return }
            SpaceSwipe.back(browser)
        }
    }

    private static func back(_ browser: Browser) {
        if let shown = browser.spaceShown, shown != browser.spaceAt {
            land(browser, on: shown)
        } else {
            browser.spaceShown = nil
            browser.spaceNext = nil
        }
    }

    func cancel() {
        guard let browser else { return }
        if tracking {
            ended(cancelled: true)
            gliding = false
        } else {
            settle(browser)
        }
    }

    func slide(_ browser: Browser, to target: Int, from here: Int, velocity: CGFloat? = nil) {
        self.browser = browser
        browser.hoverCards.quiet()
        let wasMoving = finish != nil
        finish?()
        if !wasMoving, !tracking, let shown = browser.spaceShown, shown != browser.spaceAt {
            SpaceSwipe.land(browser, on: shown)
        }
        let here = wasMoving || browser.spaceShown != nil ? reach(of: browser).here : here
        guard target != here else { return }
        if browser.makingSpace || browser.spaceAsk.up, target != browser.spaces.count {
            browser.cancelSpaceCreation()
        }
        let width = browser.prefs.columnWidth
        let lane = SpaceLane.place(target, real: browser.spaceAt, seen: here, next: target)
        browser.spaceStep = target > here ? 1 : -1
        resting = Date().addingTimeInterval(SpaceSwipe.rest)
        browser.spaceMotion.window = browser.window
        let land = { [weak self, weak browser] in
            guard let browser else { return }
            self?.finish = nil
            self?.heading = nil
            SpaceSwipe.land(browser, on: target)
        }
        guard !Motion.reduced else { return land() }
        finish = land
        heading = target
        browser.spaceNext = target
        browser.spaceMotion.carry(to: -lane * width, width: width, velocity: velocity) { land() }
    }

    private static func land(_ browser: Browser, on target: Int) {
        let moves = target != browser.spaceAt
        KitChange.still {
            browser.spaceShown = nil
            if target >= browser.spaces.count {
                browser.makingSpace = true
            } else {
                browser.makingSpace = false
                browser.spaceDraftIcon = nil
                let id = browser.spaces[target].id
                if !browser.isPrivate, id != browser.spaceID {
                    browser.spacePages.adopt(id, row: browser.parked[id], leaving: browser.spaceID)
                }
                browser.switchSpace(to: id)
            }
            browser.spaceNext = nil
            if moves { browser.spaceMotion.land() } else { browser.spaceMotion.rest() }
        }
        browser.spacePages.settle()
    }
}

struct SpaceReach: Equatable {
    let count: Int
    let here: Int
    let making: Bool

    func holds(_ index: Int) -> Bool {
        !making && index >= 0 && index < count
    }

    func step(_ by: Int) -> Int? {
        let target = here + by
        return by != 0 && holds(target) ? target : nil
    }

    func neighbour(for shown: CGFloat) -> Int? {
        guard shown != 0 else { return nil }
        return step(shown < 0 ? 1 : -1)
    }

    static let give: CGFloat = 18

    func resisted(_ travel: CGFloat, width: CGFloat) -> CGFloat {
        guard neighbour(for: travel) != nil else {
            return (travel < 0 ? -1 : 1) * Self.give * (1 - exp(-abs(travel) / (4 * Self.give)))
        }
        guard abs(travel) > width else { return travel }
        return (travel < 0 ? -1 : 1) * (width + (abs(travel) - width) / 6)
    }

    static func caught(_ offset: CGFloat, width: CGFloat) -> (lands: Bool, offset: CGFloat) {
        guard abs(offset) > width / 2 else { return (false, offset) }
        return (true, offset + (offset < 0 ? width : -width))
    }

    func landing(travel: CGFloat, speed: CGFloat, cancelled: Bool) -> Int? {
        guard !cancelled else { return nil }
        let fast = abs(speed) > SpaceSwipe.flick
        let thrownBack = fast && (speed < 0) != (travel < 0)
        guard !thrownBack, fast || abs(travel) >= SpaceSwipe.enough else { return nil }
        return neighbour(for: travel)
    }
}

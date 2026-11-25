import AppKit
import Combine
import EventKit
import Observation

enum MeetingLead: String, CaseIterable, Identifiable, Sendable {
    case start = "0", one = "1", two = "2", five = "5", ten = "10"

    var id: String { rawValue }
    var minutes: Int { Int(rawValue) ?? 1 }
    var seconds: TimeInterval { TimeInterval(minutes * 60) }

    var title: String {
        switch self {
        case .start: "When it starts"
        case .one: "1 minute before"
        default: "\(minutes) minutes before"
        }
    }
}

@MainActor
@Observable
final class MeetingAlertPrefs {
    static let shared = MeetingAlertPrefs()

    nonisolated static let onKey = "meetings.alerts"
    nonisolated static let leadKey = "meetings.lead"
    nonisolated static let skipKey = "meetings.skip"

    @ObservationIgnored private let store: UserDefaults

    var chosen: Bool? {
        didSet {
            if let chosen { store.set(chosen, forKey: Self.onKey) } else { store.removeObject(forKey: Self.onKey) }
        }
    }
    var lead: MeetingLead {
        didSet { store.set(lead.rawValue, forKey: Self.leadKey) }
    }
    var skipped: Set<String> {
        didSet { store.set(skipped.sorted(), forKey: Self.skipKey) }
    }

    init(store: UserDefaults = Store.settings) {
        self.store = store
        chosen = store.object(forKey: Self.onKey) as? Bool
        lead = store.string(forKey: Self.leadKey).flatMap(MeetingLead.init) ?? .one
        skipped = Set(store.stringArray(forKey: Self.skipKey) ?? [])
    }

    var on: Bool { chosen ?? true }

    func alerts(from calendar: MeetingCalendar) -> Bool {
        !skipped.contains(calendar.id)
    }

    func alerts(from calendar: MeetingCalendar, shown: Bool) {
        if shown { skipped.remove(calendar.id) } else { skipped.insert(calendar.id) }
    }
}

struct MeetingAlertPlan: Equatable {
    var due: [Meeting] = []
    var next: Date?
}

enum MeetingJoin: Equatable {
    case tab(URL)
    case app(URL)

    static func installed(_ scheme: String) -> Bool {
        guard let probe = URL(string: "\(scheme)://") else { return false }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    static func route(_ link: URL, service: MeetingLink.Service?, installed: (String) -> Bool) -> MeetingJoin {
        switch service {
        case .zoom:
            if let app = zoomApp(link), installed("zoommtg") { return .app(app) }
        case .teams:
            if let app = teamsApp(link), installed("msteams") { return .app(app) }
        default:
            break
        }
        return .tab(link)
    }

    static func zoomApp(_ link: URL) -> URL? {
        guard let host = link.host()?.lowercased() else { return nil }
        let parts = link.pathComponents.filter { $0 != "/" }
        guard let mark = parts.firstIndex(where: { ["j", "w", "wc"].contains($0.lowercased()) }), mark + 1 < parts.count else { return nil }
        let number = parts[mark + 1]
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        var made = URLComponents()
        made.scheme = "zoommtg"
        made.host = host
        made.path = "/join"
        var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: number)]
        if let pwd = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
            items.append(URLQueryItem(name: "pwd", value: pwd))
        }
        made.queryItems = items
        return made.url
    }

    static func teamsApp(_ link: URL) -> URL? {
        let text = link.absoluteString
        for prefix in ["https://teams.microsoft.com", "https://teams.live.com"] where text.lowercased().hasPrefix(prefix) {
            return URL(string: "msteams:" + text.dropFirst(prefix.count))
        }
        return nil
    }
}

enum MeetingAlertRules {
    static let lingers: TimeInterval = 600

    static func key(_ event: CalendarEvent) -> String {
        "\(event.id)|\(Int(event.start.timeIntervalSince1970))"
    }

    static func gone(_ event: CalendarEvent) -> Date {
        event.end > event.start ? min(event.start.addingTimeInterval(lingers), event.end) : event.start.addingTimeInterval(lingers)
    }

    static func plan(_ events: [CalendarEvent], at now: Date, lead: TimeInterval, skip: Set<String> = [],
                     dismissed: Set<String> = [], snoozed: [String: Date] = [:]) -> MeetingAlertPlan {
        var plan = MeetingAlertPlan()
        func soon(_ date: Date) { plan.next = min(plan.next ?? date, date) }
        var seen = Set<String>()
        for event in events.sorted(by: { ($0.start, $0.id) < ($1.start, $1.id) }) {
            let key = key(event)
            guard !event.allDay, !event.declined, !skip.contains(event.calendar), !dismissed.contains(key),
                  seen.insert(key).inserted
            else { continue }
            let gone = gone(event)
            guard gone > now else { continue }
            let at = snoozed[key] ?? event.start.addingTimeInterval(-lead)
            if at <= now {
                plan.due.append(Meeting(event: event))
                soon(gone)
            } else if at < gone {
                soon(at)
            }
        }
        return plan
    }

    static func snooze(_ event: CalendarEvent, at now: Date) -> Date {
        event.start.timeIntervalSince(now) > 30 ? event.start : now.addingTimeInterval(120)
    }

    enum Stage: Equatable {
        case soon(Int)
        case now
        case late(Int)

        var said: String {
            switch self {
            case .soon(let minutes): "In \(minutes) min"
            case .now: "Now"
            case .late(let minutes): "Started \(minutes) min ago"
            }
        }
    }

    static func stage(_ event: CalendarEvent, at now: Date) -> Stage {
        let wait = event.start.timeIntervalSince(now)
        if wait > 30 { return .soon(max(1, Int((wait / 60).rounded(.up)))) }
        if wait > -60 { return .now }
        return .late(Int((-wait / 60).rounded(.down)))
    }

    static func span(_ event: CalendarEvent) -> String {
        "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))"
    }

    static func when(_ event: CalendarEvent, at now: Date) -> String {
        "\(stage(event, at: now).said) · \(span(event))"
    }

    static func snoozeTitle(_ event: CalendarEvent, at now: Date) -> String {
        let wait = snooze(event, at: now).timeIntervalSince(now)
        return "Snooze \(max(1, Int((wait / 60).rounded(.up)))) min"
    }

    static func changes(_ event: CalendarEvent) -> [Date] {
        let before = (1...10).map { event.start.addingTimeInterval(TimeInterval(-60 * $0)) }
        let after = (1...10).map { event.start.addingTimeInterval(TimeInterval(60 * $0)) }
        return (before + [event.start.addingTimeInterval(-30)] + after).sorted()
    }

    static func reply(for event: CalendarEvent) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in [event.url?.absoluteString ?? "", event.location, event.notes] {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { continue }
                let path = url.path().lowercased()
                let query = url.query()?.lowercased() ?? ""
                if host == "calendar.google.com", path.hasPrefix("/calendar/event") || query.contains("eid=") { return url }
                if ["outlook.office.com", "outlook.office365.com", "outlook.live.com"].contains(host), path.contains("calendar") { return url }
            }
        }
        guard !event.external.isEmpty,
              let id = event.external.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))
        else { return nil }
        return URL(string: "ical://ekevent/\(id)?method=show&options=more")
    }

    static func initials(_ person: MeetingPerson) -> String {
        let words = person.name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" }).filter { $0.first?.isLetter == true }
        if words.count >= 2, let first = words.first?.first, let last = words.last?.first { return "\(first)\(last)".uppercased() }
        if let only = words.first?.first { return String(only).uppercased() }
        let local = person.email.split(separator: "@").first ?? ""
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" }).filter { $0.first?.isLetter == true }
        if parts.count >= 2, let first = parts.first?.first, let last = parts.last?.first { return "\(first)\(last)".uppercased() }
        return parts.first?.first.map { String($0).uppercased() } ?? "?"
    }

    static func hue(_ person: MeetingPerson) -> Double {
        let seed = (person.email.isEmpty ? person.name : person.email).lowercased()
        var hash: UInt32 = 2166136261
        for byte in seed.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return Double(hash % 360) / 360
    }
}

@MainActor
final class MeetingAlerts {
    static let shared = MeetingAlerts(meetings: .shared, prefs: .shared)
    static let horizon: TimeInterval = 24 * 3600
    static let reread: TimeInterval = 6 * 3600
    private static let dismissedKey = "meetings.dismissed"

    private(set) var due: [Meeting] = []
    private(set) var fireAt: Date?
    private(set) var running = false
    private(set) var reads = 0
    private(set) var reading: Task<Void, Never>?
    private(set) var opened: [URL] = []

    var clock: () -> Date = Date.init
    var arm: ((Date?) -> Void)?
    var present: (([Meeting]) -> Void)?
    var installed: (String) -> Bool = { Store.testing ? false : MeetingJoin.installed($0) }

    let meetings: Meetings
    let prefs: MeetingAlertPrefs
    private let store: UserDefaults
    private var events: [CalendarEvent] = []
    private var readAt: Date?
    private var timer: Timer?
    private var watchers: [(NotificationCenter, NSObjectProtocol)] = []
    private var dismissed: Set<String>
    private var snoozed: [String: Date] = [:]
    private var changes: AnyCancellable?
    private lazy var panel = MeetingAlertPanel(alerts: self)

    init(meetings: Meetings, prefs: MeetingAlertPrefs, store: UserDefaults = Store.settings) {
        self.meetings = meetings
        self.prefs = prefs
        self.store = store
        let floor = Date().addingTimeInterval(-24 * 3600).timeIntervalSince1970
        dismissed = Set((store.stringArray(forKey: Self.dismissedKey) ?? []).filter { key in
            key.split(separator: "|").last.flatMap { Double($0) }.map { $0 > floor } ?? false
        })
        changes = kitObserve(initial: false, { [weak prefs] in (prefs?.chosen, prefs?.lead, prefs?.skipped) }) { [weak self] _ in
            self?.sync()
        }
    }

    var wanted: Bool { prefs.on && meetings.hasAccess }

    func sync() {
        if wanted {
            if running { replan() } else { start() }
        } else {
            stop()
        }
    }

    func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for (hub, name) in [(center, Notification.Name.EKEventStoreChanged), (center, .NSSystemTimeZoneDidChange),
                            (center, .NSSystemClockDidChange), (workspace, NSWorkspace.didWakeNotification)] {
            let watcher = hub.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reread() }
            }
            watchers.append((hub, watcher))
        }
        reread()
    }

    func stop() {
        running = false
        for (hub, watcher) in watchers { hub.removeObserver(watcher) }
        watchers = []
        reading?.cancel()
        reading = nil
        events = []
        readAt = nil
        schedule(nil)
        show([])
    }

    func reread() {
        reading = Task { await refresh() }
    }

    func refresh() async {
        guard running else { return }
        let now = clock()
        let found = await meetings.events(from: now.addingTimeInterval(-MeetingAlertRules.lingers), to: now.addingTimeInterval(Self.horizon))
        guard running, !Task.isCancelled else { return }
        reads += 1
        events = found
        readAt = now
        replan()
    }

    func replan() {
        guard running else { return }
        let now = clock()
        snoozed = snoozed.filter { $0.value > now.addingTimeInterval(-Self.horizon) }
        let plan = MeetingAlertRules.plan(events, at: now, lead: prefs.lead.seconds, skip: prefs.skipped,
                                          dismissed: dismissed, snoozed: snoozed)
        show(plan.due)
        var next = plan.next
        if let readAt {
            let again = readAt.addingTimeInterval(Self.reread)
            next = min(next ?? again, again)
        }
        schedule(next)
    }

    func fire() {
        guard running else { return }
        if let readAt, clock() >= readAt.addingTimeInterval(Self.reread) {
            reread()
        } else {
            replan()
        }
    }

    private func show(_ found: [Meeting]) {
        guard found != due else { return }
        due = found
        if let present { present(found) } else { panel.update(found) }
    }

    private func schedule(_ date: Date?) {
        fireAt = date
        if let arm {
            arm(date)
            return
        }
        timer?.invalidate()
        timer = nil
        guard let date else { return }
        let next = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        next.tolerance = 0
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }

    func dismiss(_ meeting: Meeting) {
        dismissed.insert(MeetingAlertRules.key(meeting.event))
        store.set(dismissed.sorted(), forKey: Self.dismissedKey)
        replan()
    }

    func snooze(_ meeting: Meeting) {
        snoozed[MeetingAlertRules.key(meeting.event)] = MeetingAlertRules.snooze(meeting.event, at: clock())
        replan()
    }

    func join(_ meeting: Meeting, in browser: Browser? = nil) {
        guard let link = meeting.link else { return }
        switch MeetingJoin.route(link, service: meeting.service, installed: installed) {
        case .app(let app):
            opened.append(app)
            if !Store.testing { NSWorkspace.shared.open(app) }
        case .tab(let page):
            opened.append(page)
            (browser ?? Browsers.acting).joinMeeting(page, event: meeting.event)
        }
        dismiss(meeting)
    }

    func respond(_ meeting: Meeting, in browser: Browser? = nil) {
        guard let reply = MeetingAlertRules.reply(for: meeting.event) else { return }
        opened.append(reply)
        if reply.scheme == "https" {
            (browser ?? Browsers.acting).joinMeeting(reply, event: meeting.event)
        } else if !Store.testing {
            NSWorkspace.shared.open(reply)
        }
    }

    func forgetOpened() { opened = [] }

    var panelFrame: NSRect { panel.frame }
    var panelTakesClicks: Bool { panel.takesClicks }
    func panelReach(at pointer: NSPoint) { panel.reach(at: pointer) }
    var panelCards: [NSRect] { panel.cards.compactMap { card in card.window.map { $0.convertToScreen(card.convert(card.bounds, to: nil)) } } }
    var panelShown: Bool { panel.shown }

    func shot(dark: Bool, front: Bool = false, controls: Bool = false, key: Bool = false, ground: String? = nil,
              join: String? = nil) -> [String: Any]? {
        panel.beginShot(dark: dark, front: front, controls: controls, key: key, ground: ground, join: join)
    }
    var shotState: [String: Any] { panel.shotState }
    func endShot() { panel.endShot() }
    func takeShot(then: @escaping (Data?) -> Void) { panel.take(then: then) }
    func render(dark: Bool) -> Data? { panel.render(dark: dark) }
}

extension Meeting {
    var alertKey: String { MeetingAlertRules.key(event) }
}

@MainActor
final class MeetingAlertPanel {
    static let width: CGFloat = 340
    static let gap: CGFloat = 16
    static let bleed: CGFloat = 44

    private unowned let alerts: MeetingAlerts
    private var panel: NSPanel?
    private var stack: MeetingAlertStackView?
    private var shotWindow: NSPanel?
    private var parked: [(NSWindow, NSRect)] = []
    private var given: NSRunningApplication?
    private var pagesShown = false
    private var watching: [Any] = []
    private var pulse: Timer?

    init(alerts: MeetingAlerts) {
        self.alerts = alerts
    }

    var shown: Bool { panel != nil }
    var frame: NSRect { panel?.frame ?? .zero }
    var cards: [MeetingAlertCardView] { stack?.cards ?? [] }

    func update(_ due: [Meeting]) {
        guard !due.isEmpty else {
            unwatch()
            panel?.orderOut(nil)
            panel = nil
            stack = nil
            return
        }
        if let stack {
            stack.due = due
        } else {
            let made = MeetingAlertStackView(alerts: alerts)
            made.due = due
            stack = made
            let panel = Lifted(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = KeepOnTop.panelLevel
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.isExcludedFromWindowsMenu = true
            panel.title = "Meeting alert"
            panel.contentView = made
            self.panel = panel
        }
        guard let panel, let stack else { return }
        let size = stack.intrinsicContentSize
        panel.setFrame(NSRect(origin: spot(for: size), size: size), display: true)
        stack.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        watch()
        reach()
    }

    private func spot(for size: NSSize) -> NSPoint {
        if Store.testing { return NSPoint(x: -20000, y: -20000) }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let past = Self.bleed - Self.gap
        return NSPoint(x: visible.maxX - size.width + past, y: visible.maxY - size.height + past)
    }

    var takesClicks: Bool { panel.map { !$0.ignoresMouseEvents } ?? false }

    func reach(at pointer: NSPoint = NSEvent.mouseLocation) {
        guard let panel, let stack, NSEvent.pressedMouseButtons == 0 else { return }
        let over = stack.cards.contains { panel.convertToScreen($0.convert($0.bounds, to: nil)).contains(pointer) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    private func watch() {
        guard watching.isEmpty, !Store.testing else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let far = NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
            MainActor.assumeIsolated { self?.reach() }
        }
        let near = NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            MainActor.assumeIsolated { self?.reach() }
            return event
        }
        watching = [far, near].compactMap { $0 }
        let beat = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reach() }
        }
        beat.tolerance = 0.02
        RunLoop.main.add(beat, forMode: .common)
        pulse = beat
    }

    private func unwatch() {
        for monitor in watching { NSEvent.removeMonitor(monitor) }
        watching = []
        pulse?.invalidate()
        pulse = nil
    }

    func beginShot(dark: Bool, front: Bool = false, controls: Bool = false, key: Bool = false, ground: String? = nil,
                   join pose: String? = nil) -> [String: Any]? {
        guard Store.testing, !alerts.due.isEmpty else { return nil }
        endShot()
        let view = MeetingAlertShotView(due: alerts.due, alerts: alerts, dark: dark, drawn: false, controls: controls, ground: ground)
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel]
        let window: NSPanel = key ? Keyed(contentRect: view.frame, styleMask: style, backing: .buffered, defer: false)
            : Lifted(contentRect: view.frame, styleMask: style, backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.title = "Broadway meeting alert probe"
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.ignoresMouseEvents = true
        if ground == "clear" {
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
        }
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.contentView = view
        parked = NSApp.windows.filter { $0 !== window }.map { ($0, $0.frame) }
        let away = NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 10000,
                           y: (NSScreen.screens.map(\.frame.maxY).max() ?? 0) + 10000)
        for (other, _) in parked {
            other.orderOut(nil)
            other.setFrameOrigin(away)
        }
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        window.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.minY + 20))
        pagesShown = Bench.pagesShown
        Bench.pagesShown = true
        shotWindow = window
        window.orderBack(nil)
        if front {
            given = NSWorkspace.shared.frontmostApplication
            Bench.frontAsked = true
            NSApp.activate(ignoringOtherApps: true)
            if !NSApp.isActive, let given { NSRunningApplication.current.activate(from: given, options: .activateAllWindows) }
            if key { window.makeKey() }
        } else {
            NSApp.unhideWithoutActivation()
        }
        view.layoutSubtreeIfNeeded()
        let joinKey = view.kitSubviews(of: MeetingJoinButton.self).first
        if let joinKey, let pose { self.pose(joinKey, pose, in: window) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = window.backingScaleFactor
        func spot(_ target: NSView) -> [Int] {
            let box = target.convert(target.bounds, to: nil)
            return [box.minX, window.frame.height - box.maxY, box.width, box.height].map { Int(($0 * scale).rounded()) }
        }
        var spots: [String: [Int]] = [:]
        if let join = view.kitSubviews(of: MeetingJoinButton.self).first { spots["join"] = spot(join) }
        if let snooze = view.kitSubviews(of: KitGlassKey.self).first(where: { $0.title.hasPrefix("Snooze") }) { spots["snooze"] = spot(snooze) }
        if let stack = view.kitSubviews(of: MeetingAlertStackView.self).first { spots["stack"] = spot(stack) }
        for (index, card) in view.kitSubviews(of: MeetingAlertCardView.self).enumerated() { spots["card\(index)"] = spot(card) }
        for (name, swatch) in view.swatches { spots[name] = spot(swatch) }
        var join: [String: Any] = [:]
        if let joinKey {
            join["layers"] = joinKey.layer.map { Self.layerLines($0) } ?? []
            join["views"] = Self.viewLines(joinKey)
            join["face"] = Self.srgb(joinKey.face.layer?.backgroundColor)
            join["systemGreen"] = Self.srgb(joinKey.resolved(.systemGreen))
            join["pressed"] = joinKey.pressed
            join["hovering"] = joinKey.hovering
            join["focused"] = window.firstResponder === joinKey
            join["scale"] = scale
        }
        return ["join": join, "window": window.windowNumber, "pid": ProcessInfo.processInfo.processIdentifier,
                "width": Int(window.frame.width * scale), "height": Int(window.frame.height * scale), "spots": spots]
    }

    var shotState: [String: Any] {
        guard let window = shotWindow else { return [:] }
        return ["active": NSApp.isActive, "key": window.isKeyWindow,
                "frontApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
                "front": NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier]
    }

    func take(then: @escaping (Data?) -> Void) {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard Store.testing, let window = shotWindow, let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else {
            then(nil)
            return
        }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let number = UInt32(window.windowNumber)
        DispatchQueue.global(qos: .userInitiated).async {
            let image = capture(.null, 1 << 3, number, 1 | 8)?.takeRetainedValue()
            let png = image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            DispatchQueue.main.async { then(png) }
        }
    }

    func render(dark: Bool) -> Data? {
        guard Store.testing, !alerts.due.isEmpty else { return nil }
        let view = MeetingAlertShotView(due: alerts.due, alerts: alerts, dark: dark, drawn: true)
        let size = view.frame.size
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private var focusWas: (() -> Bool)?

    private func pose(_ key: MeetingJoinButton, _ pose: String, in window: NSWindow) {
        switch pose {
        case "hover":
            key.benchPillHover(true)
        case "press":
            let middle = key.convert(NSPoint(x: key.bounds.midX, y: key.bounds.midY), to: nil)
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: middle, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(down)
            }
        case "focus":
            focusWas = KitFocus.keyboardAccess
            KitFocus.keyboardAccess = { true }
            window.makeFirstResponder(key)
            key.needsDisplay = true
        default:
            break
        }
    }

    private static func srgb(_ color: CGColor?) -> [Int] {
        guard let color, let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let made = color.converted(to: sRGB, intent: .defaultIntent, options: nil), let parts = made.components, parts.count >= 3 else { return [] }
        return parts.prefix(4).map { Int(($0 * 255).rounded()) }
    }

    private static func layerLines(_ layer: CALayer, depth: Int = 0) -> [String] {
        let colour = srgb(layer.backgroundColor)
        let line = String(repeating: "  ", count: depth) + "\(type(of: layer)) \(layer.name ?? "")"
            + " frame=\(layer.frame.integral) radius=\(layer.cornerRadius) clips=\(layer.masksToBounds) bg=\(colour)"
            + " border=\(layer.borderWidth) shadow=\(layer.shadowOpacity) hidden=\(layer.isHidden) opacity=\(layer.opacity)"
            + " mask=\(layer.mask != nil) filters=\(layer.filters?.count ?? 0) bgFilters=\(layer.backgroundFilters?.count ?? 0)"
            + " contents=\(layer.contents != nil) delegate=\(layer.delegate.map { "\(type(of: $0))" } ?? "-")"
        return [line] + (layer.sublayers ?? []).flatMap { layerLines($0, depth: depth + 1) }
    }

    private static func viewLines(_ view: NSView, depth: Int = 0) -> [String] {
        let radius = (view as? NSGlassEffectView).map { " glassRadius=\($0.cornerRadius) tint=\(srgb($0.tintColor?.cgColor))" } ?? ""
        let line = String(repeating: "  ", count: depth) + "\(type(of: view)) frame=\(view.frame)\(radius) hidden=\(view.isHidden)"
        return [line] + view.subviews.flatMap { viewLines($0, depth: depth + 1) }
    }

    func endShot() {
        if let focusWas {
            KitFocus.keyboardAccess = focusWas
            self.focusWas = nil
        }
        guard let window = shotWindow else { return }
        window.orderOut(nil)
        Bench.frontAsked = false
        NSApp.hide(nil)
        given?.activate()
        given = nil
        window.contentView = nil
        window.close()
        shotWindow = nil
        for (other, frame) in parked {
            other.setFrame(frame, display: false)
            if other === panel { other.orderFrontRegardless() }
        }
        parked = []
        Bench.pagesShown = pagesShown
    }

    class Lifted: KitLitPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    final class Keyed: Lifted {
        override var canBecomeKey: Bool { true }
    }
}

@MainActor
final class MeetingAlertStackView: NSView {
    private unowned let alerts: MeetingAlerts
    let drawn: Bool
    private(set) var cards: [MeetingAlertCardView] = []

    var due: [Meeting] = [] {
        didSet {
            guard due != oldValue else { return }
            let wanted = Array(due.prefix(3))
            var kept: [MeetingAlertCardView] = []
            for meeting in wanted {
                if let card = cards.first(where: { $0.meeting.alertKey == meeting.alertKey }) {
                    card.meeting = meeting
                    kept.append(card)
                } else {
                    let card = MeetingAlertCardView(meeting: meeting, alerts: alerts, drawn: drawn)
                    addSubview(card)
                    kept.append(card)
                }
            }
            for card in cards where !kept.contains(where: { $0 === card }) { card.removeFromSuperview() }
            cards = kept
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(alerts: MeetingAlerts, drawn: Bool = false) {
        self.alerts = alerts
        self.drawn = drawn
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let heights = cards.map { $0.intrinsicContentSize.height }
        let inner = heights.reduce(0, +) + 10 * CGFloat(max(0, heights.count - 1))
        return NSSize(width: MeetingAlertPanel.width + MeetingAlertPanel.bleed * 2, height: inner + MeetingAlertPanel.bleed * 2)
    }

    override func layout() {
        super.layout()
        var y = MeetingAlertPanel.bleed
        for card in cards {
            let height = card.intrinsicContentSize.height
            card.frame = NSRect(x: MeetingAlertPanel.bleed, y: y, width: MeetingAlertPanel.width, height: height)
            y += height + 10
        }
    }

}

@MainActor
final class MeetingAlertShotView: NSView {
    private(set) var swatches: [(String, NSView)] = []

    init(due: [Meeting], alerts: MeetingAlerts, dark: Bool, drawn: Bool, controls: Bool = false, ground named: String? = nil) {
        let stack = MeetingAlertStackView(alerts: alerts, drawn: drawn)
        stack.due = due
        let size = stack.intrinsicContentSize
        let width = size.width + 8 + 120
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: size.height + 8))
        appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let ground = KitBox(fill: nil)
        switch named {
        case "white": ground.fill = .white
        case "black": ground.fill = .black
        case "clear": break
        default:
            ground.gradient = dark ? [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.20, alpha: 1), NSColor(srgbRed: 0.22, green: 0.16, blue: 0.30, alpha: 1)]
                : [NSColor(srgbRed: 0.78, green: 0.86, blue: 0.96, alpha: 1), NSColor(srgbRed: 0.95, green: 0.86, blue: 0.82, alpha: 1)]
            ground.gradientAxis = (CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1))
        }
        ground.frame = bounds
        addSubview(ground)
        stack.frame = NSRect(x: width - 8 - size.width, y: 8, width: size.width, height: size.height)
        addSubview(stack)
        guard controls else { return }
        let green = NSColor.systemGreen.withAlphaComponent(0.8)
        let late = KitGlass(interactive: true)
        let made: [(String, NSView)] = [
            ("glass interactive", KitGlass(tint: green, interactive: true)),
            ("glass still", KitGlass(tint: green, interactive: false)),
            ("glass tinted late", late),
            ("fill", KitBox(fill: green, corners: .capsule)),
        ]
        for (index, (_, swatch)) in made.enumerated() {
            (swatch as? KitGlass)?.capsule = true
            swatch.frame = NSRect(x: 18, y: 24 + CGFloat(index) * 40, width: 84, height: 28)
            addSubview(swatch)
        }
        swatches = made
        DispatchQueue.main.async { late.tintColor = green }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}

@MainActor
final class MeetingAlertCardView: NSView {
    static let inset: CGFloat = 14
    static let keyHeight: CGFloat = 32
    private static let stageFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private static let spanFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    private unowned let alerts: MeetingAlerts
    let drawn: Bool
    var meeting: Meeting { didSet { if meeting != oldValue { rebuild() } } }

    private let shade = NSView()
    private let ground: NSView
    private let inside = KitBox(fill: nil)
    private let badge = MeetingServiceBadge()
    private let title = NSTextField(wrappingLabelWithString: "")
    private let when = KitLabel("", font: MeetingAlertCardView.spanFont, color: KitColor.muted)
    private let place = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let dismiss: NSView
    private var faces: MeetingFacesView?
    private var invited: MeetingInvitedView?
    private var join: MeetingJoinButton?
    private var respond: NSView?
    private let snooze: NSView
    private var ticker: Timer?

    init(meeting: Meeting, alerts: MeetingAlerts, drawn: Bool) {
        self.meeting = meeting
        self.alerts = alerts
        self.drawn = drawn
        if drawn {
            let box = KitBox(fill: Palette.NS.glassTint, stroke: Palette.NS.cardEdge, corners: .radius(24))
            ground = box
        } else {
            ground = KitGlass.floating(radius: 24, ground: false)
        }
        dismiss = Self.key(symbol: "xmark", drawn: drawn, label: "Dismiss") {}
        snooze = Self.key(title: "Snooze", drawn: drawn) {}
        super.init(frame: .zero)
        wantsLayer = true
        shade.wantsLayer = true
        addSubview(shade)
        addSubview(ground)
        if let glass = ground as? KitGlass { glass.hold(inside) } else { addSubview(inside) }
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = Palette.NS.ink
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.cell?.truncatesLastVisibleLine = true
        place.overflow = .tail
        when.overflow = .tail
        for view in [badge, title, when, place, dismiss, snooze] { inside.addSubview(view) }
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ticker?.invalidate()
            ticker = nil
        } else {
            tick()
        }
    }

    private var event: CalendarEvent { meeting.event }

    private static func key(title: String? = nil, symbol: String? = nil, drawn: Bool, label: String? = nil, action: @escaping () -> Void) -> NSView {
        if drawn { return MeetingDrawnKey(title: title, symbol: symbol, label: label, action: action) }
        if let symbol { return KitGlassKey(symbol: symbol, circle: 24, symbolSize: 10, weight: .semibold, quiet: true, label: label, action: action) }
        return KitGlassKey(title: title ?? "", kind: .secondary, size: .regular, tall: keyHeight, action: action)
    }

    private func setAction(_ view: NSView?, _ action: @escaping () -> Void) {
        (view as? KitButton)?.action = action
    }

    private func name(_ view: NSView, _ title: String) {
        (view as? KitGlassKey)?.title = title
        (view as? MeetingDrawnKey)?.title = title
    }

    static func ink(_ stage: MeetingAlertRules.Stage) -> NSColor {
        switch stage {
        case .soon: KitColor.ink
        case .now: Palette.NS.glassSafe
        case .late: MeetingInvitedView.ink
        }
    }

    private func rebuild() {
        let meeting = meeting
        badge.show(meeting)
        title.stringValue = event.title
        place.text = placeText ?? ""
        place.isHidden = placeText == nil
        setAction(dismiss) { [weak alerts] in alerts?.dismiss(meeting) }
        dismiss.kitAccess(label: "Dismiss", help: "Dismiss")
        setAction(snooze) { [weak alerts] in alerts?.snooze(meeting) }
        faces?.removeFromSuperview()
        faces = nil
        invited?.removeFromSuperview()
        invited = nil
        if !event.people.isEmpty {
            let made = MeetingFacesView(people: event.people, pending: event.pending)
            inside.addSubview(made)
            faces = made
        } else if event.pending {
            let made = MeetingInvitedView()
            inside.addSubview(made)
            invited = made
        }
        join?.removeFromSuperview()
        join = nil
        if meeting.link != nil {
            let made = MeetingJoinButton(symbol: meeting.symbol + ".fill", drawn: drawn)
            made.action = { [weak alerts] in alerts?.join(meeting) }
            made.kitAccess(label: "Join", help: meeting.service.map { "Join with \($0.rawValue)" } ?? "Join")
            inside.addSubview(made)
            join = made
        }
        respond?.removeFromSuperview()
        respond = nil
        if event.pending, MeetingAlertRules.reply(for: event) != nil {
            let made = Self.key(title: "Respond", drawn: drawn) { [weak alerts] in alerts?.respond(meeting) }
            made.kitAccess(help: "Accept or decline where the invitation lives")
            inside.addSubview(made)
            respond = made
        }
        tick()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func tick() {
        ticker?.invalidate()
        ticker = nil
        let now = alerts.clock()
        let stage = MeetingAlertRules.stage(event, at: now)
        when.runs = [KitLabel.Run(text: stage.said, font: Self.stageFont, color: Self.ink(stage)),
                     KitLabel.Run(text: " · \(MeetingAlertRules.span(event))", font: Self.spanFont)]
        name(snooze, MeetingAlertRules.snoozeTitle(event, at: now))
        snooze.kitAccess(help: event.start.timeIntervalSince(now) > 30 ? "Again when it starts" : "Again in 2 minutes")
        needsLayout = true
        guard window != nil, let next = MeetingAlertRules.changes(event).first(where: { $0 > now }) else { return }
        let wait = next.timeIntervalSince(now)
        let timer = Timer(fire: Date().addingTimeInterval(wait), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private var placeText: String? {
        let location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
        return location.isEmpty || location.contains("://") ? nil : location
    }

    private static let inner = MeetingAlertPanel.width - inset * 2
    private static let lead: CGFloat = 26
    private static let text = lead + 10
    private static let column = inner - text - 8 - 24

    private struct Places {
        var height: CGFloat = 0
        var badge = NSRect.zero
        var title = NSRect.zero
        var when = NSRect.zero
        var place = NSRect.zero
        var dismiss = NSRect.zero
        var extra = NSRect.zero
        var keys: [(NSView, NSRect)] = []
    }

    private func places() -> Places {
        var out = Places()
        let inner = Self.inner
        let wide = inner - Self.text
        let titleHeight = ceil(title.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: Self.column + 4, height: 1000)).height ?? 18)
        let whenSize = when.intrinsicContentSize
        let placeSize = place.intrinsicContentSize
        var y: CGFloat = 0
        out.title = NSRect(x: Self.text - 2, y: y, width: Self.column + 4, height: titleHeight)
        y += titleHeight + 3
        out.when = NSRect(x: Self.text, y: y, width: min(wide, whenSize.width), height: whenSize.height)
        y += whenSize.height
        if !place.isHidden {
            y += 3
            out.place = NSRect(x: Self.text, y: y, width: min(wide, placeSize.width), height: placeSize.height)
            y += placeSize.height
        }
        let cap = (title.font?.ascender ?? 0) - (title.font?.capHeight ?? 0)
        let last = place.isHidden ? (when, out.when) : (place, out.place)
        let base = last.1.minY + (last.1.height - last.0.measure(width: .greatestFiniteMagnitude).height) / 2 + last.0.font.ascender
        out.badge = NSRect(x: 0, y: cap, width: Self.lead, height: base - cap)
        out.dismiss = NSRect(x: inner - 24, y: -3, width: 24, height: 24)
        var top = y
        if let faces {
            top += 12
            out.extra = NSRect(x: 0, y: top, width: inner, height: faces.intrinsicContentSize.height)
            top += out.extra.height
        } else if let invited {
            top += 12
            let size = invited.intrinsicContentSize
            out.extra = NSRect(x: 0, y: top, width: size.width, height: size.height)
            top += size.height
        }
        top += 12
        let fixed = [respond, snooze].compactMap { $0 }
        let sizes = fixed.map(\.intrinsicContentSize)
        let rowHeight = Self.keyHeight
        var x: CGFloat = 0
        if join != nil {
            let width = inner - sizes.map(\.width).reduce(0, +) - 8 * CGFloat(sizes.count)
            if let join { out.keys.append((join, NSRect(x: 0, y: top, width: width, height: rowHeight))) }
            x = width + 8
        }
        for (view, size) in zip(fixed, sizes) {
            out.keys.append((view, NSRect(x: x, y: top + (rowHeight - size.height) / 2, width: size.width, height: size.height)))
            x += size.width + 8
        }
        out.height = Self.inset + top + rowHeight + Self.inset
        return out
    }

    override var intrinsicContentSize: NSSize { NSSize(width: MeetingAlertPanel.width, height: places().height) }

    override func layout() {
        super.layout()
        let places = places()
        ground.frame = bounds
        inside.frame = ground is KitGlass ? ground.bounds : bounds
        let origin = CGPoint(x: Self.inset, y: Self.inset)
        func moved(_ rect: NSRect) -> NSRect { kitSnap(rect.offsetBy(dx: origin.x, dy: origin.y)) }
        badge.frame = moved(places.badge)
        title.frame = moved(places.title)
        when.frame = moved(places.when)
        place.frame = moved(places.place)
        dismiss.frame = moved(places.dismiss)
        if let faces { faces.frame = moved(places.extra) }
        if let invited { invited.frame = moved(places.extra) }
        for (view, rect) in places.keys { view.frame = moved(rect) }
        shade.frame = bounds
        if let layer = shade.layer {
            layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 24, cornerHeight: 24, transform: nil)
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.18
            layer.shadowRadius = 12
            layer.shadowOffset = CGSize(width: 0, height: -4)
            layer.masksToBounds = false
        }
    }
}

@MainActor
private final class MeetingDrawnKey: KitButton {
    private let ground = KitBox(fill: Palette.NS.ink.withAlphaComponent(0.08), stroke: Palette.NS.cardEdge, corners: .capsule)
    private let circle: Bool

    var title: String {
        get { (content as? KitLabel)?.text ?? "" }
        set {
            guard let label = content as? KitLabel, label.text != newValue else { return }
            label.text = newValue
            setAccessibilityLabel(newValue)
            invalidateIntrinsicContentSize()
        }
    }

    init(title: String?, symbol: String?, label: String?, action: @escaping () -> Void) {
        circle = symbol != nil
        super.init(.plain(press: 1), label: label ?? title, action: action)
        addSubview(ground, positioned: .below, relativeTo: nil)
        if let symbol {
            content = KitSymbol(symbol, style: KitSymbol.Style(size: 10, weight: .semibold))
        } else {
            content = KitLabel(title ?? "", font: .systemFont(ofSize: 13))
            padding = 12
        }
        height = circle ? 24 : MeetingAlertCardView.keyHeight
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        circle ? NSSize(width: 24, height: 24) : super.intrinsicContentSize
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
    }
}

@MainActor
final class MeetingJoinButton: KitButton {
    private let glass: NSView
    let face = KitBox(fill: nil, corners: .capsule)

    init(symbol: String, drawn: Bool) {
        if drawn {
            glass = face
        } else {
            let made = KitGlass(interactive: true)
            made.capsule = true
            face.autoresizingMask = [.width, .height]
            made.kitCatch.addSubview(face)
            glass = made
        }
        super.init(.plain(press: 0.97), label: "Join")
        addSubview(glass, positioned: .below, relativeTo: nil)
        pressGlass = glass as? NSGlassEffectView
        content = MeetingJoinWords(symbol: symbol)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func fill(dark: Bool, raised: Bool = false, lit: Bool = false, pressed: Bool = false) -> NSColor {
        let base = raised ? NSColor(srgbRed: 0.094, green: 0.431, blue: 0.18, alpha: 1)
            : dark ? NSColor(srgbRed: 0.13, green: 0.6, blue: 0.27, alpha: 1) : NSColor(srgbRed: 0.106, green: 0.553, blue: 0.231, alpha: 1)
        if pressed { return base.blended(withFraction: 0.18, of: .black) ?? base }
        if lit { return base.blended(withFraction: 0.1, of: .white) ?? base }
        return base
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        if face !== glass {
            face.superview?.frame = glass.bounds
            face.frame = glass.bounds
        }
    }

    override func hoverChanged() {
        super.hoverChanged()
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        paint()
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        paint()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        paint()
    }

    func resolved(_ color: NSColor) -> CGColor {
        var out = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
        return out
    }

    private func paint() {
        face.fill = Self.fill(dark: kitDark, raised: Contrast.raised, lit: hovering && isEnabled, pressed: pressed)
    }
}

@MainActor
private final class MeetingJoinWords: NSView {
    private static let gap: CGFloat = 6
    private let mark: KitSymbol
    private let word = KitLabel("Join", font: .systemFont(ofSize: 13, weight: .semibold), color: .white)

    init(symbol: String) {
        mark = KitSymbol(symbol, style: KitSymbol.Style(size: 13, weight: .semibold), tint: .white)
        super.init(frame: .zero)
        addSubview(mark)
        addSubview(word)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var slot: CGFloat { ceil(mark.image?.size.width ?? 0) }

    override var intrinsicContentSize: NSSize {
        let text = word.intrinsicContentSize
        return NSSize(width: slot + Self.gap + text.width, height: max(ceil(mark.image?.size.height ?? 0), text.height))
    }

    override func layout() {
        super.layout()
        let text = word.intrinsicContentSize
        word.frame = kitSnap(NSRect(x: slot + Self.gap, y: (bounds.height - text.height) / 2, width: text.width, height: text.height))
        let font = word.font
        let line = word.measure(width: .greatestFiniteMagnitude).height
        let cap = word.frame.minY + (word.frame.height - line) / 2 + font.ascender - font.capHeight / 2
        mark.centreInk(in: NSRect(x: 0, y: cap - bounds.height / 2, width: slot, height: bounds.height))
    }
}

@MainActor
private final class MeetingServiceBadge: NSView {
    private let mark = KitSymbol("calendar", style: KitSymbol.Style(size: 20, weight: IconLook.weight), tint: KitColor.muted)

    init() {
        super.init(frame: .zero)
        addSubview(mark)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ meeting: Meeting) {
        mark.name = meeting.symbol
        toolTip = meeting.service?.rawValue
        needsLayout = true
    }

    override func layout() {
        super.layout()
        mark.centreInk(in: bounds)
    }
}

@MainActor
private final class MeetingFacesView: NSView {
    private static let step: CGFloat = 22
    private var circles: [MeetingFaceView] = []
    private let names: [String]
    private let summary: KitLabel
    private let invited: MeetingInvitedView?

    init(people: [MeetingPerson], pending: Bool) {
        names = people.map(MeetingGuests.name)
        summary = KitLabel(MeetingGuests.line(names), font: .systemFont(ofSize: 12), color: KitColor.muted)
        invited = pending ? MeetingInvitedView() : nil
        super.init(frame: .zero)
        for person in people.prefix(5) {
            let face = MeetingFaceView(person: person)
            let letters = KitLabel(MeetingAlertRules.initials(person), font: .systemFont(ofSize: 10, weight: .semibold), color: .white)
            letters.alignment = .center
            face.addSubview(letters)
            face.toolTip = person.name.isEmpty ? person.email : person.name
            face.passesClicks = false
            addSubview(face)
            circles.append(face)
            face.show(MeetingFaces.shared.face(for: person) { [weak face] image in face?.show(image, fading: true) }, fading: false)
        }
        addSubview(summary)
        if let invited { addSubview(invited) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(26, summary.intrinsicContentSize.height, invited?.intrinsicContentSize.height ?? 0))
    }

    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        var x: CGFloat = 0
        for (index, face) in circles.enumerated() {
            face.frame = NSRect(x: x, y: middle - 13, width: 26, height: 26)
            let bitten = index + 1 < circles.count
            face.bite = bitten ? Self.step + 13 : nil
            if let letters = face.subviews.first {
                let size = letters.intrinsicContentSize
                letters.frame = face.kitSnap(NSRect(x: bitten ? -1 : 0, y: (26 - size.height) / 2, width: 26, height: size.height))
            }
            x += Self.step
        }
        x += 26 - Self.step + 8
        var right = bounds.width
        if let invited {
            let size = invited.intrinsicContentSize
            invited.frame = kitSnap(NSRect(x: right - size.width, y: middle - size.height / 2, width: size.width, height: size.height))
            right -= size.width + 8
        }
        summary.text = MeetingGuests.line(names, font: summary.font, width: max(0, right - x - 8))
        summary.setAccessibilityValue(MeetingGuests.line(names))
        let size = summary.intrinsicContentSize
        summary.frame = kitSnap(NSRect(x: x, y: middle - size.height / 2, width: max(0, min(size.width, right - x - 8)), height: size.height))
    }
}

@MainActor
final class MeetingFaceView: KitBox {
    private let photo = CALayer()
    private(set) var image: NSImage?
    var bite: CGFloat? { didSet { if bite != oldValue { needsLayout = true } } }

    init(person: MeetingPerson) {
        super.init(frame: .zero)
        let hue = MeetingAlertRules.hue(person)
        gradient = [NSColor(hue: hue, saturation: 0.44, brightness: 0.8, alpha: 1), NSColor(hue: hue, saturation: 0.6, brightness: 0.6, alpha: 1)]
        corners = .capsule
        photo.masksToBounds = true
        photo.contentsGravity = .resizeAspectFill
        photo.isHidden = true
        photo.zPosition = 1
        layer?.addSublayer(photo)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var showsPhoto: Bool { !photo.isHidden }

    func show(_ image: NSImage?, fading: Bool) {
        guard let image else { return }
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.contents = image
        photo.isHidden = false
        photo.opacity = 1
        CATransaction.commit()
        guard fading, window != nil, let fade = Motion.kitSettle.animation("opacity", from: 0, to: 1) else {
            for view in subviews { view.isHidden = true }
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.image === image else { return }
            for view in self.subviews { view.isHidden = true }
        }
        photo.add(fade, forKey: "faceArrive")
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        photo.frame = bounds
        photo.cornerRadius = bounds.height / 2
        photo.contentsScale = window?.backingScaleFactor ?? 2
        if let bite {
            let mask = (layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
            let reach = bounds.height / 2 + 1.5
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addEllipse(in: CGRect(x: bite - reach, y: bounds.midY - reach, width: reach * 2, height: reach * 2))
            mask.fillRule = .evenOdd
            mask.path = path
            mask.frame = bounds
            layer?.mask = mask
        } else {
            layer?.mask = nil
        }
        CATransaction.commit()
    }
}

@MainActor
private final class MeetingInvitedView: NSView {
    private let ground = KitBox(fill: NSColor.systemOrange.withAlphaComponent(0.15), corners: .capsule)
    static let ink = NSColor(name: nil) { look in
        look.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 1, green: 0.78, blue: 0.45, alpha: 1) : NSColor(srgbRed: 0x9A / 255.0, green: 0x4D / 255.0, blue: 0, alpha: 1)
    }
    private let word = KitLabel("Invited", font: .systemFont(ofSize: 11, weight: .medium), color: MeetingInvitedView.ink)

    init() {
        super.init(frame: .zero)
        addSubview(ground)
        addSubview(word)
        toolTip = "You haven't answered this invitation"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: word.intrinsicContentSize.width + 14, height: 18) }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let size = word.intrinsicContentSize
        word.frame = kitSnap(NSRect(x: 7, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
}

extension MeetingAlerts {
    static let surfaceNow = Date(timeIntervalSince1970: 1_793_000_000)

    static func surfaceMeetings(_ kind: String) -> [Meeting] {
        let now = surfaceNow
        let people = [MeetingPerson(name: "Dana Scully", email: "dana@example.test"), MeetingPerson(name: "Fox Mulder", email: "fox@example.test"),
                      MeetingPerson(name: "", email: "walter.skinner@example.test"), MeetingPerson(name: "Monica Reyes", email: "monica@example.test")]
        let sync = CalendarEvent(id: "sync", title: "Design sync with the whole platform team", start: now.addingTimeInterval(270), end: now.addingTimeInterval(2070),
                                 location: "Room 4", url: URL(string: "https://meet.google.com/abc-defg-hij"), people: people, pending: true,
                                 external: "sync-external")
        if kind == "long" {
            let crowd = people + [MeetingPerson(name: "Bartholomew Featherstonehaugh-Winterbourne", email: "bartholomew@example.test"),
                                  MeetingPerson(name: "Ines Okonkwo", email: "ines@example.test"),
                                  MeetingPerson(name: "Jun Castellanos", email: "jun@example.test"),
                                  MeetingPerson(name: "", email: "a.very.long.address.for.a.shared.mailbox@example.test")]
            let long = CalendarEvent(id: "long", title: "Quarterly planning review for every product area with the leadership team and the guests from finance and operations",
                                     start: now.addingTimeInterval(270), end: now.addingTimeInterval(2070),
                                     location: "Building 12, fourth floor, the large corner room beside the kitchen and the lifts",
                                     url: URL(string: "https://meet.google.com/abc-defg-hij"), people: Array(crowd.reversed()), pending: true,
                                     external: "long-external")
            return [Meeting(event: long)]
        }
        guard kind == "two" else { return [Meeting(event: sync)] }
        let zoom = CalendarEvent(id: "zoom", title: "Weekly check-in", start: now.addingTimeInterval(-90), end: now.addingTimeInterval(1710),
                                 notes: "https://zoom.us/j/123456789?pwd=abc")
        let plain = CalendarEvent(id: "plain", title: "Lunch", start: now.addingTimeInterval(30), end: now.addingTimeInterval(3630),
                                  location: "The canteen", people: [people[0]])
        return [Meeting(event: zoom), Meeting(event: plain)]
    }

    static func surfacePortrait(skin: NSColor, hair: NSColor, shirt: NSColor, ground: [NSColor]) -> NSImage {
        NSImage(size: NSSize(width: 96, height: 96), flipped: false) { rect in
            NSGradient(colors: ground)?.draw(in: rect, angle: 90)
            shirt.setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: -34, width: 68, height: 62)).fill()
            skin.setFill()
            NSBezierPath(rect: NSRect(x: 40, y: 22, width: 16, height: 14)).fill()
            NSBezierPath(ovalIn: NSRect(x: 29, y: 30, width: 38, height: 46)).fill()
            hair.setFill()
            let top = NSBezierPath()
            top.appendArc(withCenter: NSPoint(x: 48, y: 58), radius: 21, startAngle: 10, endAngle: 170)
            top.close()
            top.fill()
            return true
        }
    }

    static func surfaceFaces() {
        let faces = MeetingFaces.shared
        faces.forget()
        faces.sources = [FixedFaces([:])]
        faces.seed("dana@example.test", surfacePortrait(skin: NSColor(red: 0.96, green: 0.8, blue: 0.69, alpha: 1),
                                                        hair: NSColor(red: 0.62, green: 0.26, blue: 0.12, alpha: 1),
                                                        shirt: NSColor(red: 0.2, green: 0.29, blue: 0.45, alpha: 1),
                                                        ground: [NSColor(red: 0.78, green: 0.86, blue: 0.93, alpha: 1), NSColor(red: 0.6, green: 0.72, blue: 0.84, alpha: 1)]))
        faces.seed("monica@example.test", surfacePortrait(skin: NSColor(red: 0.78, green: 0.58, blue: 0.43, alpha: 1),
                                                          hair: NSColor(red: 0.16, green: 0.12, blue: 0.1, alpha: 1),
                                                          shirt: NSColor(red: 0.55, green: 0.18, blue: 0.22, alpha: 1),
                                                          ground: [NSColor(red: 0.93, green: 0.88, blue: 0.78, alpha: 1), NSColor(red: 0.82, green: 0.74, blue: 0.6, alpha: 1)]))
        faces.seed("fox@example.test", nil)
        faces.seed("walter.skinner@example.test", nil)
    }

    static func surface(_ kind: String) -> NSView {
        if kind == "faces" {
            surfaceFaces()
        } else {
            MeetingFaces.shared.forget()
            MeetingFaces.shared.sources = []
        }
        let alerts = MeetingAlerts(meetings: .shared, prefs: .shared)
        alerts.clock = { surfaceNow }
        let stack = MeetingAlertStackView(alerts: alerts)
        stack.due = surfaceMeetings(kind)
        stack.frame = NSRect(origin: .zero, size: stack.intrinsicContentSize)
        return KitFixedView(stack, keep: alerts)
    }
}

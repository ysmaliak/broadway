import AppKit
import Combine
import EventKit
import Observation

struct MeetingPerson: Equatable, Sendable {
    let name: String
    let email: String
}

struct CalendarEvent: Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    var allDay = false
    var declined = false
    var location = ""
    var notes = ""
    var url: URL?
    var people: [MeetingPerson] = []
    var pending = false
    var calendar = ""
    var external = ""
    var account = ""
    var source = ""
    var sourceTitle = ""
}

struct MeetingCalendar: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    var account = ""
    var source = ""
}

protocol CalendarSource: Sendable {
    var hasAccess: Bool { get }
    func requestAccess() async -> Bool
    func events(from start: Date, to end: Date) -> [CalendarEvent]
    func calendars() -> [MeetingCalendar]
}

extension CalendarSource {
    func calendars() -> [MeetingCalendar] { [] }
}

final class MacCalendars: CalendarSource, @unchecked Sendable {
    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "search.calendars", qos: .utility)

    var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        queue.sync {
            let found = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            return found.map { event in
                let people = (event.attendees ?? []).filter { !$0.isCurrentUser }.map { person in
                    let address = person.url.absoluteString
                    return MeetingPerson(name: person.name ?? "",
                                         email: address.hasPrefix("mailto:") ? String(address.dropFirst(7)) : "")
                }
                let mine = event.attendees?.first(where: \.isCurrentUser)
                let account = [mine?.url.absoluteString ?? "", event.calendar?.source?.title ?? "", event.calendar?.title ?? ""]
                    .map { $0.hasPrefix("mailto:") ? String($0.dropFirst(7)) : $0 }
                    .first { $0.contains("@") } ?? ""
                return CalendarEvent(id: event.calendarItemIdentifier, title: event.title ?? "Meeting",
                                     start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                                     declined: mine?.participantStatus == .declined,
                                     location: event.location ?? "", notes: event.notes ?? "", url: event.url,
                                     people: people, pending: mine?.participantStatus == .pending,
                                     calendar: event.calendar?.calendarIdentifier ?? "",
                                     external: event.calendarItemExternalIdentifier ?? "", account: account.lowercased(),
                                     source: event.calendar?.source?.sourceIdentifier ?? "", sourceTitle: event.calendar?.source?.title ?? "")
            }
        }
    }

    func calendars() -> [MeetingCalendar] {
        queue.sync {
            store.calendars(for: .event)
                .map { MeetingCalendar(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "",
                                       source: $0.source?.sourceIdentifier ?? "") }
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
        }
    }
}

enum MeetingLink {
    enum Service: String, Sendable, CaseIterable {
        case meet = "Google Meet", zoom = "Zoom", teams = "Microsoft Teams", slack = "Slack huddle", webex = "Webex"
        case around = "Around", facetime = "FaceTime"

        var name: String {
            switch self {
            case .meet: "meet"
            case .zoom: "zoom"
            case .teams: "teams"
            case .slack: "slack"
            case .webex: "webex"
            case .around: "around"
            case .facetime: "facetime"
            }
        }
    }

    nonisolated(unsafe) static var testHosts: [String: Service] = [:]

    static func service(of url: URL) -> Service? {
        guard let host = url.host()?.lowercased() else { return nil }
        let path = url.path().lowercased()
        func on(_ name: String) -> Bool { host == name || host.hasSuffix("." + name) }
        if on("meet.google.com"), path.count > 1 { return .meet }
        if on("zoom.us") || on("zoomgov.com"),
           path.hasPrefix("/j/") || path.hasPrefix("/my/") || path.hasPrefix("/wc/") || path.hasPrefix("/w/") { return .zoom }
        if on("teams.microsoft.com") || on("teams.live.com"), path.contains("meet") { return .teams }
        if on("slack.com"), path.contains("huddle") { return .slack }
        if on("webex.com"), path.hasPrefix("/meet/") || path.hasPrefix("/join/") || path.contains("/j.php") || path.contains("/wbxmjs/") { return .webex }
        if on("around.co"), path.hasPrefix("/r/") || (host != "around.co" && host != "www.around.co" && path.count > 1) { return .around }
        if host == "facetime.apple.com", path.hasPrefix("/join") { return .facetime }
        if Store.testing, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), path.count > 1 {
            return testHosts[host]
        }
        return nil
    }

    static func find(in texts: [String]) -> (url: URL, service: Service)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      let service = service(of: url)
                else { continue }
                return (url, service)
            }
        }
        return nil
    }

    static func identifier(of url: URL) -> String {
        let path = url.path().lowercased()
        if service(of: url) == .zoom { return path.filter(\.isNumber) }
        if service(of: url) == .meet { return url.lastPathComponent.lowercased() }
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func same(_ one: URL, _ other: URL) -> Bool {
        guard let service = service(of: one), service == self.service(of: other) else { return false }
        return identifier(of: one) == identifier(of: other)
    }
}

struct Meeting: Equatable, Sendable {
    let event: CalendarEvent
    let link: URL?
    let service: MeetingLink.Service?

    init(event: CalendarEvent) {
        self.event = event
        let found = MeetingLink.find(in: [event.url?.absoluteString ?? "", event.location, event.notes])
        link = found?.url
        service = found?.service
    }

    var symbol: String {
        switch service {
        case .slack: "headphones"
        case nil: link == nil ? "calendar" : "phone"
        default: "video"
        }
    }

    func joinable(at now: Date) -> Bool {
        link != nil && event.end > now && event.start.timeIntervalSince(now) <= 15 * 60
    }

    enum PinLabel: Equatable {
        case join
        case countdown(String)
        case started(minutes: Int)

        var text: String {
            switch self {
            case .join: "Join"
            case .countdown(let text): text
            case .started(let minutes) where minutes < 1: "Now"
            case .started(let minutes) where minutes < 60: "\(minutes)m ago"
            case .started(let minutes): "\(minutes / 60)h ago"
            }
        }

        func said(title: String) -> String {
            switch self {
            case .join: "Join"
            case .countdown(let text): text
            case .started(let minutes) where minutes < 1: "Starting now, \(title)"
            case .started(let minutes) where minutes < 60: "Started \(Self.count(minutes, "minute")) ago, \(title)"
            case .started(let minutes): "Started \(Self.count(minutes / 60, "hour")) ago, \(title)"
            }
        }

        private static func count(_ number: Int, _ unit: String) -> String {
            "\(number) \(unit)\(number == 1 ? "" : "s")"
        }
    }

    func pinLabel(at now: Date, onCall: Bool = false) -> PinLabel? {
        let wait = event.start.timeIntervalSince(now)
        guard event.end > now else { return nil }
        if wait <= 60 {
            if link != nil, !onCall { return .join }
            return .started(minutes: max(0, Int((-wait / 60).rounded(.down))))
        }
        guard wait <= 30 * 60 else { return nil }
        return .countdown("\(Int((wait / 60).rounded(.up)))m")
    }

    func minutesLeft(at now: Date) -> Int? {
        let left = event.end.timeIntervalSince(now)
        guard left > 0, left <= 5 * 60, event.start <= now else { return nil }
        return Int((left / 60).rounded(.up))
    }

    func said(at now: Date) -> String {
        let wait = event.start.timeIntervalSince(now)
        if wait <= 0 { return "Now" }
        return "In \(max(1, Int((wait / 60).rounded(.up)))) min"
    }
}

@MainActor
@Observable
final class Meetings {
    static let shared: Meetings = {
        let made = Meetings(source: Store.testing ? nil : MacCalendars())
        if Shared.prefs.nextMeeting { made.start() }
        return made
    }()

    private(set) var next: Meeting?
    private(set) var clock = Date()
    private(set) var calendarList: [MeetingCalendar] = []
    @ObservationIgnored private(set) var known: [Meeting] = []

    @ObservationIgnored private var source: CalendarSource?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watcher: NSObjectProtocol?
    @ObservationIgnored private var ticks = 0

    init(source: CalendarSource?) {
        self.source = source
    }

    func use(_ source: CalendarSource?) {
        self.source = source
        known = []
        calendarList = []
        MeetingAlerts.shared.sync()
    }

    var hasAccess: Bool { source?.hasAccess ?? false }

    func calendars() async -> [MeetingCalendar] {
        guard let source, source.hasAccess else { return [] }
        return await Task.detached(priority: .utility) { source.calendars() }.value
    }

    func readCalendars() async {
        let found = await calendars()
        if found != calendarList { calendarList = found }
    }

    static func pick(_ events: [CalendarEvent], at now: Date) -> Meeting? {
        let ahead = events
            .filter { !$0.allDay && !$0.declined && $0.end > now }
            .sorted { $0.start < $1.start }
            .map(Meeting.init(event:))
        let joinable = ahead.first { $0.joinable(at: now) }
        return joinable ?? ahead.first
    }

    func refresh(at now: Date = Date()) async {
        guard let source, source.hasAccess else {
            clock = now
            if next != nil { next = nil }
            known = []
            return
        }
        let found = await Task.detached(priority: .utility) {
            source.events(from: now.addingTimeInterval(-12 * 3600), to: now.addingTimeInterval(36 * 3600))
        }.value
        clock = now
        known = found.filter { !$0.declined }.map(Meeting.init(event:)).filter { $0.link != nil }
        let picked = Self.pick(found, at: now)
        if picked != next { next = picked }
    }

    func events(from start: Date, to end: Date) async -> [CalendarEvent] {
        guard let source, source.hasAccess else { return [] }
        return await Task.detached(priority: .utility) { source.events(from: start, to: end) }.value
    }

    func start() {
        guard timer == nil else { return }
        watcher = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refresh() }
            }
        }
        let tick = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick.tolerance = 5
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        Task { await refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let watcher { NotificationCenter.default.removeObserver(watcher) }
        watcher = nil
        next = nil
    }

    private func tick() {
        ticks += 1
        if ticks % 4 == 0 {
            Task { await refresh() }
        } else {
            clock = Date()
        }
    }

    func turnOn() async -> Bool {
        guard let source else { return false }
        let granted = source.hasAccess ? true : await source.requestAccess()
        Shared.prefs.nextMeeting = granted
        if granted { start() }
        MeetingAlerts.shared.sync()
        return granted
    }

    func turnOff() {
        Shared.prefs.nextMeeting = false
        stop()
    }

    func minutesLeft(on address: URL) -> Int? {
        guard let meeting = next, let link = meeting.link, MeetingLink.same(address, link) else { return nil }
        return meeting.minutesLeft(at: clock)
    }

    static func tabs(with people: [MeetingPerson], among tabs: [(id: UUID, title: String, url: String)]) -> [UUID] {
        let names = people.map { $0.name.lowercased() }.filter { $0.count >= 4 }
        let emails = people.map { $0.email.lowercased() }.filter { !$0.isEmpty }
        return tabs.filter { tab in
            let title = tab.title.lowercased()
            let url = tab.url.lowercased()
            return names.contains { title.contains($0) } || emails.contains { title.contains($0) || url.contains($0) }
        }
        .map(\.id)
    }

    nonisolated(unsafe) static var testCalendars: Set<String> = []

    static func isCalendar(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased() else { return false }
        if Store.testing, testCalendars.contains(host) { return true }
        let bare = PageIndex.bare(host)
        if ["calendar.google.com", "calendar.notion.so", "cal.com", "app.cal.com", "app.reclaim.ai", "fantastical.app",
            "web.flexibits.com", "calendar.yahoo.com"].contains(bare) { return true }
        if bare == "outlook.office.com" || bare == "outlook.live.com" || bare == "outlook.office365.com" {
            return url.path().hasPrefix("/calendar")
        }
        return false
    }
}

extension Browser {
    func joinNextMeeting(using meetings: Meetings = .shared, at now: Date = Date()) {
        guard let meeting = meetings.next, meeting.joinable(at: now), let link = meeting.link else {
            announce("No meeting to join in the next 15 minutes")
            return
        }
        joinMeeting(link, event: meeting.event)
    }

    func tab(on link: URL) -> Tab? {
        tabs.first { $0.address.map { MeetingLink.same($0, link) } == true }
    }

    func pinLabel(for meeting: Meeting?, at now: Date) -> Meeting.PinLabel? {
        guard let meeting, let label = meeting.pinLabel(at: now) else { return nil }
        guard label == .join, let link = meeting.link, tab(on: link) != nil else { return label }
        return meeting.pinLabel(at: now, onCall: true)
    }

    func openWithMeetingPeople(using meetings: Meetings = .shared) {
        guard let meeting = meetings.next else {
            announce("No meeting coming up")
            return
        }
        let open = tabs.filter { !$0.shy && !$0.isBlank }.map { (id: $0.id, title: $0.label, url: $0.address?.absoluteString ?? "") }
        guard let id = Meetings.tabs(with: meeting.event.people, among: open).first,
              let tab = tabs.first(where: { $0.id == id })
        else {
            announce("Nothing open with people from \(meeting.event.title)")
            return
        }
        select(tab)
    }
}

enum PinMeetingPlaces {
    static let capsule: CGFloat = 14
    static let gap: CGFloat = 2
    static let narrowest: CGFloat = 36
    static let joinSide: CGFloat = 6
    static let side: CGFloat = 5
    static let tightest: CGFloat = 3
    static var font: NSFont { .systemFont(ofSize: 9, weight: .semibold, width: .condensed) }

    static func padding(word: CGFloat, tile: CGFloat) -> CGFloat {
        min(side, max(tightest, ((tile - word) / 2).rounded(.down)))
    }

    static func margin(in height: CGFloat) -> CGFloat {
        max(0, (height - PinPlaces.mark - gap - capsule) / 2)
    }

    static func lift(in height: CGFloat) -> CGFloat {
        (height - PinPlaces.mark) / 2 - margin(in: height)
    }
}

@MainActor
final class PinMeetingBadgeView: KitButton {
    weak var browser: Browser?
    private let ground = KitBox(fill: nil, corners: .capsule)
    private let word = KitLabel("", font: PinMeetingPlaces.font, color: .white)
    private var label: Meeting.PinLabel = .join
    var tile: CGFloat = .greatestFiniteMagnitude { didSet { if tile != oldValue { pad() } } }

    init(browser: Browser?) {
        self.browser = browser
        super.init(.plain(press: 1))
        addSubview(ground, positioned: .below, relativeTo: nil)
        word.setAccessibilityElement(false)
        content = word
        action = { [weak self] in self?.browser?.joinNextMeeting() }
        show(.join, title: "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ label: Meeting.PinLabel, title: String) {
        self.label = label
        switch label {
        case .join:
            word.text = "Join"
            word.color = .white
            ground.fill = .systemGreen
            toolTip = title
            setAccessibilityElement(true)
            setAccessibilityRole(.button)
            setAccessibilityLabel("Join")
        case .countdown(let text):
            word.text = text
            word.color = KitColor.ink
            ground.fill = Palette.NS.wash
            toolTip = nil
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(text)
        case .started:
            word.text = label.text
            word.color = KitColor.ink
            ground.fill = Palette.NS.wash
            toolTip = nil
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(label.said(title: title))
        }
        pad()
        height = PinMeetingPlaces.capsule
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func pad() {
        let side = label == .join ? PinMeetingPlaces.joinSide
            : PinMeetingPlaces.padding(word: word.intrinsicContentSize.width, tile: tile)
        if padding != side { padding = side }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if label != .join { return nil }
        let hit = super.hitTest(point)
        return hit == nil ? nil : self
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
    }
}

@MainActor
final class CallMinutesView: NSView {
    private let word = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: KitColor.muted)
    var minutes = 0 {
        didSet {
            guard minutes != oldValue else { return }
            word.text = "\(minutes)m left"
            invalidateIntrinsicContentSize()
        }
    }

    init() {
        super.init(frame: .zero)
        addSubview(word)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { word.intrinsicContentSize }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        word.frame = bounds
    }
}

@MainActor
enum PinMeetingSurface {
    static func make() -> NSView {
        let browser = Browser(record: WindowRecord())
        let stage = KitBox(fill: nil)
        var x: CGFloat = 6
        for label in [Meeting.PinLabel.join, .countdown("12m"), .countdown("3m"), .started(minutes: 48)] {
            let badge = PinMeetingBadgeView(browser: browser)
            badge.show(label, title: "Design sync")
            let size = badge.intrinsicContentSize
            badge.frame = NSRect(x: x, y: 6, width: size.width, height: size.height)
            stage.addSubview(badge)
            x += size.width + 8
        }
        stage.frame = NSRect(x: 0, y: 0, width: x - 8 + 6, height: PinMeetingPlaces.capsule + 12)
        return KitFixedView(stage, keep: browser)
    }
}

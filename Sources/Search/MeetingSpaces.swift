import AppKit
import Observation

enum MeetingSpaceReason: String, Equatable {
    case tied, chosenCalendar, chosenAccount, account, link, calendar, current
}

enum MeetingCalendarPlace: Hashable {
    case account, any, space(UUID)
}

struct MeetingSpaceSignals: Equatable {
    var current: UUID
    var spaces: [UUID]
    var tied: UUID? = nil
    var chosenCalendar: MeetingCalendarPlace = .account
    var chosenAccount: UUID? = nil
    var account: [UUID] = []
    var link: UUID? = nil
    var calendar: UUID? = nil
}

struct MeetingAccount: Equatable, Hashable {
    let key: String
    let title: String
    var calendars: [MeetingCalendar]

    var name: String { title.isEmpty ? "Other" : title }

    static func grouped(_ calendars: [MeetingCalendar]) -> [MeetingAccount] {
        var out: [MeetingAccount] = []
        for calendar in calendars {
            let key = calendar.source.isEmpty ? "title:" + calendar.account : calendar.source
            if let at = out.firstIndex(where: { $0.key == key }) {
                out[at].calendars.append(calendar)
            } else {
                out.append(MeetingAccount(key: key, title: calendar.account, calendars: [calendar]))
            }
        }
        return out
    }
}

enum MeetingSpaceChoice {
    static func choose(_ signals: MeetingSpaceSignals) -> (space: UUID, reason: MeetingSpaceReason) {
        let known = Set(signals.spaces)
        if let tied = signals.tied, known.contains(tied) { return (tied, .tied) }
        switch signals.chosenCalendar {
        case .space(let id) where known.contains(id):
            return (id, .chosenCalendar)
        case .any:
            break
        default:
            if let chosen = signals.chosenAccount, known.contains(chosen) { return (chosen, .chosenAccount) }
        }
        let signed = Set(signals.account.filter(known.contains))
        if signed.count == 1, let only = signed.first { return (only, .account) }
        if let link = signals.link, known.contains(link) { return (link, .link) }
        if let calendar = signals.calendar, known.contains(calendar) { return (calendar, .calendar) }
        return (signals.current, .current)
    }

    static let accountSites: Set<String> = ["mail.google.com", "calendar.google.com", "meet.google.com"]

    private static let address = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#)

    static func address(in text: String) -> String? {
        guard let address, let match = address.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return text[range].lowercased()
    }

    static func account(inTitle title: String, at url: URL?) -> String? {
        guard let url, let host = url.host()?.lowercased(), accountSites.contains(host) else { return nil }
        let given = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "authuser" }?.value ?? ""
        if let found = address(in: given), found == given.lowercased() { return found }
        return address(in: title)
    }

    static func linkKey(_ url: URL) -> String? {
        guard let service = MeetingLink.service(of: url) else { return nil }
        let id = MeetingLink.identifier(of: url)
        return id.isEmpty ? nil : "\(service.name):\(id)"
    }
}

@MainActor
@Observable
final class MeetingSpacePlaces {
    static let shared = MeetingSpacePlaces(store: Store.settings)
    static let accountsKey = "meetings.accountPlaces"
    static let calendarsKey = "meetings.calendarPlaces"
    static let offeredKey = "meetings.offeredAccounts"
    static let anySpace = "any"

    @ObservationIgnored let store: UserDefaults
    private(set) var accounts: [String: String]
    private(set) var calendars: [String: String]
    private(set) var offered: Set<String>

    init(store: UserDefaults) {
        self.store = store
        accounts = store.dictionary(forKey: Self.accountsKey) as? [String: String] ?? [:]
        calendars = store.dictionary(forKey: Self.calendarsKey) as? [String: String] ?? [:]
        offered = Set(store.stringArray(forKey: Self.offeredKey) ?? [])
    }

    func reload() {
        accounts = store.dictionary(forKey: Self.accountsKey) as? [String: String] ?? [:]
        calendars = store.dictionary(forKey: Self.calendarsKey) as? [String: String] ?? [:]
        offered = Set(store.stringArray(forKey: Self.offeredKey) ?? [])
    }

    func space(ofAccount key: String) -> UUID? {
        guard !key.isEmpty else { return nil }
        return accounts[key].flatMap(UUID.init(uuidString:))
    }

    func place(_ space: UUID?, ofAccount key: String) {
        guard !key.isEmpty else { return }
        accounts[key] = space?.uuidString
        store.set(accounts, forKey: Self.accountsKey)
    }

    func place(ofCalendar id: String) -> MeetingCalendarPlace {
        guard !id.isEmpty, let kept = calendars[id] else { return .account }
        if kept == Self.anySpace { return .any }
        return UUID(uuidString: kept).map(MeetingCalendarPlace.space) ?? .account
    }

    func place(_ place: MeetingCalendarPlace, ofCalendar id: String) {
        guard !id.isEmpty else { return }
        switch place {
        case .account: calendars[id] = nil
        case .any: calendars[id] = Self.anySpace
        case .space(let space): calendars[id] = space.uuidString
        }
        store.set(calendars, forKey: Self.calendarsKey)
    }

    func wasOffered(_ key: String) -> Bool { offered.contains(key) }

    func offer(_ key: String) {
        offered.insert(key)
        store.set(offered.sorted(), forKey: Self.offeredKey)
    }

    func shown(_ space: UUID?, among spaces: [UUID]) -> UUID? {
        space.flatMap { spaces.contains($0) ? $0 : nil }
    }

    func shown(_ place: MeetingCalendarPlace, among spaces: [UUID]) -> MeetingCalendarPlace {
        if case .space(let id) = place, !spaces.contains(id) { return .account }
        return place
    }
}

@MainActor
final class MeetingSpaceMemory {
    static let shared = MeetingSpaceMemory(store: Store.settings)
    static let accountsKey = "meetings.accountSpaces"
    static let openedKey = "meetings.callSpaces"
    static let fellKey = "meetings.fellSpaces"
    static let oldOpenedKey = "meetings.openedSpaces"
    static let accountKeep: TimeInterval = 60 * 24 * 3600
    static let mostOpened = 200
    static let mostJoined = 50

    let store: UserDefaults
    var clock: () -> Date = Date.init
    var lastChoice: MeetingSpaceReason?
    var quiet = false
    private var joined: [(key: String, event: CalendarEvent)] = []

    init(store: UserDefaults) {
        self.store = store
        store.removeObject(forKey: Self.oldOpenedKey)
    }

    private var accounts: [String: [String: Double]] {
        get { store.dictionary(forKey: Self.accountsKey) as? [String: [String: Double]] ?? [:] }
        set { store.set(newValue, forKey: Self.accountsKey) }
    }

    private var opened: [String: [String: Any]] {
        get { store.dictionary(forKey: Self.openedKey) as? [String: [String: Any]] ?? [:] }
        set { store.set(newValue, forKey: Self.openedKey) }
    }

    private var fellen: [String: [String: Any]] {
        get { store.dictionary(forKey: Self.fellKey) as? [String: [String: Any]] ?? [:] }
        set { store.set(newValue, forKey: Self.fellKey) }
    }

    func forgetSession() {
        joined = []
    }

    private static func trimmed(_ all: [String: [String: Any]]) -> [String: [String: Any]] {
        guard all.count > mostOpened else { return all }
        var kept = all
        let oldest = all.sorted { ($0.value["at"] as? Double ?? 0) < ($1.value["at"] as? Double ?? 0) }
        for (key, _) in oldest.prefix(all.count - mostOpened) { kept[key] = nil }
        return kept
    }

    func saw(account email: String, in space: UUID) {
        let email = email.lowercased()
        guard !email.isEmpty else { return }
        let now = clock().timeIntervalSince1970
        var all = accounts
        if let last = all[email]?[space.uuidString], now - last < 3600 {
            if all[email]?.values.allSatisfy({ $0 <= last }) == true { return }
        }
        all[email, default: [:]][space.uuidString] = now
        accounts = all
    }

    func spaces(signedInto email: String) -> [UUID] {
        let email = email.lowercased()
        guard !email.isEmpty, let seen = accounts[email] else { return [] }
        let now = clock().timeIntervalSince1970
        return seen.filter { now - $0.value < Self.accountKeep }.compactMap { UUID(uuidString: $0.key) }
    }

    func lastSeen(account email: String) -> UUID? {
        let email = email.lowercased()
        guard !email.isEmpty, let seen = accounts[email] else { return nil }
        let now = clock().timeIntervalSince1970
        return seen.filter { now - $0.value < Self.accountKeep }.max { $0.value < $1.value }.flatMap { UUID(uuidString: $0.key) }
    }

    func opened(_ link: URL?, calendar: String, in space: UUID) {
        var all = opened
        let now = clock().timeIntervalSince1970
        let entry: [String: Any] = ["space": space.uuidString, "at": now]
        if let link, let key = MeetingSpaceChoice.linkKey(link) {
            all["link:" + key] = entry
            if fellen[key] != nil { fellen[key] = nil }
        }
        if !calendar.isEmpty { all["calendar:" + calendar] = entry }
        opened = Self.trimmed(all)
    }

    func fell(_ link: URL, into space: UUID) {
        guard let key = MeetingSpaceChoice.linkKey(link) else { return }
        var all = fellen
        all[key] = ["space": space.uuidString, "at": clock().timeIntervalSince1970]
        fellen = Self.trimmed(all)
    }

    func fellBack(_ link: URL, in space: UUID) -> Bool {
        guard let key = MeetingSpaceChoice.linkKey(link) else { return false }
        return self.space(fellen[key]) == space
    }

    func remember(_ link: URL, event: CalendarEvent?) {
        guard let event, let key = MeetingSpaceChoice.linkKey(link) else { return }
        joined.removeAll { $0.key == key }
        joined.append((key, event))
        if joined.count > Self.mostJoined { joined.removeFirst(joined.count - Self.mostJoined) }
    }

    func event(for link: URL) -> CalendarEvent? {
        guard let key = MeetingSpaceChoice.linkKey(link) else { return nil }
        return joined.last { $0.key == key }?.event
    }

    func lastOpened(link: URL?) -> UUID? {
        guard let link, let key = MeetingSpaceChoice.linkKey(link) else { return nil }
        return space(opened["link:" + key])
    }

    func lastOpened(calendar: String) -> UUID? {
        guard !calendar.isEmpty else { return nil }
        return space(opened["calendar:" + calendar])
    }

    private func space(_ entry: [String: Any]?) -> UUID? {
        (entry?["space"] as? String).flatMap(UUID.init(uuidString:))
    }

    func signals(for link: URL, event: CalendarEvent?, current: UUID, spaces: [UUID], tied: UUID?,
                 places: MeetingSpacePlaces = .shared) -> MeetingSpaceSignals {
        MeetingSpaceSignals(current: current, spaces: spaces, tied: tied,
                            chosenCalendar: event.map { places.place(ofCalendar: $0.calendar) } ?? .account,
                            chosenAccount: event.flatMap { places.space(ofAccount: $0.source) },
                            account: event.map { self.spaces(signedInto: $0.account) } ?? [],
                            link: lastOpened(link: link),
                            calendar: event.flatMap { lastOpened(calendar: $0.calendar) })
    }
}

enum MeetingSpaceWords {
    static func offer(_ account: String, _ space: String) -> String { "Always open \(account) calls in \(space)?" }
    static func told(_ account: String, _ space: String) -> String { "\(account) calls open in \(space) from now on" }
}

extension Browser {
    func meetingEvent(for link: URL, wide: Bool = true) -> CalendarEvent? {
        let known = [Meetings.shared.next].compactMap { $0 } + MeetingAlerts.shared.due + (wide ? Meetings.shared.known : [])
        if let found = known.first(where: { $0.link.map { MeetingLink.same($0, link) || $0 == link } == true })?.event { return found }
        return wide ? MeetingSpaceMemory.shared.event(for: link) : nil
    }

    func joinMeeting(_ link: URL, event: CalendarEvent? = nil) {
        let event = event ?? meetingEvent(for: link)
        let memory = MeetingSpaceMemory.shared
        memory.remember(link, event: event)
        let landed = landMeeting(link, event: event)
        landed.browser.meetingJoined(link, event: event)
        switch memory.lastChoice {
        case nil, .current: break
        default: memory.opened(link, calendar: event?.calendar ?? "", in: landed.space)
        }
        if let event, let reason = memory.lastChoice, ![.tied, .chosenCalendar, .chosenAccount].contains(reason),
           let seen = memory.lastSeen(account: event.account), seen != landed.space {
            landed.browser.offerMeetingSpace(for: event, in: seen)
        }
        guard !Store.testing else { return }
        Browsers.show(landed.browser)
        landed.browser.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func landMeeting(_ link: URL, event: CalendarEvent?) -> (browser: Browser, space: UUID) {
        MeetingSpaceMemory.shared.lastChoice = nil
        if let tab = tabs.first(where: { $0.address.map { $0 == link || MeetingLink.same($0, link) } == true }) {
            select(tab)
            return (self, spaceID)
        }
        guard showsSpaces else {
            open(link, foreground: true, from: active)
            return (self, spaceID)
        }
        let world = Browsers.linkWorld(from: self, rules: LinkRules.shared.rules)
        let source = IncomingLink(url: link, source: .page(space: spaceID, site: nil))
        if let (id, space) = meetingTab(for: link) {
            let decision = LinkDecision(url: link, place: .tab(id, space: space), rule: nil, steps: [], background: false)
            return (Browsers.apply(decision, link: source, from: self, world: world).browser, space)
        }
        let signals = MeetingSpaceMemory.shared.signals(for: link, event: event, current: spaceID, spaces: spaces.map(\.id),
                                                        tied: tiedSpace(for: link, world: world))
        let chosen = MeetingSpaceChoice.choose(signals)
        MeetingSpaceMemory.shared.lastChoice = chosen.reason
        if chosen.reason == .current { MeetingSpaceMemory.shared.fell(link, into: spaceID) }
        guard chosen.space != spaceID else {
            open(link, foreground: true, from: active)
            return (self, spaceID)
        }
        let decision = LinkDecision(url: link, place: .space(chosen.space, folder: nil), rule: nil, steps: [], background: false)
        return (Browsers.apply(decision, link: source, from: self, world: world).browser, chosen.space)
    }

    func meetingTab(for link: URL) -> (UUID, UUID)? {
        for window in Browsers.linkTargets where window.showsSpaces {
            if let tab = window.tabs.first(where: { $0.address.map { MeetingLink.same($0, link) } == true }) { return (tab.id, window.spaceID) }
        }
        for (space, parked) in parked {
            if let tab = parked.tabs.first(where: { $0.address.map { MeetingLink.same($0, link) } == true }) { return (tab.id, space) }
        }
        return nil
    }

    func tiedSpace(for link: URL, world: LinkWorld) -> UUID? {
        let store = LinkRules.shared
        let decision = LinkRouter.decide(IncomingLink(url: link, source: .unknownApp), rules: store.rules, settings: store.settings, world: world)
        guard decision.rule != nil else { return nil }
        switch decision.place {
        case .space(let id, _): return id
        case .tab(_, let space): return space
        case .here: return world.front
        default: return nil
        }
    }

    func noteMeetingPage(_ tab: Tab) {
        guard !isPrivate, !tab.shy, !tab.bench, let url = tab.address else { return }
        let home = tabs.contains(where: { $0 === tab }) ? spaceID : parked.first { $0.value.tabs.contains { $0 === tab } }?.key ?? spaceID
        let memory = MeetingSpaceMemory.shared
        let call = MeetingSpaceChoice.linkKey(url) != nil
        if !call, let email = MeetingSpaceChoice.account(inTitle: tab.title, at: url) {
            memory.saw(account: email, in: home)
        }
        if call, !memory.fellBack(url, in: home), memory.lastOpened(link: url) != home {
            memory.opened(url, calendar: meetingEvent(for: url, wide: false)?.calendar ?? "", in: home)
        }
    }

    func joinsMeeting(_ url: URL, from source: Tab?) -> Bool {
        guard showsSpaces, spaces.count > 1, let source, !source.shy, !source.bench, !source.agent,
              Meetings.isCalendar(source.address), MeetingLink.service(of: url) != nil
        else { return false }
        joinMeeting(url)
        return true
    }

    @discardableResult
    func meetingMoved(_ tab: Tab, to space: UUID) -> Bool {
        guard !MeetingSpaceMemory.shared.quiet, !isPrivate, !tab.shy, !tab.bench, !tab.agent, let url = tab.address,
              MeetingSpaceChoice.linkKey(url) != nil else { return false }
        let event = meetingEvent(for: url)
        MeetingSpaceMemory.shared.opened(url, calendar: event?.calendar ?? "", in: space)
        guard let event else { return false }
        offerMeetingSpace(for: event, in: space)
        return true
    }

    func offerMeetingSpace(for event: CalendarEvent, in space: UUID, places: MeetingSpacePlaces = .shared) {
        let key = event.source
        let name = event.sourceTitle.isEmpty ? event.account : event.sourceTitle
        guard showsSpaces, spaces.count > 1, !key.isEmpty, !name.isEmpty, !places.wasOffered(key),
              places.place(ofCalendar: event.calendar) == .account,
              places.shown(places.space(ofAccount: key), among: spaces.map(\.id)) != space,
              let target = spaces.first(where: { $0.id == space })
        else { return }
        places.offer(key)
        let spaceName = target.name
        showLinkNotice(LinkNotice(MeetingSpaceWords.offer(name, spaceName), kind: .offer, choices: [
            .init("Not Now", id: "meeting.notice.notNow") { [weak self] in self?.showLinkNotice(nil) },
            .init("Yes", .primary, id: "meeting.notice.yes") { [weak self] in
                places.place(space, ofAccount: key)
                self?.showLinkNotice(nil)
                self?.announce(MeetingSpaceWords.told(name, spaceName))
            },
        ]))
    }
}

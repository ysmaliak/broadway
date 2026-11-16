import AppKit

enum MeetingSpaceReason: String, Equatable {
    case tied, account, link, calendar, current
}

struct MeetingSpaceSignals: Equatable {
    var current: UUID
    var spaces: [UUID]
    var tied: UUID? = nil
    var account: [UUID] = []
    var link: UUID? = nil
    var calendar: UUID? = nil
}

enum MeetingSpaceChoice {
    static func choose(_ signals: MeetingSpaceSignals) -> (space: UUID, reason: MeetingSpaceReason) {
        let known = Set(signals.spaces)
        if let tied = signals.tied, known.contains(tied) { return (tied, .tied) }
        let signed = Set(signals.account.filter(known.contains))
        if signed.count == 1, let only = signed.first { return (only, .account) }
        if let link = signals.link, known.contains(link) { return (link, .link) }
        if let calendar = signals.calendar, known.contains(calendar) { return (calendar, .calendar) }
        return (signals.current, .current)
    }

    static func account(inTitle title: String, at url: URL?) -> String? {
        guard url?.host()?.lowercased() == "mail.google.com",
              let pattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#),
              let match = pattern.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range, in: title)
        else { return nil }
        return title[range].lowercased()
    }

    static func linkKey(_ url: URL) -> String? {
        guard let service = MeetingLink.service(of: url) else { return nil }
        let id = MeetingLink.identifier(of: url)
        return id.isEmpty ? nil : "\(service.name):\(id)"
    }
}

@MainActor
final class MeetingSpaceMemory {
    static let shared = MeetingSpaceMemory(store: Store.settings)
    static let accountsKey = "meetings.accountSpaces"
    static let openedKey = "meetings.openedSpaces"
    static let accountKeep: TimeInterval = 60 * 24 * 3600
    static let mostOpened = 200

    let store: UserDefaults
    var clock: () -> Date = Date.init
    var lastChoice: MeetingSpaceReason?

    init(store: UserDefaults) {
        self.store = store
    }

    private var accounts: [String: [String: Double]] {
        get { store.dictionary(forKey: Self.accountsKey) as? [String: [String: Double]] ?? [:] }
        set { store.set(newValue, forKey: Self.accountsKey) }
    }

    private var opened: [String: [String: Any]] {
        get { store.dictionary(forKey: Self.openedKey) as? [String: [String: Any]] ?? [:] }
        set { store.set(newValue, forKey: Self.openedKey) }
    }

    func saw(account email: String, in space: UUID) {
        let email = email.lowercased()
        guard !email.isEmpty else { return }
        let now = clock().timeIntervalSince1970
        var all = accounts
        if let last = all[email]?[space.uuidString], now - last < 3600 { return }
        all[email, default: [:]][space.uuidString] = now
        accounts = all
    }

    func spaces(signedInto email: String) -> [UUID] {
        let email = email.lowercased()
        guard !email.isEmpty, let seen = accounts[email] else { return [] }
        let now = clock().timeIntervalSince1970
        return seen.filter { now - $0.value < Self.accountKeep }.compactMap { UUID(uuidString: $0.key) }
    }

    func opened(_ link: URL?, calendar: String, in space: UUID) {
        var all = opened
        let now = clock().timeIntervalSince1970
        let entry: [String: Any] = ["space": space.uuidString, "at": now]
        if let link, let key = MeetingSpaceChoice.linkKey(link) { all["link:" + key] = entry }
        if !calendar.isEmpty { all["calendar:" + calendar] = entry }
        if all.count > Self.mostOpened {
            let oldest = all.sorted { ($0.value["at"] as? Double ?? 0) < ($1.value["at"] as? Double ?? 0) }
            for (key, _) in oldest.prefix(all.count - Self.mostOpened) { all[key] = nil }
        }
        opened = all
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

    func signals(for link: URL, event: CalendarEvent?, current: UUID, spaces: [UUID], tied: UUID?) -> MeetingSpaceSignals {
        MeetingSpaceSignals(current: current, spaces: spaces, tied: tied,
                            account: event.map { self.spaces(signedInto: $0.account) } ?? [],
                            link: lastOpened(link: link),
                            calendar: event.flatMap { lastOpened(calendar: $0.calendar) })
    }
}

extension Browser {
    func meetingEvent(for link: URL) -> CalendarEvent? {
        let known = [Meetings.shared.next].compactMap { $0 } + MeetingAlerts.shared.due
        return known.first { $0.link.map { MeetingLink.same($0, link) || $0 == link } == true }?.event
    }

    func joinMeeting(_ link: URL, event: CalendarEvent? = nil) {
        let event = event ?? meetingEvent(for: link)
        let landed = landMeeting(link, event: event)
        MeetingSpaceMemory.shared.opened(link, calendar: event?.calendar ?? "", in: landed.space)
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
        if let email = MeetingSpaceChoice.account(inTitle: tab.title, at: url) {
            MeetingSpaceMemory.shared.saw(account: email, in: home)
        }
        if MeetingSpaceChoice.linkKey(url) != nil, MeetingSpaceMemory.shared.lastOpened(link: url) != home {
            MeetingSpaceMemory.shared.opened(url, calendar: meetingEvent(for: url)?.calendar ?? "", in: home)
        }
    }
}

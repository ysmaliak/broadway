import AppKit
import UserNotifications

@MainActor
enum AgentLooking {
    static var early: Double = 20
    static var looking: () -> Bool = { AgentLooking.cardOnScreen() }

    static func cardOnScreen() -> Bool {
        guard NSApp.isActive, !NSApp.isHidden, AgentDesk.shared.front != nil else { return false }
        return Browsers.all.contains { browser in
            guard !browser.isPopup, let window = browser.window else { return false }
            return window.isVisible && !window.isMiniaturized && window.isOnActiveSpace && window.occlusionState.contains(.visible)
        }
    }

    static func unseen(for task: UUID?) -> Double? {
        guard let task, TaskLedger.shared.entry(task) != nil, !overSSH(task) else { return nil }
        return early
    }

    static func overSSH(_ task: UUID) -> Bool {
        if AgentLinks.shared.link(task)?.remote == true { return true }
        guard case .named(let key)? = AgentLinks.shared.link(task)?.key else { return false }
        return key.hasPrefix("ssh:")
    }
}

@MainActor
final class AgentHeld {
    static let shared = AgentHeld()
    static let life: TimeInterval = 600

    enum Kind {
        case handoff, ask, person
    }

    final class Entry {
        let key: String
        let task: UUID
        let kind: Kind
        let question: UUID
        let tab: Tab.ID?
        let asking: Task<AgentAnswer, Never>
        let started: Date
        let before: String?
        var answer: AgentAnswer?
        var answeredAt: Date?
        var watcher: Task<Void, Never>?
        var taken = false

        init(key: String, task: UUID, kind: Kind, question: UUID, tab: Tab.ID?, asking: Task<AgentAnswer, Never>, started: Date, before: String?) {
            self.key = key
            self.task = task
            self.kind = kind
            self.question = question
            self.tab = tab
            self.asking = asking
            self.started = started
            self.before = before
        }

        var pending: Bool { answer == nil }
    }

    private var entries: [String: Entry] = [:]

    private func key(_ task: UUID, _ signature: String) -> String { "\(task.uuidString)|\(signature)" }

    func entry(_ task: UUID, _ signature: String, at now: Date = Date()) -> Entry? {
        let key = key(task, signature)
        guard let found = entries[key] else { return nil }
        if found.answer == .dropped || found.answeredAt.map({ now.timeIntervalSince($0) > Self.life }) == true {
            release(found)
            return nil
        }
        return found
    }

    func holds(_ task: UUID, _ signature: String) -> Bool { entry(task, signature) != nil }

    func pending(_ task: UUID, kind: Kind) -> Entry? {
        entries.values.first { $0.task == task && $0.kind == kind && $0.pending }
    }

    func hold(_ task: UUID, _ signature: String, kind: Kind, question: UUID, tab: Tab.ID? = nil, asking: Task<AgentAnswer, Never>,
              started: Date = Date(), before: String? = nil) -> Entry {
        let made = Entry(key: key(task, signature), task: task, kind: kind, question: question, tab: tab, asking: asking, started: started, before: before)
        if let old = entries[made.key] { release(old) }
        entries[made.key] = made
        Task { @MainActor [weak made] in
            let said = await asking.value
            made?.answer = said
            made?.answeredAt = Date()
            made?.watcher?.cancel()
        }
        return made
    }

    func release(_ entry: Entry) {
        entry.watcher?.cancel()
        if entries[entry.key] === entry { entries[entry.key] = nil }
    }

    func forget(task: UUID) {
        for entry in entries.values where entry.task == task { release(entry) }
    }

    func reset() {
        for entry in Array(entries.values) { release(entry) }
    }
}

@MainActor
enum AgentBadge {
    static var drivesTile = !Store.testing {
        didSet { NSApp.dockTile.badgeLabel = drivesTile ? shown : nil }
    }
    private(set) static var shown: String?

    static func show(_ count: Int) {
        let label = count > 0 ? "\(count)" : nil
        guard label != shown else { return }
        shown = label
        if drivesTile { NSApp.dockTile.badgeLabel = label }
    }
}

@MainActor
enum AgentNotice {
    static func tell(_ question: AgentQuestion) {
        guard !AgentLooking.looking() else { return }
        let link = question.task.flatMap { AgentLinks.shared.link($0) }
        var info: [String: Any] = ["search.kind": "agent", "search.question": question.id.uuidString]
        if let tab = question.tab { info["search.tab"] = tab.uuidString }
        SiteNotifications.shared.authorize()
        SiteNotifications.shared.post(id: question.id.uuidString, title: link?.needsYouLine ?? "An agent needs you", body: firstLine(question.title),
                                      origin: question.site.map { "https://\($0)" } ?? "broadway://agents", tag: "", info: info)
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    static func taken(_ id: UUID) {
        guard !Store.testing else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id.uuidString])
    }

    static func clicked(_ info: [AnyHashable: Any]) {
        let wanted = (info["search.tab"] as? String).flatMap(UUID.init(uuidString:))
        let found = wanted.flatMap { id in
            Browsers.all.lazy.compactMap { browser in browser.tabs.first { $0.id == id }.map { (browser, $0) } }.first
        }
        if let (browser, tab) = found {
            browser.select(tab)
            Browsers.show(browser)
        } else if let browser = Browsers.front {
            Browsers.show(browser)
        }
        NSApp.activate()
    }
}

@MainActor
enum AgentGone {
    private static var sources: [Int32: DispatchSourceProcess] = [:]

    static func process(of link: AgentLink) -> AgentProcessID? {
        if case .process(let pid, let started) = link.key { return AgentProcessID(pid: pid, started: started) }
        return link.process
    }

    static func watch(_ task: UUID?) {
        guard let task, let link = AgentLinks.shared.link(task), link.live, let process = process(of: link), sources[process.pid] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                sources[process.pid]?.cancel()
                sources[process.pid] = nil
                ended(process)
            }
        }
        sources[process.pid] = source
        source.resume()
        if !AgentLinks.shared.alive(process.pid, process.started) {
            source.cancel()
            sources[process.pid] = nil
            ended(process)
        }
    }

    static func ended(_ process: AgentProcessID) {
        for link in AgentLinks.shared.live where Self.process(of: link) == process {
            AgentDesk.shared.drop(task: link.id)
            if !link.person { AgentLinks.shared.end(link.id, .done(nil)) }
        }
    }
}

@MainActor
enum AgentSignIn {
    static var settle: TimeInterval = 3
    static var every: Duration = .milliseconds(500)
    static let needsScript = AgentPage.walkBase + "\nreturn broadwayNeeds();"

    static func needs(_ tab: Tab, box: BrowserToolbox) async -> String? {
        if Passkeys.shared.busy { return "passkey" }
        return await box.timed(tab, needsScript) as? String
    }

    static func watch(_ tab: Tab, question: UUID, box: BrowserToolbox) -> Task<Void, Never> {
        Task { @MainActor [weak tab, weak box] in
            guard let tab, let box, let first = await needs(tab, box: box), !first.isEmpty else { return }
            let start = tab.pageAddress.map(History.identity(for:))
            var clear: Date?
            while !Task.isCancelled, AgentDesk.shared.pending.contains(where: { $0.id == question }) {
                try? await Task.sleep(for: every)
                guard !Task.isCancelled else { return }
                guard !tab.loading, let now = await needs(tab, box: box) else {
                    clear = nil
                    continue
                }
                guard now.isEmpty, tab.pageAddress.map(History.identity(for:)) != start else {
                    clear = nil
                    continue
                }
                let since = clear ?? Date()
                clear = since
                if Date().timeIntervalSince(since) >= settle {
                    AgentDesk.shared.take(question, .picked(0))
                    return
                }
            }
        }
    }
}

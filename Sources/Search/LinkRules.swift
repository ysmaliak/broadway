import Foundation
import Observation

struct LinkSender: Codable, Equatable, Hashable {
    var bundleID: String
    var name: String
}

struct LinkRecent: Identifiable, Equatable {
    let id = UUID()
    var site: String
    var from: String
    var rule: UUID?
    var went: String
    var live: String? = nil
    var when = Date()
}

@MainActor
@Observable
final class LinkRules {
    static let shared = LinkRules(file: Store.file("links.json"), old: Store.file("routes.json"))
    static let recentLimit = 20
    static let sendersLimit = 12

    private(set) var rules: [LinkRule] = []
    private(set) var settings = LinkSettings()
    private(set) var senders: [LinkSender] = []
    private(set) var recent: [LinkRecent] = []
    private(set) var revision = 0

    @ObservationIgnored private let file: URL

    private struct Saved: Codable {
        var rules: [LinkRule]
        var settings: LinkSettings?
        var senders: [LinkSender]?
    }

    private struct OldRoute: Codable {
        enum Target: Codable {
            case space(UUID)
            case window(UUID?)
            case peek
        }

        var id: UUID?
        var site: String
        var target: Target
    }

    init(file: URL, old: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            guard let saved = try? JSONDecoder().decode(Saved.self, from: data) else {
                Store.quarantine(file)
                return
            }
            rules = saved.rules
            settings = saved.settings ?? LinkSettings()
            senders = saved.senders ?? []
            return
        }
        guard let data = try? Data(contentsOf: old), let moved = LinkRules.migrate(data) else { return }
        rules = moved
        save()
    }

    static func migrate(_ data: Data, made: Date = Date()) -> [LinkRule]? {
        guard let routes = try? JSONDecoder().decode([OldRoute].self, from: data) else { return nil }
        return routes.map { route in
            let target: LinkRule.Target = switch route.target {
            case .space(let id): .space(id, folder: nil)
            case .window(let id): .window(id)
            case .peek: .peek
            }
            return LinkRule(id: route.id ?? UUID(), match: .site(route.site), from: .otherApps, target: target, made: made)
        }
    }

    private func save() {
        revision += 1
        let saved = Saved(rules: rules, settings: settings, senders: senders)
        Disk.write(file) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try? encoder.encode(saved)
        }
    }

    func rule(_ id: UUID?) -> LinkRule? {
        guard let id else { return nil }
        return rules.first { $0.id == id }
    }

    func index(of id: UUID) -> Int? { rules.firstIndex { $0.id == id } }

    @discardableResult
    func add(_ rule: LinkRule, at index: Int? = nil) -> LinkRule {
        let at = min(max(index ?? rules.count, 0), rules.count)
        rules.insert(rule, at: at)
        save()
        return rule
    }

    func update(_ rule: LinkRule) {
        guard let at = index(of: rule.id), rules[at] != rule else { return }
        rules[at] = rule
        save()
    }

    func change(_ id: UUID, _ edit: (inout LinkRule) -> Void) {
        guard let at = index(of: id) else { return }
        var rule = rules[at]
        edit(&rule)
        update(rule)
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func move(_ id: UUID, by step: Int) {
        guard let at = index(of: id) else { return }
        let to = at + step
        guard rules.indices.contains(to) else { return }
        rules.swapAt(at, to)
        save()
    }

    func move(_ id: UUID, to index: Int) {
        guard let at = self.index(of: id) else { return }
        let rule = rules.remove(at: at)
        rules.insert(rule, at: min(max(index, 0), rules.count))
        save()
    }

    func set(_ edit: (inout LinkSettings) -> Void) {
        var next = settings
        edit(&next)
        guard next != settings else { return }
        settings = next
        save()
    }

    func replaceAll(_ rules: [LinkRule], settings: LinkSettings = LinkSettings()) {
        self.rules = rules
        self.settings = settings
        recent = []
        save()
    }

    func siteRule(_ site: String) -> LinkRule? {
        rules.first { rule in
            if case .site(let text) = rule.match { return LinkRouter.plainSite(text) == site }
            return false
        }
    }

    func target(of site: String) -> LinkRule.Target? { siteRule(site)?.target }

    @discardableResult
    func always(_ site: String, to target: LinkRule.Target, from: LinkRule.From = .anywhere) -> LinkRule {
        if var rule = siteRule(site) {
            rule.target = target
            rule.on = true
            update(rule)
            return rule
        }
        let rule = LinkRule(match: .site(site), from: from, target: target)
        return add(rule, at: LinkRules.place(forSite: site, in: rules))
    }

    func forget(_ site: String) {
        guard let rule = siteRule(site) else { return }
        remove(rule.id)
    }

    static func place(forSite site: String, in rules: [LinkRule]) -> Int {
        guard let home = URL(string: "https://\(site)/") else { return rules.count }
        for (index, rule) in rules.enumerated() {
            switch rule.match {
            case .site(let text):
                let other = LinkRouter.plainSite(text)
                if site == other || site.hasSuffix("." + other) { return index }
            case .host:
                continue
            case .starts, .contains, .pattern, .regex:
                if LinkRouter.matches(rule.match, home) { return index }
            }
        }
        return rules.count
    }

    func saw(_ sender: LinkSender) {
        guard !sender.bundleID.isEmpty else { return }
        var next = senders.filter { $0.bundleID != sender.bundleID }
        next.insert(sender, at: 0)
        next = Array(next.prefix(LinkRules.sendersLimit))
        guard next != senders else { return }
        senders = next
        save()
    }

    func note(_ entry: LinkRecent) {
        recent.insert(entry, at: 0)
        if recent.count > LinkRules.recentLimit { recent.removeLast(recent.count - LinkRules.recentLimit) }
    }

    func clearRecent() { recent = [] }

    static func sites(_ rows: [UUID: [String]], taken: Set<String> = []) -> [String: [UUID: Int]] {
        var seen: [String: [UUID: Int]] = [:]
        for (space, addresses) in rows {
            for address in addresses {
                guard let site = LinkRouter.site(of: URL(string: address)), !taken.contains(site) else { continue }
                seen[site, default: [:]][space, default: 0] += 1
            }
        }
        return seen
    }

    static func rows(_ spaces: [UUID], leaving pins: Set<UUID> = []) -> [UUID: [String]] {
        Dictionary(spaces.map { space in
            (space, Session.read(space: space).tabs.filter { $0.pinID.map(pins.contains) != true }.map(\.url))
        }, uniquingKeysWith: { a, _ in a })
    }

    static func habits(_ rows: [UUID: [String]], taken: Set<String>) -> [(site: String, space: UUID)] {
        sites(rows, taken: taken).compactMap { site, spaces -> (site: String, space: UUID, count: Int)? in
            guard spaces.count == 1, let only = spaces.first, only.value >= 3 else { return nil }
            return (site, only.key, only.value)
        }
        .sorted { ($0.count, $1.site) > ($1.count, $0.site) }
        .map { ($0.site, $0.space) }
    }

    func suggestions(for browser: Browser) -> [(site: String, space: UUID)] {
        guard browser.prefs.usesSpaces, browser.spaces.count > 1 else { return [] }
        let rows = LinkRules.rows(browser.spaces.map(\.id))
        let taken = Set(rules.compactMap { rule -> String? in
            if case .site(let text) = rule.match { return LinkRouter.plainSite(text) }
            return nil
        })
        return Array(LinkRules.habits(rows, taken: taken).prefix(3))
    }
}

import Foundation

struct AIGroupTab: Equatable, Sendable {
    var id: UUID
    var title: String
    var host: String
    var path: String
    var query = ""
    var by = ""

    var key: String { AIGroupTab.key(host: host, path: path, query: query) }

    static func key(host: String, path: String, query: String = "") -> String {
        query.isEmpty ? host + path : host + path + "?" + query
    }

    init(id: UUID, title: String, host: String, path: String, query: String = "", by: String = "") {
        self.id = id
        self.title = title
        self.host = host
        self.path = path
        self.query = query
        self.by = by
    }

    init?(id: UUID, title: String, url: URL?, by: String = "") {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let found = url.host(), !found.isEmpty else { return nil }
        let words = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return nil }
        var host = found.lowercased()
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        var path = url.path(percentEncoded: false)
        if path == "/" { path = "" }
        let named = by.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        self.init(id: id, title: String(words.prefix(120)), host: host, path: String(path.prefix(80)),
                  query: String((url.query(percentEncoded: true) ?? "").prefix(200)), by: String(named.prefix(60)))
    }

    var line: String {
        "\"\(title.replacingOccurrences(of: "\"", with: "'"))\" \(host)\(path)"
    }

    var localLine: String {
        "\"\(title)\" on \(host)" + (by.isEmpty ? "" : " — by \(by)")
    }

    var sent: AIGroupTab {
        var out = self
        out.by = ""
        out.query = ""
        return out
    }

    var bare: AIGroupTab {
        var out = self
        out.query = ""
        out.path = ""
        return out
    }

    var remoteLine: String {
        "\"\(title.replacingOccurrences(of: "\"", with: "'"))\" — \(host)" + (by.isEmpty ? "" : " — by \(by)")
    }
}

struct AIGroupInfo: Equatable, Sendable {
    var id: UUID
    var name: String
    var members: [AIGroupTab]
    var refused: Set<String> = []
    var settled = true

    var sent: AIGroupInfo {
        AIGroupInfo(id: id, name: name, members: members.map(\.sent), settled: settled)
    }

    var bare: AIGroupInfo {
        AIGroupInfo(id: id, name: name, members: members.map(\.bare), settled: settled)
    }
}

struct AIGroupAsk: Equatable, Sendable {
    var groups: [AIGroupInfo]
    var loose: [AIGroupTab]
    var fresh: [AIGroupTab]

    var sent: AIGroupAsk {
        AIGroupAsk(groups: groups.map { AIGroupInfo(id: $0.id, name: $0.name, members: $0.members.map(\.sent), refused: []) },
                   loose: loose.map(\.sent), fresh: fresh.map(\.sent))
    }

    var bare: AIGroupAsk {
        AIGroupAsk(groups: groups.map { AIGroupInfo(id: $0.id, name: $0.name, members: $0.members.map(\.bare), refused: []) },
                   loose: loose.map(\.bare), fresh: fresh.map(\.bare))
    }

    var signature: String {
        (groups.map { $0.id.uuidString } + loose.map(\.key)).sorted().joined(separator: "|")
    }
}

enum AIGroupPick: Equatable, Sendable {
    case none
    case group(UUID)
    case tab(UUID)
}

struct AIGroupNameAsk: Equatable, Sendable {
    var tabs: [AIGroupTab]
    var current: String?
    var currentEmoji: String?
    var emoji: Bool
    var query: String? = nil
    var rejected: [String] = []

    var sent: AIGroupNameAsk {
        var out = self
        out.tabs = tabs.map(\.sent)
        return out
    }

    var bare: AIGroupNameAsk {
        var out = self
        out.tabs = tabs.map(\.bare)
        return out
    }
}

struct AIGroupName: Equatable, Sendable {
    var name: String
    var emoji: String?
    var keep = false

    static func cleaned(name: String, emoji: String?, keep: Bool) -> AIGroupName? {
        let plain = String(name.filter { !isEmoji($0) })
        let short = plain.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”«».")))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let mark = emoji.flatMap(AIGroupName.emoji(in:))
        guard !short.isEmpty || keep else { return nil }
        return AIGroupName(name: short, emoji: mark, keep: keep)
    }

    static func emoji(in text: String) -> String? {
        text.first(where: isEmoji).map(String.init)
    }

    static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }
    }
}

struct AIGroupPlan: Equatable {
    var joins: [UUID: UUID] = [:]
    var formed: [[UUID]] = []

    var isEmpty: Bool { joins.isEmpty && formed.isEmpty }
}

enum AIGroupRules {
    static func plan(_ ask: AIGroupAsk, picks: [UUID: AIGroupPick], dismissed: [Set<String>] = [],
                     openers: [UUID: UUID] = [:]) -> AIGroupPlan {
        let fresh = Dictionary(ask.fresh.map { ($0.id, $0) }, uniquingKeysWith: { one, _ in one })
        let loose = Dictionary(ask.loose.map { ($0.id, $0) }, uniquingKeysWith: { one, _ in one })
        let groups = Dictionary(ask.groups.map { ($0.id, $0) }, uniquingKeysWith: { one, _ in one })
        var parent: [UUID: UUID] = [:]
        func root(_ id: UUID) -> UUID {
            var at = id
            while let up = parent[at], up != at { at = up }
            return at
        }
        func join(_ one: UUID, _ two: UUID) {
            let a = root(one), b = root(two)
            if a != b { parent[b] = a }
        }
        var wanted: [UUID: UUID] = [:]
        for tab in ask.fresh {
            parent[tab.id] = tab.id
        }
        for tab in ask.fresh {
            switch picks[tab.id] ?? .none {
            case .none:
                break
            case .group(let id):
                if groups[id] != nil { wanted[tab.id] = id }
            case .tab(let other):
                guard other != tab.id, fresh[other] != nil || loose[other] != nil else { continue }
                if parent[other] == nil { parent[other] = other }
                join(tab.id, other)
            }
        }
        for tab in ask.fresh {
            guard let from = openers[tab.id], from != tab.id, fresh[from] != nil || loose[from] != nil,
                  (picks[tab.id] ?? AIGroupPick.none) != AIGroupPick.none, (picks[from] ?? AIGroupPick.none) == AIGroupPick.none else { continue }
            if parent[from] == nil { parent[from] = from }
            join(tab.id, from)
        }
        var components: [UUID: [UUID]] = [:]
        var order: [UUID] = []
        for id in ask.fresh.map(\.id) + ask.loose.map(\.id) where parent[id] != nil {
            let top = root(id)
            if components[top] == nil { order.append(top) }
            components[top, default: []].append(id)
        }
        func tab(_ id: UUID) -> AIGroupTab? { fresh[id] ?? loose[id] }
        func splits(_ keys: [String]) -> Bool {
            dismissed.contains { set in keys.filter(set.contains).count >= 2 }
        }
        var out = AIGroupPlan()
        var holding = Dictionary(ask.groups.map { ($0.id, $0.members.map(\.key)) }, uniquingKeysWith: { one, _ in one })
        for top in order {
            let members = components[top] ?? []
            let target = members.compactMap { wanted[$0] }.first
            if let target, groups[target] != nil {
                for id in members {
                    guard let found = tab(id) else { continue }
                    let aim = wanted[id] ?? target
                    guard let aimed = groups[aim], !aimed.refused.contains(found.key) else { continue }
                    let keys = (holding[aim] ?? []) + [found.key]
                    guard !splits(keys) else { continue }
                    holding[aim] = keys
                    out.joins[id] = aim
                }
                continue
            }
            guard members.count >= 2, members.contains(where: { fresh[$0] != nil }) else { continue }
            let keys = members.compactMap { tab($0)?.key }
            guard !splits(keys) else { continue }
            out.formed.append(members)
        }
        return out
    }
}

enum AIGroupPrompt {
    struct Labels {
        var groups: [String: UUID] = [:]
        var tabs: [String: UUID] = [:]
        var fresh: [(label: String, tab: AIGroupTab)] = []

        func pick(_ said: String) -> AIGroupPick? {
            let word = said.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'."))).lowercased()
            if word.isEmpty || word == "none" || word == "loose" { return AIGroupPick.none }
            if let id = groups[word] { return .group(id) }
            if let id = tabs[word] { return .tab(id) }
            return nil
        }
    }

    static func labels(_ ask: AIGroupAsk) -> Labels {
        var out = Labels()
        for (index, group) in ask.groups.enumerated() { out.groups["g\(index + 1)"] = group.id }
        for (index, tab) in ask.loose.enumerated() { out.tabs["t\(index + 1)"] = tab.id }
        for (index, tab) in ask.fresh.enumerated() {
            out.tabs["n\(index + 1)"] = tab.id
            out.fresh.append(("n\(index + 1)", tab))
        }
        return out
    }

    static let deciding = """
    You tidy a web browser's tabs into groups, the way a person files them into folders. For each new tab, pick \
    the group it belongs in, or the tab it should be grouped with because both serve the same trip, project, \
    purchase or subject, or none. Different sites are fine when the subject is the same. Sharing only a website, \
    or only a kind of page such as two videos or two articles, is not a reason to group. Pick none for a tab \
    whose subject nothing else shares, and when in doubt: a wrong group is worse than no group.
    """

    static func deciding(_ ask: AIGroupAsk) -> String {
        var lines: [String] = []
        if !ask.groups.isEmpty {
            lines.append("Groups:")
            for (index, group) in ask.groups.enumerated() {
                let members = group.members.prefix(6).map(\.line).joined(separator: "; ")
                lines.append("g\(index + 1): \(group.name) — \(members)")
            }
        }
        if !ask.loose.isEmpty {
            lines.append("Tabs in no group:")
            for (index, tab) in ask.loose.enumerated() { lines.append("t\(index + 1): \(tab.line)") }
        }
        lines.append("New tabs:")
        for (index, tab) in ask.fresh.enumerated() { lines.append("n\(index + 1): \(tab.line)") }
        return lines.joined(separator: "\n")
    }

    static func jsonDeciding(_ ask: AIGroupAsk) -> String {
        deciding(ask) + "\n\nAnswer with JSON only: {\"placements\": [{\"tab\": \"n1\", \"with\": \"g1\"}]}, one entry for each new tab."
    }

    static let subject = """
    You name a folder of browser tabs after the subject its tabs share: the product, project, film, show, book, \
    place, trip, person or topic, as specific as still fits every tab. Say the subject, never words lifted from one \
    page title: pages called Kyoto Hotels, Kansai Rail Pass and Fushimi Inari Guide make Kyoto Trip, not Rail Pass, \
    and pages called Atlas Launch Plan, Atlas Copy Draft and Atlas Checklist make Atlas, not Copy Draft. Examples: \
    Maze Runner, Lisbon Trip, SwiftUI Layout, Бегущий в лабиринте.
    """

    static let format = """
    Rules: one to three words. Write it in the language most of the tab titles use. Use title case in English and \
    other languages that have it, and ordinary sentence case otherwise. Never copy a page title or the search. Never \
    only a site's name. No sentence and no punctuation. Leave out words about how to get it, such as watch online, \
    free, download, HD, in English, смотреть онлайн, бесплатно, скачать or на английском. Leave out a year unless two \
    things with the same name need telling apart. Never a generic word such as Travel, Tabs, Search, Videos or \
    Documentation on its own.
    """

    static let staying = """
    When the folder already has a name that still says what its tabs share, keep it, even if a new tab does not \
    repeat its words. Change it only when it has clearly stopped describing the tabs.
    """

    static func naming(emoji: Bool) -> String {
        [subject, format, staying].joined(separator: " ") + (emoji ? " Add one emoji that fits." : "")
    }

    static func remoteNaming(emoji: Bool) -> String {
        [subject, format, staying].joined(separator: " ") + (emoji ? " Add one emoji that fits." : "")
            + "\n\nAnswer with JSON only: {\"name\": \"…\", \"emoji\": \"…\", \"keep\": false}. Set keep to true to keep the current name."
    }

    static let filler: Set<String> = ["and", "the", "for", "with", "from", "into", "tabs", "your", "about", "our", "of", "to", "in", "on", "a", "an", "&"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !filler.contains($0) }
    }

    static func fits(_ name: String, _ tabs: [AIGroupTab]) -> Bool {
        let named = words(name)
        guard !named.isEmpty else { return false }
        return tabs.allSatisfy { tab in
            let said = (tab.title + " " + tab.host + " " + tab.path + " " + tab.by).lowercased()
            return named.contains { said.contains($0) }
        }
    }

    static func naming(_ ask: AIGroupNameAsk) -> String {
        var lines = ["Tabs:"] + ask.tabs.prefix(12).map { "- \($0.line)" + ($0.by.isEmpty ? "" : " — by \($0.by)") }
        let common = AIGroupEvidence.common(ask.tabs).prefix(3).map { AIGroupEvidence.written($0, in: ask.tabs) }
        if !common.isEmpty { lines.append("Every tab has: \(common.joined(separator: ", "))") }
        if let query = ask.query { lines.append("Searched for: \(query)") }
        lines.append("Current name: \(ask.current ?? "none")")
        if ask.emoji { lines.append("Current emoji: \(ask.currentEmoji ?? "none")") }
        for refused in ask.rejected { lines.append("Not allowed: \(refused)") }
        return lines.joined(separator: "\n")
    }

    static func remoteNaming(_ ask: AIGroupNameAsk) -> String {
        let tabs = ask.tabs.map(\.bare)
        var lines = ["Tabs:"] + tabs.prefix(12).map { "- \($0.remoteLine)" }
        let common = AIGroupEvidence.common(tabs).prefix(3).map { AIGroupEvidence.written($0, in: tabs) }
        if !common.isEmpty { lines.append("Every tab has: \(common.joined(separator: ", "))") }
        if let query = ask.query { lines.append("Searched for: \(query)") }
        lines.append("Current name: \(ask.current ?? "none")")
        if ask.emoji { lines.append("Current emoji: \(ask.currentEmoji ?? "none")") }
        for refused in ask.rejected { lines.append("Not allowed: \(refused)") }
        return lines.joined(separator: "\n")
    }

    static func jsonNaming(_ ask: AIGroupNameAsk) -> String {
        naming(ask) + "\n\nAnswer with JSON only: {\"name\": \"…\", \"emoji\": \"…\", \"keep\": false}. Set keep to true to keep the current name."
    }

    static func picks(_ said: [(tab: String, with: String)], labels: Labels) -> [UUID: AIGroupPick] {
        var out: [UUID: AIGroupPick] = [:]
        for (tab, with) in said {
            guard let id = labels.tabs[tab.trimmingCharacters(in: .whitespaces).lowercased()],
                  labels.fresh.contains(where: { $0.tab.id == id }) else { continue }
            out[id] = labels.pick(with) ?? AIGroupPick.none
        }
        return out
    }

    static func object(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let body = Data(text[start...end].utf8)
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func picks(json text: String, labels: Labels) -> [UUID: AIGroupPick]? {
        guard let found = object(in: text), let list = found["placements"] as? [[String: Any]] else { return nil }
        let said = list.compactMap { entry -> (String, String)? in
            guard let tab = entry["tab"] as? String else { return nil }
            return (tab, entry["with"] as? String ?? "none")
        }
        return picks(said.map { (tab: $0.0, with: $0.1) }, labels: labels)
    }

    static func name(json text: String) -> AIGroupName? {
        guard let found = object(in: text) else { return nil }
        return AIGroupName.cleaned(name: found["name"] as? String ?? "", emoji: found["emoji"] as? String,
                                   keep: found["keep"] as? Bool ?? false)
    }
}

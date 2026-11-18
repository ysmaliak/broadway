import Foundation

struct FileClicks: Equatable {
    static let within: TimeInterval = 30

    private var earned = 0
    private var earnedAt: TimeInterval = 0
    private var spent = 0
    private var spentAt: TimeInterval?

    mutating func clicked(_ interaction: Int, at now: TimeInterval) {
        guard interaction != earned else { return }
        earned = interaction
        earnedAt = now
    }

    mutating func take(at now: TimeInterval) -> Bool {
        guard earned > spent, now >= earnedAt, now - earnedAt <= Self.within else { return false }
        spent = earned
        spentAt = now
        return true
    }

    func spentLately(at now: TimeInterval) -> Bool {
        spentAt.map { now >= $0 && now - $0 <= Self.within } ?? false
    }

    mutating func committed() {
        spent = earned
    }
}

enum FileStart: Equatable {
    case page
    case typed
    case menu
    case broadway
}

struct FileFacts: Equatable {
    var start: FileStart
    var agent = false
    var clicked = false
    var url: URL
    var pageSecure = false
}

enum FileVerdict: Equatable {
    case go
    case drop
    case askSite
    case askInsecure
}

enum SiteFiles {
    static func local(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return Address.isLocal(host: host) || Address.isLocal(host: "[\(host)]") || Hosts.isLoopback(host)
    }

    static func insecure(_ facts: FileFacts, local: (String) -> Bool = SiteFiles.local) -> Bool {
        guard facts.start == .page, facts.pageSecure, facts.url.scheme?.lowercased() == "http",
              let host = facts.url.host(percentEncoded: false), !host.isEmpty else { return false }
        return !local(host)
    }

    static func asked(_ facts: FileFacts) -> Bool {
        facts.agent || facts.start != .page || facts.clicked
    }

    static func verdict(_ facts: FileFacts, kept: Bool?, local: (String) -> Bool = SiteFiles.local) -> FileVerdict {
        if facts.agent || facts.start == .broadway || facts.url.isFileURL { return .go }
        let asked = asked(facts)
        if !asked, kept == false { return .drop }
        if insecure(facts, local: local) { return .askInsecure }
        if asked || kept == true { return .go }
        return .askSite
    }
}

struct SiteFileAnswers {
    private var kept: [String: Bool] = [:]

    private static func key(_ site: String, _ store: String) -> String { store + " " + site.lowercased() }

    func answer(site: String, store: String) -> Bool? { kept[Self.key(site, store)] }

    mutating func keep(_ allowed: Bool, site: String, store: String) { kept[Self.key(site, store)] = allowed }

    mutating func forget(store: String) { kept = kept.filter { !$0.key.hasPrefix(store + " ") } }

    var count: Int { kept.count }
}

struct FileCard: Equatable, Identifiable {
    enum Kind: Equatable {
        case site
        case insecure
    }

    let id: UUID
    let kind: Kind
    let site: String
    let host: String
    private(set) var names: [String]
    private(set) var files: [UUID]
    private(set) var more: Bool

    init(id: UUID = UUID(), kind: Kind, site: String, host: String, name: String, file: UUID, more: Bool) {
        self.id = id
        self.kind = kind
        self.site = site
        self.host = host
        names = [name]
        files = [file]
        self.more = more
    }

    mutating func join(_ file: UUID, name: String) {
        files.append(file)
        names.append(name)
        more = true
    }

    var title: String {
        switch kind {
        case .insecure: return "This file is not sent securely"
        case .site: return more ? "\u{201C}\(site)\u{201D} wants to download more files" : "\u{201C}\(site)\u{201D} wants to download a file"
        }
    }

    var text: String? {
        switch kind {
        case .insecure: return "\u{201C}\(names.first ?? "")\u{201D} from \u{201C}\(host)\u{201D} could be read or changed on the way"
        case .site: return more ? nil : names.first
        }
    }

    var allow: String { kind == .insecure ? "Download Anyway" : "Allow" }
    var deny: String { kind == .insecure ? "Don't Download" : "Don't Allow" }
}

struct FileCards: Equatable {
    private(set) var cards: [FileCard] = []

    var front: FileCard? { cards.first }
    var isEmpty: Bool { cards.isEmpty }

    @discardableResult
    mutating func add(_ verdict: FileVerdict, file: UUID, name: String, site: String, host: String, more: Bool) -> UUID? {
        switch verdict {
        case .askSite:
            if let index = cards.firstIndex(where: { $0.kind == .site && $0.site == site }) {
                cards[index].join(file, name: name)
                return cards[index].id
            }
            let card = FileCard(kind: .site, site: site, host: host, name: name, file: file, more: more)
            cards.append(card)
            return card.id
        case .askInsecure:
            let card = FileCard(kind: .insecure, site: site, host: host, name: name, file: file, more: false)
            cards.append(card)
            return card.id
        case .go, .drop:
            return nil
        }
    }

    mutating func answer(_ id: UUID) -> FileCard? {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return nil }
        return cards.remove(at: index)
    }

    mutating func leave(_ file: UUID) -> FileCard? {
        guard let index = cards.firstIndex(where: { $0.files.contains(file) }) else { return nil }
        let card = cards[index]
        guard card.files.count == 1 else {
            cards[index] = cards[index].dropping(file)
            return nil
        }
        cards.remove(at: index)
        return card
    }

    mutating func clear() -> [FileCard] {
        defer { cards = [] }
        return cards
    }
}

private extension FileCard {
    func dropping(_ file: UUID) -> FileCard {
        var card = self
        if let index = card.files.firstIndex(of: file) {
            card.files.remove(at: index)
            card.names.remove(at: index)
        }
        return card
    }
}

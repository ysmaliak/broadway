import Foundation

struct LinkRule: Codable, Identifiable, Equatable, Hashable {
    enum Match: Codable, Equatable, Hashable {
        case site(String)
        case host(String)
        case starts(String)
        case contains(String)
        case pattern(String)
        case regex(String)

        enum Kind: String, CaseIterable {
            case site, host, starts, contains, pattern, regex
        }

        var kind: Kind {
            switch self {
            case .site: .site
            case .host: .host
            case .starts: .starts
            case .contains: .contains
            case .pattern: .pattern
            case .regex: .regex
            }
        }

        var text: String {
            switch self {
            case .site(let text), .host(let text), .starts(let text), .contains(let text), .pattern(let text), .regex(let text): text
            }
        }

        static func make(_ kind: Kind, _ text: String) -> Match {
            switch kind {
            case .site: .site(text)
            case .host: .host(text)
            case .starts: .starts(text)
            case .contains: .contains(text)
            case .pattern: .pattern(text)
            case .regex: .regex(text)
            }
        }
    }

    enum From: Codable, Equatable, Hashable {
        case anywhere
        case otherApps
        case app(bundleID: String, name: String)
        case insideBroadway
    }

    enum Target: Codable, Equatable, Hashable {
        case space(UUID, folder: UUID?)
        case frontSpace
        case whereOpen
        case window(UUID?)
        case peek
        case app(bundleID: String, name: String)
        case ask
    }

    struct Rewrite: Codable, Equatable, Hashable {
        var find: String
        var replace: String
    }

    var id = UUID()
    var on = true
    var match: Match
    var from: From = .anywhere
    var target: Target
    var background = false
    var rewrite: Rewrite?
    var made = Date()
    var note = ""

    init(id: UUID = UUID(), on: Bool = true, match: Match, from: From = .anywhere, target: Target, background: Bool = false,
         rewrite: Rewrite? = nil, made: Date = Date(), note: String = "") {
        self.id = id
        self.on = on
        self.match = match
        self.from = from
        self.target = target
        self.background = background
        self.rewrite = rewrite
        self.made = made
        self.note = note
    }

    private enum Keys: String, CodingKey {
        case id, on, match, from, target, background, rewrite, made, note
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        id = try box.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        on = try box.decodeIfPresent(Bool.self, forKey: .on) ?? true
        match = try box.decode(Match.self, forKey: .match)
        from = (try? box.decodeIfPresent(From.self, forKey: .from)) ?? .anywhere
        target = try box.decode(Target.self, forKey: .target)
        background = try box.decodeIfPresent(Bool.self, forKey: .background) ?? false
        rewrite = try? box.decodeIfPresent(Rewrite.self, forKey: .rewrite)
        made = try box.decodeIfPresent(Date.self, forKey: .made) ?? Date()
        note = try box.decodeIfPresent(String.self, forKey: .note) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: Keys.self)
        try box.encode(id, forKey: .id)
        try box.encode(on, forKey: .on)
        try box.encode(match, forKey: .match)
        try box.encode(from, forKey: .from)
        try box.encode(target, forKey: .target)
        try box.encode(background, forKey: .background)
        try box.encodeIfPresent(rewrite, forKey: .rewrite)
        try box.encode(made, forKey: .made)
        try box.encode(note, forKey: .note)
    }
}

struct LinkSettings: Codable, Equatable {
    enum Outside: Codable, Equatable, Hashable {
        case front
        case space(UUID)
        case ask
    }

    var outsideDefault: Outside = .front
    var chooseKey = true
    var cleansLinks = true
    var unwrapsLinks = true
    var goesToOpenTab = false
    var goesToLiveRow = true

    init() {}

    private enum Keys: String, CodingKey {
        case outsideDefault, chooseKey, cleansLinks, unwrapsLinks, goesToOpenTab, goesToLiveRow
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: Keys.self)
        outsideDefault = (try? box.decodeIfPresent(Outside.self, forKey: .outsideDefault)) ?? .front
        chooseKey = try box.decodeIfPresent(Bool.self, forKey: .chooseKey) ?? true
        cleansLinks = try box.decodeIfPresent(Bool.self, forKey: .cleansLinks) ?? true
        unwrapsLinks = try box.decodeIfPresent(Bool.self, forKey: .unwrapsLinks) ?? true
        goesToOpenTab = try box.decodeIfPresent(Bool.self, forKey: .goesToOpenTab) ?? false
        goesToLiveRow = try box.decodeIfPresent(Bool.self, forKey: .goesToLiveRow) ?? true
    }
}

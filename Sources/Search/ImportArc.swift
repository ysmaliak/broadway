import AppKit

// Arc's sidebar, read: its spaces and what is pinned in each, and the
// favourites above them. Arc keeps them in one plain JSON file beside its
// profiles, StorableSidebar.json — no key, no keychain, nothing signed in.
// This only reads it and says what is there; the import sheet makes the
// spaces and pins (see ImportPanel).
//
// The file keeps everything in flat lists of an id followed by its object:
// spaces, and items — a tab, a folder ("list"), or a container of items —
// joined by parentID and childrenIds. A space names its containers the same
// way, a label followed by an id: the "pinned" one is what we take; the
// "unpinned" one is Arc's Today, which lives a day and is left behind.
//
// Read as damaged files are: a folder is taken once and no deeper than 64,
// only http and https addresses come, a password in one is dropped, and a
// file larger than any real sidebar isn't read at all.

struct ArcSidebar: Equatable {
    struct Item: Equatable { var title: String; var url: URL }
    struct Folder: Equatable { var title: String; var items: [Node] }
    indirect enum Node: Equatable { case item(Item), folder(Folder) }
    struct Space: Equatable {
        var name: String
        /// Arc's own, kept for the day it is wanted as it was.
        var emoji: String?
        /// One of Spaces.icons, from Arc.symbol(emoji:name:).
        var symbol: String
        /// The Chromium profile folder the space signs in with: "Default",
        /// or another's ("Profile 1"), which is a space with sign-ins of
        /// its own.
        var profile: String
        /// In Arc's order, folders kept as folders.
        var pinned: [Node]
        var id: String? = nil
        var colours: [String] = []
    }
    /// The icons at the top, shared by every space of their profile.
    var favorites: [Item]
    /// The same, by the profile they belong to ("Default", "Profile 1"),
    /// for giving each space only its own profile's.
    var favoritesByProfile: [String: [Item]] = [:]
    var spaces: [Space]

    var pinnedCount: Int { spaces.reduce(0) { $0 + Arc.count($1.pinned) } }
}

struct ArcRouting: Equatable {
    enum Kind: Equatable { case contains, equals }

    struct Rule: Equatable {
        var kind: Kind
        var text: String
        var space: String
    }

    var rules: [Rule]
    var leftOut: Int
}

enum Arc {
    /// Beside Arc's profiles, under Chromium.base: a test run reads a
    /// made-up one from its own folder.
    static var file: URL {
        Chromium.base.appendingPathComponent("Arc/StorableSidebar.json")
    }

    static var routingFile: URL {
        Chromium.base.appendingPathComponent("Arc/StorableLinkRouting.json")
    }

    static func routing() -> ArcRouting? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: routingFile.path))?[.size] as? NSNumber,
              size.intValue <= 8 << 20,
              let data = try? Data(contentsOf: routingFile)
        else { return nil }
        return parse(routing: data)
    }

    static func parse(routing data: Data) -> ArcRouting? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["rules"] as? [Any]
        else { return nil }
        var rules: [ArcRouting.Rule] = []
        var leftOut = 0
        for entry in list where !(entry is String) {
            guard rules.count + leftOut < 5000 else { break }
            if let rule = rule(entry) { rules.append(rule) } else { leftOut += 1 }
        }
        return ArcRouting(rules: rules, leftOut: leftOut)
    }

    private static func rule(_ entry: Any) -> ArcRouting.Rule? {
        guard let rule = entry as? [String: Any],
              let conditions = rule["sourceComponents"] as? [Any], conditions.count == 1,
              let type = (conditions[0] as? [String: Any])?["componentType"] as? [String: Any],
              let match = type["urlMatch"] as? [String: Any],
              let kind = kind(match["_0"]),
              let text = named(match["_1"] as? String),
              let space = destination(rule["destination"])
        else { return nil }
        return ArcRouting.Rule(kind: kind, text: text, space: space)
    }

    private static func kind(_ value: Any?) -> ArcRouting.Kind? {
        let name: String
        if let text = value as? String {
            name = text
        } else if let box = value as? [String: Any], box.count == 1, let only = box.keys.first {
            name = only
        } else {
            return nil
        }
        let plain = String(name.lowercased().filter(\.isLetter))
        if plain == "contains" || plain == "contain" { return .contains }
        let equal: Set<String> = ["is", "equals", "equal", "equalto", "isequal", "isequalto", "exact", "exactly", "exactmatch", "same"]
        return equal.contains(plain) ? .equals : nil
    }

    private static func destination(_ value: Any?) -> String? {
        guard let box = value as? [String: Any],
              let outer = (box["space"] as? [String: Any])?["_0"] as? [String: Any]
        else { return nil }
        if let text = outer["space"] as? String { return named(text) }
        return named((outer["space"] as? [String: Any])?["_0"] as? String)
    }

    static func match(_ text: String) -> LinkRule.Match? {
        let bare = LinkRouter.anchored(text)
        guard !bare.isEmpty else { return nil }
        let host = bare.hasSuffix("/") ? String(bare.dropLast()) : bare
        let plainHost = !host.isEmpty && host.contains(".") && !host.contains(where: { "/?#:@ ".contains($0) })
        if plainHost, let site = LinkRouter.site(typed: host) {
            return site == host ? .site(host) : .host(host)
        }
        return .contains(bare)
    }

    static func linkRules(_ routing: ArcRouting, spaces: [String: UUID], have: [LinkRule], made: Date = Date())
        -> (rules: [LinkRule], leftOut: Int) {
        struct Key: Hashable {
            var kind: LinkRule.Match.Kind
            var text: String
            var target: LinkRule.Target
        }
        func key(_ rule: LinkRule) -> Key { Key(kind: rule.match.kind, text: rule.match.text.lowercased(), target: rule.target) }
        let byID = Dictionary(spaces.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        var seen = Set(have.map(key))
        var rules: [LinkRule] = []
        var leftOut = routing.leftOut
        for arc in routing.rules {
            guard let space = byID[arc.space.lowercased()], let match = match(arc.text) else {
                leftOut += 1
                continue
            }
            let rule = LinkRule(match: match, from: .otherApps, target: .space(space, folder: nil), made: made)
            guard seen.insert(key(rule)).inserted else { continue }
            rules.append(rule)
        }
        return (rules, leftOut)
    }

    /// Arc's sidebar for one profile ("Default", "Profile 1"), or for every
    /// one when nil. Nil when there is no file or it doesn't read.
    static func sidebar(profile: String?) -> ArcSidebar? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber,
              size.intValue <= 32 << 20,
              let data = try? Data(contentsOf: file)
        else { return nil }
        return parse(data, profile: profile)
    }

    /// How many spaces and pinned things there are, for the sheet's counts.
    static func counts(profile: String?) -> (spaces: Int, pinned: Int)? {
        sidebar(profile: profile).map { ($0.spaces.count, $0.pinnedCount + $0.favorites.count) }
    }

    static func parse(_ data: Data, profile wanted: String?) -> ArcSidebar? {
        guard let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (top["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = containers.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil })
        else { return nil }

        var items: [String: [String: Any]] = [:]
        for case let item as [String: Any] in (main["items"] as? [Any]) ?? [] {
            if let id = item["id"] as? String { items[id] = item }
        }
        let inProfile = { (name: String) in wanted == nil || wanted == name }

        // What a container or folder holds, in order: each item once, no
        // more than 64 folders down and 5000 things in all.
        var taken = Set<String>()
        var total = 0
        func nodes(under id: String, depth: Int) -> [ArcSidebar.Node] {
            guard depth < 64, let children = items[id]?["childrenIds"] as? [Any] else { return [] }
            return children.compactMap { child -> ArcSidebar.Node? in
                guard let childID = child as? String, total < 5000,
                      taken.insert(childID).inserted, let item = items[childID],
                      let data = item["data"] as? [String: Any]
                else { return nil }
                if let tab = data["tab"] as? [String: Any] {
                    guard let url = page(tab["savedURL"] as? String) else { return nil }
                    total += 1
                    let title = named(item["title"] as? String) ?? named(tab["savedTitle"] as? String) ?? url.host() ?? url.absoluteString
                    return .item(.init(title: title, url: url))
                }
                if data["list"] != nil {
                    let inside = nodes(under: childID, depth: depth + 1)
                    guard !inside.isEmpty else { return nil }
                    return .folder(.init(title: named(item["title"] as? String) ?? "Folder", items: inside))
                }
                return nil
            }
        }

        var spaces: [ArcSidebar.Space] = []
        var lastID: String?
        for entry in (main["spaces"] as? [Any]) ?? [] {
            if let text = entry as? String {
                lastID = text
                continue
            }
            let before = lastID
            lastID = nil
            guard let space = entry as? [String: Any] else { continue }
            let profile = profileName(space["profile"])
            guard inProfile(profile) else { continue }
            let name = named(space["title"] as? String) ?? "Space"
            let info = space["customInfo"] as? [String: Any]
            let emoji = (info?["iconType"] as? [String: Any])?["emoji_v2"] as? String
            let pinned = container("pinned", in: space["newContainerIDs"] as? [Any])
                ?? container("pinned", in: space["containerIDs"] as? [Any])
            spaces.append(.init(name: name, emoji: emoji, symbol: symbol(emoji: emoji, name: name), profile: profile,
                                pinned: pinned.map { nodes(under: $0, depth: 0) } ?? [],
                                id: named(space["id"] as? String) ?? named(before), colours: colours(info?["windowTheme"])))
        }

        // The favourites: a profile followed by its container's id.
        var favorites: [ArcSidebar.Item] = []
        var byProfile: [String: [ArcSidebar.Item]] = [:]
        let tops = (main["topAppsContainerIDs"] as? [Any]) ?? []
        for (index, entry) in tops.enumerated() where !(entry is String) {
            let profile = profileName(entry)
            guard index + 1 < tops.count, let id = tops[index + 1] as? String, inProfile(profile) else { continue }
            for node in nodes(under: id, depth: 0) {
                if case .item(let item) = node {
                    favorites.append(item)
                    byProfile[profile, default: []].append(item)
                }
            }
        }
        return ArcSidebar(favorites: favorites, favoritesByProfile: byProfile, spaces: spaces)
    }

    /// The id after `label` in a space's list of containers. Arc has written
    /// the label as a string and, lately, as an object keyed by it.
    private static func container(_ label: String, in list: [Any]?) -> String? {
        guard let list else { return nil }
        for (index, entry) in list.enumerated() where index + 1 < list.count {
            let matches = (entry as? String) == label || (entry as? [String: Any])?[label] != nil
            if matches, let id = list[index + 1] as? String { return id }
        }
        return nil
    }

    /// "Default", or the folder of the profile a space or favourites belong
    /// to: {"default": {}} or {"custom": {"_0": {"directoryBasename": …}}}.
    private static func profileName(_ value: Any?) -> String {
        guard let custom = (value as? [String: Any])?["custom"] as? [String: Any] else { return "Default" }
        let inner = (custom["_0"] as? [String: Any]) ?? custom
        return (inner["directoryBasename"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Default"
    }

    /// A web address, with any password in it left behind.
    private static func page(_ text: String?) -> URL? {
        guard let text, var parts = URLComponents(string: text),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return nil }
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    private static func named(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(300))
    }

    static func colours(_ value: Any?) -> [String] {
        guard let theme = value as? [String: Any] else { return [] }
        let rest = theme.filter { !$0.key.lowercased().contains("palette") }
        let found = stops(in: rest, depth: 0) ?? []
        if found.count > 1 { return found }
        if let mid = colour((theme["primaryColorPalette"] as? [String: Any])?["midTone"], depth: 0) { return [mid] }
        return found
    }

    private static func stops(in value: Any, depth: Int) -> [String]? {
        guard depth < 12 else { return nil }
        if let list = value as? [Any] {
            let found = list.compactMap { colour($0, depth: 0) }
            if found.count > 1 { return found }
            var one: [String]?
            for item in list {
                guard let inner = stops(in: item, depth: depth + 1) else { continue }
                if inner.count > 1 { return inner }
                one = one ?? inner
            }
            return one ?? (found.isEmpty ? nil : found)
        }
        guard let box = value as? [String: Any] else { return nil }
        if box["red"] != nil, let single = colour(box, depth: 0) { return [single] }
        var one: [String]?
        for key in box.keys.sorted() {
            guard let inner = stops(in: box[key] as Any, depth: depth + 1) else { continue }
            if inner.count > 1 { return inner }
            one = one ?? inner
        }
        return one
    }

    static func colour(_ value: Any?, depth: Int) -> String? {
        guard depth < 4, let box = value as? [String: Any] else { return nil }
        if let red = unit(box["red"]), let green = unit(box["green"]), let blue = unit(box["blue"]) {
            let space = ((box["colorSpace"] ?? box["colourSpace"]) as? String)?.lowercased() ?? ""
            let made = space.contains("p3")
                ? NSColor(displayP3Red: red, green: green, blue: blue, alpha: 1)
                : NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
            return made.code
        }
        for key in ["color", "colour", "_0"] {
            if let inner = colour(box[key], depth: depth + 1) { return inner }
        }
        return nil
    }

    private static func unit(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return CGFloat(min(1, max(0, double)))
    }

    static func count(_ nodes: [ArcSidebar.Node]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .item: return total + 1
            case .folder(let folder): return total + count(folder.items)
            }
        }
    }

    // MARK: - the space's picture

    /// Arc's emoji as the nearest of Search's space pictures (Spaces.icons),
    /// then the space's name, then a briefcase. The one table for both.
    static func symbol(emoji: String?, name: String) -> String {
        known(emoji: emoji, name: name) ?? "briefcase"
    }

    static func known(emoji: String?, name: String) -> String? {
        if let emoji {
            // The same emoji with or without the mark asking for its
            // coloured form (U+FE0F), which Arc writes on some.
            let bare = String(String.UnicodeScalarView(emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
            for (symbol, emojis) in byEmoji where emojis.contains(bare) { return symbol }
        }
        // Whole words, or the start of one for the longer keys: "ai" is a
        // word here, not the middle of "maison".
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for (symbol, keys) in byWord
        where keys.contains(where: { key in words.contains { $0 == key || (key.count >= 4 && $0.hasPrefix(key)) } }) {
            return symbol
        }
        return nil
    }

    private static let byEmoji: [(String, [String])] = [
        ("briefcase", ["💼", "👔", "📊", "📈", "🗂"]),
        ("building.2", ["🏢", "🏛", "🏙"]),
        ("house", ["🏠", "🏡", "🛋"]),
        ("desktopcomputer", ["🖥"]),
        ("laptopcomputer", ["💻"]),
        ("terminal", ["⌨", "🧑‍💻", "👨‍💻", "👩‍💻"]),
        ("chevron.left.forwardslash.chevron.right", ["🧑‍🔧", "🛠", "🔧", "⚙"]),
        ("sparkles", ["✨", "🤖", "🪄", "⭐", "🌟"]),
        ("brain.head.profile", ["🧠"]),
        ("lightbulb", ["💡"]),
        ("gamecontroller", ["🎮", "🕹", "👾"]),
        ("beach.umbrella", ["🏖", "🌴", "⛱", "🏝"]),
        ("cup.and.saucer", ["☕", "🍵", "🫖"]),
        ("music.note", ["🎵", "🎶", "🎧", "🎸", "🎹"]),
        ("film", ["🎬", "🍿", "📺", "🎥"]),
        ("paintpalette", ["🎨", "🖌", "🖍", "✏"]),
        ("camera", ["📷", "📸"]),
        ("book", ["📚", "📖", "📕", "📘", "📰"]),
        ("graduationcap", ["🎓", "🏫", "✍"]),
        ("cart", ["🛒", "🛍", "💸", "💰", "💳"]),
        ("airplane", ["✈", "🧳", "🌍", "🌎", "🌏", "🗺"]),
        ("dumbbell", ["🏋", "💪", "🏃", "⚽", "🏀"]),
        ("leaf", ["🌿", "🌱", "🍃", "🦋", "🌸", "🌳"]),
        ("heart", ["❤", "💖", "💕", "🥰", "😍"]),
    ]

    private static let byWord: [(String, [String])] = [
        ("briefcase", ["work", "job", "office", "boulot", "travail", "client"]),
        ("house", ["home", "perso", "personal", "maison", "family", "famille"]),
        ("chevron.left.forwardslash.chevron.right", ["code", "dev", "github", "eng"]),
        ("sparkles", ["ai", "gpt", "claude", "llm"]),
        ("graduationcap", ["school", "study", "studies", "course", "cours", "uni", "école"]),
        ("book", ["read", "lecture", "news", "research"]),
        ("paintpalette", ["design", "art", "creative", "figma"]),
        ("music.note", ["music", "musique"]),
        ("gamecontroller", ["game", "gaming", "jeu"]),
        ("cart", ["shop", "achat", "money", "finance"]),
        ("airplane", ["travel", "trip", "voyage"]),
        ("dumbbell", ["sport", "gym", "fitness"]),
        ("film", ["film", "movie", "video", "watch"]),
    ]
}

extension ImportSource {
    /// Arc's spaces and pins, nil for any other browser.
    func arcSidebar(profile: String?) -> ArcSidebar? {
        guard case .chromium(let source) = self, source.name == "Arc" else { return nil }
        return Arc.sidebar(profile: profile)
    }

    func arcRouting() -> ArcRouting? {
        guard case .chromium(let source) = self, source.name == "Arc" else { return nil }
        return Arc.routing()
    }

    func arcCounts(profile: String?) -> (spaces: Int, pinned: Int)? {
        guard case .chromium(let source) = self, source.name == "Arc" else { return nil }
        return Arc.counts(profile: profile)
    }
}

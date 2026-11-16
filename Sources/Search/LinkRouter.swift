import Foundation

struct IncomingLink: Equatable {
    enum Source: Equatable, Hashable {
        case app(bundleID: String, name: String)
        case unknownApp
        case page(space: UUID, site: String?)

        var outside: Bool {
            if case .page = self { return false }
            return true
        }

        var space: UUID? {
            if case .page(let space, _) = self { return space }
            return nil
        }
    }

    struct Seat: Equatable {
        var kind: LiveSource.Kind
        var key: String
    }

    var url: URL
    var source: Source
    var chooses = false
    var behind = false
    var seats: [Seat] = []
}

struct LinkWorld: Equatable {
    struct Folder: Equatable {
        var id: UUID
        var name: String
    }

    struct Space: Equatable {
        var id: UUID
        var name: String
        var folders: [Folder] = []
    }

    struct Row: Equatable {
        var folder: UUID
        var name: String
        var space: UUID
        var kind: LiveSource.Kind
        var key: String
    }

    var spaces: [Space] = []
    var rows: [Row] = []
    var front: UUID?
    var usesSpaces = true
    var open: [String: [UUID]] = [:]
    var tabs: [UUID: [String: UUID]] = [:]
    var windows: [UUID] = []
    var apps: Set<String> = []
    var broadway = ""

    func space(_ id: UUID) -> Space? { spaces.first { $0.id == id } }

    func name(of space: UUID) -> String { self.space(space)?.name ?? "a space that's gone" }
}

struct LinkDecision: Equatable {
    enum Place: Equatable, Hashable {
        case here
        case space(UUID, folder: UUID?)
        case window(UUID?)
        case peek
        case app(bundleID: String, name: String)
        case ask
        case tab(UUID, space: UUID)
        case row(String, folder: UUID, space: UUID)

        var leaves: Bool {
            if case .app = self { return true }
            return false
        }
    }

    var url: URL
    var place: Place
    var rule: UUID?
    var steps: [String]
    var background: Bool
}

enum LinkRouter {
    static func decide(_ link: IncomingLink, rules: [LinkRule], settings: LinkSettings, world: LinkWorld) -> LinkDecision {
        var steps: [String] = []
        var url = link.url
        let outside = link.source.outside
        if outside {
            if settings.unwrapsLinks {
                for _ in 0..<3 {
                    guard let (inner, name) = LinkUnwrap.unwrap(url) else { break }
                    url = inner
                    steps.append("Unwrapped \(name) redirect")
                }
            }
            if settings.cleansLinks {
                let clean = CleanLink.clean(url)
                if clean != url {
                    url = clean
                    steps.append("Took the tracking parameters off")
                }
            }
        }
        let here = outside ? world.front : link.source.space
        if outside, link.chooses, settings.chooseKey {
            if settings.goesToLiveRow {
                var unheld = link
                unheld.chooses = false
                var usual = decide(unheld, rules: rules, settings: settings, world: world)
                if case .row = usual.place {
                    usual.steps.insert("⌥ was held, but a live folder has it, so you aren't asked", at: max(usual.steps.count - 1, 0))
                    return usual
                }
            }
            steps.append("⌥ was held, so you choose")
            steps.append(words(.ask, world: world))
            return LinkDecision(url: url, place: .ask, rule: nil, steps: steps, background: false)
        }
        for (index, rule) in rules.enumerated() where rule.on {
            guard accepts(rule.from, link.source), matches(rule.match, url) else { continue }
            let number = index + 1
            steps.append("Matched rule \(number): \(words(rule.match))")
            var going = url
            if let rewrite = rule.rewrite {
                if let changed = rewritten(url, by: rewrite) {
                    if changed != url {
                        going = changed
                        steps.append("Changed the address to \(changed.absoluteString)")
                    }
                } else {
                    steps.append("The address change gave no web address, so the address stays")
                }
            }
            switch resolve(rule.target, url: going, here: here, outside: outside, world: world) {
            case .gone(let why):
                steps.append("\(why). Trying the next rule.")
                continue
            case .place(let place, let said):
                if let said { steps.append(said) }
                return finish(LinkDecision(url: going, place: place, rule: rule.id, steps: steps, background: rule.background || link.behind),
                              link: link, here: here, settings: settings, world: world)
            }
        }
        var place = LinkDecision.Place.here
        if outside {
            if rules.contains(where: \.on) { steps.append("No rule matched") }
            switch settings.outsideDefault {
            case .front:
                break
            case .space(let id):
                if !world.usesSpaces {
                    steps.append("Spaces are off, so it opened where you are")
                } else if world.space(id) == nil {
                    steps.append("The space links go to no longer exists, so it opened where you are")
                } else if id != here {
                    place = .space(id, folder: nil)
                }
            case .ask:
                place = .ask
            }
        }
        return finish(LinkDecision(url: url, place: place, rule: nil, steps: steps, background: link.behind),
                      link: link, here: here, settings: settings, world: world)
    }

    private static func finish(_ decision: LinkDecision, link: IncomingLink, here: UUID?, settings: LinkSettings, world: LinkWorld) -> LinkDecision {
        var decision = decision
        let outside = link.source.outside
        let seated = link.seats.contains { LiveLinks.same(decision.url, as: $0.key, in: $0.kind) }
        if settings.goesToLiveRow, seated, !decision.place.leaves {
            decision.steps.append("You're on its row, so it gets a tab of its own")
        }
        if settings.goesToLiveRow, !seated, !decision.place.leaves,
           let row = row(for: decision.url, toward: decision.place, here: here, world: world) {
            var said = "Already in \(row.name)"
            if world.usesSpaces, world.spaces.count > 1, row.space != here { said += " in \(world.name(of: row.space))" }
            if decision.rule != nil { said += ", so the rule doesn't move it" }
            decision.steps.append(said)
            decision.place = .row(row.key, folder: row.folder, space: row.space)
            decision.rule = nil
            decision.steps.append(decision.background ? "Its row goes there in the background" : "Shown there")
            return decision
        }
        if outside, settings.goesToOpenTab {
            let space: UUID? = switch decision.place {
            case .here: here
            case .space(let id, _): id
            default: nil
            }
            if let space, let tab = world.tabs[space]?[key(of: decision.url)] {
                decision.place = .tab(tab, space: space)
                decision.steps.append("That page is already open there")
            }
        }
        decision.steps.append(words(decision.place, world: world, outside: outside))
        return decision
    }

    static func row(for url: URL, toward place: LinkDecision.Place, here: UUID?, world: LinkWorld) -> LinkWorld.Row? {
        guard !world.rows.isEmpty else { return nil }
        var asked: [LiveSource.Kind: String] = [:]
        for kind in Set(world.rows.map(\.kind)) { asked[kind] = LiveLinks.thing(url, in: kind) }
        let found = world.rows.filter { row in
            guard let wanted = asked[row.kind], let kept = URL(string: row.key) else { return false }
            return LiveLinks.thing(kept, in: row.kind) == wanted
        }
        if let front = found.first(where: { $0.space == here }) { return front }
        if case .space(let named, _) = place, let ruled = found.first(where: { $0.space == named }) { return ruled }
        return found.first
    }

    private enum Resolved {
        case place(LinkDecision.Place, String?)
        case gone(String)
    }

    private static func resolve(_ target: LinkRule.Target, url: URL, here: UUID?, outside: Bool, world: LinkWorld) -> Resolved {
        switch target {
        case .space(let id, let folder):
            guard world.usesSpaces else { return .gone("Spaces are off") }
            guard let space = world.space(id) else { return .gone("Its space no longer exists") }
            var kept = folder
            var said: String?
            if let folder, !space.folders.contains(where: { $0.id == folder }) {
                kept = nil
                said = "Its folder is gone, so it opened loose in \(space.name)"
            }
            if id == here, kept == nil { return .place(.here, said ?? "Already going there") }
            return .place(.space(id, folder: kept), said)
        case .frontSpace:
            return .place(.here, nil)
        case .whereOpen:
            guard world.usesSpaces, let site = site(of: url),
                  let first = world.open[site]?.first(where: { world.space($0) != nil }) else {
                return .place(.here, "Not open in any space, so it opened where you are")
            }
            return .place(first == here ? .here : .space(first, folder: nil), nil)
        case .window(let id):
            guard let id else { return .place(.window(nil), nil) }
            guard world.windows.contains(id) else { return .gone("Its window is closed") }
            return .place(.window(id), nil)
        case .peek:
            return .place(.peek, nil)
        case .app(let bundle, let name):
            guard bundle.lowercased() != world.broadway.lowercased() else { return .gone("A rule can't send links to Broadway itself") }
            guard world.apps.contains(bundle) else { return .gone("\(name) isn't installed") }
            return .place(.app(bundleID: bundle, name: name), nil)
        case .ask:
            return .place(.ask, nil)
        }
    }

    static func accepts(_ from: LinkRule.From, _ source: IncomingLink.Source) -> Bool {
        switch (from, source) {
        case (.anywhere, _): true
        case (.otherApps, .app), (.otherApps, .unknownApp): true
        case (.app(let wanted, _), .app(let bundle, _)): wanted.lowercased() == bundle.lowercased()
        case (.insideBroadway, .page): true
        default: false
        }
    }

    static func matches(_ match: LinkRule.Match, _ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host()?.lowercased(), !host.isEmpty else { return false }
        switch match {
        case .site(let typed):
            let site = plainSite(typed)
            guard !site.isEmpty else { return false }
            return host == site || host.hasSuffix("." + site)
        case .host(let typed):
            let wanted = plainSite(typed, keepsWWW: true)
            return !wanted.isEmpty && host == wanted
        case .starts(let typed):
            let wanted = anchored(typed)
            guard !wanted.isEmpty, let text = bare(url) else { return false }
            return text.hasPrefix(wanted)
        case .contains(let typed):
            let wanted = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty, let text = bare(url) else { return false }
            return text.contains(wanted)
        case .pattern(let typed):
            guard let expression = wildcard(anchored(typed)), let text = bare(url) else { return false }
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        case .regex(let typed):
            guard let expression = regex(typed) else { return false }
            let text = url.absoluteString
            return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
    }

    static func bare(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        var text = withoutWWW(host)
        if let port = parts.port { text += ":\(port)" }
        text += parts.percentEncodedPath
        if let query = parts.percentEncodedQuery { text += "?" + query }
        if let fragment = parts.percentEncodedFragment { text += "#" + fragment }
        return text
    }

    static func anchored(_ typed: String) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        let cut = text.firstIndex { "/?#".contains($0) } ?? text.endIndex
        let head = withoutWWW(text[..<cut].lowercased())
        return head + text[cut...]
    }

    static func plainSite(_ typed: String, keepsWWW: Bool = false) -> String {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if let cut = text.firstIndex(where: { "/?#:".contains($0) }) { text = String(text[..<cut]) }
        return keepsWWW ? text : withoutWWW(text)
    }

    static func withoutWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func wildcard(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        let body = pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: ".*")
        return try? NSRegularExpression(pattern: "^" + body + "$", options: [.dotMatchesLineSeparators])
    }

    static func regex(_ typed: String) -> NSRegularExpression? {
        guard !typed.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: typed, options: [.caseInsensitive])
    }

    static func rewritten(_ url: URL, by rewrite: LinkRule.Rewrite) -> URL? {
        guard let expression = try? NSRegularExpression(pattern: rewrite.find) else { return nil }
        let text = url.absoluteString
        let range = NSRange(text.startIndex..., in: text)
        guard expression.firstMatch(in: text, range: range) != nil else { return url }
        let changed = expression.stringByReplacingMatches(in: text, range: range, withTemplate: rewrite.replace)
        guard let made = URL(string: changed), let scheme = made.scheme?.lowercased(), scheme == "http" || scheme == "https",
              made.host() != nil else { return nil }
        return made
    }

    static func broken(_ rule: LinkRule) -> String? {
        switch rule.match {
        case .regex(let text) where regex(text) == nil:
            return "The expression doesn't read"
        case .pattern(let text) where wildcard(anchored(text)) == nil:
            return "The pattern is empty"
        default:
            break
        }
        if rule.match.text.trimmingCharacters(in: .whitespaces).isEmpty { return "Nothing to match yet" }
        if let rewrite = rule.rewrite, !rewrite.find.isEmpty, (try? NSRegularExpression(pattern: rewrite.find)) == nil {
            return "The address change doesn't read"
        }
        return nil
    }

    static func problem(_ rule: LinkRule, world: LinkWorld) -> String? {
        if let broken = broken(rule) { return broken }
        switch rule.target {
        case .space(let id, let folder):
            guard world.usesSpaces else { return "Spaces are off" }
            guard let space = world.space(id) else { return "Its space no longer exists" }
            if let folder, !space.folders.contains(where: { $0.id == folder }) { return "Its folder is gone, so it opens loose" }
        case .window(let id?):
            if !world.windows.contains(id) { return "Its window is closed" }
        case .app(let bundle, let name):
            if bundle.lowercased() == world.broadway.lowercased() { return "A rule can't send links to Broadway itself" }
            if !world.apps.contains(bundle) { return "\(name) isn't installed" }
        default:
            break
        }
        return nil
    }

    static func key(of url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        parts.host = parts.host?.lowercased()
        parts.scheme = parts.scheme?.lowercased()
        var text = parts.string ?? url.absoluteString
        if parts.path.isEmpty, parts.query == nil { text += "/" }
        return text
    }

    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased() else { return nil }
        return Vault.registrable(host)
    }

    static func site(typed text: String) -> String? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        let url = URL(string: typed.contains("://") ? typed : "https://\(typed)")
        guard let site = site(of: url), site.contains(".") else { return nil }
        return site
    }

    static func words(_ match: LinkRule.Match) -> String {
        switch match {
        case .site(let text): plainSite(text)
        case .host(let text): "only " + plainSite(text, keepsWWW: true)
        case .starts(let text): anchored(text) + "…"
        case .contains(let text): "any address with “\(text)”"
        case .pattern(let text): LinkRuleEditor.isAny(match) ? "every link" : anchored(text)
        case .regex(let text): "/\(text)/"
        }
    }

    static func words(_ target: LinkRule.Target, world: LinkWorld) -> String {
        switch target {
        case .space(let id, let folder):
            let space = world.space(id)
            let name = space?.name ?? "A space that's gone"
            guard let folder else { return name }
            return name + " › " + (space?.folders.first { $0.id == folder }?.name ?? "a folder that's gone")
        case .frontSpace: return "The space in front"
        case .whereOpen: return "Where it's already open"
        case .window(let id):
            guard let id else { return "A new window" }
            if let index = world.windows.firstIndex(of: id) { return "Window \(index + 1)" }
            return "A window that's closed"
        case .peek: return "A peek"
        case .app(_, let name): return name
        case .ask: return "Ask every time"
        }
    }

    static func words(_ from: LinkRule.From) -> String {
        switch from {
        case .anywhere: "From anywhere"
        case .otherApps: "From other apps"
        case .app(_, let name): "From \(name)"
        case .insideBroadway: "From pages in Broadway"
        }
    }

    static func words(_ place: LinkDecision.Place, world: LinkWorld, outside: Bool = true) -> String {
        switch place {
        case .here: return outside ? "Opens where you are" : "Opens as usual"
        case .space(let id, let folder):
            return "Opens in " + words(.space(id, folder: folder), world: world)
        case .window(let id): return "Opens in " + words(.window(id), world: world).lowercasedFirst
        case .peek: return "Opens in a peek"
        case .app(_, let name): return "Goes to \(name)"
        case .ask: return "Asks you where"
        case .tab(_, let space): return world.usesSpaces && world.spaces.count > 1 ? "Goes to its tab in \(world.name(of: space))" : "Goes to its tab"
        case .row(_, let folder, _): return "Shown in " + (world.rows.first { $0.folder == folder }?.name ?? "its live folder")
        }
    }

    static func pointed(_ place: LinkDecision.Place, here: UUID?, world: LinkWorld) -> String {
        guard case .row(_, let folder, let space) = place else { return words(place, world: world) }
        var text = "Opened in its row in " + (world.rows.first { $0.folder == folder }?.name ?? "a live folder")
        if world.usesSpaces, world.spaces.count > 1, space != here { text += " in \(world.name(of: space))" }
        return text
    }
}

enum LinkUnwrap {
    static func unwrap(_ url: URL) -> (URL, String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let full = parts.host?.lowercased() else { return nil }
        let host = LinkRouter.withoutWWW(full)
        let path = parts.path
        let found: (keys: [String], name: String)? = if google(host), path == "/url" {
            (["q", "url"], "a Google")
        } else if ["l.facebook.com", "lm.facebook.com"].contains(host), path == "/l.php" {
            (["u"], "a Facebook")
        } else if host == "slack-redir.net", path == "/link" {
            (["url"], "a Slack")
        } else if host.hasSuffix(".safelinks.protection.outlook.com") {
            (["url"], "an Outlook Safe Links")
        } else if host == "l.instagram.com" {
            (["u"], "an Instagram")
        } else if host == "t.umblr.com", path == "/redirect" {
            (["z"], "a Tumblr")
        } else if host == "link.zhihu.com" {
            (["target"], "a Zhihu")
        } else if ["youtube.com", "m.youtube.com"].contains(host), path == "/redirect" {
            (["q"], "a YouTube")
        } else if host == "away.vk.com", path == "/away.php" {
            (["to"], "a VK")
        } else {
            nil
        }
        guard let found else { return nil }
        let items = parts.queryItems ?? []
        for key in found.keys {
            guard let value = items.first(where: { $0.name == key })?.value, let inner = URL(string: value),
                  let innerScheme = inner.scheme?.lowercased(), innerScheme == "http" || innerScheme == "https",
                  inner.host() != nil else { continue }
            return (inner, found.name)
        }
        return nil
    }

    private static func google(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        return parts.first == "google" && (2...3).contains(parts.count)
    }
}

extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

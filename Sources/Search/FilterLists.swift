import Foundation

struct FilterRule: Hashable, Sendable {
    enum Action: Hashable, Sendable {
        case block
        case ignore
        case hide(String)
    }

    var filter: String
    var caseSensitive = false
    var types: [String] = []
    var load: String?
    var topFrameOnly = false
    var only: [String] = []
    var except: [String] = []
    var action: Action

    var json: [String: Any] {
        var trigger: [String: Any] = ["url-filter": filter]
        if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
        if !types.isEmpty { trigger["resource-type"] = types }
        if let load { trigger["load-type"] = [load] }
        if topFrameOnly { trigger["load-context"] = ["top-frame"] }
        if !only.isEmpty { trigger["if-domain"] = only }
        if !except.isEmpty { trigger["unless-domain"] = except }
        let shaped: [String: Any]
        switch action {
        case .block: shaped = ["type": "block"]
        case .ignore: shaped = ["type": "ignore-previous-rules"]
        case .hide(let selector): shaped = ["type": "css-display-none", "selector": selector]
        }
        return ["trigger": trigger, "action": shaped]
    }
}

enum FilterLists {
    struct Source: Hashable, Sendable {
        let id: String
        let name: String
        let address: String
        var strict = false
    }

    struct Input: Sendable {
        var text: String
        var strict = false
    }

    static let sources = [
        Source(id: "easylist", name: "EasyList", address: "https://easylist.to/easylist/easylist.txt"),
        Source(id: "easyprivacy", name: "EasyPrivacy", address: "https://easylist.to/easylist/easyprivacy.txt"),
        Source(id: "ublock", name: "uBlock filters", address: "https://ublockorigin.github.io/uAssets/filters/filters.txt"),
        Source(id: "ublock-privacy", name: "uBlock privacy", address: "https://ublockorigin.github.io/uAssets/filters/privacy.txt"),
        Source(id: "ublock-badware", name: "uBlock badware", address: "https://ublockorigin.github.io/uAssets/filters/badware.txt", strict: true),
        Source(id: "lowe", name: "Peter Lowe's list", address: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext"),
        Source(id: "easylist-cookie", name: "EasyList Cookie List", address: "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt"),
    ]

    static let version = 1
    static let perList = 40_000
    static let selectorsPerRule = 100

    struct Converted: Sendable {
        var blocks: [FilterRule] = []
        var pageBlocks: [FilterRule] = []
        var exceptions: [FilterRule] = []
        var pageExceptions: [FilterRule] = []
        var genericHides: [FilterRule] = []
        var genericHideExceptions: [FilterRule] = []
        var siteHides: [FilterRule] = []
        var hideExceptions: [FilterRule] = []
        var lines = 0
        var skipped = 0

        var ruleCount: Int { blocks.count + pageBlocks.count + genericHides.count + siteHides.count }
    }

    private static let start = "^https?://([^/]+\\.)?"
    private static let startSocket = "^wss?://([^/]+\\.)?"
    private static let separator = "[^a-zA-Z0-9_.%-]"
    private static let everyType = ["image", "style-sheet", "script", "font", "media", "svg-document", "document", "fetch", "websocket", "ping", "other"]
    private static let typeNames: [String: [String]] = [
        "script": ["script"], "image": ["image"], "img": ["image"], "stylesheet": ["style-sheet"], "css": ["style-sheet"],
        "font": ["font"], "media": ["media"], "object": ["other"], "object-subrequest": ["other"],
        "xmlhttprequest": ["fetch"], "xhr": ["fetch"], "subdocument": ["document"], "frame": ["document"],
        "websocket": ["websocket"], "ping": ["ping"], "beacon": ["ping"], "other": ["other"], "font-face": ["font"],
    ]
    private static let optionShape = try? NSRegularExpression(pattern: "^~?[a-z0-9_-]+(=.*)?$")

    private static let extendedSelectors = [
        ":-abp-", ":has-text", ":contains", ":matches-", ":xpath", ":style(", ":remove", ":upward", ":min-text-length",
        ":nth-ancestor", ":others", ":watch-attr", ":if(", ":if-not", ":-ext-", ":matches-path", ":matches-css",
        ":matches-attr", ":matches-prop",
    ]

    static func convert(_ lists: [Input]) -> Converted {
        var out = Converted()
        var lines: [(text: Substring, strict: Bool)] = []
        for list in lists {
            lines.append(contentsOf: list.text.split(whereSeparator: \.isNewline).map { ($0, list.strict) })
        }

        var undone = Set<String>()
        for line in lines where line.text.contains("badfilter") {
            let text = String(line.text).trimmingCharacters(in: .whitespaces)
            if let cut = text.range(of: ",badfilter") ?? text.range(of: "$badfilter") {
                var left = text
                left.removeSubrange(cut)
                undone.insert(left)
            }
        }

        var generic: [String] = []
        var bySites: [SiteKey: [String]] = [:]
        var excused: [String: [String]] = [:]
        var excusedEverywhere = Set<String>()
        var blocks = Set<FilterRule>()
        var pageBlocks = Set<FilterRule>()
        var exceptions = Set<FilterRule>()
        var pageExceptions = Set<FilterRule>()
        var genericHideExceptions = Set<FilterRule>()
        var hideExceptions = Set<FilterRule>()
        var seen = Set<String>()

        for raw in lines {
            let line = String(raw.text).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("!"), !line.hasPrefix("[") else { continue }
            out.lines += 1
            guard seen.insert(line).inserted, !undone.contains(line) else { continue }
            if let hide = cosmetic(line) {
                switch hide {
                case .unusable: out.skipped += 1
                case .generic(let selector): generic.append(selector)
                case .sites(let key, let selector): bySites[key, default: []].append(selector)
                case .excuse(let sites, let selector):
                    if sites.isEmpty { excusedEverywhere.insert(selector) } else { excused[selector, default: []] += sites }
                }
                continue
            }
            guard let network = network(line, strict: raw.strict) else {
                out.skipped += 1
                continue
            }
            for rule in network.rules {
                switch network.kind {
                case .block: blocks.insert(rule)
                case .pageBlock: pageBlocks.insert(rule)
                case .exception: exceptions.insert(rule)
                case .pageException: pageExceptions.insert(rule)
                case .genericHideException: genericHideExceptions.insert(rule)
                case .hideException: hideExceptions.insert(rule)
                }
            }
        }

        let order: (FilterRule, FilterRule) -> Bool = {
            ($0.filter, $0.types.joined(), $0.only.joined()) < ($1.filter, $1.types.joined(), $1.only.joined())
        }
        out.blocks = blocks.sorted(by: order)
        out.pageBlocks = pageBlocks.sorted(by: order)
        out.exceptions = exceptions.sorted(by: order)
        out.pageExceptions = pageExceptions.sorted(by: order)
        out.genericHideExceptions = genericHideExceptions.sorted(by: order)
        out.hideExceptions = hideExceptions.sorted(by: order)

        var plain: [String] = []
        for selector in Set(generic).sorted() where !excusedEverywhere.contains(selector) {
            if let sites = excused[selector] {
                out.genericHides.append(FilterRule(filter: ".*", except: wild(sites), action: .hide(selector)))
            } else {
                plain.append(selector)
            }
        }
        var index = 0
        while index < plain.count {
            let end = min(index + selectorsPerRule, plain.count)
            out.genericHides.append(FilterRule(filter: ".*", action: .hide(plain[index..<end].joined(separator: ", "))))
            index = end
        }

        for key in bySites.keys.sorted(by: { $0.sites.joined() < $1.sites.joined() }) {
            let excuses = Set(key.sites)
            let selectors = Set(bySites[key] ?? []).sorted().filter { selector in
                !excusedEverywhere.contains(selector) && Set(excused[selector] ?? []).isDisjoint(with: excuses)
            }
            var index = 0
            while index < selectors.count {
                let end = min(index + selectorsPerRule, selectors.count)
                let joined = selectors[index..<end].joined(separator: ", ")
                out.siteHides.append(FilterRule(filter: ".*", only: key.negative ? [] : wild(key.sites),
                                                except: key.negative ? wild(key.sites) : [], action: .hide(joined)))
                index = end
            }
        }
        return out
    }

    struct Part: Sendable {
        var head: [FilterRule]
        var tail: [FilterRule]
        var rules: [FilterRule] { head + tail }
    }

    static func parts(_ converted: Converted, limit: Int = perList) -> [Part] {
        var parts: [Part] = []
        let hideTail = converted.hideExceptions + converted.pageExceptions
        let genericTail = converted.genericHideExceptions + hideTail
        for batch in chunks(converted.genericHides, room: limit - genericTail.count) {
            parts.append(Part(head: batch, tail: genericTail))
        }
        for batch in chunks(converted.siteHides, room: limit - hideTail.count) {
            parts.append(Part(head: batch, tail: hideTail))
        }
        let blockTail = converted.exceptions + converted.pageExceptions
        for batch in chunks(converted.pageBlocks, room: limit - blockTail.count) {
            parts.append(Part(head: batch, tail: blockTail))
        }
        let openings = FilterRule(filter: ".*", types: ["document"], topFrameOnly: true, action: .ignore)
        for batch in chunks(converted.blocks, room: limit - blockTail.count - 1) {
            parts.append(Part(head: batch, tail: [openings] + blockTail))
        }
        return parts
    }

    private static func chunks(_ rules: [FilterRule], room: Int) -> [[FilterRule]] {
        let size = max(1000, room)
        return stride(from: 0, to: rules.count, by: size).map { Array(rules[$0..<min($0 + size, rules.count)]) }
    }

    static func encoded(_ rules: [FilterRule]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: rules.map(\.json)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct SiteKey: Hashable {
        let sites: [String]
        let negative: Bool
    }

    private enum Cosmetic {
        case unusable
        case generic(String)
        case sites(SiteKey, String)
        case excuse([String], String)
    }

    private static func cosmetic(_ line: String) -> Cosmetic? {
        if ["#?#", "#$#", "#%#", "#@?#", "#@$#", "#@%#", "$$", "$@$"].contains(where: line.contains) { return .unusable }
        let excuse = line.range(of: "#@#")
        guard let mark = excuse ?? line.range(of: "##") else { return nil }
        let head = String(line[line.startIndex..<mark.lowerBound])
        guard !head.contains("/"), !head.contains("|"), !head.contains("$"), !head.contains("^"), !head.contains("=") else { return nil }
        let selector = String(line[mark.upperBound...])
        guard usable(selector) else { return .unusable }
        var positive: [String] = []
        var negative: [String] = []
        for piece in head.split(separator: ",") {
            let text = piece.trimmingCharacters(in: .whitespaces).lowercased()
            let away = text.hasPrefix("~")
            guard let name = domain(away ? String(text.dropFirst()) : text) else { return .unusable }
            if away { negative.append(name) } else { positive.append(name) }
        }
        if excuse != nil {
            return negative.isEmpty ? .excuse(positive, selector) : .unusable
        }
        if positive.isEmpty, negative.isEmpty { return .generic(selector) }
        if !positive.isEmpty, !negative.isEmpty { return .sites(SiteKey(sites: positive.sorted(), negative: false), selector) }
        return .sites(SiteKey(sites: (positive + negative).sorted(), negative: positive.isEmpty), selector)
    }

    static func usable(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.count < 800, !selector.hasPrefix("+js("), !selector.hasPrefix("^") else { return false }
        if selector.contains("{") || selector.contains("}") || selector.contains("<") { return false }
        if extendedSelectors.contains(where: selector.contains) { return false }
        if selector.components(separatedBy: ":has(").count > 2 { return false }
        var round = 0, square = 0
        var quote: Character?
        var escaped = false
        for character in selector {
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(": round += 1
            case ")": round -= 1
            case "[": square += 1
            case "]": square -= 1
            default: break
            }
            if round < 0 || square < 0 { return false }
        }
        return round == 0 && square == 0 && quote == nil
    }

    private static func domain(_ text: String) -> String? {
        guard !text.isEmpty, !text.hasSuffix(".*"), !text.hasPrefix("/"), !text.contains("*") else { return nil }
        if text.allSatisfy({ $0.isASCII }) { return text }
        guard let host = URL(string: "https://\(text)/")?.host(), host.allSatisfy({ $0.isASCII }) else { return nil }
        return host.lowercased()
    }

    private static func wild(_ sites: [String]) -> [String] { sites.map { "*" + $0 } }

    private enum Kind { case block, pageBlock, exception, pageException, genericHideException, hideException }

    private struct Options {
        var types: Set<String> = []
        var away: Set<String> = []
        var load: String?
        var only: [String] = []
        var except: [String] = []
        var caseSensitive = false
        var page = false
        var generichide = false
        var elemhide = false
    }

    private static func network(_ line: String, strict: Bool) -> (kind: Kind, rules: [FilterRule])? {
        var body = line
        let exception = body.hasPrefix("@@")
        if exception { body.removeFirst(2) }

        var options = Options()
        if let cut = body.lastIndex(of: "$"), !(body.hasPrefix("/") && body.hasSuffix("/")) {
            let suffix = String(body[body.index(after: cut)...])
            let tokens = suffix.split(separator: ",").map(String.init)
            if !tokens.isEmpty, tokens.allSatisfy(looksLikeOption) {
                guard let read = read(tokens) else { return nil }
                options = read
                body = String(body[..<cut])
            }
        }
        if body.hasPrefix("/"), body.hasSuffix("/"), body.count > 1 { return nil }
        guard body.allSatisfy({ $0.isASCII }) else { return nil }

        if exception, options.page || options.elemhide || options.generichide {
            guard let host = plainHost(body) else { return nil }
            let rule = FilterRule(filter: ".*", only: ["*" + host], action: .ignore)
            let kind: Kind = options.page ? .pageException : options.generichide ? .genericHideException : .hideException
            return (kind, [rule])
        }

        guard let filters = regex(body, socket: options.types == ["websocket"]) else { return nil }
        let literal = body.filter { !"|^*".contains($0) }
        if literal.count < 3, options.only.isEmpty, !body.hasPrefix("||") { return nil }

        var types = options.types
        if !options.away.isEmpty {
            types = Set(everyType).subtracting(options.away)
        }
        let rules = filters.map { filter in
            FilterRule(filter: filter, caseSensitive: options.caseSensitive, types: types.sorted(), load: options.load,
                       only: options.only, except: options.except, action: exception ? .ignore : .block)
        }
        if exception { return (.exception, rules) }
        guard options.page || (strict && types.isEmpty) else { return (.block, rules) }
        return (.pageBlock, rules.map { rule in
            var page = rule
            page.types = []
            return page
        })
    }

    private static func plainHost(_ body: String) -> String? {
        guard body.hasPrefix("||") else { return nil }
        var host = String(body.dropFirst(2))
        if host.hasSuffix("^") { host.removeLast() }
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return domain(host.lowercased())
    }

    private static func looksLikeOption(_ token: String) -> Bool {
        guard let shape = optionShape else { return false }
        return shape.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil
    }

    private static func read(_ tokens: [String]) -> Options? {
        var options = Options()
        for token in tokens {
            let parts = token.split(separator: "=", maxSplits: 1).map(String.init)
            var name = parts[0]
            let value = parts.count > 1 ? parts[1] : ""
            let negated = name.hasPrefix("~")
            if negated { name.removeFirst() }
            switch name {
            case "third-party", "3p":
                options.load = negated ? "first-party" : "third-party"
            case "first-party", "1p":
                options.load = negated ? "third-party" : "first-party"
            case "match-case":
                options.caseSensitive = true
            case "important":
                continue
            case "domain", "from":
                for piece in value.split(separator: "|") {
                    let text = piece.lowercased()
                    let away = text.hasPrefix("~")
                    guard let site = domain(away ? String(text.dropFirst()) : text) else { return nil }
                    if away { options.except.append("*" + site) } else { options.only.append("*" + site) }
                }
                if !options.only.isEmpty, !options.except.isEmpty { return nil }
            case "document", "doc":
                options.page = true
            case "all":
                options.types = Set(everyType)
            case "popup":
                options.types.insert("popup")
            case "generichide", "ghide":
                options.generichide = true
            case "elemhide", "ehide":
                options.elemhide = true
            default:
                guard let types = typeNames[name] else { return nil }
                if negated { options.away.formUnion(types) } else { options.types.formUnion(types) }
            }
        }
        return options
    }

    private static func regex(_ pattern: String, socket: Bool) -> [String]? {
        var text = pattern
        var prefix = ""
        var hostLevel = false
        if text.hasPrefix("||") {
            text.removeFirst(2)
            prefix = socket ? startSocket : start
            hostLevel = true
        } else if text.hasPrefix("|") {
            text.removeFirst()
            prefix = "^"
        }
        var suffix = ""
        if text.hasSuffix("|"), !text.hasSuffix("\\|") {
            text.removeLast()
            suffix = "$"
        }
        var trailingSeparator = false
        if text.hasSuffix("^") {
            text.removeLast()
            trailingSeparator = true
        }
        while text.hasPrefix("*") {
            text.removeFirst()
            if prefix != start, prefix != startSocket { prefix = "" }
        }
        while text.hasSuffix("*") {
            text.removeLast()
            suffix = ""
            trailingSeparator = false
        }

        var out = prefix
        var star = false
        for character in text {
            if character == "*" {
                if !star { out += ".*" }
                star = true
                continue
            }
            star = false
            switch character {
            case "^": out += separator
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|":
                out += "\\" + String(character)
            default:
                out.append(character)
            }
        }
        if text.isEmpty { return prefix.isEmpty && !trailingSeparator ? [".*"] : nil }
        if trailingSeparator {
            let bareHost = hostLevel && !text.contains("/") && !text.contains("*") && !text.contains("^")
            if bareHost { return [out + "[:/]"] }
            return [out + separator + suffix, out + "$"]
        }
        return [out + suffix]
    }
}

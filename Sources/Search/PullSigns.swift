import Foundation

enum PullSigns {
    enum Kind: Equatable { case word, review, approval, push, event }

    struct Said: Equatable {
        var at: Date
        var who: String
        var bot: Bool = false
        var asks: Bool = false
        var kind: Kind = .word

        init(at: Date, who: String, bot: Bool = false, asks: Bool = false, kind: Kind = .word) {
            self.at = at
            self.who = who.lowercased()
            self.bot = bot
            self.asks = asks
            self.kind = kind
        }

        var spoken: Bool { kind == .word || kind == .review || kind == .approval }
    }

    struct Thread: Equatable {
        var resolved: Bool
        var said: [Said]
        var id: String? = nil

        var key: String { id ?? said.first.map { "\($0.who)@\($0.at.timeIntervalSince1970)" } ?? "" }
    }

    struct Seen: Equatable {
        var resolved: Date?
        var yours: Bool
    }

    struct Read: Equatable {
        var activity: Date?
        var unanswered: Int
        var back: Bool = false
    }

    struct Talk: Equatable {
        var said: [Said] = []
        var threads: [Thread] = []
        var viewer: String?
        var author: String?
    }

    static func read(_ talk: Talk) -> Read { read(talk, seen: [:]) }

    static func read(_ talk: Talk, seen: [String: Seen]) -> Read {
        var made = read(talk.said, threads: talk.threads, viewer: talk.viewer, author: talk.author)
        if let since = back(talk, seen: seen) {
            made.back = true
            if since > (made.activity ?? .distantPast), since != .distantPast { made.activity = since }
        }
        return made
    }

    static func seen(_ talk: Talk, before: [String: Seen]?, at now: Date) -> [String: Seen] {
        let me = talk.viewer?.lowercased()
        var out: [String: Seen] = [:]
        for thread in talk.threads {
            let talking = thread.said.filter { !$0.bot }
            let shown = talking.max { $0.at < $1.at }
            let yours = shown.map { last in last.who == me && talking.contains { $0.who == me } } ?? before?[thread.key]?.yours ?? false
            guard thread.resolved else {
                out[thread.key] = Seen(resolved: nil, yours: yours)
                continue
            }
            let when = before.map { $0[thread.key]?.resolved ?? now } ?? .distantPast
            out[thread.key] = Seen(resolved: when, yours: yours)
        }
        return out
    }

    static func back(_ talk: Talk, seen: [String: Seen] = [:]) -> Date? {
        guard let me = talk.viewer?.lowercased(), !me.isEmpty else { return nil }
        let author = talk.author?.lowercased()
        guard author != me else { return nil }
        let everything = (talk.said + talk.threads.flatMap(\.said)).filter { !$0.bot }
        guard let last = everything.filter({ $0.who == me && $0.spoken }).map(\.at).max() else { return nil }
        let review = talk.said.filter { $0.who == me && ($0.kind == .review || $0.kind == .approval) }.max { $0.at < $1.at }
        guard review?.kind != .approval else { return nil }
        let news = everything.filter { one in
            one.who != me && one.at > last && (one.kind == .push || one.spoken && one.who == author)
        }.map(\.at)
        let resolves = talk.threads.compactMap { thread -> Date? in
            guard thread.resolved, let mark = seen[thread.key], mark.yours, let when = mark.resolved, when > last else { return nil }
            return when
        }
        return (news + resolves).max()
    }

    static func read(_ said: [Said], threads: [Thread], viewer: String?, author: String? = nil) -> Read {
        let me = viewer?.lowercased()
        let people = (said + threads.flatMap(\.said)).filter { !$0.bot }
        let newest = people.max { $0.at < $1.at }
        let activity = newest.flatMap { $0.who == me ? nil : $0.at }
        let mine = people.filter { $0.who == me }.map(\.at).max()
        let own = author.map { $0.lowercased() == me } ?? true
        let open = threads.filter { thread in
            let talking = thread.said.filter { !$0.bot }
            guard !thread.resolved, let last = talking.max(by: { $0.at < $1.at }), last.who != me else { return false }
            return own || talking.contains { $0.who == me }
        }.count
        let asked = own || mine != nil
            ? said.filter { one in one.asks && !one.bot && one.who != me && mine.map { one.at > $0 } ?? true }.count
            : 0
        return Read(activity: activity, unanswered: open + asked)
    }

    static func page(_ html: String) -> Talk? {
        let marker = #"class="js-timeline-item"#
        let viewer = meta("user-login", in: html)
        guard let viewer, !viewer.isEmpty else { return nil }
        guard let start = html.range(of: marker)?.lowerBound else {
            return html.contains("discussion-timeline-actions") ? Talk(viewer: viewer, author: authors(in: html[...]).first?.who) : nil
        }
        let tail = html[start...]
        let end = tail.range(of: "discussion-timeline-actions")?.lowerBound
            ?? tail.range(of: "partial-discussion-sidebar")?.lowerBound ?? html.endIndex
        var talk = Talk(viewer: viewer, author: authors(in: html[..<start]).first?.who)
        var clock: Date?
        for segment in split(html[start..<end], on: marker) {
            let gid = attribute("data-gid", in: segment.prefix(400)) ?? ""
            if gid.hasPrefix("C_") {
                if let pushed = authors(in: segment).first {
                    clock = max(clock ?? pushed.at, pushed.at)
                    talk.said.append(Said(at: pushed.at, who: pushed.who, bot: pushed.bot, kind: .push))
                    continue
                }
                guard let after = clock, let (who, bot) = committer(in: segment) else { continue }
                clock = after.addingTimeInterval(1)
                talk.said.append(Said(at: after.addingTimeInterval(1), who: who, bot: bot, kind: .push))
                continue
            }
            let parts = split(segment, on: "<review-thread-collapsible")
            let head = segment.range(of: "<review-thread-collapsible").map { segment[..<$0.lowerBound] } ?? segment
            let found = authored(in: head)
            var said = found.map(\.said)
            if !said.isEmpty {
                let review = gid.hasPrefix("PRR_") && head.contains("requested changes")
                said[0].asks = gid.hasPrefix("IC_") || review
                said[0].kind = kind(gid, head)
                for index in said.indices.dropFirst() { said[index].kind = .event }
            }
            for index in said.indices where found[index].rest.contains(">force-pushed</a>") { said[index].kind = .push }
            if let latest = said.map(\.at).max() { clock = max(clock ?? latest, latest) }
            talk.said += said
            var before = parts.first.map { $0.hasPrefix("<review-thread-collapsible") ? Substring() : $0 } ?? Substring()
            for part in parts {
                guard part.hasPrefix("<review-thread-collapsible") else {
                    before = part
                    continue
                }
                let tag = part.prefix { $0 != ">" }
                talk.threads.append(Thread(resolved: tag.contains(#"data-resolved="true""#), said: authors(in: part),
                                           id: thread(tag, after: before)))
                before = part
            }
        }
        return talk
    }

    private static func kind(_ gid: String, _ head: Substring) -> Kind {
        if gid.hasPrefix("PRR_") { return head.contains("approved these changes") ? .approval : .review }
        if gid.hasPrefix("HRFPE_") { return .push }
        if gid.hasPrefix("IC_") || gid.isEmpty { return .word }
        return .event
    }

    private static func thread(_ tag: Substring, after before: Substring) -> String? {
        if let found = tag.range(of: "/threads/") {
            let digits = tag[found.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty { return String(digits) }
        }
        guard let found = before.range(of: "review-thread-or-comment-id-", options: .backwards) else { return nil }
        let digits = before[found.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }

    private static func split(_ text: Substring, on marker: String) -> [Substring] {
        var out: [Substring] = []
        var from = text.startIndex
        var search = text.startIndex
        while let found = text.range(of: marker, range: search..<text.endIndex) {
            if found.lowerBound > from { out.append(text[from..<found.lowerBound]) }
            from = found.lowerBound
            search = found.upperBound
        }
        if from < text.endIndex { out.append(text[from...]) }
        return out
    }

    private static func tag(around found: Range<Substring.Index>, in text: Substring) -> Substring? {
        guard let open = text[..<found.lowerBound].lastIndex(of: "<"),
              let close = text[found.upperBound...].firstIndex(of: ">") else { return nil }
        return text[open..<close]
    }

    private static func person(_ tag: Substring) -> (String, Bool)? {
        guard let href = attribute("href", in: tag) else { return nil }
        let path = href.hasPrefix("/") ? String(href.dropFirst()) : href
        let bot = path.hasPrefix("apps/")
        let who = bot ? String(path.dropFirst(5)) : path
        guard !who.isEmpty, !who.contains("/"), !who.contains(":") else { return nil }
        return (who, bot)
    }

    private static func committer(in text: Substring) -> (String, Bool)? {
        for marker in [#"class="author"#, #"data-test-selector="commits-avatar-stack-avatar-link""#] {
            guard let found = text.range(of: marker), let tag = tag(around: found, in: text), let person = person(tag) else { continue }
            return person
        }
        return nil
    }

    private static func authors(in text: Substring) -> [Said] {
        authored(in: text).map(\.said)
    }

    private static func authored(in text: Substring) -> [(said: Said, rest: Substring)] {
        var out: [(said: Said, rest: Substring)] = []
        var search = text.startIndex
        while let found = text.range(of: #"class="author"#, range: search..<text.endIndex) {
            guard let tag = tag(around: found, in: text) else { break }
            search = tag.endIndex
            let next = text.range(of: #"class="author"#, range: tag.endIndex..<text.endIndex)?.lowerBound ?? text.endIndex
            guard let (who, bot) = person(tag), let time = text.range(of: "<relative-time", range: tag.endIndex..<next),
                  let stamp = text[time.upperBound...].prefix(300).firstIndex(of: ">").map({ text[time.upperBound..<$0] }),
                  let when = attribute("datetime", in: stamp).flatMap(GitHubAPI.date) else { continue }
            out.append((Said(at: when, who: who, bot: bot), text[tag.endIndex..<next]))
        }
        return out
    }

    private static func attribute(_ name: String, in tag: Substring) -> String? {
        guard let found = tag.range(of: " \(name)=\"") ?? tag.range(of: "\n\(name)=\"") else { return nil }
        let rest = tag[found.upperBound...]
        guard let quote = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<quote]).replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func meta(_ name: String, in html: String) -> String? {
        guard let found = html.range(of: #"<meta name="\#(name)" content=""#) else { return nil }
        let rest = html[found.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}

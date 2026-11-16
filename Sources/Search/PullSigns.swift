import Foundation

enum PullSigns {
    struct Said: Equatable {
        var at: Date
        var who: String
        var bot: Bool = false
        var asks: Bool = false

        init(at: Date, who: String, bot: Bool = false, asks: Bool = false) {
            self.at = at
            self.who = who.lowercased()
            self.bot = bot
            self.asks = asks
        }
    }

    struct Thread: Equatable {
        var resolved: Bool
        var said: [Said]
    }

    struct Read: Equatable {
        var activity: Date?
        var unanswered: Int
    }

    struct Talk: Equatable {
        var said: [Said] = []
        var threads: [Thread] = []
        var viewer: String?
        var author: String?
    }

    static func read(_ talk: Talk) -> Read {
        read(talk.said, threads: talk.threads, viewer: talk.viewer, author: talk.author)
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
                guard let after = clock, let (who, bot) = committer(in: segment) else { continue }
                clock = after.addingTimeInterval(1)
                talk.said.append(Said(at: after.addingTimeInterval(1), who: who, bot: bot))
                continue
            }
            let parts = split(segment, on: "<review-thread-collapsible")
            let head = segment.range(of: "<review-thread-collapsible").map { segment[..<$0.lowerBound] } ?? segment
            var said = authors(in: head)
            if !said.isEmpty {
                let review = gid.hasPrefix("PRR_") && head.contains("requested changes")
                said[0].asks = gid.hasPrefix("IC_") || review
            }
            if let latest = said.map(\.at).max() { clock = max(clock ?? latest, latest) }
            talk.said += said
            for part in parts where part.hasPrefix("<review-thread-collapsible") {
                let tag = part.prefix { $0 != ">" }
                talk.threads.append(Thread(resolved: tag.contains(#"data-resolved="true""#), said: authors(in: part)))
            }
        }
        return talk
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
        var out: [Said] = []
        var search = text.startIndex
        while let found = text.range(of: #"class="author"#, range: search..<text.endIndex) {
            guard let tag = tag(around: found, in: text) else { break }
            search = tag.endIndex
            let next = text.range(of: #"class="author"#, range: tag.endIndex..<text.endIndex)?.lowerBound ?? text.endIndex
            guard let (who, bot) = person(tag), let time = text.range(of: "<relative-time", range: tag.endIndex..<next),
                  let stamp = text[time.upperBound...].prefix(300).firstIndex(of: ">").map({ text[time.upperBound..<$0] }),
                  let when = attribute("datetime", in: stamp).flatMap(GitHubAPI.date) else { continue }
            out.append(Said(at: when, who: who, bot: bot))
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

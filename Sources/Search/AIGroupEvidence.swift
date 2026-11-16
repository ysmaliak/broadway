import Foundation

enum AIGroupEvidence {
    static let plain: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "for", "from", "has", "have", "how", "i", "in", "into", "is", "it",
        "its", "my", "new", "no", "not", "of", "on", "or", "our", "so", "than", "that", "the", "their", "this", "to", "too", "up",
        "vs", "was", "we", "what", "when", "where", "which", "who", "why", "will", "with", "without", "you", "your", "about",
        "after", "all", "also", "any", "can", "do", "does", "more", "most",
        "de", "la", "le", "les", "du", "des", "der", "die", "das", "und", "ein", "eine", "mit", "von", "für", "fur", "auf", "im",
        "ist", "wie", "el", "los",
        "и", "в", "во", "на", "с", "со", "по", "для", "от", "до", "из", "за", "как", "что", "это", "или", "не", "к", "у", "о",
        "об", "же", "бы", "ли", "все", "всё", "мой", "моя", "мы", "вы", "он", "она", "они", "его", "её", "их",
        "best", "top", "review", "reviews", "buy", "price", "prices", "cost", "guide", "official", "video", "videos", "news",
        "home", "page", "online", "free", "watch", "full", "part", "pull", "request", "issue", "issues", "comments", "comment",
        "question", "questions", "answer", "docs", "documentation", "reference", "com", "www", "org", "net", "http", "https",
        "купить", "цена", "отзывы", "смотреть", "онлайн", "бесплатно", "сайт", "главная", "новости", "обзор",
    ]

    static let pathNoise: Set<String> = [
        "html", "index", "status", "watch", "item", "issues", "pull", "comments", "search", "article", "articles", "reviews",
        "review", "questions", "wiki", "docs", "news", "posts", "view", "edit", "shop", "city",
    ]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        let cleaned = fold(text).replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "’", with: "")
        for piece in cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(piece)
            if plain.contains(word) { continue }
            if word.allSatisfy(\.isNumber) {
                if word.count >= 4, !AIGroupNames.isYear(word) { out.append(word) }
                continue
            }
            let mixed = word.contains(where: \.isNumber)
            if word.count >= 3 || (mixed && word.count >= 2) { out.append(word) }
        }
        return out
    }

    static func same(_ one: String, _ two: String) -> Bool {
        if one == two { return true }
        if one.contains(where: \.isNumber) || two.contains(where: \.isNumber) { return false }
        let short = min(one.count, two.count)
        if short >= 6, one.hasPrefix(two) || two.hasPrefix(one) { return true }
        if short < 4 || abs(one.count - two.count) > 3 { return false }
        let need = short > 4 ? max(4, short - 1) : 3
        return one.commonPrefix(with: two).count >= need
    }

    static func segments(_ title: String) -> [String] {
        var parts = [title]
        for mark in [" - ", " | ", " — ", " – ", " · ", " / ", ": "] {
            parts = parts.flatMap { $0.components(separatedBy: mark) }
        }
        return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func site(_ tab: AIGroupTab) -> String {
        fold(AIGroupNames.site(tab.host))
    }

    static func pathWords(_ tab: AIGroupTab) -> [String] {
        let spaced = String(tab.path.map { "/_-.+".contains($0) ? " " : $0 })
        return tokens(spaced).filter { $0.count >= 5 && !$0.contains(where: \.isNumber) && !pathNoise.contains($0) }
    }

    static func chrome(_ tab: AIGroupTab, beside other: AIGroupTab) -> Set<String> {
        guard site(tab) == site(other) else { return [] }
        var drop: Set<String> = [site(tab)]
        let mine = segments(tab.title)
        guard mine.count >= 2, let last = mine.last, let end = segments(other.title).last else { return drop }
        if fold(last) == fold(end) { drop.formUnion(tokens(last)) }
        return drop
    }

    static func by(_ tab: AIGroupTab) -> [String] {
        let words = tokens(tab.by)
        guard !words.isEmpty else { return [] }
        let joined = words.joined()
        let place = fold(tab.host + tab.path).filter { $0.isLetter || $0.isNumber }
        if place.contains(joined) || joined.contains(site(tab)) { return [] }
        return words
    }

    static func signed(_ tab: AIGroupTab, beside other: AIGroupTab) -> Set<String> {
        guard site(tab) == site(other) else { return [] }
        let theirs = Set(segments(other.title).map(fold))
        var drop: Set<String> = []
        for part in segments(tab.title) where theirs.contains(fold(part)) && tokens(part).contains(site(tab)) {
            drop.formUnion(tokens(part))
        }
        return drop
    }

    static func words(_ tab: AIGroupTab, beside other: AIGroupTab) -> [String] {
        let drop = chrome(tab, beside: other).union(signed(tab, beside: other))
        let apart = site(tab) != site(other)
        return (tokens(tab.title) + by(tab)).filter { !drop.contains($0) } + (apart ? pathWords(tab) : [])
    }

    static func shared(_ one: AIGroupTab, _ two: AIGroupTab) -> [String] {
        let theirs = words(two, beside: one)
        var out: [String] = []
        for word in words(one, beside: two) where !out.contains(word) && theirs.contains(where: { same(word, $0) }) {
            out.append(word)
        }
        return out
    }

    static func channel(_ one: AIGroupTab, _ two: AIGroupTab) -> Bool {
        let mine = by(one)
        return !mine.isEmpty && mine == by(two) && site(one) == site(two)
    }

    static func common(_ tabs: [AIGroupTab]) -> [String] {
        guard tabs.count >= 2, let first = tabs.first else { return [] }
        let oneSite = tabs.allSatisfy { site($0) == site(first) }
        func held(_ tab: AIGroupTab) -> [String] {
            var drop: Set<String> = oneSite ? [site(tab)] : []
            if oneSite, let other = tabs.first(where: { $0.id != tab.id }) { drop = chrome(tab, beside: other) }
            return (tokens(tab.title) + by(tab)).filter { !drop.contains($0) }
        }
        let others = tabs.dropFirst().map(held)
        var out: [String] = []
        for word in held(first) where !out.contains(word) && others.allSatisfy({ $0.contains { same(word, $0) } }) {
            out.append(word)
        }
        return out
    }

    static func written(_ word: String, in tabs: [AIGroupTab]) -> String {
        for tab in tabs {
            for text in [tab.by, tab.title] {
                for piece in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }) {
                    if tokens(String(piece)).first == word { return String(piece) }
                }
            }
        }
        return word
    }

    static func holds(_ name: String, anyOf words: [String]) -> Bool {
        let said = tokens(name) + [fold(name).filter { $0.isLetter || $0.isNumber }]
        return words.contains { word in said.contains { same($0, word) || ($0.count >= 6 && $0.contains(word) && word.count >= 4) } }
    }
}

struct AIGroupSorter {
    var judge: @Sendable (AIGroupTab, AIGroupTab) async throws -> Bool
    var belongs: (@Sendable (AIGroupInfo, AIGroupTab) async throws -> Bool)?
    var subject: (@Sendable (AIGroupTab) async throws -> AIGroupSubject?)? = nil
    var meant: (@Sendable (AIGroupTab, AIGroupSubject, AIGroupTab, AIGroupSubject) async throws -> Bool)? = nil
    var recalled: (@Sendable (AIGroupTab) -> AIGroupSubject?)? = nil
    var subjects: [UUID: AIGroupSubject] = [:]

    static let reach = 4
    static let asked = 3
    static let described = 6

    func meaning(_ one: AIGroupTab, _ two: AIGroupTab) -> [String] {
        AIGroupSubject.shared(one, subjects[one.id], two, subjects[two.id])
    }

    func weight(_ one: AIGroupTab, _ two: AIGroupTab) -> Int {
        AIGroupEvidence.shared(one, two).count + (AIGroupEvidence.channel(one, two) ? 1 : 0) + meaning(one, two).count
    }

    func described(_ ask: AIGroupAsk) async throws -> AIGroupSorter {
        guard let subject else { return self }
        var out = self
        var seen: Set<UUID> = []
        var unknown: [AIGroupTab] = []
        for tab in ask.fresh + ask.groups.flatMap(\.members) + ask.loose.reversed() where seen.insert(tab.id).inserted {
            if out.subjects[tab.id] != nil { continue }
            if let found = recalled?(tab) {
                out.subjects[tab.id] = found
            } else {
                unknown.append(tab)
            }
        }
        let fresh = Set(ask.fresh.map(\.id))
        var asked = 0
        for tab in unknown {
            if !fresh.contains(tab.id) {
                guard asked < Self.described else { break }
                asked += 1
            }
            try Task.checkCancellation()
            if let found = try await subject(tab) { out.subjects[tab.id] = found }
        }
        return out
    }

    func agree(_ one: AIGroupTab, _ two: AIGroupTab) async throws -> Bool {
        try Task.checkCancellation()
        if AIGroupEvidence.channel(one, two) { return true }
        guard AIGroupEvidence.shared(one, two).isEmpty else {
            guard try await judge(one, two) else { return false }
            return try await judge(two, one)
        }
        guard !meaning(one, two).isEmpty else { return false }
        guard try await ask(one, two) else { return false }
        return try await ask(two, one)
    }

    func ask(_ one: AIGroupTab, _ two: AIGroupTab) async throws -> Bool {
        if AIGroupEvidence.shared(one, two).isEmpty, let meant, let mine = subjects[one.id], let theirs = subjects[two.id] {
            return try await meant(one, mine, two, theirs)
        }
        return try await judge(one, two)
    }

    func fits(_ tab: AIGroupTab, among members: [AIGroupTab]) async throws -> Bool {
        let near = members.map { (member: $0, weight: weight(tab, $0)) }
            .filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }.prefix(Self.asked)
        guard !near.isEmpty else { return false }
        let need = members.count <= 2 || near.count == 1 ? 1 : 2
        var yes = 0
        for (index, entry) in near.enumerated() {
            if try await agree(tab, entry.member) { yes += 1 }
            if yes >= need { return true }
            if yes + near.count - index - 1 < need { return false }
        }
        return false
    }

    func leans(_ tab: AIGroupTab, among members: [AIGroupTab]) async throws -> Bool {
        let near = members.map { (member: $0, weight: AIGroupEvidence.shared(tab, $0).count + meaning(tab, $0).count) }
            .filter { $0.weight > 0 }.sorted { $0.weight > $1.weight }.prefix(Self.asked)
        for entry in near {
            try Task.checkCancellation()
            if try await ask(tab, entry.member) { return true }
            if try await ask(entry.member, tab) { return true }
        }
        return false
    }

    func joins(_ tab: AIGroupTab, _ group: AIGroupInfo) async throws -> Bool {
        if try await fits(tab, among: group.members) { return true }
        guard group.settled, let belongs, try await leans(tab, among: group.members) else { return false }
        guard try await belongs(group, tab) else { return false }
        var turned = group
        turned.members.reverse()
        return try await belongs(turned, tab)
    }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        try await described(ask).sort(ask)
    }

    func sort(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        struct Made {
            var anchor: UUID
            var members: [AIGroupTab]
        }
        enum Place {
            case group(AIGroupInfo)
            case made(Int)
            case tab(AIGroupTab)
        }
        func weight(_ tab: AIGroupTab, _ members: [AIGroupTab]) -> Int {
            members.reduce(0) { $0 + self.weight(tab, $1) }
        }
        var picks: [UUID: AIGroupPick] = [:]
        var made: [Made] = []
        var loose = ask.loose + ask.fresh
        for tab in ask.fresh {
            picks[tab.id] = AIGroupPick.none
            guard loose.contains(where: { $0.id == tab.id }) else { continue }
            var places: [(score: Int, place: Place)] = []
            for group in ask.groups where !group.refused.contains(tab.key) {
                let score = weight(tab, group.members)
                if score > 0 { places.append((score + 100, .group(group))) }
            }
            for (index, group) in made.enumerated() {
                let score = weight(tab, group.members)
                if score > 0 { places.append((score + 100, .made(index))) }
            }
            for other in loose where other.id != tab.id {
                let score = weight(tab, [other])
                if score > 0 { places.append((score, .tab(other))) }
            }
            for entry in places.sorted(by: { $0.score > $1.score }).prefix(Self.reach) {
                switch entry.place {
                case .group(let group):
                    guard try await joins(tab, group) else { continue }
                    picks[tab.id] = .group(group.id)
                case .made(let index):
                    guard try await fits(tab, among: made[index].members) else { continue }
                    picks[tab.id] = .tab(made[index].anchor)
                    made[index].members.append(tab)
                case .tab(let other):
                    guard try await agree(tab, other) else { continue }
                    picks[tab.id] = .tab(other.id)
                    made.append(Made(anchor: other.id, members: [other, tab]))
                    loose.removeAll { $0.id == other.id }
                }
                loose.removeAll { $0.id == tab.id }
                break
            }
        }
        return picks
    }
}

enum AIGroupReader {
    static let script = """
    (() => {
      const said = (node) => node ? (node.getAttribute('content') || node.textContent || '').trim() : '';
      const first = (...queries) => {
        for (const query of queries) {
          const found = said(document.querySelector(query));
          if (found && !/^https?:/.test(found)) return found;
        }
        return '';
      };
      const named = (thing) => {
        if (!thing) return '';
        if (typeof thing === 'string') return /^https?:/.test(thing) ? '' : thing;
        if (Array.isArray(thing)) return named(thing[0]);
        return typeof thing.name === 'string' ? thing.name : '';
      };
      let by = '';
      if (/(^|\\.)youtube\\.com$/.test(location.hostname)) {
        by = first('ytd-watch-metadata ytd-channel-name a', '#owner ytd-channel-name a', 'ytd-video-owner-renderer #channel-name a');
        const video = said(document.querySelector('meta[itemprop="identifier"]'));
        if (!by && video && video === new URLSearchParams(location.search).get('v')) {
          by = first('span[itemprop="author"] link[itemprop="name"]');
        }
        return by.replace(/\\s+/g, ' ').slice(0, 80);
      }
      for (const block of document.querySelectorAll('script[type="application/ld+json"]')) {
        try {
          const parsed = JSON.parse(block.textContent);
          for (const entry of [].concat(parsed, parsed['@graph'] || [])) {
            by = named(entry && entry.author);
            if (by) break;
          }
        } catch (error) {}
        if (by) break;
      }
      if (!by) by = first('[itemprop="author"] [itemprop="name"]', 'meta[name="author"]', 'a[rel="author"]');
      return by.replace(/\\s+/g, ' ').slice(0, 80);
    })()
    """
}

extension Tab {
    var by: String {
        guard let madeBy, madeBy.page == pageAddress else { return "" }
        return madeBy.name
    }

    func readBy() async {
        guard let page = pageAddress, let built, !asleep else { return }
        let found: String = await withCheckedContinuation { done in
            built.evaluateJavaScript(AIGroupReader.script, in: nil, in: Web.world) { result in
                done.resume(returning: (try? result.get()) as? String ?? "")
            }
        }
        guard pageAddress == page else { return }
        if !found.isEmpty || madeBy?.page != page { madeBy = (page, found) }
    }
}

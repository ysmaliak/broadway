import Foundation

enum AIGroupNames {
    static let maxWords = 3
    static let maxLength = 32

    static let banned: Set<String> = [
        "watch", "online", "free", "download", "downloads", "stream", "streaming", "torrent", "hd", "1080p", "720p", "4k",
        "subtitles", "subs", "official", "website", "homepage", "results",
        "смотреть", "онлайн", "бесплатно", "бесплатный", "бесплатные", "скачать", "торрент", "качестве", "регистрации",
        "субтитрами", "официальный", "сайт",
    ]

    static let queryFiller: Set<String> = banned.union([
        "in", "on", "at", "with", "without", "for", "to", "of", "and", "or", "a", "an", "the", "full", "good", "quality",
        "english", "russian", "language", "original", "best", "top", "cheap", "near", "me", "how", "what", "where", "why",
        "в", "на", "с", "без", "и", "или", "по", "для", "от", "хорошем", "хорошее", "полностью", "все", "серии",
        "английском", "английский", "русском", "русский", "языке", "оригинале", "как", "где", "что",
    ])

    static let generic: Set<String> = [
        "tabs", "tab", "folder", "group", "misc", "other", "stuff", "pages", "links", "search", "travel", "flights",
        "documentation", "docs", "news", "shopping", "videos", "video", "movies", "web", "reading", "вкладки", "папка",
        "поиск", "разное", "видео", "фильмы",
    ]

    static let small: Set<String> = [
        "a", "an", "and", "as", "at", "by", "de", "for", "in", "la", "of", "on", "or", "the", "to", "vs", "with",
    ]

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map { String($0) }
    }

    static func bare(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    static func isYear(_ word: String) -> Bool {
        let plain = bare(word)
        guard plain.count == 4, let value = Int(plain) else { return false }
        return (1900...2099).contains(value)
    }

    static func site(_ host: String) -> String {
        let name = Vault.registrable(host)
        return name.split(separator: ".").first.map(String.init) ?? name
    }

    static func scripts(_ text: String) -> Set<Int> {
        Set(text.unicodeScalars.filter { $0.properties.isAlphabetic }.map { scalar in
            switch scalar.value {
            case ..<0x0250: return 0
            case 0x0370..<0x0400: return 1
            case 0x0400..<0x0530: return 2
            default: return Int(scalar.value >> 8)
            }
        })
    }

    static func twins(_ one: String, _ two: String) -> Bool {
        let first = stems(one), second = stems(two)
        return !first.isEmpty && first == second
    }

    static func stems(_ text: String) -> String {
        fold(text).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { word -> String in
            let plain = String(word)
            for ending in ["ches", "shes", "sses", "xes", "zes"] where plain.hasSuffix(ending) && plain.count > ending.count + 2 {
                return String(plain.dropLast(2))
            }
            if plain.hasSuffix("ies"), plain.count > 4 { return String(plain.dropLast(3)) + "y" }
            if plain.hasSuffix("s"), !plain.hasSuffix("ss"), plain.count > 3 { return String(plain.dropLast()) }
            return plain
        }.joined()
    }

    static func sameSubject(_ said: String, _ current: String) -> Bool {
        guard let head = AIGroupEvidence.tokens(current).first else { return false }
        return AIGroupEvidence.tokens(said).contains { AIGroupEvidence.same($0, head) }
    }

    static func describes(_ current: String, _ tabs: [AIGroupTab]) -> Bool {
        guard let head = AIGroupEvidence.tokens(current).first else { return false }
        let lacking = tabs.filter { tab in !AIGroupEvidence.tokens(tab.title + " " + tab.by).contains { AIGroupEvidence.same($0, head) } }
        return lacking.count <= max(1, tabs.count / 4)
    }

    static func problem(_ name: String, tabs: [AIGroupTab], query: String? = nil) -> String? {
        let words = tokens(name)
        guard !words.isEmpty else { return "it is empty" }
        if words.count > maxWords { return "it has more than three words" }
        if name.count > maxLength { return "it is too long" }
        if name.contains(where: { ".!?,;:|/\\()[]{}«»\"“”—–".contains($0) }) || words.contains("-") {
            return "it reads like a page title or a sentence"
        }
        if words.contains(where: { banned.contains(bare($0)) }) {
            return "it has words like watch online, free or download"
        }
        let folded = fold(name)
        let plain = folded.replacingOccurrences(of: " ", with: "")
        if let query, fold(query) == folded { return "it copies the search" }
        if tabs.contains(where: { fold($0.title) == folded }) { return "it copies a page title" }
        let common = query == nil ? AIGroupEvidence.common(tabs) : []
        if tabs.contains(where: { site($0.host).lowercased() == plain }), !AIGroupEvidence.holds(name, anyOf: common) {
            return "it is only a site's name"
        }
        if words.count == 1, generic.contains(bare(words[0])) { return "it is too generic" }
        if words.allSatisfy(isYear) { return "it is only a year" }
        let written = scripts(([query ?? ""] + tabs.map(\.title)).joined(separator: " "))
        if !written.isEmpty, !scripts(name).isSubset(of: written) { return "it is not in the language and alphabet of the tab titles" }
        return nil
    }

    static func spelled(_ name: String, like tabs: [AIGroupTab]) -> String {
        tokens(name).map { word in
            guard let key = AIGroupEvidence.tokens(word).first, AIGroupEvidence.tokens(word).count == 1 else { return word }
            let written = AIGroupEvidence.written(key, in: tabs)
            guard written.lowercased() == word.lowercased(), written.dropFirst().contains(where: \.isUppercase) else { return word }
            let numeral = (2...4).contains(written.count) && written.allSatisfy { "IVX".contains($0) }
            let mixed = written.contains(where: \.isLowercase) || written.contains(where: \.isNumber)
            return numeral || mixed ? written : word
        }.joined(separator: " ")
    }

    static func cased(_ name: String) -> String {
        var words = tokens(name)
        if words.count > 2 {
            let kept = words.filter { !isYear($0) }
            if !kept.isEmpty { words = kept }
        }
        guard let first = words.first?.first(where: \.isLetter) else { return words.joined(separator: " ") }
        let latin = first.unicodeScalars.allSatisfy { $0.properties.isAlphabetic && $0.value < 0x0250 }
        let hasCase = first.isUppercase || first.isLowercase
        guard hasCase else { return words.joined(separator: " ") }
        func capital(_ word: String) -> String {
            guard word == word.lowercased(), let head = word.first else { return word }
            return head.uppercased() + word.dropFirst()
        }
        if latin {
            return words.enumerated().map { index, word in
                index > 0 && small.contains(word) ? word : capital(word)
            }.joined(separator: " ")
        }
        return ([capital(words[0])] + words.dropFirst()).joined(separator: " ")
    }

    static func fromQuery(_ query: String) -> String? {
        func trimmed(_ words: [String]) -> [String] {
            var out = ArraySlice(words)
            while let first = out.first, queryFiller.contains(bare(first)) { out = out.dropFirst() }
            while let last = out.last, queryFiller.contains(bare(last)) { out = out.dropLast() }
            return Array(out)
        }
        let words = tokens(query).map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty && !banned.contains(bare($0)) && !isYear($0) }
        let kept = trimmed(Array(trimmed(words).prefix(maxWords)))
        guard !kept.isEmpty else { return nil }
        return cased(kept.joined(separator: " "))
    }

    static func shared(_ tabs: [AIGroupTab]) -> String? {
        guard tabs.count >= 2, let first = tabs.first else { return nil }
        let maker = AIGroupEvidence.by(first)
        if !maker.isEmpty, tabs.allSatisfy({ AIGroupEvidence.channel($0, first) || $0.id == first.id }) {
            let name = cased(tokens(first.by).prefix(maxWords).joined(separator: " "))
            if problem(name, tabs: tabs) == nil { return name }
        }
        let common = AIGroupEvidence.common(tabs).filter { !queryFiller.contains($0) }
        guard !common.isEmpty else { return nil }
        let name = cased(common.prefix(2).map { AIGroupEvidence.written($0, in: tabs) }.joined(separator: " "))
        return problem(name, tabs: tabs) == nil ? name : nil
    }

    static func fallback(_ tabs: [AIGroupTab], query: String? = nil) -> String {
        if let query, let name = fromQuery(query) { return name }
        if let name = shared(tabs) { return spelled(name, like: tabs) }
        let hosts = tabs.map { site($0.host) }
        if let first = hosts.first, hosts.allSatisfy({ $0 == first }) {
            return first.prefix(1).uppercased() + first.dropFirst()
        }
        return "Tabs"
    }
}

import Foundation

enum HistoryQuestion {
    private static let dull: Set<String> = [
        "a", "about", "an", "and", "any", "are", "article", "be", "blog", "can", "could", "did", "do", "does", "find", "for", "from", "had", "has",
        "have", "how", "i", "in", "is", "it", "its", "looked", "me", "mentioned", "my", "of", "on", "one", "page", "pages", "post", "read", "reading",
        "remember", "saw", "see", "seen", "show", "site", "some", "something", "tell", "that", "the", "there", "thing", "this", "those", "to", "was",
        "website", "were", "what", "whats", "when", "where", "which", "who", "why", "with", "you", "history", "browsing", "visited", "opened", "last", "at",
    ]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: \.isWhitespace).map { word in
            var word = String(word)
            while let last = word.last, !last.isLetter, !last.isNumber { word.removeLast() }
            while let first = word.first, !first.isLetter, !first.isNumber { word.removeFirst() }
            return word
        }
        .filter { !$0.isEmpty }
    }

    static func query(_ question: String, now: Date = Date(), calendar: Calendar = .current) -> PageQuery? {
        var head = tokens(question)
        var tail: [String] = []
        var trimming = true
        while trimming {
            trimming = false
            if head.count >= 2, ["this", "last"].contains(head[head.count - 2]), ["week", "month"].contains(head[head.count - 1]), !tail.contains(where: { ["today", "yesterday", "week", "month"].contains($0) }) {
                tail = Array(head.suffix(2)) + tail
                head.removeLast(2)
                trimming = true
            } else if let last = head.last, ["today", "yesterday"].contains(last), !tail.contains(where: { ["today", "yesterday", "week", "month"].contains($0) }) {
                tail.insert(last, at: 0)
                head.removeLast()
                trimming = true
            } else if head.count >= 2, ["on", "at", "from"].contains(head[head.count - 2]), head[head.count - 1].contains(".") {
                tail = Array(head.suffix(2)) + tail
                head.removeLast(2)
                trimming = true
            }
        }
        let wanted = head.filter { !dull.contains($0) }
        guard !wanted.isEmpty else { return nil }
        return PageQuery((wanted + tail).joined(separator: " "), minimumWords: 1, now: now, calendar: calendar)
    }

    static func find(_ question: String, in index: PageIndex, limit: Int = 8, now: Date = Date(), calendar: Calendar = .current) async -> [PageHit] {
        guard let query = query(question, now: now, calendar: calendar) else { return [] }
        let all = await index.search(query, limit: limit)
        guard all.isEmpty, query.words.count >= 2 else { return all }
        var tally: [String: (hit: PageHit, count: Int)] = [:]
        for word in query.words {
            var single = query
            single.words = [word]
            for hit in await index.search(single, limit: limit) {
                tally[hit.key] = (tally[hit.key]?.hit ?? hit, (tally[hit.key]?.count ?? 0) + 1)
            }
        }
        let least = query.words.count >= 3 ? 2 : 1
        return tally.values.filter { $0.count >= least }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.hit.visited > $1.hit.visited }
            .prefix(limit).map(\.hit)
    }
}

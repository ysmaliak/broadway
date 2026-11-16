import Foundation

struct TitleSettle: Equatable {
    static let quiet: TimeInterval = 0.35
    static let floor: TimeInterval = 0.12
    static let longest: TimeInterval = 1.5

    private(set) var booting = false
    private var loaded = false
    private var ended: TimeInterval = 0
    private var waiting: String?
    private var heard: TimeInterval = 0
    private var first: TimeInterval?

    mutating func committed(at now: TimeInterval) {
        booting = true
        loaded = false
        ended = 0
        waiting = nil
        first = nil
    }

    mutating func heard(_ title: String, at now: TimeInterval) -> String? {
        guard booting else { return title }
        guard !title.isEmpty else { return nil }
        waiting = title
        heard = now
        if first == nil { first = now }
        return due(at: now)
    }

    mutating func loadEnded(at now: TimeInterval) -> String? {
        guard booting, !loaded else { return nil }
        loaded = true
        ended = now
        if let waiting, now - heard >= TitleSettle.floor { return finish(waiting) }
        return nil
    }

    var deadline: TimeInterval? {
        guard booting else { return nil }
        if waiting != nil, let first { return min(heard + TitleSettle.quiet, first + TitleSettle.longest) }
        return loaded ? ended + TitleSettle.quiet : nil
    }

    mutating func tick(at now: TimeInterval) -> String? { due(at: now) }

    mutating func stop() {
        booting = false
        loaded = false
        waiting = nil
        first = nil
    }

    private mutating func due(at now: TimeInterval) -> String? {
        guard let deadline, now >= deadline - 0.001 else { return nil }
        return finish(waiting ?? "")
    }

    private mutating func finish(_ title: String) -> String {
        stop()
        return title
    }
}

enum TabHeading: Equatable {
    case blank
    case title(String)
    case address(URL)
}

enum TitleSource {
    static func best(history: String? = nil, named: String? = nil, link: String? = nil) -> String? {
        for candidate in [history, named, link] {
            if let clean = candidate.map(tidy), !clean.isEmpty { return clean }
        }
        return nil
    }

    static func tidy(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = words.joined(separator: " ")
        return joined.count > 200 ? String(joined.prefix(200)) : joined
    }

    static func heading(known: String?, url: URL?) -> TabHeading {
        if let known, !known.isEmpty { return .title(known) }
        if let url { return .address(url) }
        return .blank
    }
}

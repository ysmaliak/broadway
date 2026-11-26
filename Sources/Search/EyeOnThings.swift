import AppKit
import Observation
import CryptoKit
import Foundation

enum ReplyCheck {
    enum Change: Equatable {
        case same
        case replied(Int)
        case notTheSamePage
    }

    private static let passing = #"(?i)\b(ago|just now|yesterday|today|online|offline|typing|seen|edited|active)\b"#

    static func lines(in text: String) -> [String] {
        var kept = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let bare = line.lowercased().filter { !$0.isNumber }.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard bare.filter(\.isLetter).count >= 2 else { continue }
            if bare.count <= 40, bare.range(of: passing, options: .regularExpression) != nil { continue }
            kept.insert(SHA256.hash(data: Data(bare.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined())
        }
        return kept.sorted()
    }

    static func change(old: [String], new: [String]) -> Change {
        let before = Set(old), after = Set(new)
        guard !before.isEmpty, Double(before.intersection(after).count) >= Double(before.count) * 0.5 else { return .notTheSamePage }
        let added = after.subtracting(before).count
        return added == 0 ? .same : .replied(added)
    }
}

struct ReplyWatch: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let url: URL
    let title: String
    var lines: [String]
    var started: Date
    var replied: Date?
    var unreadable = false
}

@MainActor
protocol ReplyReader: AnyObject {
    func text(of url: URL) async -> String?
}

@MainActor
final class TabReplyReader: ReplyReader {
    private let window: @MainActor () -> Browser?

    init(window: @escaping @MainActor () -> Browser? = { Browsers.primary }) {
        self.window = window
    }

    func text(of url: URL) async -> String? {
        guard let browser = window() else { return nil }
        let tab = browser.benchOpen(url)
        tab.agent = true
        Bench.shared.house(tab)
        defer { browser.close(tab) }
        tab.web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        for _ in 0..<100 {
            try? await Task.sleep(for: .milliseconds(200))
            if !tab.loading { break }
        }
        try? await Task.sleep(for: .seconds(2))
        return await AIPage.read(tab)?.text
    }
}

@MainActor
@Observable
final class ReplyWatches {
    static let shared = ReplyWatches(file: Store.file("reply-watches.json"))
    static let every: TimeInterval = 15 * 60
    static let lasts: TimeInterval = 7 * 86_400
    static let rowLasts: TimeInterval = 3 * 86_400

    static func title(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    private let file: URL
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var begun = false
    @ObservationIgnored var reader: ReplyReader?

    private(set) var watches: [ReplyWatch] = []

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let saved = try? decoder.decode([ReplyWatch].self, from: data) {
            watches = saved
        } else {
            Store.quarantine(file)
        }
    }

    private func write() {
        let saved = watches
        Disk.write(file) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try? encoder.encode(saved)
        }
    }

    func begin(for browser: Browser) {
        self.browser = browser
        begun = true
        if reader == nil { reader = TabReplyReader() }
        startClock()
    }

    private func startClock() {
        guard timer == nil, begun, !watches.isEmpty else { return }
        let made = Timer(timeInterval: Self.every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check() }
            }
        }
        made.tolerance = 60
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    func add(url: URL, title: String, text: String, now: Date = Date()) {
        watches.removeAll { $0.url == url }
        watches.append(ReplyWatch(url: url, title: title, lines: ReplyCheck.lines(in: text), started: now))
        write()
        startClock()
    }

    func stop(_ id: UUID) {
        watches.removeAll { $0.id == id }
        write()
    }

    func check(now: Date = Date()) async {
        guard !checking, let reader else { return }
        if let browser = browser ?? Browsers.primary, !browser.prefs.agentsAllowed { return }
        checking = true
        defer { checking = false }
        watches.removeAll { now.timeIntervalSince($0.replied ?? $0.started) > ($0.replied == nil ? Self.lasts : Self.rowLasts) }
        for watch in watches where watch.replied == nil {
            let text = await reader.text(of: watch.url)
            guard let index = watches.firstIndex(where: { $0.id == watch.id }) else { continue }
            let found = text.map { ReplyCheck.change(old: watch.lines, new: ReplyCheck.lines(in: $0)) } ?? .notTheSamePage
            watches[index].unreadable = found == .notTheSamePage
            if case .replied = found { watches[index].replied = now }
        }
        write()
    }

    func rows(at now: Date) -> [NowRow] {
        watches.compactMap { watch -> NowRow? in
            guard let replied = watch.replied, now.timeIntervalSince(replied) <= Self.rowLasts else { return nil }
            return NowRow(id: "reply:\(watch.id.uuidString)", title: "Reply in \(watch.title)", detail: Address.pretty(watch.url),
                          symbol: "arrowshape.turn.up.left", url: watch.url, putOff: 3 * 3600) { browser in
                browser.open(watch.url, foreground: true)
            }
        }
    }
}

extension Browser {
    func watchForReply() {
        guard prefs.agentsAllowed else {
            announce("Turn on Let agents use Broadway first")
            return
        }
        guard let tab = active, tab.canBeRead, let url = tab.pageAddress else {
            announce("Broadway can't watch this tab")
            return
        }
        Task {
            guard let read = await AIPage.read(tab) else {
                announce("There's nothing to watch on this page")
                return
            }
            ReplyWatches.shared.add(url: url, title: ReplyWatches.title(tab.title), text: read.text)
            announce("Watching for a reply")
        }
    }
}

extension Tab {
    var neverSent: Bool {
        shy || built.map { !$0.configuration.websiteDataStore.isPersistent } == true
    }

    var canBeRead: Bool {
        guard isWeb, !neverSent, let scheme = pageAddress?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

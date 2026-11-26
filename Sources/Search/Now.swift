import AppKit

struct NowRow {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    var url: URL?
    var putOff: TimeInterval = 3600
    var stays = false
    let run: @MainActor (Browser) -> Void
}

@MainActor
enum NowBoard {
    typealias Rows = @MainActor (Browser, Date) -> [NowRow]

    static let limit = 5
    private static var sources: [(name: String, rows: Rows)] = [
        ("copied", { browser, now in
            copiedRow(CopiedLink.shared.copy, at: now, showing: browser.active?.shownURL).map { [$0] } ?? []
        }),
        ("meeting", { browser, now in
            guard browser.prefs.nextMeeting else { return [] }
            return meetingRow(Meetings.shared.next, at: now).map { [$0] } ?? []
        }),
        ("download", { browser, now in
            downloadRow(browser.loot.kept, at: now).map { [$0] } ?? []
        }),
        ("integrations", { browser, now in
            browser.prefs.liveFolders ? IntegrationNow.rows(from: LiveFolders.shared.folders.filter { $0.space == browser.spaceID }, at: now) : []
        }),
    ]
    private static var last: [String: NowRow] = [:]

    static func add(_ name: String, rows: @escaping Rows) {
        remove(name)
        sources.append((name, rows))
    }

    static func remove(_ name: String) {
        sources.removeAll { $0.name == name }
    }

    static func rows(for browser: Browser, at now: Date, memory: NowMemory = .shared) -> [NowRow] {
        let rows = sources.flatMap { $0.rows(browser, now) }.filter { !memory.hides($0.id, at: now) }
        let shown = Array(rows.prefix(limit))
        last = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return shown
    }

    static func row(_ id: String) -> NowRow? { last[id] }

    static func copiedRow(_ copy: CopiedLink.Copy?, at now: Date, showing page: URL?) -> NowRow? {
        guard let copy, now.timeIntervalSince(copy.at) <= 5 * 60 else { return nil }
        if let link = copy.link, let page, History.identity(for: link) == History.identity(for: page) { return nil }
        return NowRow(id: "copied:\(copy.change)", title: copy.link.map(Address.pretty) ?? "Open Copied Link",
                      detail: "Copied a moment ago", symbol: "link", url: copy.link) { browser in
            browser.openCopied(copy)
        }
    }

    static func meetingRow(_ meeting: Meeting?, at now: Date) -> NowRow? {
        guard let meeting else { return nil }
        let wait = meeting.event.start.timeIntervalSince(now)
        guard wait <= 3600, meeting.event.end > now else { return nil }
        let joinable = meeting.joinable(at: now)
        let said = meeting.said(at: now)
        return NowRow(id: "meeting:\(meeting.event.id):\(Int(meeting.event.start.timeIntervalSince1970))",
                      title: joinable ? "Join \(meeting.event.title)" : meeting.event.title,
                      detail: meeting.service.map { "\(said) · \($0.rawValue)" } ?? said,
                      symbol: joinable ? meeting.symbol : "calendar", putOff: joinable ? 5 * 60 : max(5 * 60, wait - 15 * 60), stays: !joinable) { browser in
            if joinable {
                browser.joinNextMeeting()
            } else {
                browser.openBefore(meeting, said: said)
            }
        }
    }

    static func downloadRow(_ kept: [Keep], at now: Date) -> NowRow? {
        guard let keep = kept.first(where: { now.timeIntervalSince($0.date) <= 15 * 60 }), keep.stillThere else { return nil }
        return NowRow(id: "download:\(Int(keep.date.timeIntervalSince1970 * 1000))", title: keep.name,
                      detail: "Downloaded a moment ago", symbol: "arrow.down.circle") { browser in
            browser.loot.open(keep)
        }
    }
}

@MainActor
final class NowMemory {
    static let shared = NowMemory(file: Store.file("now.json"))

    private let file: URL
    private var until: [String: Date] = [:]

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([String: Date].self, from: data) {
            until = read.filter { $0.value > Date() }
        }
    }

    func hides(_ id: String, at now: Date) -> Bool {
        until[id].map { $0 > now } ?? false
    }

    func done(_ id: String, at now: Date = Date()) {
        keep(id, until: now.addingTimeInterval(30 * 24 * 3600), at: now)
    }

    func putOff(_ id: String, for time: TimeInterval, at now: Date = Date()) {
        keep(id, until: now.addingTimeInterval(time), at: now)
    }

    func forget(_ id: String, at now: Date = Date()) {
        guard until.removeValue(forKey: id) != nil else { return }
        until = until.filter { $0.value > now }
        let snapshot = until
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }

    private func keep(_ id: String, until date: Date, at now: Date) {
        until = until.filter { $0.value > now }
        until[id] = date
        let snapshot = until
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}

@MainActor
protocol CopiedBoard: AnyObject {
    var change: Int { get }
    var secret: Bool { get }
    var free: Bool { get }
    func looksLikeLink() async -> Bool
    func text() -> String?
    var holdsText: Bool { get }
}

extension CopiedBoard {
    var holdsText: Bool { true }
}

final class MacClipboard: CopiedBoard {
    private let board: NSPasteboard

    init(board: NSPasteboard = .general) {
        self.board = board
    }

    var change: Int { board.changeCount }
    var secret: Bool { board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) ?? false }
    var free: Bool { board.accessBehavior == .alwaysAllow }

    func looksLikeLink() async -> Bool {
        let found = try? await board.detectedPatterns(for: [\.probableWebURL])
        return found?.contains(\.probableWebURL) ?? false
    }

    func text() -> String? { board.string(forType: .string) }

    var holdsText: Bool { board.types?.contains(.string) ?? false }
}

@MainActor
final class CopiedLink {
    struct Copy: Equatable {
        let change: Int
        let at: Date
        let link: URL?
    }

    static let shared = CopiedLink(board: Store.testing ? nil : MacClipboard())

    private(set) var copy: Copy?
    private var board: CopiedBoard?
    private var seen: Int

    init(board: CopiedBoard?) {
        self.board = board
        seen = board?.change ?? 0
    }

    func use(_ board: CopiedBoard?) {
        self.board = board
        seen = board?.change ?? 0
        copy = nil
    }

    func look(at now: Date = Date(), skipping: Bool, then: @escaping @MainActor () -> Void) {
        guard let board, board.change != seen else { return }
        let change = board.change
        seen = change
        copy = nil
        guard !skipping, !board.secret else { return }
        Task { [weak self] in
            guard await board.looksLikeLink(), let self, self.seen == change else { return }
            if board.free {
                guard let link = board.text().flatMap(Self.link(in:)) else { return }
                self.copy = Copy(change: change, at: now, link: link)
            } else {
                self.copy = Copy(change: change, at: now, link: nil)
            }
            then()
        }
    }

    func read() -> URL? {
        board?.text().flatMap(Self.link(in:))
    }

    nonisolated static func link(in text: String) -> URL? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, words.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
              let match = detector.firstMatch(in: words, range: NSRange(words.startIndex..., in: words)),
              match.range.length == (words as NSString).length,
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        else { return nil }
        return url
    }
}

extension Browser {
    func nowRows(at now: Date = Date()) -> [Suggestion] {
        return NowBoard.rows(for: self, at: now).map { row in
            var made = Suggestion(key: row.title, title: row.detail, url: row.url ?? FieldAction.nowhere,
                                  kind: .action("now:" + row.id))
            made.symbol = row.symbol
            return made
        }
    }

    func runNow(_ id: String) {
        guard let row = NowBoard.row(id) else { return }
        if !row.stays { NowMemory.shared.done(id) }
        row.run(self)
    }

    func noticeClipboard() {
        CopiedLink.shared.look(skipping: active?.shy == true) { [weak self] in
            guard let self, !self.fieldShowing, self.typed.isEmpty, !self.summoning else { return }
            self.retype()
        }
    }

    func openCopied(_ copy: CopiedLink.Copy) {
        guard let link = copy.link ?? CopiedLink.shared.read() else {
            announce("There's no link on the clipboard")
            return
        }
        open(link, foreground: true, from: active)
    }

    func openBefore(_ meeting: Meeting, said: String) {
        if meeting.link != nil {
            MeetingAlerts.shared.join(meeting, in: self)
        } else if let pin = tabs.first(where: { Meetings.isCalendar($0.address) }) {
            select(pin)
        } else {
            announce("\(meeting.event.title): \(said.lowercased())")
        }
    }

    private func nowID(of offer: Suggestion?) -> String? {
        guard case .action(let id)? = offer?.kind, id.hasPrefix("now:") else { return nil }
        return String(id.dropFirst("now:".count))
    }

    private func retypeKeepingNow() {
        let place = picked
        retype()
        guard let place, let section = fieldSections.first(where: { $0.title == "Now" }) else { return }
        picked = min(place, section.range.upperBound - 1)
    }

    func markNowDone(_ id: String) {
        NowMemory.shared.done(id)
        retypeKeepingNow()
    }

    func putNowOff(_ id: String) {
        guard let row = NowBoard.row(id) else { return }
        NowMemory.shared.putOff(id, for: row.putOff)
        retypeKeepingNow()
    }

    func handleNowKey(_ combo: KeyCombo) -> Bool {
        guard typed.isEmpty, let id = nowID(of: pickedOffer) else { return false }
        if combo == KeyCombo("delete", command: false) {
            markNowDone(id)
            return true
        }
        if combo == KeyCombo("return", command: false, option: true) {
            putNowOff(id)
            return true
        }
        return false
    }

    func addNowItems(_ offer: Suggestion, into items: inout [FieldMenuItem]) {
        guard let id = nowID(of: offer) else { return }
        items.append(FieldMenuItem(id: "done", title: "Mark Done", symbol: "checkmark", keys: "⌫") { [weak self] in
            self?.markNowDone(id)
        })
        items.append(FieldMenuItem(id: "putOff", title: "Put Off", symbol: "clock", keys: "⌥↩") { [weak self] in
            self?.putNowOff(id)
        })
    }
}

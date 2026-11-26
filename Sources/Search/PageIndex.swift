import Foundation
import SQLite3

struct PageHit: Identifiable, Equatable, Sendable {
    let key: String
    let url: URL
    let title: String
    let snippet: String
    let matched: String
    let visited: Date

    var id: String { key }

    static func plain(_ url: URL) -> URL {
        guard url.absoluteString.contains("#:~:") else { return url }
        return URL(string: url.absoluteString.components(separatedBy: "#:~:")[0]) ?? url
    }

    var opening: URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._~"))
        guard !matched.isEmpty, url.fragment == nil,
              let words = matched.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return url }
        return URL(string: url.absoluteString + "#:~:text=" + words) ?? url
    }
}

struct PageQuery: Equatable, Sendable {
    var words: [String]
    var since: Date?
    var until: Date?
    var site: String?

    init?(_ typed: String, minimumWords: Int = 2, now: Date = Date(), calendar: Calendar = .current, isSite: (String) -> Bool = { $0.contains(".") }) {
        var tokens = typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= minimumWords else { return nil }
        var since: Date?
        var until: Date?
        var site: String?
        let today = calendar.startOfDay(for: now)

        func interval(_ unit: Calendar.Component, back: Int) -> (Date, Date)? {
            guard let shifted = calendar.date(byAdding: unit, value: -back, to: now) else { return nil }
            return calendar.dateInterval(of: unit, for: shifted).map { ($0.start, $0.end) }
        }

        var trimming = true
        while trimming {
            trimming = false
            if since == nil, tokens.count > 2 {
                let phrase = tokens.suffix(2).joined(separator: " ")
                let found: (Date, Date)?
                switch phrase {
                case "this week": found = interval(.weekOfYear, back: 0)
                case "last week": found = interval(.weekOfYear, back: 1)
                case "this month": found = interval(.month, back: 0)
                case "last month": found = interval(.month, back: 1)
                default: found = nil
                }
                if let found {
                    (since, until) = (found.0, found.1)
                    tokens.removeLast(2)
                    trimming = true
                    continue
                }
            }
            if since == nil, tokens.count > 1, let last = tokens.last {
                if last == "today" {
                    since = today
                    tokens.removeLast()
                    trimming = true
                    continue
                }
                if last == "yesterday", let day = calendar.date(byAdding: .day, value: -1, to: today) {
                    (since, until) = (day, today)
                    tokens.removeLast()
                    trimming = true
                    continue
                }
            }
            if site == nil, tokens.count > 2, ["on", "at", "from"].contains(tokens[tokens.count - 2]), isSite(tokens[tokens.count - 1]) {
                site = tokens.last
                tokens.removeLast(2)
                trimming = true
            }
        }
        guard !tokens.isEmpty else { return nil }
        self.words = tokens
        self.since = since
        self.until = until
        self.site = site
    }

    var match: String {
        words.enumerated().map { index, word in
            let quoted = "\"" + word.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return index == words.count - 1 ? quoted + "*" : quoted
        }
        .joined(separator: " ")
    }
}

final class PageIndex: @unchecked Sendable {
    static let mostCharacters = 100_000

    private let file: URL
    private let queue = DispatchQueue(label: "search.pagetext", qos: .utility)
    private var db: OpaquePointer?

    init(file: URL) {
        self.file = file
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func add(key: String, url: URL, title: String, text: String, visited: Date = Date()) {
        queue.async { [self] in
            let body = Self.squeezed(text)
            guard !body.isEmpty, let db = connection(creating: true) else { return }
            guard exec(db, "BEGIN IMMEDIATE") else { return }
            var committed = false
            defer { if !committed { _ = exec(db, "ROLLBACK") } }
            let known = rows(db, "SELECT id FROM pages WHERE key = ?", [.text(key)]) { sqlite3_column_int64($0, 0) }.first
            let host = Self.bare(url.host()?.lowercased() ?? "")
            let id: Int64
            if let known {
                guard run(db, "DELETE FROM passages WHERE rowid = ?", [.int(known)]),
                      run(db, "UPDATE pages SET url = ?, host = ?, visited = ? WHERE id = ?",
                          [.text(url.absoluteString), .text(host), .real(visited.timeIntervalSince1970), .int(known)])
                else { return }
                id = known
            } else {
                guard run(db, "INSERT INTO pages(key, url, host, visited) VALUES (?, ?, ?, ?)",
                          [.text(key), .text(url.absoluteString), .text(host), .real(visited.timeIntervalSince1970)])
                else { return }
                id = sqlite3_last_insert_rowid(db)
            }
            guard run(db, "INSERT INTO passages(rowid, title, body) VALUES (?, ?, ?)",
                      [.int(id), .text(title), .text(body)])
            else { return }
            committed = exec(db, "COMMIT")
        }
    }

    struct Kept: Sendable {
        let key: String
        let url: URL
        let title: String
        let body: String
        let visited: Date
    }

    func remove(key: String, keeping: (@Sendable (Kept?) -> Void)? = nil) {
        queue.async { [self] in
            guard let db = connection(creating: false), exec(db, "BEGIN IMMEDIATE") else {
                keeping?(nil)
                return
            }
            if let keeping {
                let sql = "SELECT pages.url, passages.title, passages.body, pages.visited FROM passages CROSS JOIN pages ON pages.id = passages.rowid WHERE pages.key = ?"
                keeping(rows(db, sql, [.text(key)]) { row -> Kept? in
                    guard let address = sqlite3_column_text(row, 0), let url = URL(string: String(cString: address)) else { return nil }
                    return Kept(key: key, url: url, title: sqlite3_column_text(row, 1).map { String(cString: $0) } ?? "",
                                body: sqlite3_column_text(row, 2).map { String(cString: $0) } ?? "",
                                visited: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)))
                }.compactMap { $0 }.first)
            }
            let id = rows(db, "SELECT id FROM pages WHERE key = ?", [.text(key)]) { sqlite3_column_int64($0, 0) }.first
            if let id {
                _ = run(db, "DELETE FROM passages WHERE rowid = ?", [.int(id)])
                _ = run(db, "DELETE FROM pages WHERE id = ?", [.int(id)])
            }
            _ = exec(db, "COMMIT")
            scrub(db)
        }
    }

    func removeAll() {
        queue.async { [self] in
            if let db { sqlite3_close(db) }
            db = nil
            Self.deleteFiles(of: file)
        }
    }

    func keep(only keys: Set<String>) {
        queue.async { [self] in
            guard let db = connection(creating: false) else { return }
            let held: [(Int64, String)] = rows(db, "SELECT id, key FROM pages", []) {
                (sqlite3_column_int64($0, 0), String(cString: sqlite3_column_text($0, 1)))
            }
            let gone = held.filter { !keys.contains($0.1) }
            guard !gone.isEmpty, exec(db, "BEGIN IMMEDIATE") else { return }
            for page in gone {
                _ = run(db, "DELETE FROM passages WHERE rowid = ?", [.int(page.0)])
                _ = run(db, "DELETE FROM pages WHERE id = ?", [.int(page.0)])
            }
            _ = exec(db, "COMMIT")
            scrub(db)
        }
    }

    func search(_ query: PageQuery, limit: Int = 20) async -> [PageHit] {
        await withCheckedContinuation { done in
            queue.async(qos: .userInitiated, flags: .enforceQoS) { [self] in
                done.resume(returning: find(query, limit: limit))
            }
        }
    }

    func search(_ typed: String, limit: Int = 20) async -> [PageHit] {
        guard let query = PageQuery(typed, minimumWords: 1) else { return [] }
        return await search(query, limit: limit)
    }

    func count() async -> Int {
        await withCheckedContinuation { done in
            queue.async { [self] in
                guard let db = connection(creating: false) else {
                    done.resume(returning: 0)
                    return
                }
                let total = rows(db, "SELECT count(*) FROM pages", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
                done.resume(returning: total)
            }
        }
    }

    func settled() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }

    private func find(_ query: PageQuery, limit: Int) -> [PageHit] {
        guard let db = connection(creating: false) else { return [] }
        var filters = ""
        var values: [Bound] = [.text(query.match)]
        if let since = query.since {
            filters += " AND pages.visited >= ?"
            values.append(.real(since.timeIntervalSince1970))
        }
        if let until = query.until {
            filters += " AND pages.visited < ?"
            values.append(.real(until.timeIntervalSince1970))
        }
        if let site = query.site {
            filters += " AND instr(pages.host, ?) > 0"
            values.append(.text(site))
        }
        values.append(.int(Int64(limit)))
        let sql = """
            SELECT pages.key, pages.url, passages.title, pages.visited,
                   snippet(passages, 1, char(2), char(3), '…', 14)
            FROM passages CROSS JOIN pages ON pages.id = passages.rowid
            WHERE passages MATCH ?\(filters)
            ORDER BY bm25(passages, 4.0, 1.0), pages.visited DESC
            LIMIT ?
            """
        return rows(db, sql, values) { row -> PageHit? in
            guard let key = sqlite3_column_text(row, 0), let address = sqlite3_column_text(row, 1),
                  let url = URL(string: String(cString: address))
            else { return nil }
            let title = sqlite3_column_text(row, 2).map { String(cString: $0) } ?? ""
            let marked = sqlite3_column_text(row, 4).map { String(cString: $0) } ?? ""
            let (snippet, matched) = Self.unmarked(marked)
            return PageHit(key: String(cString: key), url: url, title: title,
                           snippet: snippet, matched: matched ?? "",
                           visited: Date(timeIntervalSince1970: sqlite3_column_double(row, 3)))
        }
        .compactMap { $0 }
    }

    static func unmarked(_ marked: String) -> (String, String?) {
        var plain = ""
        var first: String?
        var current: String?
        for character in marked {
            switch character {
            case "\u{2}": current = ""
            case "\u{3}":
                if first == nil { first = current }
                current = nil
            default:
                plain.append(character)
                current?.append(character)
            }
        }
        return (plain, first)
    }

    static func squeezed(_ text: String) -> String {
        String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(mostCharacters))
    }

    static func bare(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func deleteFiles(of file: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: file.path + suffix)
        }
    }

    private func connection(creating: Bool) -> OpaquePointer? {
        if let db { return db }
        if !creating, !FileManager.default.fileExists(atPath: file.path) { return nil }
        for attempt in 0..<2 {
            if let opened = open() { return opened }
            if attempt == 0 { Self.deleteFiles(of: file) }
        }
        return nil
    }

    private func open() -> OpaquePointer? {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle
        else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        let ready = exec(handle, "PRAGMA journal_mode = WAL")
            && exec(handle, "PRAGMA synchronous = NORMAL")
            && exec(handle, "PRAGMA secure_delete = ON")
            && exec(handle, "CREATE TABLE IF NOT EXISTS pages(id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, url TEXT NOT NULL, host TEXT NOT NULL, visited REAL NOT NULL)")
            && exec(handle, "CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(title, body, tokenize = \"unicode61 remove_diacritics 2\")")
            && exec(handle, "SELECT count(*) FROM pages")
        guard ready else {
            sqlite3_close(handle)
            return nil
        }
        db = handle
        return handle
    }

    private func scrub(_ db: OpaquePointer) {
        _ = exec(db, "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private enum Bound {
        case text(String)
        case int(Int64)
        case real(Double)
    }

    private func exec(_ db: OpaquePointer, _ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func prepared(_ db: OpaquePointer, _ sql: String, _ values: [Bound]) -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let place = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, place, text, -1, transient)
            case .int(let number): sqlite3_bind_int64(statement, place, number)
            case .real(let number): sqlite3_bind_double(statement, place, number)
            }
        }
        return statement
    }

    private func run(_ db: OpaquePointer, _ sql: String, _ values: [Bound]) -> Bool {
        guard let statement = prepared(db, sql, values) else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_DONE
    }

    private func rows<T>(_ db: OpaquePointer, _ sql: String, _ values: [Bound], _ read: (OpaquePointer) -> T) -> [T] {
        guard let statement = prepared(db, sql, values) else { return [] }
        defer { sqlite3_finalize(statement) }
        var found: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW { found.append(read(statement)) }
        return found
    }
}

extension Browser {
    nonisolated static let pageTextWait: TimeInterval = 2.5

    nonisolated static let pageTextScript = """
        (function () {
          if (!document.body || document.querySelector('input[type=password]')) return '';
          return (document.body.innerText || '').slice(0, \(PageIndex.mostCharacters));
        })()
        """

    func rememberText(of tab: Tab, at url: URL) {
        let key = History.identity(for: url)
        guard prefs.remembersPageText, history.wantsText(of: key) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pageTextWait) { [weak self, weak tab] in
            guard let self, let tab, !tab.shy, !tab.bench, tab.translator == nil, self.prefs.remembersPageText,
                  tab.address.map(History.identity(for:)) == key, let web = tab.built
            else { return }
            web.evaluateInSearch(Self.pageTextScript) { [weak self, weak tab] value in
                MainActor.assumeIsolated {
                    guard let self, let tab, !tab.shy, self.prefs.remembersPageText,
                          let text = value as? String, !text.isEmpty
                    else { return }
                    self.history.keepText(key: key, url: PageHit.plain(History.kept(url) ?? url), title: tab.title, text: text)
                }
            }
        }
    }

    func askPages() {
        guard prefs.remembersPageText, !summoning, siteChip == nil, fieldPlace == nil, active?.shy != true,
              Address.url(from: typed) == nil, let query = PageQuery(typed, isSite: history.namesSite)
        else { return }
        let asked = typed
        pageQuestion = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            let hits = await self.history.pages.search(query, limit: 3)
            guard !Task.isCancelled, self.typed == asked, self.fieldShowing, self.fieldPlace == nil else { return }
            self.showPages(hits)
        }
    }

    func showPages(_ hits: [PageHit]) {
        let seen = Set(offers.map { History.identity(for: $0.url) })
        let rows = hits.filter { !seen.contains($0.key) }.map { hit -> Suggestion in
            var row = Suggestion(key: Address.editable(hit.url), title: hit.title, url: hit.opening, kind: .passage)
            row.note = hit.snippet
            return row
        }
        guard !rows.isEmpty else { return }
        let place = offers.firstIndex { $0.kind == .suggested } ?? offers.endIndex
        if let picked, picked >= place { return }
        offers.insert(contentsOf: rows, at: place)
    }
}

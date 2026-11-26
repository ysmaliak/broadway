import Foundation
import SQLite3
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct ImportReaderTests {
    private func database(_ file: URL, _ statements: [String], blobs: [(String, Data)] = []) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(file.path, &db) == SQLITE_OK, let db else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        }
        for (sql, data) in blobs {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw CocoaError(.fileWriteUnknown) }
            defer { sqlite3_finalize(statement) }
            _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32(data.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            guard sqlite3_step(statement) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private func shape(_ marks: [Bookmark]) -> [String] {
        marks.map { mark in
            mark.isFolder ? "\(mark.title)[\(shape(mark.children ?? []).joined(separator: ","))]" : "\(mark.title) \(mark.url ?? "")"
        }
    }

    private static let chromiumDay: Int64 = 13_380_000_000_000_000

    @Test func aChromiumBrowsersHistoryIsReadNewestFirstWithItsWebPagesOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = Self.chromiumDay
        try database(root.appendingPathComponent("Default/History"), [
            "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER)",
            "INSERT INTO urls VALUES(1, 'https://example.com/a', 'A', 3, \(day), 0)",
            "INSERT INTO urls VALUES(2, 'http://shop.example/', 'Shop', 0, \(day + 2_000_000), 0)",
            "INSERT INTO urls VALUES(3, 'http://shop.example/cart', NULL, 1, \(day + 1_000_000), 0)",
            "INSERT INTO urls VALUES(4, 'ftp://example.com/', 'Files', 1, \(day + 3_000_000), 0)",
            "INSERT INTO urls VALUES(5, 'https://example.com/hidden', 'Hidden', 1, \(day + 4_000_000), 1)",
        ])
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)

        let places = Chromium.places(in: source)

        #expect(places.map(\.url.absoluteString) == ["http://shop.example/cart", "https://example.com/a"])
        #expect(places.map(\.title) == ["", "A"])
        #expect(places.map(\.count) == [1, 3])
        #expect(places.last?.last == Date(timeIntervalSince1970: Double(day) / 1_000_000 - 11_644_473_600))
        #expect(Chromium.preview(of: source, profile: nil).places == 2)
    }

    @Test func aChromiumBrowsersIconsComeFromThePageOrElseItsFrontDoor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let small = Data(repeating: 1, count: 70), large = Data(repeating: 2, count: 90), door = Data(repeating: 3, count: 80)
        try database(root.appendingPathComponent("Default/Favicons"), [
            "CREATE TABLE icon_mapping(page_url TEXT, icon_id INTEGER)",
            "CREATE TABLE favicon_bitmaps(icon_id INTEGER, width INTEGER, image_data BLOB)",
            "INSERT INTO icon_mapping VALUES('https://example.com/a', 1)",
            "INSERT INTO icon_mapping VALUES('https://example.com/a', 2)",
            "INSERT INTO icon_mapping VALUES('https://shop.example/', 3)",
            "INSERT INTO icon_mapping VALUES('https://example.org/', 4)",
        ], blobs: [
            ("INSERT INTO favicon_bitmaps VALUES(1, 16, ?)", small),
            ("INSERT INTO favicon_bitmaps VALUES(2, 32, ?)", large),
            ("INSERT INTO favicon_bitmaps VALUES(3, 32, ?)", door),
            ("INSERT INTO favicon_bitmaps VALUES(4, 32, ?)", Data(repeating: 4, count: 20)),
        ])
        try Data("{}".utf8).write(to: root.appendingPathComponent("Default/Bookmarks"))
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)
        let pages = ["https://example.com/a", "https://shop.example/deep/page", "https://example.org/"].compactMap(URL.init(string:))

        let icons = Chromium.icons(in: source, for: pages)

        let hosts = pages.compactMap(Favicons.site)
        #expect(icons.count == 2)
        #expect(icons[hosts[0]] == large)
        #expect(icons[hosts[1]] == door)
        #expect(icons[hosts[2]] == nil)
    }

    @Test func aChromiumBrowsersPasswordsAreCountedWithoutSitesMarkedNever() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try database(root.appendingPathComponent("Default/Login Data"), [
            "CREATE TABLE logins(origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER, date_last_used INTEGER)",
            "INSERT INTO logins VALUES('https://example.com/', 'me', x'0102', 0, 0)",
            "INSERT INTO logins VALUES('https://shop.example/', 'me', x'0304', 0, 0)",
            "INSERT INTO logins VALUES('https://example.org/', '', x'', 1, 0)",
            "INSERT INTO logins VALUES('https://example.net/', 'me', x'', 0, 0)",
        ])
        let source = Chromium.Source(name: "Fixture", folder: "", service: "", account: "", app: "", rootOverride: root)

        #expect(Chromium.preview(of: source, profile: nil).passwords == 2)
        #expect(Chromium.count("SELECT COUNT(*) FROM logins", in: root.appendingPathComponent("Default/Login Data")) == 4)
        #expect(Chromium.count("SELECT COUNT(*) FROM nothing", in: root.appendingPathComponent("Default/Login Data")) == 0)
        #expect(Chromium.count("SELECT COUNT(*) FROM logins", in: root.appendingPathComponent("Default/Missing")) == 0)
    }

    @Test func aSnapshotQueryWalksRowsInOrderAndFailsWithTheReadersOwnTrouble() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rows.sqlite")
        try database(file, ["CREATE TABLE t(n INTEGER)", "INSERT INTO t VALUES(3)", "INSERT INTO t VALUES(1)", "INSERT INTO t VALUES(2)"])
        var seen: [Int] = []
        try Snapshot.rows(file, "SELECT n FROM t ORDER BY rowid", failing: Mozilla.Trouble.unreadable) { seen.append(Int(sqlite3_column_int($0, 0))) }
        #expect(seen == [3, 1, 2])

        let text = root.appendingPathComponent("text.sqlite")
        try Data("not a database".utf8).write(to: text)
        do {
            try Snapshot.rows(text, "SELECT n FROM t", failing: Mozilla.Trouble.unreadable) { _ in }
            Issue.record("a file that is not a database was read")
        } catch let trouble as Mozilla.Trouble {
            #expect(trouble == .unreadable)
        }

        do {
            try Snapshot.rows(root.appendingPathComponent("missing.sqlite"), "SELECT 1", failing: Mozilla.Trouble.unreadable) { _ in }
            Issue.record("a missing file was read")
        } catch {
            #expect(!(error is Mozilla.Trouble))
        }
    }

    private func mozillaProfile() throws -> (source: Mozilla.Source, root: URL, profile: URL) {
        let folder = "SearchTests/\(UUID().uuidString)"
        let root = Chromium.base.appendingPathComponent(folder, isDirectory: true)
        let profile = root.appendingPathComponent("Profiles/x", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        return (Mozilla.Source(name: "Fixture", folders: ["\(folder)/Profiles"]), root, profile)
    }

    @Test func aMozillaBrowsersBookmarksAndHistoryAreReadFromPlaces() throws {
        let (source, root, profile) = try mozillaProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        try database(profile.appendingPathComponent("places.sqlite"), [
            "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_date INTEGER, hidden INTEGER)",
            "CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT)",
            "INSERT INTO moz_places VALUES(1, 'https://example.com/a', 'A', 2, 1700000000000000, 0)",
            "INSERT INTO moz_places VALUES(2, 'https://shop.example/', 'Shop', 1, 1700000100000000, 0)",
            "INSERT INTO moz_places VALUES(3, 'about:config', 'Config', 4, 1700000200000000, 0)",
            "INSERT INTO moz_places VALUES(4, 'https://example.org/', 'Never', 1, NULL, 0)",
            "INSERT INTO moz_bookmarks VALUES(1, 2, NULL, 0, 0, '', 'root________')",
            "INSERT INTO moz_bookmarks VALUES(2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____')",
            "INSERT INTO moz_bookmarks VALUES(3, 1, 1, 2, 0, 'A', 'a')",
            "INSERT INTO moz_bookmarks VALUES(4, 2, NULL, 2, 1, 'Shops', 'f')",
            "INSERT INTO moz_bookmarks VALUES(5, 1, 2, 4, 0, 'Shop', 's')",
            "INSERT INTO moz_bookmarks VALUES(6, 1, 3, 2, 2, 'Config', 'c')",
            "INSERT INTO moz_bookmarks VALUES(7, 2, NULL, 1, 1, 'unfiled', 'unfiled_____')",
            "INSERT INTO moz_bookmarks VALUES(8, 1, 1, 7, 0, 'Again', 'g')",
        ])

        let places = Mozilla.places(in: source)
        let marks = Mozilla.bookmarks(in: source)

        #expect(places.map(\.url.absoluteString) == ["https://shop.example/", "https://example.com/a"])
        #expect(places.map(\.count) == [1, 2])
        #expect(places.last?.last == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(shape(marks) == ["A https://example.com/a", "Shops[Shop https://shop.example/]", "Other[Again https://example.com/a]"])
        #expect(Mozilla.preview(of: source, profile: nil).places == 2)
    }

    @Test func aMozillaBrowsersIconsComeFromThePageOrElseItsFrontDoor() throws {
        let (source, root, profile) = try mozillaProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        try database(profile.appendingPathComponent("places.sqlite"), ["CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT)"])
        let large = Data(repeating: 2, count: 90), door = Data(repeating: 3, count: 80)
        try database(profile.appendingPathComponent("favicons.sqlite"), [
            "CREATE TABLE moz_pages_w_icons(id INTEGER PRIMARY KEY, page_url TEXT)",
            "CREATE TABLE moz_icons_to_pages(page_id INTEGER, icon_id INTEGER)",
            "CREATE TABLE moz_icons(id INTEGER PRIMARY KEY, width INTEGER, data BLOB)",
            "INSERT INTO moz_pages_w_icons VALUES(1, 'https://example.com/a')",
            "INSERT INTO moz_pages_w_icons VALUES(2, 'https://shop.example/')",
            "INSERT INTO moz_icons_to_pages VALUES(1, 1)",
            "INSERT INTO moz_icons_to_pages VALUES(1, 2)",
            "INSERT INTO moz_icons_to_pages VALUES(2, 3)",
        ], blobs: [
            ("INSERT INTO moz_icons VALUES(1, 16, ?)", Data(repeating: 1, count: 70)),
            ("INSERT INTO moz_icons VALUES(2, 32, ?)", large),
            ("INSERT INTO moz_icons VALUES(3, 32, ?)", door),
        ])
        let pages = ["https://example.com/a", "https://shop.example/deep/page", "https://example.org/"].compactMap(URL.init(string:))

        let icons = Mozilla.icons(in: source, for: pages)

        let hosts = pages.compactMap(Favicons.site)
        #expect(icons.count == 2)
        #expect(icons[hosts[0]] == large)
        #expect(icons[hosts[1]] == door)
    }
}

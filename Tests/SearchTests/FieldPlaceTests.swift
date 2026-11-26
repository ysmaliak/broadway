import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FieldPlaceTests {
    private var browser: Browser!
    private var marks: [Bookmark.ID] = []
    private var folder: URL!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.history.forget()
        browser.loot.forgetAll()
        for node in browser.bookmarks.roots { browser.bookmarks.remove(node.id) }
        PlaceFiles.done = []
        AnswerBoard.write("")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("field-places-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func tearDown() async {
        for id in marks { browser.bookmarks.remove(id) }
        marks = []
        browser.history.forget()
        browser.loot.forgetAll()
        browser.closeAll()
        browser = nil
        try? FileManager.default.removeItem(at: folder)
    }

    private func visit(_ address: String, _ title: String, minutesAgo: Double) {
        browser.history.take(URL(string: address)!, title: title, count: 3, last: Date().addingTimeInterval(-minutesAgo * 60))
        browser.history.settle()
    }

    private func keep(_ name: String, minutesAgo: Double, from host: String = "files.example", there: Bool = true) -> Keep {
        let file = folder.appendingPathComponent(name)
        if there { try? Data("x".utf8).write(to: file) }
        let keep = Keep(name: name, from: host, path: file.path, date: Date().addingTimeInterval(-minutesAgo * 60))
        browser.loot.add(keep)
        return keep
    }

    private func mark(_ title: String, _ address: String, in parent: Bookmark.ID? = nil) -> Bookmark {
        let made = browser.bookmarks.insert(Bookmark.site(title, URL(string: address)!), into: parent)
        if parent == nil { marks.append(made.id) }
        return made
    }

    private func titles() -> [String] { browser.offers.map(\.primary) }

    private func press(_ key: String, command: Bool = false, shift: Bool = false, control: Bool = false) -> Bool {
        browser.placeKey(KeyCombo(key, command: command, shift: shift, control: control))
    }

    @Test func aNameAndTabOffersThePlace() {
        let cases: [(String, FieldPlace?)] = [
            ("hist", .history), ("History", .history), ("his", nil), ("book", .bookmarks), ("downl", .downloads),
            ("files", .downloads), ("закл", .bookmarks), ("исто", .history), ("file:///tmp", nil), ("historyx", nil),
        ]

        for (typed, place) in cases {
            #expect(FieldPlace.offered(for: typed) == place, "\(typed)")
        }
    }

    @Test func typingANameOffersItAndTabEntersIt() {
        visit("https://older.example/a", "Older page", minutesAgo: 30)
        browser.edit()

        browser.typed = "hist"

        #expect(browser.placeOffer == .history)
        #expect(browser.siteOffer == nil)

        let took = browser.lockSiteOffer()

        #expect(took)
        #expect(browser.fieldPlace == .history)
        #expect(browser.typed == "")
        #expect(browser.placeOffer == nil)
        #expect(titles() == ["Older page"])
    }

    @Test func historyIsNewestFirstAndFilteredByEveryWord() {
        visit("https://swift.org/blog", "Swift blog", minutesAgo: 60)
        visit("https://news.example/today", "Morning news", minutesAgo: 5)
        visit("https://swift.org/docs", "Swift documentation", minutesAgo: 20)
        browser.edit()
        browser.enterPlace(.history)

        #expect(titles() == ["Morning news", "Swift documentation", "Swift blog"])
        #expect(browser.picked == 0)

        browser.typed = "swift doc"

        #expect(titles() == ["Swift documentation"])

        browser.typed = "news.example"

        #expect(titles() == ["Morning news"])
    }

    @Test func forgetFromHistoryShowsShiftDeleteAndTakesControlXInTheMainList() throws {
        visit("https://keys.example/page", "Keys page", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.history)
        let placed = browser.fieldMenuItems(for: browser.pickedOffer).first { $0.title == "Forget from History" }
        browser.quitField()
        browser.edit()
        browser.offers = [Suggestion(key: "keys.example/page", title: "Keys page", url: URL(string: "https://keys.example/page")!, kind: .visited)]
        browser.picked = 0
        let listed = browser.fieldMenuItems(for: browser.pickedOffer).first { $0.title == "Forget from History" }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{18}", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))

        let taken = browser.fieldKey(event)

        #expect(placed?.keys == "⇧⌫")
        #expect(listed?.keys == "⇧⌫")
        #expect(taken)
        #expect(browser.announcement == "Forgot Keys page")
        #expect(FieldPlace.history.hints(splits: false).map(\.keys) == ["⌘↩", "⇧⌘C", "⇧⌫"])
        #expect(FieldPlace.history.hints(splits: false).first?.word == "Background")
    }

    @Test func clearHistoryInAHistoryRowsMenuComesLastAfterARuleAndAsksFirst() throws {
        visit("https://clear.example/page", "Clear page", minutesAgo: 1)
        browser.edit()
        let row = Suggestion(key: "clear.example/page", title: "Clear page", url: URL(string: "https://clear.example/page")!, kind: .visited)
        let items = browser.fieldMenuItems(for: row)
        let last = try #require(items.last)
        Ask.asked = []
        Ask.testing = false
        defer { Ask.testing = nil }

        last.run()

        #expect(last.title == "Clear History…")
        #expect(last.parted)
        #expect(!items.contains { $0.title == "Forget Everything" })
        #expect(Ask.asked == ["Clear history?"])
        #expect(browser.history.trace(History.identity(for: URL(string: "https://clear.example/page")!)) != nil)
    }

    @Test func historyRowsAreCapped() {
        for index in 0..<(FieldPlace.most + 10) {
            visit("https://many.example/\(index)", "Page \(index)", minutesAgo: Double(index))
        }

        browser.edit()
        browser.enterPlace(.history)

        #expect(browser.offers.count == FieldPlace.most)
        #expect(browser.offers.first?.primary == "Page 0")
        #expect(browser.offers.last?.primary == "Page \(FieldPlace.most - 1)")
    }

    @Test func answersSnippetsAndTheEngineStayOutOfAPlace() {
        visit("https://maths.example/", "2 + 2 tables", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.history)

        browser.typed = "2 + 2"

        #expect(!browser.offers.contains { if case .answer = $0.kind { return true } else { return false } })
        #expect(browser.offers.allSatisfy { $0.placed != nil })
        #expect(browser.engineQuestion(for: browser.typed) == nil)
        #expect(browser.ending == nil)
    }

    @Test func walkingKeepsTheQueryInTheField() {
        visit("https://one.example/", "One", minutesAgo: 1)
        visit("https://two.example/", "Two", minutesAgo: 2)
        browser.edit()
        browser.enterPlace(.history)
        browser.typed = "example"

        browser.walk(1)

        #expect(browser.picked == 1)
        #expect(browser.completed == "example")
    }

    @Test func escapeClearsTheQueryThenLeavesThePlaceThenGivesWay() {
        browser.edit()
        browser.enterPlace(.bookmarks)
        browser.typed = "zz"

        #expect(browser.escapePlace())
        #expect(browser.typed == "")
        #expect(browser.fieldPlace == .bookmarks)

        #expect(browser.escapePlace())
        #expect(browser.fieldPlace == nil)
        #expect(browser.picked == nil)

        #expect(!browser.escapePlace())
    }

    @Test func closingTheFieldLeavesThePlace() {
        _ = browser.open(URL(string: "about:blank#page")!, foreground: true)
        browser.edit()
        browser.enterPlace(.downloads)

        browser.quitField()

        #expect(browser.fieldPlace == nil)
    }

    @Test func downloadsAreNewestFirstAndFindByNameOrSite() {
        _ = keep("report.pdf", minutesAgo: 30, from: "bank.example")
        _ = keep("photo.jpg", minutesAgo: 2, from: "camera.example")
        _ = keep("notes.txt", minutesAgo: 10)

        browser.edit()
        browser.enterPlace(.downloads)

        #expect(titles() == ["photo.jpg", "notes.txt", "report.pdf"])

        browser.typed = "bank"

        #expect(titles() == ["report.pdf"])
    }

    @Test func downloadsFilterIsPure() {
        let now = Date()
        let kept = (0..<50).map { Keep(name: "file\($0).zip", from: "host\($0 % 2).example", path: "/tmp/\($0)", date: now.addingTimeInterval(Double(-$0))) }

        let found = FieldPlace.downloads(kept.shuffled(), matching: "host1 zip", limit: 5)

        #expect(found.map(\.name) == ["file1.zip", "file3.zip", "file5.zip", "file7.zip", "file9.zip"])
    }

    @Test func bookmarksKeepTheirOrderAndFindByFolder() {
        let work = browser.bookmarks.insert(Bookmark.folder("Work", []), into: nil)
        marks.append(work.id)
        _ = mark("Tracker", "https://tracker.example/", in: work.id)
        _ = mark("Recipes", "https://food.example/")
        _ = mark("Run this", "javascript:alert(1)")

        browser.edit()
        browser.enterPlace(.bookmarks)

        #expect(titles() == ["Tracker", "Recipes"])
        #expect(browser.offers.first?.placed?.aside == "Work")

        browser.typed = "work"

        #expect(titles() == ["Tracker"])
    }

    @Test func controlXForgetsAHistoryPageAndUndoBringsItBack() {
        visit("https://keep.example/", "Keep", minutesAgo: 1)
        visit("https://drop.example/", "Drop", minutesAgo: 2)
        browser.edit()
        browser.enterPlace(.history)
        browser.picked = 1

        let taken = press("x", control: true)

        #expect(taken)
        #expect(!browser.history.knows(History.identity(for: URL(string: "https://drop.example/")!)))
        #expect(titles() == ["Keep"])
        #expect(browser.picked == 0)
        #expect(browser.announcement == "Forgot Drop")
        #expect(browser.announcedUndo != nil)

        browser.undoAnnounced()

        #expect(titles() == ["Keep", "Drop"])
        #expect(browser.history.trace(History.identity(for: URL(string: "https://drop.example/")!))?.count == 3)
        #expect(browser.announcement == nil)
    }

    @Test func controlXRemovesABookmarkAndUndoPutsItBackInItsFolder() throws {
        let work = browser.bookmarks.insert(Bookmark.folder("Work", []), into: nil)
        marks.append(work.id)
        _ = mark("First", "https://first.example/", in: work.id)
        let second = mark("Second", "https://second.example/", in: work.id)
        _ = mark("Third", "https://third.example/", in: work.id)
        browser.edit()
        browser.enterPlace(.bookmarks)
        browser.picked = 1

        #expect(press("x", control: true))

        #expect(browser.bookmarks.bookmark(second.id) == nil)
        #expect(titles() == ["First", "Third"])

        browser.undoAnnounced()

        let folder = try #require(browser.bookmarks.bookmark(work.id))
        #expect(folder.children?.map(\.title) == ["First", "Second", "Third"])
        #expect(browser.bookmarks.bookmark(second.id)?.id == second.id)
    }

    @Test func controlXTakesADownloadOffTheListButNeverTheFile() {
        let file = keep("keep-me.pdf", minutesAgo: 1)
        _ = keep("older.pdf", minutesAgo: 9)
        browser.edit()
        browser.enterPlace(.downloads)

        #expect(press("x", control: true))

        #expect(!browser.loot.kept.contains { $0.path == file.path })
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(titles() == ["older.pdf"])

        browser.undoAnnounced()

        #expect(browser.loot.kept.map(\.name) == ["keep-me.pdf", "older.pdf"])
        #expect(titles() == ["keep-me.pdf", "older.pdf"])
    }

    @Test func commandZUndoesTheLastRemovalEvenWithNoRowLeft() {
        _ = keep("only.pdf", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.downloads)
        #expect(press("x", control: true))
        #expect(browser.offers.isEmpty)

        let taken = press("z", command: true)

        #expect(taken)
        #expect(titles() == ["only.pdf"])
        #expect(!press("z", command: true))
    }

    @Test func theSwitcherLeavesThePlace() {
        browser.edit()
        browser.enterPlace(.history)

        browser.summon()

        #expect(browser.fieldPlace == nil)
    }

    @Test func commandRRevealsOnlyADownload() {
        let file = keep("shown.pdf", minutesAgo: 1)
        visit("https://page.example/", "Page", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.history)

        #expect(!press("r", command: true))

        browser.enterPlace(.downloads)
        let taken = press("r", command: true)

        #expect(taken)
        #expect(PlaceFiles.done == ["reveal " + file.path])
        #expect(!browser.editing)
    }

    @Test func shiftCommandCCopiesTheLinkOrThePath() {
        let file = keep("path.pdf", minutesAgo: 1)
        visit("https://copy.example/page", "Copy me", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.history)

        #expect(press("c", command: true, shift: true))

        #expect(AnswerBoard.written == "https://copy.example/page")
        #expect(browser.announcement == "Link copied")
        #expect(browser.fieldPlace == .history)

        browser.enterPlace(.downloads)
        #expect(press("c", command: true, shift: true))

        #expect(AnswerBoard.written == file.path)
        #expect(browser.announcement == "Path copied")
    }

    @Test func returnOnADownloadOpensTheFileAndNeverLoadsIt() {
        let page = browser.open(URL(string: "about:blank#page")!, foreground: true)
        let file = keep("open-me.pdf", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.downloads)

        browser.submit()

        #expect(PlaceFiles.done == ["open " + file.path])
        #expect(page.address?.isFileURL != true)
        #expect(browser.fieldPlace == nil)
        #expect(!browser.editing)
    }

    @Test func aMissingDownloadSaysSoAndStays() throws {
        _ = keep("gone.pdf", minutesAgo: 1, there: false)
        browser.edit()
        browser.enterPlace(.downloads)

        browser.submit()

        #expect(browser.offers.first?.placed?.missing == true)
        #expect(browser.returnIsIdle)
        #expect(PlaceFiles.done.isEmpty)
        #expect(browser.fieldPlace == .downloads)

        browser.take(try #require(browser.offers.first))

        #expect(PlaceFiles.done.isEmpty)
        #expect(browser.announcement == "gone.pdf isn't there any more")
        #expect(browser.fieldPlace == .downloads)
    }

    @Test func returnWithNoMatchDoesNothing() {
        let page = browser.open(URL(string: "about:blank#stay")!, foreground: true)
        browser.edit()
        browser.enterPlace(.history)
        browser.typed = "nothing like this"
        let tabs = browser.tabs.count

        browser.submit()

        #expect(browser.returnIsIdle)
        #expect(browser.tabs.count == tabs)
        #expect(page.address?.absoluteString == "about:blank#stay")
        #expect(browser.fieldPlace == .history)
    }

    @Test func commandReturnOpensAHistoryPageInANewTab() {
        _ = browser.open(URL(string: "about:blank#here")!, foreground: true)
        visit("https://aside.example/", "Aside", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.history)
        let tabs = browser.tabs.count

        browser.submit(aside: true)

        #expect(browser.tabs.count == (tabs + 1))
        #expect(browser.fieldPlace == nil)
    }

    @Test func commandKInAPlaceOffersTheRowsKeysAndTheFullPage() {
        _ = keep("menu.pdf", minutesAgo: 1)
        visit("https://menu.example/", "Menu", minutesAgo: 1)
        browser.edit()
        browser.enterPlace(.downloads)

        let items = browser.fieldMenuItems(for: browser.pickedOffer)
        let resting = browser.fieldMenuItems(for: nil)

        #expect(items.map(\.keys) == ["↩", "⌘R", "⇧⌘C", "⌃X", ""])
        #expect(items.last?.title == "Clear List")
        #expect(resting.map(\.title) == ["Clear List"])

        browser.enterPlace(.history)

        #expect(browser.fieldMenuItems(for: browser.pickedOffer).last?.title == "Open History Page")
        #expect(browser.fieldMenuItems(for: nil).map(\.title) == ["Open History Page"])
    }

    @Test func privateWindowsLeaveNothingInTheHistoryPlace() async throws {
        let server = try LocalPageServer([
            "/open": .init(type: "text/html", body: "<!doctype html><title>Open page</title><p>open"),
            "/hidden": .init(type: "text/html", body: "<!doctype html><title>Hidden page</title><p>hidden"),
        ])
        defer { server.stop() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [], backing: .buffered, defer: false)
        let open = browser.open(server.url("/open"), foreground: true)
        window.contentView = open.web
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        quiet.arrive(server.url("/hidden"))
        let hidden = try #require(quiet.active)
        #expect(hidden.shy)
        let key = History.identity(for: server.url("/open"))
        for _ in 0..<200 where !browser.history.knows(key) || browser.history.title(for: server.url("/open")) != "Open page" || hidden.web.isLoading || hidden.web.url == nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(browser.history.knows(key))
        #expect(hidden.web.url == server.url("/hidden"))

        browser.edit()
        browser.enterPlace(.history)

        #expect(titles() == ["Open page"])
        #expect(!browser.offers.contains { $0.url.path == "/hidden" })
        window.contentView = nil
    }

    @Test func newestScansWithoutSortingEverything() {
        for index in 0..<5000 {
            browser.history.take(URL(string: "https://bulk.example/\(index)")!, title: "Bulk \(index)", count: 1,
                                 last: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
        }
        browser.history.settle()

        let started = Date()
        let found = browser.history.newest(matching: "bulk", limit: FieldPlace.most)
        let took = Date().timeIntervalSince(started)

        #expect(found.first?.title == "Bulk 4999")
        #expect(found.count == FieldPlace.most)
        #expect(took < 0.25)
    }
}

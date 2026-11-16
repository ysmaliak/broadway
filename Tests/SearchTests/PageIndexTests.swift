import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PageIndexTests {
    private var folder: URL!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("page-index-\(UUID().uuidString)")
    }

    private func tearDown() async {
        try? FileManager.default.removeItem(at: folder)
    }

    private func index() -> PageIndex { PageIndex(file: folder.appendingPathComponent("text.sqlite")) }
    private func url(_ text: String) -> URL { URL(string: text)! }

    private func history() -> History {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return History(file: folder.appendingPathComponent("history.json"), pages: folder.appendingPathComponent("pagetext.sqlite"))
    }

    @Test func findsPagesByTheirWordsWithASnippet() async {
        let pages = index()
        pages.add(key: "https://stripe.com/a", url: url("https://stripe.com/a"), title: "Billing",
                  text: "Your  invoice\n\nfor October is ready to download from the portal")
        pages.add(key: "https://news.example/b", url: url("https://news.example/b"), title: "News",
                  text: "Nothing about money here at all")

        let hits = await pages.search("invoice october")

        #expect(hits.map(\.key) == ["https://stripe.com/a"])
        #expect(hits[0].snippet.contains("invoice for October"), "\(hits[0].snippet)")
        #expect(hits[0].matched.lowercased() == "invoice")
        #expect(hits[0].opening.absoluteString == "https://stripe.com/a#:~:text=invoice")
    }

    @Test func lastWordMatchesWhileStillBeingTyped() async {
        let pages = index()
        pages.add(key: "k", url: url("https://a.example/"), title: "T", text: "quarterly reconciliation notes")

        let hits = await pages.search("quarterly recon")

        #expect(hits.count == 1)
    }

    @Test func aPageRevisitedKeepsOneRowWithItsNewText() async {
        let pages = index()
        pages.add(key: "k", url: url("https://a.example/"), title: "One", text: "first words")
        pages.add(key: "k", url: url("https://a.example/"), title: "Two", text: "second words")

        let old = await pages.search("first")
        let new = await pages.search("second")
        let count = await pages.count()

        #expect(old.isEmpty)
        #expect(new.first?.title == "Two")
        #expect(count == 1)
    }

    @Test func removingAPageRemovesItsWords() async {
        let pages = index()
        pages.add(key: "k", url: url("https://a.example/"), title: "T", text: "secret words")

        pages.remove(key: "k")
        let hits = await pages.search("secret")

        #expect(hits.isEmpty)
    }

    @Test func removeAllDeletesTheFiles() async {
        let pages = index()
        let file = folder.appendingPathComponent("text.sqlite")
        pages.add(key: "k", url: url("https://a.example/"), title: "T", text: "words")
        await pages.settled()
        #expect(FileManager.default.fileExists(atPath: file.path))

        pages.removeAll()
        await pages.settled()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.path + "-wal"))
        let hits = await pages.search("words")
        #expect(hits.isEmpty)
        pages.add(key: "k", url: url("https://a.example/"), title: "T", text: "words")
        let again = await pages.search("words")
        #expect(again.count == 1)
    }

    @Test func keepOnlyDropsWhatHistoryLetGoOf() async {
        let pages = index()
        pages.add(key: "stays", url: url("https://a.example/"), title: "T", text: "words")
        pages.add(key: "goes", url: url("https://b.example/"), title: "T", text: "words")

        pages.keep(only: ["stays"])
        let hits = await pages.search("words")

        #expect(hits.map(\.key) == ["stays"])
    }

    @Test func punctuationAndQuotesCannotBreakTheQuery() async {
        let pages = index()
        pages.add(key: "k", url: url("https://a.example/"), title: "T", text: "plain words")

        let hits = await pages.search("\"plain\" AND (NEAR words*")

        #expect(hits.isEmpty)
    }

    @Test func nothingIsCreatedOnDiskUntilAPageIsKept() async {
        let pages = index()

        _ = await pages.search("anything")
        pages.keep(only: [])
        await pages.settled()

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("text.sqlite").path))
    }

    @Test func theTextHeldForAPageHasACeiling() {
        let long = String(repeating: "word ", count: PageIndex.mostCharacters)

        let squeezed = PageIndex.squeezed(long)

        #expect(squeezed.count == PageIndex.mostCharacters)
    }

    @Test func searchHonoursWhenAndWhere() async {
        let pages = index()
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: now)!
        let lastYear = calendar.date(byAdding: .year, value: -1, to: now)!
        pages.add(key: "s", url: url("https://www.stripe.com/1"), title: "S", text: "invoice paid", visited: lastWeek)
        pages.add(key: "o", url: url("https://old.stripe.com/2"), title: "O", text: "invoice paid", visited: lastYear)
        pages.add(key: "g", url: url("https://gusto.com/3"), title: "G", text: "invoice paid", visited: lastWeek)

        let query = PageQuery("invoice last week on stripe", now: now, calendar: calendar)!
        let hits = await pages.search(query)

        #expect(query.words == ["invoice"])
        #expect(query.site == "stripe")
        #expect(hits.map(\.key) == ["s"])
    }

    @Test func queriesNeedTwoWordsInTheField() {
        #expect(PageQuery("invoice") == nil)
        #expect(PageQuery("   ") == nil)
        #expect(PageQuery("on stripe")?.words == ["on", "stripe"])
        #expect(PageQuery("invoice today")?.words == ["invoice"])
        #expect(PageQuery("invoice", minimumWords: 1)?.words == ["invoice"])
    }

    @Test func yesterdayIsThatDayAlone() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 12))!

        let query = PageQuery("receipt yesterday", now: now, calendar: calendar)

        #expect(query?.since == calendar.date(from: DateComponents(year: 2026, month: 11, day: 17)))
        #expect(query?.until == calendar.date(from: DateComponents(year: 2026, month: 11, day: 18)))
    }

    @Test func forgettingFromHistoryForgetsTheText() async {
        _ = NSApplication.shared
        let history = self.history()
        let page = url("https://forget.example/page")
        let key = History.identity(for: page)
        history.record(page, title: "Page")
        history.keepText(key: key, url: page, title: "Page", text: "unforgettable passage")
        let before = await history.pages.search("unforgettable")
        #expect(before.count == 1)

        history.forget(key)
        let after = await history.pages.search("unforgettable")

        #expect(after.isEmpty)
        #expect(!history.knows(key))
    }

    @Test func clearingHistoryForgetsAllText() async {
        _ = NSApplication.shared
        let history = self.history()
        let page = url("https://clear.example/page")
        history.record(page, title: "Page")
        history.keepText(key: History.identity(for: page), url: page, title: "Page", text: "clearable passage")

        history.forget()
        let count = await history.pages.count()

        #expect(count == 0)
    }

    @Test func textForAPageNotInHistoryIsRefused() async {
        _ = NSApplication.shared
        let history = self.history()
        let page = url("https://gone.example/page")

        history.keepText(key: History.identity(for: page), url: page, title: "Page", text: "late arrival")
        let hits = await history.pages.search("arrival")

        #expect(hits.isEmpty)
    }

    @Test func aPageIsNotReadAgainStraightAway() {
        _ = NSApplication.shared
        let history = self.history()
        let page = url("https://again.example/page")
        let key = History.identity(for: page)
        history.record(page, title: "Page")
        #expect(history.wantsText(of: key))

        history.keepText(key: key, url: page, title: "Page", text: "words")

        #expect(!history.wantsText(of: key))
        #expect(history.wantsText(of: key, now: Date().addingTimeInterval(601)))
    }

    @Test func fieldAddsPageRowsBeforeTheEnginesAndSkipsWhatIsListed() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let hit = PageHit(key: "https://a.example/x", url: url("https://a.example/x"), title: "Stripe invoice",
                          snippet: "the invoice is here", matched: "invoice", visited: Date())
        browser.offers = [Suggestion(key: "invoice paid", title: "Google", url: url("https://google.com/s"), kind: .search),
                          Suggestion(key: "invoice paid now", title: "", url: url("https://google.com/t"), kind: .suggested)]

        browser.showPages([hit])

        #expect(browser.offers.map(\.kind) == [.search, .passage, .suggested])
        #expect(browser.offers[1].url.absoluteString == "https://a.example/x#:~:text=invoice")
        browser.showPages([hit])
        #expect(browser.offers.count == 3)
    }

    @Test func privateFieldDoesNotAskThePages() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { browser.closeAll() }

        browser.pageQuestion = nil
        browser.typed = "two words"

        #expect(browser.pageQuestion == nil)
    }
}

import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SearchFolderTests {
    private func browser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        keepSetting(AIGroups.shared, \.on, AIGroups.onKey)
        AIGroups.shared.on = false
        addTeardownBlock { @MainActor in
            browser.closeAll()
        }
        return browser
    }

    private func result(_ text: String) -> URL { URL(string: text)! }

    @Test func everyEngineGivesItsQuery() {
        let cases: [(String, String)] = [
            ("https://www.google.com/search?q=pizza+rome", "pizza rome"),
            ("https://www.google.co.uk/search?q=pizza", "pizza"),
            ("https://duckduckgo.com/?q=pizza", "pizza"),
            ("https://www.bing.com/search?q=pizza", "pizza"),
            ("https://kagi.com/search?q=pizza", "pizza"),
            ("https://search.brave.com/search?q=pizza", "pizza"),
            ("https://www.ecosia.org/search?q=pizza", "pizza"),
            ("https://www.startpage.com/sp/search?query=pizza", "pizza"),
            ("https://www.qwant.com/?q=pizza", "pizza"),
            ("https://yandex.com/search/?text=pizza", "pizza"),
            ("https://ya.ru/search/?text=pizza", "pizza"),
            ("https://www.perplexity.ai/search?q=pizza", "pizza"),
        ]
        for (address, query) in cases {
            #expect(SearchFolders.query(of: result(address)) == query, "\(address)")
        }
    }

    @Test func aQueryFromThePageTitleWhereTheAddressHasNone() {
        #expect(SearchFolders.query(of: result("https://www.startpage.com/sp/search"), title: "pizza rome - Startpage Search Results") == "pizza rome")
        #expect(SearchFolders.query(of: result("https://www.perplexity.ai/search/pizza-rome-AbC123"), title: "pizza rome - Perplexity") == "pizza rome")
    }

    @Test func aCustomEngineIsReadFromItsTemplate() {
        #expect(SearchFolders.query(of: result("https://find.example.org/lookup?term=pizza"),
                                           customTemplate: "https://find.example.org/lookup?term=%s") == "pizza")
        #expect(SearchFolders.query(of: result("https://other.example.org/lookup?term=pizza"),
                                         customTemplate: "https://find.example.org/lookup?term=%s") == nil)
    }

    @Test func aPageThatIsNotAResultsPageHasNoQuery() {
        #expect(SearchFolders.query(of: result("https://www.google.com/maps?q=rome")) == nil)
        #expect(SearchFolders.query(of: result("https://example.com/search?q=pizza")) == nil)
        #expect(SearchFolders.query(of: result("https://www.google.com/search")) == nil)
    }

    @Test func titlesLoseTheQueryWords() {
        #expect(SearchFolders.strip("Best Pizza in Rome - Tripadvisor", words: ["pizza", "rome"]) == "Best - Tripadvisor")
        #expect(SearchFolders.strip("Pizza | Rome", words: ["pizza", "rome"]) == "Pizza | Rome", "Nothing left: the title stands")
        #expect(SearchFolders.strip("Where to eat: Rome's pizza guide", words: ["pizza"]) == "Where to eat: Rome's guide")
    }

    @Test func followUpsAreRelated() {
        #expect(SearchFolders.related("pizza rome", "best pizza in rome"))
        #expect(SearchFolders.related("pizza rome", "pizza"))
        #expect(!SearchFolders.related("pizza rome", "weather oslo"))
        #expect(!SearchFolders.related("the", "of the"))
    }

    @Test func aCommandClickedResultStartsAFolderAndFollowUpsJoinIt() throws {
        let browser = browser()
        let search = try #require(browser.tabs.first)
        search.restore(url: result("https://www.google.com/search?q=pizza+rome"), title: "pizza rome - Google Search")

        let first = browser.open(result("https://one.example/"), foreground: false, from: search, mayWait: true, link: true)
        browser.fileSearchResult(first, from: search)

        let folder = try #require(browser.tabGroups.first)
        #expect(folder.name == "Pizza Rome")
        #expect(folder.query == "pizza rome")
        #expect(!folder.ai)
        #expect(first.groupID == folder.id)
        #expect(search.groupID == folder.id, "The results page goes with its result")
        #expect(browser.tabs(in: folder.id).first?.id == search.id)
        #expect(search.trimWords == nil)
        #expect(first.trimWords == ["pizza", "rome"])

        search.restore(url: result("https://www.google.com/search?q=best+pizza+rome"), title: "best pizza rome")
        let second = browser.open(result("https://two.example/"), foreground: false, from: search, mayWait: true, link: true)
        browser.fileSearchResult(second, from: search)

        #expect(browser.tabGroups.count == 1)
        #expect(second.groupID == folder.id)
        #expect(second.trimWords == ["best", "pizza", "rome"])

        search.restore(url: result("https://www.google.com/search?q=weather+oslo"), title: "weather oslo")
        let third = browser.open(result("https://three.example/"), foreground: false, from: search, mayWait: true, link: true)
        browser.fileSearchResult(third, from: search)

        #expect(browser.tabGroups.count == 2)
        #expect(third.groupID != folder.id)
        #expect(search.groupID == third.groupID, "A new search takes its page to the new folder")
        #expect(browser.tabGroups.first { $0.id == third.groupID }?.name == "Weather Oslo")
        #expect(Set(browser.tabs(in: folder.id).map { $0.id }) == Set([first.id, second.id]))
    }

    @Test func theShotsSearchGetsAShortNameAndKeepsItsPage() throws {
        let browser = browser()
        let search = try #require(browser.tabs.first)
        search.restore(url: result("https://www.google.com/search?q=Runner+%D1%81%D0%BC%D0%BE%D1%82%D1%80%D0%B5%D1%82%D1%8C+%D0%BE%D0%BD%D0%BB%D0%B0%D0%B9%D0%BD+%D0%BD%D0%B0+%D0%B0%D0%BD%D0%B3%D0%BB%D0%B8%D0%B9%D1%81%D0%BA%D0%BE%D0%BC"),
                       title: "Runner смотреть онлайн на английском - Поиск в Google")

        let opened = browser.open(result("https://kinogo.example/1234-begushchij-v-labirinte.html"), foreground: false, from: search, mayWait: true, link: true)
        browser.fileSearchResult(opened, from: search)

        let folder = try #require(browser.tabGroups.first)
        #expect(folder.name == "Runner")
        #expect(folder.query == "Runner смотреть онлайн на английском")
        #expect(search.groupID == folder.id)
        #expect(opened.groupID == folder.id)
    }

    @Test func aPinnedOrPairedSearchPageStaysPut() throws {
        let browser = browser()
        let search = try #require(browser.tabs.first)
        search.restore(url: result("https://www.google.com/search?q=pizza"), title: "pizza - Google Search")
        let partner = browser.open(result("https://map.example/"), foreground: false, from: search, mayWait: true, link: false)
        browser.pair(partner, with: search, onLeft: false)

        let opened = browser.open(result("https://one.example/"), foreground: false, from: search, mayWait: true, link: true)
        browser.fileSearchResult(opened, from: search)

        #expect(opened.groupID != nil)
        #expect(search.groupID == nil)
        #expect(partner.groupID == nil)
    }

    @Test func aLinkFromATabInAQueryFolderKeepsTheFolder() throws {
        let browser = browser()
        let search = try #require(browser.tabs.first)
        search.restore(url: result("https://www.google.com/search?q=pizza"), title: "pizza")
        let first = browser.open(result("https://one.example/"), foreground: false, from: search, mayWait: true, link: true)
        browser.fileSearchResult(first, from: search)

        let next = browser.open(result("https://two.example/"), foreground: false, from: first, mayWait: true, link: true)
        browser.fileSearchResult(next, from: first)

        #expect(next.groupID == first.groupID)
        #expect(next.trimWords == ["pizza"])
    }

    @Test func aResultFromAnOrdinaryPageMakesNoFolder() throws {
        let browser = browser()
        let page = try #require(browser.tabs.first)
        page.restore(url: result("https://example.com/"), title: "Example")

        let opened = browser.open(result("https://one.example/"), foreground: false, from: page, mayWait: true, link: true)
        browser.fileSearchResult(opened, from: page)

        #expect(browser.tabGroups.isEmpty)
        #expect(opened.trimWords == nil)
    }

    @Test func ungroupUndoesIt() throws {
        let browser = browser()
        let search = try #require(browser.tabs.first)
        search.restore(url: result("https://www.google.com/search?q=pizza"), title: "pizza")
        let first = browser.open(result("https://one.example/"), foreground: false, from: search, mayWait: true, link: true)
        browser.fileSearchResult(first, from: search)
        first.restore(url: result("https://one.example/"), title: "Pizza Places")
        #expect(first.label == "Places")

        browser.removeTabGroup(try #require(first.groupID))

        #expect(browser.tabGroups.isEmpty)
        #expect(first.groupID == nil)
        #expect(first.label == "Pizza Places")
    }

    @Test func aFolderFromTypedWordsTakesTheLooseTabsThatMatch() throws {
        let browser = browser()
        let tabs = try ["Pizza Rome", "Pizza Oslo", "Weather"].map { title -> Tab in
            let tab = browser.open(result("https://example.com/\(title.count)"), foreground: false)
            tab.restore(url: result("https://example.com/\(title.count)"), title: title)
            return try #require(tab as Tab?)
        }

        let id = try #require(browser.folderFromSearch("pizza"))

        #expect(Set(browser.tabs(in: id).map { $0.id }) == Set(tabs.prefix(2).map { $0.id }))
        #expect(tabs[0].label == "Rome")
        #expect(browser.folderFromSearch("nothing here") == nil)
    }

    @Test func trimWordsAreSaved() throws {
        let entry = Session.Entry(url: "https://one.example/", title: "Pizza", trim: ["pizza"])

        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(Session.Entry.self, from: data)

        #expect(back.trim == ["pizza"])
    }
}

import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class HoverCardTests {
    private var browser: Browser!
    private var cards: HoverCards { browser.hoverCards }
    private let frame = CGRect(x: 10, y: 100, width: 220, height: 34)

    init() async throws {
        keepSetting(Shared.prefs, \.hoverCards, "tabs.cards")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.hoverCards = true
        HoverCards.dwell = 10
    }

    private func tearDown() async {
        cards.dismiss()
        HoverCards.dwell = 0.6
        browser.closeAll()
        browser = nil
    }

    private func tab(_ title: String) -> Tab {
        browser.newTab()
        let tab = browser.active!
        tab.restore(url: URL(string: "https://example.com/\(title)")!, title: title)
        return tab
    }

    private func folder(_ tabs: [Tab]) -> UUID {
        browser.newFolder(with: tabs, named: "Work", editing: false)!
    }

    @Test func pageKeepsItsKeysUntilThePointerIsOnTheList() {
        let cards = browser.hoverCards
        let page = WKWebView()

        #expect(!cards.takesKeys(from: page))
        #expect(cards.takesKeys(from: nil))
    }

    @Test func nothingShowsBeforeTheDwell() {
        let page = tab("one")

        cards.enter(.tab(page.id), frame: frame)

        #expect(cards.kind == nil)
    }

    @Test func theCardShowsForAPageAndGoesWithThePointer() {
        let page = tab("one")
        cards.enter(.tab(page.id), frame: frame)

        cards.show(.tab(page.id))
        let shown = cards.kind
        cards.leave(.tab(page.id))

        #expect(shown == .tab(page.id))
        #expect(cards.kind == nil)
    }

    @Test func anEmptyTabHasNoCard() {
        browser.newTab()
        let blank = browser.active!
        cards.enter(.tab(blank.id), frame: frame)

        cards.show(.tab(blank.id))

        #expect(cards.kind == nil)
    }

    @Test func theSettingKeepsCardsAway() {
        let page = tab("one")
        browser.prefs.hoverCards = false
        cards.enter(.tab(page.id), frame: frame)

        cards.show(.tab(page.id))

        #expect(cards.kind == nil)
    }

    @Test func aRowThatMovesPutsItsCardAwayUntilThePointerComesBack() {
        let page = tab("one")
        cards.enter(.tab(page.id), frame: frame)
        cards.show(.tab(page.id))

        cards.enter(.tab(page.id), frame: frame.offsetBy(dx: 0, dy: 40))
        cards.show(.tab(page.id))
        let moved = cards.kind
        cards.leave(.tab(page.id))
        cards.enter(.tab(page.id), frame: frame)
        cards.show(.tab(page.id))

        #expect(moved == nil)
        #expect(cards.kind == .tab(page.id))
    }

    @Test func typingNarrowsAShutFolder() {
        let id = folder([tab("alpha"), tab("beta")])
        cards.enter(.folder(id), frame: frame)
        cards.show(.folder(id))

        cards.press(.text("be"))
        let narrowed = cards.entries.count
        cards.press(.delete)
        cards.press(.delete)

        #expect(narrowed == 1)
        #expect(cards.entries.count == 2)
    }

    @Test func returnOpensTheChosenTabAndPutsTheListAway() {
        let one = tab("alpha"), two = tab("beta")
        let id = folder([one, two])
        browser.select(tab("elsewhere"))
        cards.enter(.folder(id), frame: frame)
        cards.show(.folder(id))
        let wanted = cards.entries.count > 1 ? cards.entries[1].id : one.id

        cards.press(.down)
        cards.press(.enter)

        #expect(browser.activeID == wanted)
        #expect(cards.kind == nil)
    }

    @Test func arrowsGoInAndOutOfNestedFolders() throws {
        let outer = folder([tab("alpha")])
        let inner = try #require(browser.newFolder(inside: outer, named: "Inner", editing: false))
        browser.move(tab("beta"), toGroup: inner)
        cards.enter(.folder(outer), frame: frame)
        cards.show(.folder(outer))

        cards.press(.right)
        let inside = cards.title
        cards.press(.left)

        #expect(inside == "Inner")
        #expect(cards.title == "Work")
    }

    @Test func escapePutsTheListAwayForThisHover() {
        let id = folder([tab("alpha")])
        cards.enter(.folder(id), frame: frame)
        cards.show(.folder(id))

        cards.press(.escape)
        cards.show(.folder(id))

        #expect(cards.kind == nil)
    }

    @Test func aTabsSleepIsNeverSaid() {
        let page = tab("one")

        let doing = HoverCards.doing(page)

        #expect(page.asleep)
        #expect(doing == nil)
    }

    @Test func theCutLeftHoverCardsWithoutARow() {
        let item = SettingsIndex.item("tabs.cards")

        #expect(item == nil)
    }

}

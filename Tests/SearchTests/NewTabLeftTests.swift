import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct NewTabLeftTests {
    private func world(_ body: (Browser, Tab, Tab) async throws -> Void) async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesTabGroups, prefs.usesSpaces, prefs.splitView, prefs.floatingNewTab)
        (prefs.usesTabGroups, prefs.usesSpaces, prefs.splitView, prefs.floatingNewTab) = (true, true, true, false)
        defer {
            browser.closeAll()
            (prefs.usesTabGroups, prefs.usesSpaces, prefs.splitView, prefs.floatingNewTab) = previous
        }
        let first = browser.open(URL(string: "about:blank#first")!, foreground: true)
        let second = browser.open(URL(string: "about:blank#second")!, foreground: true)
        await drain()
        for blank in browser.tabs where blank.isBlank { browser.close(blank) }
        browser.select(first)
        await drain()
        try await body(browser, first, second)
    }

    private func drain() async {
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
    }

    private func newTab(_ browser: Browser) throws -> Tab {
        browser.newTab()
        let blank = try #require(browser.active)
        #expect(blank.isBlank)
        return blank
    }

    @Test func anUntouchedNewTabClosesWhenAnotherTabIsChosen() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)

            browser.select(second)
            await drain()

            #expect(!browser.tabs.contains { $0.id == blank.id })
            #expect(browser.activeID == second.id)
        }
    }

    @Test func itClosesWhateverTookItsPlace() async throws {
        try await world { browser, _, _ in
            let blank = try newTab(browser)

            let opened = browser.open(URL(string: "about:blank#link")!, foreground: true)
            await drain()

            #expect(!browser.tabs.contains { $0.id == blank.id })
            #expect(browser.activeID == opened.id)
        }
    }

    @Test func closingTheTabBesideItIsNotLeavingIt() async throws {
        try await world { browser, first, _ in
            let blank = try newTab(browser)

            browser.close(first)
            await drain()

            #expect(browser.activeID == blank.id)
            #expect(browser.tabs.contains { $0.id == blank.id })
        }
    }

    @Test func theCloseIsSilent() async throws {
        try await world { browser, first, second in
            browser.close(first)
            let ghosts = browser.ghosts.count
            let closed = browser.recentlyClosed.map(\.url)
            let blank = try newTab(browser)

            browser.select(second)
            await drain()

            #expect(!browser.tabs.contains { $0.id == blank.id })
            #expect(browser.ghosts.count == ghosts)
            #expect(browser.recentlyClosed.map(\.url) == closed)
            #expect(browser.activeID == second.id)
            #expect(browser.tabBefore(second)?.id != blank.id)
        }
    }

    @Test func newTabAskedAgainMakesAFreshOne() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            browser.select(second)
            await drain()

            let again = try newTab(browser)

            #expect(again.id != blank.id)
            #expect(browser.tabs.filter(\.isBlank).count == 1)
        }
    }

    @Test func aNewTabWithWordsTypedStays() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            browser.typed = "half a thought"

            browser.select(second)
            await drain()

            #expect(browser.tabs.contains { $0.id == blank.id })
            #expect(blank.draft == "half a thought")
            browser.select(blank)
            #expect(browser.typed == "half a thought")
        }
    }

    @Test func wordsTypedStayWhenALinkTakesItsPlace() async throws {
        try await world { browser, _, _ in
            let blank = try newTab(browser)
            browser.typed = "kept"

            _ = browser.open(URL(string: "about:blank#elsewhere")!, foreground: true)
            await drain()

            #expect(browser.tabs.contains { $0.id == blank.id })
            #expect(blank.draft == "kept")
        }
    }

    @Test func wordsForFindingATabAreNotADraft() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            browser.summon()
            browser.typed = "sec"

            browser.select(second)
            await drain()

            #expect(!browser.tabs.contains { $0.id == blank.id })
        }
    }

    @Test func aChosenSiteKeepsIt() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            browser.siteChip = SearchSite(name: "Fixture", host: "example.test", template: "https://example.test/?q=%s")

            browser.select(second)
            await drain()
            browser.siteChip = nil

            #expect(browser.tabs.contains { $0.id == blank.id })
        }
    }

    @Test func aNewTabInAFolderStays() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            browser.addTabGroup(containing: blank)
            browser.editingGroupID = nil

            browser.select(second)
            await drain()

            #expect(browser.tabs.contains { $0.id == blank.id })
        }
    }

    @Test func anAgentsOrABenchBlankStays() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            blank.agent = true

            browser.select(second)
            await drain()

            #expect(browser.tabs.contains { $0.id == blank.id })
            blank.agent = false
            browser.close(blank)
            let bench = try newTab(browser)
            bench.bench = true

            browser.select(second)
            await drain()

            #expect(browser.tabs.contains { $0.id == bench.id })
            bench.bench = false
        }
    }

    @Test func aPinnedPageIsNeverClosedForBeingLeft() async throws {
        try await world { browser, first, second in
            browser.pin(first)
            browser.select(first)

            browser.select(second)
            await drain()

            #expect(browser.tabs.contains { $0.id == first.id })
        }
    }

    @Test func focusMovingToTheOtherPaneIsNotLeaving() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            browser.pair(blank, with: second, onLeft: false)

            browser.focusPane(second)
            await drain()

            #expect(browser.tabs.contains { $0.id == blank.id })
            #expect(browser.visibleTabIDs.contains(blank.id))
        }
    }

    @Test func theEmptyHalfOfAPairStaysWhenThePairIsLeft() async throws {
        try await world { browser, first, second in
            let blank = try newTab(browser)
            browser.pair(blank, with: second, onLeft: false)

            browser.select(first)
            await drain()

            #expect(browser.tabs.contains { $0.id == blank.id })
            #expect(browser.split(for: blank) != nil)
        }
    }

    @Test func anotherSpaceIsNotLeaving() async throws {
        try await world { browser, _, second in
            let blank = try newTab(browser)
            let home = browser.spaceID

            browser.addSpace(named: "Elsewhere")
            await drain()
            browser.switchSpace(to: home)
            await drain()

            #expect(browser.activeID == blank.id)
            #expect(browser.tabs.contains { $0.id == blank.id })
            browser.select(second)
            await drain()
            #expect(!browser.tabs.contains { $0.id == blank.id })
            browser.deleteSpace(try #require(browser.spaces.first { $0.name == "Elsewhere" }).id)
        }
    }

    @Test func choosingATabInAStackedSectionClosesTheNewTabItReplaced() async throws {
        try await world { browser, first, _ in
            let home = browser.spaceID
            browser.addSpace(named: "Stacked")
            let other = browser.spaceID
            let page = browser.open(URL(string: "about:blank#stacked")!, foreground: true)
            await drain()
            let blank = try newTab(browser)
            browser.switchSpace(to: home)
            await drain()
            #expect(browser.activeID == first.id)

            browser.stackedSelect(page, in: other)
            await drain()

            #expect(browser.spaceID == other)
            #expect(browser.activeID == page.id)
            #expect(!browser.tabs.contains { $0.id == blank.id })
            browser.deleteSpace(other)
        }
    }

    @Test func theOnlyTabOfItsSpaceStays() async throws {
        try await world { browser, first, second in
            browser.close(first)
            browser.close(second)
            await drain()
            let blank = try #require(browser.tabs.first)
            #expect(browser.tabs.count == 1)

            browser.select(blank)
            browser.closeLeftNewTabs()
            await drain()

            #expect(browser.tabs.map(\.id) == [blank.id])
            #expect(browser.activeID == blank.id)
        }
    }

    @Test func leavingForAPinKeepsThePinInFront() async throws {
        try await world { browser, first, second in
            browser.pin(first)
            browser.close(second)
            await drain()
            let blank = try newTab(browser)

            browser.select(first)
            await drain()

            #expect(!browser.tabs.contains { $0.id == blank.id })
            #expect(browser.activeID == first.id)
            #expect(!browser.tabs.isEmpty)
        }
    }
}

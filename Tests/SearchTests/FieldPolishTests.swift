import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FieldPolishTests {
    private var browser: Browser!
    private var saved = false

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        saved = browser.prefs.floatingNewTab
        browser.prefs.newTabStyle = .floating
    }

    private func tearDown() async {
        browser.prefs.floatingNewTab = saved
        browser.closeAll()
        browser = nil
    }

    private func floatingOverTwoPages() {
        _ = browser.open(URL(string: "about:blank#first")!, foreground: true)
        _ = browser.open(URL(string: "about:blank#second")!, foreground: true)
        browser.launch()
        browser.fieldRose()
    }

    @Test func theFloatingFieldOpensWithNoRowLit() {
        _ = browser.open(URL(string: "about:blank#first")!, foreground: true)
        _ = browser.open(URL(string: "about:blank#second")!, foreground: true)

        browser.launch()
        browser.fieldRose()

        #expect(browser.launching)
        #expect(browser.fieldSections.contains { $0.title == "Recent Tabs" })
        #expect(browser.picked == nil)
        #expect(browser.fieldRow == nil)
        #expect(browser.pickedOffer == nil)
    }

    @Test func downLightsTheFirstRow() {
        floatingOverTwoPages()

        browser.walk(1)

        #expect(browser.picked == 0)
    }

    @Test func returnWithNothingTypedAndNothingLitDoesNothing() {
        floatingOverTwoPages()
        let tabs = browser.tabs.map(\.id)
        let active = browser.activeID
        let refusals = browser.refusals

        browser.submit()

        #expect(browser.tabs.map(\.id) == tabs)
        #expect(browser.activeID == active)
        #expect(browser.refusals == refusals)
        #expect(browser.editing)
        #expect(browser.launching)
    }

    @Test func theReturnButtonIsIdleUntilARowIsLitOrSomethingIsTyped() {
        floatingOverTwoPages()
        #expect(browser.returnIsIdle)

        browser.walk(1)

        #expect(!browser.returnIsIdle)
        browser.picked = nil
        browser.typed = "example"
        #expect(!browser.returnIsIdle)
    }

    @Test func oneEscapeClosesTheFloatingFieldEvenWithARowLit() {
        floatingOverTwoPages()
        browser.walk(1)

        let letGo = browser.letGoOfRow()
        browser.dismiss()

        #expect(!letGo)
        #expect(!browser.editing)
        #expect(!browser.launching)
    }

    @Test func oneEscapeClosesAFloatingBlankTabEvenWithARowLit() {
        _ = browser.open(URL(string: "about:blank#first")!, foreground: true)
        browser.newTab()
        browser.fieldRose()
        browser.walk(1)

        let letGo = browser.letGoOfRow()

        #expect(!letGo)
        #expect(browser.picked != nil)
    }

    @Test func escapeOverAnEditedAddressStillLetsGoOfTheRowFirst() throws {
        _ = browser.open(URL(string: "about:blank#first")!, foreground: true)
        browser.edit()
        browser.typed = "example"
        if browser.offers.isEmpty { try Test.cancel() }
        browser.walk(1)

        let letGo = browser.letGoOfRow()

        #expect(letGo)
        #expect(browser.picked == nil)
        #expect(browser.editing)
    }

    @Test func closingKeepsTheRowsTheLeavingPanelShows() {
        floatingOverTwoPages()
        browser.typed = "example"
        let rows = browser.offers.map(\.key)

        browser.dismiss()

        #expect(browser.offers.map(\.key) == rows)
        #expect(browser.typed == "")
        #expect(browser.ending == nil)
    }

    @Test func openingAgainStartsFromTheRestingRows() {
        floatingOverTwoPages()
        browser.typed = "example"
        browser.dismiss()

        browser.launch()

        #expect(browser.fieldSections.contains { $0.title == "Recent Tabs" })
        #expect(browser.picked == nil)
    }
}

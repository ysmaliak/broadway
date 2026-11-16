import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class IdleTabBatchTests {
    private var browser: Browser!
    private var kept: (TabLife, Bool)!

    init() async throws {
        keepSettings("tabs.close.after")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.tabGroups = []
        kept = (browser.prefs.tabLife, browser.prefs.splitView)
        browser.prefs.tabLife = .halfDay
        browser.prefs.splitView = true
    }

    private func tearDown() async {
        browser.closeAll()
        browser.prefs.tabLife = kept.0
        browser.prefs.splitView = kept.1
        browser = nil
    }

    private func row(_ count: Int) -> [Tab] {
        let tabs = (0..<count).map { index in
            let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.restore(url: URL(string: "about:blank#\(index)")!, title: "Tab \(index)")
            tab.touch(at: .distantPast)
            return tab
        }
        browser.showRow(tabs, active: tabs.last?.id)
        return tabs
    }

    private func forms(_ tab: Tab, unsaved: Bool) async {
        await withCheckedContinuation { continuation in
            tab.web.evaluateInSearch("window.__officeForms = {unsaved: () => \(unsaved)}") { _ in continuation.resume() }
        }
    }

    private func waitForClosure() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    @Test func oneReopenRestoresTheWholePassInOrderAndKeepsTheActivePage() {
        let tabs = row(6)
        tabs[1].touch()
        tabs[3].muted = true

        browser.closeLeftAlone()

        #expect(browser.tabs.map(\.id) == [tabs[1].id, tabs[5].id])
        #expect(browser.recentlyClosed.count == 1)
        #expect(browser.reopenTitle == "Reopen 4 Closed Tabs")

        browser.reopen()

        #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
        #expect(browser.activeID == tabs[5].id)
        #expect(browser.tabs[3].muted == true)
        #expect(browser.ghosts.isEmpty)
    }

    @Test func aReopenedSplitKeepsItsOrderAxisSizesAndFocusedPage() throws {
        let tabs = row(5)
        let pair = TabSplit(tabs: [tabs[1].id, tabs[2].id], axis: .vertical,
                            sizes: [0.3, 0.7], focused: tabs[2].id)
        browser.showRow(tabs, active: tabs[4].id, splits: [pair])

        browser.closeLeftAlone()
        browser.reopen()

        #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
        let restored = try #require(browser.split(for: browser.tabs[1]))
        #expect(restored.tabs == [browser.tabs[1].id, browser.tabs[2].id])
        #expect(restored.axis == pair.axis)
        #expect(restored.sizes == pair.sizes)
        #expect(restored.focused == browser.tabs[2].id)
        #expect(browser.activeID == tabs[4].id)
        #expect(browser.tabs[1].built == nil)
        #expect(browser.tabs[2].built == nil)
    }

    @Test func largePassIsOneHistoryStepAndManualCloseRemainsSeparate() {
        let tabs = row(18)
        tabs[1].touch()

        browser.closeLeftAlone()
        browser.close(tabs[1])

        #expect(browser.ghosts.count == 17)
        #expect(browser.recentlyClosed.count == 2)

        browser.reopen()

        #expect(browser.tabs.compactMap(\.address) == [tabs[1], tabs[17]].compactMap { $0.address })
        #expect(browser.ghosts.count == 16)

        browser.reopen()

        #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
    }

    @Test func batchClosingOneSplitHalfCanRestoreItBesideTheSurvivingHalf() throws {
        let tabs = row(4)
        let pair = TabSplit(tabs: [tabs[0].id, tabs[1].id], sizes: [0.35, 0.65], focused: tabs[1].id)
        browser.showRow(tabs, active: tabs[3].id, splits: [pair])

        browser.closingTogether(.tabs) { _ in browser.close(tabs[0]) }
        browser.reopen()

        let restored = try #require(browser.split(for: tabs[1]))
        #expect(browser.tabs.compactMap(\.address) == tabs.compactMap { $0.address })
        #expect(restored.sizes == pair.sizes)
        #expect(restored.focused == tabs[1].id)
    }

    @Test func aProtectedOrFreshHalfKeepsItsWholeSplit() {
        let tabs = row(5)
        let pair = TabSplit(tabs: [tabs[0].id, tabs[1].id])
        browser.showRow(tabs, active: tabs[4].id, splits: [pair])
        tabs[1].touch()
        tabs[2].name = "Keep"
        tabs[3].noisy = true

        browser.closeLeftAlone()

        #expect(browser.tabs.map(\.id) == tabs.map { $0.id })
        #expect(browser.ghosts.isEmpty)
    }

    @Test func unsavedSplitStaysWhileOtherIdleTabsCloseAsOneBatch() async {
        let tabs = row(6)
        browser.showRow(tabs, active: tabs[5].id, splits: [TabSplit(tabs: [tabs[0].id, tabs[1].id])])
        await forms(tabs[1], unsaved: true)

        browser.closeLeftAlone()
        await waitForClosure()

        #expect(browser.tabs.map(\.id) == [tabs[0], tabs[1], tabs[5]].map { $0.id })
        #expect(browser.recentlyClosed.count == 1)
        #expect(browser.ghosts.count == 3)
        #expect(browser.split(for: tabs[0]) != nil)
    }

    @Test func returningToATabDuringTheFormCheckKeepsIt() async {
        let tabs = row(4)
        await forms(tabs[0], unsaved: false)

        browser.closeLeftAlone()
        browser.select(tabs[0])
        await waitForClosure()

        #expect(browser.tabs.contains { $0 === tabs[0] })
        #expect(!browser.tabs.contains { $0 === tabs[1] })
        #expect(!browser.tabs.contains { $0 === tabs[2] })
        #expect(browser.activeID == tabs[0].id)
    }
}

import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct NewTabsAtBottomTests {
    init() {
        keepSettings(Preferences.newAtBottomKey, "tabs.newPlace", "newtab.floating")
    }

    @Test func onByDefault() {
        let store = Store.settings
        let saved = (store.object(forKey: Preferences.newAtBottomKey), store.object(forKey: "tabs.newPlace"))
        defer {
            store.set(saved.0, forKey: Preferences.newAtBottomKey)
            store.set(saved.1, forKey: "tabs.newPlace")
        }
        store.removeObject(forKey: Preferences.newAtBottomKey)
        store.removeObject(forKey: "tabs.newPlace")

        let prefs = Preferences()

        #expect(prefs.newTabsAtBottom)
    }

    @Test func theCutFixesNewTabsAtTheBottom() {
        let store = Store.settings
        let saved = (store.object(forKey: Preferences.newAtBottomKey), store.object(forKey: "tabs.newPlace"))
        defer {
            store.set(saved.0, forKey: Preferences.newAtBottomKey)
            store.set(saved.1, forKey: "tabs.newPlace")
        }
        store.set(false, forKey: Preferences.newAtBottomKey)
        store.set(NewTabPlace.top.rawValue, forKey: "tabs.newPlace")

        let prefs = Preferences()

        #expect(prefs.newTabsAtBottom)
    }

    @Test func aNewTabLandsAtTheBottomJustAboveTheRow() throws {
        try withBrowser(bottom: true) { browser, tabs in
            browser.select(tabs[0])

            browser.newTab()

            let fresh = try #require(browser.active)
            #expect(fresh.isBlank)
            #expect(browser.tabs.last?.id == fresh.id)
            #expect(Array(browser.tabs.dropLast().map { $0.id }) == tabs.map { $0.id })
        }
    }

    @Test func aNewTabLandsAtTheTopUnderThePins() throws {
        try withBrowser(bottom: false) { browser, tabs in
            browser.pin(tabs[0])
            browser.select(tabs[3])

            browser.newTab()

            let fresh = try #require(browser.active)
            #expect(fresh.isBlank)
            #expect(browser.pinnedCount == 1)
            #expect(browser.tabs.first?.id == tabs[0].id)
            #expect(browser.tabs[1].id == fresh.id)
            browser.unpin(tabs[0])
        }
    }

    @Test func aBlankMovesToWhereNewTabsGo() throws {
        try withBrowser(bottom: true) { browser, tabs in
            browser.newTab()
            let blank = try #require(browser.active)
            browser.prefs.newTabsAtBottom = false
            browser.select(tabs[2])

            browser.newTab()

            #expect(browser.activeID == blank.id)
            #expect(browser.tabs.first?.id == blank.id)
        }
    }

    @Test func theSwitchAndThePlaceAgree() throws {
        try withBrowser(bottom: true) { browser, _ in
            let prefs = browser.prefs

            prefs.newTabPlace = .top

            #expect(!prefs.newTabsAtBottom)

            prefs.newTabsAtBottom = true

            #expect(prefs.newTabPlace == .end)
            #expect((Store.settings.object(forKey: Preferences.newAtBottomKey) as? Bool) == true)

            prefs.newTabPlace = .next
            prefs.newTabsAtBottom = false

            #expect(prefs.newTabPlace == .next, "a link still opens beside its tab")
            #expect(browser.placeForFront() == browser.pinnedCount)
        }
    }

    @Test func aLinkFromAnotherAppFollowsTheSwitchUnlessBesideIsChosen() throws {
        try withBrowser(bottom: true) { browser, tabs in
            browser.select(tabs[1])
            browser.prefs.newTabPlace = .end

            #expect(browser.placeForNew() == browser.tabs.count)

            browser.prefs.newTabsAtBottom = false

            #expect(browser.placeForNew() == browser.pinnedCount)

            browser.prefs.newTabPlace = .next

            #expect(browser.placeForNew() == 2)
        }
    }

    @Test func aPageOpenedAsANewTabGoesWhereNewTabsGoEvenWhenLinksOpenBeside() throws {
        try withBrowser(bottom: true) { browser, tabs in
            browser.prefs.newTabPlace = .next
            browser.select(tabs[0])

            let bottom = browser.open(URL(string: "about:blank#bottom")!, foreground: true, front: true)

            #expect(browser.tabs.last?.id == bottom.id)

            browser.prefs.newTabsAtBottom = false
            let top = browser.open(URL(string: "about:blank#top")!, foreground: true, front: true)

            #expect(browser.tabs.first?.id == top.id)
        }
    }

    @Test func aLinkFollowsTheSwitchUnlessBesideIsChosen() throws {
        try withBrowser(bottom: true) { browser, tabs in
            browser.prefs.newTabPlace = .end
            browser.select(tabs[1])

            let bottom = browser.open(URL(string: "about:blank#bottom")!, foreground: false, from: tabs[1], link: true)

            #expect(browser.tabs.last?.id == bottom.id)

            browser.prefs.newTabsAtBottom = false
            let top = browser.open(URL(string: "about:blank#top")!, foreground: false, from: tabs[1], link: true)

            #expect(browser.tabs.firstIndex { $0.id == top.id } == browser.pinnedCount)

            browser.prefs.newTabPlace = .next
            let beside = browser.open(URL(string: "about:blank#beside")!, foreground: false, from: tabs[1], link: true)

            let source = try #require(browser.tabs.firstIndex { $0.id == tabs[1].id })
            #expect(browser.tabs.firstIndex { $0.id == beside.id } == (source + 1))
        }
    }

    @Test func theSettingHasNoRowAfterTheCut() {
        let item = SettingsIndex.item("tabs.newAtBottom")

        #expect(item == nil)
        #expect(PersonSettings.table["tabs.newAtBottom"] == nil)
        #expect(!SettingsIndex.apply("tabs.newAtBottom", false, to: Preferences()))
    }

    private func withBrowser(bottom: Bool, _ body: (Browser, [Tab]) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let prefs = browser.prefs
        let saved = (prefs.usesTabGroups, prefs.splitView, prefs.newTabPlace, prefs.newTabsAtBottom, prefs.floatingNewTab)
        defer {
            browser.closeAll()
            prefs.usesTabGroups = saved.0
            prefs.splitView = saved.1
            prefs.newTabPlace = saved.2
            prefs.newTabsAtBottom = saved.3
            prefs.floatingNewTab = saved.4
        }
        prefs.usesTabGroups = false
        prefs.splitView = false
        prefs.floatingNewTab = false
        prefs.newTabPlace = .next
        prefs.newTabsAtBottom = bottom
        for number in 1...4 {
            if number > 1 { browser.newTab() }
            browser.active?.restore(url: URL(string: "about:blank#\(number)")!, title: "Tab \(number)")
        }
        try body(browser, browser.tabs)
    }
}

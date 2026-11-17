import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct MuteOthersTests {
    init() {
        keepSetting(Shared.prefs, \.splitView)
    }

    private func withBrowser(_ body: (Browser, [Tab]) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.parked = [:]
        for number in 1...4 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "https://mute-others-\(number).example/")!, title: "Tab \(number)")
        }
        defer { browser.closeAll() }
        try body(browser, browser.tabs)
    }

    @Test func everyOtherTabPlayingSoundIsMutedButTheOneInFront() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            for tab in tabs { tab.noisy = true }

            browser.muteOtherTabs()

            #expect(tabs.map(\.muted) == [false, true, true, true])
        }
    }

    @Test func aSilentTabIsLeftAlone() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            tabs[1].noisy = true

            browser.muteOtherTabs()

            #expect(tabs.map(\.muted) == [false, true, false, false])
        }
    }

    @Test func aTabAlreadyMutedStaysMutedAndNothingIsUnmuted() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            tabs[0].toggleMute()
            tabs[2].noisy = true
            tabs[2].toggleMute()

            browser.muteOtherTabs()

            #expect(tabs[0].muted)
            #expect(tabs[2].muted)
        }
    }

    @Test func theOtherHalfOfASplitViewOnScreenIsSpared() {
        withBrowser { browser, tabs in
            browser.prefs.splitView = true
            browser.putBackSplit(TabSplit(tabs: [tabs[0].id, tabs[1].id]))
            browser.select(tabs[0])
            for tab in tabs { tab.noisy = true }

            browser.muteOtherTabs()

            #expect(tabs.map(\.muted) == [false, false, true, true])
        }
    }

    @Test func fromATabsMenuThatTabIsSparedToo() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            for tab in tabs { tab.noisy = true }

            browser.muteOtherTabs(sparing: tabs[3])

            #expect(tabs.map(\.muted) == [false, true, true, false])
        }
    }

    @Test func theRowIsOfferedOnlyWhileAnotherTabPlaysSound() {
        withBrowser { browser, tabs in
            browser.select(tabs[0])
            tabs[0].noisy = true
            #expect(!browser.canMuteOtherTabs)
            #expect(browser.tabsToMute(sparing: tabs[2]).isEmpty)

            tabs[2].noisy = true

            #expect(browser.canMuteOtherTabs)
            #expect(browser.tabsToMute(sparing: tabs[2]).isEmpty)
        }
    }
}

import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SiteSpaceLockTests {
    private var browser: Browser!

    init() {
        keepSetting(Shared.prefs, \.keywords, "search.keywords")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.prefs.searchesSites = true
        browser.prefs.keywords = []
    }

    private func tearDown() {
        browser.prefs.searchesSites = true
        browser.prefs.keywords = []
        browser.closeAll()
        browser = nil
    }

    @Test func anAliasTypedWholeNamesItsSite() {
        let cases: [(String, String?)] = [
            ("gh", "GitHub"), ("yt", "YouTube"), ("YT", "YouTube"), ("wiki", "Wikipedia"),
            ("so", nil), ("music", nil), ("drive", nil), ("npm", nil), ("reddit", nil), ("stack overflow", nil),
        ]

        for (typed, name) in cases {
            #expect(SiteSearch.exact(typed)?.name == name, "\(typed)")
        }
    }

    @Test func aBeginningOrAPhraseIsNotAnExactSite() {
        let typed = ["red", "yout", "so what", "so ", " so", "s", "google m", ""]

        for text in typed {
            #expect(SiteSearch.exact(text) == nil, "\(text)")
        }
    }

    @Test func spaceAfterAWholeAliasLocksTheSite() {
        browser.edit()
        browser.typed = "gh"

        let took = browser.lockSiteOnSpace()

        #expect(took)
        #expect(browser.siteChip?.name == "GitHub")
        #expect(browser.typed == "")
    }

    @Test func spaceAfterAnOrdinaryWordOrASitesNameIsAPlainSpace() {
        for word in ["Reddit", "so", "music", "netflix"] {
            browser.edit()
            browser.typed = word

            let took = browser.lockSiteOnSpace()

            #expect(!took, "\(word)")
            #expect(browser.siteChip == nil)
        }
    }

    @Test func spaceInsideAPhraseIsTypedAsUsual() {
        browser.edit()
        browser.typed = "so what"

        let took = browser.lockSiteOnSpace()

        #expect(!took)
        #expect(browser.siteChip == nil)
        #expect(browser.typed == "so what")
    }

    @Test func spaceAfterTheStartOfANameIsTypedAsUsual() {
        browser.edit()
        browser.typed = "red"

        let took = browser.lockSiteOnSpace()

        #expect(!took)
        #expect(browser.siteChip == nil)
    }

    @Test func yourOwnShortcutKeepsItsWord() {
        browser.prefs.keywords = [Keyword(keyword: "yt", template: "https://example.com/find?q=%s")]
        browser.edit()
        browser.typed = "yt"

        let took = browser.lockSiteOnSpace()

        #expect(!took)
        #expect(browser.siteChip == nil)
        #expect(browser.typed == "yt")
    }

    @Test func spaceDoesNothingWhenSiteSearchIsOff() {
        browser.prefs.searchesSites = false
        browser.edit()
        browser.typed = "gh"

        let took = browser.lockSiteOnSpace()

        #expect(!took)
        #expect(browser.siteChip == nil)
    }

    @Test func spaceWithASiteAlreadyLockedIsTypedAsUsual() {
        browser.edit()
        browser.typed = "gh"
        _ = browser.lockSiteOnSpace()
        browser.typed = "yt"

        let took = browser.lockSiteOnSpace()

        #expect(!took)
        #expect(browser.siteChip?.name == "GitHub")
        #expect(browser.typed == "yt")
    }

    @Test func aPlaceNameIsNotLockedBySpace() {
        browser.edit()
        browser.typed = "history"

        let took = browser.lockSiteOnSpace()

        #expect(!took)
        #expect(browser.fieldPlace == nil)
    }
}

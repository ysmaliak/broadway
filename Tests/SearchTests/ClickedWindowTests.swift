import Foundation
import Testing
@testable import Search

struct ClickedWindowTests {
    private let blank = URL(string: "about:blank")!
    private let page = URL(string: "https://files.example.com/")!

    @Test func onlyTheBlankPageCountsAsBlank() {
        #expect(ClickedWindow.blank(nil))
        #expect(ClickedWindow.blank(blank))
        #expect(ClickedWindow.blank(URL(string: "about:blank#top")!))
        #expect(!ClickedWindow.blank(URL(string: "about:srcdoc")!))
        #expect(!ClickedWindow.blank(page))
    }

    @Test func aWindowWithNothingCommittedTakesItsOpenersClickAsBefore() {
        #expect(ClickedWindow.takesOpenersClick(committed: nil, shownPage: false, byClick: false))
        #expect(ClickedWindow.takesOpenersClick(committed: nil, shownPage: false, byClick: true))
    }

    @Test func aClickedWindowThatShowedOnlyTheBlankPageTakesItsOpenersClick() {
        #expect(ClickedWindow.takesOpenersClick(committed: blank, shownPage: false, byClick: true))
    }

    @Test func aBlankWindowNoClickOpenedHasNoClickToGive() {
        #expect(!ClickedWindow.takesOpenersClick(committed: blank, shownPage: false, byClick: false))
    }

    @Test func aClickedWindowThatShowedAPageHasItsOwnClicksOnly() {
        #expect(!ClickedWindow.takesOpenersClick(committed: page, shownPage: true, byClick: true))
        #expect(!ClickedWindow.takesOpenersClick(committed: blank, shownPage: true, byClick: true))
    }
}

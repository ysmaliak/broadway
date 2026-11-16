import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct WindowTitleTests {
    @Test func windowIsNamedForItsPage() {
        #expect(WindowTitle.name(page: "Example Domain", private: false) == "Example Domain")
        #expect(WindowTitle.name(page: "  Example Domain \n", private: false) == "Example Domain")
    }

    @Test func windowWithoutAPageTitleIsNamedForTheApp() {
        #expect(WindowTitle.name(page: "", private: false) == "Broadway")
        #expect(WindowTitle.name(page: "   ", private: false) == "Broadway")
    }

    @Test func privateTabNeverGivesItsPageAway() {
        #expect(WindowTitle.name(page: "Something personal", private: true) == "Private Window")
    }
}

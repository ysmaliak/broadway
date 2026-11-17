import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FillMarkTabTests {
    private func tab(_ url: String) -> Tab {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: false, configuration: configuration)
        tab.setAddressOptimistically(URL(string: url)!)
        return tab
    }

    @Test func theMarksGoWhenTheTabCommitsAPageOnAnotherSite() {
        let page = tab("https://id.example.test/login")
        page.keptFill = FillMark(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        page.appleFill = AppleFill(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        page.setAddressOptimistically(URL(string: "https://elsewhere.test/")!)
        page.didCommit()
        #expect(page.keptFill == nil)
        #expect(page.appleFill == nil)
    }

    @Test func theMarksStayOnAnotherPageOfTheSameSite() {
        let page = tab("https://id.example.test/login")
        page.keptFill = FillMark(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        page.setAddressOptimistically(URL(string: "https://id.example.test/home")!)
        page.didCommit()
        #expect(page.keptFill != nil)
    }

    @Test func theMarksStayWhileASentSignInIsWaiting() {
        let page = tab("https://id.example.test/login")
        page.keptFill = FillMark(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        page.sentSignIn(user: "pat", password: "sa-made-up-1")
        page.setAddressOptimistically(URL(string: "https://elsewhere.test/")!)
        page.didCommit()
        #expect(page.keptFill != nil)
    }
}

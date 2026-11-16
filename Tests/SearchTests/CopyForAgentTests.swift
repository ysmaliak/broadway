import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CopyForAgentTests {
    private let url = URL(string: "https://example.com/a?token=abc&x=1")

    private func read(_ text: String, cut: Bool = false) -> AIPage.Read {
        AIPage.Read(title: "T", url: url, text: text, links: [], cut: cut)
    }

    @Test func pageCarriesTitleAndAddress() {
        let page = read("Some words")

        let text = CopyForAgent.text(title: "A Page", url: url, selection: "", page: page, errors: [])

        #expect(text == "Page: A Page\nURL: https://example.com/a?token=[removed]&x=1\n\nSome words")
    }

    @Test func selectionWinsOverThePage() {
        let page = read("The whole page")

        let text = CopyForAgent.text(title: "A", url: nil, selection: "  just this  ", page: page, errors: [])

        #expect(text == "Page: A\nSelected text:\n\njust this")
    }

    @Test func nothingToCopy() {
        let page = read("   ")

        let text = CopyForAgent.text(title: "A", url: url, selection: "", page: page, errors: [])

        #expect(text == nil)
    }

    @Test func aLongPageSaysSo() {
        let page = read("words", cut: true)

        let text = CopyForAgent.text(title: "A", url: nil, selection: "", page: page, errors: [])

        #expect(text?.hasSuffix("[The middle of a long page was left out]") == true)
    }

    @Test func errorsComeAlongWithoutTokens() {
        var error = DevEntry(kind: .error)
        error.message = "failed with Bearer abc.def"
        var warning = DevEntry(kind: .warning)
        warning.message = "ignored"

        let text = CopyForAgent.text(title: "A", url: nil, selection: "", page: read("words"), errors: [error, warning])

        #expect(text?.hasSuffix("Errors on this page:\n- failed with Bearer [removed]") == true)
        #expect(!(text?.contains("ignored") == true))
    }
}

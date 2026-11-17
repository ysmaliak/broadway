import Foundation
import Testing
@testable import Search

struct HighlightLinkTests {
    private static let page = URL(string: "https://notes.example/garden")!

    @Test("the link names the selection", arguments: [
        ("https://notes.example/garden", "quiet harbour", "", "https://notes.example/garden#:~:text=quiet%20harbour"),
        ("https://notes.example/garden#:~:text=old", "quiet harbour", "", "https://notes.example/garden#:~:text=quiet%20harbour"),
        ("https://notes.example/garden#roses", "quiet harbour", "", "https://notes.example/garden#roses:~:text=quiet%20harbour"),
        ("https://notes.example/garden#roses:~:text=old", "quiet harbour", "", "https://notes.example/garden#roses:~:text=quiet%20harbour"),
        ("https://notes.example/garden", "  quiet\t  harbour  ", "", "https://notes.example/garden#:~:text=quiet%20harbour"),
        ("https://notes.example/garden", "salt, pepper & thyme-oil", "",
         "https://notes.example/garden#:~:text=salt%2C%20pepper%20%26%20thyme%2Doil"),
        ("https://notes.example/garden", "café ~ 1.5", "", "https://notes.example/garden#:~:text=caf%C3%A9%20~%201.5"),
    ])
    func names(page: String, selection: String, before: String, expected: String) throws {
        let link = HighlightLink.address(try #require(URL(string: page)), selection: selection, before: before)

        #expect(link?.absoluteString == expected)
    }

    @Test func aSelectionOfExactly300CharactersIsNamedWhole() throws {
        let selection = String(repeating: "a", count: 300)

        let link = try #require(HighlightLink.address(Self.page, selection: selection, before: ""))

        #expect(link.absoluteString == "https://notes.example/garden#:~:text=" + selection)
    }

    @Test func aLongerSelectionIsNamedByItsFirstAndLastFiveWords() throws {
        let words = (1...80).map { "word\($0)" }
        let selection = words.joined(separator: " ")
        #expect(selection.count > 300)

        let link = try #require(HighlightLink.address(Self.page, selection: selection, before: ""))

        #expect(link.absoluteString == "https://notes.example/garden#:~:text=word1%20word2%20word3%20word4%20word5,word76%20word77%20word78%20word79%20word80")
    }

    @Test func wordsThatCameEarlierInThePageAddTheThreeWordsBefore() throws {
        let link = try #require(HighlightLink.address(Self.page, selection: "quiet harbour",
                                                      before: "The quiet harbour sleeps. Boats rest. Again the"))

        #expect(link.absoluteString == "https://notes.example/garden#:~:text=rest.%20Again%20the-,quiet%20harbour")
    }

    @Test func anEarlierMatchIsFoundWhateverItsCase() throws {
        let link = try #require(HighlightLink.address(Self.page, selection: "Quiet Harbour", before: "the quiet harbour and then"))

        #expect(link.absoluteString == "https://notes.example/garden#:~:text=harbour%20and%20then-,Quiet%20Harbour")
    }

    @Test func aLongSelectionLooksForItsFirstWordsEarlier() throws {
        let words = (1...80).map { "word\($0)" }
        let link = try #require(HighlightLink.address(Self.page, selection: words.joined(separator: " "),
                                                      before: "word1 word2 word3 word4 word5 here and there"))

        #expect(link.absoluteString.hasPrefix("https://notes.example/garden#:~:text=here%20and%20there-,word1%20word2"))
    }

    @Test func wordsBeforeThatDoNotRepeatTheSelectionAddNothing() throws {
        let link = try #require(HighlightLink.address(Self.page, selection: "quiet harbour", before: "Boats rest here"))

        #expect(link.absoluteString == "https://notes.example/garden#:~:text=quiet%20harbour")
    }

    @Test func aSelectionAcrossParagraphsIsNamedByItsEnds() throws {
        let link = try #require(HighlightLink.address(Self.page, selection: "the quiet harbour sleeps\n\nBoats rest on the sand tonight", before: ""))

        #expect(link.absoluteString == "https://notes.example/garden#:~:text=the%20quiet%20harbour%20sleeps,rest%20on%20the%20sand%20tonight")
    }

    @Test func theWordsBeforeComeFromTheSelectionsOwnParagraph() throws {
        let link = try #require(HighlightLink.address(Self.page, selection: "quiet harbour",
                                                      before: "the quiet harbour sleeps\nAgain the"))
        let first = try #require(HighlightLink.address(Self.page, selection: "quiet harbour",
                                                       before: "the quiet harbour sleeps\n"))

        #expect(link.absoluteString == "https://notes.example/garden#:~:text=Again%20the-,quiet%20harbour")
        #expect(first.absoluteString == "https://notes.example/garden#:~:text=quiet%20harbour")
    }

    @Test func nothingSelectedGivesNoLink() {
        #expect(HighlightLink.address(Self.page, selection: " \n ", before: "") == nil)
    }

    @Test func onlyWebPagesAndLocalFilesGetALink() {
        #expect(HighlightLink.address(URL(string: "broadway://settings")!, selection: "words", before: "") == nil)
        #expect(HighlightLink.address(URL(string: "file:///pages/garden.html")!, selection: "words", before: "") != nil)
    }
}

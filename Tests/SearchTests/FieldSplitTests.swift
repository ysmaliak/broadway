import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
struct FieldSplitTests {
    private static let page: (blank: Bool, bench: Bool)? = (false, false)
    private static let url = URL(string: "https://example.test/notes")!

    private func placed(_ place: FieldPlace) -> Suggestion.Kind {
        .placed(FieldPlaceItem(place: place, id: "1", title: "Notes", detail: "", aside: "", url: Self.url))
    }

    @Test func whatIsTypedTakesTheSplit() {
        #expect(FieldSplit.splits(nil, switches: false, splitView: true, page: Self.page))
    }

    @Test func rowsThatLoadAPageTakeTheSplit() {
        let kinds: [Suggestion.Kind] = [.visited, .bookmark, .known, .search, .suggested, .passage, .open,
                                        placed(.history), placed(.bookmarks)]
        for kind in kinds {
            #expect(FieldSplit.splits(kind, switches: false, splitView: true, page: Self.page), "\(kind)")
        }
    }

    @Test func rowsThatDoSomethingElseDoWhatReturnDoes() {
        let kinds: [Suggestion.Kind] = [.command(.settings), .action("reader"),
                                        .answer(FieldAnswer(kind: .sum, expression: "2+2", answer: "4", copy: "4")),
                                        .snippet(Snippet(title: "Hello", keyword: "hi", text: "Hello there")),
                                        placed(.downloads), placed(.snippets)]
        for kind in kinds {
            #expect(!FieldSplit.splits(kind, switches: false, splitView: true, page: Self.page), "\(kind)")
        }
    }

    @Test func aRowThatSwitchesToAnOpenTabDoesWhatReturnDoes() {
        #expect(!FieldSplit.splits(.visited, switches: true, splitView: true, page: Self.page))
        #expect(!FieldSplit.splits(.open, switches: true, splitView: true, page: Self.page))
    }

    @Test func withSplitViewOffNothingTakesTheSplit() {
        #expect(!FieldSplit.splits(nil, switches: false, splitView: false, page: Self.page))
        #expect(!FieldSplit.splits(.visited, switches: false, splitView: false, page: Self.page))
        #expect(!FieldSplit.pairs(splitView: false, page: Self.page))
    }

    @Test func withNothingOnScreenToPairWithNothingTakesTheSplit() {
        #expect(!FieldSplit.splits(nil, switches: false, splitView: true, page: nil))
        #expect(!FieldSplit.splits(nil, switches: false, splitView: true, page: (blank: true, bench: false)))
        #expect(!FieldSplit.splits(nil, switches: false, splitView: true, page: (blank: false, bench: true)))
        #expect(FieldSplit.pairs(splitView: true, page: Self.page))
    }

    @Test func theHintNamesTheSplitOnlyWhenItSplits() {
        #expect(FieldPlace.history.hints(splits: true).contains { $0.keys == "⌥↩" && $0.word == "Split View" })
        #expect(!FieldPlace.history.hints(splits: false).contains { $0.keys == "⌥↩" })
        #expect(FieldPlace.bookmarks.hints(splits: true).first?.keys == "⌘↩")
        #expect(FieldPlace.downloads.hints(splits: true).allSatisfy { $0.keys != "⌥↩" })
    }
}

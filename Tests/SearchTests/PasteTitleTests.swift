import AppKit
import Testing
@testable import Search

@MainActor
private final class HeldBoard: CopiedBoard {
    var change = 1
    var secret = false
    var free = true
    var linky = false
    var words: String?
    var holdsText: Bool { words != nil }

    init(_ words: String?, free: Bool = true, linky: Bool = false) {
        self.words = words
        self.free = free
        self.linky = linky
    }

    func looksLikeLink() async -> Bool { linky }
    func text() -> String? { words }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct PasteTitleTests {
    @Test func anAddressOnTheClipboardIsPasteAndGo() {
        let title = PasteTitle(board: HeldBoard("https://example.com/news?id=4")).title(page: nil)

        #expect(title == "Paste and Go")
    }

    @Test func wordsOnTheClipboardArePasteAndSearch() {
        let title = PasteTitle(board: HeldBoard("best ramen in lisbon")).title(page: nil)

        #expect(title == "Paste and Search")
    }

    @Test func anEmptyClipboardIsPasteAndGo() {
        #expect(PasteTitle(board: HeldBoard(nil)).title(page: nil) == "Paste and Go")
        #expect(PasteTitle(board: HeldBoard("  \n ")).title(page: nil) == "Paste and Go")
    }

    @Test func anAddressWithoutASchemeIsPasteAndGo() {
        #expect(PasteTitle(board: HeldBoard("example.com/path")).title(page: nil) == "Paste and Go")
        #expect(PasteTitle(board: HeldBoard("  github.com  ")).title(page: nil) == "Paste and Go")
    }

    @Test func aFilePathIsPasteAndGoWithoutLookingAtTheDisk() {
        #expect(PasteTitle(board: HeldBoard("/nowhere-\(UUID().uuidString)/report.pdf")).title(page: nil) == "Paste and Go")
        #expect(PasteTitle(board: HeldBoard("~/Documents/report.pdf")).title(page: nil) == "Paste and Go")
    }

    @Test func anIssueReferenceOnItsSiteIsPasteAndGo() {
        let page = URL(string: "https://github.com/ysmaliak/broadway/pulls")

        #expect(PasteTitle(board: HeldBoard("#123")).title(page: page) == "Paste and Go")
    }

    @Test func aCopyIsGuessedWhenBroadwayComesBackBeforeTheMenuOpens() async throws {
        let paste = PasteTitle(board: HeldBoard("best ramen in lisbon", free: false, linky: false))

        paste.prime()
        for _ in 0..<100 where paste.title(page: nil) == "Paste and Go" { try await Task.sleep(for: .milliseconds(10)) }

        #expect(paste.title(page: nil) == "Paste and Search")
    }

    @Test func oneWordThatIsNotAnAddressIsPasteAndSearch() {
        #expect(PasteTitle(board: HeldBoard("ramen")).title(page: nil) == "Paste and Search")
    }

    @Test func theTitleFollowsTheClipboardEachTimeItIsAsked() {
        let board = HeldBoard("example.com")
        let paste = PasteTitle(board: board)
        #expect(paste.title(page: nil) == "Paste and Go")

        board.words = "example dot com"
        board.change += 1

        #expect(paste.title(page: nil) == "Paste and Search")
    }

    @Test func aClipboardBroadwayMayNotReadIsRetitledFromTheSystemsGuess() async throws {
        let board = HeldBoard("best ramen in lisbon", free: false, linky: false)
        let paste = PasteTitle(board: board)
        var later: String?

        let first = paste.title(page: nil) { later = $0 }
        for _ in 0..<100 where later == nil { try await Task.sleep(for: .milliseconds(10)) }

        #expect(first == "Paste and Go")
        #expect(later == "Paste and Search")
        #expect(paste.title(page: nil) == "Paste and Search")
    }

    @Test func aLinkBroadwayMayNotReadStaysPasteAndGo() async throws {
        let paste = PasteTitle(board: HeldBoard("https://example.com", free: false, linky: true))
        var later: String?

        _ = paste.title(page: nil) { later = $0 }
        try await Task.sleep(for: .milliseconds(200))

        #expect(later == nil)
        #expect(paste.title(page: nil) == "Paste and Go")
    }

    @Test func theShortcutsPageKeepsTheNamePasteAndGo() throws {
        let command = try #require(Command.all.first { $0.id == "tabs.pasteAndGo" })

        #expect(command.title == "Paste and Go")
    }
}

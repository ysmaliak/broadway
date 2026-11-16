import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FieldAnswerRowTests {
    private var browser: Browser!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        _ = browser.open(URL(string: "about:blank#page")!, foreground: true)
        AnswerBoard.write("")
    }

    private func tearDown() async {
        browser.closeAll()
        browser = nil
    }

    private func answerRow() -> FieldAnswer? {
        if case .answer(let answer) = browser.offers.first?.kind { return answer }
        return nil
    }

    @Test func theBoardIsNotTheGeneralPasteboardInTests() {
        #expect(AnswerBoard.board.name != NSPasteboard.general.name)
    }

    @Test func anAnswerLeadsTheListAboveTheSearch() {
        browser.edit()

        browser.typed = "20% of 80"

        #expect(answerRow()?.answer == "16")
        #expect(browser.offers.first?.leads == true)
        #expect(browser.ending == nil)
        #expect(browser.offers.dropFirst().contains { $0.kind == .search })
        #expect(browser.offers.filter { $0.leads }.count == 1)
    }

    @Test func returnCopiesTheAnswerAndKeepsTheFieldOpen() {
        browser.edit()
        browser.typed = "1000 * 1000"

        browser.submit()

        #expect(AnswerBoard.written == "1000000")
        #expect(browser.announcement == "Copied")
        #expect(browser.editing)
        #expect(browser.typed == "1000 * 1000")
        #expect(browser.offers.first?.leads == true)
        #expect(browser.active?.shownURL?.absoluteString == "about:blank#page")
    }

    @Test func commandReturnCopiesTheQuestionWithTheAnswer() {
        browser.edit()
        browser.typed = "5 km in mi"
        let tabs = browser.tabs.count

        browser.submit(aside: true)

        #expect(AnswerBoard.written == "5 km in mi = 3.10686 mi")
        #expect(browser.tabs.count == tabs)
        #expect(browser.editing)
        #expect(browser.typed == "5 km in mi")
    }

    @Test func clickingTheRowCopiesIt() {
        browser.edit()
        browser.typed = "255 in hex"

        browser.take(browser.offers[0])

        #expect(AnswerBoard.written == "0xFF")
        #expect(browser.editing)
        #expect(browser.typed == "255 in hex")
    }

    @Test func optionReturnCopiesTheSelectedAnswerWithoutOpeningATab() throws {
        browser.edit()
        browser.typed = "2+2"
        browser.picked = 0
        let tabs = browser.tabs.count
        let page = browser.activeID
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))

        let handled = browser.fieldKey(event)

        #expect(handled)
        #expect(AnswerBoard.written == "4")
        #expect(browser.tabs.count == tabs)
        #expect(browser.activeID == page)
        #expect(browser.active?.shownURL?.absoluteString == "about:blank#page")
        #expect(browser.editing)
        #expect(browser.typed == "2+2")
    }

    @Test func walkingPastTheAnswerSearchesInstead() {
        browser.edit()
        browser.typed = "2+2"
        let search = browser.offers.firstIndex { $0.kind == .search }

        browser.picked = search

        #expect(search != nil)
        #expect(browser.leadingAnswer == nil)
    }

    @Test func addressesAndWordsKeepTheirRows() {
        browser.edit()
        let typed = ["example.com", "weather tomorrow", "localhost:8080", "1.2.3.4", "iphone 15", "2024-11-04"]

        for text in typed {
            browser.typed = text
            #expect(answerRow() == nil, "\(text)")
            #expect(!browser.offers.contains { if case .answer = $0.kind { return true }; return false }, "\(text)")
        }
    }

    @Test func actionsOnAnAnswerCopyIt() {
        browser.edit()
        browser.typed = "2+2"
        browser.picked = 0

        let items = browser.fieldMenuItems(for: browser.pickedOffer)
        items.first { $0.id == "copyWhole" }?.run()

        #expect(items.map(\.title) == ["Copy", "Copy with Question"])
        #expect(AnswerBoard.written == "2+2 = 4")
    }

    @Test func noAnswerWhileSummoning() {
        browser.summon()

        browser.typed = "2+2"

        #expect(answerRow() == nil)
    }
}

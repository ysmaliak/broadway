import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(5)))
struct TitleSettleTests {
    @Test func idleTitlesPassStraightThrough() {
        var settle = TitleSettle()

        let shown = settle.heard("(1) Chat", at: 10)

        #expect(shown == "(1) Chat")
        #expect(settle.deadline == nil)
    }

    @Test func aStaticPageSettlesAfterTheQuietPeriod() {
        var settle = TitleSettle()
        settle.committed(at: 0)

        let early = settle.heard("Rivers in Spring", at: 0.05)
        let before = settle.tick(at: 0.05 + TitleSettle.quiet - 0.01)
        let after = settle.tick(at: 0.05 + TitleSettle.quiet)

        #expect(early == nil)
        #expect(before == nil)
        #expect(after == "Rivers in Spring")
        #expect(!settle.booting)
    }

    @Test func titlesWhileBootingCoalesceIntoTheLastOne() {
        var settle = TitleSettle()
        settle.committed(at: 0)

        var out: [String] = []
        for (at, title) in [(0.04, "Loading…"), (0.12, "Loading… 40%"), (0.22, "Mail"), (0.30, "Inbox (3) – Mail")] {
            if let shown = settle.heard(title, at: at) { out.append(shown) }
            if let shown = settle.tick(at: at) { out.append(shown) }
        }
        if let shown = settle.tick(at: 0.30 + TitleSettle.quiet) { out.append(shown) }

        #expect(out == ["Inbox (3) – Mail"])
    }

    @Test func loadEndSettlesAQuietTitleAtOnce() {
        var settle = TitleSettle()
        settle.committed(at: 0)
        _ = settle.heard("Docs", at: 0.05)

        let shown = settle.loadEnded(at: 0.05 + TitleSettle.floor + 0.01)

        #expect(shown == "Docs")
    }

    @Test func aTitleStillMovingAtLoadEndWaitsForQuiet() {
        var settle = TitleSettle()
        settle.committed(at: 0)
        _ = settle.heard("Loading…", at: 0.20)

        let atEnd = settle.loadEnded(at: 0.25)
        _ = settle.heard("Board – Tracker", at: 0.40)
        let between = settle.tick(at: 0.40 + TitleSettle.quiet - 0.01)
        let settled = settle.tick(at: 0.40 + TitleSettle.quiet)

        #expect(atEnd == nil)
        #expect(between == nil)
        #expect(settled == "Board – Tracker")
    }

    @Test func aPageWithoutATitleSettlesEmptyAQuietPeriodAfterLoad() {
        var settle = TitleSettle()
        settle.committed(at: 0)

        let atEnd = settle.loadEnded(at: 0.5)
        let later = settle.tick(at: 0.5 + TitleSettle.quiet)

        #expect(atEnd == nil)
        #expect(later == "")
    }

    @Test func aTitleArrivingAfterATitlelessLoadIsStillCoalesced() {
        var settle = TitleSettle()
        settle.committed(at: 0)
        _ = settle.loadEnded(at: 0.5)

        let first = settle.heard("Loading…", at: 0.56)
        let second = settle.heard("Board – Tracker", at: 0.76)
        let settled = settle.tick(at: 0.76 + TitleSettle.quiet)

        #expect(first == nil)
        #expect(second == nil)
        #expect(settled == "Board – Tracker")
    }

    @Test func emptyTitlesWhileBootingAreNotShown() {
        var settle = TitleSettle()
        settle.committed(at: 0)

        let empty = settle.heard("", at: 0.01)

        #expect(empty == nil)
        #expect(settle.deadline == nil)
    }

    @Test func aTitleThatNeverRestsIsShownWithinTheLongestWait() {
        var settle = TitleSettle()
        settle.committed(at: 0)

        var shown: String?
        var at = 0.0
        while shown == nil, at < 5 {
            at += 0.2
            shown = settle.heard("Tick \(Int(at * 10))", at: at)
            if shown == nil, let deadline = settle.deadline, deadline < at + 0.2 {
                at = deadline
                shown = settle.tick(at: deadline)
            }
        }

        #expect(shown != nil)
        #expect(at <= 0.2 + TitleSettle.longest + 0.001)
    }

    @Test func afterSettlingLaterTitlesShowPromptly() {
        var settle = TitleSettle()
        settle.committed(at: 0)
        _ = settle.heard("Chat", at: 0.05)
        _ = settle.loadEnded(at: 0.5)

        let later = settle.heard("(1) Chat", at: 3)

        #expect(later == "(1) Chat")
    }

    @Test func aLoadThatNeverCommittedSettlesNothing() {
        var settle = TitleSettle()

        let ended = settle.loadEnded(at: 1)

        #expect(ended == nil)
        #expect(settle.deadline == nil)
    }
}

@Suite(.timeLimit(.minutes(5)))
struct TitleSourceTests {
    @Test func historyComesFirst() {
        #expect(TitleSource.best(history: "Rivers in Spring | News", named: "Rivers", link: "read more") == "Rivers in Spring | News")
    }

    @Test func aNameIsUsedWhenHistoryHasNone() {
        #expect(TitleSource.best(history: nil, named: "My bookmark", link: "read more") == "My bookmark")
        #expect(TitleSource.best(history: "  ", named: "My bookmark") == "My bookmark")
    }

    @Test func linkWordsAreTheLastResort() {
        #expect(TitleSource.best(link: "  Read the\n  whole story ") == "Read the whole story")
    }

    @Test func nothingKnownIsNil() {
        #expect(TitleSource.best() == nil)
        #expect(TitleSource.best(history: "", named: " \n", link: "") == nil)
    }

    @Test func headingFallsBackToTheAddress() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(TitleSource.heading(known: "Known", url: url) == .title("Known"))
        #expect(TitleSource.heading(known: nil, url: url) == .address(url))
        #expect(TitleSource.heading(known: nil, url: nil) == .blank)
    }
}

import Foundation
import Testing
import WebKit
@testable import Search

@Suite
@MainActor
struct DialogRunTests {
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aPagesFirstDialogOffersNoWayToSilenceIt() {
        let run = DialogRun()
        #expect(!run.offersSilence(at: start))
        #expect(!run.silenced)
    }

    @Test func aSecondDialogWithinTenSecondsOfTheLastAnswerOffersToSilenceThePage() {
        var run = DialogRun()
        run.answer(at: start, silence: false)
        #expect(run.offersSilence(at: start.addingTimeInterval(1)))
        #expect(run.offersSilence(at: start.addingTimeInterval(9.9)))
        #expect(!run.silenced)
    }

    @Test func aDialogMoreThanTenSecondsAfterTheLastAnswerOffersNothing() {
        var run = DialogRun()
        run.answer(at: start, silence: false)
        #expect(!run.offersSilence(at: start.addingTimeInterval(10)))
        #expect(!run.offersSilence(at: start.addingTimeInterval(60)))
    }

    @Test func tickingTheBoxSilencesThePageForGood() {
        var run = DialogRun()
        run.answer(at: start, silence: false)
        run.answer(at: start.addingTimeInterval(1), silence: true)
        run.answer(at: start.addingTimeInterval(2), silence: false)
        #expect(run.silenced)
    }

    @Test func aSilencedPageIsHeardAgainAfterItNavigates() {
        let page = WKWebView()
        #expect(!DialogRuns.silenced(page))
        DialogRuns.answered(page, silence: false, at: start)
        #expect(DialogRuns.offersSilence(page, at: start.addingTimeInterval(2)))
        DialogRuns.answered(page, silence: true, at: start.addingTimeInterval(3))
        #expect(DialogRuns.silenced(page))
        DialogRuns.reset(page)
        #expect(!DialogRuns.silenced(page))
        #expect(!DialogRuns.offersSilence(page, at: start.addingTimeInterval(4)))
    }

    @Test func silencingOnePageLeavesAnotherHeard() {
        let one = WKWebView(), other = WKWebView()
        DialogRuns.answered(one, silence: true, at: start)
        #expect(DialogRuns.silenced(one))
        #expect(!DialogRuns.silenced(other))
        DialogRuns.reset(one)
    }
}

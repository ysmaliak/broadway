import Foundation
import Testing
@testable import Search

struct LeaveRulesTests {
    private let page = LeavePage()

    @Test(arguments: [LeaveWhy.navigate, .closeTab, .closeWindow, .quit, .restart(pressed: true)])
    func whatAPersonStartsAsks(_ why: LeaveWhy) {
        #expect(LeaveRules.answer(why, page: page, testing: false, held: false) == .ask)
    }

    @Test(arguments: [LeaveWhy.restart(pressed: false), .broadwayCloses, .broadwaySleeps])
    func whatBroadwayDoesByItselfNeverAsks(_ why: LeaveWhy) {
        #expect(LeaveRules.answer(why, page: page, testing: false, held: false) == .leave)
    }

    @Test(arguments: [LeaveWhy.navigate, .closeTab, .closeWindow, .quit])
    func anAgentsTabIsAnsweredLeave(_ why: LeaveWhy) {
        #expect(LeaveRules.answer(why, page: LeavePage(agent: true), testing: false, held: false) == .leave)
    }

    @Test func movingPickedTabsLeavesTheQuestionToBroadwaysOwn() {
        #expect(LeaveRules.answer(.movePicked, page: page, testing: false, held: false) == .leave)
    }

    @Test func aPageBroadwayAlreadyAskedAboutIsAnsweredLeave() {
        #expect(LeaveRules.answer(.quit, page: LeavePage(settled: true), testing: false, held: false) == .leave)
    }

    @Test func aStuckTabIsEndedAndClosedWithoutAQuestion() {
        #expect(LeaveRules.answer(.closeTab, page: LeavePage(stuck: true), testing: false, held: false) == .endThenLeave)
        #expect(LeaveRules.answer(.quit, page: LeavePage(stuck: true), testing: false, held: false) == .endThenLeave)
    }

    @Test func aTabWithNoPageHasNothingToAsk() {
        #expect(LeaveRules.answer(.closeTab, page: LeavePage(hasPage: false), testing: false, held: false) == .leave)
    }

    @Test func aTestWorldAsksOnlyWhenTheBenchHoldsTheQuestion() {
        #expect(LeaveRules.answer(.closeTab, page: page, testing: true, held: false) == .leave)
        #expect(LeaveRules.answer(.closeTab, page: page, testing: true, held: true) == .ask)
    }

    @Test func oneStayKeepsAWindowOrAQuit() {
        var run = LeaveRun(count: 3)

        let first = run.first
        let second = run.answered(leave: true)
        let kept = run.answered(leave: false)
        let later = run.answered(leave: true)

        #expect(first == .ask(0))
        #expect(second == .ask(1))
        #expect(kept == .keep)
        #expect(later == .keep)
    }

    @Test func everyPageLeavingLetsTheWindowGo() {
        var run = LeaveRun(count: 2)

        _ = run.answered(leave: true)
        let last = run.answered(leave: true)

        #expect(last == .go)
    }

    @Test func nothingToAskGoesAtOnce() {
        #expect(LeaveRun(count: 0).first == .go)
    }

    @Test func aCloseThePageHasNotAnsweredInFiveSecondsGoesAhead() {
        let since = Date(timeIntervalSince1970: 1000)

        #expect(!LeaveRules.timedOut(since: since, asked: false, at: since.addingTimeInterval(4.9)))
        #expect(LeaveRules.timedOut(since: since, asked: false, at: since.addingTimeInterval(5)))
    }

    @Test func aCloseThePageAskedAboutWaitsForThePerson() {
        let since = Date(timeIntervalSince1970: 1000)

        #expect(!LeaveRules.timedOut(since: since, asked: true, at: since.addingTimeInterval(60)))
    }

    @Test func aCloseWebKitSendsSoonAfterStayIsIgnored() {
        let stayed = Date(timeIntervalSince1970: 1000)

        #expect(LeaveRules.swallows(stayedAt: stayed, at: stayed.addingTimeInterval(0.5)))
        #expect(!LeaveRules.swallows(stayedAt: stayed, at: stayed.addingTimeInterval(6)))
        #expect(!LeaveRules.swallows(stayedAt: nil, at: stayed))
    }
}

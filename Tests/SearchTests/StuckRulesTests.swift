import Foundation
import Testing
@testable import Search

struct StuckRulesTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let times = StuckTimes.standard
    private let page = URL(string: "https://pond.example/notes")!

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func stuck(agent: Bool = false) -> StuckState {
        var state = StuckState()
        _ = StuckRules.heard(&state, at: start, agent: agent, times: times)
        return state
    }

    @Test func theWaitsAreTwelveAndTwentySecondsWithThirtyOfQuiet() {
        #expect(StuckTimes.standard == StuckTimes(question: 12, agent: 20, quiet: 30))
    }

    @Test func reloadOnAStuckTabEndsTheProcessThenReloads() {
        #expect(StuckRules.plan(.ask(.reload(fromOrigin: false)), stuck: true, remembers: true) == .endThen(.reload(fromOrigin: false)))
    }

    @Test func backForwardAndAnAddressOnAStuckTabEndTheProcessFirst() {
        #expect(StuckRules.plan(.ask(.back), stuck: true, remembers: true) == .endThen(.back))
        #expect(StuckRules.plan(.ask(.forward), stuck: true, remembers: true) == .endThen(.forward))
        #expect(StuckRules.plan(.ask(.address(page)), stuck: true, remembers: true) == .endThen(.address(page)))
    }

    @Test func stopOnAStuckTabEndsTheProcessAndLeavesItAsleep() {
        #expect(StuckRules.plan(.ask(.stop), stuck: true, remembers: true) == .endAndSleep)
    }

    @Test func putToSleepOnAStuckTabEndsTheProcessWithoutAskingThePage() {
        #expect(StuckRules.plan(.sleep, stuck: true, remembers: true) == .endAndSleep)
        #expect(StuckRules.plan(.sleep, stuck: false, remembers: true) == .asIs)
    }

    @Test func closeOnAStuckTabEndsTheProcessAndLoadsNothing() {
        #expect(StuckRules.plan(.close, stuck: true, remembers: true) == .endAndClose)
        #expect(StuckRules.plan(.close, stuck: false, remembers: true) == .asIs)
    }

    @Test func anAskOfATabThatAnswersIsRememberedForAReplay() {
        #expect(StuckRules.plan(.ask(.address(page)), stuck: false, remembers: true) == .remember(.address(page)))
    }

    @Test func anAskThatIsNotThePersonsIsNotRemembered() {
        #expect(StuckRules.plan(.ask(.reload(fromOrigin: false)), stuck: false, remembers: false) == .asIs)
    }

    @Test func wordThatTheTabIsStuckRightAfterAnAskDoesItAgainOnAFreshProcess() {
        var state = StuckState()
        StuckRules.remember(.reload(fromOrigin: true), in: &state, at: start)
        #expect(StuckRules.heard(&state, at: at(3), agent: false, times: times) == .redo(.reload(fromOrigin: true)))
        #expect(state.asked == nil)
        #expect(state.due == nil)
    }

    @Test func aStopAskedBeforeTheWordIsDoneAgainByPuttingTheTabToSleep() {
        #expect(StuckRules.redo(.stop) == .endAndSleep)
        #expect(StuckRules.redo(.back) == .endThen(.back))
    }

    @Test func anAskTheNewPageCommittedIsNotDoneAgain() {
        var state = StuckState()
        StuckRules.remember(.address(page), in: &state, at: start)
        StuckRules.committed(&state)
        #expect(StuckRules.heard(&state, at: at(3), agent: false, times: times) == .askAt(at(15)))
    }

    @Test func anAskOlderThanTheWordCanFollowIsNotDoneAgain() {
        var state = StuckState()
        StuckRules.remember(.back, in: &state, at: start)
        #expect(StuckRules.heard(&state, at: at(StuckTimes.askHolds + 1), agent: false, times: times) == .askAt(at(StuckTimes.askHolds + 13)))
    }

    @Test func theQuestionIsDueTwelveSecondsAfterTheWord() {
        var state = StuckState()
        #expect(StuckRules.heard(&state, at: start, agent: false, times: times) == .askAt(at(12)))
        #expect(state.since == start)
    }

    @Test func theQuestionIsNotDueBeforeItsTime() {
        var state = stuck()
        #expect(StuckRules.due(&state, at: at(11), onScreen: true, agent: false) == .nothing)
        #expect(!state.card)
    }

    @Test func aDueQuestionOnScreenPutsTheCardUp() {
        var state = stuck()
        #expect(StuckRules.due(&state, at: at(12), onScreen: true, agent: false) == .show)
        #expect(state.card)
    }

    @Test func aDueQuestionOffScreenWaitsForTheTabToComeForward() {
        var state = stuck()
        #expect(StuckRules.due(&state, at: at(12), onScreen: false, agent: false) == .owe)
        #expect(!state.card)
        #expect(StuckRules.cameForward(&state, agent: false))
        #expect(state.card)
    }

    @Test func aTabThatAnsweredBeforeComingForwardIsNotAskedAbout() {
        var state = stuck()
        _ = StuckRules.due(&state, at: at(12), onScreen: false, agent: false)
        StuckRules.answered(&state)
        #expect(!StuckRules.cameForward(&state, agent: false))
        #expect(!state.card)
    }

    @Test func aPageThatAnswersByItselfTakesTheCardAway() {
        var state = stuck()
        _ = StuckRules.due(&state, at: at(12), onScreen: true, agent: false)
        StuckRules.answered(&state)
        #expect(!state.card)
        #expect(!state.stuck)
        #expect(state.quietUntil == nil)
    }

    @Test func aPageThatAnswersBeforeTheQuestionIsDueIsNeverAsked() {
        var state = stuck()
        StuckRules.answered(&state)
        #expect(StuckRules.due(&state, at: at(12), onScreen: true, agent: false) == .nothing)
    }

    @Test func waitTakesTheCardAwayForTheQuietTime() {
        var state = stuck()
        _ = StuckRules.due(&state, at: at(12), onScreen: true, agent: false)
        StuckRules.wait(&state, at: at(13), times: times)
        #expect(!state.card)
        #expect(state.quietUntil == at(43))
        StuckRules.answered(&state)
        #expect(StuckRules.heard(&state, at: at(30), agent: false, times: times) == .nothing)
        #expect(StuckRules.due(&state, at: at(42), onScreen: true, agent: false) == .nothing)
    }

    @Test func afterTheQuietTheNextWordStartsTheTwelveSecondsAgain() {
        var state = stuck()
        _ = StuckRules.due(&state, at: at(12), onScreen: true, agent: false)
        StuckRules.wait(&state, at: at(13), times: times)
        StuckRules.answered(&state)
        #expect(StuckRules.heard(&state, at: at(44), agent: false, times: times) == .askAt(at(56)))
    }

    @Test func anotherWordWhileTheQuestionIsComingDoesNotMoveIt() {
        var state = stuck()
        #expect(StuckRules.heard(&state, at: at(5), agent: false, times: times) == .nothing)
        #expect(state.since == start)
        #expect(state.due == at(12))
    }

    @Test func anAgentsStuckTabIsNeverAskedAbout() {
        var state = StuckState()
        #expect(StuckRules.heard(&state, at: start, agent: true, times: times) == .endAgentAt(at(20)))
        #expect(state.due == nil)
        #expect(StuckRules.due(&state, at: at(30), onScreen: true, agent: true) == .nothing)
        #expect(!StuckRules.cameForward(&state, agent: true))
    }

    @Test func anAgentsTabIsRestartedOnlyAfterTwentySecondsStuck() {
        let state = stuck(agent: true)
        #expect(!StuckRules.agentDue(state, at: at(19), agent: true))
        #expect(StuckRules.agentDue(state, at: at(20), agent: true))
    }

    @Test func anAgentsTabThatAnswersIsNotRestarted() {
        var state = stuck(agent: true)
        StuckRules.answered(&state)
        #expect(!StuckRules.agentDue(state, at: at(20), agent: true))
    }

    @Test func anAgentsAskIsNeverReplayedButWaitsForItsRule() {
        var state = StuckState()
        StuckRules.remember(.reload(fromOrigin: false), in: &state, at: start)
        #expect(StuckRules.heard(&state, at: at(3), agent: true, times: times) == .endAgentAt(at(23)))
    }

    @Test func aRestartForAnAgentOwesItOneFailure() {
        var state = stuck(agent: true)
        state.letGo()
        StuckRules.restartedForAgent(&state)
        #expect(state.restarts == 1)
        #expect(StuckRules.takeAgentFailure(&state))
        #expect(!StuckRules.takeAgentFailure(&state))
    }

    @Test func theWordThatFollowsAnEndedProcessDoesNotForgiveTheAgentsFailure() {
        var state = stuck(agent: true)
        state.letGo()
        StuckRules.restartedForAgent(&state)
        StuckRules.answered(&state)
        #expect(state.owesAgent)
        #expect(state.quietUntil == nil)
    }

    @Test func endingTheProcessLetsGoOfEverythingButTheQuietAndTheAgentsDue() {
        var state = stuck()
        _ = StuckRules.due(&state, at: at(12), onScreen: true, agent: false)
        StuckRules.wait(&state, at: at(13), times: times)
        StuckRules.restartedForAgent(&state)
        state.letGo()
        #expect(!state.stuck)
        #expect(!state.card)
        #expect(state.quietUntil == at(43))
        #expect(state.owesAgent)
    }
}

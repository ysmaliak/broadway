import Foundation
import Testing
@testable import Search

@Suite
struct AgentSettlePauseTests {
    @Test func sleepsOnlyUntilTheQuietWindowEnds() {
        let left = AgentSettleRule.pause(elapsed: 0.45, quietFor: 0.45, busy: 0, navigating: false, cap: 5)
        #expect(abs(left - 0.05) < 0.000_1)
        #expect(abs(AgentSettleRule.pause(elapsed: 0.7, quietFor: 0.42, busy: 0, navigating: false, cap: 5) - 0.08) < 0.000_1)
        #expect(AgentSettleRule.pause(elapsed: 0.1, quietFor: 0.1, busy: 0, navigating: false, cap: 5) == AgentSettleRule.step)
        #expect(AgentSettleRule.pause(elapsed: 0.499, quietFor: 0.499, busy: 0, navigating: false, cap: 5) == AgentSettleRule.shortest)
    }

    @Test func keepsItsStepWhileARequestIsInFlight() {
        #expect(AgentSettleRule.pause(elapsed: 0.45, quietFor: 0.45, busy: 1, navigating: false, cap: 5) == AgentSettleRule.step)
    }

    @Test func looksSoonerWhileAPageLoads() {
        #expect(AgentSettleRule.pause(elapsed: 0.05, quietFor: 0, busy: 0, navigating: true, cap: 5) == AgentSettleRule.loadingStep)
        #expect(AgentSettleRule.pause(elapsed: 0.45, quietFor: 0.45, busy: 2, navigating: true, cap: 5) == AgentSettleRule.loadingStep)
        #expect(AgentSettleRule.pause(elapsed: 4.99, quietFor: 0, busy: 0, navigating: true, cap: 5) == AgentSettleRule.shortest)
    }

    @Test func takesAnotherStep() {
        #expect(AgentSettleRule.pause(elapsed: 0.2, quietFor: 0.2, busy: 0, navigating: false, cap: 10, step: 0.15) == 0.15)
        #expect(abs(AgentSettleRule.pause(elapsed: 0.45, quietFor: 0.45, busy: 0, navigating: false, cap: 10, step: 0.15) - 0.05) < 0.000_1)
        #expect(AgentSettleRule.pause(elapsed: 0.45, quietFor: 0.45, busy: 0, navigating: true, cap: 10, step: 0.15) == AgentSettleRule.loadingStep)
    }

    @Test func wakesAtTheCap() {
        #expect(abs(AgentSettleRule.pause(elapsed: 4.97, quietFor: 0, busy: 2, navigating: false, cap: 5) - 0.03) < 0.000_1)
        #expect(AgentSettleRule.pause(elapsed: 5.2, quietFor: 0, busy: 2, navigating: false, cap: 5) == AgentSettleRule.shortest)
    }

    @Test func theVerdictIsUnchanged() {
        #expect(AgentSettleRule.verdict(elapsed: 0.5, quietFor: 0.5, busy: 0, navigating: false, cap: 5) == .quiet)
        #expect(AgentSettleRule.verdict(elapsed: 0.5, quietFor: 0.49, busy: 0, navigating: false, cap: 5) == nil)
        #expect(AgentSettleRule.verdict(elapsed: 5, quietFor: 0.1, busy: 1, navigating: false, cap: 5) == .capped)
    }
}

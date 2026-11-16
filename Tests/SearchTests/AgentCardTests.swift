import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentCardTests {
    @Test func foldedTheCardIsThePlayersHeightAndSitsAtItsGap() {
        let one = [AgentsLayout.Section(rows: 2)]

        let folded = AgentsLayout.height(one, folded: true, column: 800)

        #expect(folded - AgentsLayout.below == MiniPlayerView.height)
        #expect(AgentsLayout.below == MiniPlayerView.below)
        #expect(AgentsLayout.pad == MiniPlayerView.openInset)
        #expect(AgentsLayout.corner == SideLook.cardRadius - AgentsLayout.pad)
    }

    @Test func theRowsMarksStayInLineWithTheTabsAbove() {
        #expect(Metrics.sideInset + AgentsLayout.pad + AgentsLayout.lead == Metrics.sideInset + SideLook.rowLead)
    }

    @Test func aFoldTurnedMidwayCarriesOnFromWhereItIsAtTheSameSpeed() {
        let spring = KitSpring.cover
        let from: CGFloat = 44, to: CGFloat = 300
        let turn = 0.09
        let share = spring.progress(turn)
        let at = Double(from) + Double(to - from) * share
        let speed = Double(to - from) * spring.rate(turn)
        let back = Double(from) - at
        let velocity = speed / back

        let next = AgentsAreaView.progress(.spring(spring), at: 0, velocity: velocity)
        let soon = AgentsAreaView.progress(.spring(spring), at: 0.001, velocity: velocity)
        let moved = back * soon.share

        #expect(next.share == 0)
        #expect(abs(moved - speed * 0.001) < abs(speed * 0.001) * 0.05)
        #expect(moved > 0)
    }

    @Test func theRingIsTwoPointsDeepAndLeavesThePageInsideAlone() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        let ring = AgentRimView.ring(in: bounds, corner: Metrics.pageRadius)

        #expect(ring.contains(CGPoint(x: 1, y: 150), using: .evenOdd))
        #expect(ring.contains(CGPoint(x: 200, y: 1.5), using: .evenOdd))
        #expect(!ring.contains(CGPoint(x: 2.5, y: 150), using: .evenOdd))
        #expect(!ring.contains(CGPoint(x: 200, y: 150), using: .evenOdd))
        #expect(AgentRimView.width == 2)
    }

    @Test func anAgentsTabWearsItsColourOnlyWhileTheAgentIsThere() {
        AgentLinks.shared.reset()
        defer { AgentLinks.shared.reset() }
        let link = AgentLinks.shared.join(.named("claude"), name: "Claude Code")
        let tab = Search.Tab(configuration: Web.configuration(space: UUID()))
        tab.agent = true
        tab.agentTask = link.id
        let mine = Search.Tab(configuration: Web.configuration(space: UUID()))

        let worn = tab.agentColour
        tab.driving = true
        let driving = tab.agentColour
        _ = AgentLinks.shared.end(link.id, .done(nil))

        #expect(worn == AgentCharacter.accentColor(link.accent))
        #expect(driving == worn)
        #expect(tab.agentColour == nil)
        #expect(mine.agentColour == nil)
    }
}

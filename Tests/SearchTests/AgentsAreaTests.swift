import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentsAreaTests {
    @Test func noAgentsTakeNoRoom() {
        let sections: [AgentsLayout.Section] = []

        let height = AgentsLayout.height(sections, folded: true, column: 800)

        #expect(height == 0)
    }

    @Test func foldedTheAreaIsOneRowHoweverManyAgentsWork() {
        let one = [AgentsLayout.Section(rows: 2)]
        let three = Array(repeating: AgentsLayout.Section(rows: 6, headed: true), count: 3)

        let alone = AgentsLayout.height(one, folded: true, column: 800)
        let crowd = AgentsLayout.height(three, folded: true, column: 800)

        #expect(alone == (AgentsLayout.row + AgentsLayout.margin))
        #expect(crowd == alone)
        #expect(AgentsLayout.row == Metrics.sideRowHeight)
    }

    @Test func unfoldedOneAgentsTabsSitRightUnderTheRow() {
        let one = [AgentsLayout.Section(rows: 2, headed: AgentsLayout.headed(1))]

        let height = AgentsLayout.height(one, folded: false, column: 800)

        #expect(!AgentsLayout.headed(1))
        #expect(height == (3 * AgentsLayout.row + AgentsLayout.margin))
    }

    @Test func severalAgentsEachGetAHeadingOverTheirTabs() {
        let two = [AgentsLayout.Section(rows: 2, headed: AgentsLayout.headed(2)), AgentsLayout.Section(rows: 0, headed: AgentsLayout.headed(2))]

        let content = AgentsLayout.content(two)

        #expect(AgentsLayout.headed(2))
        #expect(content == (4 * AgentsLayout.row))
        #expect(AgentsLayout.height(two, folded: false, column: 800) == (5 * AgentsLayout.row + AgentsLayout.margin))
    }

    @Test func theAreaNeverTakesMoreThanItsShareOfTheColumn() {
        let many = Array(repeating: AgentsLayout.Section(rows: 8, headed: true), count: 4)

        let height = AgentsLayout.height(many, folded: false, column: 700)

        #expect(height == (700 * AgentsLayout.share + AgentsLayout.margin))
    }

    @Test func aShortColumnStillShowsTheRow() {
        let one = [AgentsLayout.Section(rows: 4)]

        let height = AgentsLayout.height(one, folded: false, column: 60)

        #expect(height == (AgentsLayout.row + AgentsLayout.margin))
    }

    @Test func aPageRectIsReadAndBadOnesAreRefused() {
        let good: [String: Any] = ["x": 10, "y": 20.5, "width": 100, "height": 30]
        let bad: [String: Any] = ["x": 10, "y": 20, "width": -1, "height": 30]

        let rect = AgentPointer.rect(good)

        #expect(rect == CGRect(x: 10, y: 20.5, width: 100, height: 30))
        #expect(AgentPointer.rect(bad) == nil)
        #expect(AgentPointer.rect(nil) == nil)
    }

    @Test func typingPointsAtTheFieldsStart() {
        let field = CGRect(x: 100, y: 50, width: 200, height: 30)

        let typing = AgentPointer(target: field, kind: .type, at: Date(), name: "A", accent: 0).spot
        let clicking = AgentPointer(target: field, kind: .click, at: Date(), name: "A", accent: 0).spot

        #expect(typing == CGPoint(x: 118, y: 65))
        #expect(clicking == CGPoint(x: 200, y: 65))
    }

    @Test func theAreaStartsFoldedAndRemembersBeingUnfolded() throws {
        let suite = "agents-fold-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let fresh = AgentsFolds(store: store)

        let first = fresh.folded
        fresh.toggle()
        let later = AgentsFolds(store: store)
        later.toggle()

        #expect(first)
        #expect(!fresh.folded)
        #expect(later.folded)
        #expect(AgentsFolds(store: store).folded)
    }

    @Test func aSessionWithManyTabsShowsFourAndAMoreRowUntilOpenedWhole() {
        let five = AgentsLayout.Section(rows: 5)
        let eight = AgentsLayout.Section(rows: 8, headed: true)
        let whole = AgentsLayout.Section(rows: 8, whole: true)

        let rows = [five, eight, whole].map(AgentsLayout.rows)

        #expect(rows == [5, 5, 8])
        #expect(AgentsLayout.shown(8, whole: false) == 4)
        #expect(AgentsLayout.sectionHeight(eight) == (6 * AgentsLayout.row))
    }

    @Test func aPressGoesToTheQuestionFirstAndFoldsOnceItIsInFront() {
        let asking = UUID(), other = UUID()

        let calm = AgentsLayout.press(asking: nil, front: other)
        let asked = AgentsLayout.press(asking: asking, front: other)
        let nothingInFront = AgentsLayout.press(asking: asking, front: nil)
        let there = AgentsLayout.press(asking: asking, front: asking)

        #expect(calm == .fold)
        #expect(asked == .question)
        #expect(nothingInFront == .question)
        #expect(there == .fold)
    }

    @Test func theRowNamesOneAgentAndWhatItDoes() {
        let one = [(title: "Claude Code", state: AgentLinkState.working("Typing on github.com"))]

        let voice = AgentsLayout.voice(one)

        #expect(voice == AgentsLayout.Voice(title: "Agents", line: "Claude Code · Typing on github.com"))
    }

    @Test func theRowCountsSeveralAgentsByWhatTheyDo() {
        let several = [(title: "Claude Code", state: AgentLinkState.working("Reading")), (title: "Claude Code 2", state: .working("Typing")),
                       (title: "Codex", state: .done("All green")), (title: "Script", state: .failed(nil)), (title: "Zed", state: .idle)]

        let voice = AgentsLayout.voice(several)

        #expect(voice == AgentsLayout.Voice(title: "Agents", line: "2 working · 1 done · 1 failed · 1 idle"))
    }

    @Test func theRowSaysWhoWaitsAndForWhat() {
        let asked = [(title: "Claude Code", state: AgentLinkState.working("Reading")), (title: "Codex", state: .needsYou("Send on mail.google.com?"))]
        let bare = [(title: "Claude Code", state: AgentLinkState.working("Reading")), (title: "Codex", state: .needsYou(""))]
        let both = [(title: "Claude Code", state: AgentLinkState.needsYou("Pay?")), (title: "Codex", state: .needsYou("Send?"))]

        let voices = [asked, bare, both].map(AgentsLayout.voice)

        #expect(voices[0] == AgentsLayout.Voice(title: "Codex needs you", line: "Send on mail.google.com?", attention: true))
        #expect(voices[1] == AgentsLayout.Voice(title: "Codex needs you", line: "1 working", attention: true))
        #expect(voices[2] == AgentsLayout.Voice(title: "2 agents need you", line: "Claude Code: Pay?", attention: true))
    }

    @Test func theRowShowsThreeFacesAndNeverDropsTheOneThatAsks() {
        let ids = (0..<5).map { _ in UUID() }
        let calm = ids.map { (id: $0, attention: false) }
        let lastAsks = ids.enumerated().map { (id: $1, attention: $0 == 4) }

        let few = AgentsLayout.faces(Array(calm.prefix(2)))
        let capped = AgentsLayout.faces(calm)
        let kept = AgentsLayout.faces(lastAsks)

        #expect(few == Array(ids.prefix(2)))
        #expect(capped == Array(ids.prefix(3)))
        #expect(kept == [ids[0], ids[1], ids[4]])
    }

    @Test func unfoldedTheAreaScrollsToTheSessionThatAsksElseTheNewest() {
        let old = UUID(), asking = UUID(), newest = UUID()

        let calm = AgentsLayout.revealed([(old, false), (newest, false)])
        let asked = AgentsLayout.revealed([(old, false), (asking, true), (newest, false)])
        let none = AgentsLayout.revealed([])

        #expect(calm == newest)
        #expect(asked == asking)
        #expect(none == nil)
    }
}

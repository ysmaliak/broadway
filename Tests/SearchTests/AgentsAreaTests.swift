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
        #expect(height == (AgentsLayout.row + 2 * AgentsLayout.step + AgentsLayout.margin))
    }

    @Test func severalAgentsEachGetAHeadingAndKeepTheirOtherTabsFoldedUnderIt() {
        let two = [AgentsLayout.Section(rows: AgentsLayout.fold(3, headed: AgentsLayout.headed(2)), headed: AgentsLayout.headed(2)),
                   AgentsLayout.Section(rows: AgentsLayout.fold(0, headed: AgentsLayout.headed(2)), headed: AgentsLayout.headed(2))]
        var opened = two
        opened[0].open = true

        let content = AgentsLayout.content(two)

        #expect(AgentsLayout.headed(2))
        #expect(two.map(\.rows) == [2, 0])
        #expect(AgentsLayout.fold(3, headed: false) == 3)
        #expect(content == (2 * AgentsLayout.step))
        #expect(AgentsLayout.content(opened) == (4 * AgentsLayout.step))
        #expect(AgentsLayout.height(two, folded: false, column: 800) == (AgentsLayout.row + 2 * AgentsLayout.step + AgentsLayout.margin))
        #expect(AgentsLayout.height(opened, folded: false, column: 800) == (AgentsLayout.row + 4 * AgentsLayout.step + AgentsLayout.margin))
    }

    @Test func theAreaNeverTakesMoreThanItsShareOfTheColumn() {
        let many = Array(repeating: AgentsLayout.Section(rows: 8, headed: true, open: true), count: 4)

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

    @Test func anAgentsTabRowHasTheRegularTabRowsMetrics() {
        let height = Metrics.sideRowHeight
        let slots = AgentsLayout.rowSlots(width: 220, height: AgentsLayout.row)

        let square = Metrics.closeSquare(height), inset = Metrics.closeInset(height)

        #expect(AgentsLayout.row == height)
        #expect(AgentsLayout.gap == Metrics.sideGap)
        #expect(AgentsLayout.step == height + Metrics.sideGap)
        #expect(AgentsLayout.rowCorner == Metrics.sideRadius)
        #expect(slots.mark == NSRect(x: TabRowView.iconLead, y: (height - SideLook.rowMark) / 2, width: SideLook.rowMark, height: SideLook.rowMark))
        #expect(slots.close == NSRect(x: 220 - inset - square, y: inset, width: square, height: square))
        #expect(slots.dot.midX == slots.close.midX && slots.dot.midY == height / 2)
        #expect(AgentsLayout.pad + AgentsLayout.indent == SideLook.cardRowInset)
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

    @Test func anOldUnfoldedSettingIsForgottenSoEveryoneStartsFolded() throws {
        let suite = "agents-fold-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(true, forKey: AgentsFolds.retired)

        let folds = AgentsFolds(store: store)

        #expect(folds.folded)
        #expect(store.object(forKey: AgentsFolds.retired) == nil)
        #expect(store.object(forKey: AgentsFolds.key) == nil)
    }

    @Test func theChoiceIsKeptAcrossLaunchesBothWays() throws {
        let suite = "agents-fold-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }

        AgentsFolds(store: store).toggle()
        let opened = AgentsFolds(store: store).folded
        let again = AgentsFolds(store: store)
        again.toggle()

        #expect(!opened)
        #expect(AgentsFolds(store: store).folded)
        #expect(store.object(forKey: AgentsFolds.key) as? Bool == false)
    }

    @Test func aSessionWithManyTabsShowsFourAndAMoreRowUntilOpenedWhole() {
        let five = AgentsLayout.Section(rows: 5)
        let eight = AgentsLayout.Section(rows: 8, headed: true, open: true)
        let whole = AgentsLayout.Section(rows: 8, whole: true)
        let shut = AgentsLayout.Section(rows: 8, headed: true)

        let rows = [five, eight, whole, shut].map(AgentsLayout.rows)

        #expect(rows == [5, 5, 8, 0])
        #expect(AgentsLayout.shown(8, whole: false) == 4)
        #expect(AgentsLayout.sectionHeight(eight) == (6 * AgentsLayout.step))
        #expect(AgentsLayout.sectionHeight(shut) == AgentsLayout.step)
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

        #expect(voice == AgentsLayout.Voice(title: "Agents", line: "3 working · 1 done · 1 failed"))
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

    @Test func aListThatFitsDoesNotScrollAndOnlyAnOverflowingOneDoes() {
        let one = AgentsLayout.content([AgentsLayout.Section(rows: 1)])
        let many = AgentsLayout.content([AgentsLayout.Section(rows: 4, whole: true)])
        let viewport = 3 * AgentsLayout.step

        #expect(AgentsLayout.fits(content: one, viewport: one))
        #expect(AgentsLayout.limit(content: one, viewport: one) == 0)
        #expect(!AgentsLayout.fits(content: many, viewport: viewport))
        #expect(AgentsLayout.limit(content: many, viewport: viewport) == AgentsLayout.step)
    }

    @Test func aWheelGestureIsHandedOnOrKeptForItsWholeLengthAsItBegan() {
        let begins = AgentsLayout.wheelPasses(fits: true, starts: true, phased: true, held: nil)
        let carries = AgentsLayout.wheelPasses(fits: false, starts: false, phased: true, held: true)
        let keeps = AgentsLayout.wheelPasses(fits: true, starts: false, phased: true, held: false)
        let notch = AgentsLayout.wheelPasses(fits: false, starts: false, phased: false, held: true)

        #expect(begins)
        #expect(carries)
        #expect(!keeps)
        #expect(!notch)
    }

    @Test func theTopBandIsOffAtRestAndGrowsWithTheOffset() {
        let rest = AgentsLayout.bandStrength(0)
        let pulled = AgentsLayout.bandStrength(-12)
        let half = AgentsLayout.bandStrength(AgentsLayout.band / 2)
        let deep = AgentsLayout.bandStrength(200)
        let stops = AgentsLayout.bandStops(half, height: 140)

        #expect(rest == 0)
        #expect(pulled == 0)
        #expect(half == 0.5)
        #expect(deep == 1)
        #expect(stops.alphas == [0.5, 1, 1])
        #expect(stops.locations == [0, AgentsLayout.band / 140, 1])
        #expect(AgentsLayout.bandStops(0, height: 140).alphas == [1, 1, 1])
    }

    @Test func aRowBlursAsItPassesUnderTheBandAndNotWithReducedTransparency() {
        let row: ClosedRange<CGFloat> = 40...74

        let below = AgentsLayout.blur(row: row, offset: 0, strength: 1, plain: false)
        let entering = AgentsLayout.blur(row: row, offset: 33, strength: 1, plain: false)
        let under = AgentsLayout.blur(row: row, offset: 66, strength: 1, plain: false)
        let plain = AgentsLayout.blur(row: row, offset: 66, strength: 1, plain: true)
        let resting = AgentsLayout.blur(row: row, offset: 66, strength: 0, plain: false)

        #expect(below == 0)
        #expect(entering > 0 && entering < under)
        #expect(under == AgentsLayout.blurMost)
        #expect(plain == 0)
        #expect(resting == 0)
    }

    @Test func nothingButThePersonMovesTheListDuringAScrollAndForAWhileAfter() {
        let span = AgentsLayout.quietSpan

        #expect(span == 1.5)
        #expect(AgentsLayout.quiet(now: 10, last: 0, live: true))
        #expect(AgentsLayout.quiet(now: 10, last: 10 - span + 0.1, live: false))
        #expect(!AgentsLayout.quiet(now: 10, last: 10 - span - 0.1, live: false))
    }

    @Test func aListThatGotShorterIsBroughtBackToItsNewEndAndRestsOnWholePoints() {
        let back = AgentsLayout.clamped(80, limit: 43)
        let inside = AgentsLayout.clamped(40, limit: 43)

        #expect(back == 43)
        #expect(inside == nil)
        #expect(AgentsLayout.whole(12.4, limit: 43) == 12)
        #expect(AgentsLayout.whole(42.8, limit: 43) == 43)
        #expect(AgentsLayout.whole(12, limit: 43) == nil)
        #expect(AgentsLayout.whole(-3.5, limit: 43) == nil)
        #expect(AgentsLayout.whole(44.2, limit: 43) == nil)
    }
}

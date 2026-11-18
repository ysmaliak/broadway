import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentLinksTests {
    private var links: AgentLinks!
    private var living: Set<Int32> = []
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() {        links = AgentLinks()
        living = [101, 202]
        links.alive = { [unowned self] pid, _ in living.contains(pid) }
    }

    @Test func theSameAgentJoinsTheSameSession() {
        let key = AgentLinkKey.process(pid: 101, started: 7)

        let first = links.join(key, name: "Claude Code", at: start)
        let again = links.join(key, name: nil, at: start.addingTimeInterval(5))

        #expect(first.id == again.id)
        #expect(again.name == "Claude Code")
        #expect(links.lastHeard(again.id) == start.addingTimeInterval(5))
        #expect(links.live.count == 1)
    }

    @Test func aReusedProcessIdWithAnotherStartIsAnotherAgent() {
        let old = links.join(.process(pid: 101, started: 7), name: "Codex", at: start)

        let new = links.join(.process(pid: 101, started: 9), name: "Codex", at: start)

        #expect(old.id != new.id)
        #expect(links.live.count == 2)
    }

    @Test func twoAgentsKeepTheirOwnLastTab() {
        let one = links.join(.process(pid: 101, started: 1), name: "Claude Code", at: start)
        let two = links.join(.process(pid: 202, started: 1), name: "Codex", at: start)

        links.setCurrentTab(one.id, "aaaa1111")
        links.setCurrentTab(two.id, "bbbb2222")

        #expect(links.currentTab(one.id) == "aaaa1111")
        #expect(links.currentTab(two.id) == "bbbb2222")
    }

    @Test func disconnectEndsWithTheSummaryAndAJoinAfterwardsStartsAgain() {
        let key = AgentLinkKey.process(pid: 101, started: 1)
        let link = links.join(key, name: "Claude Code", at: start)
        var told: [AgentLink] = []
        links.ending = { told.append($0) }

        let ended = links.end(link.id, .done("Opened three\npull requests  "), at: start.addingTimeInterval(60))
        let next = links.join(key, name: "Claude Code", at: start.addingTimeInterval(61))

        #expect(ended)
        #expect(links.link(link.id)?.ended == .done("Opened three pull requests"))
        #expect(told.map(\.id) == [link.id])
        #expect(next.id != link.id)
        #expect(!links.end(link.id, .left))
    }

    @Test func aLongSummaryIsCut() {
        let link = links.join(.named("script"), name: "Script", at: start)

        links.end(link.id, .failed(String(repeating: "a", count: 500)))

        #expect(links.link(link.id)?.ended?.summary?.count == AgentLinks.summaryLimit)
        #expect(links.link(link.id)?.ended?.failed == true)
    }

    @Test func anIdleAgentIsLeftButABusyOneStays() {
        let idle = links.join(.process(pid: 101, started: 1), name: "A", at: start)
        let busy = links.join(.process(pid: 202, started: 1), name: "B", at: start)
        let later = start.addingTimeInterval(links.idleLimit + 1)

        let gone = links.sweep(at: later) { $0 == busy.id }

        #expect(gone == [idle.id])
        #expect(links.link(idle.id)?.ended == .left)
        #expect(links.link(busy.id)?.ended == nil)
    }

    @Test func anAgentWhoseProcessExitedEndsAtTheNextSweep() {
        let link = links.join(.process(pid: 101, started: 1), name: "Claude Code", at: start)
        living.remove(101)

        let gone = links.sweep(at: start.addingTimeInterval(30))

        #expect(gone == [link.id])
        #expect(links.link(link.id)?.ended == .done(nil))
    }

    @Test func closingAnMCPConnectionEndsItsSession() {
        let connection = UUID()
        let link = links.join(.connection(connection), name: AgentLinks.mcpName("claude-code"), at: start)

        links.endConnection(connection)

        #expect(link.name == "Claude Code")
        #expect(!(links.link(link.id)?.live ?? true))
    }

    @Test func endedCardsLeaveOnlyOnceTheirTabsAreGone() {
        let held = links.join(.named("one"), name: "One", at: start)
        let empty = links.join(.named("two"), name: "Two", at: start)
        links.end(held.id, .done(nil))
        links.end(empty.id, .done(nil))

        links.forgetEnded { $0 == held.id }

        #expect(links.link(held.id) != nil)
        #expect(links.link(empty.id) == nil)
    }

    @Test func namesAreOneShortLine() {
        let messy = "  Claude\nCode\u{7}  "

        let cleaned = AgentLinks.clean(messy)

        #expect(cleaned == "Claude Code")
        #expect(AgentLinks.clean("   ") == nil)
        #expect(AgentLinks.clean(String(repeating: "x", count: 90))?.count == 40)
    }

    @Test func executablesGetFriendlyNames() {
        let names = ["claude", "codex", "Cursor Helper (Renderer)", "my-bot"]

        let shown = names.map(AgentLinks.displayName(executable:))

        #expect(shown == ["Claude Code", "Codex", "Cursor", "My-bot"])
    }

    @Test func aQuestionOutranksEverythingOnTheCard() {
        let tabs = [AgentLinkState.TabFacts(acting: "Typing", host: "github.com"),
                    AgentLinkState.TabFacts(mood: .waving, driving: true, question: "Send on mail.google.com?")]

        let state = AgentLinkState.of(tabs, ended: nil)

        #expect(state == .needsYou("Send on mail.google.com?"))
        #expect(state.attention)
        #expect(state.mood == .waving)
        #expect(state.line == "Needs you: Send on mail.google.com?")
    }

    @Test func drivingThenEndingThenWorkingThenIdle() {
        let typing = AgentLinkState.TabFacts(acting: "Typing", host: "www.github.com")
        let driven = AgentLinkState.TabFacts(driving: true)

        let states = [AgentLinkState.of([typing, driven], ended: nil),
                      AgentLinkState.of([typing], ended: .failed("No access")),
                      AgentLinkState.of([typing], ended: nil),
                      AgentLinkState.of([AgentLinkState.TabFacts()], ended: nil),
                      AgentLinkState.of([], ended: .left)]

        #expect(states == [.driving, .failed("No access"), .working("Typing on github.com"), .idle, .done(nil)])
        #expect(states.map(\.mood) == [.driving, .failed, .typing, .idle, .done])
        #expect(states.map(\.animated) == [false, false, true, false, false])
    }

    @Test func statusLinesReadAsSentences() {
        let acts = ["Reading", "Looking", "Clicking", "Going to example.com", "Pressing a key"]

        let lines = acts.map { AgentLinkState.phrase($0, host: "WWW.Example.com") }

        #expect(lines == ["Reading example.com", "Looking at example.com", "Clicking on example.com",
                               "Going to example.com", "Pressing a key on example.com"])
        #expect(AgentLinkState.phrase("Reading", host: nil) == "Reading")
    }

    @Test func eachSessionHasASteadyAccentAndSeed() {
        let link = links.join(.named("x"), name: "X", at: start)

        let again = links.link(link.id)

        #expect(link.accent == again?.accent)
        #expect(link.seed == again?.seed)
        #expect((0..<AgentLinks.accents).contains(link.accent))
    }

    @Test func anAgentsColourFollowsItsNameNotItsSession() {
        let first = links.join(.named("one"), name: "Claude Code", at: start)
        let second = links.join(.named("two"), name: "Claude Code", at: start)
        let codex = links.join(.named("three"), name: "Codex", at: start)

        let script = AgentLinks.accent(for: "Nightly check")

        #expect(first.id != second.id)
        #expect(first.accent == second.accent)
        #expect(first.accent != codex.accent)
        #expect(script == AgentLinks.accent(for: "  nightly CHECK "))
        #expect(AgentLinks.accent(for: "Codex nightly") == codex.accent)
        #expect(AgentLinks.accent(for: "Claude (review)") == first.accent)
        #expect((0..<AgentLinks.accents).contains(script))
        #expect(!["a", "b", "Nightly check", "Python", "Probe Agent", "Script"].map(AgentLinks.accent).contains { $0 == first.accent || $0 == codex.accent })
    }

    @Test func renamingAnAgentChangesItsColourWithItsName() {
        let link = links.join(.named("x"), name: "Agent", at: start)

        links.rename(link.id, "Codex")

        #expect(links.link(link.id)?.accent == AgentLinks.accent(for: "Codex"))
    }

    @Test func twoSessionsOfOneProductAreToldApartByNumber() {
        let first = links.join(.named("a"), name: "Claude Code", at: start)
        let second = links.join(.named("b"), name: "Claude Code", at: start.addingTimeInterval(1))
        let codex = links.join(.named("c"), name: "Codex", at: start.addingTimeInterval(2))

        links.forget(first.id)
        let third = links.join(.named("d"), name: "Claude Code", at: start.addingTimeInterval(3))

        #expect(first.title == "Claude Code")
        #expect(second.title == "Claude Code 2")
        #expect(codex.title == "Codex")
        #expect(links.link(second.id)?.title == "Claude Code 2")
        #expect(third.title == "Claude Code")
    }

    @Test func aRenamedSessionTakesANumberAmongItsNewNames() {
        _ = links.join(.named("a"), name: "Codex", at: start)
        let other = links.join(.named("b"), name: "Agent", at: start)

        links.rename(other.id, "Codex")

        #expect(links.link(other.id)?.title == "Codex 2")
    }
}

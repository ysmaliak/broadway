import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentFinishTests {
    private var links: AgentLinks!
    private var living: Set<Int32> = []
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    init() {
        links = AgentLinks()
        living = [101, 202]
        links.alive = { [unowned self] pid, _ in living.contains(pid) }
    }

    private func state(_ link: AgentLink, _ tabs: [AgentLinkState.TabFacts] = []) -> AgentLinkState {
        let found = links.link(link.id) ?? link
        return AgentLinkState.of(tabs, ended: found.ended, rest: found.rest, last: found.last)
    }

    @Test func aTurnThatEndedReadsFinishedWithTheLastThingItDid() {
        let link = links.join(.named("session:claude:one"), name: "Claude Code", at: start)
        links.did(link.id, AgentLinkState.phrase("Reading", host: "www.example.com"))

        let finished = links.finish(link.id)
        let said = state(link)

        #expect(finished)
        #expect(said == .finished("Finished after reading example.com"))
        #expect(said.line == "Finished after reading example.com")
        #expect(said.mood == .done)
        #expect(!said.animated && !said.attention && !said.working)
        #expect(links.link(link.id)?.live == true)
    }

    @Test func aSummaryTakesThePlaceOfTheLastThing() {
        let link = links.join(.named("session:claude:two"), name: "Claude Code", at: start)
        links.did(link.id, "Clicking on example.com")

        links.finish(link.id, summary: "Found the three flights")

        #expect(state(link).line == "Found the three flights")
        #expect(AgentLinkState.finished(nil).line == "Finished")
    }

    @Test func theNextCommandMakesTheSameSessionWorkAgain() {
        let key = AgentLinkKey.named("session:claude:three")
        let link = links.join(key, name: "Claude Code", at: start)
        links.finish(link.id)

        links.calling(link.id, at: start.addingTimeInterval(30))
        let busy = state(link, [AgentLinkState.TabFacts(acting: "Reading", host: "example.com")])
        links.called(link.id, at: start.addingTimeInterval(31))
        let again = links.join(key, name: nil, at: start.addingTimeInterval(32))

        #expect(busy == .working("Reading example.com"))
        #expect(links.link(link.id)?.rest == nil)
        #expect(again.id == link.id)
        #expect(state(link) == .idle)
        #expect(state(link).line == "Thinking")
    }

    @Test func aQuestionUpIsNeverFinished() {
        let link = links.join(.named("session:claude:four"), name: "Claude Code", at: start)
        links.finish(link.id)
        let asked = [AgentLinkState.TabFacts(question: "Send on mail.example.com?", asking: true)]

        let said = state(link, asked)
        links.asking = { _ in true }
        links.sweep(at: start.addingTimeInterval(links.quietLimit + 1))

        #expect(said == .needsYou("Send on mail.example.com?"))
        #expect(said.attention)
        #expect(state(link, asked).attention)
    }

    @Test func aQuestionKeepsTheQuietTimeFromStarting() {
        let link = links.join(.named("session:codex:five"), name: "Codex", at: start)

        links.asking = { _ in true }
        links.sweep(at: start.addingTimeInterval(links.quietLimit + 1))

        #expect(links.link(link.id)?.rest == nil)
        #expect(state(link) == .idle)
    }

    @Test func aQuietAgentReadsIdleAfterTheQuietTimeAndNotBefore() {
        let link = links.join(.named("session:codex:six"), name: "Codex", at: start)
        links.did(link.id, "Reading example.com")

        links.sweep(at: start.addingTimeInterval(links.quietLimit - 1))
        let early = state(link)
        links.sweep(at: start.addingTimeInterval(links.quietLimit + 1))
        let late = state(link)

        #expect(early == .idle)
        #expect(late == .quiet("Reading example.com"))
        #expect(late.line == "Idle after reading example.com")
        #expect(late.mood == .ended)
        #expect(AgentLinkState.quiet(nil).line == "Idle")
        #expect(links.link(link.id)?.live == true)
    }

    @Test func aCallInFlightIsNeverQuiet() {
        let link = links.join(.named("session:codex:seven"), name: "Codex", at: start)
        links.calling(link.id, at: start)

        links.sweep(at: start.addingTimeInterval(links.quietLimit * 3))
        let waiting = links.link(link.id)?.rest
        links.called(link.id, at: start.addingTimeInterval(links.quietLimit * 3))
        links.sweep(at: start.addingTimeInterval(links.quietLimit * 3 + 10))

        #expect(waiting == nil)
        #expect(links.link(link.id)?.rest == nil)
        #expect(links.inFlight(link.id) == 0)
    }

    @Test func busyTabsAndTasksAreNeverQuiet() {
        let link = links.join(.named("session:codex:eight"), name: "Codex", at: start)
        let task = links.join(.task(UUID()), name: "Find a flight", at: start)

        links.sweep(at: start.addingTimeInterval(links.quietLimit + 1), busy: { $0 == link.id })

        #expect(links.link(link.id)?.rest == nil)
        #expect(links.link(task.id)?.rest == nil)
        #expect(!links.finish(task.id))
    }

    @Test func theTwentyMinuteEndStillComes() {
        let link = links.join(.named("session:codex:nine"), name: "Codex", at: start)
        links.finish(link.id)

        let gone = links.sweep(at: start.addingTimeInterval(links.idleLimit + 1))

        #expect(gone == [link.id])
        #expect(links.link(link.id)?.ended == .left)
    }

    @Test func doneWinsOverFinished() {
        let link = links.join(.named("session:claude:ten"), name: "Claude Code", at: start)
        links.finish(link.id)

        links.end(link.id, .done("Booked the table"))

        #expect(state(link) == .done("Booked the table"))
        #expect(!links.finish(link.id))
    }

    @Test func theAgentsProcessExitingEndsItsSession() {
        let link = links.join(.named("session:claude:eleven"), name: "Claude Code", at: start)
        links.watch(link.id, AgentProcessID(pid: 303, started: 1))
        let other = links.join(.named("session:claude:twelve"), name: "Claude Code", at: start)
        links.watch(other.id, AgentProcessID(pid: 101, started: 1))

        let gone = links.sweep(at: start.addingTimeInterval(1))

        #expect(gone == [link.id])
        #expect(links.link(link.id)?.ended == .done(nil))
        #expect(links.link(other.id)?.live == true)
    }

    @Test func aSharedConnectionClosingFinishesButKeepsTheSession() {
        let link = links.join(.named("session:claude:thirteen"), name: "Claude Code", at: start)
        let busy = links.join(.named("session:claude:fourteen"), name: "Claude Code", at: start)
        links.calling(busy.id, at: start)

        links.closedShared(link.id)
        links.closedShared(busy.id)

        #expect(links.link(link.id)?.rest == .finished(nil))
        #expect(links.link(link.id)?.live == true)
        #expect(links.link(busy.id)?.rest == nil)
    }

    @Test func theHeaderCountsFinishedAsDoneAndQuietAsIdle() {
        let several = [(title: "Claude Code", state: AgentLinkState.finished("Finished after reading example.com")),
                       (title: "Claude Code 2", state: .finished(nil)), (title: "Codex", state: .quiet(nil)),
                       (title: "Zed", state: .idle)]

        let voice = AgentsLayout.voice(several)
        let one = AgentsLayout.voice([several[0]])

        #expect(voice == AgentsLayout.Voice(title: "Agents", line: "1 working · 2 done · 1 idle"))
        #expect(!voice.attention)
        #expect(one == AgentsLayout.Voice(title: "Agents", line: "Claude Code · Finished after reading example.com"))
    }

    @Test func listingSaysFinishedAndIdle() {
        #expect(AgentLinks.word(.finished(nil)) == "finished")
        #expect(AgentLinks.word(.quiet(nil)) == "idle")
        #expect(AgentLinks.word(.idle) == "connected")
        #expect(AgentLinks.word(.needsYou("")) == "needs_you")
    }

    @Test func theFacesAreTheExistingOnes() {
        let face = AgentCharacter.face(.finished(nil), ended: nil, connected: start, now: start.addingTimeInterval(600))
        let quiet = AgentCharacter.face(.quiet(nil), ended: nil, connected: start, now: start.addingTimeInterval(600))

        #expect(face == .done)
        #expect(quiet == .ended)
        #expect(AgentCharacter.Mood.idle.title == "Thinking")
    }

    @Test func onlyTheSessionsOwnKindOfProgramIsWatchedAndNeverRepointed() {
        let link = links.join(.named("session:claude:fifteen"), name: "Claude Code", at: start)
        links.watch(link.id, AgentProcessID(pid: 101, started: 1))

        links.watch(link.id, AgentProcessID(pid: 303, started: 1))
        let gone = links.sweep(at: start.addingTimeInterval(1))

        #expect(links.link(link.id)?.process == AgentProcessID(pid: 101, started: 1))
        #expect(gone.isEmpty)
        #expect(AgentLinks.watchable("claude", session: "session:claude:x"))
        #expect(!AgentLinks.watchable("codex", session: "session:claude:x"))
        #expect(!AgentLinks.watchable("sandbox-exec", session: "session:codex:x"))
        #expect(!AgentLinks.watchable("zsh", session: nil))
        #expect(AgentLinks.watchable("codex", session: nil))
    }

    @Test func aCodexDesktopThreadWithNothingGoingOnReadsIdle() {
        let state = AgentLinkState.codex(CodexThread(id: "invented-thread"), ended: nil)

        #expect(state == .quiet(nil))
        #expect(state.line == "Idle")
        #expect(AgentsLayout.tally([state]) == "1 idle")
    }
}

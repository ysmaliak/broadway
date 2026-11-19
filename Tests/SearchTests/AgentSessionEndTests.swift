import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentSessionEndTests {
    struct Cell: Equatable, CustomStringConvertible {
        var state: String
        var shown: Bool
        var parked: Bool
        var cards: Int

        var description: String { "\(state) shown:\(shown ? "open" : "closed") parked:\(parked ? "open" : "closed") cards:\(cards)" }
    }

    private var browser: Browser!
    private var socket: AgentSocket!
    private var work = UUID()
    private var home = UUID()
    private var made: [UUID] = []
    private var questions: [UUID] = []
    private let start = Date()
    private let here = AgentLinks.shared.here
    private let alive = AgentLinks.shared.alive

    init() {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.splitView, "splitView")
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        browser.prefs.usesSpaces = true
        browser.prefs.splitView = false
        browser.prefs.agentMode = .auto
        browser.prefs.agentsOn = true
        work = browser.spaceID
        browser.spaces = [Space(id: work, name: "Work", colour: 0, icon: TabIcon(emoji: "💼")),
                          Space(id: home, name: "Home", colour: 1, icon: TabIcon(emoji: "🏠"))]
        AgentBoard.note(browser)
        AgentLinks.wire()
        AgentLinks.shared.here = { [work] in work }
        socket = AgentSocket()
        socket.box.browser = browser
    }

    private func tearDown() {
        for id in questions { AgentDesk.shared.take(id, .dropped) }
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
        AgentLinks.shared.here = here
        AgentLinks.shared.alive = alive
        browser?.switchSpace(to: work)
        browser?.closeAll()
        browser = nil
    }

    private func link(_ name: String = "Claude Code", key: AgentLinkKey? = nil) -> AgentLink {
        let made = AgentLinks.shared.join(key ?? .named("session:claude:" + UUID().uuidString.lowercased()), name: name, at: start)
        AgentLinks.shared.announce(made.id)
        self.made.append(made.id)
        return AgentLinks.shared.link(made.id) ?? made
    }

    private func page(_ name: String, in space: UUID, for link: AgentLink? = nil) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: space))
        tab.space = space
        tab.restore(url: URL(string: "https://example.com/\(name.lowercased())")!, title: name)
        if let link {
            tab.agent = true
            tab.bench = true
            tab.agentTask = link.id
        }
        return tab
    }

    private func place(_ link: AgentLink, looking: Bool = false) -> (shown: Tab, parked: Tab, mine: Tab) {
        let mine = page("Mine", in: work)
        let shown = page("Shown", in: work, for: link)
        let parked = page("Parked", in: home, for: link)
        let theirs = page("Theirs", in: home)
        browser.switchSpace(to: home)
        browser.showRow([theirs, parked], active: theirs.id)
        browser.switchSpace(to: work)
        browser.showRow([mine, shown], active: looking ? shown.id : mine.id)
        return (shown, parked, mine)
    }

    private func there(_ tab: Tab) -> Bool {
        (browser.tabs + browser.parked.values.flatMap(\.tabs)).contains { $0 === tab }
    }

    private func cards(_ link: AgentLink) -> Int {
        let listed = AgentLinks.shared.links.filter { $0.id == link.id }
        return [work, home].filter { space in
            browser.agentSessions(links: listed, front: true, in: space).contains { $0.id == link.id && !$0.tabs.isEmpty }
        }.count
    }

    private func at(_ minutes: Double, _ link: AgentLink, _ tabs: (shown: Tab, parked: Tab, mine: Tab)) async -> Cell {
        await AgentLinks.sweepAll(at: start.addingTimeInterval(minutes * 60))
        let found = AgentLinks.shared.link(link.id)
        let state = found == nil ? "gone" : found?.live == true ? "live" : "ended"
        return Cell(state: state, shown: there(tabs.shown), parked: there(tabs.parked), cards: cards(link))
    }

    private func timeline(_ link: AgentLink, _ tabs: (shown: Tab, parked: Tab, mine: Tab)) async -> [Cell] {
        var cells: [Cell] = []
        for minutes in [1.0, 20.1, 60, 180] { cells.append(await at(minutes, link, tabs)) }
        return cells
    }

    private func verb(_ noun: String, _ name: String, _ arguments: [String: Any] = [:], as link: AgentLink?) async throws -> [String: Any] {
        let verb = try #require(PersonCommands.find(noun, name))
        var call = PersonCall(noun: noun, verb: name, arguments: arguments, browser: browser, box: socket.box)
        call.link = link.flatMap { AgentLinks.shared.link($0.id) }
        return try await verb.run(call)
    }

    private func asked() async -> AgentQuestion? {
        for _ in 0..<600 {
            if let front = AgentDesk.shared.front { return front }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func doneKeep(_ agent: AgentLink, answer: AgentAnswer?) async throws -> (said: [String: Any], asked: AgentQuestion?) {
        let running = Task { try await self.verb("agents", "done", ["keep": true], as: agent) }
        let question = await asked()
        if let question {
            questions.append(question.id)
            if let answer { AgentDesk.shared.take(question.id, answer) }
        }
        return (try await running.value, question)
    }

    private func caller(_ executable: String, pid: Int32) throws -> AgentLink {
        let request: [String: Any] = ["agent": ["pid": Int(pid), "started": 1, "executable": executable]]
        let found = try #require(socket.link(for: request, create: true))
        made.append(found.id)
        return found
    }

    private static let gone = Cell(state: "gone", shown: false, parked: false, cards: 0)
    private static let handedShown = Cell(state: "gone", shown: true, parked: false, cards: 0)
    private let closedAfterEnd = [gone, gone, gone, gone]
    private let closedAtTwenty = [Cell(state: "live", shown: true, parked: true, cards: 2), gone, gone, gone]

    @Test func doneClosesItsTabsInEverySpace() async throws {
        let agent = link()
        let tabs = place(agent)
        tabs.shown.agentSeen = true

        let said = try await verb("agents", "done", ["summary": "Booked it"], as: agent)
        let now = (there(tabs.shown), there(tabs.parked))
        let cells = await timeline(agent, tabs)

        #expect(now == (false, false))
        #expect(said["left"] as? Int == 0)
        #expect(cells == closedAfterEnd)
        #expect(there(tabs.mine))
    }

    @Test func doneWithCloseMeansNoMoreThanDone() async throws {
        let agent = link()
        let tabs = place(agent)
        tabs.shown.agentSeen = true

        _ = try await verb("agents", "done", ["close": true], as: agent)
        let cells = await timeline(agent, tabs)

        #expect(cells == closedAfterEnd)
    }

    @Test func doneWithKeepHandsEveryTabToThePerson() async throws {
        let agent = link()
        let tabs = place(agent)

        let (said, question) = try await doneKeep(agent, answer: .yes)
        let cells = await timeline(agent, tabs)

        #expect(question?.title == "Keep this agent's 2 tabs as yours, in Work and Home?")
        #expect(said["keep"] as? String == "yes")
        #expect(!tabs.shown.agent && !tabs.parked.agent)
        #expect(!tabs.shown.bench && !tabs.parked.bench)
        #expect(cells.allSatisfy { $0.shown && $0.parked && $0.cards == 0 })
        #expect(browser.parked[home]?.tabs.contains { $0 === tabs.parked } == true)
    }

    @Test func doneWithKeepClosesEveryTabWhenThePersonSaysNo() async throws {
        let agent = link()
        let tabs = place(agent)

        let (said, question) = try await doneKeep(agent, answer: .no)
        let cells = await timeline(agent, tabs)

        #expect(question != nil)
        #expect(said["keep"] as? String == "said_no")
        #expect(cells == closedAfterEnd)
    }

    @Test func doneWithKeepClosesEveryTabWhenNobodyAnswersInTime() async throws {
        let agent = link()
        let tabs = place(agent)
        AgentLinks.shared.setPatience(agent.id, 0.3)

        let (said, question) = try await doneKeep(agent, answer: nil)
        let cells = await timeline(agent, tabs)

        #expect(question != nil)
        #expect(said["keep"] as? String == "needs_you")
        #expect(cells == closedAfterEnd)
    }

    @Test func theSessionEndHookAsksNothingEvenWithKeep() async throws {
        let session = UUID().uuidString.lowercased()
        let agent = link(key: .named("session:claude:" + session))
        let tabs = place(agent)
        let request: [String: Any] = ["op": "do", "noun": "agents", "verb": "done", "arguments": ["keep": true], "hook": true,
                                      "agent": ["session": "claude:" + session]]

        let reply = await PersonCommands.perform(request, browser: browser, socket: socket, channel: PersonChannel { _ in }) {
            socket.link(for: request, create: false)
        }
        let none = AgentDesk.shared.pending.isEmpty
        let cells = await timeline(agent, tabs)

        #expect(reply["ok"] as? Bool == true)
        #expect(none)
        #expect(cells == closedAfterEnd)
    }

    @Test func thePersonsOwnOpenFromATerminalEndsOnlyAfterTwentyQuietMinutesAndTheTabInFrontStaysTheirs() async throws {
        let pid: Int32 = 7100
        AgentLinks.shared.alive = { found, _ in found == pid }
        let terminal = try caller("Terminal", pid: pid)
        let tabs = place(terminal, looking: true)
        tabs.shown.agentSeen = true

        let cells = await timeline(terminal, tabs)

        #expect(cells == [Cell(state: "live", shown: true, parked: true, cards: 2), Self.handedShown, Self.handedShown, Self.handedShown])
        #expect(!tabs.shown.agent && !tabs.shown.bench)
    }

    @Test func thePersonsOwnOpenInTheBackgroundClosesAfterTwentyQuietMinutes() async throws {
        let pid: Int32 = 7200
        AgentLinks.shared.alive = { found, _ in found == pid }
        let terminal = try caller("iTerm2", pid: pid)
        let tabs = place(terminal)

        let cells = await timeline(terminal, tabs)

        #expect(cells == closedAtTwenty)
    }

    @Test func aShortScriptThatExitsKeepsItsTabsUntilTwentyQuietMinutes() async throws {
        AgentLinks.shared.alive = { _, _ in false }
        let script = try caller("python3", pid: 7300)
        let tabs = place(script)
        tabs.shown.agentSeen = true

        let cells = await timeline(script, tabs)

        #expect(cells == [Cell(state: "live", shown: true, parked: true, cards: 2), Self.handedShown, Self.handedShown, Self.handedShown])
        #expect(!tabs.shown.agent)
    }

    @Test func anAgentWithoutHooksFoundByItsProcessStillEndsWhenItsProcessIsGone() async throws {
        AgentLinks.shared.alive = { _, _ in false }
        for (index, name) in ["opencode", "gemini", "Cursor", "claude"].enumerated() {
            let agent = try caller(name, pid: 7400 + Int32(index))
            let tabs = place(agent)

            let cells = await timeline(agent, tabs)

            #expect(cells == closedAfterEnd, "\(name)")
        }
    }

    @Test func doneFailedClosesItsTabsToo() async throws {
        let agent = link()
        let tabs = place(agent)

        _ = try await verb("agents", "done", ["failed": true, "summary": "No seats"], as: agent)
        let ended = AgentLinks.shared.link(agent.id)?.ended
        let cells = await timeline(agent, tabs)

        #expect(ended == .failed("No seats"))
        #expect(cells == closedAfterEnd)
    }

    @Test func disconnectClosesItsTabs() async throws {
        let agent = link()
        let tabs = place(agent)

        _ = try await verb("agents", "disconnect", ["id": PersonCommands.short(agent.id)], as: nil)
        let cells = await timeline(agent, tabs)

        #expect(cells == closedAfterEnd)
    }

    @Test func theSessionEndHookClosesItsTabs() async throws {
        let session = UUID().uuidString.lowercased()
        let agent = link(key: .named("session:claude:" + session))
        let tabs = place(agent)
        let request: [String: Any] = ["op": "do", "noun": "agents", "verb": "done", "arguments": [String: Any](), "hook": true,
                                      "agent": ["session": "claude:" + session]]

        let reply = await PersonCommands.perform(request, browser: browser, socket: socket, channel: PersonChannel { _ in }) {
            socket.link(for: request, create: false)
        }
        let cells = await timeline(agent, tabs)

        #expect(reply["ok"] as? Bool == true)
        #expect(cells == closedAfterEnd)
    }

    @Test func aFinishedTurnFollowedBySilenceEndsAtTwentyMinutesAndClosesItsTabs() async throws {
        let agent = link()
        let tabs = place(agent)
        tabs.shown.agentSeen = true

        _ = try await verb("agents", "idle", as: agent)
        let cells = await timeline(agent, tabs)

        #expect(cells == closedAtTwenty)
    }

    @Test func anAgentWithNoHooksEndsAtTwentyMinutesAndClosesItsTabs() async {
        for name in ["Cursor", "opencode", "Gemini", "Codex"] {
            let agent = link(name, key: .process(pid: 4000 + Int32(made.count), started: 1))
            AgentLinks.shared.alive = { _, _ in true }
            let tabs = place(agent)

            let cells = await timeline(agent, tabs)

            #expect(cells == closedAtTwenty, "\(name)")
        }
    }

    @Test func theAgentsProcessGoneClosesItsTabs() async {
        let agent = link(key: .process(pid: 4242, started: 1))
        let tabs = place(agent)
        AgentLinks.shared.alive = { pid, _ in pid != 4242 }

        let cells = await timeline(agent, tabs)

        #expect(cells == closedAfterEnd)
    }

    @Test func aClosedMCPConnectionClosesItsTabs() async {
        let connection = UUID()
        let agent = link(key: .connection(connection))
        let tabs = place(agent)

        AgentLinks.shared.endConnection(connection)
        let cells = await timeline(agent, tabs)

        #expect(cells == closedAfterEnd)
    }

    @Test func anAskNeverAnsweredHoldsTheEndOnlyForASecondQuietLimit() async {
        let agent = link()
        let tabs = place(agent)
        var question = AgentQuestion(kind: .choice(["Yes", "No"]), title: "Which seat?")
        question.task = agent.id
        questions.append(question.id)
        let asked = question
        Task { @MainActor in _ = await AgentDesk.shared.ask(asked) }
        await Task.yield()

        let early = await at(20.1, agent, tabs)
        let late = await at(40.1, agent, tabs)

        #expect(early == Cell(state: "live", shown: true, parked: true, cards: 2))
        #expect(late == Self.gone)
        #expect(!AgentDesk.shared.pending.contains { $0.id == asked.id })
    }

    @Test func aTabStuckActingHoldsTheEndOnlyForASecondQuietLimit() async {
        let agent = link()
        let tabs = place(agent)
        tabs.parked.agentActing = "Clicking"

        let early = await at(20.1, agent, tabs)
        let late = await at(40.1, agent, tabs)

        #expect(early == Cell(state: "live", shown: true, parked: true, cards: 2))
        #expect(late == Self.gone)
    }

    @Test func aHeldCodexThreadLeavesTheCardAfterItsHold() async {
        let agent = link("Codex", key: .codex("invented-thread-" + UUID().uuidString))
        AgentLinks.shared.setCodex(agent.id, CodexThread(id: "invented-thread"))

        AgentLinks.shared.end(agent.id, .done(nil), at: start)
        await AgentLinks.sweepAll(at: start.addingTimeInterval(60))
        let held = AgentLinks.shared.link(agent.id) != nil
        await AgentLinks.sweepAll(at: start.addingTimeInterval(CodexDesktop.hold + 60))

        #expect(held)
        #expect(AgentLinks.shared.link(agent.id) == nil)
    }

    @Test func theTabThePersonIsLookingAtBecomesTheirs() async throws {
        let agent = link()
        let tabs = place(agent, looking: true)

        _ = try await verb("agents", "done", as: agent)

        #expect(there(tabs.shown) && !tabs.shown.agent && !tabs.shown.bench)
        #expect(!there(tabs.parked))
        #expect(browser.tabsInSession.contains(tabs.shown.id))
    }

    @Test func aSparedTabClosesOnceItsReasonIsGone() async throws {
        let agent = link()
        let tabs = place(agent)
        tabs.shown.noisy = true

        _ = try await verb("agents", "done", as: agent)
        let spared = there(tabs.shown) && tabs.shown.agent
        tabs.shown.noisy = false
        let cell = await at(1, agent, tabs)

        #expect(spared)
        #expect(cell == Self.gone)
    }

    @Test func aTabStillSparedAfterTheQuietLimitBecomesThePersonsInItsOwnSpace() async throws {
        let agent = link()
        let tabs = place(agent)
        tabs.parked.noisy = true

        _ = try await verb("agents", "done", as: agent)
        let early = await at(10, agent, tabs)
        let stillTheAgents = tabs.parked.agent
        let late = await at(20.1, agent, tabs)

        #expect(early == Cell(state: "ended", shown: false, parked: true, cards: 1))
        #expect(stillTheAgents)
        #expect(late == Cell(state: "gone", shown: false, parked: true, cards: 0))
        #expect(!tabs.parked.agent && !tabs.parked.bench)
        #expect(browser.parked[home]?.tabs.contains { $0 === tabs.parked } == true)
        #expect(cards(agent) == 0)
    }

    @Test func anOpenerAndItsPopupFromOneSessionCloseTogether() async throws {
        let agent = link()
        let tabs = place(agent)
        let popup = page("Popup", in: work, for: agent)
        popup.popup = true
        popup.opener = tabs.shown.id
        browser.showRow(browser.tabs + [popup], active: tabs.mine.id)

        _ = try await verb("agents", "done", as: agent)
        await AgentLinks.sweepAll(at: start.addingTimeInterval(60))

        #expect(!there(tabs.shown))
        #expect(!there(popup))
    }

    @Test func aReturningAgentIsToldItsSessionEnded() async throws {
        let session = "session:claude:" + UUID().uuidString.lowercased()
        let agent = link(key: .named(session))
        let tabs = place(agent)
        let closed = PersonCommands.short(tabs.parked.id)
        _ = try await verb("agents", "done", as: agent)
        await AgentLinks.sweepAll(at: start.addingTimeInterval(60))
        let back = link(key: .named(session))

        let named = await socket.target(closed, browser: browser, link: back.id)
        let bare = await socket.target(nil, browser: browser, link: back.id, reads: true)
        let again = await socket.target(nil, browser: browser, link: back.id, reads: true)

        guard case .failure(let refused) = named else { Issue.record("a closed tab was found: \(named)"); return }
        #expect(refused.code == "session_ended")
        #expect(refused.message.contains("ended"))
        guard case .failure(let first) = bare else { Issue.record("a bare read went to the person's tab: \(bare)"); return }
        #expect(first.code == "session_ended")
        if case .failure(let second) = again { #expect(second.code != "session_ended") }
    }

    @Test func aReturningAgentNeverActsOnATabThatIsNowThePersons() async throws {
        let session = "session:claude:" + UUID().uuidString.lowercased()
        let agent = link(key: .named(session))
        let tabs = place(agent, looking: true)
        let handed = PersonCommands.short(tabs.shown.id)
        _ = try await verb("agents", "done", as: agent)
        let back = link(key: .named(session))

        let named = await socket.target(handed, browser: browser, link: back.id)

        guard case .failure(let refused) = named else { Issue.record("the person's tab was reached: \(named)"); return }
        #expect(refused.code == "session_ended")
        #expect(!tabs.shown.agent)
    }

    @Test func anAgentTabIsNeverWrittenToTheSessionSoAQuitLeavesNothing() async {
        let agent = link()
        let tabs = place(agent)

        #expect(!browser.tabsInSession.contains(tabs.shown.id))
        #expect(browser.tabsInSession.contains(tabs.mine.id))
    }
}

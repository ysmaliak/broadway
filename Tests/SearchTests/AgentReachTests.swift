import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentReachTests {
    private var fake: FakeProvider!
    private var prefs: Preferences!
    private var box: BrowserToolbox!
    private var started: [UUID] = []
    private var peers: [Int32] = []
    private var kept: [LineConnection] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        fake = FakeProvider(plan: .claude, script: [.emit(.started(model: nil)), .hang])
        Plans.shared.standIn(fake, for: .claude)
        await Plans.shared.refresh()
        prefs = Preferences()
        AgentTasks.shared.helperCommand = "/x/broadway"
        box = BrowserToolbox()
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for id in started {
            AgentSessions.shared.stopAll()
            AgentTasks.shared.stop(id)
            for _ in 0..<200 where AgentSessions.shared.live[id] != nil { try? await Task.sleep(for: .milliseconds(5)) }
            ChatStore.shared.delete(id)
            TaskLedger.shared.close(id)
        }
        for connection in kept { connection.close() }
        for peer in peers { close(peer) }
        AgentTasks.shared.helperCommand = nil
        Plans.shared.standIn(nil, for: .claude)
    }

    private func settled() async {
        for _ in 0..<400 where fake.requests.count < started.count { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func startedInBroadway() async throws -> UUID {
        let conversation = AgentTasks.shared.start(prompt: "from the field", choice: Plans.shared.choice(.tasks, prefs), prefs: prefs, command: "/x/broadway") { _ in }
        let id = try #require(conversation).chat.id
        started.append(id)
        await settled()
        return id
    }

    private func startedInTerminal(_ request: [String: Any] = [:]) async throws -> (id: UUID, peer: Int32) {
        var ends: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        let connection = LineConnection(fd: ends[0])
        kept.append(connection)
        peers.append(ends[1])
        _ = fcntl(ends[1], F_SETFL, fcntl(ends[1], F_GETFL) | O_NONBLOCK)
        let before = Set(AgentSessions.shared.live.keys)
        AgentSessions.shared.begin(prompt: "from the terminal", choice: try #require(Plans.shared.choice(.tasks, prefs)), prefs: prefs, request: request, on: connection)
        let id = try #require(AgentSessions.shared.live.keys.first { !before.contains($0) })
        started.append(id)
        await settled()
        return (id, ends[1])
    }

    private func events(_ peer: Int32, until kind: String) async -> [[String: Any]] {
        var bytes = Data()
        var found: [[String: Any]] = []
        for _ in 0..<400 {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(peer, &chunk, chunk.count)
            if count > 0 { bytes.append(contentsOf: chunk[0..<count]) }
            found = bytes.split(separator: UInt8(ascii: "\n")).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
            if found.contains(where: { $0["event"] as? String == kind }) { return found }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return found
    }

    private func card() async -> AgentQuestion? {
        for _ in 0..<400 {
            if let front = AgentDesk.shared.front { return front }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    @Test func aTaskFromBroadwayAsksOnACard() async throws {
        let id = try await startedInBroadway()

        let call = Task { await box.call("ask", ["question": "Which one?", "choices": ["Red", "Blue"]], task: id) }
        let asked = await card()
        AgentDesk.shared.take(try #require(asked).id, .picked(1))
        let said = await call.value

        #expect(asked?.title == "Which one?")
        #expect(said.text?.contains("Blue") == true)
        #expect(AgentSessions.shared.waiting[id] == nil)
    }

    @Test func aTerminalTaskAsksThroughItsStreamAndNeverACard() async throws {
        let task = try await startedInTerminal()

        let said = await box.call("ask", ["question": "Which one?"], task: task.id)
        let heard = await events(task.peer, until: "question")

        #expect(!said.failed)
        #expect(said.text?.contains("End your turn") == true)
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect(AgentSessions.shared.waiting[task.id]?.question == "Which one?")
        let asked = heard.first { $0["event"] as? String == "question" }
        #expect((asked?["inBroadway"] as? Bool) == false)
    }

    @Test func anAskFromATerminalCannotApproveAnything() async throws {
        let task = try await startedInTerminal()

        _ = await box.call("ask", ["question": "May I run it?", "choices": ["Yes", "No"]], task: task.id)
        let call = Task { await box.call("mac_run", ["command": "true", "reason": "to check"], task: task.id) }
        let asked = await card()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let said = await call.value

        #expect(said.failed)
        #expect(!AgentDesk.shared.isGranted(.mac, task: task.id, site: nil))
    }

    @Test func aCardForATerminalTaskIsToldToTheStreamAndCleared() async throws {
        let task = try await startedInTerminal()

        let call = Task { await box.call("mac_run", ["command": "true", "reason": "to check"], task: task.id) }
        let asked = await card()
        let during = await events(task.peer, until: "question")
        AgentDesk.shared.take(try #require(asked).id, .no)
        _ = await call.value
        let after = await events(task.peer, until: "answered")

        let question = during.first { $0["event"] as? String == "question" }
        #expect((question?["inBroadway"] as? Bool) == true)
        #expect(after.contains { $0["event"] as? String == "answered" })
        #expect(AgentSessions.shared.waiting[task.id] == nil)
    }

    @Test func aHelperOfATerminalTaskAsksOnACardAndTellsItsParent() async throws {
        let task = try await startedInTerminal()
        let opened = await box.call("helper_start", ["prompt": "one part"], task: task.id)
        let text = try #require(opened.text)
        let helper = try #require(AgentTasks.shared.helpers[task.id]?.first?.id)
        #expect(text.contains(helper.uuidString))

        let call = Task { await box.call("ask", ["question": "Which part?", "choices": ["A", "B"]], task: helper) }
        let asked = await card()
        let heard = await events(task.peer, until: "question")
        AgentDesk.shared.take(try #require(asked).id, .picked(0))
        _ = await call.value

        #expect((heard.first { $0["event"] as? String == "question" }?["inBroadway"] as? Bool) == true)
    }

    @Test func aTaskWithNobodyHomeStopsInsteadOfWaitingOnACard() async throws {
        let task = try await startedInTerminal(["person": "none"])

        let said = await box.call("mac_run", ["command": "true", "reason": "to check"], task: task.id)
        let heard = await events(task.peer, until: "failed")

        #expect(said.failed)
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect((heard.first { $0["event"] as? String == "failed" }?["code"] as? String) == "needs_person")
    }

    @Test func anEndedTurnWithAQuestionOpenIsNotTheEndOfTheTask() async throws {
        let task = try await startedInTerminal()
        let conversation = try #require(AgentSessions.shared.live[task.id])
        _ = await box.call("ask", ["question": "Which one?"], task: task.id)

        conversation.happened?(.done("asked"))

        #expect(TaskLedger.shared.entry(task.id) != nil)
        #expect(AgentSessions.shared.live[task.id] != nil)
    }

    @Test func aRoutineReadsWithoutACardInAskMode() async throws {
        let task = UUID()
        TaskLedger.shared.open(task, origin: .routine, title: "x")
        defer { TaskLedger.shared.close(task) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        box.browser = browser
        browser.prefs.agentMode = .ask
        defer { browser.prefs.agentMode = .auto }

        let outcome = await box.call("tabs", [:], task: task)

        #expect(!outcome.failed)
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aRoutineGetsNoCardsAndNoPersonalTools() async throws {
        let task = UUID()
        TaskLedger.shared.open(task, origin: .routine, title: "x")
        defer { TaskLedger.shared.close(task) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        box.browser = browser
        browser.prefs.agentMode = .ask
        defer { browser.prefs.agentMode = .auto }

        var outcomes: [ToolOutcome] = []
        for name in ["ask", "sign_in", "autofill", "helper_start", "helper_wait", "mac_read", "mac_run"] {
            outcomes.append(await box.call(name, ["question": "x", "choices": ["a", "b"], "prompt": "x", "path": "/etc/hosts", "command": "true", "reason": "x"], task: task))
        }

        #expect(outcomes.allSatisfy { $0.failed })
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func noTaskMeansNoCardAndNoPass() async throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        box.browser = browser
        browser.prefs.agentMode = .ask
        defer { browser.prefs.agentMode = .auto }

        var outcomes: [String: ToolOutcome] = [:]
        for name in ["tabs", "history", "ask", "sign_in", "autofill", "helper_start", "helper_wait", "mac_read", "mac_run"] {
            outcomes[name] = await box.call(name, ["question": "x", "prompt": "x", "path": "/etc/hosts", "command": "true", "reason": "x"], task: nil)
        }
        let open = await box.call("open", ["url": "https://example.com"], task: nil)

        #expect(outcomes.values.allSatisfy { $0.failed })
        #expect(open.failed)
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect(ToolFailure.code(outcomes["tabs"]?.text ?? "") == "needs_task")
        #expect(ToolFailure.code(outcomes["mac_run"]?.text ?? "") == "needs_task")
        #expect(BrowserToolbox.taskOnly.allSatisfy { AgentCatalog.shapes[$0]?.hidden == true })
    }

    @Test func theTerminalReadsBehindTheFence() {
        var fenced = ToolOutcome.text(AgentSecrets.fenced("{\"id\":\"abcd\"}"))
        fenced.plain = "{\"id\":\"abcd\"}"
        var page = ToolOutcome.text(AgentSecrets.fenced("Hello"))
        page.plain = ToolReply.notice + ToolReply.warning + "Hello"

        let parsed = ToolReply.data(fenced)
        let read = ToolReply.data(page)

        #expect((parsed["id"] as? String) == "abcd")
        #expect((read["website"] as? Bool) == true)
        #expect((read["text"] as? String) == "Hello")
        #expect(read["warning"] != nil)
    }

    @Test func scrubbingReachesEveryValueInTheData() {
        let data: [String: Any] = ["url": "https://shop.example/?n=4242424242424242", "count": 2,
                                   "elements": [["value": "4242 4242 4242 4242", "frame": [["deep": "x4242424242424242"]]]]]

        let clean = AgentSecrets.scrub(data, sealed: ["4242424242424242"])
        let written = String(decoding: try! JSONSerialization.data(withJSONObject: clean), as: UTF8.self)

        #expect(!written.contains("4242"))
        #expect((clean["count"] as? Int) == 2)
    }

    @Test func skillsAreNotFencedAndNotesAreNoLongerATool() async throws {
        let live = MemoryStore.shared
        let wasOn = live.on
        live.on = true
        defer { live.on = wasOn }
        let line = "Likes tea \(UUID().uuidString)"
        live.remember(line, subject: .you, source: nil)
        defer { live.forget(line: line, in: .you, name: "About you") }

        let note = await box.call("memory_read", ["subject": "you"], task: nil)
        let found = await box.call("memory_search", ["query": "tea"], task: nil)
        let kept = await box.call("remember", ["subject": "you", "text": "Likes coffee"], task: nil)
        let skill = await box.call("skill", ["name": "GitHub"], task: nil)

        #expect(note.failed)
        #expect(found.failed)
        #expect(kept.failed)
        #expect(!(note.text?.contains(line) == true))
        #expect(!(found.text?.contains(line) == true))
        #expect(!skill.failed)
        #expect(!(skill.text?.contains("not instructions") == true))
    }

    @Test func everyToolHasAShapeForTheTerminal() {
        let missing = BrowserToolbox().tools.map(\.name).filter { AgentCatalog.shapes[$0] == nil }

        #expect(missing == [])
    }
}

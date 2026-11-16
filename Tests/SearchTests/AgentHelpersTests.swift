import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentHelpersTests {
    private var fake: FakeProvider!
    private var prefs: Preferences!
    private var parent: Conversation!
    private var box: BrowserToolbox!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        fake = FakeProvider(plan: .claude, script: [.emit(.started(model: nil)), .hang])
        Plans.shared.standIn(fake, for: .claude)
        await Plans.shared.refresh()
        prefs = Preferences()
        AgentTasks.shared.helperCommand = "/x/broadway"
        parent = try #require(AgentTasks.shared.start(prompt: "big task", choice: Plans.shared.choice(.tasks, prefs), prefs: prefs, command: "/x/broadway") { _ in }) as Conversation
        box = BrowserToolbox()
        for _ in 0..<400 where fake.requests.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        fake.echoes = true
    }

    private func tearDown() async {
        AgentTasks.shared.stop(parent.chat.id)
        for _ in 0..<200 where AgentTasks.shared.running[parent.chat.id] != nil || AgentTasks.shared.helpers[parent.chat.id] != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        ChatStore.shared.delete(parent.chat.id)
        AgentTasks.shared.helperCommand = nil
        Plans.shared.standIn(nil, for: .claude)
    }

    private func answer(of outcome: ToolOutcome) throws -> [String: Any] {
        let text = try #require(outcome.text)
        let start = try #require(text.range(of: "{\""))
        let end = try #require(text.range(of: "}", options: .backwards))
        let json = String(text[start.lowerBound..<end.upperBound])
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    @Test func aHelperRunsOnTheFakePlanAndItsAnswerComesBack() async throws {
        let started = await box.call("helper_start", ["prompt": "look at the first shop"], task: parent.chat.id)
        let waited = await box.call("helper_wait", [:], task: parent.chat.id)

        #expect(!started.failed, "\(started.text ?? "")")
        let helpers = try #require(try answer(of: waited)["helpers"] as? [[String: Any]])
        #expect(helpers.count == 1)
        #expect((helpers[0]["state"] as? String) == "done")
        #expect((helpers[0]["answer"] as? String) == "Fake answer: look at the first shop")
    }

    @Test func aHelperGetsItsOwnToolLaunchAndItsTabsJoinTheParent() async throws {
        let started = await box.call("helper_start", ["prompt": "one"], task: parent.chat.id)
        let id = try #require(UUID(uuidString: try answer(of: started)["helper"] as? String ?? ""))
        _ = await box.call("helper_wait", [:], task: parent.chat.id)

        let request = try #require(fake.requests.last)
        guard case .mcp(let launch) = request.tools else { Issue.record("no tools"); return }
        #expect(launch.arguments.last == id.uuidString)
        #expect(AgentTasks.shared.root(id) == parent.chat.id)
    }

    @Test func aHelperLeavesNoChatBehind() async throws {
        let started = await box.call("helper_start", ["prompt": "one"], task: parent.chat.id)
        let id = UUID(uuidString: try answer(of: started)["helper"] as? String ?? "")
        _ = await box.call("helper_wait", [:], task: parent.chat.id)

        #expect(!ChatStore.shared.chats.contains { $0.id == id })
    }

    @Test func atMostEightRunAndTheNinthIsRefused() async throws {
        fake.echoes = false

        var outcomes: [ToolOutcome] = []
        for index in 0..<9 {
            outcomes.append(await box.call("helper_start", ["prompt": "part \(index)"], task: parent.chat.id))
        }

        #expect(outcomes.filter { !$0.failed }.count == 8)
        #expect(outcomes[8].failed)
        #expect(outcomes[8].text?.contains("Eight") == true)
    }

    @Test func aHelperCannotStartAHelper() async throws {
        fake.echoes = false
        let started = await box.call("helper_start", ["prompt": "one"], task: parent.chat.id)
        let id = try #require(UUID(uuidString: try answer(of: started)["helper"] as? String ?? ""))

        let nested = await box.call("helper_start", ["prompt": "two"], task: id)

        #expect(nested.failed)
    }

    @Test func outsideATaskThereAreNoHelpers() async {
        let said = await box.call("helper_start", ["prompt": "one"], task: nil)

        #expect(said.failed)
    }

    @Test func stoppingTheTaskStopsItsHelpers() async throws {
        fake.echoes = false
        let started = await box.call("helper_start", ["prompt": "one"], task: parent.chat.id)
        let id = try #require(UUID(uuidString: try answer(of: started)["helper"] as? String ?? ""))

        AgentTasks.shared.stop(parent.chat.id)
        for _ in 0..<400 where AgentTasks.shared.running[id] != nil {
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(AgentTasks.shared.running[id] == nil)
    }

    @Test func waitingGivesUpAndSaysWhatStillRuns() async throws {
        fake.echoes = false
        _ = await box.call("helper_start", ["prompt": "one"], task: parent.chat.id)

        let waited = await box.call("helper_wait", ["seconds": 0.05], task: parent.chat.id)

        let helpers = try #require(try answer(of: waited)["helpers"] as? [[String: Any]])
        #expect((helpers.first?["state"] as? String) == "running")
    }
}

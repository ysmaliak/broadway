import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentReachTests {
    private var box: BrowserToolbox!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        box = BrowserToolbox()
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
    }

    @Test func noTaskMeansNoCardAndNoPass() async throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        box.browser = browser
        browser.prefs.agentMode = .ask
        defer { browser.prefs.agentMode = .auto }

        var outcomes: [String: ToolOutcome] = [:]
        for name in ["tabs", "history", "ask"] {
            outcomes[name] = await box.call(name, ["question": "x"], task: nil)
        }
        let open = await box.call("open", ["url": "https://example.com"], task: nil)

        #expect(outcomes.values.allSatisfy { $0.failed })
        #expect(open.failed)
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect(ToolFailure.code(outcomes["tabs"]?.text ?? "") == "needs_task")
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
        var said: [String: ToolOutcome] = [:]
        for name in ["memory_read", "memory_search", "remember", "no_such_tool"] {
            said[name] = await box.call(name, ["subject": "you", "query": "tea", "text": "Likes coffee"], task: nil)
        }
        let skill = await box.call("skill", ["name": "GitHub"], task: nil)

        for name in ["memory_read", "memory_search", "remember"] {
            #expect(said[name]?.failed == true, "\(name)")
            #expect(said[name]?.code == said["no_such_tool"]?.code, "\(name)")
        }
        #expect(!KnowledgeTools.offered.contains("memory_read"))
        #expect(!KnowledgeTools.offered.contains("memory_search"))
        #expect(KnowledgeTools.call("memory_read", ["subject": "you"]) == nil)
        #expect(!skill.failed)
        #expect(!(skill.text?.contains("not instructions") == true))
    }
    @Test func everyToolHasAShapeForTheTerminal() {
        let missing = BrowserToolbox().tools.map(\.name).filter { AgentCatalog.shapes[$0] == nil }

        #expect(missing == [])
    }
}

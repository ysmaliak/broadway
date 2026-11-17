import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentBatchTests {
    private var browser: Browser!
    private var socket: AgentSocket!
    private var server: LocalPageServer!
    private var tab: Tab!
    private var id = ""
    private let link = UUID()

    init() async throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        browser.prefs.agentsOn = true
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
        socket = AgentSocket()
        socket.box.browser = browser
        server = try LocalPageServer(["/page": .init(type: "text/html", body: """
        <!doctype html><title>Shop</title>
        <button onclick="window.added=(window.added||0)+1">Add to basket</button>
        <button onclick="window.sent=true">Send message</button>
        <label>Password <input id=p type=password></label>
        """)])
        let before = Set(browser.tabs.map(\.id))
        _ = await socket.box.call("open", ["url": "http://127.0.0.1:\(server.port)/page"], task: nil)
        tab = try #require(browser.tabs.first { !before.contains($0.id) })
        id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await socket.box.call("wait", ["tab": id], task: nil)
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        server?.stop()
        AgentSites.shared.reset()
        browser?.closeAll()
        browser = nil
    }

    private func ref(_ label: String) async throws -> String {
        let shot = await socket.box.call("snapshot", ["tab": id], task: link)
        let line = try #require(shot.text?.split(separator: "\n").first { $0.contains("\"\(label)\"") })
        let word = String(line.split(separator: " ")[0])
        return word.hasPrefix("@") ? String(word.dropFirst()) : word
    }

    private func step(_ tool: String, _ arguments: [String: Any], line: String? = nil) -> [String: Any] {
        ["tool": tool, "arguments": arguments, "line": line ?? tool]
    }

    private func value(_ script: String) async -> Any? {
        try? await tab.web.evaluateJavaScript(script)
    }

    private func added(_ want: Int) async -> Int {
        var seen = 0
        for _ in 0..<100 {
            seen = await value("window.added || 0") as? Int ?? 0
            if seen == want { return seen }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return seen
    }

    private func steps(_ reply: [String: Any]) -> [[String: Any]] {
        (reply["data"] as? [String: Any])?["steps"] as? [[String: Any]] ?? []
    }

    private func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    @Test func refusedStepsStopTheWholeBatchBeforeAnythingRuns() async throws {
        let add = try await ref("Add to basket")
        for bad in ["batch", "ask", "mac_run", "sign_in", "history", "nothing"] {
            let reply = await socket.batch(["steps": [step("click", ["tab": id, "ref": add]), step(bad, [:])]], browser: browser, link: link)

            #expect(code(reply) == "usage", "\(bad)")
            #expect((reply["data"] as? [String: Any])?["step"] as? Int == 2)
        }
        let many = await socket.batch(["steps": Array(repeating: step("click", ["tab": id, "ref": add]), count: AgentBatch.most + 1)], browser: browser, link: link)
        let lines = await socket.batch(["lines": ["click Save"]], browser: browser, link: link)

        #expect(code(many) == "usage")
        #expect(code(lines) == "usage")
        #expect(await value("window.added || 0") as? Int == 0)
    }

    @Test func eachStepRunsAndTheAnswerSaysWhatLanded() async throws {
        let add = try await ref("Add to basket")

        let reply = await socket.batch(["steps": [step("click", ["tab": id, "ref": add]), step("click", ["tab": id, "ref": add]), step("wait", ["tab": id])], "of": 3],
                                       browser: browser, link: link)

        let data = try #require(reply["data"] as? [String: Any])
        #expect(reply["ok"] as? Bool == true, "\(reply)")
        #expect(data["landed"] as? [Int] == [1, 2, 3])
        #expect(data["ran"] as? Int == 3)
        #expect(data["tab"] as? String == id)
        #expect(await added(2) == 2)
    }

    @Test func theFirstFailureStopsTheRestAndSaysWhatLanded() async throws {
        let add = try await ref("Add to basket")

        let reply = await socket.batch(["steps": [step("click", ["tab": id, "ref": add]), step("click", ["tab": id, "ref": "e999999"]),
                                                  step("click", ["tab": id, "ref": add])]], browser: browser, link: link)

        let error = try #require(reply["error"] as? [String: Any])
        #expect(reply["ok"] as? Bool == false)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["hint"] as? String == "broadway batch --from 2")
        #expect((reply["data"] as? [String: Any])?["landed"] as? [Int] == [1])
        #expect(steps(reply).last?["ran"] as? Bool == false)
        #expect(await added(1) == 1)
    }

    @Test func aSecretFieldStepIsRefusedAsItWouldBeAlone() async throws {
        let password = try await ref("Password")

        let reply = await socket.batch(["steps": [step("type", ["tab": id, "ref": password, "text": "hunter2"])]], browser: browser, link: link)
        let typed = await value("document.querySelector('#p').value") as? String

        #expect(reply["ok"] as? Bool == false)
        #expect((reply["data"] as? [String: Any])?["landed"] as? [Int] == [])
        #expect(typed == "")
        #expect(!String(describing: reply).contains("hunter2") || typed == "")
    }

    @Test func aHeavyStepAsksThePersonAndANoStopsTheBatch() async throws {
        let add = try await ref("Add to basket")
        let send = try await ref("Send message")

        let run = Task { await self.socket.batch(["steps": [step("click", ["tab": self.id, "ref": add]), step("click", ["tab": self.id, "ref": send, "final": "send"]),
                                                            step("click", ["tab": self.id, "ref": add])], "keep_going": true], browser: self.browser, link: self.link) }
        var asked: AgentQuestion?
        for _ in 0..<600 where asked == nil {
            asked = AgentDesk.shared.front
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard let question = asked else {
            let reply = await run.value
            Issue.record("no question: \(reply)")
            return
        }
        AgentDesk.shared.take(question.id, .no)
        let reply = await run.value

        #expect(reply["ok"] as? Bool == false)
        #expect((reply["data"] as? [String: Any])?["landed"] as? [Int] == [1])
        #expect(steps(reply).last?["ran"] as? Bool == false)
        #expect(await value("window.sent === true") as? Bool == false)
        #expect(await added(1) == 1)
    }

    @Test func aDrivenTabRefusesTheStep() async throws {
        let add = try await ref("Add to basket")
        browser.select(tab)
        browser.takeOver()

        let run = Task { await self.socket.batch(["steps": [step("click", ["tab": self.id, "ref": add])]], browser: self.browser, link: self.link) }
        try? await Task.sleep(for: .milliseconds(150))
        let clickedWhileDriving = await value("window.added || 0") as? Int
        browser.handBack()
        let reply = await run.value

        #expect(clickedWhileDriving == 0)
        #expect(reply["ok"] as? Bool == false)
        #expect(await value("window.added || 0") as? Int == 0)
    }

    @Test func keepGoingStillStopsOnThePersonsAnswers() async {
        var calls = 0
        let all = (1...3).map { AgentBatch.Step(n: $0, tool: "click", arguments: [:], line: "click \($0)") }

        let reply = await AgentBatch.run(all, keepGoing: true) { step in
            calls += 1
            return step.n == 2 ? ToolFailure.error("needs_you", "Waits for the person's yes") : ["ok": true, "data": ["page": ["title": "Shop"]]]
        }

        #expect(calls == 2)
        #expect(code(reply) == "needs_you")
        #expect((reply["error"] as? [String: Any])?["message"] as? String == "Step 2 waits for the person's yes")
    }

    @Test func keepGoingPassesAnOrdinaryFailure() async {
        var calls = 0
        let all = (1...3).map { AgentBatch.Step(n: $0, tool: "click", arguments: [:], line: "click \($0)") }

        let reply = await AgentBatch.run(all, keepGoing: true) { step in
            calls += 1
            return step.n == 2 ? ToolFailure.error("stale_ref", "Gone") : ["ok": true, "data": [:]]
        }

        #expect(calls == 3)
        #expect((reply["data"] as? [String: Any])?["landed"] as? [Int] == [1, 3])
        #expect(code(reply) == "stale_ref")
    }

    @Test func nothingLandedMeansARetryIsSafe() async {
        let reply = await AgentBatch.run([AgentBatch.Step(n: 4, tool: "click", arguments: [:], line: "click")], keepGoing: false) { _ in
            ToolFailure.error("not_found", "No element is named Pay")
        }

        #expect((reply["error"] as? [String: Any])?["retry_safe"] as? Bool == true)
        #expect((reply["error"] as? [String: Any])?["hint"] as? String == "broadway batch --from 4")
    }

    @Test func commandWordsReachTheirTools() {
        let tools = BrowserToolbox().tools
        #expect(AgentBatch.tool("go", in: tools) == "navigate")
        #expect(AgentBatch.tool("read", in: tools) == "text")
        #expect(AgentBatch.tool("shot", in: tools) == "screenshot")
        #expect(AgentBatch.tool("fill", in: tools) == "fill_form")
        #expect(AgentBatch.tool("find", in: tools) != nil)
    }

    @Test func refreshingSkillsNeverRunsInATestWorld() {
        #expect(!AgentCommand.refreshesSkills)
        #expect(!AgentCommand.setsUpAgents)
        #expect(AgentCommand.refreshWords == ["setup", "claude", "codex", "cursor", "opencode", "gemini", "--refresh"])
    }

    @Test func anUnmetExpectationStopsTheRun() async {
        var calls = 0
        let all = (1...3).map { AgentBatch.Step(n: $0, tool: "click", arguments: [:], line: "click \($0)") }

        let reply = await AgentBatch.run(all, keepGoing: true) { step in
            calls += 1
            let met = step.n != 2
            return ["ok": true, "data": ["page": ["title": "Shop"], "expect": ["kind": "text", "want": "1 item", "met": met]]]
        }

        #expect(calls == 2)
        #expect(code(reply) == "unmet")
        #expect((reply["data"] as? [String: Any])?["landed"] as? [Int] == [1, 2])
        #expect((reply["error"] as? [String: Any])?["retry_safe"] as? Bool == false)
    }

    @Test func aStepAfterANewPageMayNotUseAnOldRef() async {
        var calls = 0
        let all = [AgentBatch.Step(n: 1, tool: "click", arguments: ["ref": "e2"], line: "click @e2"),
                   AgentBatch.Step(n: 2, tool: "wait", arguments: ["text": "Checkout"], line: "wait Checkout"),
                   AgentBatch.Step(n: 3, tool: "click", arguments: ["target": ["ref": "e9"]], line: "click @e9")]

        let reply = await AgentBatch.run(all, keepGoing: false) { step in
            calls += 1
            return ["ok": true, "data": ["page": ["title": "Checkout", "navigated": step.n == 1]]]
        }

        #expect(calls == 2)
        #expect(code(reply) == "moved")
        #expect((reply["error"] as? [String: Any])?["message"] as? String == "Step 3 didn't run because it names @e9 from before step 1 went to a new page")
        #expect((reply["data"] as? [String: Any])?["landed"] as? [Int] == [1, 2])
    }

    @Test func aStepAfterADialogMustAnswerIt() async {
        var calls: [String] = []
        let all = [AgentBatch.Step(n: 1, tool: "click", arguments: ["ref": "e8"], line: "click @e8"),
                   AgentBatch.Step(n: 2, tool: "dialog", arguments: ["action": "accept"], line: "dialog accept"),
                   AgentBatch.Step(n: 3, tool: "click", arguments: [:], line: "click Go")]
        let other = [all[0], AgentBatch.Step(n: 2, tool: "click", arguments: [:], line: "click Go")]

        let answered = await AgentBatch.run(all, keepGoing: false) { step in
            calls.append(step.tool)
            return ["ok": true, "data": ["page": ["title": "Shop"], "dialog": step.n == 1 ? ["kind": "confirm", "message": "Sure?"] as Any : NSNull() as Any]]
        }
        let ignored = await AgentBatch.run(other, keepGoing: true) { step in
            ["ok": true, "data": ["page": ["title": "Shop"], "dialog": ["kind": "confirm", "message": "Sure?"]]]
        }

        #expect(answered["ok"] as? Bool == true)
        #expect(calls == ["click", "dialog", "click"])
        #expect(code(ignored) == "moved")
    }
}

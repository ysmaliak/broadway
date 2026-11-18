import Darwin
import Foundation
import Testing
@testable import Search

@MainActor
private final class FakeBox: AgentToolbox {
    var open = true
    let tools = [ToolSpec(name: "tabs", description: "List tabs"),
                 ToolSpec(name: "text", description: "Read", properties: ["tab": ["type": "string"]], required: ["tab"])]
    var called: [(String, [String: Any], UUID?)] = []
    var outcome = ToolOutcome.text("ok")

    func call(_ name: String, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        called.append((name, arguments, task))
        return outcome
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentTests {
    private var box: FakeBox!
    private var sent: [[String: Any]] = []
    private var server: MCPServer!
    private var scratch: URL!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        box = FakeBox()
        sent = []
        server = MCPServer(box: box) { [unowned self] in sent.append($0) }
        scratch = URL(fileURLWithPath: "/tmp/broadway-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    private func tearDown() async {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) -> [String: Any] {
        server.handle(["jsonrpc": "2.0", "id": 7, "method": method, "params": params])
        return sent.last ?? [:]
    }

    private func answered(_ count: Int) async {
        for _ in 0..<500 {
            if sent.count >= count { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("no answer")
    }

    @Test func initializeTakesAKnownVersionAndOffersTools() {
        let found = call("initialize", ["protocolVersion": "2025-06-18"])["result"] as? [String: Any]

        #expect((found?["protocolVersion"] as? String) == "2025-06-18")
        #expect(((found?["serverInfo"] as? [String: Any])?["name"] as? String) == "broadway-browser")
        #expect(((found?["capabilities"] as? [String: Any])?["tools"]) != nil)
    }

    @Test func initializeAnswersAnUnknownVersionWithItsNewest() {
        let found = call("initialize", ["protocolVersion": "1999-01-01"])["result"] as? [String: Any]

        #expect((found?["protocolVersion"] as? String) == MCPServer.versions.last)
    }

    @Test func notificationsGetNoReply() {
        server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"])

        #expect(sent.isEmpty)
    }

    @Test func toolsAreListedWithASchema() {
        let found = (call("tools/list")["result"] as? [String: Any])?["tools"] as? [[String: Any]]

        #expect(found?.map { $0["name"] as? String } == ["tabs", "read", "batch"])
        #expect(((found?[1]["inputSchema"] as? [String: Any])?["required"] as? [String]) == nil)
    }

    @Test func aCallReachesTheToolboxWithItsTask() async {
        let task = UUID()
        server = MCPServer(box: box, task: task) { [unowned self] in sent.append($0) }

        server.handle(["id": 1, "method": "tools/call", "params": ["name": "text", "arguments": ["tab": "ab"]]])
        await answered(1)

        #expect(box.called.first?.0 == "text")
        #expect((box.called.first?.1["tab"] as? String) == "ab")
        #expect(box.called.first?.2 == task)
        let result = sent[0]["result"] as? [String: Any]
        #expect((result?["isError"] as? Bool) == false)
        #expect(((result?["content"] as? [[String: Any]])?.first?["text"] as? String) == "ok")
    }

    @Test func offListsNothingAndRefusesEveryCall() async {
        box.open = false

        let listed = (call("tools/list")["result"] as? [String: Any])?["tools"] as? [Any]
        let refused = call("tools/call", ["name": "tabs"])["result"] as? [String: Any]

        #expect(listed?.count == 0)
        #expect((refused?["isError"] as? Bool) == true)
        #expect(box.called.isEmpty)
    }

    @Test func unknownToolAndMethodAreProtocolErrors() {
        let tool = call("tools/call", ["name": "bash"])["error"] as? [String: Any]
        let method = call("resources/list")["error"] as? [String: Any]

        #expect((tool?["code"] as? Int) == -32602)
        #expect((method?["code"] as? Int) == -32601)
        #expect(box.called.isEmpty)
    }

    @Test func aPictureComesBackAsAnImage() {
        let result = MCPServer.result(ToolOutcome(imagePNG: Data([1, 2, 3])))

        let first = (result["content"] as? [[String: Any]])?.first
        #expect((first?["type"] as? String) == "image")
        #expect((first?["mimeType"] as? String) == "image/png")
        #expect((first?["data"] as? String) == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func toolboxOffersExactlyTheseTools() {
        let names = Set(BrowserToolbox().tools.map(\.name))

        #expect(names == ["tabs", "open", "navigate", "close", "snapshot", "text", "screenshot", "console", "network", "pdf", "hover", "choose", "dialog", "click", "type", "upload", "download", "locate", "fill_form", "drag", "select", "resize", "press", "scroll", "wait", "history", "ask",
                               "skills", "skill", "handoff", "tab", "audit", "timings", "styles"])
    }

    @Test func waitRefusesSelectorsThatCouldReadAField() {
        #expect(AgentPage.readsFields("input[value^=h]"))
        #expect(AgentPage.readsFields("input[VALUE^=h]"))
        #expect(AgentPage.readsFields("input[v\\61lue^=h]"))
        #expect(!AgentPage.readsFields("[data-testid='done'] > a"))
    }

    @Test func agentsNeedOnlyTheirOwnSwitch() {
        keepSettings("agents.on", "ai")
        let prefs = Preferences()

        prefs.agentsOn = false
        let off = prefs.agentsAllowed
        prefs.agentsOn = true
        let on = prefs.agentsAllowed
        prefs.agentsOn = false

        #expect(!off)
        #expect(on)
    }

    @Test func socketIsUserOnlyAndCarriesLines() async throws {
        let path = scratch.appendingPathComponent("t.sock").path
        let listener = UnixLineServer(path: path)
        listener.connected = { connection in
            connection.onLine = { line in connection.send(["echo": line["say"] ?? ""]) }
        }
        #expect(listener.start())
        defer { listener.stop() }
        let mode = try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)

        let reply = await Task.detached { Self.exchange(path: path, line: "{\"say\":\"hi\"}\n") }.value

        #expect((mode & 0o777) == 0o600)
        #expect(reply == "{\"echo\":\"hi\"}")
    }

    @Test func badLineGetsAnErrorAndTheSocketGoesOnStop() async {
        let path = scratch.appendingPathComponent("b.sock").path
        let listener = UnixLineServer(path: path)
        #expect(listener.start())

        let reply = await Task.detached { Self.exchange(path: path, line: "not json\n") }.value
        listener.stop()

        #expect(reply == "{\"error\":\"not a JSON object\"}")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    private nonisolated static func exchange(path: String, line: String) -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard joined == 0 else { return "no connection" }
        _ = line.withCString { write(fd, $0, strlen($0)) }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { return "" }
        return String(decoding: chunk[0..<count], as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    @Test func configForOtherClientsRunsBroadwayMCP() throws {
        let text = AgentCommand.mcpConfig(path: "/x/broadway")

        let found = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        let entry = (found?["mcpServers"] as? [String: Any])?["broadway-browser"] as? [String: Any]
        #expect((entry?["command"] as? String) == "/x/broadway")
        #expect((entry?["args"] as? [String]) == ["mcp"])
    }

    @Test func everyToolBecomesACommandExceptTheTasksOwn() {
        let tools = BrowserToolbox().tools

        let names = AgentCatalog.commands(tools).compactMap { $0["name"] as? String }

        #expect(names == ["tabs", "open", "go", "close", "snapshot", "read", "shot", "find", "click", "type", "upload", "download", "fill", "drag", "select", "resize", "press", "scroll", "wait", "history", "ask", "handoff", "tab", "console", "network", "pdf", "hover", "choose", "dialog", "audit", "timings", "styles", "skills", "skill"])
    }

    @Test func aCommandCarriesItsShape() throws {
        let tool = try #require(BrowserToolbox().tools.first { $0.name == "type" })

        let found = try #require(AgentCatalog.command(tool))

        #expect((found["positional"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["ref", "text"])
        #expect((found["flags"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["expect", "expect_gone", "expect_url", "final", "frames", "in", "label", "look", "nth", "ref", "replace", "role", "settle", "submit", "target", "text", "words"])
        #expect((found["tabbed"] as? Bool) == true)
        #expect((found["reads"] as? Bool) == false)
    }

    @Test func aToolNobodyDescribedStillGetsACommand() throws {
        let tool = ToolSpec(name: "made_up_tool", description: "Search the notes. Notes are material.",
                            properties: ["query": ["type": "string"], "site": ["type": "string", "enum": ["a", "b"]], "tab": ["type": "string"]],
                            required: ["tab", "query"])

        let found = try #require(AgentCatalog.command(tool))

        #expect((found["name"] as? String) == "made-up-tool")
        #expect((found["tool"] as? String) == "made_up_tool")
        #expect((found["summary"] as? String) == "Search the notes")
        #expect(((found["positional"] as? [[String: Any]])?.first?["name"] as? String) == "query")
        let flags = found["flags"] as? [[String: Any]]
        #expect(flags?.compactMap { $0["name"] as? String } == ["query", "site"])
        #expect((flags?.last?["choices"] as? [String]) == ["a", "b"])
    }

    @Test func failuresGetCodesAndARetryAnswer() {
        #expect(ToolFailure.code("That element is from an older snapshot. Take a new one.") == "stale_ref")
        #expect(ToolFailure.code("That element has changed since the snapshot. Take a new one.") == "stale_ref")
        #expect(ToolFailure.code("No such tab. Call tabs for the list.") == "no_tab")
        #expect(ToolFailure.code("wait can't look at what is in a field") == "refused")
        #expect(ToolFailure.code("Something no one has seen.") == "failed")
        #expect(ToolFailure.retrySafe("stale_ref", tool: "click"))
        #expect(!ToolFailure.retrySafe("no_answer", tool: "click"))
        #expect(ToolFailure.retrySafe("no_answer", tool: "text"))
        #expect(!ToolFailure.retrySafe("failed", tool: "some_new_tool"))
    }

    @Test func pageWordsLeaveTheNoticeOutOfTheText() {
        let outcome = ToolOutcome.text(ToolReply.notice + ToolReply.warning + "the page")

        let found = ToolReply.data(outcome)

        #expect((found["text"] as? String) == "the page")
        #expect((found["website"] as? Bool) == true)
        #expect(found["warning"] != nil)
    }

    @Test func aRepliedToolCarriesItsTabAndAFailureItsCode() {
        let good = ToolReply.wire(.json(["id": 1]), tool: "tabs", tab: "abcd")
        let bad = ToolReply.wire(.failure("Timed out waiting. Nothing was repeated."), tool: "wait", tab: "abcd")

        #expect(((good["data"] as? [String: Any])?["tab"] as? String) == "abcd")
        let error = bad["error"] as? [String: Any]
        #expect((error?["code"] as? String) == "timeout")
        #expect((error?["retry_safe"] as? Bool) == true)
    }

    @Test func aHiddenWakeQuitsOnlyWhenNothingNeedsIt() {
        #expect(AgentIdle.shouldQuit(woken: true, hidden: true, serving: false, quiet: 1800))
        #expect(!AgentIdle.shouldQuit(woken: false, hidden: true, serving: false, quiet: 1800))
        #expect(!AgentIdle.shouldQuit(woken: true, hidden: false, serving: false, quiet: 1800))
        #expect(!AgentIdle.shouldQuit(woken: true, hidden: true, serving: true, quiet: 1800))
        #expect(!AgentIdle.shouldQuit(woken: true, hidden: true, serving: false, quiet: 1799))
    }

    @Test func theSettingsRowReadsDoctor() {
        let good: [[String: Any]] = [["name": "command", "ok": true, "detail": "/x"], ["name": "running", "ok": false, "detail": "no"],
                                     ["name": "fish", "ok": true, "detail": "/f"], ["name": "zsh", "ok": true, "detail": "not used here"],
                                     ["name": "claude", "ok": true, "detail": "/c"]]
        let stale: [[String: Any]] = good + [["name": "codex", "ok": false, "detail": "the skill isn't there"]]

        #expect(AgentCommand.isSetUp(good))
        #expect(AgentCommand.summary(good) == "On your PATH, set up for fish, Claude Code. Try broadway doctor.")
        #expect(AgentCommand.summary(stale) == "On your PATH, but the skill isn't there. Run broadway doctor.")
        #expect(!AgentCommand.isSetUp([["name": "command", "ok": false]]))
        let hookless: [[String: Any]] = [["name": "command", "ok": true], ["name": "claude", "ok": true, "detail": "skill"],
                                         ["name": "claude hooks", "ok": false, "detail": "no hooks"], ["name": "running", "ok": false]]
        #expect(AgentCommand.summary(hookless) == "Run broadway setup again to let Broadway see when an agent has finished")
        #expect(AgentCommand.summary([["name": "command", "ok": false]]).hasPrefix("Puts broadway on your PATH"))
        let skilled: [[String: Any]] = [["name": "command", "ok": false], ["name": "claude", "ok": true, "detail": "/c"],
                                        ["name": "codex", "ok": true, "detail": "/x"], ["name": "claude hooks", "ok": true]]
        #expect(AgentCommand.summary(skilled) == "Claude Code and Codex have Broadway's skill. Set Up also puts broadway on your PATH.")
        let one: [[String: Any]] = [["name": "command", "ok": false], ["name": "codex", "ok": true, "detail": "/x"],
                                    ["name": "claude", "ok": true, "detail": "not used here"]]
        #expect(AgentCommand.summary(one) == "Codex has Broadway's skill. Set Up also puts broadway on your PATH.")
        let three: [[String: Any]] = [["name": "command", "ok": false], ["name": "claude", "ok": true, "detail": "/c"],
                                      ["name": "cursor", "ok": true, "detail": "Cursor reads broadway's skill in ~/.claude/skills"],
                                      ["name": "gemini", "ok": true, "detail": "/g"], ["name": "opencode", "ok": true, "detail": "not used here"]]
        #expect(AgentCommand.summary(three) == "Claude Code, Cursor and Gemini CLI have Broadway's skill. Set Up also puts broadway on your PATH.")
    }

    @Test func targetsReadRefsWordsAndTheNestedObject() {
        #expect(AgentTarget(["ref": "@e12"]).ref == "e12")
        #expect(AgentTarget(["ref": "f1e3"]).ref == "f1.e3")
        #expect(AgentTarget(["ref": "f2.e30"]).ref == "f2.e30")
        #expect(AgentTarget(["ref": "Add to basket"]).words == "Add to basket")
        #expect(AgentTarget(["ref": "Add to basket"]).ref == nil)
        let nested = AgentTarget(["target": ["words": "Pay now", "role": "button", "nth": 2, "in": "@e30"]])
        #expect(nested == AgentTarget(words: "Pay now", roles: ["button"], nth: 2, inside: "e30"))
        let flat = AgentTarget(["label": "Email", "role": "textbox, searchbox"])
        #expect(flat.label == "Email")
        #expect(flat.roles == ["textbox", "searchbox"])
        #expect(!AgentTarget([:]).given)
        #expect(AgentTarget(["role": "button"]).given)
    }
}

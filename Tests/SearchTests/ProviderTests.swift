import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
final class ProviderTests {
    private func script(_ body: String) throws -> URL {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("broadway-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("tool")
        try ("#!/bin/bash\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    private func collect(_ session: ProviderSession) async -> (events: [ProviderEvent], error: Error?) {
        var seen: [ProviderEvent] = []
        do {
            for try await event in session.events { seen.append(event) }
            return (seen, nil)
        } catch {
            return (seen, error)
        }
    }

    @Test @MainActor func claudeArgumentsCloseEverythingForAPlainAnswer() {
        let request = ProviderRequest(system: "system", prompt: "SECRET PAGE TEXT", model: "sonnet", effort: .high)

        let arguments = ClaudeProvider.arguments(for: request)

        #expect(!arguments.joined().contains("SECRET PAGE TEXT"))
        #expect(arguments.contains("--safe-mode"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.contains("--no-session-persistence"))
        let tools = arguments.firstIndex(of: "--tools")
        #expect(tools.map { arguments[$0 + 1] } == "")
        #expect(!arguments.contains { $0.contains("dangerously") })
        #expect(!arguments.contains("--bare"))
        #expect(arguments.suffix(4) == ["--model", "sonnet", "--effort", "high"])
    }

    @Test @MainActor func claudeArgumentsForToolsNameOnlyThatServer() {
        let server = MCPLaunch(name: "broadway", command: "/tmp/broadway", arguments: ["mcp"])
        let request = ProviderRequest(system: "s", prompt: "p", tools: .mcp(server))

        let arguments = ClaudeProvider.arguments(for: request)

        #expect(arguments.contains("--restricted"))
        #expect(!arguments.contains("--safe-mode"))
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "")
        #expect(arguments.firstIndex(of: "--allowedTools").map { arguments[$0 + 1] } == "mcp__broadway")
        let config = arguments.firstIndex(of: "--mcp-config").map { arguments[$0 + 1] } ?? ""
        #expect(config.contains("/tmp/broadway"))
    }

    @Test @MainActor func codexArgumentsCloseTheShellAndReadTheStdin() {
        let request = ProviderRequest(system: "system", prompt: "SECRET PAGE TEXT", model: "gpt-x", effort: .low)

        let arguments = CodexProvider.arguments(for: request)
        let input = String(decoding: CodexProvider.stdin(for: request), as: UTF8.self)

        #expect(!arguments.joined().contains("SECRET PAGE TEXT"))
        #expect(input.contains("SECRET PAGE TEXT"))
        #expect(arguments.last == "-")
        for flag in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "--skip-git-repo-check", "--json"] {
            #expect(arguments.contains(flag), "\(flag)")
        }
        #expect(arguments.firstIndex(of: "--sandbox").map { arguments[$0 + 1] } == "read-only")
        #expect(zip(arguments, arguments.dropFirst()).contains { $0 == "--disable" && $1 == "shell_tool" })
        #expect(arguments.contains("web_search=\"disabled\""))
        #expect(!arguments.contains { $0.contains("dangerously") })
    }

    @Test @MainActor func claudeLinesReadTheRealRunShape() throws {
        let run = [
            #"{"type":"system","subtype":"init","cwd":"/x","tools":[],"mcp_servers":[],"model":"claude-haiku-5-5"}"#,
            #"{"type":"system","subtype":"status"}"#,
            #"{"type":"stream_event","event":{"type":"message_start"}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"po"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"ng"}}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"pong"}]}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"result":"pong","usage":{"input_tokens":2,"output_tokens":4}}"#,
        ]
        var lines = ClaudeLines()

        let events = try run.flatMap { try lines.feed($0) }

        #expect(events == [.started(model: "claude-haiku-5-5"), .text("po"), .text("ng"),
                                .rateLimit(PlanLimit(window: "current")),
                                .finished(ProviderUsage(inputTokens: 2, outputTokens: 4))])
        #expect(throws: Never.self) { try lines.ended(status: 0, stderr: "") }
    }

    @Test @MainActor func claudeLinesReadToolsAndUnstreamedText() throws {
        var lines = ClaudeLines()
        let use = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking"},{"type":"tool_use","id":"t1","name":"mcp__broadway__navigate","input":{"url":"https://a.example"}}]}}"#
        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]}}"#

        let first = try lines.feed(use)
        let again = try lines.feed(use)
        let second = try lines.feed(result)

        #expect(first == [.text("Looking"), .toolStarted(id: "t1", name: "navigate", summary: "https://a.example")])
        #expect(again == [.text("Looking")])
        #expect(second == [.toolFinished(id: "t1", failed: true)])
    }

    @Test @MainActor func claudeErrorsAreNamed() {
        var lines = ClaudeLines()
        let limit = #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your limit · resets 3pm"}"#
        let login = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"#

        #expect(throws: ProviderError.planOut("You've hit your limit · resets 3pm")) { try lines.feed(limit) }
        #expect(throws: ProviderError.notSignedIn(.claude)) { try lines.feed(login) }
    }

    @Test @MainActor func codexLinesReadThePublishedShape() throws {
        let run = [
            #"{"type":"thread.started","thread_id":"t"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"i0","type":"reasoning"}}"#,
            #"{"type":"item.started","item":{"id":"i1","type":"mcp_tool_call","tool":"tabs","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"i1","type":"mcp_tool_call","tool":"tabs","status":"failed"}}"#,
            #"{"type":"item.updated","item":{"id":"i2","type":"agent_message","text":"Hel"}}"#,
            #"{"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"Hello"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":5,"output_tokens":6}}"#,
        ]
        var lines = CodexLines()

        let events = try run.flatMap { try lines.feed($0) }

        #expect(events == [.started(model: nil), .status("Thinking"),
                                .toolStarted(id: "i1", name: "tabs", summary: ""), .toolFinished(id: "i1", failed: true),
                                .text("Hel"), .text("lo"), .finished(ProviderUsage(inputTokens: 5, outputTokens: 6))])
    }

    @Test @MainActor func codexTurnFailureThrows() {
        var lines = CodexLines()

        #expect(throws: ProviderError.planOut("You've hit your usage limit")) { try lines.feed(#"{"type":"turn.failed","error":{"message":"You've hit your usage limit"}}"#) }
    }

    @Test @MainActor func statusReading() {
        let plan = #"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#
        let out = #"{"loggedIn":false}"#

        let connected = ClaudeProvider.reading(status: plan, path: "/x")
        let signedOut = ClaudeProvider.reading(status: out, path: "/x")

        #expect(connected == PlanStatus(path: "/x", connected: true, account: "Max plan"))
        #expect(!signedOut.connected)
        #expect(CodexProvider.reading(status: "Logged in using ChatGPT\n", code: 0, path: "/x").connected)
        #expect(!CodexProvider.reading(status: "Not logged in\n", code: 1, path: "/x").connected)
    }

    @Test @MainActor func codexModelsComeFromTheCache() throws {
        let cache = #"{"models":[{"slug":"gpt-a","display_name":"GPT A","visibility":"list","default_reasoning_level":"low","supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"}]},{"slug":"hidden","visibility":"hide"}]}"#

        let models = CodexProvider.models(cache: Data(cache.utf8))
        let fallback = CodexProvider.models(config: "web_search = \"live\"\nmodel = \"gpt-z\"\nmodel_verbosity = \"low\"\n")

        #expect(models == [PlanModel(id: "gpt-a", name: "GPT A", efforts: [.low, .ultra], defaultEffort: .low)])
        #expect(fallback.map(\.id) == ["gpt-z"])
    }

    @Test @MainActor func finderLooksInTheUsualPlaces() {
        let home = "/Users/x"

        let found = CLIFinder.find("claude", home: home) { $0 == "/opt/homebrew/bin/claude" }
        let missing = CLIFinder.find("claude", home: home) { _ in false }

        #expect(found == "/opt/homebrew/bin/claude")
        #expect(missing == nil)
    }

    @Test @MainActor func environmentIsMinimal() {
        setenv("ANTHROPIC_API_KEY", "nope", 1)
        setenv("OPENAI_API_KEY", "nope", 1)
        defer {
            unsetenv("ANTHROPIC_API_KEY")
            unsetenv("OPENAI_API_KEY")
        }

        let environment = CLIFinder.environment

        #expect(environment["ANTHROPIC_API_KEY"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["HOME"] != nil)
        #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    @Test func realToolsAreRefusedUnderTest() async {
        let provider = ClaudeProvider(path: { "/usr/bin/true" })

        let run = await collect(provider.start(ProviderRequest(system: "s", prompt: "p")))

        #expect((run.error as? ProviderError) == .refused("A test run never calls a real model"))
    }

    @Test func runStreamsLinesAndFeedsStdin() async throws {
        let tool = try script("""
        read -r line
        echo '{"type":"system","subtype":"init","model":"m"}'
        echo "$line" > "$(dirname "$0")/stdin"
        echo '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}'
        echo '{"type":"result","subtype":"success","is_error":false,"usage":{}}'
        """)

        let provider = ClaudeProvider(path: { tool.path })
        let run = await collect(provider.start(ProviderRequest(system: "s", prompt: "the prompt")))
        let stdin = try String(contentsOf: tool.deletingLastPathComponent().appendingPathComponent("stdin"), encoding: .utf8)

        #expect(run.error == nil)
        #expect(run.events == [.started(model: "m"), .text("hello"), .finished(ProviderUsage())])
        #expect(stdin.contains("the prompt"))
    }

    @Test func runReportsStderrWhenTheToolDies() async throws {
        let tool = try script("echo 'Not logged in' >&2\nexit 1\n")

        let run = await collect(ClaudeProvider(path: { tool.path }).start(ProviderRequest(system: "s", prompt: "p")))

        #expect((run.error as? ProviderError) == .notSignedIn(.claude))
    }

    @Test func cancelStopsARunningTool() async throws {
        let tool = try script("""
        echo '{"type":"system","subtype":"init","model":"m"}'
        exec sleep 30
        """)
        let session = ClaudeProvider(path: { tool.path }).start(ProviderRequest(system: "s", prompt: "p"))
        let started = Date()

        var seen: [ProviderEvent] = []
        var failure: Error?
        do {
            for try await event in session.events {
                seen.append(event)
                session.cancel()
            }
        } catch {
            failure = error
        }

        #expect(seen == [.started(model: "m")])
        #expect((failure as? ProviderError) == .cancelled)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func steerWritesASecondMessageAndClosesAfterTheLastResult() async throws {
        let tool = try script("""
        while read -r line; do
          echo "$line" >> "$(dirname "$0")/stdin"
          echo '{"type":"result","subtype":"success","is_error":false,"usage":{}}'
          sleep 0.05
        done
        """)
        var request = ProviderRequest(system: "s", prompt: "first")
        request.keepOpen = true
        let session = ClaudeProvider(path: { tool.path }).start(request)

        #expect(session.canSteer)
        #expect(session.send("second"))
        let run = await collect(session)
        let stdin = try String(contentsOf: tool.deletingLastPathComponent().appendingPathComponent("stdin"), encoding: .utf8)

        #expect(run.error == nil)
        #expect(run.events.count == 2)
        #expect(stdin.contains("first"))
        #expect(stdin.contains("second"))
    }

    @Test func fakeProviderFollowsItsScript() async {
        let fake = FakeProvider(script: [.emit(.text("a")), .wait(0.01), .emit(.text("b")), .fail(.planOut("out"))])

        let run = await collect(fake.start(ProviderRequest(system: "s", prompt: "p")))

        #expect(run.events == [.text("a"), .text("b")])
        #expect((run.error as? ProviderError) == .planOut("out"))
        #expect(fake.requests.map(\.prompt) == ["p"])
    }

    @Test func fakeProviderCancels() async {
        let fake = FakeProvider(script: [.emit(.text("a")), .hang])
        let session = fake.start(ProviderRequest(system: "s", prompt: "p"))

        session.cancel()
        let run = await collect(session)

        #expect((run.error as? ProviderError) == .cancelled)
    }

    @MainActor
    @Test func plansChooseTheConnectedPlan() async {
        let plans = Plans()
        let claude = FakeProvider(plan: .claude)
        let codex = FakeProvider(plan: .chatGPT)
        claude.fakeStatus.connected = false
        plans.standIn(claude, for: .claude)
        plans.standIn(codex, for: .chatGPT)
        let prefs = Preferences()
        prefs.aiPlan = nil

        await plans.refresh()

        #expect(plans.defaultPlan(prefs) == .chatGPT)
        #expect(plans.choice(.tasks, prefs) == ModelChoice(plan: .chatGPT, model: "fake", effort: .low))
        #expect(plans.trouble(prefs) == nil)

        codex.fakeStatus.connected = false
        await plans.refresh()

        #expect(plans.defaultPlan(prefs) == nil)
        #expect(plans.trouble(prefs) == "Sign in to Claude Code first. Run claude auth login in Terminal.")
    }
}

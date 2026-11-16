import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PlanRoomTests {
    private var claude: FakeProvider!
    private var codex: FakeProvider!
    private var prefs: Preferences!

    init() async throws {
        keepSettings("ai.plan")
        addTeardownBlock { await self.tearDown() }
        claude = FakeProvider(plan: .claude, echoes: true)
        codex = FakeProvider(plan: .chatGPT, echoes: true)
        Plans.shared.standIn(claude, for: .claude)
        Plans.shared.standIn(codex, for: .chatGPT)
        await Plans.shared.refresh()
        Plans.shared.limits = [:]
        Plans.shared.ranOut = [:]
        prefs = Preferences()
        prefs.aiPlan = .claude
    }

    private func tearDown() async {
        Plans.shared.limits = [:]
        Plans.shared.ranOut = [:]
        Plans.shared.standIn(nil, for: .claude)
        Plans.shared.standIn(nil, for: .chatGPT)
    }

    private func settled(_ conversation: Conversation) async {
        for _ in 0..<600 where conversation.running {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func claudeRateLimitEventIsRead() throws {
        var lines = ClaudeLines()
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","resetsAt":1800000000,"rateLimitType":"five_hour","utilization":0.82}}"#

        let events = try lines.feed(line)

        #expect(events == [.rateLimit(PlanLimit(window: "5-hour", used: 0.82, resets: Date(timeIntervalSince1970: 1_800_000_000), out: false))])
    }

    @Test func claudeFullestWindowWinsAndRejectedIsOut() throws {
        var lines = ClaudeLines()
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1800000000,"rateLimitType":"five_hour","utilization":0.3,"unifiedWindows":{"five_hour":{"utilization":0.3,"resetsAt":1800000000},"seven_day":{"utilization":1.0,"resetsAt":1800090000}}}}"#

        let events = try lines.feed(line)

        #expect(events == [.rateLimit(PlanLimit(window: "weekly", used: 1, resets: Date(timeIntervalSince1970: 1_800_090_000), out: true))])
    }

    @Test func codexRateLimitsAreReadWhereverTheyAppear() throws {
        var lines = CodexLines()
        let top = #"{"type":"turn.completed","rate_limits":{"primary":{"used_percent":40,"window_minutes":300,"resets_at":1800000000},"secondary":{"used_percent":12,"window_minutes":10080,"resets_at":1800090000}}}"#
        let nested = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":100,"window_minutes":300,"resets_at":1800000000},"rate_limit_reached_type":"primary"}}}"#

        let first = try lines.feed(top)
        let second = try lines.feed(nested)

        #expect(first == [.rateLimit(PlanLimit(window: "5-hour", used: 0.4, resets: Date(timeIntervalSince1970: 1_800_000_000), out: false))])
        guard case .rateLimit(let limit)? = second.first else { Issue.record("no limit"); return }
        #expect(limit.out)
    }

    @Test func limitErrorsAreRead() {
        for said in ["usage_limit_reached", "rate_limit_exceeded", "insufficient_quota", "You've hit your limit"] {
            guard case .planOut = ProviderError.reading(said, plan: .chatGPT) else { Issue.record("\(said)"); return }
        }
    }

    @Test func timeoutsLeaveTimeToAnswerAQuestion() {
        let request = ProviderRequest(system: "", prompt: "", tools: .mcp(MCPLaunch(name: "broadway", command: "/x", arguments: [])))
        let codexArguments = CodexProvider.arguments(for: request)

        #expect(ClaudeProvider.quiet["MCP_TOOL_TIMEOUT"] == "1800000")
        #expect(codexArguments.contains("mcp_servers.broadway.tool_timeout_sec=1800"))
    }

    @Test func aBareEventKeepsTheMeasuredUsage() {
        let measured = PlanLimit(window: "5-hour", used: 0.6, resets: Date(timeIntervalSince1970: 1_800_000_000))
        Plans.shared.note(measured, on: .claude)

        Plans.shared.note(PlanLimit(window: "current"), on: .claude)

        #expect(Plans.shared.limits[.claude] == measured)
    }

    @Test func roomComesBackAtReset() {
        let now = Date()
        Plans.shared.note(PlanLimit(window: "5-hour", used: 1, resets: now.addingTimeInterval(60), out: true), on: .claude, at: now)

        #expect(!Plans.shared.hasRoom(.claude, at: now))
        #expect(Plans.shared.hasRoom(.claude, at: now.addingTimeInterval(61)))
    }

    @Test func withoutAResetTimeRoomComesBackAfterAnHour() {
        let now = Date()
        Plans.shared.noteOut(.claude, at: now)

        #expect(!Plans.shared.hasRoom(.claude, at: now.addingTimeInterval(3599)))
        #expect(Plans.shared.hasRoom(.claude, at: now.addingTimeInterval(3601)))
    }

    @Test func aTaskStartsOnTheFirstPlanWithRoom() async throws {
        Plans.shared.noteOut(.claude)

        let task = try #require(AgentTasks.shared.start(prompt: "go", choice: Plans.shared.choice(.tasks, prefs), prefs: prefs, command: "/x/broadway") { _ in })
        await settled(task)

        #expect(task.chat.model?.plan == .chatGPT)
        #expect(claude.requests.isEmpty)
        #expect(codex.requests.count == 1)
        ChatStore.shared.delete(task.chat.id)
    }

    @Test func aRunningTaskMovesOnWithWhatItHadDone() async throws {
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .emit(.text("Found three shops.")),
                         .emit(.toolStarted(id: "1", name: "open", summary: "shop.example")), .emit(.toolFinished(id: "1", failed: false)),
                         .fail(.planOut("You've hit your limit"))]

        let task = try #require(AgentTasks.shared.start(prompt: "compare shops", choice: Plans.shared.choice(.tasks, prefs), prefs: prefs, command: "/x/broadway") { _ in })
        await settled(task)

        let next = try #require(codex.requests.first)
        #expect(next.prompt.contains("Found three shops."))
        #expect(next.prompt.contains("open: shop.example"))
        #expect(next.prompt.contains("compare shops"))
        guard case .mcp = next.tools else { Issue.record("the tools were lost"); return }
        let answer = try #require(task.lastAnswer)
        #expect(answer.failed == nil)
        #expect(answer.steps.contains { $0.name == "Moved to ChatGPT" })
        #expect(answer.model?.plan == .chatGPT)
        #expect(task.chat.model?.plan == .chatGPT)
        #expect(!Plans.shared.hasRoom(.claude))
        ChatStore.shared.delete(task.chat.id)
    }

    @Test func whenBothAreOutTheTaskFailsAndStops() async throws {
        claude.echoes = false
        codex.echoes = false
        claude.script = [.fail(.planOut("out"))]
        codex.script = [.fail(.planOut("out too"))]

        let task = try #require(AgentTasks.shared.start(prompt: "go", choice: Plans.shared.choice(.tasks, prefs), prefs: prefs, command: "/x/broadway") { _ in })
        await settled(task)

        #expect(claude.requests.count == 1)
        #expect(codex.requests.count == 1)
        #expect(task.lastAnswer?.failed == "out too")
        ChatStore.shared.delete(task.chat.id)
    }

    @Test func aFreshLimitEventIsKeptForTheRing() async throws {
        claude.echoes = false
        let limit = PlanLimit(window: "5-hour", used: 0.5, resets: nil, out: false)
        claude.script = [.emit(.rateLimit(limit)), .emit(.finished(ProviderUsage()))]
        let chat = Conversation(chat: Chat(), saved: false, prefs: prefs)

        chat.send("hello")
        await settled(chat)

        #expect(Plans.shared.limits[.claude] == limit)
    }

    @Test func theRingSaysWhatItKnows() {
        let now = Date()
        let limit = PlanLimit(window: "5-hour", used: 0.25, resets: now.addingTimeInterval(600), out: false)

        #expect(PlanUsage.detail(nil, room: true) == "Not measured yet")
        #expect(PlanUsage.detail(limit, room: true, now: now).hasPrefix("25% of the 5-hour limit used · resets"))
        #expect(PlanUsage.detail(limit, room: false, now: now).hasPrefix("Ran out · resets"))
    }
}

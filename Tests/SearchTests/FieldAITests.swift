import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FieldAITests {
    private var browser: Browser!
    private var claude: FakeProvider!
    private var codex: FakeProvider!
    private var mac: FakeProvider?

    init() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        keepSetting(Shared.prefs, \.ai, "ai")
        keepSetting(Shared.prefs, \.aiPlan, "ai.plan")
        keepSetting(Shared.prefs, \.askAndChat, Preferences.askKey)
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.prefs.ai = true
        browser.prefs.askAndChat = true
        browser.prefs.aiPlan = .claude
        browser.prefs.agentsOn = true
        claude = FakeProvider(plan: .claude, echoes: true)
        codex = FakeProvider(plan: .chatGPT, echoes: true)
        codex.fakeStatus.connected = false
        Plans.shared.standIn(claude, for: .claude)
        Plans.shared.standIn(codex, for: .chatGPT)
        await Plans.shared.refresh()
    }

    private func tearDown() async {
        browser.closeLine()
        browser.closeAll()
        browser = nil
        Plans.shared.standIn(nil, for: .claude)
        Plans.shared.standIn(nil, for: .chatGPT)
        Plans.shared.standIn(nil, for: .thisMac)
        await Plans.shared.refresh()
    }

    private func page() async throws -> Tab {
        let tab = browser.open(try #require(URL(string: "about:blank")), foreground: true)
        tab.web.loadHTMLString("<html><head><title>Leaf and Cup</title></head><body><p>Green tea from Uji.</p></body></html>",
                               baseURL: URL(string: "https://tea.example/"))
        for _ in 0..<750 {
            let ready = (try? await tab.web.evaluateJavaScript("document.readyState")) as? String == "complete"
            if !tab.web.isLoading, ready, tab.pageAddress?.host() == "tea.example" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return tab
    }

    private func type(_ text: String) {
        browser.typed = text
        browser.offers = []
        browser.addFieldRows()
    }

    private func answered() async throws -> PageAsk {
        for _ in 0..<400 where browser.ai.line == nil { try await Task.sleep(for: .milliseconds(5)) }
        let line = try #require(browser.ai.line)
        for _ in 0..<600 where line.conversation.running || line.conversation.lastAnswer?.done != true {
            try await Task.sleep(for: .milliseconds(5))
        }
        return line
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags, _ text: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    @Test func theWordsTypedReadAsAQuestionOrAsWork() {
        #expect(FieldIntent.of("what time is it in tokyo") == .question)
        #expect(FieldIntent.of("swiss trains faster than french?") == .question)
        #expect(FieldIntent.of("compare these three laptops") == .task)
        #expect(FieldIntent.of("tokyo") == nil)
        #expect(FieldIntent.of("book") == nil)
        #expect(FieldIntent.of("swift concurrency docs") == nil)
        #expect(FieldIntent.of("https://a.example/what is this") == nil)
    }

    @Test func aQuestionLeadsWithAsk() async throws {
        _ = try await page()

        type("when does the shop open")

        #expect(browser.offers.first?.kind == .action("ask:when does the shop open"))
        #expect(browser.offers.first?.key == "Ask")
        #expect(browser.offers.first?.leads == true)
    }

    @Test func workLeadsWithStartATaskAndAskComesNext() async throws {
        _ = try await page()

        type("compare these three kettles")

        #expect(browser.offers.first?.kind == .action("task:compare these three kettles"))
        #expect(browser.offers.first?.key == "Start a task")
        #expect(browser.offers.dropFirst().first?.kind == .action("ask:compare these three kettles"))
    }

    @Test func tabPutsTheSearchBackOnTop() async throws {
        _ = try await page()
        browser.typed = "compare these three kettles"
        browser.retype()
        #expect(browser.offers.first?.leads == true)

        let taken = browser.fieldTabKey()

        #expect(taken)
        #expect(!browser.offers.contains { $0.leads })
        #expect(browser.offers.contains { $0.kind == .action("task:compare these three kettles") })
    }

    @Test func withAgentsOffThereIsNoTaskRow() async throws {
        _ = try await page()
        browser.prefs.agentsOn = false

        type("compare these three kettles")

        let kinds = browser.offers.map(\.kind)
        #expect(!kinds.contains(.action("task:compare these three kettles")))
        #expect(kinds.contains(.action("ask:compare these three kettles")))
    }

    @Test func withAskAndChatOffThereIsNoAskRowAndNothingIsSent() async throws {
        _ = try await page()
        PageAsk.set(false, browser.prefs, in: [browser])

        type("when does the shop open")
        browser.askFromField("when does the shop open", withPage: true)
        try await Task.sleep(for: .milliseconds(100))

        #expect(!browser.offers.contains { $0.key == "Ask" })
        #expect(browser.ai.line == nil)
        #expect(claude.requests.isEmpty)
    }

    @Test func withThisMacPickedThereIsNoTaskRowAndNothingLeavesTheMac() async throws {
        let made = FakeProvider(plan: .thisMac, echoes: true)
        mac = made
        Plans.shared.standIn(made, for: .thisMac)
        browser.prefs.aiPlan = .thisMac
        await Plans.shared.refresh()
        _ = try await page()

        type("compare these three kettles")
        #expect(!browser.offers.contains { $0.key == "Start a task" })
        browser.runFieldAction("ask:compare these three kettles")
        let line = try await answered()

        #expect(line.agent == .thisMac)
        #expect(made.requests.count == 1)
        #expect(claude.requests.isEmpty)
        #expect(codex.requests.isEmpty)
    }

    @Test func aQuestionFromTheFieldIsAnsweredInTheLineWithThePageAndNoTools() async throws {
        _ = try await page()

        browser.runFieldAction("ask:where is the tea from")
        let line = try await answered()

        #expect(line.fromField)
        #expect(line.onPage)
        #expect(line.conversation.lastAnswer?.text == "Fake answer: where is the tea from")
        let request = try #require(claude.requests.first)
        #expect(request.tools == .none)
        #expect(request.prompt.contains("Green tea from Uji"))
    }

    @Test func aQuestionFromANewTabsFieldSendsNoPage() async throws {
        _ = try await page()

        browser.runFieldAction("ask-new:where is the tea from")
        let line = try await answered()

        #expect(!line.onPage)
        #expect(line.conversation.attachments.isEmpty)
        #expect(claude.requests.first?.prompt.contains("Green tea from Uji") == false)
        #expect(claude.requests.first?.tools == ProviderTools.none)
    }

    @Test func returnCopiesAndCommandRAsksAgain() async throws {
        _ = try await page()
        browser.runFieldAction("ask:where is the tea from")
        let line = try await answered()
        let board = NSPasteboard(name: NSPasteboard.Name("field-ai-\(UUID().uuidString)"))
        PageAsk.board = board
        defer {
            PageAsk.board = .general
            board.releaseGlobally()
        }

        let copied = browser.aiKey(key(36, [], "\r"))
        let text = board.string(forType: .string)
        let again = browser.aiKey(key(15, .command, "r"))
        for _ in 0..<600 where claude.requests.count < 2 || line.conversation.running { try await Task.sleep(for: .milliseconds(5)) }

        #expect(copied)
        #expect(text == "Fake answer: where is the tea from")
        #expect(again)
        #expect(claude.requests.count == 2)
        #expect(line.conversation.chat.messages.count == 2)
    }

    @Test func commandReturnHandsTheQuestionToATaskWithTools() async throws {
        _ = try await page()
        browser.runFieldAction("ask:compare the teas on this page")
        let line = try await answered()

        #expect(browser.aiKey(key(36, .command, "\r")))
        #expect(browser.ai.line == nil)
        browser.startFieldTask("compare the teas on this page", command: "/nowhere/broadway")
        for _ in 0..<600 where claude.requests.count < 2 { try await Task.sleep(for: .milliseconds(5)) }

        #expect(line.conversation.chat.messages.first?.text == "compare the teas on this page")
        #expect(claude.requests.count == 2)
        #expect(claude.requests.first?.tools == ProviderTools.none)
        #expect(claude.requests.last?.tools != ProviderTools.none)
        for id in AgentSessions.shared.live.keys { AgentSessions.shared.clear(id) }
    }

    @Test func aPlainLineLeavesReturnAndCommandRAlone() async throws {
        let tab = try await page()
        await browser.openLine(tab)
        let line = try #require(browser.ai.line)
        line.run("where is the tea from")
        _ = try await answered()

        #expect(!browser.aiKey(key(36, [], "\r")))
        #expect(!browser.aiKey(key(15, .command, "r")))
    }
}

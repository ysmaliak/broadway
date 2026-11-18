import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ChatColumnTests {
    private var claude: FakeProvider!
    private var codex: FakeProvider!
    private var made: [UUID] = []

    init() async throws {
        keepSetting(Shared.prefs, \.aiPlan, "ai.plan")
        keepSetting(Shared.prefs, \.askAndChat, Preferences.askKey)
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        claude = FakeProvider(plan: .claude, echoes: true)
        codex = FakeProvider(plan: .chatGPT, echoes: true)
        codex.fakeStatus.connected = false
        let mac = FakeProvider(plan: .thisMac, echoes: true)
        mac.fakeStatus.connected = false
        Plans.shared.standIn(claude, for: .claude)
        Plans.shared.standIn(codex, for: .chatGPT)
        Plans.shared.standIn(mac, for: .thisMac)
        Plans.shared.ranOut = [:]
        Plans.shared.limits = [:]
        await Plans.shared.refresh()
    }

    private func tearDown() async {
        for plan in Plan.allCases { Plans.shared.standIn(nil, for: plan) }
        Plans.shared.ranOut = [:]
        Plans.shared.limits = [:]
        for id in made { ChatStore.shared.delete(id) }
        #expect(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
    }

    private func page(_ name: String, shy: Bool = false) -> Tab {
        let tab = Tab(shy: shy)
        tab.restore(url: URL(string: "https://\(name).example/")!, title: name)
        return tab
    }

    private func world(shut: Bool = false, tabs: [String] = ["first"]) -> Browser {
        let browser = shut ? Browser(record: WindowRecord(), privateStore: .nonPersistent()) : Browser(record: WindowRecord())
        browser.prefs.askAndChat = true
        browser.prefs.agentsOn = false
        browser.prefs.aiPlan = .claude
        for name in tabs { browser.receive(page(name)) }
        return browser
    }

    private func mac(connected: Bool = true) async -> FakeProvider {
        let fake = FakeProvider(plan: .thisMac, echoes: true)
        fake.fakeStatus.connected = connected
        Plans.shared.standIn(fake, for: .thisMac)
        await Plans.shared.refresh()
        return fake
    }

    private func ask(_ browser: Browser, _ text: String, queue: Bool = false) {
        if !browser.chatOpen, let tab = browser.active { browser.showChat(tab) }
        browser.ai.chatDraft = text
        browser.sendChat(queue: queue)
        if let id = browser.ai.chat?.chat.id, !made.contains(id) { made.append(id) }
    }

    private func settle(_ browser: Browser) async {
        for _ in 0..<600 {
            if browser.ai.chat?.running == false, browser.ai.chat?.queued.isEmpty == true { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("still running")
    }

    private func running(_ browser: Browser) async {
        for _ in 0..<600 {
            if browser.ai.chat?.running == true { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never started")
    }

    private func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    @Test func showChatPutsTheColumnInTheSidePanelsSlot() {
        let browser = world()

        browser.toggleChat()

        #expect(browser.chatOpen)
        #expect(browser.sidePanel == .chat)
        #expect(browser.sidePanelShown)
        browser.toggleChat()
        #expect(!browser.chatOpen)
        #expect(browser.sidePanel == nil)
    }

    @Test func withAskAndChatOffTheColumnNeverOpensAndAnOpenOneCloses() async throws {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .emit(.text("Going")), .hang]
        ask(browser, "Keep going")
        await running(browser)
        let live = try #require(browser.ai.chat)

        PageAsk.set(false, browser.prefs, in: [browser])
        for _ in 0..<400 where live.running { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(!browser.chatOpen)
        #expect(!live.running)
        browser.toggleChat()
        browser.showChats()
        #expect(!browser.chatOpen)
        let show = try #require(Command.all.first { $0.id == "view.chat" })
        let list = try #require(Command.all.first { $0.id == "view.chats" })
        #expect(!FieldCommands.available(show, in: browser))
        #expect(!FieldCommands.available(list, in: browser))
        claude.script = [.emit(.started(model: nil)), .emit(.text("Looking")), .hang]
        browser.prefs.agentsOn = true
        let task = try #require(AgentTasks.shared.start(prompt: "Find a quiet cafe", choice: Plans.shared.defaultChoice(.claude),
                                                        prefs: browser.prefs, command: "/x/broadway") { _ in })
        made.append(task.chat.id)
        for _ in 0..<400 where !task.running { try? await Task.sleep(for: .milliseconds(5)) }

        browser.showTask(task.chat.id)
        #expect(browser.chatOpen)
        #expect(browser.ai.chat === task)
        browser.newChat()
        browser.showChats()
        #expect(browser.ai.chat === task)
        #expect(!browser.ai.chatListing)
        browser.ai.chatDraft = "Only ones open now"
        browser.sendChat()
        for _ in 0..<400 where !task.chat.messages.contains(where: { $0.text == "Only ones open now" }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(task.chat.messages.contains { $0.role == .user && $0.text == "Only ones open now" })
        PageAsk.set(false, browser.prefs, in: [browser])
        #expect(browser.chatOpen)
        #expect(browser.ai.chat === task)
        browser.hideChat()
        #expect(browser.ai.chat == nil)
        AgentTasks.shared.stop(task.chat.id)
        browser.prefs.agentsOn = false
        browser.showTask(task.chat.id)
        #expect(!browser.chatOpen)
        PageAsk.set(true, browser.prefs, in: [browser])
        #expect(FieldCommands.available(show, in: browser))
    }

    @Test func theColumnAndASiteInTheSidePanelTakeTurns() {
        let browser = world()
        browser.prefs.sitesInPanel = true
        browser.toggleChat()

        browser.showSiteInPanel(URL(string: "https://panel.example/")!)

        #expect(!browser.chatOpen)
        #expect(browser.sidePanel != .chat)
        browser.toggleChat()
        #expect(browser.sidePanel == .chat)
        browser.closeSidePanel()
    }

    @Test func aQuestionGetsItsAnswerWithNoTools() async {
        let browser = world()

        ask(browser, "What is this?")
        await settle(browser)

        let turns = browser.ai.chat?.chat.messages ?? []
        #expect(turns.map(\.role) == [.user, .assistant])
        #expect(turns.last?.text == "Fake answer: What is this?")
        #expect(turns.last?.model?.plan == .claude)
        #expect(claude.requests.count == 1)
        #expect(claude.requests.allSatisfy { $0.tools == .none })
        #expect(browser.ai.chatDraft.isEmpty)
    }

    @Test func returnSteersARunningAnswer() async throws {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .emit(.text("Working")), .hang]
        ask(browser, "Tell me about it")
        for _ in 0..<600 where browser.ai.chat?.chat.messages.last?.text != "Working" { try? await Task.sleep(for: .milliseconds(5)) }
        browser.ai.chatFocused = true
        claude.echoes = true

        browser.ai.chatDraft = "Shorter please"
        let taken = browser.chatKey(try key(36, "\r"), [], "\r")
        await settle(browser)

        #expect(taken)
        let asked = browser.ai.chat?.chat.messages.filter { $0.role == .user }.map(\.text)
        #expect(asked == ["Tell me about it", "Shorter please"])
        #expect(claude.requests.count == 2)
        #expect(browser.ai.chat?.chat.messages.last?.text == "Fake answer: Shorter please")
        #expect(claude.requests.allSatisfy { $0.tools == .none })
    }

    @Test func commandReturnQueuesTheNextQuestion() async throws {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .wait(0.3), .emit(.text("First")), .emit(.finished(ProviderUsage()))]
        ask(browser, "One")
        await running(browser)
        browser.ai.chatFocused = true

        browser.ai.chatDraft = "Two"
        let taken = browser.chatKey(try key(36, "\r", .command), .command, "\r")

        #expect(taken)
        #expect(browser.ai.chat?.queued == ["Two"])
        claude.echoes = true
        await settle(browser)
        let asked = browser.ai.chat?.chat.messages.filter { $0.role == .user }.map(\.text)
        #expect(asked == ["One", "Two"])
        #expect(browser.ai.chat?.chat.messages.last?.text == "Fake answer: Two")
    }

    @Test func escapeStopsAnAnswer() async throws {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .emit(.text("Half")), .hang]
        ask(browser, "Go on")
        for _ in 0..<600 where browser.ai.chat?.chat.messages.last?.text != "Half" { try? await Task.sleep(for: .milliseconds(5)) }
        browser.ai.chatFocused = true

        let taken = browser.chatKey(try key(53, "\u{1b}"), [], "\u{1b}")
        await settle(browser)

        #expect(taken)
        #expect(browser.ai.chat?.chat.messages.last?.stopped == true)
    }

    @Test func escapeWhileThePageIsReadStopsBeforeAnythingIsSent() async throws {
        let browser = world()
        ask(browser, "Read this")
        #expect(browser.ai.chat?.running == true)
        browser.ai.chatFocused = true

        #expect(browser.chatKey(try key(53, "\u{1b}"), [], "\u{1b}"))
        await settle(browser)

        #expect(claude.requests.isEmpty)
        #expect(browser.ai.chat?.chat.messages.last?.stopped == true)
    }

    @Test func returnInTheComposerNeverAnswersAnAgentsQuestion() async throws {
        let browser = world()
        browser.toggleChat()
        browser.ai.chatFocused = true
        var question = AgentQuestion(kind: .approval(.send), title: "Send?")
        question.shown = Date().addingTimeInterval(-5)
        let asked = Task { await AgentDesk.shared.ask(question) }
        for _ in 0..<200 where AgentDesk.shared.front == nil { try? await Task.sleep(for: .milliseconds(5)) }

        browser.ai.chatDraft = "Hello"
        let taken = browser.aiKey(try key(36, "\r"))
        await settle(browser)

        #expect(taken)
        #expect(AgentDesk.shared.front?.id == question.id)
        #expect(browser.ai.chat?.chat.messages.first?.text == "Hello")
        AgentDesk.shared.take(question.id, .no)
        _ = await asked.value
        if let id = browser.ai.chat?.chat.id { made.append(id) }
    }

    @Test func theChatFollowsTheFrontTabUntilTheFirstQuestionAndKeepsItAfter() async {
        let browser = world(tabs: ["first", "second"])
        let first = browser.tabs[0], second = browser.tabs[1]
        browser.select(first)
        browser.toggleChat()

        browser.select(second)
        #expect(browser.chatPlace()?.tab == second.id)
        ask(browser, "About this one")
        await settle(browser)
        browser.select(first)

        #expect(browser.chatPlace()?.tab == second.id)
        #expect(browser.chatPlace()?.kept == true)
        #expect(browser.ai.chat?.attachments.map(\.label) == ["second"])
        #expect(browser.ai.chat?.chat.messages.first?.sources == ["second"])
        browser.goToChatPage()
        #expect(browser.activeID == second.id)
    }

    @Test func newChatStartsOverAboutThePageInFront() async {
        let browser = world(tabs: ["first", "second"])
        browser.select(browser.tabs[0])
        ask(browser, "Hi")
        await settle(browser)
        browser.select(browser.tabs[1])

        browser.newChat()

        #expect(browser.ai.chat?.chat.messages.isEmpty == true)
        #expect(browser.chatPlace()?.tab == browser.tabs[1].id)
        #expect(browser.chatPlace()?.kept == false)
    }

    @Test func aPrivateTabWithACloudAgentPickedAsksItNothing() async {
        let browser = world(tabs: [])
        browser.receive(page("hidden", shy: true))

        ask(browser, "Anything?")
        try? await Task.sleep(for: .milliseconds(50))

        #expect(claude.requests.isEmpty)
        #expect(browser.chatAnswerer().refusal == ChatAnswerer.notPrivate)
        #expect(browser.ai.chat?.chat.messages.isEmpty == true)
    }

    @Test func aPrivateTabIsAnsweredOnlyByThisMac() async {
        let here = await mac()
        let browser = world(tabs: [])
        browser.receive(page("hidden", shy: true))

        ask(browser, "Anything?")
        await settle(browser)

        #expect(claude.requests.isEmpty)
        #expect(here.requests.count == 1)
        #expect(browser.ai.chat?.chat.messages.last?.model?.plan == .thisMac)
        #expect(browser.chatAgents() == [.thisMac])
        browser.pickChatAgent(.claude)
        ask(browser, "Again?")
        await settle(browser)
        #expect(claude.requests.isEmpty)
        #expect(here.requests.allSatisfy { !$0.prompt.contains("hidden.example") })
    }

    @Test func aPrivateWindowSaysSoWithNoModelOnThisMac() {
        let browser = world(shut: true)
        browser.toggleChat()

        #expect(browser.chatAnswerer().refusal == "Not available in a private window")
    }

    @Test func aChatInAPrivateWindowIsNeverSaved() async {
        _ = await mac()
        let browser = world(shut: true)

        ask(browser, "Keep this to yourself")
        await settle(browser)

        let id = try? #require(browser.ai.chat?.chat.id)
        #expect(browser.ai.chat?.saved == false)
        #expect(browser.ai.chat?.chat.messages.count == 2)
        #expect(!ChatStore.shared.chats.contains { $0.id == id })
        #expect(claude.requests.isEmpty)
    }

    @Test func withNoCloudAgentThisMacAnswers() async {
        claude.fakeStatus.connected = false
        let here = await mac()
        let browser = world()

        ask(browser, "Who answers?")
        await settle(browser)

        #expect(here.requests.count == 1)
        #expect(claude.requests.isEmpty)
        #expect(browser.chatAnswerer().choice?.plan == .thisMac)
    }

    @Test func thisMacPickedInSettingsNeverSendsThePageToACloudAgent() async {
        codex.fakeStatus.connected = true
        let here = await mac()
        let browser = world()
        browser.prefs.aiPlan = .thisMac
        browser.toggleChat()
        browser.ai.chat?.chat.model = Plans.shared.defaultChoice(.claude)

        browser.pickChatAgent(.chatGPT)
        ask(browser, "Where does this go?")
        await settle(browser)
        ask(browser, "And this?")
        await settle(browser)

        #expect(browser.chatAgents() == [.thisMac])
        #expect(here.requests.count == 2)
        #expect(claude.requests.isEmpty)
        #expect(codex.requests.isEmpty)
    }

    @Test func thisMacPickedButNotThereRefusesRatherThanAskACloudAgent() async {
        let browser = world()
        browser.prefs.aiPlan = .thisMac

        ask(browser, "Anyone?")

        #expect(browser.chatAnswerer().refusal == ChatAnswerer.macOff)
        #expect(browser.chatAgents().isEmpty)
        #expect(browser.ai.chat?.chat.messages.isEmpty == true)
        #expect(claude.requests.isEmpty)
    }

    @Test func aSignedOutPickWithAnotherAgentThereStillSends() async {
        claude.fakeStatus.connected = false
        codex.fakeStatus.connected = true
        await Plans.shared.refresh()
        let browser = world()

        ask(browser, "Who now?")
        await settle(browser)

        #expect(codex.requests.count == 1)
        #expect(browser.ai.chatDraft.isEmpty)
    }

    @Test func withNoAgentAtAllTheComposerTakesNothing() async {
        claude.fakeStatus.connected = false
        await Plans.shared.refresh()
        let browser = world()

        ask(browser, "Hello?")

        #expect(browser.chatAnswerer().refusal == "Install Claude Code or Codex and sign in")
        #expect(browser.ai.chat?.chat.messages.isEmpty == true)
        #expect(browser.ai.chatDraft == "Hello?")
    }

    @Test func anAgentsTabGivesNoPage() async {
        let browser = world()
        browser.active?.agent = true

        ask(browser, "What is here?")
        await settle(browser)

        #expect(browser.chatPlace()?.agentTab == true)
        #expect(browser.ai.chat?.attachments.isEmpty == true)
        #expect(claude.requests.count == 1)
        #expect(claude.requests.allSatisfy { !$0.prompt.contains("first.example") && $0.tools == .none })
        browser.active?.agent = false
    }

    @Test func theAgentPickedInTheHeadIsForThisChatOnly() async {
        codex.fakeStatus.connected = true
        await Plans.shared.refresh()
        let browser = world()
        browser.toggleChat()

        browser.pickChatAgent(.chatGPT)
        ask(browser, "Which one?")
        await settle(browser)

        #expect(codex.requests.count == 1)
        #expect(claude.requests.isEmpty)
        #expect(browser.prefs.aiPlan == .claude)
        browser.newChat()
        #expect(browser.chatAnswerer().choice?.plan == .claude)
    }

    @Test func aFinishedAnswerSaysItMayBeWrongAndNamesTheAgent() async {
        let browser = world()
        ask(browser, "Say something")
        await settle(browser)

        let turn = ChatAnswerTurn(key: "a", browser: browser)
        turn.set(try! #require(browser.ai.chat?.chat.messages.last), status: nil, last: true)

        let labels = turn.subviews.compactMap { $0 as? ChatAnswerFoot }.flatMap { $0.subviews.compactMap { ($0 as? KitLabel)?.text } }
        #expect(labels == ["AI, may be wrong · Claude Code"])
        #expect(turn.accessibilityLabel()?.hasPrefix("Answer: Fake answer") == true)
    }

    private func trouble(_ error: ProviderError) async -> ChatTrouble? {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .fail(error)]
        ask(browser, "Will it work?")
        await settle(browser)
        guard let last = browser.ai.chat?.chat.messages.last, last.failed != nil else { return nil }
        return ChatTrouble(last, offline: false)
    }

    @Test func signedOutSaysHowToSignIn() async {
        let said = await trouble(.notSignedIn(.claude))
        #expect(said?.kind == .signedOut)
        #expect(said?.title == "Claude Code is signed out")
        #expect(said?.detail == "Run claude auth login in Terminal, then try again")
    }

    @Test func notInstalledSaysSo() async {
        let said = await trouble(.notInstalled(.claude))
        #expect(said?.kind == .notInstalled)
    }

    @Test func aUsedUpAllowanceSaysWhenItComesBack() async {
        let back = Date().addingTimeInterval(3600)
        Plans.shared.limits[.claude] = PlanLimit(window: "5h", used: 1, resets: back, out: true)
        let said = await trouble(.planOut("You've hit your usage limit"))
        #expect(said?.kind == .usedUp)
        #expect(said?.detail.contains(back.formatted(date: .omitted, time: .shortened)) == true)
    }

    @Test func offlineSaysToConnect() async {
        let said = await trouble(.failed("The Internet connection appears to be offline."))
        #expect(said?.kind == .offline)
        #expect(said?.title == "This Mac is offline")
    }

    @Test func anythingElseSaysWhatTheAgentSaid() async {
        let said = await trouble(.failed("Something unexpected went sideways"))
        #expect(said?.kind == .other)
        #expect(said?.detail == "Something unexpected went sideways")
    }

    @Test func tryAgainAsksTheLastQuestionAgain() async {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .fail(.failed("Something unexpected went sideways"))]
        ask(browser, "Again please")
        await settle(browser)
        claude.echoes = true

        browser.retryChat()
        await settle(browser)

        let turns = browser.ai.chat?.chat.messages ?? []
        #expect(turns.count == 2)
        #expect(turns.last?.failed == nil)
        #expect(turns.last?.text == "Fake answer: Again please")
    }

    @Test func troubleWordsKeepToTheCopyRules() {
        let all: [ChatTrouble] = [
            ChatTrouble(failed: "Claude Code isn't installed on this Mac", plan: .claude, ranOut: false, resets: nil, offline: false),
            ChatTrouble(failed: "not logged in", plan: .chatGPT, ranOut: false, resets: nil, offline: false),
            ChatTrouble(failed: "", plan: .claude, ranOut: true, resets: Date().addingTimeInterval(7200), offline: false),
            ChatTrouble(failed: "", plan: .claude, ranOut: true, resets: nil, offline: false),
            ChatTrouble(failed: "boom; crash", plan: .claude, ranOut: false, resets: nil, offline: true),
            ChatTrouble(failed: "boom; crash and burn", plan: .claude, ranOut: false, resets: nil, offline: false),
        ]
        for trouble in all {
            for words in [trouble.title, trouble.detail] {
                #expect(!words.contains(";"), "\(words)")
                let sentences = words.components(separatedBy: ". ").count
                #expect(sentences > 1 || !words.hasSuffix("."), "\(words)")
            }
        }
    }

    @Test func aTasksConversationShowsInTheColumnAndTakesNoQuestion() async {
        let browser = world()
        browser.prefs.agentsOn = true
        var task = Chat()
        task.kind = .task
        task.title = "Find a flight"
        task.messages = [ChatMessage(role: .user, text: "Find a flight"),
                         ChatMessage(role: .assistant, text: "Done", steps: [ChatStep(id: "1", name: "snapshot", summary: "Reading", done: true)])]
        ChatStore.shared.save(task)
        made.append(task.id)

        browser.showTask(task.id)

        #expect(browser.chatOpen)
        #expect(browser.ai.chat?.chat.kind == .task)
        #expect(browser.ai.chat?.chat.messages.count == 2)
        #expect(browser.chatAnswerer().refusal == ChatAnswerer.taskDone)
        browser.ai.chatDraft = "Do more"
        browser.sendChat()
        #expect(browser.ai.chat?.chat.messages.count == 2)
        #expect(claude.requests.isEmpty)
    }

    @Test func answersKeepListsCodeAndOnlyWebLinks() {
        let blocks = ChatText.blocks("Intro [site](https://a.example/x) and [bad](file:///etc/hosts)\n\n- one\n- two\n\n```\nlet a = 1\n```")

        #expect(blocks.count == 2)
        guard case .words(let words) = blocks[0], case .code(let code) = blocks[1] else { Issue.record("blocks"); return }
        #expect(code == "let a = 1")
        #expect(words.string.contains("•\tone"))
        var links: [URL] = []
        words.enumerateAttribute(.link, in: NSRange(location: 0, length: words.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links == [URL(string: "https://a.example/x")!])
        #expect(words.string.contains("[bad](file:///etc/hosts)"))
    }

    @Test func aLongWordThatCannotBreakStaysInsideTheColumn() {
        let view = ChatTextView(selectable: true)
        view.set(ChatText.paragraphs([String(repeating: "x", count: 400)]))

        let height = view.height(for: 240)
        let used = view.layoutManager!.usedRect(for: view.textContainer!)

        #expect(height > 40)
        #expect(used.width <= 240)
    }
}

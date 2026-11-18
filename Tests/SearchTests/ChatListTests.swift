import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ChatListTests {
    private var claude: FakeProvider!
    private var made: [UUID] = []

    init() async throws {
        keepSetting(Shared.prefs, \.aiPlan, "ai.plan")
        keepSetting(Shared.prefs, \.askAndChat, Preferences.askKey)
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        claude = FakeProvider(plan: .claude, echoes: true)
        let codex = FakeProvider(plan: .chatGPT, echoes: true)
        codex.fakeStatus.connected = false
        let mac = FakeProvider(plan: .thisMac, echoes: true)
        Plans.shared.standIn(claude, for: .claude)
        Plans.shared.standIn(codex, for: .chatGPT)
        Plans.shared.standIn(mac, for: .thisMac)
        await Plans.shared.refresh()
        ChatStore.shared.load()
    }

    private func tearDown() async {
        for plan in Plan.allCases { Plans.shared.standIn(nil, for: plan) }
        for id in made { ChatStore.shared.delete(id) }
        #expect(NSApp.windows.allSatisfy { !$0.isVisible }, "a window was shown")
    }

    private func world(shut: Bool = false) -> Browser {
        let browser = shut ? Browser(record: WindowRecord(), privateStore: .nonPersistent()) : Browser(record: WindowRecord())
        browser.prefs.askAndChat = true
        browser.prefs.agentsOn = false
        browser.prefs.aiPlan = .claude
        let tab = Tab()
        tab.restore(url: URL(string: "https://list.example/")!, title: "List page")
        browser.receive(tab)
        return browser
    }

    private func kept(_ title: String, kind: ChatKind = .chat, ago: TimeInterval = 0, pinned: Bool = false,
                      archived: Bool = false, project: UUID? = nil) -> Chat {
        var chat = Chat()
        chat.title = title
        chat.kind = kind
        chat.updated = Date().addingTimeInterval(-ago)
        chat.pinned = pinned
        chat.archived = archived
        chat.project = project
        var answer = ChatMessage(role: .assistant, text: "An answer")
        answer.model = ModelChoice(plan: .claude, model: "fake", effort: nil)
        chat.messages = [ChatMessage(role: .user, text: title), answer]
        ChatStore.shared.save(chat)
        made.append(chat.id)
        return chat
    }

    private func ours(_ browser: Browser) -> [String] {
        browser.chatList.filter { made.contains($0.id) }.map(\.title)
    }

    private func ask(_ browser: Browser, _ text: String) async {
        if !browser.chatOpen, let tab = browser.active { browser.showChat(tab) }
        browser.ai.chatDraft = text
        browser.sendChat()
        if let id = browser.ai.chat?.chat.id { made.append(id) }
        for _ in 0..<600 where browser.ai.chat?.running != false { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func pinnedChatsComeFirstThenNewest() {
        let browser = world()
        _ = kept("Older", ago: 7200)
        _ = kept("Newer", ago: 60)
        _ = kept("Pinned and old", ago: 90000, pinned: true)

        #expect(ours(browser) == ["Pinned and old", "Newer", "Older"])
    }

    @Test func tasksAndRoutinesAreNotListed() {
        let browser = world()
        _ = kept("A chat")
        _ = kept("A task", kind: .task)
        _ = kept("A routine", kind: .routine)

        #expect(ours(browser) == ["A chat"])
    }

    @Test func chatsKeptBeforeShowAgainEvenArchivedOrInAProject() {
        let browser = world()
        _ = kept("Archived long ago", ago: 86400 * 40, archived: true)
        _ = kept("In a project", ago: 86400 * 20, project: UUID())

        #expect(ours(browser) == ["In a project", "Archived long ago"])
    }

    @Test func aChatsTitleIsItsFirstQuestionShortened() async {
        let browser = world()
        let long = "How does this page explain the way the bridge was built across the river in the old town?"

        await ask(browser, long)

        let title = browser.ai.chat?.chat.title ?? ""
        #expect(title.count == 60)
        #expect(title.hasSuffix("…"))
        #expect(long.hasPrefix(String(title.dropLast())))
        #expect(ours(browser).first == title)
    }

    @Test func renameKeepsTheNewNameAfterTheNextAnswer() async {
        let browser = world()
        await ask(browser, "First question")
        let id = try! #require(browser.ai.chat?.chat.id)

        browser.renameChat(id, to: "  My name  ")
        await ask(browser, "Second question")

        #expect(ChatStore.shared.chats.first { $0.id == id }?.title == "My name")
        #expect(browser.ai.chat?.chat.title == "My name")
    }

    @Test func pinAndUnpin() {
        let browser = world()
        let chat = kept("To pin", ago: 9000)
        _ = kept("Fresh")

        browser.pinChat(chat.id)
        #expect(ours(browser).first == "To pin")
        browser.pinChat(chat.id)
        #expect(ours(browser).first == "Fresh")
    }

    @Test func deleteTakesItAwayAtOnceAndUndoBringsItBack() throws {
        let browser = world()
        let chat = kept("To delete")

        browser.deleteChat(chat.id)

        #expect(!ours(browser).contains("To delete"))
        #expect(!FileManager.default.fileExists(atPath: ChatStore.shared.file(chat.id).path))
        #expect(browser.announcement == "Chat deleted")
        browser.undoAnnounced()
        #expect(ours(browser).contains("To delete"))
    }

    @Test func deletingARunningChatStopsItAndALateAnswerNeverBringsItBack() async {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .emit(.text("Working")), .wait(0.2), .emit(.text(" on")), .hang]
        browser.showChat(try! #require(browser.active))
        browser.ai.chatDraft = "Long one"
        browser.sendChat()
        let id = try! #require(browser.ai.chat?.chat.id)
        made.append(id)
        for _ in 0..<600 where browser.ai.chat?.chat.messages.last?.text.isEmpty != false { try? await Task.sleep(for: .milliseconds(5)) }
        ChatStore.shared.save(try! #require(browser.ai.chat?.chat))

        browser.deleteChat(id)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(!ChatStore.shared.chats.contains { $0.id == id })
        #expect(browser.ai.chat?.chat.id != id)
    }

    @Test func openingAChatCarriesItOn() async {
        let browser = world()
        let chat = kept("Earlier talk", ago: 600)
        browser.showChats()
        #expect(browser.ai.chatListing)

        browser.open(chat: chat)
        await ask(browser, "And then?")

        #expect(!browser.ai.chatListing)
        #expect(browser.ai.chat?.chat.id == chat.id)
        #expect(browser.ai.chat?.chat.messages.map(\.text).prefix(3) == ["Earlier talk", "An answer", "And then?"])
        #expect(ChatStore.shared.chats.first { $0.id == chat.id }?.messages.count == 4)
        #expect(claude.requests.last?.tools == ProviderTools.none)
    }

    @Test func openingAChatStillAnsweringBehindTakesUpThatSameAnswer() async throws {
        let browser = world()
        claude.echoes = false
        claude.script = [.emit(.started(model: nil)), .emit(.text("Slow")), .wait(0.4), .emit(.text(" answer")), .emit(.finished(ProviderUsage()))]
        browser.showChat(try #require(browser.active))
        browser.ai.chatDraft = "Take your time"
        browser.sendChat()
        let first = try #require(browser.ai.chat)
        made.append(first.chat.id)
        for _ in 0..<600 where first.chat.messages.last?.text.isEmpty != false { try? await Task.sleep(for: .milliseconds(5)) }

        browser.newChat()
        browser.open(chat: first.chat)

        #expect(browser.ai.chat === first)
        for _ in 0..<600 where first.running { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(ChatStore.shared.chats.first { $0.id == first.chat.id }?.messages.last?.text == "Slow answer")
    }

    @Test func aChatInAPrivateWindowIsNeverListed() async {
        let browser = world(shut: true)

        await ask(browser, "Quiet question")

        #expect(browser.ai.chat?.chat.messages.count == 2)
        #expect(!ChatStore.shared.chats.contains { $0.title == "Quiet question" })
    }

    @Test func anEmptyListSaysSo() {
        let browser = world()
        let list = ChatListView(browser: browser)
        list.refresh()

        let shown = list.subviews.compactMap { $0 as? KitLabel }.filter { !$0.isHidden }.map(\.text)
        #expect(browser.chatList.isEmpty ? shown == ["No chats yet"] : shown.isEmpty)
    }

    @Test func aRowsMenuOffersRenamePinAndDelete() {
        let browser = world()
        let row = ChatListRow(chat: kept("Menu chat"), browser: browser)

        #expect(row.menu().items.filter { !$0.isSeparatorItem }.map(\.title) == ["Rename…", "Pin", "Delete"])
    }

    @Test func whenSaysTodayYesterdayOrTheDay() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!

        #expect(ChatWhen.said(now, now: now) == now.formatted(date: .omitted, time: .shortened))
        #expect(ChatWhen.said(yesterday, now: now) == "Yesterday")
    }
}

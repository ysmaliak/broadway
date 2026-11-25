import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class AgentFindsYouTests {
    private var browser: Browser!
    private var socket: AgentSocket!
    private var server: LocalPageServer!
    private var made: [UUID] = []
    private var looking = false
    private let told: ((AgentQuestion) -> Void)?
    private let early = AgentLooking.early
    private let seen = AgentLooking.looking

    init() throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        told = AgentDesk.shared.told
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        socket = AgentSocket()
        socket.box.browser = browser
        browser.prefs.agentMode = .auto
        browser.prefs.agentsOn = true
        AgentSites.shared.reset()
        AgentAskBook.shared.forget()
        AgentHeld.shared.reset()
        AgentLooking.early = 0.4
        AgentLooking.looking = { [unowned self] in looking }
        AgentDesk.shared.told = { AgentNotice.tell($0) }
        let message = "<!doctype html><title>Message</title><h1>Message</h1><button onclick='window.sentIt=true'>Send</button>"
        let login = "<!doctype html><title>Sign in</title><form action='/home'><input name=user><input type=password name=pass></form>"
        let code = "<!doctype html><title>Code</title><form action='/home'><input autocomplete='one-time-code' name=code></form>"
        let home = "<!doctype html><title>Home</title><h1>Signed in</h1>"
        server = try LocalPageServer(["/message": .init(type: "text/html", body: message), "/login": .init(type: "text/html", body: login),
                                      "/code": .init(type: "text/html", body: code), "/home": .init(type: "text/html", body: home)])
    }

    private func tearDown() {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
        AgentHeld.shared.reset()
        AgentAskBook.shared.forget()
        AgentWorkTabs.forget()
        AgentSites.shared.reset()
        AgentLooking.early = early
        AgentLooking.looking = seen
        AgentDesk.shared.told = told
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func session(_ name: String = "Claude Code", workdir: String = "/Users/me/Developer/garden", key: String = UUID().uuidString) -> UUID {
        let link = AgentLinks.shared.join(.named(key), name: name, wish: AgentWish(workdir: workdir))
        TaskLedger.shared.open(link.id, title: name)
        AgentLinks.shared.setPatience(link.id, 30)
        made.append(link.id)
        return link.id
    }

    private func call(_ name: String, _ arguments: [String: Any] = [:], _ link: UUID) async -> ToolOutcome {
        await socket.session(name, arguments, task: link, browser: browser).outcome
    }

    private func open(_ link: UUID, _ path: String = "/message") async -> (tab: Tab, id: String) {
        let said = await call("open", ["url": "http://127.0.0.1:\(server.port)\(path)"], link)
        let id = ToolReply.data(said)["id"] as? String ?? ""
        _ = await call("wait", ["tab": id], link)
        let tab = socket.box.find(["tab": id])!.tab
        return (tab, id)
    }

    private func question(_ link: UUID) async -> AgentQuestion? {
        for _ in 0..<600 {
            if let found = AgentDesk.shared.pending.first(where: { $0.task == link }) { return found }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func sent(_ tab: Tab) async -> Bool {
        (try? await tab.web.evaluateJavaScript("window.sentIt === true")) as? Bool ?? false
    }

    private func sendRef(_ id: String, _ link: UUID) async throws -> String {
        let shot = await call("snapshot", ["tab": id], link)
        let line = try #require(shot.plain?.split(separator: "\n").first { $0.contains("\"Send\"") })
        return String(line.split(separator: " ")[0])
    }

    private func notices(_ title: String) -> Int {
        SiteNotifications.shared.recorded.filter { $0["title"] == title && $0["kind"] == "agent" }.count
    }

    private func go(_ tab: Tab, _ path: String) async {
        _ = try? await tab.web.evaluateJavaScript("location.href = '\(path)'")
        for _ in 0..<400 {
            try? await Task.sleep(for: .milliseconds(10))
            if tab.pageAddress?.path == path, !tab.loading { return }
        }
    }

    @Test func awayFromBroadwayAYesAnswersEarlyAndTheSameCommandWaitsForTheSameQuestion() async throws {
        let link = session()
        let (tab, id) = await open(link)
        let ref = try await sendRef(id, link)
        let before = notices("Claude Code in garden needs you")

        let started = Date()
        let first = await call("click", ["tab": id, "ref": ref], link)
        let asked = try #require(AgentDesk.shared.pending.first { $0.task == link })
        let again = Task { await self.call("click", ["tab": id, "ref": ref], link) }
        try await Task.sleep(for: .seconds(1))
        let up = AgentDesk.shared.pending.filter { $0.task == link }.count
        AgentDesk.shared.take(asked.id, .yes)
        let second = await again.value

        #expect(first.code == "needs_you")
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(first.text?.contains("Send on") == true)
        #expect(first.text?.contains("They are away from Broadway") == true)
        #expect((first.data?["question"] as? [String: Any])?["away"] as? Bool == true)
        #expect(first.hint == ToolReply.awayHint)
        #expect(up == 1)
        #expect(!second.failed)
        #expect(await sent(tab))
        #expect(notices("Claude Code in garden needs you") == before + 1)
    }

    @Test func awayAYesGivenWhileNoCommandWaitsLetsTheNextTryThrough() async throws {
        let link = session()
        let (tab, id) = await open(link)
        let ref = try await sendRef(id, link)

        let first = await call("click", ["tab": id, "ref": ref], link)
        let asked = try #require(AgentDesk.shared.pending.first { $0.task == link })
        AgentDesk.shared.take(asked.id, .yes)
        try await Task.sleep(for: .milliseconds(200))
        let second = await call("click", ["tab": id, "ref": ref], link)

        #expect(first.code == "needs_you")
        #expect(!second.failed)
        #expect(await sent(tab))
        #expect(AgentDesk.shared.pending.filter { $0.task == link }.isEmpty)
    }

    @Test func whileThePersonSeesTheCardTheWaitStaysAsItIs() async throws {
        let link = session()
        let (tab, id) = await open(link)
        let ref = try await sendRef(id, link)
        looking = true
        let before = notices("Claude Code in garden needs you")

        let running = Task { await self.call("click", ["tab": id, "ref": ref], link) }
        let asked = try #require(await question(link))
        try await Task.sleep(for: .seconds(1.2))
        AgentDesk.shared.take(asked.id, .yes)
        let said = await running.value

        #expect(!said.failed)
        #expect(await sent(tab))
        #expect(notices("Claude Code in garden needs you") == before)
    }

    @Test func overSSHTheWaitStaysAsItIsWhileThePersonIsAway() async throws {
        let link = session("SSH from 192.0.2.41", key: "ssh:192.0.2.41")
        let (tab, id) = await open(link)
        let ref = try await sendRef(id, link)

        let running = Task { await self.call("click", ["tab": id, "ref": ref], link) }
        let asked = try #require(await question(link))
        try await Task.sleep(for: .seconds(1.2))
        let still = AgentDesk.shared.pending.contains { $0.id == asked.id }
        AgentDesk.shared.take(asked.id, .yes)
        let said = await running.value

        #expect(still)
        #expect(!said.failed)
        #expect(await sent(tab))
    }

    @Test func awayAHandOverStaysUpAndTheSameHandOverWaitsForIt() async throws {
        let link = session()
        let (tab, id) = await open(link)
        let before = notices("Claude Code in garden needs you")

        let first = await call("handoff", ["tab": id, "reason": "Solve the captcha"], link)
        let asked = try #require(AgentDesk.shared.pending.first { $0.task == link })
        let mood = tab.agentMood
        let again = Task { await self.call("handoff", ["tab": id, "reason": "Solve the captcha"], link) }
        try await Task.sleep(for: .seconds(1))
        let up = AgentDesk.shared.pending.filter { $0.task == link }.count
        AgentDesk.shared.take(asked.id, .picked(0))
        let second = await again.value

        #expect(first.code == "needs_you")
        #expect(first.text?.contains("Solve the captcha") == true)
        #expect(first.text?.contains("They are away from Broadway") == true)
        #expect(mood == .waving)
        #expect(up == 1)
        #expect(!second.failed)
        #expect((second.data?["message"] as? String)?.hasPrefix("The person gave the tab back") == true)
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect(notices("Claude Code in garden needs you") == before + 1)
    }

    @Test func aHandOverDoneWhileNoCommandWaitsIsKeptForTheNextTry() async throws {
        let link = session()
        let (_, id) = await open(link)

        let first = await call("handoff", ["tab": id, "reason": "Type the code"], link)
        let asked = try #require(AgentDesk.shared.pending.first { $0.task == link })
        AgentDesk.shared.take(asked.id, .picked(0))
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        let second = await call("handoff", ["tab": id, "reason": "Type the code"], link)

        #expect(first.code == "needs_you")
        #expect(!second.failed)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func awayAQuestionStaysUpAndOnlyTheSameQuestionWaitsForIt() async throws {
        let link = session()
        let asking: [String: Any] = ["question": "Which account?", "choices": ["Work", "Personal"]]

        let first = await call("ask", asking, link)
        let asked = try #require(AgentDesk.shared.pending.first { $0.task == link })
        let other = await call("ask", ["question": "Which day?", "choices": ["Monday", "Friday"]], link)
        let again = Task { await self.call("ask", asking, link) }
        try await Task.sleep(for: .seconds(1))
        AgentDesk.shared.take(asked.id, .picked(1))
        let second = await again.value

        #expect(first.code == "needs_you")
        #expect(first.text?.contains("Which account?") == true)
        #expect(other.code == "question_open")
        #expect(!second.failed)
        #expect(second.data?["picked"] as? String == "Personal")
    }

    @Test func theDockBadgeCountsTheQuestionsWaiting() async throws {
        var one = AgentQuestion(kind: .approval(.send), title: "Send on shop.example?")
        one.task = UUID()
        var two = AgentQuestion(kind: .approval(.pay), title: "Pay on shop.example?")
        two.task = UUID()

        let first = Task { await AgentDesk.shared.ask(one) }
        let second = Task { await AgentDesk.shared.ask(two) }
        for _ in 0..<200 where AgentDesk.shared.pending.count < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        let both = AgentBadge.shown
        AgentDesk.shared.take(one.id, .no)
        let left = AgentBadge.shown
        AgentDesk.shared.take(two.id, .no)
        _ = await (first.value, second.value)

        #expect(both == "2")
        #expect(left == "1")
        #expect(AgentBadge.shown == nil)
    }

    @Test func theNoticeNamesTheAgentAndFolderAndIsNotSentWhileThePersonLooks() throws {
        let link = session()
        var question = AgentQuestion(kind: .approval(.send), title: "Send on shop.example?")
        question.task = link
        question.site = "shop.example"
        let before = SiteNotifications.shared.recorded.count

        looking = true
        AgentNotice.tell(question)
        let whileLooking = SiteNotifications.shared.recorded.count
        looking = false
        AgentNotice.tell(question)
        let sent = try #require(SiteNotifications.shared.recorded.last)

        #expect(whileLooking == before)
        #expect(sent["title"] == "Claude Code in garden needs you")
        #expect(sent["body"] == "Send on shop.example?")
        #expect(sent["kind"] == "agent")
    }

    @Test func aQuestionWhoseAgentEndsIsTakenDownAtOnce() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        let pid = child.processIdentifier
        let started = try #require(AgentProcess.startTime(pid))
        let link = AgentLinks.shared.join(.process(pid: pid, started: started), name: "Claude Code")
        TaskLedger.shared.open(link.id, title: "Claude Code")
        made.append(link.id)
        var question = AgentQuestion(kind: .approval(.send), title: "Send on shop.example?")
        question.task = link.id
        let waiting = Task { await AgentDesk.shared.ask(question) }
        for _ in 0..<200 where AgentDesk.shared.pending.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }

        let killed = Date()
        child.terminate()
        let answer = await waiting.value

        #expect(answer == .dropped)
        #expect(Date().timeIntervalSince(killed) < 3)
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect(AgentLinks.shared.link(link.id)?.live == false)
    }

    @Test func aSignInHandOverEndsByItselfOncePastTheWall() async throws {
        let link = session()
        let (tab, id) = await open(link, "/login")
        looking = true

        let running = Task { await self.call("handoff", ["tab": id, "reason": "Sign in, please"], link) }
        let asked = try #require(await question(link))
        try await Task.sleep(for: .seconds(1))
        await go(tab, "/code")
        try await Task.sleep(for: .seconds(4))
        let stillUp = AgentDesk.shared.pending.contains { $0.id == asked.id }
        await go(tab, "/home")
        let said = await running.value

        #expect(stillUp)
        #expect(!said.failed)
        #expect((said.data?["message"] as? String)?.hasPrefix("The person gave the tab back") == true)
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aHandOverForAnythingElseNeverEndsByItself() async throws {
        let link = session()
        let (tab, id) = await open(link)
        looking = true

        let running = Task { await self.call("handoff", ["tab": id, "reason": "Pick a colour"], link) }
        let asked = try #require(await question(link))
        await go(tab, "/home")
        try await Task.sleep(for: .seconds(4.5))
        let stillUp = AgentDesk.shared.pending.contains { $0.id == asked.id }
        AgentDesk.shared.take(asked.id, .picked(0))
        _ = await running.value

        #expect(stillUp)
    }
}

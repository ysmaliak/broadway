import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentDrivingTests {
    private let task = UUID()

    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!
    private var sends: LocalPageServer?
    private var tab: Tab!
    private var id = ""

    init() async throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><title>Shop</title><button onclick='window.hit=true'>Go on</button>")])
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": "http://127.0.0.1:\(server.port)/page"], task: UUID())
        tab = try #require(browser.tabs.first { !before.contains($0.id) }) as Tab
        id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        sends?.stop()
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func key(_ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code)!
    }

    @Test func takingOverNeedsAnAgentHere() {
        browser.select(browser.tabs[0])

        let onMine = browser.takeOver()
        browser.select(tab)
        let onTheirs = browser.takeOver()
        let twice = browser.takeOver()

        #expect(!onMine)
        #expect(onTheirs)
        #expect(!twice)
        #expect(tab.driving)
    }

    @Test func aFinishedTabHasNoAgentToTakeOverFrom() {
        tab.agentFinished = Date()
        tab.agentActing = nil
        browser.select(tab)

        #expect(!browser.takeOver())
    }

    @Test func takeOverAlsoWorksOnYourTabWhileAnAgentActs() {
        let mine = browser.tabs[0]
        browser.select(mine)
        mine.agentActing = "Clicking"

        browser.takeOver()

        #expect(mine.driving)
        #expect(mine.agentActing == nil)
        mine.driving = false
    }

    @Test func aClickOnThePageTakesOverAndAClickElsewhereDoesNot() {
        browser.select(tab)
        tab.web.frame = NSRect(x: 100, y: 0, width: 400, height: 300)
        let inside = tab.web.convert(NSPoint(x: 10, y: 10), to: nil)
        let outside = tab.web.convert(NSPoint(x: -50, y: 10), to: nil)

        browser.clickTakesOver(in: tab.web.window, at: outside)
        let elsewhere = tab.driving
        browser.clickTakesOver(in: tab.web.window, at: inside)

        #expect(!elsewhere)
        #expect(tab.driving)
    }

    @Test func commandReturnHandsBackOnlyWhileDriving() {
        browser.select(tab)

        let idle = browser.drivingKey(key(36, .command))
        browser.takeOver()
        let plain = browser.drivingKey(key(36, []))
        let held = tab.driving
        let back = browser.drivingKey(key(36, .command)) || browser.deskKey(key(36, .command))

        #expect(!idle)
        #expect(!plain)
        #expect(held)
        #expect(back)
        #expect(!tab.driving)
    }

    @Test func theCommandIsListedWithItsKey() {
        let command = Command.named("agent.takeOver")

        #expect(command?.defaultKey == KeyCombo("."))
    }

    @Test func aToolWaitsWhileDrivingAndDoesNotActOnAStaleView() async {
        browser.select(tab)
        let shot = await box.call("snapshot", ["tab": id], task: task).text ?? ""
        let ref = shot.split(separator: "\n").first { $0.contains("Go on") }.map { String($0.split(separator: " ")[0]) } ?? ""
        browser.takeOver()

        let call = Task { await box.call("click", ["tab": id, "ref": ref], task: task) }
        try? await Task.sleep(for: .milliseconds(120))
        browser.handBack()
        let said = await call.value
        let look = await box.call("snapshot", ["tab": id], task: task)
        let hit = try? await tab.web.evaluateJavaScript("window.hit === true")

        #expect(said.failed)
        #expect(said.text?.contains("Look at it again") == true)
        #expect(!look.failed)
        #expect(!tab.handedBack)
        #expect((hit as? Bool) == false)
    }

    private func sendPage() async throws -> (tab: Tab, id: String, ref: String) {
        let other = try LocalPageServer(["/send": .init(type: "text/html", body: "<!doctype html><title>Mail</title><button onclick='window.hit=true'>Send message</button>")])
        sends = other
        let before = Set(browser.tabs.map(\.id))
        _ = await box.call("open", ["url": "http://127.0.0.1:\(other.port)/send"], task: UUID())
        let tab = try #require(browser.tabs.first { !before.contains($0.id) })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        let shot = await box.call("snapshot", ["tab": id], task: task).text ?? ""
        let line = try #require(shot.split(separator: "\n").first { $0.contains("Send message") })
        return (tab, id, String(line.split(separator: " ")[0]))
    }

    private func question() async throws -> AgentQuestion {
        var asked: AgentQuestion?
        for _ in 0..<400 where asked == nil {
            asked = AgentDesk.shared.front
            try? await Task.sleep(for: .milliseconds(5))
        }
        return try #require(asked)
    }

    @Test func takingOverCancelsACardThatIsWaitingOnThatTab() async throws {
        let page = try await sendPage()
        let call = Task { await box.call("click", ["tab": page.id, "ref": page.ref], task: task) }
        _ = try await question()
        browser.select(page.tab)
        page.tab.agentActing = nil

        let took = browser.takeOver()
        let said = await call.value
        let hit = try await page.tab.web.evaluateJavaScript("window.hit === true") as? Bool

        #expect(took)
        #expect(page.tab.driving)
        #expect(AgentDesk.shared.front == nil)
        #expect(said.failed)
        #expect(hit == false)
    }

    @Test func aYesThatLandsWhileDrivingClicksNothing() async throws {
        let page = try await sendPage()
        let call = Task { await box.call("click", ["tab": page.id, "ref": page.ref], task: task) }
        let asked = try await question()
        page.tab.driving = true

        AgentDesk.shared.take(asked.id, .yes)
        let said = await call.value
        let hit = try await page.tab.web.evaluateJavaScript("window.hit === true") as? Bool
        page.tab.driving = false

        #expect(said.failed)
        #expect(hit == false)
    }

    @Test func handBackNeverAnswersACardOnAnotherTab() async throws {
        let page = try await sendPage()
        browser.select(tab)
        browser.takeOver()
        let call = Task { await box.call("click", ["tab": page.id, "ref": page.ref], task: task) }
        let asked = try await question()
        try await Task.sleep(for: .milliseconds(600))

        let pressed = browser.drivingKey(key(36, .command)) || browser.deskKey(key(36, .command))
        let open = AgentDesk.shared.front?.id
        AgentDesk.shared.take(asked.id, .no)
        _ = await call.value

        #expect(pressed)
        #expect(!tab.driving)
        #expect(open == asked.id)
    }

    @Test func aToolGivesUpIfThePersonKeepsDriving() async {
        box.drivingPatience = .milliseconds(30)
        browser.select(tab)
        browser.takeOver()

        let said = await box.call("text", ["tab": id], task: task)

        #expect(said.failed)
        #expect(said.text?.contains("driving") == true)
        #expect(tab.driving)
    }

    @Test func aToolThatArrivedAfterHandBackReadsNormally() async {
        browser.select(tab)
        browser.takeOver()
        browser.handBack()

        let first = await box.call("text", ["tab": id], task: task)
        let second = await box.call("scroll", ["tab": id], task: task)

        #expect(!first.failed)
        #expect(!second.failed)
    }

    @Test func endingTheTaskClearsDriving() {
        browser.select(tab)
        browser.takeOver()
        let task = tab.agentTask

        AgentBoard.finish(task ?? UUID(), mood: .done)

        #expect(!tab.driving)
    }
}

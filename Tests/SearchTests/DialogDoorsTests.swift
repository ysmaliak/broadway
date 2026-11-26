import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class DialogDoorsTests {
    private var browser: Browser!
    private var server: LocalPageServer!
    private var splitWas = false
    private var tasks: [UUID] = []

    init() throws {
        addTeardownBlock { await self.tearDown() }
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        splitWas = browser.prefs.splitView
        browser.prefs.splitView = true
        browser.prefs.agentMode = .auto
        server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><title>Basket</title><p>Basket</p>")])
    }

    private func tearDown() async {
        for task in tasks { AgentDesk.shared.drop(task: task) }
        browser?.dropQuestions()
        browser?.prefs.splitView = splitWas
        browser?.closeAll()
        browser = nil
        server?.stop()
    }

    private func loaded(_ tab: Tab) async throws {
        for _ in 0..<500 {
            let ready = try? await tab.web.evaluateJavaScript("document.readyState") as? String
            if ready == "complete", tab.web.url?.path == "/page", !tab.loading {
                try await Task.sleep(for: .milliseconds(500))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("the page never loaded")
    }

    private func pane() async throws -> Tab {
        browser.newTab()
        let left = try #require(browser.tabs.last)
        browser.select(left)
        browser.startSplit()
        try #require(browser.activeSplit?.contains(left.id) == true)
        left.go(to: server.url("/page"))
        try await loaded(left)
        return left
    }

    private func paneAsks(_ tab: Tab) async throws -> PaneQuestion {
        let before = browser.paneQuestions.count
        tab.web.evaluateJavaScript("confirm('Leave this page?')") { _, _ in }
        for _ in 0..<300 where browser.paneQuestions.count == before { try await Task.sleep(for: .milliseconds(10)) }
        return try #require(browser.paneQuestions.last)
    }

    private func answeredAtOnce(_ tab: Tab) async throws -> Bool? {
        var said: Bool?
        var came = false
        tab.web.evaluateJavaScript("confirm('Leave this page?')") { result, _ in
            said = result as? Bool
            came = true
        }
        for _ in 0..<200 where !came { try await Task.sleep(for: .milliseconds(10)) }
        return came ? said : nil
    }

    private func card(for tab: Tab) -> PaneLayersView {
        let view = PaneLayersView(browser: browser, tab: tab)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: 500)
        view.show(paired: true, hovered: false, corners: .init(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0), width: 600)
        view.layoutSubtreeIfNeeded()
        return view
    }

    @Test func aPaneCardOffersTheBoxFromThePagesSecondDialogAndTickingItSilencesThePage() async throws {
        let left = try await pane()
        let unfocused = browser.activeID != left.id
        Dialogs.askedInTest = []
        let first = try await paneAsks(left)
        let view = card(for: left)
        let boxedFirst = !view.kitSubviews(of: DialogSilenceBox.self).isEmpty
        browser.answer(first, ok: false)

        let second = try await paneAsks(left)
        view.show(paired: true, hovered: false, corners: .init(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0), width: 600)
        view.layoutSubtreeIfNeeded()
        let box = try #require(view.kitSubviews(of: DialogSilenceBox.self).first)
        let cancel = try #require(view.kitSubviews(of: KitButton.self).first { $0.accessibilityLabel() == "Cancel" })
        box.flip()
        let ticked = box.isOn
        cancel.action?()
        let silencedAtOnce = DialogRuns.silenced(left.web)
        let stillOpen = second.open
        let third = try await answeredAtOnce(left)
        #expect(unfocused)
        #expect(ticked)
        #expect(silencedAtOnce)
        #expect(!stillOpen)

        #expect(!first.offersSilence)
        #expect(!boxedFirst)
        #expect(second.offersSilence)
        #expect(box.accessibilityLabel() == "Don't let this page show more dialogs")
        #expect(box.accessibilityLabel() == Dialogs.silenceWords)
        #expect(!second.open)
        #expect(DialogRuns.silenced(left.web))
        #expect(second.page === left.web)
        #expect(Dialogs.askedInTest.isEmpty)
        #expect(third == false)
        #expect(browser.paneQuestions.isEmpty)
    }

    @Test func aPaneCardAnsweredWithTheBoxLeftClearKeepsThePageHeard() async throws {
        let left = try await pane()
        browser.answer(try await paneAsks(left), ok: true)
        let second = try await paneAsks(left)

        browser.answer(second, ok: true, silence: false)
        let third = try await paneAsks(left)

        #expect(second.offersSilence)
        #expect(!DialogRuns.silenced(left.web))
        #expect(third.open)
        #expect(third.offersSilence)
        browser.answer(third, ok: false)
    }

    private func agentTab(_ task: UUID, box: BrowserToolbox) async throws -> (Tab, String) {
        tasks.append(task)
        _ = await box.call("open", ["url": server.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent && $0.agentTask == task })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func agentAsked(_ tab: Tab, after old: PaneQuestion?) async throws -> PaneQuestion {
        tab.web.evaluateJavaScript("confirm('Delete this item?')") { _, _ in }
        for _ in 0..<300 where tab.agentDialog == nil || tab.agentDialog === old { try await Task.sleep(for: .milliseconds(10)) }
        let asked = try #require(tab.agentDialog)
        try #require(asked !== old)
        return asked
    }

    private func front() async throws -> AgentQuestion {
        for _ in 0..<400 where AgentDesk.shared.front == nil { try await Task.sleep(for: .milliseconds(5)) }
        return try #require(AgentDesk.shared.front)
    }

    @Test func theAgentCardForAPagesSecondDialogCarriesTheBoxAndTickingItSilencesThePage() async throws {
        let box = BrowserToolbox()
        box.browser = browser
        let task = UUID()
        let (tab, id) = try await agentTab(task, box: box)
        let first = try await agentAsked(tab, after: nil)
        let read = await box.call("dialog", ["tab": id], task: task)
        _ = await box.call("dialog", ["tab": id, "action": "dismiss", "id": first.id.uuidString], task: task)

        let second = try await agentAsked(tab, after: first)
        let call = Task { await box.call("dialog", ["tab": id, "action": "accept", "id": second.id.uuidString], task: task) }
        let asked = try await front()
        let view = AgentCardView(browser: browser, desk: .shared)
        view.frame = NSRect(x: 0, y: 0, width: AgentCardView.widest, height: 400)
        view.layoutSubtreeIfNeeded()
        let tick = try #require(view.kitSubviews(of: DialogSilenceBox.self).first)
        tick.flip()
        browser.newTab()
        if let other = browser.tabs.first(where: { $0.id != browser.activeID }) { browser.select(other) }
        view.sync()
        view.layoutSubtreeIfNeeded()
        let redrawn = try #require(view.kitSubviews(of: DialogSilenceBox.self).first)
        AgentDesk.shared.take(asked.id, .no)
        let said = await call.value
        _ = await box.call("dialog", ["tab": id, "action": "dismiss", "id": second.id.uuidString], task: task)
        let third = try await answeredAtOnce(tab)

        #expect(!first.offersSilence)
        #expect(!(read.text ?? "").contains(Dialogs.silenceWords))
        #expect(second.offersSilence)
        #expect(asked.silence != nil)
        #expect(tick.accessibilityLabel() == Dialogs.silenceWords)
        #expect(redrawn !== tick)
        #expect(redrawn.isOn)
        #expect(said.failed)
        #expect(DialogRuns.silenced(tab.web))
        #expect(third == false)
        #expect(tab.agentDialog == nil)
    }

    @Test func theAgentCardForAPagesFirstDialogHasNoBox() async throws {
        let box = BrowserToolbox()
        box.browser = browser
        let task = UUID()
        let (tab, id) = try await agentTab(task, box: box)
        let first = try await agentAsked(tab, after: nil)
        let call = Task { await box.call("dialog", ["tab": id, "action": "accept", "id": first.id.uuidString], task: task) }
        let asked = try await front()
        let view = AgentCardView(browser: browser, desk: .shared)
        view.frame = NSRect(x: 0, y: 0, width: AgentCardView.widest, height: 400)
        view.layoutSubtreeIfNeeded()
        let boxed = !view.kitSubviews(of: DialogSilenceBox.self).isEmpty
        AgentDesk.shared.take(asked.id, .no)
        _ = await call.value
        _ = await box.call("dialog", ["tab": id, "action": "dismiss", "id": first.id.uuidString], task: task)

        #expect(asked.silence == nil)
        #expect(!boxed)
        #expect(!DialogRuns.silenced(tab.web))
    }
}

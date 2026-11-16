import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentDiagnosticsTests {
    private func data(_ outcome: ToolOutcome) throws -> [String: Any] {
        let text = try #require(outcome.text)
        return try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func diagnosticsScrubURLsCredentialsAndAssignments() {
        let text = #"failed HTTPS://alice:private@example.com/api?%74oken=query-secret&page=2#code=fragment-secret Authorization: Basic credential-secret"#
        let assignments = #"{"refresh_token":"refresh-secret","password":"password-secret","apiKey":"key-secret","session":"session-secret","cardNumber":"card-secret"} Bearer bearer-secret"#

        let clean = AgentSecrets.diagnostic(text + "\n" + assignments)

        for secret in ["alice", "private", "query-secret", "fragment-secret", "credential-secret", "refresh-secret", "password-secret", "key-secret", "bearer-secret", "session-secret", "card-secret"] {
            #expect(!clean.contains(secret), "\(clean)")
        }
        #expect(clean.contains("page=2"), "\(clean)")
        #expect(AgentSecrets.diagnosticURL("data:text/plain,sensitive") == "[source hidden]")
    }

    @Test func networkNeverExportsHeadersOrBodiesAndSealedValuesAreScrubbed() throws {
        let log = DevLog()
        var entry = DevEntry(kind: .request)
        entry.url = "https://user:password@example.com/?api_key=key-secret"
        entry.headers = ["Authorization": "header-secret"]
        entry.body = "body-secret"
        entry.message = "token=message-secret"
        entry.method = "POST"
        entry.resourceType = "fetch"
        entry.bytes = 42
        log.add(entry)

        let outcome = AgentDiagnostics.read(log, name: "network", arguments: [:])
        let found = try data(outcome)
        let rows = try #require(found["requests"] as? [[String: Any]])
        let sealed = AgentSecrets.scrub(outcome.text ?? "", sealed: ["example.com"])

        #expect(rows.count == 1)
        #expect((rows[0]["bytes"] as? Int) == 42)
        #expect((rows[0]["failed"] as? Bool) == true)
        #expect(rows[0]["headers"] == nil)
        #expect(rows[0]["body"] == nil)
        for secret in ["header-secret", "body-secret", "message-secret", "key-secret", "user:password"] { #expect(!(outcome.text?.contains(secret) == true)) }
        #expect(!sealed.contains("example.com"))
    }

    @Test func nestedConsoleCredentialsAndEscapedQuotesAreHidden() throws {
        let fixtures = [
            #"{"payload":{"password":"nested-password"},"safe":"visible"}"#,
            #"{"items":[{"apiKey":"nested-key"},{"access_token":"nested-token"}],"safe":"visible"}"#,
            #"prefix {"payload":{"password":"escaped\"password-tail"},"safe":"visible"}"#,
            #"{payload: {password: 'escaped\'password-tail'}, safe: 'visible'}"#,
        ]
        let log = DevLog()
        for fixture in fixtures {
            var entry = DevEntry(kind: .log)
            entry.message = fixture
            log.add(entry)
        }

        let direct = fixtures.map(AgentSecrets.diagnostic)
        let exported = AgentDiagnostics.read(log, name: "console", arguments: [:]).text ?? ""

        for clean in direct + [exported] {
            for secret in ["nested-password", "nested-key", "nested-token", "password-tail"] {
                #expect(!clean.contains(secret), "\(clean)")
            }
            #expect(clean.contains("visible"), "\(clean)")
        }
    }

    @Test func recentBoundsLevelsAndCursorAcrossClear() throws {
        let log = DevLog()
        for index in 0..<405 {
            var entry = DevEntry(kind: index % 2 == 0 ? .error : .log)
            entry.message = "row \(index)"
            log.add(entry)
        }

        let first = try data(AgentDiagnostics.read(log, name: "console", arguments: ["level": "error", "limit": 2]))
        let cursor = try #require(first["cursor"] as? String)
        log.clear()
        log.add(DevEntry(kind: .warning))
        let next = try data(AgentDiagnostics.read(log, name: "console", arguments: ["since": cursor]))
        let empty = try data(AgentDiagnostics.read(log, name: "console", arguments: ["since": next["cursor"]!]))

        let messages = try #require(first["messages"] as? [[String: Any]])
        #expect(messages.map { $0["message"] as? String } == ["row 402", "row 404"])
        #expect((first["truncated"] as? Bool) == true)
        #expect((next["messages"] as? [[String: Any]])?.count == 1)
        #expect((empty["messages"] as? [[String: Any]])?.count == 0)
        #expect(AgentDiagnostics.read(DevLog(), name: "console", arguments: ["since": cursor]).failed)
        #expect(AgentDiagnostics.read(log, name: "console", arguments: ["limit": 101]).failed)
        #expect(AgentDiagnostics.read(log, name: "console", arguments: ["level": "nope"]).failed)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentDiagnosticsGateTests {
    private final class MessageRecorder: NSObject, WKScriptMessageHandler {
        var messages: [WKScriptMessage] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            messages.append(message)
        }
    }

    @Test func lateDiagnosticsFromThePreviousHostAreRejected() async throws {
        try await lateDiagnostics(changingPort: false)
    }

    @Test func lateDiagnosticsFromThePreviousPortAreRejected() async throws {
        try await lateDiagnostics(changingPort: true)
    }

    private func lateDiagnostics(changingPort: Bool) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let box = BrowserToolbox()
        box.browser = browser
        let mode = browser.prefs.agentMode
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><p>Diagnostics</p>")])
        let destination = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><p>Destination</p>")])
        let host = changingPort ? "127.0.0.1" : "localhost"
        let destinationURL = "http://\(host):\(destination.port)"
        let task = UUID()
        defer {
            browser.prefs.agentMode = mode
            AgentDesk.shared.drop(task: task)
            AgentSites.shared.reset()
            server.stop()
            destination.stop()
            browser.closeAll()
        }
        _ = await box.call("open", ["url": "http://127.0.0.1:\(server.port)/page"], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        var oldConsole = DevEntry(kind: .log)
        oldConsole.message = "previous-site-console"
        tab.devLog.add(oldConsole)
        var oldRequest = DevEntry(kind: .request)
        oldRequest.url = "http://127.0.0.1:\(server.port)/previous-site-request"
        tab.devLog.add(oldRequest)
        let recorder = MessageRecorder()
        let controller = tab.web.configuration.userContentController
        controller.add(recorder, contentWorld: .page, name: "lateDiagnostic")
        defer { controller.removeScriptMessageHandler(forName: "lateDiagnostic", contentWorld: .page) }
        _ = try await tab.web.evaluateJavaScript("window.webkit.messageHandlers.lateDiagnostic.postMessage({kind:'log', message:'previous-site-late-console', source:'\(destinationURL)/forged'}); window.webkit.messageHandlers.lateDiagnostic.postMessage({kind:'request', url:'\(destinationURL)/previous-site-late-request', status:200}); true")
        for _ in 0..<200 where recorder.messages.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(recorder.messages.count == 2)
        let relay = DevRelay(log: tab.devLog)

        tab.go(to: try #require(URL(string: destinationURL + "/page")))
        for _ in 0..<400 where tab.committed?.host() != host || tab.committed?.port != Int(destination.port) || tab.loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.committed?.host() == host)
        #expect(tab.committed?.port == Int(destination.port))
        for message in recorder.messages { relay.userContentController(controller, didReceive: message) }
        _ = try await tab.web.evaluateJavaScript("console.log('current-site-console'); fetch('/current-site-request'); true")
        for _ in 0..<200 where !tab.devLog.entries.contains(where: { $0.url.contains("current-site-request") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        if !changingPort { AgentSites.shared.set(.never, for: "127.0.0.1") }
        let console = await box.call("console", ["tab": id], task: task)
        let network = await box.call("network", ["tab": id], task: task)
        browser.prefs.agentMode = .ask
        AgentDesk.shared.grant(.tab, task: task, site: host)
        let askedConsole = await box.call("console", ["tab": id], task: task)
        let askedNetwork = await box.call("network", ["tab": id], task: task)

        for result in [console, network, askedConsole, askedNetwork] {
            #expect(!result.failed, "\(result.text ?? "")")
            #expect(!(result.text?.contains("previous-site") == true), "\(result.text ?? "")")
        }
        #expect(console.text?.contains("current-site-console") == true)
        #expect(network.text?.contains("current-site-request") == true)
    }

    @Test func diagnosticsCollectOnParkedTabCommits() async throws {
        try await unselectedDiagnostics(parked: true)
    }

    @Test func diagnosticsCollectOnPeekCommits() async throws {
        try await unselectedDiagnostics(parked: false)
    }

    private func unselectedDiagnostics(parked: Bool) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><p>Unselected diagnostics</p><script>console.log('document-start-console')</script>")])
        defer { server.stop(); browser.closeAll() }
        let url = try #require(URL(string: "http://127.0.0.1:\(server.port)/page"))
        let tab: Tab
        if parked {
            tab = browser.benchOpen(url, space: UUID())
        } else {
            tab = Tab()
            browser.prepare(tab)
            browser.peekTab = tab
        }
        tab.agent = true
        tab.arm(hiding: "")

        if !parked { tab.go(to: url) }
        for _ in 0..<400 where tab.committed != url || tab.loading { try await Task.sleep(for: .milliseconds(10)) }
        _ = try await tab.web.evaluateJavaScript("console.log('unselected-page-console'); true")
        for _ in 0..<200 where !tab.devLog.entries.contains(where: { $0.message == "unselected-page-console" }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(tab.committed == url)
        #expect(tab.devLog.entries.contains { $0.message == "document-start-console" })
        #expect(tab.devLog.entries.contains { $0.message == "unselected-page-console" })
    }

    @Test func commitClearsDiagnosticsRefilledAfterLeaving() {
        let tab = Tab()
        tab.leaving()
        var late = DevEntry(kind: .log)
        late.message = "between-policy-and-commit"
        tab.devLog.add(late)

        tab.didCommit()

        #expect(tab.devLog.entries.isEmpty)
    }

    @Test func agentDialogDismissedOnceWhenKeptByThePerson() {
        let tab = Tab()
        tab.agent = true
        var answers: [Bool] = []
        tab.agentDialog = PaneQuestion(tab: tab.id, host: "example.com", message: "Continue?", kind: .confirm) { ok, _ in answers.append(ok) }

        tab.agent = false
        tab.agent = false

        #expect(tab.agentDialog == nil)
        #expect(answers == [false])
    }

    @Test func hoverRoomRestoresActivityWithoutChangingTheKeyWindow() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let room = AgentPageRoom(contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        let key = NSApp.keyWindow

        room.beginHover()
        room.beginHover()
        room.endHover()
        let active = room.isKeyWindow
        let unchanged = NSApp.keyWindow === key
        room.endHover()

        #expect(active)
        #expect(unchanged)
        #expect(!room.isKeyWindow)
        #expect(NSApp.keyWindow === key)
    }

    @Test func siteGatePrivateTabsAndDialogOwnership() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><p>Probe</p>")])
        defer {
            AgentSites.shared.reset()
            server.stop()
            browser.closeAll()
        }
        let task = UUID()
        _ = await box.call("open", ["url": "http://127.0.0.1:\(server.port)/page"], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        var answers: [Bool] = []
        tab.agentDialog = PaneQuestion(tab: tab.id, host: "127.0.0.1", message: "Continue?", kind: .confirm) { ok, _ in answers.append(ok) }
        let dialogID = try #require(tab.agentDialog).id.uuidString
        tab.seal("sealed-probe-value")
        var console = DevEntry(kind: .log)
        console.message = "sealed-probe-value"
        tab.devLog.add(console)

        let scrubbed = await box.call("console", ["tab": id], task: task)
        let blockedRead = await box.call("snapshot", ["tab": id], task: task)
        let wrong = await box.call("dialog", ["tab": id, "action": "accept", "id": dialogID], task: UUID())
        AgentSites.shared.set(.never, for: "127.0.0.1")
        var refused: [Bool] = []
        for name in ["console", "network", "pdf", "hover", "choose", "dialog"] {
            refused.append(await box.call(name, ["tab": id], task: task).failed)
        }
        AgentSites.shared.reset()
        let accepted = await box.call("dialog", ["tab": id, "action": "accept", "id": dialogID], task: task)
        var promptText: String?
        tab.agentDialog = PaneQuestion(tab: tab.id, host: "127.0.0.1", message: "Shipping address?", kind: .prompt("")) { _, text in promptText = text }
        let promptID = try #require(tab.agentDialog).id.uuidString
        let shipping = await box.call("dialog", ["tab": id, "action": "accept", "id": promptID, "text": "Test street"], task: task)
        tab.agentDialog = PaneQuestion(tab: tab.id, host: "127.0.0.1", message: "Enter PIN", kind: .prompt("")) { _, _ in }
        let pinID = try #require(tab.agentDialog).id.uuidString
        let pin = await box.call("dialog", ["tab": id, "action": "accept", "id": pinID, "text": "123456"], task: task)
        tab.agentDialog?.answer(ok: false)
        tab.agentDialog = nil
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        let privateTab = quiet.benchOpen(URL(string: "http://127.0.0.1:\(server.port)/page")!)
        let privateID = String(privateTab.id.uuidString.prefix(8)).lowercased()
        let hidden = await box.call("console", ["tab": privateID], task: task)

        #expect(!(scrubbed.text?.contains("sealed-probe-value") == true))
        #expect(blockedRead.failed)
        #expect(wrong.failed)
        #expect(refused == Array(repeating: true, count: 6))
        #expect(!accepted.failed)
        #expect(answers == [true])
        #expect(pin.failed)
        #expect(!shipping.failed)
        #expect(promptText == "Test street")
        #expect(hidden.failed)
    }
}

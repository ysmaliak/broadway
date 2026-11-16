import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AgentDialogMessageTests {
    @Test func promptClassificationIncludesWordsBeyondTheDisplayedPrefix() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let box = BrowserToolbox()
        box.browser = browser
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        browser.prefs.agentMode = .auto
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><p>Dialog fixture</p>")])
        let task = UUID()
        defer {
            AgentDesk.shared.drop(task: task)
            server.stop()
            browser.closeAll()
        }
        _ = await box.call("open", ["url": server.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        let message = String(repeating: "Ordinary words. ", count: 300) + " Enter your password"
        tab.web.evaluateJavaScript("prompt(\(String(reflecting: message)))") { _, _ in }
        for _ in 0..<200 where tab.agentDialog == nil { try await Task.sleep(for: .milliseconds(10)) }
        let question = try #require(tab.agentDialog)

        let accepted = await box.call("dialog", ["tab": id, "action": "accept", "id": question.id.uuidString, "text": "fixture"], task: task)
        let stillOpen = question.open
        _ = await box.call("dialog", ["tab": id, "action": "dismiss", "id": question.id.uuidString], task: task)

        #expect(question.message == message)
        #expect(accepted.failed, "\(accepted.text ?? "")")
        #expect(stillOpen)
        #expect(!question.open)
    }
}

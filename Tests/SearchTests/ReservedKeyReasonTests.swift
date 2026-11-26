import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ReservedKeyReasonTests {
    private func refusal(_ keys: String) async throws -> String? {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let socket = AgentSocket()
        socket.box.browser = browser
        let verb = try #require(PersonCommands.find("shortcuts", "set"))
        let call = PersonCall(noun: "shortcuts", verb: "set", arguments: ["shortcut": "tabs.toNewWindow", "keys": keys],
                              browser: browser, box: socket.box)
        do {
            _ = try await verb.run(call)
            return nil
        } catch let refused as PersonRefusal {
            return refused.message
        }
    }

    @Test func anAgentHearsTheSameReasonForAReservedKeyAsTheShortcutsPage() async throws {
        #expect(try await refusal("cmd+q") == "⌘Q: macOS uses this key")
        #expect(try await refusal("cmd+3") == "⌘3: Tabs 1 to 9 use this key")
        #expect(try await refusal("cmd+tab")?.hasSuffix(": Escape and Tab can't be shortcuts") == true)
        #expect(try await refusal("ctrl+escape")?.hasSuffix(": Escape and Tab can't be shortcuts") == true)
    }
}

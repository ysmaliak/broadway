import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SnippetSettingsTests {
    @Test func addPresentsAndDismissesItsSheetWithNoSavedSnippets() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-settings-\(UUID().uuidString)")
        let store = SnippetStore(url: folder.appendingPathComponent("snippets.json"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderBack(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
            NSApp.setActivationPolicy(policy)
            try? FileManager.default.removeItem(at: folder)
        }

        SettingsEditors.snippet(Snippet(), store: store, over: window)
        for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(10)) }

        let sheet = try #require(window.attachedSheet)
        #expect(store.snippets.isEmpty)
        let content = try #require(sheet.contentView)
        let buttons = content.kitSubviews(of: NSButton.self)
        let save = try #require(buttons.first { $0.title == "Save" })
        #expect(!save.isEnabled)
        let cancel = try #require(buttons.first { $0.title == "Cancel" })
        cancel.performClick(nil)
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(window.attachedSheet == nil)
        #expect(store.snippets.isEmpty)
    }
}

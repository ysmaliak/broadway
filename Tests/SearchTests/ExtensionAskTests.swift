import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct ExtensionAskTests {
    @Test func anExtensionsQuestionKeepsItsWordsButtonsAndKeys() {
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        let asked = Extensions.questionAlert("Add “Notes”?", detail: "It can read and change what's on example.com", icon: icon,
                                             yes: "Add Extension", no: "Cancel", updating: false)
        let updating = Extensions.questionAlert("Update “Notes”?", detail: "It now asks to read and change cookies", icon: nil,
                                                yes: "Update", no: "Keep Old Version", updating: true)

        #expect(asked.messageText == "Add “Notes”?")
        #expect(asked.informativeText == "It can read and change what's on example.com")
        #expect(asked.icon === icon)
        #expect(asked.buttons.map(\.title) == ["Add Extension", "Cancel"])
        #expect(asked.buttons.map(\.keyEquivalent) == ["\r", "\u{1b}"])
        #expect(updating.buttons.map(\.title) == ["Update", "Keep Old Version"])
        #expect(updating.buttons.map(\.keyEquivalent) == ["", "\r"])
        #expect((asked.buttons + updating.buttons).allSatisfy { !$0.hasDestructiveAction })
    }

    @Test func anUpdatingQuestionGetsAnEscapeWatchForCancel() throws {
        let alert = Extensions.questionAlert("Update “Notes”?", detail: "", icon: nil, yes: "Update", no: "Keep Old Version", updating: true)
        let escape = try #require(Ask.escapeCancels(alert))
        NSEvent.removeMonitor(escape)

        #expect(alert.buttons[1].keyEquivalent == "\r")
    }
}

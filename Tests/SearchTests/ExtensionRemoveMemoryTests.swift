import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(3)))
@MainActor
struct ExtensionRemoveMemoryTests {
    @Test func removingAnExtensionForgetsWhatWasHeldForItInMemory() {
        let id = "removememory\(UUID().uuidString.prefix(8).lowercased())"
        let other = "removememory\(UUID().uuidString.prefix(8).lowercased())"
        let now = Date()
        Extensions.clicked[id] = now
        Extensions.pressed[id] = now
        Extensions.touched[id] = now
        ExtensionShims.popups[id] = ["*": "popup.html"]
        ExtensionShims.ownDownloads[id] = ["/tmp/example.pdf"]
        ExtensionShims.panelPath[id] = "panel.html"
        ExtensionShims.panelOnClick.insert(id)
        let asked = URL(string: "https://example.com/file-\(id).pdf")!, kept = URL(string: "https://example.com/file-\(other).pdf")!
        ExtensionShims.askedDownloads[asked] = id
        ExtensionShims.askedDownloads[kept] = other
        defer {
            ExtensionShims.askedDownloads[kept] = nil
            Extensions.clicked[other] = nil
        }
        Extensions.clicked[other] = now
        Extensions.shared.remove(id)
        #expect(Extensions.clicked[id] == nil)
        #expect(Extensions.pressed[id] == nil)
        #expect(Extensions.touched[id] == nil)
        #expect(ExtensionShims.popups[id] == nil)
        #expect(ExtensionShims.ownDownloads[id] == nil)
        #expect(ExtensionShims.panelPath[id] == nil)
        #expect(!ExtensionShims.panelOnClick.contains(id))
        #expect(ExtensionShims.askedDownloads[asked] == nil)
        #expect(ExtensionShims.askedDownloads[kept] == other)
        #expect(Extensions.clicked[other] == now)
    }
}

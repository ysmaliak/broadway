import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionPopupSealTests {
    private func made(_ name: String) async throws -> (URL, WKWebExtensionContext) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("popup-seal-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": name, "version": "1", "permissions": ["tabs"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return (folder, WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder)))
    }

    @Test func anExtensionsPopupShowsNothingOfItselfToAnotherExtension() async throws {
        let (ownFolder, own) = try await made("Own")
        let (otherFolder, other) = try await made("Other")
        defer {
            try? FileManager.default.removeItem(at: ownFolder)
            try? FileManager.default.removeItem(at: otherFolder)
        }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        web.loadHTMLString("<title>Vault</title>", baseURL: URL(string: "https://example.com/popup.html")!)
        let deadline = Date().addingTimeInterval(10)
        while web.url == nil || web.isLoading, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let page = PopupPage(web: web, owner: own.uniqueIdentifier)
        #expect(page.url(for: own) == web.url)
        #expect(page.webView(for: own) === web)
        #expect(page.url(for: other) == nil)
        #expect(page.title(for: other) == nil)
        #expect(page.webView(for: other) == nil)
    }
}

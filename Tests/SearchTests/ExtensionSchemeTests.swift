import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionSchemeTests {
    @Test func anotherExtensionsPageIsKnownByTheCurrentAndTheFormerScheme() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("schemes-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Schemes", "version": "1"]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = "schemesabcdefghijklmnopabcdefghi"

        #expect(Extensions.schemes == ["chrome-extension", "webkit-extension"])
        #expect(Extensions.othersPage(URL(string: "chrome-extension://otherabcdefghijklmnop/page.html"), for: context))
        #expect(Extensions.othersPage(URL(string: "webkit-extension://otherabcdefghijklmnop/page.html"), for: context))
        #expect(Extensions.othersPage(URL(string: "WEBKIT-EXTENSION://otherabcdefghijklmnop/"), for: context))
        #expect(!Extensions.othersPage(URL(string: "chrome-extension://schemesabcdefghijklmnopabcdefghi/page.html"), for: context))
        #expect(!Extensions.othersPage(URL(string: "https://example.com/"), for: context))
    }
}

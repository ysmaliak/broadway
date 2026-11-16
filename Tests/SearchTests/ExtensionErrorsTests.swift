import WebKit
import Testing
@testable import Search

/// WebKit's extension errors are WKNSError proxies, not NSError instances.
/// Search reads them without Swift's Error bridging, which crashed 1.0.7 on
/// macOS 15 when 1Password's button recorded an error on its context.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
final class ExtensionErrorsTests {
    private var root: URL!

    @MainActor init() throws {
        addTeardownBlock { self.tearDown() }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("extension-errors-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    @Test func webKitsOwnErrorsAreReadWithoutBridging() async throws {
        // A permission WebKit doesn't know is recorded as a warning.
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Errors", "version": "1",
            "permissions": ["notARealPermission"],
            "background": ["service_worker": "missing.js"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        let found = try await WKWebExtension(resourceBaseURL: root)
        let raw = found.value(forKey: "errors") as? NSArray
        #expect((raw?.count ?? 0) > 0, "the manifest should give WebKit something to report")
        let read = Extensions.errors(in: raw)
        #expect(read.count == raw?.count)
        for error in read {
            #expect(!error.domain.isEmpty)
            #expect(!error.text.isEmpty)
        }

        let context = WKWebExtensionContext(for: found)
        #expect(Extensions.errors(of: context).count == (context.value(forKey: "errors") as? NSArray)?.count)
    }

    @Test @MainActor func anythingButAnErrorIsSkipped() {
        let error = NSError(domain: WKWebExtensionContext.errorDomain, code: WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue, userInfo: [NSLocalizedDescriptionKey: "worker"])
        let read = Extensions.errors(in: [error, "not an error", NSNull(), 3] as NSArray)
        #expect(read.count == 1)
        #expect(read.first?.domain == WKWebExtensionContext.errorDomain)
        #expect(read.first?.code == WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue)
        #expect(read.first?.text == "worker")
        #expect(Extensions.errors(in: nil).isEmpty)
    }
}

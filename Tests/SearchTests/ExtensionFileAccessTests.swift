import AppKit
import WebKit
import Testing
@testable import Search

/// Files on this Mac are never an extension's, whatever its manifest names,
/// as in Chrome with "Allow access to file URLs" left off.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionFileAccessTests {
    @Test func filesAreNeverGrantedButSitesAre() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("file-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Files", "version": "1",
            "host_permissions": ["file:///*", "https://example.com/*"],
            "content_scripts": [["matches": ["file://*/*", "<all_urls>"], "js": ["c.js"]]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        try Data("0".utf8).write(to: folder.appendingPathComponent("c.js"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))

        Extensions.grantSites(context)
        Extensions.fence(context)

        let file = try #require(URL(string: "file:///Users/someone/notes.html"))
        let site = try #require(URL(string: "https://example.com/page"))
        #expect(!context.hasAccess(to: file), "a file was given")
        #expect(context.hasAccess(to: site), "a named site was not given")
        #expect(!context.grantedPermissionMatchPatterns.keys.contains { Extensions.reachesFiles($0) })

        // A file pattern granted some other way is still outweighed by the fence.
        // Since macOS 27, WebKit refuses a granted file pattern on its own
        // (#617): with nothing granted, there is nothing for the fence to
        // outweigh, and this half has nothing left to prove.
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "file:///*"))
        guard context.hasAccess(to: file) else {
            try Test.cancel("WebKit refuses a granted file pattern itself (#617): nothing for the fence to outweigh")
        }
        Extensions.fence(context)
        #expect(!context.hasAccess(to: file), "the fence let a file through")
    }

    @Test func onlyFilePatternsReachFiles() throws {
        #expect(Extensions.reachesFiles(try WKWebExtension.MatchPattern(string: "file:///*")))
        #expect(Extensions.withheld(try WKWebExtension.MatchPattern(string: "file://*/*")))
        #expect(!Extensions.withheld(try WKWebExtension.MatchPattern(string: "https://*/*")))
        #expect(!Extensions.withheld(WKWebExtension.MatchPattern.allURLs()))
    }
}

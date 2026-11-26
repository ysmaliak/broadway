import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionAddedPermissionsTests {
    private func fixture(in folder: URL, permissions: [String], added: [String]?) async throws -> WKWebExtension {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Added permissions", "version": "1",
            "permissions": permissions,
            "host_permissions": ["https://example.com/*"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        if let added {
            try JSONSerialization.data(withJSONObject: added).write(to: folder.appendingPathComponent(".search-added"))
        }
        return try await WKWebExtension(resourceBaseURL: folder)
    }

    @Test func whatSearchAddedIsNotGrantedAndOnlyWebKitsPermissionsLeaveItsDescription() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("added-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = try await fixture(in: folder, permissions: ["storage", "nativeMessaging", "history", "bookmarks"], added: ["nativeMessaging", "history"])

        #expect(Extensions.grants(found, in: folder) == ["search:bookmarks", "site:https://example.com/*", "storage"])
        #expect(Extensions.describe(found, in: folder) == [
            "Read and change what's on example.com", "Read and change your history", "Read and change your bookmarks",
        ])
    }

    @Test func withNothingAddedEveryDeclaredPermissionCounts() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("added-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = try await fixture(in: folder, permissions: ["storage", "nativeMessaging", "history"], added: nil)

        #expect(Extensions.grants(found, in: folder) == ["nativeMessaging", "search:history", "site:https://example.com/*", "storage"])
        #expect(Extensions.describe(found, in: folder).last == "Read and change your history")
    }

    @Test func nativeMessagingSearchAddedIsNotAskedFor() async throws {
        let id = "addedperms\(UUID().uuidString.prefix(8).lowercased())"
        let folder = Extensions.folder(for: id)
        defer { try? FileManager.default.removeItem(at: folder) }
        let added = WKWebExtensionContext(for: try await fixture(in: folder, permissions: ["nativeMessaging"], added: ["nativeMessaging"]))
        added.uniqueIdentifier = id
        #expect(!Extensions.asksForNative(added))

        try FileManager.default.removeItem(at: folder.appendingPathComponent(".search-added"))
        #expect(Extensions.asksForNative(added))
    }
}

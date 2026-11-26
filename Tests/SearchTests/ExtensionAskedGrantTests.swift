import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionAskedGrantTests {
    private func fixture() async throws -> (URL, WKWebExtension) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("asked-grants-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Asked grants", "version": "1",
            "permissions": ["storage"],
            "optional_permissions": ["cookies"],
            "optional_host_permissions": ["https://example.com/*"],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        return (folder, try await WKWebExtension(resourceBaseURL: folder))
    }

    private func made(_ ext: WKWebExtension, id: String) -> WKWebExtensionContext {
        let context = WKWebExtensionContext(for: ext)
        context.uniqueIdentifier = id
        return context
    }

    @Test func accessAllowedWhileRunningIsGivenAgainAtTheNextLoad() async throws {
        let (folder, ext) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = "askedgrants\(UUID().uuidString.prefix(8).lowercased())"
        defer { ExtensionGrants.forget(id) }
        let first = made(ext, id: id)
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        let previous = Extensions.shared.answerForTests
        Extensions.shared.answerForTests = true
        defer { Extensions.shared.answerForTests = previous }
        Extensions.clicked[id] = Date()
        let reply = try await ExtensionShims.answer([
            "api": "permissions.afterClick", "args": [["cookies"], ["https://example.com/*"]],
        ], from: first, owner: Extensions.shared) as? [String: Any]
        #expect((reply?["value"] as? Bool) == true)
        _ = try await ExtensionShims.answer([
            "api": "permissions.keep", "args": [["cookies", "tabs"], ["https://example.com/*", "https://shop.example/*"]],
        ], from: first, owner: Extensions.shared)
        #expect(Store.settings.stringArray(forKey: ExtensionGrants.permissionsKey(id)) == ["cookies"])
        #expect(Store.settings.stringArray(forKey: ExtensionGrants.sitesKey(id)) == ["https://example.com/*"])

        let next = made(ext, id: id)
        #expect(next.permissionStatus(for: .cookies) != .grantedExplicitly)
        ExtensionGrants.apply(to: next)
        #expect(next.permissionStatus(for: .cookies) == .grantedExplicitly)
        #expect(next.hasAccess(to: URL(string: "https://example.com/page")!))
        #expect(!next.hasAccess(to: URL(string: "https://shop.example/")!))
    }

    @Test func accessGivenBackIsNotGivenAgain() async throws {
        let (folder, ext) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = "askedgrants\(UUID().uuidString.prefix(8).lowercased())"
        defer { ExtensionGrants.forget(id) }
        let first = made(ext, id: id)
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        ExtensionGrants.keep([.cookies], sites: [try WKWebExtension.MatchPattern(string: "https://example.com/*")], for: id)
        _ = try await ExtensionShims.answer([
            "api": "permissions.letGo", "args": [["cookies"], ["https://example.com/*"]],
        ], from: first, owner: Extensions.shared)
        let next = made(ext, id: id)
        ExtensionGrants.apply(to: next)
        #expect(next.permissionStatus(for: .cookies) != .grantedExplicitly)
        #expect(!next.hasAccess(to: URL(string: "https://example.com/page")!))
    }

    @Test func onlyWhatTheManifestStillNamesIsGivenAgain() async throws {
        let (folder, ext) = try await fixture()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = "askedgrants\(UUID().uuidString.prefix(8).lowercased())"
        defer { ExtensionGrants.forget(id) }
        ExtensionGrants.keep([.tabs], sites: [try WKWebExtension.MatchPattern(string: "https://shop.example/*")], for: id)
        let next = made(ext, id: id)
        ExtensionGrants.apply(to: next)
        #expect(next.permissionStatus(for: .tabs) != .grantedExplicitly)
        #expect(!next.hasAccess(to: URL(string: "https://shop.example/")!))
    }

    @Test func removingTheExtensionForgetsWhatItWasGiven() {
        let id = "askedgrants\(UUID().uuidString.prefix(8).lowercased())"
        ExtensionGrants.keep([.cookies], sites: [], for: id)
        #expect(Store.settings.stringArray(forKey: ExtensionGrants.permissionsKey(id)) == ["cookies"])
        ExtensionGrants.forget(id)
        #expect(Store.settings.stringArray(forKey: ExtensionGrants.permissionsKey(id)) == nil)
    }
}

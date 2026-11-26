import AppKit
import UserNotifications
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(3)))
@MainActor
struct ExtensionShimTruthTests {
    @Test func notificationsAreGrantedOnlyWhenTheMacAllowsThem() {
        #expect(ExtensionShims.notificationLevel(.authorized) == "granted")
        #expect(ExtensionShims.notificationLevel(.provisional) == "granted")
        #expect(ExtensionShims.notificationLevel(.denied) == "denied")
        #expect(ExtensionShims.notificationLevel(.notDetermined) == "denied")
    }

    @Test func freeMemoryIsMeasuredNotHalfOfIt() {
        let free = ExtensionShims.availableMemory()
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        #expect(free > 0)
        #expect(free < total)
    }

    @Test func getSelfListsWhatTheExtensionHas() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("get-self-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Self", "version": "1",
                                       "permissions": ["storage", "management"], "host_permissions": ["https://example.com/*"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        for permission in context.webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        Extensions.grantSites(context)
        context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
        context.setPermissionStatus(.grantedExplicitly, for: try WKWebExtension.MatchPattern(string: "https://shop.example/*"))
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        let reply = try await ExtensionShims.answer(["api": "management.getSelf", "args": []], from: context, owner: Extensions.shared) as? [String: Any]
        let me = reply?["value"] as? [String: Any]
        #expect((me?["permissions"] as? [String])?.contains("storage") == true)
        #expect((me?["permissions"] as? [String])?.contains("management") == true)
        #expect(me?["hostPermissions"] as? [String] == ["https://example.com/*"])
        #expect((me?["hostPermissions"] as? [String])?.contains("https://shop.example/*") == false)
        #expect((me?["permissions"] as? [String])?.contains("nativeMessaging") == false)
    }
}

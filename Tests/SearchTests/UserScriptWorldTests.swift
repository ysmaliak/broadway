import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct UserScriptWorldTests {
    @Test func aUserScriptCanSendMessagesOnlyWhenItsWorldAllowsIt() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("user-script-world-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script: [String: Any] = ["id": "one", "js": [["code": "window.done = 1"]]]
        let closed = try String(contentsOf: folder.appendingPathComponent(ExtensionShims.userScriptFile(script, in: folder, messaging: false)), encoding: .utf8)
        let open = try String(contentsOf: folder.appendingPathComponent(ExtensionShims.userScriptFile(script, in: folder, messaging: true)), encoding: .utf8)
        #expect(!closed.contains("sendMessage"))
        #expect(!closed.contains("connect:"))
        #expect(open.contains("sendMessage"))
        #expect(open.contains("connect:"))
        #expect(closed.contains("window.done = 1"))
    }

    @Test func theSavedWorldDecidesMessagingAndAnUnconfiguredWorldFollowsTheDefaultOne() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("user-script-worlds-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Worlds", "version": "1", "permissions": ["userScripts"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let id = context.uniqueIdentifier
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer {
            browser.closeAll()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: Extensions.folder(for: id))
            try? FileManager.default.removeItem(at: ExtensionShims.userScriptsFolder(for: id))
        }
        #expect(!ExtensionShims.userScriptMessaging([:], for: id))
        let turnedOn = try await ExtensionShims.answer(["api": "userScripts.world", "args": [["messaging": true]]], from: context, owner: Extensions.shared) as? [String: Any]
        #expect(turnedOn?["value"] as? Bool == true)
        let again = try await ExtensionShims.answer(["api": "userScripts.world", "args": [["messaging": true]]], from: context, owner: Extensions.shared) as? [String: Any]
        #expect(again?["value"] as? Bool == false)
        _ = try await ExtensionShims.answer(["api": "userScripts.world", "args": [["worldId": "quiet", "messaging": false]]], from: context, owner: Extensions.shared)
        #expect(ExtensionShims.userScriptMessaging([:], for: id))
        #expect(ExtensionShims.userScriptMessaging(["worldId": "other"], for: id))
        #expect(!ExtensionShims.userScriptMessaging(["worldId": "quiet"], for: id))
    }
}

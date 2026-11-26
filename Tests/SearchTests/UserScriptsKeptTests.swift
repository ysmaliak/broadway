import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct UserScriptsKeptTests {
    private func made(id: String) async throws -> (URL, WKWebExtensionContext) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("user-scripts-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["manifest_version": 3, "name": "User scripts", "version": "1", "permissions": ["userScripts"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = id
        return (folder, context)
    }

    private func call(_ api: String, _ args: [Any], _ context: WKWebExtensionContext) async throws -> Any? {
        let reply = try await ExtensionShims.answer(["api": api, "args": args], from: context, owner: Extensions.shared) as? [String: Any]
        return reply?["value"]
    }

    @Test func registeredUserScriptsAndWorldsOutliveTheSwapOfThePackageFolder() async throws {
        let id = "userscripts\(UUID().uuidString.prefix(8).lowercased())"
        let (folder, context) = try await made(id: id)
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: Extensions.folder(for: id))
            try? FileManager.default.removeItem(at: ExtensionShims.userScriptsFolder(for: id))
        }
        let script: [String: Any] = ["id": "one", "matches": ["https://example.com/*"], "js": [["code": "1"]]]
        _ = try await call("userScripts.save", [[script]], context)
        _ = try await call("userScripts.world", [["worldId": "w", "messaging": false]], context)
        try? FileManager.default.removeItem(at: Extensions.folder(for: id))
        let list = try await call("userScripts.list", [], context) as? [[String: Any]]
        #expect(list?.compactMap { $0["id"] as? String } == ["one"])
        let worlds = try await call("userScripts.worlds", [], context) as? [[String: Any]]
        #expect(worlds?.compactMap { $0["worldId"] as? String } == ["w"])
    }

    @Test func aListKeptInsideThePackageByAnEarlierBuildIsCarriedOut() async throws {
        let id = "userscripts\(UUID().uuidString.prefix(8).lowercased())"
        let (folder, context) = try await made(id: id)
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: Extensions.folder(for: id))
            try? FileManager.default.removeItem(at: ExtensionShims.userScriptsFolder(for: id))
        }
        let inside = Extensions.folder(for: id).appendingPathComponent("_search", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [["id": "old"]]).write(to: inside.appendingPathComponent("userscripts.json"))
        #expect((try await call("userScripts.list", [], context) as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["old"])
        try FileManager.default.removeItem(at: Extensions.folder(for: id))
        #expect((try await call("userScripts.list", [], context) as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["old"])
    }
}

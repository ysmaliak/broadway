import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionRequestManyTests {
    private let site = "https://example.com/*"

    private func run(answer: Bool, gesture: Bool = true, listed: String? = nil,
                     _ check: (WKWebExtensionContext, [String: Any], [String], [String]) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("request-many-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let manifest: [String: Any] = [
            "manifest_version": 3, "name": "Request many", "version": "1",
            "permissions": ["storage"],
            "optional_permissions": ["cookies", "tabs", "clipboardRead"],
            "optional_host_permissions": [listed ?? site],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        let id = "requestmany\(UUID().uuidString.prefix(8).lowercased())"
        context.uniqueIdentifier = id
        defer {
            ExtensionGrants.forget(id)
            Store.settings.removeObject(forKey: "extensions.granted.\(id)")
            ExtensionRequest.answered[id] = nil
        }
        let browser = Browser(record: WindowRecord())
        Browsers.register(browser)
        defer { browser.closeAll() }
        let previous = Extensions.shared.answerForTests
        Extensions.shared.answerForTests = answer
        defer { Extensions.shared.answerForTests = previous }
        let before = Extensions.shared.asked.count
        let reply = try await ExtensionShims.answer([
            "api": "permissions.ask", "args": [["clipboardRead"], ["cookies", "tabs"], [site], gesture],
        ], from: context, owner: Extensions.shared) as? [String: Any] ?? [:]
        try await check(context, reply, Array(Extensions.shared.asked.dropFirst(before)), Array(Extensions.shared.askedDetails.dropFirst(before)))
    }

    private func granted(_ context: WKWebExtensionContext) throws -> [Bool] {
        let pattern = try WKWebExtension.MatchPattern(string: site)
        return [
            Store.settings.stringArray(forKey: "extensions.granted.\(context.uniqueIdentifier)")?.contains("clipboardRead") == true,
            context.permissionStatus(for: .cookies) == .grantedExplicitly,
            context.permissionStatus(for: .tabs) == .grantedExplicitly,
            context.permissionStatus(for: pattern) == .grantedExplicitly,
        ]
    }

    @Test func oneRequestForSeveralThingsAsksOnceAndListsThemAll() async throws {
        try await run(answer: true) { context, reply, titles, details in
            #expect(reply["value"] as? Bool == true)
            #expect(titles == ["Request many asks for more access"])
            let detail = try #require(details.first)
            for sentence in ["Read and change what's on example.com", "Read the clipboard", "Read and change cookies",
                             "See your open tabs and their addresses"] {
                #expect(detail.contains(sentence), "\(sentence)")
            }
            let now = try granted(context)
            #expect(now == [true, true, true, true])
        }
    }

    @Test func aSiteCoveredByAWildcardTheManifestNamesCanBeAskedFor() async throws {
        try await run(answer: true, listed: "*://*/*") { context, reply, titles, _ in
            #expect(reply["value"] as? Bool == true)
            #expect(titles.count == 1)
            let now = try granted(context)
            #expect(now == [true, true, true, true])
        }
    }

    @Test func dontAllowGrantsNoneOfThem() async throws {
        try await run(answer: false) { context, reply, titles, _ in
            #expect(reply["value"] as? Bool == false)
            #expect(titles.count == 1)
            let now = try granted(context)
            #expect(now == [false, false, false, false])
        }
    }

    @Test func withoutAClickNothingIsAskedOrGranted() async throws {
        try await run(answer: true, gesture: false) { context, reply, titles, _ in
            #expect((reply["error"] as? String)?.contains("user gesture") == true)
            #expect(titles.isEmpty)
            let now = try granted(context)
            #expect(now == [false, false, false, false])
        }
    }

    @Test func webKitAskingRightAfterTheSheetIsAnsweredFromIt() async throws {
        try await run(answer: true) { context, _, _, _ in
            let controller = WKWebExtensionController(configuration: .nonPersistent())
            let before = Extensions.shared.asked.count
            let given = await Extensions.shared.webExtensionController(controller, promptForPermissions: [.cookies, .tabs], in: nil, for: context)
            let sites = await Extensions.shared.webExtensionController(
                controller, promptForPermissionMatchPatterns: [try WKWebExtension.MatchPattern(string: site)], in: nil, for: context)
            #expect(given.0 == [.cookies, .tabs])
            #expect(sites.0.map(\.string) == [site])
            #expect(Extensions.shared.asked.count == before)
        }
    }
}

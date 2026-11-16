import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SitePermissionsTests {
    @Test func listsOnlyChoicesForTheOrigin() {
        let defaults: [String: Any] = [
            "capture.https://meet.example|1": true,
            "capture.https://meet.example|location": false,
            "capture.https://other.example|0": true,
            "unrelated": true,
        ]

        let entries = SitePermissions.entries(for: "https://meet.example", in: defaults)

        #expect(entries.map(\.name) == ["Microphone", "Location"])
        #expect(entries.map(\.allowed) == [true, false])
    }

    @Test func noChoicesGivesNothing() {
        let defaults: [String: Any] = ["capture.https://a.example|notifications": "yes"]

        let entries = SitePermissions.entries(for: "https://a.example", in: defaults)

        #expect(entries.isEmpty)
    }

    @Test func forgetRemovesTheChoice() throws {
        let suite = "site-permissions-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { removeTestDefaults(defaults, suite: suite) }
        let key = "capture.https://forget.example|0"
        defaults.set(true, forKey: key)
        let entry = SitePermissions.Entry(key: key, name: "Camera", allowed: true)

        SitePermissions.remove(entry, from: defaults)

        #expect(defaults.object(forKey: key) == nil)
    }
}

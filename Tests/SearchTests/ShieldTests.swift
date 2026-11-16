import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ShieldTests {
    @Test func networkFilterMatchesOnlyTheListedHostAndItsSubdomains() throws {
        let pattern = try NSRegularExpression(pattern: Shield.networkFilter(for: "segment.com"))
        for url in ["https://segment.com/track", "http://segment.com/track",
                    "https://cdn.segment.com/track", "https://a.b.segment.com/track",
                    "https://segment.com:8443/track", "https://segment.com/",
                    "https://segment.com/?event=test", "https://segment.com/#event"] {
            #expect(pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, "\(url)")
        }
        for url in ["https://segment.company/app.js", "https://cdn.segment.company/app.js",
                    "https://segment.com.example/app.js", "https://segment.com-example/app.js",
                    "https://notsegment.com/app.js", "https://example.com/segment.com/track",
                    "https://segmentXcom/app.js", "ftp://segment.com/track"] {
            #expect(pattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) == nil, "\(url)")
        }
    }

    @Test func theBuiltInListLetsFacebooksSignInScriptThroughAndNothingElseOfIts() throws {
        let patterns = try Shield.signInScripts.map { try NSRegularExpression(pattern: $0) }
        let matches: (String) -> Bool = { url in
            patterns.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }

        let rules = Shield.ownRules
        let filters = rules.map { ($0["trigger"] as? [String: Any])?["url-filter"] as? String ?? "" }
        let kinds = rules.map { ($0["action"] as? [String: Any])?["type"] as? String ?? "" }
        let blocked = try #require(filters.firstIndex(of: Shield.networkFilter(for: "connect.facebook.net")))
        let letThrough = try #require(filters.firstIndex(of: Shield.signInScripts[0]))

        #expect(matches("https://connect.facebook.net/en_US/sdk.js"))
        #expect(matches("https://connect.facebook.net/de_DE/sdk.js?hash=abc"))
        #expect(matches("https://connect.facebook.net/en_US/bundle/sdk.js/"))
        #expect(!matches("https://connect.facebook.net/en_US/fbevents.js"))
        #expect(!matches("https://connect.facebook.net/signals/config/123"))
        #expect(!matches("https://connect.facebook.net.example/en_US/sdk.js"))
        #expect(kinds[blocked] == "block")
        #expect(kinds[letThrough] == "ignore-previous-rules")
        #expect(letThrough > blocked)
    }

    @Test func theBuiltInListCompilesInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shield-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))
        let data = try JSONSerialization.data(withJSONObject: Shield.ownRules)
        let json = try #require(String(data: data, encoding: .utf8))

        let list = try await store.compileContentRuleList(forIdentifier: "own", encodedContentRuleList: json)

        #expect(list != nil)
    }

    @Test func networkFilterCompilesInWebKit() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shield-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))
        let rules: [[String: Any]] = [[
            "trigger": ["url-filter": Shield.networkFilter(for: "segment.com"), "load-type": ["third-party"]],
            "action": ["type": "block"],
        ]]
        let data = try JSONSerialization.data(withJSONObject: rules)
        let json = try #require(String(data: data, encoding: .utf8))
        let list = try await store.compileContentRuleList(forIdentifier: "fixture", encodedContentRuleList: json)
        #expect(list != nil)
    }
}

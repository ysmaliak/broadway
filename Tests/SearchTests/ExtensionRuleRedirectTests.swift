import Foundation
import Testing
@testable import Search

/// A declarativeNetRequest redirect to an extension's own page (Norma's
/// block page): the target WebKit hands over, and who may go there.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionRuleRedirectTests {
    private let base = "chrome-extension://offmcbeojiklcpoccgcjapoofafkhjje"
    private let manifest: [String: Any] = [
        "manifest_version": 3,
        "web_accessible_resources": [["resources": ["blocked.html"], "matches": ["<all_urls>"]]],
    ]

    @Test func escapedFragmentAndQueryComeBackAsChromeReadsThem() {
        func target(_ path: String) -> String { ExtensionRedirectPolicy.ruleTarget(URL(string: base + path)!).absoluteString }
        #expect(target("/blocked.html%23instagram.com") == (base + "/blocked.html#instagram.com"))
        #expect(target("/blocked.html%3Fsite=x%23top") == (base + "/blocked.html?site=x#top"))
        #expect(target("/blocked.html%23a%3Fb") == (base + "/blocked.html#a%3Fb"))
        #expect(target("/blocked.html") == (base + "/blocked.html"))
        // Already a query or fragment: left alone.
        #expect(target("/blocked.html?x=%23") == (base + "/blocked.html?x=%23"))
    }

    @Test func ruleRedirectReachesOnlyExposedFiles() {
        let blocked = ExtensionRedirectPolicy.ruleTarget(URL(string: base + "/blocked.html%23instagram.com")!)
        let https = URL(string: "https://www.instagram.com/")!
        let http = URL(string: "http://example.com/")!
        #expect(ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: https, manifest: manifest, fromRule: true))
        #expect(ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: http, manifest: manifest, fromRule: true))
        // A site's own return to an extension page stays HTTPS only.
        #expect(!ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: http, manifest: manifest))
        // A file the extension doesn't expose, or a way out of its folder.
        for path in ["/options.html", "/blocked.html%2F..%2Fsecret.html", "/../blocked.html"] {
            let other = ExtensionRedirectPolicy.ruleTarget(URL(string: base + path)!)
            #expect(!ExtensionRedirectPolicy.allows(target: other, sourceOrigin: https, manifest: manifest, fromRule: true), "\(path)")
        }
        // Exposed to https sites only: not to an http one, even by a rule.
        let httpsOnly: [String: Any] = [
            "manifest_version": 3,
            "web_accessible_resources": [["resources": ["blocked.html"], "matches": ["https://*/*"]]],
        ]
        #expect(ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: https, manifest: httpsOnly, fromRule: true))
        #expect(!ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: http, manifest: httpsOnly, fromRule: true))
    }

    /// The scheme of a web_accessible_resources origin is matched as
    /// written: an http pattern never lets an https site's own return in,
    /// and "*" covers both for a rule's redirect.
    @Test func originSchemesMatchAsWritten() {
        let blocked = URL(string: base + "/blocked.html")!
        let https = URL(string: "https://example.com/")!
        let http = URL(string: "http://example.com/")!
        func exposed(_ match: String) -> [String: Any] {
            ["manifest_version": 3, "web_accessible_resources": [["resources": ["blocked.html"], "matches": [match]]]]
        }
        #expect(!ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: https, manifest: exposed("http://example.com/*")))
        #expect(!ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: https, manifest: exposed("http://example.com/*"), fromRule: true))
        #expect(ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: http, manifest: exposed("http://example.com/*"), fromRule: true))
        #expect(ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: http, manifest: exposed("*://example.com/*"), fromRule: true))
        #expect(!ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: http, manifest: exposed("*://example.com/*")))
        // Never a file: or other scheme as the site.
        for odd in ["file:///etc/", "data:text/html,x", "javascript:x"] {
            #expect(!ExtensionRedirectPolicy.allows(target: blocked, sourceOrigin: URL(string: odd)!, manifest: exposed("<all_urls>"), fromRule: true), "\(odd)")
        }
        // Only an extension page is a target.
        for odd in ["javascript:alert(1)", "data:text/html,x", "file:///etc/hosts", "https://example.com/blocked.html"] {
            #expect(!ExtensionRedirectPolicy.allows(target: URL(string: odd)!, sourceOrigin: https, manifest: exposed("<all_urls>"), fromRule: true), "\(odd)")
        }
    }

    /// A file exposed with a dynamic URL (uBlock Origin Lite's
    /// strictblock.html): a site's own return never reaches it, the
    /// extension's own rule does, as in Chrome (#709).
    @Test func dynamicURLFilesOnlyByARule() {
        let page = URL(string: base + "/strictblock.html")!
        let https = URL(string: "https://example.com/")!
        let dynamic: [String: Any] = [
            "manifest_version": 3,
            "web_accessible_resources": [["resources": ["/strictblock.html"], "matches": ["<all_urls>"], "use_dynamic_url": true]],
        ]
        #expect(!ExtensionRedirectPolicy.allows(target: page, sourceOrigin: https, manifest: dynamic))
        #expect(ExtensionRedirectPolicy.allows(target: page, sourceOrigin: https, manifest: dynamic, fromRule: true))
        // Still only the file it names, and never an odd value.
        #expect(!ExtensionRedirectPolicy.allows(target: URL(string: base + "/options.html")!, sourceOrigin: https, manifest: dynamic, fromRule: true))
        let odd: [String: Any] = [
            "manifest_version": 3,
            "web_accessible_resources": [["resources": ["/strictblock.html"], "matches": ["<all_urls>"], "use_dynamic_url": "yes"]],
        ]
        #expect(!ExtensionRedirectPolicy.allows(target: page, sourceOrigin: https, manifest: odd, fromRule: true))
    }
}

/// Request rules WebKit would carry out beyond the sites they name
/// (ExtensionShims.misreadByWebKit, #709).
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionMisreadRulesTests {
    private func rule(_ type: String, _ condition: [String: Any]) -> [String: Any] {
        ["id": 1, "action": ["type": type], "condition": condition]
    }

    @Test func patternBesideSitesIsMisreadOnlyForRedirectsAndHeaders() {
        let strict: [String: Any] = ["regexFilter": "^https?://.*", "requestDomains": ["bad.example"], "resourceTypes": ["main_frame"]]
        #expect(ExtensionShims.misreadByWebKit(rule("redirect", strict)))
        #expect(ExtensionShims.misreadByWebKit(rule("modifyHeaders", strict)))
        // Blocks and allows: left as WebKit reads them, as before.
        #expect(!ExtensionShims.misreadByWebKit(rule("block", strict)))
        #expect(!ExtensionShims.misreadByWebKit(rule("allow", strict)))
        // Norma's shape (sites, no pattern) and a precise pattern: kept.
        #expect(!ExtensionShims.misreadByWebKit(rule("redirect", ["requestDomains": ["instagram.com"], "resourceTypes": ["main_frame"]])))
        #expect(!ExtensionShims.misreadByWebKit(rule("redirect", ["regexFilter": "^https?://bad\\.example/", "resourceTypes": ["main_frame"]])))
        #expect(!ExtensionShims.misreadByWebKit(rule("redirect", ["urlFilter": "||bad.example^", "requestDomains": ["bad.example"]])))
        #expect(!ExtensionShims.misreadByWebKit(["id": 2]))
    }

    @Test func rulesetsLoseOnlyMisreadRules() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("search-misread-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rules: [[String: Any]] = [
            ["id": 1, "action": ["type": "redirect", "redirect": ["extensionPath": "/strictblock.html"]],
             "condition": ["regexFilter": "^https?://.*", "requestDomains": ["bad.example"], "resourceTypes": ["main_frame"]]],
            ["id": 2, "action": ["type": "block"], "condition": ["urlFilter": "||ads.example^"]],
        ]
        let clean: [[String: Any]] = [["id": 3, "action": ["type": "block"], "condition": ["urlFilter": "/ad.js"]]]
        try JSONSerialization.data(withJSONObject: rules).write(to: folder.appendingPathComponent("a.json"))
        let untouched = try JSONSerialization.data(withJSONObject: clean)
        try untouched.write(to: folder.appendingPathComponent("b.json"))
        let manifest: [String: Any] = ["declarative_net_request": ["rule_resources": [
            ["id": "a", "enabled": true, "path": "a.json"], ["id": "b", "enabled": true, "path": "/b.json"],
            ["id": "c", "enabled": true, "path": "../outside.json"],
        ]]]
        ExtensionShims.dropMisreadRules(manifest, in: folder)
        let a = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("a.json"))) as? [[String: Any]])
        #expect(a.compactMap { $0["id"] as? Int } == [2])
        #expect(try Data(contentsOf: folder.appendingPathComponent("b.json")) == untouched)
        // Again: nothing more to take out.
        ExtensionShims.dropMisreadRules(manifest, in: folder)
        let again = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("a.json"))) as? [[String: Any]])
        #expect(again.count == 1)
    }
}

import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct ShieldOfferWordsTests {
    @Test func withNoBlockingExtensionTheOfferOnlyAsks() {
        #expect(ShieldOfferView.words(blockers: []) == "Page not working?")
    }

    @Test func aBlockingExtensionIsNamedWithWhereToPauseIt() {
        #expect(ShieldOfferView.words(blockers: ["Example Blocker"]) == "Page not working? Example Blocker still blocks here. Pause it from its own button.")
    }

    @Test func severalBlockingExtensionsAreAllNamed() {
        let words = ShieldOfferView.words(blockers: ["First Blocker", "Second Blocker", "Third Blocker"])

        #expect(words == "Page not working? First Blocker, Second Blocker and Third Blocker still block here. Pause them from their own buttons.")
    }

    @Test func anExtensionWithAnEnabledRulesetBlocks() {
        let manifest: [String: Any] = [
            "permissions": ["declarativeNetRequest", "storage"],
            "declarative_net_request": ["rule_resources": [["id": "ads", "enabled": true, "path": "rules/ads.json"] as [String: Any]]] as [String: Any],
        ]

        #expect(Extensions.blocks(manifest))
    }

    @Test func anExtensionWhoseRulesetsAreAllOffDoesNotBlock() {
        let manifest: [String: Any] = [
            "permissions": ["declarativeNetRequest"],
            "declarative_net_request": ["rule_resources": [["id": "ads", "enabled": false, "path": "rules/ads.json"] as [String: Any]]] as [String: Any],
        ]

        #expect(!Extensions.blocks(manifest))
    }

    @Test func anExtensionWithoutTheRequestPermissionDoesNotBlock() {
        let manifest: [String: Any] = [
            "permissions": ["storage"],
            "declarative_net_request": ["rule_resources": [["id": "ads", "enabled": true, "path": "rules/ads.json"] as [String: Any]]] as [String: Any],
        ]

        #expect(!Extensions.blocks(manifest))
    }
}

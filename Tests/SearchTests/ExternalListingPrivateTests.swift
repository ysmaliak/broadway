import Foundation
import Testing
@testable import Search

@Suite
struct ExternalListingPrivateTests {
    private let loaded = [
        ExtensionExternal.Loaded(id: "aaaa", manifest: ["externally_connectable": ["matches": ["https://shop.example/*"]]], privateAllowed: false),
        ExtensionExternal.Loaded(id: "bbbb", manifest: ["externally_connectable": ["matches": ["https://*.example.com/*"]]], privateAllowed: true),
    ]

    @Test func aNormalTabListsEveryLoadedExtension() {
        let found = ExtensionExternal.listings(loaded, shy: false)
        #expect(Set(found.keys) == ["aaaa", "bbbb"])
    }

    @Test func aPrivateTabListsOnlyExtensionsAllowedInPrivateWindows() {
        let found = ExtensionExternal.listings(loaded, shy: true)
        #expect(Set(found.keys) == ["bbbb"])
        #expect(found["bbbb"] == ["https://*.example.com/*"])
    }
}

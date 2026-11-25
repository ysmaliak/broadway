import Foundation
import Testing
@testable import BroadwayCLI
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct AgentCatalogOnlyTests {
    @Test func oneCommandFindsWhatTheWholeCatalogFinds() {
        let all = AgentCatalog.commands(BrowserToolbox().tools)
        let whole = Catalog(all)
        let words = all.flatMap { [$0["name"] as? String ?? ""] + ($0["aliases"] as? [String] ?? []) } + Array(Catalog.older.keys) + ["clikc", ""]
        for word in words {
            let some = AgentCatalog.only(all, Catalog.wanted(word))
            #expect(Catalog(some).find(word) == whole.find(word), "\(word)")
        }
    }

    @Test func oneCommandIsAFractionOfTheCatalog() throws {
        let all = AgentCatalog.commands(BrowserToolbox().tools)
        let some = AgentCatalog.only(all, Catalog.wanted("click"))
        #expect(some.compactMap { $0["name"] as? String } == ["click"])
        let whole = try JSONSerialization.data(withJSONObject: all)
        let one = try JSONSerialization.data(withJSONObject: some)
        #expect(one.count * 20 < whole.count)
    }
}

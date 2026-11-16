import AppKit
import Testing
@testable import Search

@MainActor
@Suite("Settings symbols", .timeLimit(.minutes(5)))
struct SettingsSymbolTests {
    @Test("every page, row and drill-in names a system symbol")
    func everyIconIsASystemSymbol() {
        let pages = SettingsPage.allCases.map { ($0.rawValue, $0.icon) }
        let rows = SettingsIndex.items.map { ($0.id, $0.icon) }
        let details = SettingsDetail.allCases.map { ($0.rawValue, $0.symbol) }
        let fixed = [("advanced", "slider.horizontal.3"), ("danger", "trash")]

        let missing = (pages + rows + details + fixed).filter { NSImage(systemSymbolName: $0.1, accessibilityDescription: nil) == nil }

        #expect(missing.isEmpty, "\(missing)")
    }

    @Test("the pages wear the asked symbols")
    func askedPageSymbols() {
        let icons = Dictionary(uniqueKeysWithValues: SettingsPage.allCases.map { ($0, $0.icon) })

        #expect(icons[.general] == "gearshape")
        #expect(icons[.field] == "magnifyingglass")
        #expect(icons[.appearance] == "circle.lefthalf.filled")
        #expect(icons[.websites] == "globe")
        #expect(icons[.tabs] == "sidebar.left")
        #expect(icons[.shortcuts] == "command")
        #expect(icons[.agents] == "person.2")
        #expect(icons[.liveFolders] == "dot.radiowaves.left.and.right")
        #expect(icons[.passwords] == "key")
        #expect(icons[.privacy] == "hand.raised")
        #expect(icons[.extensions] == "puzzlepiece.extension")
    }
}

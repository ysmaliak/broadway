import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsSearchControlsTests {
    private func rows(_ browser: Browser, _ shell: SettingsShell) -> [SettingsRowView] {
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        return view.kitSubviews(of: SettingsRowView.self)
    }

    @Test func aSearchResultHasTheControlItsPageHas() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        var withControls: [String: SettingsItem] = [:]
        for page in SettingsPage.allCases {
            let shell = SettingsShell()
            shell.go(to: page)
            for row in rows(browser, shell) where row.control != nil {
                if let item = SettingsIndex.item(row.rowID), !item.findOnly { withControls[item.id] = item }
            }
        }

        var bare: [String] = []
        for item in withControls.values.sorted(by: { $0.id < $1.id }) {
            let shell = SettingsShell()
            shell.query = item.title
            let found = rows(browser, shell).first { $0.rowID == item.id }
            if found?.control == nil { bare.append(item.id) }
        }

        #expect(withControls.count > 20)
        #expect(bare == [])
    }

    @Test func spacesInTheSidebarHasItsPicturesInSearchAndSaysWhenItWaits() {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let was = prefs.usesSpaces
        defer { prefs.usesSpaces = was }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.query = "spaces in the sidebar"

        prefs.usesSpaces = true
        let on = rows(browser, shell).first { $0.rowID == "spaces.stacked" }
        prefs.usesSpaces = false
        let off = rows(browser, shell).first { $0.rowID == "spaces.stacked" }

        #expect(on?.control != nil && on?.alphaValue == 1)
        #expect(off?.control != nil && off?.alphaValue == 0.5 && off?.detail.stringValue == "Only while you use spaces")
        #expect((on?.control as? SettingsPictureChoice)?.isEnabled == true && (off?.control as? SettingsPictureChoice)?.isEnabled == false)
    }

    @Test func anAddInASearchResultOpensItsFieldsOnThePageAndTheRowStopsGlowing() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.query = "site shortcuts"
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "search.keywords" })
        let add = try #require(row.kitSubviews(of: SettingsPill.self).first)

        #expect(add.accessibilityPerformPress())
        let landed = (shell.searching, shell.page, shell.lit)
        let fields = view.kitSubviews(of: SettingsRowView.self).map(\.rowID).filter { ["field.Word", "field.Search address"].contains($0) }
        try await Task.sleep(for: .milliseconds(1700))

        #expect(landed.0 == false && landed.1 == .field && landed.2 == "search.keywords")
        #expect(fields == ["field.Word", "field.Search address"])
        #expect(shell.lit == nil)
        #expect(view.kitSubviews(of: SettingsRowView.self).allSatisfy { !$0.lit })
    }

    @Test func aDangerRowHasOneNameOnItsPageAndInSearch() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let page = SettingsShell()
        page.go(to: .privacy)
        let found = SettingsShell()
        found.query = "clear"

        let names = { (shell: SettingsShell) in
            self.rows(browser, shell).compactMap { $0 as? SettingsDangerRow }.map { "\($0.rowID)=\($0.title.stringValue)" }.sorted()
        }

        #expect(names(page) == ["clear.cache=Clear Cache…", "clear.cookies=Sign Out of Every Site…", "clear.history=Clear History…"])
        #expect(Set(names(found)).isSubset(of: Set(names(page))) && !names(found).isEmpty)
    }
}

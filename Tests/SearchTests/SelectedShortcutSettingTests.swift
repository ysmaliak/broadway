import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SelectedShortcutSettingTests {
    @Test func theShortcutIsOffUnlessTurnedOnAndRemembered() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.selectedShortcut, "sidebar.selected")
        Store.settings.removeObject(forKey: "sidebar.selected")

        let fresh = Preferences().selectedShortcut
        prefs.selectedShortcut = true

        #expect(!fresh)
        #expect(Store.settings.object(forKey: "sidebar.selected") as? Bool == true)
        #expect(Preferences().selectedShortcut)
    }

    @Test func settingsFindsAndSetsIt() throws {
        let prefs = Shared.prefs
        keepSetting(prefs, \.selectedShortcut, "sidebar.selected")
        prefs.selectedShortcut = false
        let item = try #require(SettingsIndex.item("sidebar.selected"))

        let applied = BenchSettings.set("sidebar.selected", true, on: prefs)

        #expect(applied)
        #expect(prefs.selectedShortcut)
        #expect(BenchSettings.values(prefs)["sidebar.selected"] as? Bool == true)
        #expect(!item.findOnly && item.kind == .control && item.page == .appearance && item.group == "sidebar")
        #expect(item.title == "Selected tab shortcut")
        #expect(item.detail == "When the selected tab scrolls out of view, show it at the edge of the list")
        for words in ["selected tab", "show selected tab", "scroll to tab"] {
            #expect(SettingsIndex.find(words).contains { $0.id == "sidebar.selected" }, "\(words)")
        }
        #expect(!BenchSettings.set("sidebar.selected", "nope", on: prefs))
        #expect(PersonSettings.refusal("sidebar.selected", value: "true") == nil)
        #expect(SettingsStageMap.claim("sidebar.selected") == .spot(.tabs))
    }

    @Test func itSitsUnderTheSidebarButton() {
        let ids = SettingsIndex.items(in: "sidebar").map(\.id)

        #expect(ids == ["sidebar.button", "sidebar.selected"])
    }
}

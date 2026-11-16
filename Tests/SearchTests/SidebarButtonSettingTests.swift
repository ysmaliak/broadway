import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SidebarButtonSettingTests {
    private func door(in helm: HelmView) throws -> DoorView {
        try #require(helm.kitSubviews(of: DoorView.self).first { $0.icon.hasPrefix("sidebar.") })
    }

    private func settle(_ helm: HelmView) async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        helm.layoutSubtreeIfNeeded()
    }

    @Test func theButtonIsOnUnlessTurnedOffAndRemembered() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.sideButton, "sidebar.button")
        Store.settings.removeObject(forKey: "sidebar.button")

        let fresh = Preferences().sideButton
        prefs.sideButton = false

        #expect(fresh)
        #expect(Store.settings.object(forKey: "sidebar.button") as? Bool == false)
        #expect(!Preferences().sideButton)
    }

    @Test func settingsFindsAndSetsIt() throws {
        let prefs = Shared.prefs
        keepSetting(prefs, \.sideButton, "sidebar.button")
        prefs.sideButton = true
        let item = try #require(SettingsIndex.item("sidebar.button"))

        let applied = SettingsIndex.apply("sidebar.button", false, to: prefs)

        #expect(applied)
        #expect(!prefs.sideButton)
        #expect(SettingsIndex.values(prefs)["sidebar.button"] as? Bool == false)
        #expect(!item.findOnly && item.kind == .control && item.page == .appearance)
        #expect(item.title == "Sidebar button")
        for words in ["sidebar button", "hide sidebar", "toggle sidebar", "collapse"] {
            #expect(SettingsIndex.find(words).contains { $0.id == "sidebar.button" }, "\(words)")
        }
        #expect(!SettingsIndex.apply("sidebar.button", "nope", to: prefs))
        #expect(PersonSettings.refusal("sidebar.button", value: "false") == nil)
    }

    @Test func theHelmHidesTheButtonWhenTurnedOffAndShowsItAgain() async throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.sideButton, "sidebar.button")
        prefs.sideButton = true
        let browser = Browser(record: WindowRecord())
        let helm = HelmView(browser: browser)
        helm.frame = NSRect(x: 0, y: 0, width: 240, height: 40)
        helm.layoutSubtreeIfNeeded()
        let side = try door(in: helm)
        #expect(!side.isHidden)

        prefs.sideButton = false
        await settle(helm)

        #expect(side.isHidden)

        prefs.sideButton = true
        await settle(helm)

        #expect(!side.isHidden)
    }

    @Test func aNarrowHelmStillHidesTheButtonWhenItIsOn() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.sideButton, "sidebar.button")
        prefs.sideButton = true
        let browser = Browser(record: WindowRecord())
        let helm = HelmView(browser: browser)

        helm.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
        helm.layoutSubtreeIfNeeded()

        #expect(try door(in: helm).isHidden)
    }
}

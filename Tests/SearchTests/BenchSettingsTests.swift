import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct BenchSettingsTests {
    private func put(_ id: String, _ value: Any, _ prefs: Preferences) -> Bool {
        BenchSettings.set(id, value, on: prefs)
    }

    private func values(_ prefs: Preferences) -> [String: Any] {
        BenchSettings.values(prefs)
    }

    @Test func theBenchSetsAndReadsWhatTheProbesSend() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.tabsLayout, "sidebar.position")
        keepSetting(prefs, \.stackedSpaces, "spaces.stacked")
        keepSetting(prefs, \.fillsPasswords, "passwords.fill")
        keepSetting(prefs, \.savesPasswords, "passwords.save")
        keepSetting(prefs, \.asksWhereToSave, "downloads.ask")
        keepSetting(prefs, \.liveEvery, LiveEvery.key)
        keepSetting(prefs, \.miniSkip, Preferences.miniSkipKey)
        keepSetting(prefs, \.miniSpoken, Preferences.miniSpokenKey)
        keepSetting(prefs, \.videoQuality, "video.quality")
        keepSetting(prefs, \.remembersSpeed, "video.speed")
        keepSetting(prefs, \.pullsToRefresh, PullRefresh.key)
        keepSetting(prefs, \.sideButton, "sidebar.button")
        keepSetting(prefs, \.pageZoom, "pageZoom")
        keepSetting(prefs, \.shielded, "shield")
        keepSetting(prefs, \.agentsGivePasswords, "agents.give")

        #expect(put("tabs.layout", "right", prefs))
        #expect(!put("tabs.layout", "icons", prefs))
        #expect(put("spaces.stacked", "stacked", prefs))
        #expect(values(prefs)["spaces.stacked"] as? String == "stacked")
        #expect(put("spaces.stacked", "side", prefs))
        #expect(!put("spaces.stacked", true, prefs))
        #expect(put("passwords.fill", false, prefs))
        #expect(!prefs.fillsPasswords && !prefs.savesPasswords)
        #expect(put("downloads.ask", true, prefs))
        #expect(put(LiveEvery.key, 15, prefs))
        #expect(!put(LiveEvery.key, 7, prefs))
        #expect(put(Preferences.miniSkipKey, 30, prefs))
        #expect(!put(Preferences.miniSkipKey, 20, prefs))
        #expect(put(Preferences.miniSpokenKey, "tracks", prefs))
        #expect(put("video.quality", "1440", prefs))
        #expect(put("video.speed", false, prefs))
        #expect(put(PullRefresh.key, false, prefs))
        #expect(!put("sidebar.button", "nope", prefs))
        #expect(put("sidebar.button", false, prefs))
        #expect(put("pageZoom", 1.1, prefs))
        #expect(prefs.pageZoom == 1.1)
        #expect(put("shield", false, prefs))
        #expect(!prefs.shielded)
        #expect(put("agents.give", true, prefs))
        #expect(prefs.agentsGivePasswords)
        #expect(!put("no.such.setting", true, prefs))

        let read = values(prefs)
        #expect(read["tabs.layout"] as? String == "right")
        #expect(read["spaces.stacked"] as? String == "side")
        #expect(read["passwords.fill"] as? Bool == false)
        #expect(read["downloads.ask"] as? Bool == true)
        #expect(read[LiveEvery.key] as? Int == 15)
        #expect(read[Preferences.miniSkipKey] as? Int == 30)
        #expect(read[Preferences.miniSpokenKey] as? String == "tracks")
        #expect(read["video.quality"] as? String == "1440")
        #expect(read["video.speed"] as? Bool == false)
        #expect(read[PullRefresh.key] as? Bool == false)
        #expect(read["sidebar.button"] as? Bool == false)
        #expect(read["calendars"] as? Bool == prefs.usesCalendars)
        #expect(Set(read.keys) == Set(BenchSettings.shown))
    }

    @Test func rowsOnlyThePersonSetsStillRefuseAgents() {
        for id in ["passwords.fill", "ai.agents", "agents.give"] {
            let access = PersonSettings.table[id]
            #expect(access?.bar == .always, "\(id)")
            #expect(access.map(PersonSettings.canSet) == false, "\(id)")
            #expect(PersonSettings.refusal(id, value: "true")?.code == "person_only", "\(id)")
            #expect(PersonSettings.about(id)["takes"] as? String == "", "\(id)")
        }
    }
}

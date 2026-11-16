import AppKit

extension SettingsPageView {
    func miniPlayerRows() {
        let prefs = prefs
        settingRow(Preferences.miniKey)
        shape { prefs.miniPlayer }
        guard prefs.miniPlayer else { return }
        settingRow(Preferences.miniSkipKey)
        settingRow(Preferences.miniSpokenKey)
        settingRow(Preferences.miniSpeedKey)
    }

    func miniSkipRow() {
        let prefs = prefs
        let skips = MiniRule.skips
        row(Preferences.miniSkipKey, control: popUp(Preferences.miniSkipKey, titles: skips.map { "\($0) Seconds" },
                                                    picked: { skips.firstIndex(of: prefs.miniSkip) ?? 1 },
                                                    set: { prefs.miniSkip = skips[$0] }))
    }

    func miniSpokenRow() {
        let prefs = prefs
        let choices = MiniSpoken.allCases
        row(Preferences.miniSpokenKey, control: popUp(Preferences.miniSpokenKey, titles: choices.map(\.title),
                                                      picked: { choices.firstIndex(of: prefs.miniSpoken) ?? 0 },
                                                      set: { prefs.miniSpoken = choices[$0] }))
    }
}

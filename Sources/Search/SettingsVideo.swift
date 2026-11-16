import AppKit

extension SettingsPageView {
    func videoQualityRow() {
        let prefs = prefs
        let choices = VideoQuality.choices
        row("video.quality", control: popUp("video.quality", titles: choices.map(\.title),
                                            picked: { choices.firstIndex(of: prefs.videoQuality) ?? 0 },
                                            set: { prefs.videoQuality = choices[$0] }))
    }

    func videoSpeedSites() {
        let book = VideoSpeedBook.shared
        shape { book.sites.map { "\($0.site) \($0.rate)" } }
        for kept in book.sites {
            _ = line(kept.site, VideoSpeed.line(kept.rate), id: "video.site." + kept.site, control: button("Remove…") { [weak self] in
                SettingsQuestion.videoSpeed(kept.site).ask(over: self?.window) {
                    book.forget(kept.site)
                    self?.refresh()
                }
            })
        }
    }
}

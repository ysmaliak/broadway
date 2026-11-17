import AppKit

extension Browser {
    func tabsToMute(sparing spared: Tab? = nil) -> [Tab] {
        var shown = visibleTabIDs
        if let spared { shown.insert(spared.id) }
        return (tabs + parkedTabs).filter { $0.noisy && !$0.muted && !shown.contains($0.id) }
    }

    var canMuteOtherTabs: Bool { !tabsToMute().isEmpty }

    func muteOtherTabs(sparing spared: Tab? = nil) {
        for tab in tabsToMute(sparing: spared) { tab.toggleMute() }
    }
}

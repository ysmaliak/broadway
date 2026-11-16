import Foundation

enum SettingsCut {
    nonisolated static let fixed = [
        "tabs.give", "downloads.button", "float.leave", "float.away", "pages.120.mode", "pages.120",
        "spaces", "live.on", "tabs.newPlace", "glyph", "layout.cards", "sidebar.address", "sidebar.fullAddress",
        "float.style", "sidebar.hides", "tabs.shortcuts", "tabs.address",
        "downloads.recentFiles", "tabs.cards", "tabs.newAtBottom", "tabs.newAfterLast", "tabs.closeGoesBack",
        "tabs.lazy", "tabs.sleep", "tabs.sleep.pace", "agents.tabsClose", "meetings.lead", "field.now",
        "video.keys", "media.click", "pins.home", "pins.peek", "start.fresh", "dev.offer",
        "shield.lists", "privacy.clickIDs", "privacy.gpc", "localnetwork.ask", "autofill.forms", "autofill.drafts",
        "ai.routes", "ai.models", "ai.efforts", "ai.groups.engine", "ai.groups.namer", "links.peek", "links.peekClick",
        "swipe.history",
        "commandbar", "autoscroll", "fullscreen.escapeTwice",
        "passkeys", "passkeys.for", "passkeys.entitled",
        "sidebar.icons", "ai.defaultView", "ai",
    ]

    nonisolated static let lowPowerKey = "motion.light"

    nonisolated static let retiredPrefix = "brief."
    nonisolated static let retiredKeys = ["weather.api"]
    nonisolated static let retiredFiles = ["brief-weather.json", "brief-place.json"]

    nonisolated static func retire(_ store: UserDefaults, folder: URL) {
        for key in store.dictionaryRepresentation().keys where key.hasPrefix(retiredPrefix) { store.removeObject(forKey: key) }
        for key in retiredKeys { store.removeObject(forKey: key) }
        let files = FileManager.default
        for name in retiredFiles { try? files.removeItem(at: folder.appendingPathComponent(name)) }
        let now = folder.appendingPathComponent("now.json")
        guard let data = try? Data(contentsOf: now),
              let marks = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        let kept = marks.filter { !$0.key.hasPrefix(retiredPrefix) }
        guard kept.count != marks.count, let written = try? JSONEncoder().encode(kept) else { return }
        try? written.write(to: now, options: .atomic)
    }

    nonisolated static func migrate(_ store: UserDefaults, testing: Bool) {
        guard !testing else { return }
        let save = store.object(forKey: "passwords.save") as? Bool ?? true
        let fill = store.object(forKey: "passwords.fill") as? Bool ?? true
        if !save || !fill {
            store.set(false, forKey: "passwords.save")
            store.set(false, forKey: "passwords.fill")
        }
        if store.bool(forKey: "meetings.next") || store.object(forKey: "meetings.alerts") as? Bool == true {
            store.set(true, forKey: "meetings.next")
            store.set(true, forKey: "meetings.alerts")
        }
        if store.object(forKey: "ai") as? Bool == false {
            store.set(false, forKey: "ai.groups")
            store.set(false, forKey: "ai.groups.emoji")
            store.set(false, forKey: "agents.on")
        }
        for key in fixed { store.removeObject(forKey: key) }
        store.set(false, forKey: lowPowerKey)
    }
}

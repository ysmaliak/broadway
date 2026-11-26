import Foundation

@MainActor
enum BenchSettings {
    static let shown = ["tabs.layout", "spaces.stacked", "downloads.ask", "passwords.fill", "calendars", "newtab.floating",
                        "sidebar.button", "sidebar.selected", Preferences.hintsKey, "video.quality", "video.speed", LiveEvery.key,
                        Preferences.miniKey, Preferences.miniSkipKey, Preferences.miniSpokenKey, Preferences.miniSpeedKey, PullRefresh.key]

    static func values(_ prefs: Preferences) -> [String: Any] {
        var values: [String: Any] = [:]
        for id in shown { values[id] = PersonSettings.table[id]?.read(prefs) }
        values["spaces.stacked"] = prefs.stackedSpaces ? "stacked" : "side"
        values["downloads.ask"] = prefs.asksWhereToSave
        values["calendars"] = prefs.usesCalendars
        return values
    }

    static func set(_ id: String, _ value: Any, on prefs: Preferences) -> Bool {
        switch id {
        case "spaces.stacked":
            guard let choice = value as? String, ["side", "stacked"].contains(choice) else { return false }
            return PersonSettings.setForTests(id, choice == "stacked" ? "true" : "false", on: prefs)
        case "downloads.ask":
            guard let on = value as? Bool else { return false }
            prefs.asksWhereToSave = on
            return true
        case "pageZoom":
            guard let zoom = (value as? NSNumber)?.doubleValue else { return false }
            return PersonSettings.setForTests(id, String(Int((zoom * 100).rounded())), on: prefs)
        default:
            guard let text = text(value) else { return false }
            return PersonSettings.setForTests(id, text, on: prefs)
        }
    }

    static func text(_ value: Any) -> String? {
        if let text = value as? String { return text }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        let double = number.doubleValue
        return double == double.rounded() ? String(Int(double)) : String(double)
    }
}

import AppKit

@MainActor
enum SettingsCallSpacesFold {
    static var open: Set<String> = []
}

enum SettingsCallSpacesWords {
    static let anySpace = "Any Space"
    static let sameAsAccount = "Same as Account"
    static let calendars = "Calendars"

    static func names(_ calendars: [MeetingCalendar]) -> String {
        let titles = calendars.map(\.title)
        guard titles.count > 3 else { return titles.joined(separator: ", ") }
        return titles.prefix(2).joined(separator: ", ") + " and \(titles.count - 2) more"
    }
}

extension SettingsPageView {
    func callSpacesRows() {
        row("meetings.spaces")
        callSpaceAccounts(apart: false)
    }

    func callSpaceAccounts(apart: Bool) {
        let prefs = prefs
        let browser = browser
        shape { prefs.usesCalendars && Meetings.shared.hasAccess && prefs.usesSpaces && browser.spaces.count > 1 }
        guard prefs.usesCalendars, Meetings.shared.hasAccess, prefs.usesSpaces, browser.spaces.count > 1 else { return }
        shape { Meetings.shared.calendarList }
        shape { SettingsSpaceChoice.key(browser.spaces) }
        shape { SettingsCallSpacesFold.open }
        Task { await Meetings.shared.readCalendars() }
        let spaces = browser.spaces
        let ids = spaces.map(\.id)
        let spaceEntries: [(String, UUID, NSImage?)] = spaces.map { ($0.name, $0.id, $0.settingsBadge) }
        for account in MeetingAccount.grouped(Meetings.shared.calendarList) {
            if apart {
                section { callSpaceAccount(account, spaces: spaceEntries, ids: ids) }
            } else {
                callSpaceAccount(account, spaces: spaceEntries, ids: ids)
            }
        }
    }

    private func callSpaceAccount(_ account: MeetingAccount, spaces spaceEntries: [(String, UUID, NSImage?)], ids: [UUID]) {
        let places = MeetingSpacePlaces.shared
        let key = account.key
        let entries: [LinkMenuEntry<UUID?>] = [.value(SettingsCallSpacesWords.anySpace, nil, nil), .line]
            + spaceEntries.map { .value($0.0, $0.1, $0.2) }
        let pick = linkMenu("meetings.space.account", entries, picked: { places.shown(places.space(ofAccount: key), among: ids) },
                            set: { places.place($0, ofAccount: key) })
        pick.button.setAccessibilityIdentifier("settings.meetings.space.account." + key)
        pick.button.setAccessibilityLabel("Space for \(account.name)")
        _ = line(account.name, nil, symbol: "person.crop.circle", id: "meetings.space.account." + key, control: pick)
        let open = SettingsCallSpacesFold.open.contains(key)
        let mark = NSButton(title: "", target: nil, action: nil)
        mark.bezelStyle = .disclosure
        mark.setButtonType(.pushOnPushOff)
        mark.state = open ? .on : .off
        let flip = { [weak self] in
            if open { SettingsCallSpacesFold.open.remove(key) } else { SettingsCallSpacesFold.open.insert(key) }
            self?.refresh()
        }
        mark.kitOnChange { _ in flip() }
        mark.kitAccess(id: "settings.meetings.space.mark." + key)
        let fold = SettingsFoldRow(id: "meetings.space.fold." + key, title: SettingsCallSpacesWords.calendars,
                                   detail: open ? "" : SettingsCallSpacesWords.names(account.calendars), open: open, control: mark, flip: flip)
        fold.setAccessibilityIdentifier("settings.meetings.space.fold." + key)
        put(fold)
        guard open else { return }
        for calendar in account.calendars {
            let id = calendar.id
            let choices: [LinkMenuEntry<MeetingCalendarPlace>] = [
                .value(SettingsCallSpacesWords.sameAsAccount, .account, nil),
                .value(SettingsCallSpacesWords.anySpace, .any, nil),
                .line,
            ] + spaceEntries.map { .value($0.0, .space($0.1), $0.2) }
            let pick = linkMenu("meetings.space.calendar", choices, picked: { places.shown(places.place(ofCalendar: id), among: ids) },
                                set: { places.place($0, ofCalendar: id) })
            pick.button.setAccessibilityIdentifier("settings.meetings.space.calendar." + id)
            pick.button.setAccessibilityLabel("Space for \(calendar.title)")
            _ = line(calendar.title, nil, symbol: "calendar", id: "meetings.space.calendar." + id, control: pick)
        }
    }
}

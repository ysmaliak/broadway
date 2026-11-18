import Foundation

enum FieldAction {
    static let nowhere = URL(string: "about:blank")!
}

enum FieldName {
    static func plain(_ title: String) -> String {
        title.replacingOccurrences(of: "…", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func score(_ typed: String, title: String, aliases: [String] = []) -> Int? {
        let needle = typed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard needle.count >= 2 else { return nil }
        let wanted = needle.split(separator: " ").map(String.init)
        let name = plain(title).lowercased()
        func fits(_ text: String) -> Bool {
            let words = text.split { !$0.isLetter && !$0.isNumber }
            return wanted.allSatisfy { part in words.contains { $0.hasPrefix(part) } }
        }
        if name == needle { return 100 }
        if aliases.contains(needle) { return 90 }
        if name.hasPrefix(needle) { return 80 }
        if aliases.contains(where: { $0.hasPrefix(needle) }) { return 70 }
        if fits(name) { return 60 }
        if aliases.contains(where: fits) { return 40 }
        return nil
    }
}

@MainActor
enum FieldCommands {
    static let hidden: Set<String> = [Command.recentTabs, "field.favorite", "field.favoriteUp", "field.favoriteDown"]

    static let aliases: [String: [String]] = [
        "app.settings": ["preferences", "options"],
        "app.passwords": ["logins", "keychain"],
        "file.newPrivateWindow": ["incognito", "private window", "private browsing"],
        "file.reopen": ["undo close", "restore tab"],
        "file.import": ["import", "migrate"],
        "edit.find": ["search page"],
        "edit.copyCleanLink": ["copy link"],
        "edit.copyPageMarkdown": ["copy as markdown", "copy page", "markdown"],
        "view.fold": ["toggle sidebar", "show sidebar"],
        "view.float": ["picture in picture", "pip"],
        "view.dusk": ["dark mode", "dark page"],
        "view.inspector": ["devtools", "developer tools"],
        "tabs.split": ["split view"],
        "tabs.copyAddress": ["copy link", "copy url", "copy links"],
        "tabs.copyMarkdown": ["markdown"],
        "tabs.copyRich": ["copy link", "rich link", "copy links"],
        "tabs.pickAll": ["select all tabs"],
        "tabs.moveUp": ["reorder tab"],
        "tabs.moveDown": ["reorder tab"],
        "tabs.mute": ["mute"],
        "bookmarks.add": ["bookmark page", "save page"],
        "history.show": ["recent pages"],
        "history.clearData": ["clear cookies", "clear cache"],
    ]

    static func available(_ command: Command, in browser: Browser) -> Bool {
        if hidden.contains(command.id) { return false }
        if command.section == .spaces {
            guard browser.prefs.usesSpaces else { return false }
            if let number = Command.spaceNumber(command.id) { return number <= browser.spaces.count }
            if Command.spaceSteps.contains(command.id) { return browser.spaces.count > 1 }
            return true
        }
        if Command.split.contains(command.id), !browser.prefs.splitView { return false }
        if Command.dusk.contains(command.id), !browser.prefs.darkensPages { return false }
        if Command.meeting.contains(command.id), !browser.prefs.nextMeeting { return false }
        if Command.folders.contains(command.id), !browser.prefs.usesTabGroups { return false }
        return true
    }

    static var pages: [SettingsPage] {
        Array(SettingsPage.allCases)
    }

    static func row(_ command: Command) -> Suggestion {
        var row = Suggestion(key: FieldName.plain(command.title), title: "", url: FieldAction.nowhere,
                             kind: .action("command:" + command.id))
        row.keys = ShortcutStore.shared.key(for: command.id)?.display ?? ""
        row.symbol = "command"
        return row
    }

    static func row(_ page: SettingsPage) -> Suggestion {
        var row = Suggestion(key: page.title, title: "Settings", url: FieldAction.nowhere,
                             kind: .action("settings:" + page.rawValue))
        row.symbol = page.icon
        return row
    }

    static func row(_ item: SettingsItem) -> Suggestion {
        var row = Suggestion(key: item.title, title: "Settings › " + item.page.title, url: FieldAction.nowhere,
                             kind: .action("setting:" + item.id))
        row.symbol = item.icon
        return row
    }

    static func rows(for typed: String, in browser: Browser, limit: Int = 4) -> [Suggestion] {
        var found: [(Int, Suggestion)] = []
        for command in Command.all where available(command, in: browser) {
            if let score = FieldName.score(typed, title: command.title, aliases: aliases[command.id] ?? []) {
                found.append((score, row(command)))
            }
        }
        for page in pages {
            if let score = FieldName.score(typed, title: page.title, aliases: ["\(page.title.lowercased()) settings"]) {
                found.append((score - 1, row(page)))
            }
        }
        for item in SettingsIndex.items where !item.title.isEmpty && item.kind != .note {
            guard !item.findOnly else { continue }
            if let score = FieldName.score(typed, title: item.title, aliases: item.words) {
                found.append((score - 30, row(item)))
            }
        }
        var seen = Set<String>()
        return found
            .enumerated()
            .sorted { $0.element.0 != $1.element.0 ? $0.element.0 > $1.element.0 : $0.offset < $1.offset }
            .map(\.element.1)
            .filter { seen.insert(($0.key + "\n" + $0.title).lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }
}

extension Browser {
    func fieldRows(for typed: String) -> [Suggestion] {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2, text.rangeOfCharacter(from: CharacterSet(charactersIn: "./:")) == nil else { return [] }
        return FieldCommands.rows(for: text, in: self)
    }

    func addFieldRows() {
        let quick = QuickActions.shared.matches(typed, history: history)
        if let lead = quick.lead, let row = quickRow(lead, leads: true) {
            offers.insert(row, at: 0)
            ending = nil
        }
        offers += quick.others.compactMap { quickRow($0) }
        let listed = Set(offers.filter(\.kind.isCommand).map { $0.key.lowercased() })
        offers += fieldRows(for: typed).filter { !listed.contains($0.key.lowercased()) }
    }
}

extension Browser {
    func runFieldAction(_ id: String) {
        quitField()
        let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        switch parts[0] {
        case "command":
            Command.named(parts[1])?.run(self)
        case "settings":
            if let page = SettingsPage.named(parts[1]) { openSettings(page) }
        case "setting":
            if let item = SettingsIndex.item(parts[1]) { openSettings(item.page) }
        case "quick":
            runQuick(parts[1])
        case "page":
            runPageAction(parts[1])
        case "now":
            runNow(parts[1])
        default:
            break
        }
    }

    func openSettings(_ page: SettingsPage) {
        settingsPage = page
        tuning = true
    }
}

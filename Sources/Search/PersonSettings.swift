import AppKit
import Foundation

struct SettingAccess {
    enum Bar: Equatable {
        case free
        case always
        case turningOff
        case turningOn
        case noControl
        case soon
    }

    var bar: Bar = .free
    var takes = ""
    var read: @MainActor (Preferences) -> Any? = { _ in nil }
    var write: (@MainActor (Preferences, String) -> Bool)?
    var instead: String?
    var check: (@MainActor (String) -> Bool)?
    var failure: String?
}

@MainActor
enum PersonSettings {
    private static func yes(_ text: String) -> Bool? {
        ["true": true, "on": true, "yes": true, "1": true, "false": false, "off": false, "no": false, "0": false][text.lowercased()]
    }

    private static func settable(_ bar: SettingAccess.Bar = .free, takes: String, read: @escaping @MainActor (Preferences) -> Any?,
                                 check: @escaping @MainActor (String) -> Bool, apply: @escaping @MainActor (Preferences, String) -> Void) -> SettingAccess {
        SettingAccess(bar: bar, takes: takes, read: read, write: { prefs, text in
            guard check(text) else { return false }
            apply(prefs, text)
            return true
        }, check: check)
    }

    private static func onOff(_ bar: SettingAccess.Bar = .free, read: @escaping @MainActor (Preferences) -> Any?,
                              apply: @escaping @MainActor (Preferences, Bool) -> Void) -> SettingAccess {
        settable(bar, takes: "true or false", read: read, check: { yes($0) != nil }, apply: { prefs, text in
            if let on = yes(text) { apply(prefs, on) }
        })
    }

    private static func flag(_ path: ReferenceWritableKeyPath<Preferences, Bool>, _ bar: SettingAccess.Bar = .free) -> SettingAccess {
        onOff(bar, read: { $0[keyPath: path] }, apply: { $0[keyPath: path] = $1 })
    }

    private static func held(_ path: ReferenceWritableKeyPath<Preferences, Bool>) -> SettingAccess {
        SettingAccess(bar: .always, read: { $0[keyPath: path] }, write: { prefs, text in
            guard let on = yes(text) else { return false }
            prefs[keyPath: path] = on
            return true
        }, check: { yes($0) != nil })
    }

    private static func choice<Value: CaseIterable & RawRepresentable>(_ path: ReferenceWritableKeyPath<Preferences, Value>) -> SettingAccess where Value.RawValue == String {
        settable(takes: Value.allCases.map(\.rawValue).joined(separator: ", "), read: { $0[keyPath: path].rawValue }, check: { Value(rawValue: $0) != nil }) { prefs, text in
            if let value = Value(rawValue: text) { prefs[keyPath: path] = value }
        }
    }

    private static func stored(_ key: String, fallback: Bool) -> SettingAccess {
        SettingAccess(bar: .always, read: { _ in Store.settings.object(forKey: key) as? Bool ?? fallback })
    }

    private static func row(_ instead: String? = nil) -> SettingAccess {
        SettingAccess(bar: .noControl, instead: instead)
    }

    private static let alwaysOn = row("Always on")

    private static func always(_ path: KeyPath<Preferences, Bool>) -> SettingAccess {
        SettingAccess(bar: .noControl, read: { $0[keyPath: path] }, instead: "Always on")
    }

    private static func shared(_ read: @escaping @MainActor () -> Bool, _ write: @escaping @MainActor (Bool) -> Void) -> SettingAccess {
        onOff(.turningOn, read: { _ in read() }, apply: { write($1) })
    }

    private static func number(_ path: ReferenceWritableKeyPath<Preferences, Int>, within range: ClosedRange<Int>) -> SettingAccess {
        settable(takes: "a whole number from \(range.lowerBound) to \(range.upperBound)", read: { $0[keyPath: path] },
                 check: { Int($0).map { range.contains($0) } == true }) { prefs, text in
            if let value = Int(text) { prefs[keyPath: path] = value }
        }
    }

    private static func linked(_ path: WritableKeyPath<LinkSettings, Bool>, _ bar: SettingAccess.Bar = .free) -> SettingAccess {
        onOff(bar, read: { _ in LinkRules.shared.settings[keyPath: path] }, apply: { _, on in LinkRules.shared.set { $0[keyPath: path] = on } })
    }

    private static var linkSpaces: [Space] {
        (Browsers.linkTargets.isEmpty ? Browsers.all : Browsers.linkTargets).flatMap(\.spaces)
    }

    private static func linkSpace(_ named: String) -> UUID? {
        linkSpaces.first { $0.name.caseInsensitiveCompare(named) == .orderedSame }?.id
    }

    private static let outside = settable(takes: "front, ask or a space's name", read: { _ in
        switch LinkRules.shared.settings.outsideDefault {
        case .front: return "front"
        case .ask: return "ask"
        case .space(let id): return linkSpaces.first { $0.id == id }?.name ?? "a space that is gone"
        }
    }, check: { ["front", "ask"].contains($0.lowercased()) || linkSpace($0) != nil }) { _, text in
        switch text.lowercased() {
        case "front": LinkRules.shared.set { $0.outsideDefault = .front }
        case "ask": LinkRules.shared.set { $0.outsideDefault = .ask }
        default: if let id = linkSpace(text) { LinkRules.shared.set { $0.outsideDefault = .space(id) } }
        }
    }

    static let table: [String: SettingAccess] = [
        "links.open": outside,
        "links.choose": linked(\.chooseKey),
        "links.tracking": linked(\.cleansLinks, .turningOff),
        "links.unwrap": linked(\.unwrapsLinks, .turningOff),
        "links.openTab": linked(\.goesToOpenTab),
        "links.liveRow": linked(\.goesToLiveRow),
        "links.suggestions": row(),
        "links.try": row(),
        "links.recent": row(),
        "agents.connected": SettingAccess(bar: .always, instead: "broadway agents list reads them"),
        "agents.mode": SettingAccess(bar: .always, read: { $0.agentMode.rawValue }),
        "agents.signIn": SettingAccess(bar: .always, read: { $0.agentsAskSignIn }),
        "agents.give": held(\.agentsGivePasswords),
        "agents.sites": SettingAccess(bar: .always, instead: "broadway agents status reads them"),
        "agents.hooks": SettingAccess(bar: .always, instead: "broadway hooks list reads them"),
        "ai.agents": held(\.agentsOn),
        "ai.command": row("broadway setup"),
        "ai.groups": shared({ AIGroups.shared.on }, { AIGroups.shared.on = $0 }),
        "groups.meetings": flag(\.meetingFolders),
        "groups.openrouter": SettingAccess(bar: .always, takes: "A key only you can add or remove", read: { _ in OpenRouterKey.shared.present }),
        "ai.replies": row("broadway replies list"),
        "autocorrect": row("In the Edit menu: Spelling and Grammar"),
        "autofill.addresses": SettingAccess(bar: .always),
        "autofill.cards": SettingAccess(bar: .always),
        "autofill.profile": SettingAccess(bar: .always),
        "autofill.remembered": SettingAccess(bar: .always, read: { _ in FormAnswers.shared.siteCount }),
        "bench": row("In the View menu: Developer › Allow Scripts to Drive Broadway"),
        "bookmarks.bar": flag(\.bookmarksBar),
        "calendars": onOff(.turningOn, read: { $0.usesCalendars && Meetings.shared.hasAccess }) { _, on in
            MeetingAlertPrefs.shared.chosen = on
            if on { Task { _ = await Meetings.shared.turnOn() } } else { Meetings.shared.turnOff() }
        },
        "clear.cache": row(),
        "clear.cookies": row(),
        "clear.history": row("broadway history clear"),
        "codes.gmail": stored("codes.gmail", fallback: true),
        "downloads.folder": SettingAccess(bar: .always, read: { $0.asksWhereToSave ? "ask each time" : $0.downloads.path }),
        "field.snippets": row("broadway snippets list"),
        "languages": settable(takes: "a comma list of languages such as en-GB,pl, or mac",
                              read: { _ in LanguagePrefs.shared.chosen?.joined(separator: ",") ?? "mac" },
                              check: { PreferredLanguages.parse($0) != nil }) { _, text in
            if let parsed = PreferredLanguages.parse(text) { LanguagePrefs.shared.chosen = parsed }
        },
        "spaces.languages": row("In each space's menu: Languages"),
        "general.default": row(),
        "general.import": row(),
        Preferences.hintsKey: flag(\.hints),
        "history.pageText": held(\.remembersPageText),
        "history.freezes": row("In the Help menu: Copy Last Freeze"),
        IntegrationNow.key: onOff(read: { _ in IntegrationNow.on }) { _, on in Store.settings.set(on, forKey: IntegrationNow.key) },
        "live.folders": row("broadway live list"),
        "live.suggestions": row("broadway live add NAME SOURCE"),
        "live.offers": flag(\.suggestsLiveFolders),
        LiveEvery.key: settable(takes: LiveEvery.allCases.map { "\($0.rawValue)" }.joined(separator: ", ") + " minutes", read: { $0.liveEvery.rawValue },
                                check: { Int($0).flatMap(LiveEvery.init) != nil }) { prefs, text in
            if let every = Int(text).flatMap(LiveEvery.init) { prefs.liveEvery = every }
        },
        "live.offers.again": row(),
        "look": choice(\.look),
        "app.icon": choice(\.appIcon),
        "meetings.calendars": SettingAccess(bar: .always, read: { _ in
            let skipped = MeetingAlertPrefs.shared.skipped.count
            return skipped == 0 ? "all" : "all but \(skipped)"
        }),
        "meetings.spaces": SettingAccess(bar: .always, read: { _ in
            let places = MeetingSpacePlaces.shared
            let set = places.accounts.count + places.calendars.count
            return set == 0 ? "any space" : "\(set) chosen"
        }),
        "meetings.faces": SettingAccess(bar: .always, read: { _ in ContactFaces.on ? "from Contacts" : "initials" },
                                        instead: "Turn on People's photos in Settings › General › Calendars. Only the person can let Broadway read Contacts."),
        "newtab.floating": flag(\.floatingNewTab),
        "note.answers": alwaysOn,
        "note.awake": alwaysOn,
        "note.flick": always(\.floatFlicks),
        "note.floatkeys": alwaysOn,
        "note.groups": alwaysOn,
        "note.json": alwaysOn,
        "note.links": always(\.showsLinks),
        "note.panel": alwaysOn,
        "note.pinback": alwaysOn,
        "note.sharedpins": alwaysOn,
        "note.sitesearch": alwaysOn,
        "note.split": alwaysOn,
        "note.switcher": alwaysOn,
        "note.translate": alwaysOn,
        "notifications.ask": flag(\.siteNotifications, .turningOn),
        "pageZoom": settable(takes: "a percent from 50 to 300", read: { Int(($0.pageZoom * 100).rounded()) },
                             check: { Double($0).map { Preferences.zooms.contains($0 / 100) } == true }) { prefs, text in
            if let percent = Double(text) { prefs.pageZoom = percent / 100 }
        },
        "pages.dusk": flag(\.darkensPages),
        "video.quality": settable(takes: VideoQuality.takes, read: { $0.videoQuality.raw }, check: { VideoQuality.Choice(raw: $0) != nil }) { prefs, text in
            if let choice = VideoQuality.Choice(raw: text) { prefs.videoQuality = choice }
        },
        "video.speed": flag(\.remembersSpeed),
        Preferences.miniKey: flag(\.miniPlayer),
        Preferences.miniSkipKey: settable(takes: "10, 15 or 30", read: { $0.miniSkip }, check: { Int($0).map { MiniRule.skips.contains($0) } == true }) { prefs, text in
            if let seconds = Int(text) { prefs.miniSkip = seconds }
        },
        Preferences.miniSpokenKey: settable(takes: "seconds or tracks", read: { $0.miniSpoken.rawValue }, check: { MiniSpoken(rawValue: $0) != nil }) { prefs, text in
            if let spoken = MiniSpoken(rawValue: text) { prefs.miniSpoken = spoken }
        },
        Preferences.miniSpeedKey: flag(\.miniSpeed),
        "updates.version": SettingAccess(bar: .noControl, read: { _ in Updates.shared.line }, instead: "In the Broadway menu: Check for Updates…"),
        "updates.check": settable(.turningOff, takes: "true or false", read: { _ in Updates.shared.checks }, check: { Updates.runs && yes($0) != nil }) { _, text in
            if let on = yes(text) { Updates.shared.checks = on }
        },
        "updates.install": settable(.turningOff, takes: "true or false", read: { _ in Updates.shared.installs }, check: { Updates.runs && yes($0) != nil }) { _, text in
            if let on = yes(text) { Updates.shared.installs = on }
        },
        "support.email": row("In the Help menu: Contact Support"),
        PullRefresh.key: flag(\.pullsToRefresh),
        "passwords.apple": AppleHelper.available ? held(\.applePasswords) : SettingAccess(bar: .soon, read: { _ in false }),
        "passwords.fill": held(\.fillsAndSavesPasswords),
        "passwords.never": SettingAccess(bar: .always, read: { _ in Vault.never.count }),
        "passwords.onepassword": SettingAccess(bar: .always, read: { $0.onePassword }),
        "passwords.open": SettingAccess(bar: .always, instead: "broadway logins list reads who is kept, never a password"),
        "privacy.forget": row("broadway permissions reset SITE"),
        "privacy.permissions": row("broadway permissions list"),
        "app.openAtLogin": SettingAccess(takes: "true or false", read: { _ in OpenAtLogin.on }, write: { _, text in
            guard let on = yes(text) else { return false }
            if OpenAtLogin.on != on { try? OpenAtLogin.items.set(on) }
            return OpenAtLogin.on == on
        }, check: { yes($0) != nil }, failure: "macOS keeps login items in System Settings › General › Login Items"),
        "quit.confirm": flag(\.confirmsQuit),
        "routes": row("broadway links list"),
        "search.engine": settable(takes: Engine.allCases.filter { $0 != .custom }.map(\.rawValue).joined(separator: ", "), read: { $0.engine.rawValue },
                                  check: { Engine(rawValue: $0).map { $0 != .custom } == true }) { prefs, text in
            if let engine = Engine(rawValue: text) { prefs.engine = engine }
        },
        "search.keywords": row("broadway keywords list"),
        "search.quickactions": row("broadway actions list"),
        "search.shortcuts": row("broadway keywords list, broadway actions list and broadway snippets list"),
        "search.suggest": flag(\.engineSuggests, .turningOn),
        "shield": flag(\.shielded, .turningOff),
        "shortcuts": row("broadway shortcuts list"),
        "sidebar.button": flag(\.sideButton),
        "sidebar.selected": flag(\.selectedShortcut),
        "sites.keep": onOff(.turningOff, read: { !$0.keepsSignIns }, apply: { $0.keepsSignIns = !$1 }),
        "space.look": row("broadway spaces colour SPACE COLOUR"),
        "spaces.stacked": flag(\.stackedSpaces),
        "tabs.close.after": settable(takes: TabLife.allCases.map { "\($0.rawValue)" }.joined(separator: ", ") + " hours", read: { $0.tabLife.rawValue },
                                     check: { Int($0).flatMap(TabLife.init) != nil }) { prefs, text in
            if let life = Int(text).flatMap(TabLife.init) { prefs.tabLife = life }
        },
        "tabs.layout": choice(\.tabsLayout),
    ]

    static func refusal(_ id: String, value: String) -> PersonRefusal? {
        guard let item = SettingsIndex.item(id), let access = table[id] else { return PersonRefusal.missing("setting", id) }
        let place = "Settings › \(item.page.title) › \(item.title)"
        let on = yes(value)
        switch access.bar {
        case .free:
            break
        case .always:
            return .person("\(item.title) can only be changed by the person", where: place)
        case .noControl:
            return PersonRefusal("refused", "\(item.title) has nothing to set here", hint: instead(id))
        case .soon:
            return PersonRefusal("refused", "\(item.title) isn't available yet")
        case .turningOff:
            if on == false { return .person("Turning off \(item.title) weakens what protects the person, so only they can", where: place) }
        case .turningOn:
            if on == true { return .person("Turning on \(item.title) sends more of the person's data somewhere, so only they can", where: place) }
        }
        if id == "search.engine", value == Engine.custom.rawValue {
            return .person("A custom search address sees every search, so only the person can set one", where: place)
        }
        return nil
    }

    static func setForTests(_ id: String, _ text: String, on prefs: Preferences) -> Bool {
        guard Store.testing, let access = table[id], access.check?(text) ?? true else { return false }
        return access.write?(prefs, text) == true
    }

    static func canSet(_ access: SettingAccess) -> Bool {
        access.write != nil && [.free, .turningOff, .turningOn].contains(access.bar)
    }

    static func changes(_ access: SettingAccess?) -> String {
        switch access?.bar {
        case .free?: "this command"
        case .always?: "only the person, in Broadway"
        case .turningOff?: "true here, false only the person"
        case .turningOn?: "false here, true only the person"
        case .noControl?: "nothing to set here"
        case .soon?: "not available yet"
        case nil: ""
        }
    }

    static func instead(_ id: String) -> String? {
        guard let access = table[id] else { return nil }
        if let instead = access.instead { return instead }
        guard access.bar == .noControl, let item = SettingsIndex.item(id) else { return nil }
        return "In Settings › \(item.page.title): broadway settings open \(id)"
    }

    static func about(_ id: String) -> [String: Any] {
        let access = table[id]
        var found: [String: Any] = ["takes": access.map { canSet($0) ? $0.takes : "" } ?? "", "changes": changes(access)]
        if let instead = instead(id) { found["instead"] = instead }
        return found
    }

    struct Change {
        var item: SettingsItem
        var access: SettingAccess
        var value: String
    }

    static func planned(_ call: PersonCall) throws -> [Change] {
        let words = [try call.need("setting"), try call.need("value")] + call.strings("values")
        let several = words.count > 2
        func whole(_ refused: PersonRefusal) -> PersonRefusal {
            guard several else { return refused }
            var told = refused
            told.message = "\(refused.message). Nothing was changed."
            return told
        }
        guard words.count.isMultiple(of: 2) else {
            throw PersonRefusal.usage("\(words.last ?? "") has no value. Nothing was changed.", hint: "Give each setting its value: broadway settings set look dark pageZoom 110")
        }
        var seen = Set<String>()
        return try stride(from: 0, to: words.count, by: 2).map { at in
            let id = words[at]
            let text = words[at + 1]
            guard seen.insert(id).inserted else { throw PersonRefusal.usage("\(id) is named twice. Nothing was changed.") }
            if let refused = refusal(id, value: text) { throw whole(refused) }
            guard let item = SettingsIndex.item(id), let access = table[id], access.write != nil else {
                throw whole(PersonRefusal("refused", "\(id) has nothing to set here", hint: instead(id)))
            }
            guard access.check?(text) ?? true else { throw whole(PersonRefusal.usage("\(id) takes \(access.takes), not \(text)")) }
            return Change(item: item, access: access, value: text)
        }
    }

    private static func value(_ item: SettingsItem, _ prefs: Preferences, shown: Bool) -> Any {
        guard shown else { return "" }
        return table[item.id]?.read(prefs) ?? ""
    }

    private static func rows(_ items: [SettingsItem], _ call: PersonCall) -> [[String: Any]] {
        items.map { item in
            ["id": item.id, "title": item.title, "page": item.page.rawValue, "value": value(item, call.browser.prefs, shown: call.box.open)]
                .merging(about(item.id)) { mine, _ in mine }
        }
    }

    static func shown(_ item: SettingsItem) -> String {
        switch item.id {
        case "ai.groups": return AIGroups.shared.sends
        case "groups.openrouter":
            let key = OpenRouterKey.shared
            return AIGroupWords.keyLine(state: key.state, trouble: key.trouble)
        default: return item.detail
        }
    }

    private static func item(_ call: PersonCall) throws -> SettingsItem {
        let id = try call.need("setting")
        guard let found = SettingsIndex.item(id) else {
            throw PersonRefusal.missing("setting", id)
        }
        return found
    }

    private static func keys(_ text: String) -> KeyCombo? {
        var pieces = text.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        if text.hasSuffix("+") { pieces.append("+") }
        guard let key = pieces.popLast(), !key.isEmpty else { return nil }
        var command = false, shift = false, option = false, control = false
        for piece in pieces {
            switch piece {
            case "cmd", "command", "⌘": command = true
            case "shift", "⇧": shift = true
            case "opt", "option", "alt", "⌥": option = true
            case "ctrl", "control", "⌃": control = true
            default: return nil
            }
        }
        return KeyCombo(key, command: command, shift: shift, option: option, control: control)
    }

    private static func command(_ call: PersonCall) throws -> Command {
        let id = try call.need("shortcut")
        guard let found = Command.named(id) else {
            throw PersonRefusal.missing("command", id)
        }
        return found
    }

    static var commands: [Command] { Command.all }

    private static func installed(_ call: PersonCall) throws -> Installed {
        let wanted = try call.need("id").lowercased()
        let found = Extensions.shared.installed.filter { $0.id.lowercased().hasPrefix(wanted) || $0.name.lowercased() == wanted }
        if found.count > 1 { throw PersonRefusal.ambiguous("id", wanted, found.count) }
        guard let only = found.first else { throw PersonRefusal.missing("extension", wanted) }
        return only
    }

    private static func origins() -> [(origin: String, entry: SitePermissions.Entry)] {
        let every = Store.settings.dictionaryRepresentation()
        let origins = Set(every.keys.compactMap { key -> String? in
            guard key.hasPrefix("capture."), let bar = key.firstIndex(of: "|") else { return nil }
            return String(key["capture.".endIndex..<bar])
        })
        return origins.sorted().flatMap { origin in SitePermissions.entries(for: origin, in: every).map { (origin, $0) } }
    }

    static let verbs: [PersonVerb] = [
        PersonVerb("settings", "list", .open) { call in
            var items = SettingsIndex.items
            if let page = call.string("page") {
                guard let wanted = SettingsPage.named(page) else {
                    throw PersonRefusal("not_found", "No such settings page: \(page)", hint: "Pages: \(SettingsPage.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                items = items.filter { $0.page == wanted }
            }
            if call.flag("can-set") { items = items.filter { table[$0.id].map(canSet) == true } }
            return ["settings": rows(items, call)]
        },
        PersonVerb("settings", "find", .open) { call in
            ["settings": rows(SettingsIndex.find(call.strings("words").joined(separator: " ")), call)]
        },
        PersonVerb("settings", "get", .look) { call in
            let found = try item(call)
            let data: [String: Any] = ["id": found.id, "title": found.title, "detail": shown(found), "page": found.page.rawValue, "value": value(found, call.browser.prefs, shown: true)]
            return data.merging(about(found.id)) { mine, _ in mine }
        },
        PersonVerb("settings", "set", .arrange, first: { _ = try planned($0) }) { call in
            let prefs = call.browser.prefs
            var done: [[String: Any]] = []
            let planned = try planned(call)
            for change in planned.filter({ $0.access.failure != nil }) + planned.filter({ $0.access.failure == nil }) {
                let was = value(change.item, prefs, shown: true)
                guard change.access.write?(prefs, change.value) == true else {
                    let said = done.isEmpty ? "\(change.item.title) couldn't be changed, so nothing was" : "\(change.item.title) couldn't be changed. The settings before it were."
                    throw PersonRefusal("failed", said, hint: change.access.failure ?? "Look with broadway settings get \(change.item.id) before you try again")
                }
                done.append(["id": change.item.id, "was": was, "value": value(change.item, prefs, shown: true)])
            }
            guard done.count > 1 else {
                return ["id": done.first?["id"] ?? "", "value": done.first?["value"] ?? "", "message": "Changed"]
            }
            return ["settings": done, "message": "Changed \(done.count) settings"]
        },
        PersonVerb("settings", "open", .arrange) { call in
            let found = try call.string("setting") == nil ? nil : item(call)
            call.browser.openSettings(found?.page ?? call.browser.settingsPage)
            return ["message": "Open in Broadway"]
        },
        PersonVerb("shortcuts", "list", .look) { call in
            let store = ShortcutStore.shared
            let query = call.string("query")?.lowercased()
            let found = commands.filter { query == nil || $0.title.lowercased().contains(query ?? "") || $0.id.lowercased().contains(query ?? "") }
            return ["shortcuts": found.map {
                ["id": $0.id, "key": store.key(for: $0.id)?.display ?? "", "title": $0.title, "section": $0.section.rawValue, "changed": store.isChanged($0.id)] as [String: Any]
            }]
        },
        PersonVerb("shortcuts", "set", .arrange) { call in
            let found = try command(call)
            let typed = try call.need("keys")
            guard let combo = keys(typed), combo.isUsable else { throw PersonRefusal.usage("Keys look like cmd+shift+k, with ⌘, ⌥, ⌃ or a function key.") }
            if let reason = KeyCombo.reserved(combo) { throw PersonRefusal("refused", "\(combo.display): \(reason)") }
            let store = ShortcutStore.shared
            let other = store.owner(of: combo, except: found.id)
            store.assign(combo, to: found.id)
            return ["id": found.id, "key": combo.display, "notice": other.map { "Taken from \($0.title)" } ?? ""]
        },
        PersonVerb("shortcuts", "clear", .arrange, names: { call in
            let found = try command(call)
            return PersonAsk.line(found.title, ShortcutStore.shared.key(for: found.id)?.display)
        }) { call in
            let found = try command(call)
            ShortcutStore.shared.clear(found.id)
            return ["id": found.id, "message": "No key now"]
        },
        PersonVerb("shortcuts", "reset", .arrange) { call in
            if call.flag("all") {
                ShortcutStore.shared.resetAll()
                return ["message": "Every key is back"]
            }
            guard call.string("shortcut") != nil else { throw PersonRefusal.usage("Name a command, or --all") }
            let found = try command(call)
            ShortcutStore.shared.reset(found.id)
            return ["id": found.id, "key": ShortcutStore.shared.key(for: found.id)?.display ?? ""]
        },
        PersonVerb("extensions", "list", .look) { _ in
            ["extensions": Extensions.shared.installed.map {
                ["id": $0.id, "name": $0.name, "version": $0.version, "enabled": $0.enabled, "fromStore": $0.fromStore] as [String: Any]
            }]
        },
        PersonVerb("extensions", "show", .look) { call in
            let found = try installed(call)
            return ["id": found.id, "name": found.name, "version": found.version, "enabled": found.enabled, "fromStore": found.fromStore, "permissions": found.permissions]
        },
        PersonVerb("extensions", "enable", .arrange) { call in
            let found = try installed(call)
            Extensions.shared.setEnabled(found.id, true)
            return ["id": found.id, "message": "On"]
        },
        PersonVerb("extensions", "disable", .arrange) { call in
            let found = try installed(call)
            Extensions.shared.setEnabled(found.id, false)
            return ["id": found.id, "message": "Off"]
        },
        PersonVerb("extensions", "reload", .arrange) { call in
            let found = try installed(call)
            Extensions.shared.reload(found.id)
            return ["id": found.id, "message": "Reloaded"]
        },
        PersonVerb("extensions", "remove", .erase, first: { _ = try installed($0) }, names: { try installed($0).name }) { call in
            let found = try installed(call)
            Extensions.shared.remove(found.id)
            return ["id": found.id, "message": "Removed"]
        },
        PersonVerb("extensions", "install", .arrange) { call in
            let link = try call.need("link")
            guard let id = Crx.id(in: link) else { throw PersonRefusal.usage("That isn't a Chrome Web Store link or extension id") }
            guard !Extensions.shared.installed.contains(where: { $0.id == id }) else { throw PersonRefusal("refused", "That extension is already installed") }
            Extensions.shared.install(from: link, confirm: true)
            return ["id": id, "message": "Broadway asks the person there, and shows what it wants"]
        },
        PersonVerb("extensions", "private", .open) { _ in
            throw PersonRefusal.person("Whether an extension runs in private windows is the person's to say", where: "Settings › Extensions")
        },
        PersonVerb("shields", "list", .look) { call in
            ["on": call.browser.prefs.shielded, "lists": true, "trouble": Shield.shared.trouble ?? "",
             "lists_trouble": ShieldLists.shared.trouble ?? "", "lists_checked": PersonCommands.stamp(ShieldLists.shared.saved.checked),
             "sites": Shield.shared.paused.sorted().map { ["site": $0] }]
        },
        PersonVerb("shields", "on", .arrange) { call in
            let typed = try call.need("host").lowercased().trimmingCharacters(in: .whitespaces)
            let host = typed.hasPrefix("www.") ? String(typed.dropFirst(4)) : typed
            guard Shield.shared.isPaused(on: host) else { return ["site": host, "message": "Already on for \(host)"] }
            Shield.shared.pause(host, false)
            return ["site": host, "message": "On for \(host)"]
        },
        PersonVerb("shields", "off", .open) { _ in
            throw PersonRefusal.person("Turning the blocker off for a site is the person's to say", where: "the site's controls, beside the address")
        },
        PersonVerb("shields", "update", .arrange) { _ in
            let lists = ShieldLists.shared
            await lists.refresh(force: true)
            return ["message": lists.trouble ?? "The filter lists are up to date", "lists_trouble": lists.trouble ?? "",
                    "lists_checked": PersonCommands.stamp(lists.saved.checked), "rules": lists.saved.rules]
        },
        PersonVerb("permissions", "list", .look) { call in
            let wanted = call.string("site")?.lowercased()
            let found = origins().filter { wanted == nil || $0.origin.lowercased().contains(wanted ?? "") }
            return ["permissions": found.map { ["site": $0.origin, "kind": $0.entry.name, "allowed": $0.entry.allowed] as [String: Any] }]
        },
        PersonVerb("permissions", "reset", .arrange) { call in
            let wanted = try call.need("site").lowercased()
            let kind = call.string("kind")?.lowercased()
            let found = origins().filter { $0.origin.lowercased().contains(wanted) && (kind == nil || $0.entry.name.lowercased() == kind) }
            guard !found.isEmpty else { throw PersonRefusal.missing("permission", wanted) }
            found.forEach { SitePermissions.forget($0.entry) }
            return ["reset": found.count, "message": "Forgotten. The site has to ask again."]
        },
        PersonVerb("permissions", "allow", .open) { _ in
            throw PersonRefusal.person("A site asks and the person answers", where: "the question on the page")
        },
        PersonVerb("hooks", "list", .look) { _ in
            let book = HookBook.shared
            return ["hooks": book.hooks.map { hook in
                ["id": PersonCommands.short(hook.id), "event": hook.event.rawValue, "program": hook.path, "on": hook.on,
                 "result": book.line(hook), "said": book.results[hook.id]?.said ?? ""] as [String: Any]
            }]
        },
    ]
}

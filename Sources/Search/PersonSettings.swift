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
}

@MainActor
enum PersonSettings {
    private static func yes(_ text: String) -> Bool? {
        ["true": true, "on": true, "yes": true, "1": true, "false": false, "off": false, "no": false, "0": false][text.lowercased()]
    }

    private static func flag(_ path: ReferenceWritableKeyPath<Preferences, Bool>, _ bar: SettingAccess.Bar = .free) -> SettingAccess {
        SettingAccess(bar: bar, takes: "true or false", read: { $0[keyPath: path] }, write: { prefs, text in
            guard let on = yes(text) else { return false }
            prefs[keyPath: path] = on
            return true
        })
    }

    private static func held(_ path: KeyPath<Preferences, Bool>) -> SettingAccess {
        SettingAccess(bar: .always, read: { $0[keyPath: path] })
    }

    private static func choice<Value: CaseIterable & RawRepresentable>(_ path: ReferenceWritableKeyPath<Preferences, Value>) -> SettingAccess where Value.RawValue == String {
        SettingAccess(takes: Value.allCases.map(\.rawValue).joined(separator: ", "), read: { $0[keyPath: path].rawValue }, write: { prefs, text in
            guard let value = Value(rawValue: text) else { return false }
            prefs[keyPath: path] = value
            return true
        })
    }

    private static func stored(_ key: String, fallback: Bool) -> SettingAccess {
        SettingAccess(bar: .always, read: { _ in Store.settings.object(forKey: key) as? Bool ?? fallback })
    }

    private static func row(_ text: String, instead: String? = nil) -> SettingAccess {
        SettingAccess(bar: .noControl, takes: text, instead: instead)
    }

    private static func always(_ path: KeyPath<Preferences, Bool>) -> SettingAccess {
        SettingAccess(bar: .noControl, takes: "Always there", read: { $0[keyPath: path] })
    }

    private static func shared(_ read: @escaping @MainActor () -> Bool, _ write: @escaping @MainActor (Bool) -> Void) -> SettingAccess {
        SettingAccess(bar: .turningOn, takes: "true or false", read: { _ in read() }, write: { _, text in
            guard let on = yes(text) else { return false }
            write(on)
            return true
        })
    }

    private static func number(_ path: ReferenceWritableKeyPath<Preferences, Int>, within range: ClosedRange<Int>) -> SettingAccess {
        SettingAccess(takes: "a whole number from \(range.lowerBound) to \(range.upperBound)", read: { $0[keyPath: path] }, write: { prefs, text in
            guard let value = Int(text), range.contains(value) else { return false }
            prefs[keyPath: path] = value
            return true
        })
    }

    private static func linked(_ path: WritableKeyPath<LinkSettings, Bool>, _ bar: SettingAccess.Bar = .free) -> SettingAccess {
        SettingAccess(bar: bar, takes: "true or false", read: { _ in LinkRules.shared.settings[keyPath: path] }, write: { _, text in
            guard let on = yes(text) else { return false }
            LinkRules.shared.set { $0[keyPath: path] = on }
            return true
        })
    }

    private static let outside = SettingAccess(takes: "front or ask", read: { _ in
        switch LinkRules.shared.settings.outsideDefault {
        case .front: return "front"
        case .ask: return "ask"
        case .space(let id): return Browsers.linkTargets.flatMap(\.spaces).first { $0.id == id }?.name ?? "a space that is gone"
        }
    }, write: { _, text in
        switch text.lowercased() {
        case "front": LinkRules.shared.set { $0.outsideDefault = .front }
        case "ask": LinkRules.shared.set { $0.outsideDefault = .ask }
        default: return false
        }
        return true
    })

    static let table: [String: SettingAccess] = [
        "links.open": outside,
        "links.choose": linked(\.chooseKey),
        "links.tracking": linked(\.cleansLinks, .turningOff),
        "links.unwrap": linked(\.unwrapsLinks, .turningOff),
        "links.openTab": linked(\.goesToOpenTab),
        "links.liveRow": linked(\.goesToLiveRow),
        "links.suggestions": row("In Broadway"),
        "links.try": row("In Broadway"),
        "links.recent": row("In Broadway"),
        "agents.connected": SettingAccess(bar: .always, instead: "broadway agents list reads them"),
        "agents.mode": SettingAccess(bar: .always, read: { $0.agentMode.rawValue }),
        "agents.sites": SettingAccess(bar: .always, instead: "broadway agents status reads them"),
        "ai.agents": held(\.agentsOn),
        "ai.actions": SettingAccess(bar: .turningOn, takes: "true or false", read: { $0.textActions }, write: { prefs, text in
            guard let on = yes(text) else { return false }
            TextActions.set(on, prefs)
            return true
        }),
        "ai.ask": SettingAccess(bar: .turningOn, takes: "true or false", read: { $0.askAndChat }, write: { prefs, text in
            guard let on = yes(text) else { return false }
            PageAsk.set(on, prefs)
            return true
        }),
        "ai.plan": SettingAccess(bar: .always, read: { Plans.shared.agent($0)?.rawValue ?? "" }),
        "ai.command": row("The broadway command", instead: "broadway setup"),
        "ai.groups": shared({ AIGroups.shared.on }, { AIGroups.shared.on = $0 }),
        "groups.meetings": flag(\.meetingFolders),
        "groups.openrouter": SettingAccess(bar: .always, takes: "A key only you can add or remove", read: { _ in OpenRouterKey.shared.present }),
        "ai.replies": row("From the page", instead: "broadway replies"),
        "autocorrect": row("In Edit › Spelling and Grammar"),
        "autofill.addresses": SettingAccess(bar: .always),
        "autofill.cards": SettingAccess(bar: .always),
        "autofill.profile": SettingAccess(bar: .always),
        "autofill.remembered": SettingAccess(bar: .always, read: { _ in FormAnswers.shared.siteCount }),
        "bench": row("In View › Developer"),
        "bookmarks.bar": row("In the Bookmarks menu"),
        "calendars": SettingAccess(bar: .turningOn, takes: "true or false", read: { $0.usesCalendars && Meetings.shared.hasAccess },
                                   write: { _, text in
            guard let on = yes(text) else { return false }
            MeetingAlertPrefs.shared.chosen = on
            if on { Task { _ = await Meetings.shared.turnOn() } } else { Meetings.shared.turnOff() }
            return true
        }),
        "clear.cache": row("In Broadway"),
        "clear.cookies": row("In Broadway"),
        "clear.history": row("A button", instead: "broadway history clear"),
        "codes.gmail": stored("codes.gmail", fallback: true),
        "downloads.folder": SettingAccess(bar: .always, read: { $0.asksWhereToSave ? "ask each time" : $0.downloads.path }),
        "field.snippets": row("Your snippets"),
        "languages": SettingAccess(bar: .free, takes: "a comma list of languages such as en-GB,pl, or mac",
                                   read: { _ in LanguagePrefs.shared.chosen?.joined(separator: ",") ?? "mac" },
                                   write: { _, text in
            guard let parsed = PreferredLanguages.parse(text) else { return false }
            LanguagePrefs.shared.chosen = parsed
            return true
        }),
        "spaces.languages": row("In the space's menu"),
        "general.default": row("In Broadway"),
        "general.import": row("In Broadway"),
        "history.pageText": held(\.remembersPageText),
        IntegrationNow.key: SettingAccess(takes: "true or false", read: { _ in IntegrationNow.on }, write: { _, text in
            guard let on = yes(text) else { return false }
            Store.settings.set(on, forKey: IntegrationNow.key)
            return true
        }),
        "live.folders": row("In Broadway", instead: "broadway live list"),
        "live.suggestions": row("In Broadway", instead: "broadway live add NAME SOURCE"),
        "live.offers": flag(\.suggestsLiveFolders),
        "live.offers.again": row("In Broadway"),
        "look": choice(\.look),
        "app.icon": choice(\.appIcon),
        "meetings.calendars": SettingAccess(bar: .always, read: { _ in
            let skipped = MeetingAlertPrefs.shared.skipped.count
            return skipped == 0 ? "all" : "all but \(skipped)"
        }),
        "meetings.faces": SettingAccess(bar: .always, read: { _ in ContactFaces.on ? "from Contacts" : "initials" },
                                        instead: "Turn on People's photos in Settings › General › Calendars. Only the person can let Broadway read Contacts."),
        "newtab.floating": flag(\.floatingNewTab),
        "note.answers": row("Always there"),
        "note.awake": row("Always there"),
        "note.flick": always(\.floatFlicks),
        "note.floatkeys": row("Always there"),
        "note.groups": row("Always there"),
        "note.json": row("Always there"),
        "note.links": always(\.showsLinks),
        "note.panel": row("Always there"),
        "note.pinback": row("Always there"),
        "note.sharedpins": row("Always there"),
        "note.sitesearch": row("Always there"),
        "note.split": row("Always there"),
        "note.switcher": row("Always there"),
        "note.translate": row("Always there"),
        "notifications.ask": flag(\.siteNotifications, .turningOn),
        "pageZoom": SettingAccess(takes: "a percent from 50 to 300", read: { Int(($0.pageZoom * 100).rounded()) }, write: { prefs, text in
            guard let percent = Double(text), Preferences.zooms.contains(percent / 100) else { return false }
            prefs.pageZoom = percent / 100
            return true
        }),
        "pages.dusk": row("In the View menu"),
        "video.quality": SettingAccess(takes: VideoQuality.takes, read: { $0.videoQuality.raw }, write: { prefs, text in
            guard let choice = VideoQuality.Choice(raw: text) else { return false }
            prefs.videoQuality = choice
            return true
        }),
        "video.speed": flag(\.remembersSpeed),
        Preferences.miniKey: flag(\.miniPlayer),
        Preferences.miniSkipKey: SettingAccess(takes: "10, 15 or 30", read: { $0.miniSkip }, write: { prefs, text in
            guard let seconds = Int(text), MiniRule.skips.contains(seconds) else { return false }
            prefs.miniSkip = seconds
            return true
        }),
        Preferences.miniSpokenKey: SettingAccess(takes: "seconds or tracks", read: { $0.miniSpoken.rawValue }, write: { prefs, text in
            guard let spoken = MiniSpoken(rawValue: text) else { return false }
            prefs.miniSpoken = spoken
            return true
        }),
        Preferences.miniSpeedKey: flag(\.miniSpeed),
        "updates.version": SettingAccess(bar: .noControl, takes: "Broadway › Check for Updates…", read: { _ in Updates.shared.line }),
        "updates.check": SettingAccess(bar: .turningOff, takes: "true or false", read: { _ in Updates.shared.checks }, write: { _, text in
            guard Updates.runs, let on = yes(text) else { return false }
            Updates.shared.checks = on
            return true
        }),
        "updates.install": SettingAccess(bar: .turningOff, takes: "true or false", read: { _ in Updates.shared.installs }, write: { _, text in
            guard Updates.runs, let on = yes(text) else { return false }
            Updates.shared.installs = on
            return true
        }),
        "support.email": row("Help › Contact Support"),
        PullRefresh.key: flag(\.pullsToRefresh),
        "passwords.apple": AppleHelper.available ? held(\.applePasswords) : SettingAccess(bar: .soon, read: { _ in false }),
        "passwords.fill": held(\.fillsAndSavesPasswords),
        "passwords.never": SettingAccess(bar: .always, read: { _ in Vault.never.count }),
        "passwords.open": SettingAccess(bar: .always, instead: "broadway logins list reads who is kept, never a password"),
        "privacy.forget": row("Site by site", instead: "broadway permissions reset"),
        "privacy.permissions": row("Site by site", instead: "broadway permissions"),
        "quit.confirm": row("In the Broadway menu"),
        "routes": row("In Broadway"),
        "search.engine": SettingAccess(takes: Engine.allCases.filter { $0 != .custom }.map(\.rawValue).joined(separator: ", "), read: { $0.engine.rawValue }, write: { prefs, text in
            guard let engine = Engine(rawValue: text), engine != .custom else { return false }
            prefs.engine = engine
            return true
        }),
        "search.keywords": row("In Broadway"),
        "search.quickactions": row("In Broadway"),
        "search.shortcuts": row("In Broadway"),
        "search.suggest": flag(\.engineSuggests, .turningOn),
        "shield": flag(\.shielded, .turningOff),
        "shortcuts": row("In Broadway", instead: "broadway shortcuts"),
        "sidebar.button": flag(\.sideButton),
        "sites.keep": flag(\.keepsSignIns, .turningOff),
        "space.look": row("In each space's menu"),
        "spaces.stacked": flag(\.stackedSpaces),
        "tabs.close.after": SettingAccess(takes: TabLife.allCases.map { "\($0.rawValue)" }.joined(separator: ", ") + " hours", read: { $0.tabLife.rawValue }, write: { prefs, text in
            guard let life = Int(text).flatMap(TabLife.init) else { return false }
            prefs.tabLife = life
            return true
        }),
        "tabs.layout": row("In the View menu"),
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
            guard let instead = access.instead else { return PersonRefusal("refused", "\(item.title) has nothing to set here") }
            return PersonRefusal("refused", "\(item.title) has nothing to set here. Use \(instead).")
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

    private static func value(_ item: SettingsItem, _ prefs: Preferences, shown: Bool) -> Any {
        guard shown else { return "" }
        return table[item.id]?.read(prefs) ?? ""
    }

    private static func rows(_ items: [SettingsItem], _ call: PersonCall) -> [[String: Any]] {
        items.map { ["id": $0.id, "title": $0.title, "page": $0.page.rawValue, "value": value($0, call.browser.prefs, shown: call.box.open)] }
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
                guard let wanted = SettingsPage.named(page) else { throw PersonRefusal.missing("settings page", page) }
                items = items.filter { $0.page == wanted }
            }
            return ["settings": rows(items, call)]
        },
        PersonVerb("settings", "find", .open) { call in
            ["settings": rows(SettingsIndex.find(call.strings("words").joined(separator: " ")), call)]
        },
        PersonVerb("settings", "get", .look) { call in
            let found = try item(call)
            let access = table[found.id]
            var data: [String: Any] = ["id": found.id, "title": found.title, "detail": found.detail, "page": found.page.rawValue, "value": value(found, call.browser.prefs, shown: true)]
            switch access?.bar {
            case .always: data["changes"] = "only the person, in Broadway"
            case .noControl: data["changes"] = "nothing to set"
            case .soon: data["changes"] = "not available yet"
            case .turningOff: data["changes"] = "true here, false only the person"
            case .turningOn: data["changes"] = "false here, true only the person"
            default: data["changes"] = access?.takes ?? ""
            }
            return data
        },
        PersonVerb("settings", "set", .arrange, first: { call in
            if let refused = refusal(try call.need("setting"), value: try call.need("value")) { throw refused }
        }) { call in
            let found = try item(call)
            let text = try call.need("value")
            guard let access = table[found.id], let write = access.write else {
                throw PersonRefusal("refused", "\(found.title) has nothing to set here")
            }
            guard write(call.browser.prefs, text) else { throw PersonRefusal.usage("\(found.id) takes \(access.takes), not \(text)") }
            return ["id": found.id, "value": value(found, call.browser.prefs, shown: true), "message": "Changed"]
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
            if KeyCombo.isReserved(combo) { throw PersonRefusal("refused", "\(combo.display) is taken by macOS") }
            let store = ShortcutStore.shared
            let other = store.owner(of: combo, except: found.id)
            store.assign(combo, to: found.id)
            return ["id": found.id, "key": combo.display, "notice": other.map { "Taken from \($0.title)" } ?? ""]
        },
        PersonVerb("shortcuts", "clear", .arrange) { call in
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
        PersonVerb("extensions", "remove", .erase, first: { _ = try installed($0) }) { call in
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
            ["on": call.browser.prefs.shielded, "lists": call.browser.prefs.shieldLists, "trouble": Shield.shared.trouble ?? "",
             "sites": Shield.shared.paused.sorted().map { ["site": $0] }]
        },
        PersonVerb("shields", "on", .arrange) { call in
            let host = try call.need("host").lowercased()
            Shield.shared.pause(host, false)
            return ["site": host, "message": "On for \(host)"]
        },
        PersonVerb("shields", "off", .open) { _ in
            throw PersonRefusal.person("Turning the blocker off for a site is the person's to say", where: "the site's controls, beside the address")
        },
        PersonVerb("shields", "update", .arrange) { _ in
            Task { await ShieldLists.shared.refresh(force: true) }
            return ["message": "Fetching the lists"]
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
    ]
}

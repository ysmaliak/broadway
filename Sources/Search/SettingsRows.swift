import AppKit

extension SettingsPageView {
    @discardableResult
    func settingRow(_ id: String) -> Bool {
        let prefs = prefs
        let browser = browser
        let updates = Updates.shared
        switch id {
        case "general.default": defaultBrowserRow()
        case "general.import": row(id, control: button("Bring Things Over") { browser.lead(to: InternalPage(.importing)) })
        case Preferences.hintsKey: flag(id, \.hints)
        case "downloads.folder":
            let folder = SettingsFolderPopUp(prefs: prefs)
            update { [weak folder] in folder?.show() }
            folder.kitAccess(id: "settings.downloads.folder", label: "Downloads folder")
            row(id, control: SettingsPopUp(folder), detail: {
                prefs.asksWhereToSave ? "A save sheet asks for each download" : "Where downloads go"
            })
        case "updates.version": updatesVersionRow()
        case "updates.check": row(id, control: toggle(id, get: { updates.checks }, set: { updates.checks = $0 }))
        case "updates.install": row(id, control: toggle(id, get: { updates.installs }, set: { updates.installs = $0 }))
        case "support.email": row(id, control: button("Email Support") { Support.write { browser.announce($0) } })
        case "calendars": calendarsRow()
        case "meetings.calendars": row(id, control: SettingsCalendars(), wide: true)
        case "meetings.faces": facesRow()
        case "meetings.spaces": callSpacesRows()
        case "search.engine":
            let engines = Engine.allCases
            row(id, control: popUp(id, titles: engines.map(\.title), picked: { engines.firstIndex(of: prefs.engine) ?? 0 },
                                   set: { prefs.engine = engines[$0] }), detail: { Self.searchDetail(prefs) })
        case "search.suggest": flag(id, \.engineSuggests, detail: { Self.suggestDetail(prefs) })
        case "search.keywords": keywordsRow()
        case "field.snippets": snippetsRow()
        case "look": lookRow()
        case AppIcon.key: appIconRow()
        case "newtab.floating": newTabRow()
        case "sidebar.button": flag(id, \.sideButton)
        case "sidebar.selected": flag(id, \.selectedShortcut)
        case "notifications.ask": flag(id, \.siteNotifications)
        case "privacy.forget":
            row(id, control: button("Forget Choices…") { [weak self] in
                SettingsQuestion.siteChoices.ask(over: self?.window) { browser.forgetCaptureChoices() }
            })
        case "pageZoom":
            let zooms = Preferences.zooms
            row(id, control: popUp(id, titles: zooms.map { "\(Int(($0 * 100).rounded()))%" },
                                   picked: { zooms.firstIndex { abs($0 - prefs.pageZoom) < 0.001 } ?? zooms.firstIndex(of: 1) ?? 0 },
                                   set: { prefs.pageZoom = zooms[$0] }))
        case PullRefresh.key: flag(id, \.pullsToRefresh)
        case "video.quality": videoQualityRow()
        case "video.speed": flag(id, \.remembersSpeed)
        case "spaces.stacked":
            row(id, control: pictures(id, ["One at a Time", "All in One List"], scenes: {
                let base = WindowScene.live(prefs, browser.space.look)
                return [false, true].map { stacked in
                    var scene = base
                    scene.stacked = stacked
                    return scene
                }
            }, picked: { prefs.stackedSpaces ? 1 : 0 }, set: { prefs.stackedSpaces = $0 == 1 }), wide: true)
        case Preferences.miniKey: flag(id, \.miniPlayer)
        case Preferences.miniSkipKey: miniSkipRow()
        case Preferences.miniSpokenKey: miniSpokenRow()
        case Preferences.miniSpeedKey: flag(id, \.miniSpeed)
        case "tabs.close.after":
            let lives = TabLife.allCases
            row(id, control: popUp(id, titles: lives.map(\.title), picked: { lives.firstIndex(of: prefs.tabLife) ?? 0 },
                                   set: { prefs.tabLife = lives[$0] }))
        case "ai.groups": groupTabsRow()
        case "groups.openrouter": openRouterRow()
        case "passwords.open": row(id, control: button("Open") { browser.lead(to: InternalPage(.passwords)) })
        case "passwords.onepassword": onePasswordRow()
        case "passwords.fill":
            flag(id, \.fillsAndSavesPasswords, detail: {
                if let name = Extensions.shared.passwordSavingTakenBy {
                    return "\(name) does the saving and asked Broadway not to offer"
                }
                return SettingsIndex.item("passwords.fill")?.detail ?? ""
            })
        case "passwords.never":
            row(id, control: button("Forget…") { [weak self] in
                SettingsQuestion.neverSave(Vault.never.count).ask(over: self?.window) {
                    Vault.never = []
                    browser.announce("Every site can ask again")
                    self?.refresh()
                }
            }, detail: { SettingsIndex.neverLine(Vault.never.count) })
        case "passwords.apple": flag(id, \.applePasswords)
        case "codes.gmail":
            let book = AutofillBook.shared
            row(id, control: toggle(id, get: { book.codesFromGmail }, set: { book.codesFromGmail = $0 }))
        case "autofill.profile", "autofill.addresses", "autofill.cards", "autofill.remembered": autofillRow(id)
        case "shield":
            let shield = Shield.shared
            flag(id, \.shielded, detail: { shield.trouble ?? SettingsIndex.item("shield")?.detail ?? "" })
        case "sites.keep": row(id, control: toggle(id, get: { !prefs.keepsSignIns }, set: { prefs.keepsSignIns = !$0 }))
        case "history.pageText": flag(id, \.remembersPageText)
        case "live.offers": flag(id, \.suggestsLiveFolders)
        case LiveEvery.key:
            let paces = LiveEvery.allCases
            row(id, control: popUp(id, titles: paces.map(\.title), picked: { paces.firstIndex(of: prefs.liveEvery) ?? 0 },
                                   set: { prefs.liveEvery = paces[$0] }))
        case Preferences.meetingFoldersKey: flag(id, \.meetingFolders)
        case IntegrationNow.key:
            row(id, control: toggle(id, get: { IntegrationNow.on }, set: { Store.settings.set($0, forKey: IntegrationNow.key) }))
        case "ai.agents", "agents.mode": agentRow(id)
        case "agents.signIn": flag(id, \.agentsAskSignIn)
        case let id where Browser.Clearing(rawValue: id) != nil: dangerRow(id)
        default: return linkRow(id)
        }
        return true
    }

    func leaveSearch(for id: String) {
        guard shell.searching, let item = SettingsIndex.item(id) else { return }
        shell.lit = id
        shell.query = ""
        shell.go(to: item.page)
        unlightSoon()
    }

    func unlightSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.shell.lit = nil
            self?.kitSubviews(of: SettingsRowView.self).forEach { $0.lit = false }
        }
    }

    private func dangerRow(_ id: String) {
        guard let clearing = Browser.Clearing(rawValue: id), let item = SettingsIndex.item(id) else { return }
        let browser = browser
        let made = SettingsDangerRow(id: id, symbol: item.icon, title: clearing.row, detail: item.detail) { [weak self] in
            browser.askToClear(clearing, over: self?.window)
        }
        made.lit = shell.lit == id
        put(made)
    }

    private func defaultBrowserRow() {
        let browser = browser
        let mark = SettingsDefaultMark()
        mark.make = { [weak self] in
            Links.becomeDefault { worked in
                browser.announce(worked && Links.isDefault ? "Links now open here" : "macOS didn't change it")
                self?.refresh()
            }
        }
        update { [weak mark] in mark?.show(Links.isDefault) }
        row("general.default", control: mark, detail: {
            Links.isDefault ? "Broadway is your default browser. Lovely." : SettingsIndex.item("general.default")?.detail ?? ""
        })
    }

    private func calendarsRow() {
        let prefs = prefs
        let browser = browser
        row("calendars", control: toggle("calendars", get: { prefs.usesCalendars && Meetings.shared.hasAccess }, set: { on in
            guard on else {
                MeetingAlertPrefs.shared.chosen = false
                Meetings.shared.turnOff()
                return
            }
            Task {
                if await Meetings.shared.turnOn() {
                    MeetingAlertPrefs.shared.chosen = true
                } else {
                    browser.announce("Allow Broadway in System Settings › Privacy & Security › Calendars")
                }
            }
        }))
    }

    private func facesRow() {
        let browser = browser
        row("meetings.faces", control: toggle("meetings.faces", get: { ContactFaces.on }, set: { on in
            guard on else {
                ContactFaces.chosen = false
                return
            }
            ContactFaces.chosen = true
            Task {
                if await ContactFaces.ask() {
                    MeetingFaces.shared.forget()
                } else {
                    browser.announce("Allow Broadway in System Settings › Privacy & Security › Contacts")
                }
            }
        }), detail: { ContactFaces.on || ContactFaces.undecided ? SettingsIndex.item("meetings.faces")?.detail ?? "" : "Broadway isn't allowed to read Contacts" })
    }
}

import AppKit

@MainActor
final class SettingsDrafts {
    var profile = AutofillProfile()
    var links = ""
    var address = AutofillAddress()
    var card = ["label": "", "number": "", "expiry": "", "holder": "", "code": ""]
    var cardTrouble: String?
    var fetched: AutofillBook.Editing?
    var appleCode = ""
    var setup: [[String: Any]] = []
    var setupRuns = 0
    var busy = false
    var openRouterKey = ""
}

extension SettingsPageView {
    static let agentsNote = "Files and Terminal ask every time. When an agent asks on a site, Always Here answers for that site from then on. Hold ⌥ for Never Here."

    func agentRow(_ id: String) {
        let prefs = prefs
        guard id == "agents.mode" else {
            row(id, control: toggle(id, get: { prefs.agentsOn }, set: { prefs.agentsOn = $0 }))
            return
        }
        let modes = AgentMode.allCases
        let mode = row(id, control: choice(id, modes.map(\.title), picked: { modes.firstIndex(of: prefs.agentMode) ?? 0 },
                                           set: { [weak self] at in
                                               self?.chooseMode(modes[at])
                                               self?.refresh()
                                           }), detail: { prefs.agentMode.detail })
        update { [weak mode] in mode?.dim(!prefs.agentsOn) }
    }

    func agents() {
        let browser = browser
        let drafts = drafts
        let sites = AgentSites.shared
        let links = AgentLinks.shared
        shape { [drafts.setup.isEmpty ? "none" : AgentCommand.isSetUp(drafts.setup) ? "set" : "unset", AgentCommand.path ?? ""] }
        section(footer: Self.agentsNote) {
            settingRow("ai.agents")
            settingRow("agents.mode")
            if let path = AgentCommand.path {
                let made = AgentCommand.isSetUp(drafts.setup)
                    ? button("Remove…") { [weak self] in
                        SettingsQuestion.agentCommand.ask(over: self?.window) { self?.runCommand(["remove"], said: "broadway is removed") }
                    }
                    : button("Set Up") { [weak self] in self?.runCommand(["setup"], said: "broadway is set up") }
                update { [weak made] in made?.isEnabled = !drafts.busy }
                let command = NSStackView(views: [made])
                command.orientation = .horizontal
                row("ai.command", control: command, detail: { AgentCommand.summary(drafts.setup) })
                _ = line("Other MCP clients", "Cursor, Claude Desktop and the rest", symbol: "point.3.connected.trianglepath.dotted",
                         id: "agents.clients", control: button("Copy Config") {
                             NSPasteboard.general.clearContents()
                             NSPasteboard.general.setString(AgentCommand.mcpConfig(path: path), forType: .string)
                             browser.announce("Copied")
                         })
            }
        }
        section("In Broadway") {
            settingRow("ai.actions")
            settingRow("ai.plan")
        }
        let connected = links.live.filter { !$0.task && $0.codex == nil }
        shape { links.live.filter { !$0.task && $0.codex == nil }.map(\.id) }
        if !connected.isEmpty {
            section("Connected") {
                for link in connected {
                    let tabs = AgentBoard.allTabs(of: link.id).count
                    _ = line(link.name, tabs == 1 ? "1 tab" : "\(tabs) tabs", id: "agents.link.\(link.id)", control: button("Disconnect…") { [weak self] in
                        SettingsQuestion.agent(link.name).ask(over: self?.window) { links.end(link.id, .done(nil)) }
                    })
                }
            }
        }
        shape { sites.rules.keys.sorted() }
        if !sites.rules.isEmpty {
            section("Sites") {
                for site in sites.rules.keys.sorted() {
                    let never = sites.rules[site] == .never
                    _ = line(site, never ? "Never Here" : "Always Here", id: "agents.site." + site, control: button("Remove…") { [weak self] in
                        SettingsQuestion.agentSite(site, never: never).ask(over: self?.window) { sites.set(nil, for: site) }
                    })
                }
            }
        }
        let setup = AgentSetup.shared
        if drafts.setup.isEmpty { drafts.setupRuns = setup.runs }
        update { [weak self] in
            guard drafts.setupRuns != setup.runs else { return }
            drafts.setupRuns = setup.runs
            self?.lookAtSetup()
        }
        if drafts.setup.isEmpty { lookAtSetup() }
    }

    private func lookAtSetup() {
        let drafts = drafts
        Task { [weak self] in
            drafts.setup = await AgentCommand.helper(["doctor"])?["checks"] as? [[String: Any]] ?? []
            self?.refresh()
        }
    }

    private func chooseMode(_ mode: AgentMode) {
        let prefs = prefs
        guard mode == .bypass, prefs.agentMode != .bypass else {
            prefs.agentMode = mode
            return
        }
        Ask.sure("Let agents go ahead without asking?",
                 detail: "A page could talk an agent into sending, paying or deleting, and nothing would stop to ask you. Captchas, passkeys, card numbers and your Mac still stop for you.",
                 confirm: "Use Bypass", returnCancels: true, over: window) { prefs.agentMode = .bypass }
    }

    private func runCommand(_ words: [String], said: String) {
        let drafts = drafts
        let browser = browser
        drafts.busy = true
        refresh()
        Task { [weak self] in
            let done = await AgentCommand.helper(words) != nil
            browser.announce(done ? said : "broadway couldn't do that. Run broadway doctor.")
            drafts.setup = await AgentCommand.helper(["doctor"])?["checks"] as? [[String: Any]] ?? []
            drafts.busy = false
            self?.refresh()
        }
    }

    func pair(_ first: NSView, _ second: NSView) -> NSStackView {
        let made = NSStackView(views: [first, second])
        made.orientation = .horizontal
        made.spacing = 6
        return made
    }
}

extension SettingsPageView {
    func applePairing() {
        let prefs = prefs
        let apple = ApplePasswords.shared
        let drafts = drafts
        shape { [prefs.applePasswords ? "on" : "off", String(describing: apple.state)] }
        guard AppleHelper.available, prefs.applePasswords else { return }
        switch apple.state {
        case .idle:
            _ = line(apple.trouble ?? "Not connected",
                     "Your Mac shows a code and you type it here. Pair once per launch, the first time you want an account: Connect Apple Passwords… under a sign-in box starts it.",
                     id: "apple.pairing", control: button("Connect…") { Task { await apple.connect() } })
        case .starting:
            _ = line("Connecting…", "Waiting for your Mac to show a code", id: "apple.pairing")
        case .code, .checking:
            drafts.appleCode = ""
            let send = {
                guard drafts.appleCode.count == 6, apple.state == .code else { return }
                let typed = drafts.appleCode
                drafts.appleCode = ""
                Task { await apple.enter(typed) }
            }
            let code = field("Code", text: { drafts.appleCode }, prompt: "000000", width: 84, submit: send) { typed in
                drafts.appleCode = String(typed.filter(\.isNumber).prefix(6))
                if drafts.appleCode.count == 6 { send() }
            }
            code.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            code.isEnabled = apple.state == .code
            let controls = NSStackView(views: [code, button("OK", primary: true, act: send), button("Cancel") { apple.disconnect() }])
            controls.orientation = .horizontal
            controls.spacing = 8
            _ = line("Enter the code your Mac shows", apple.state == .checking ? "Checking…" : "Six digits, from the Passwords window",
                     id: "apple.pairing", control: controls)
            if apple.state == .code {
                DispatchQueue.main.async { [weak code] in code?.window?.makeFirstResponder(code) }
            }
        case .paired:
            _ = line("Connected", "Until Broadway quits. Accounts show under sign-in boxes, marked Apple Passwords. macOS may ask for Touch ID before filling a password.",
                     id: "apple.pairing", control: button("Disconnect…") { [weak self] in
                         SettingsQuestion.applePasswords.ask(over: self?.window) { apple.disconnect() }
                     })
        }
    }

    func autofill() {
        let book = AutofillBook.shared
        let drafts = drafts
        shape { [String(describing: book.editing), book.hasProfile ? "p" : "", book.addresses.map(\.id).joined(), book.cards.map(\.id).joined()] }
        let editing = book.editing
        if editing != drafts.fetched {
            drafts.fetched = editing
            drafts.cardTrouble = nil
            drafts.card = drafts.card.mapValues { _ in "" }
            switch editing {
            case .profile:
                drafts.profile = AutofillProfile()
                Task { [weak self] in
                    drafts.profile = await book.fetchedProfile()
                    drafts.links = drafts.profile.links.joined(separator: " ")
                    self?.refresh()
                }
            case .address(let id):
                drafts.address = AutofillAddress()
                if let id {
                    Task { [weak self] in
                        if let kept = await book.fetched(address: id) { drafts.address = kept }
                        self?.refresh()
                    }
                }
            default: break
            }
        }
        autofillRow("autofill.profile")
        if editing == .profile {
            let fields: [(String, WritableKeyPath<AutofillProfile, String>)] = [
                ("Name", \.name), ("Email", \.email), ("Phone", \.phone), ("Company", \.company), ("Role", \.role), ("Location", \.location),
            ]
            for (title, path) in fields {
                labeled(title, field(title, text: { drafts.profile[keyPath: path] }, prompt: "", set: { drafts.profile[keyPath: path] = $0 }))
            }
            labeled("Links", field("Links", text: { drafts.links }, prompt: "", set: { drafts.links = $0 }))
            editorButtons(save: {
                drafts.profile.links = drafts.links.split(whereSeparator: \.isWhitespace).map(String.init)
                book.save(profile: drafts.profile)
                book.editing = nil
            }, cancel: { book.editing = nil })
        }
        autofillRow("autofill.addresses")
        if editing == .address(nil) { addressEditor(nil) }
        for kept in book.addresses {
            if editing == .address(kept.id) {
                addressEditor(kept.id)
            } else {
                _ = line(kept.note, "Saved in your keychain", id: "autofill.address." + kept.id, control: button("Edit") { book.editing = .address(kept.id) })
            }
        }
        autofillRow("autofill.cards")
        if editing == .card(nil) { cardEditor() }
        for card in book.cards {
            let made = line(card.title, card.label.isEmpty ? nil : card.label, id: "autofill.card." + card.id, control: button("Forget…") { [weak self] in
                SettingsQuestion.card(card.title).ask(over: self?.window) { book.forget(card: card.id) }
            })
            made.setAccessibilityLabel(card.title)
        }
        autofillRow("autofill.remembered")
    }

    func autofillRow(_ id: String) {
        let book = AutofillBook.shared
        let open: (AutofillBook.Editing) -> Void = { [weak self] wanted in
            self?.leaveSearch(for: id)
            book.editing = book.editing == wanted ? nil : wanted
        }
        switch id {
        case "autofill.profile": row(id, control: button(book.hasProfile ? "Edit" : "Add") { open(.profile) })
        case "autofill.addresses": row(id, control: button("Add") { open(.address(nil)) })
        case "autofill.cards": row(id, control: button("Add") { open(.card(nil)) })
        default:
            let answers = FormAnswers.shared
            Task { [weak self] in
                await answers.ready()
                self?.refresh()
            }
            let forget = button("Forget All…") { [weak self] in FormAnswers.askToForgetAll(answers, over: self?.window) { self?.refresh() } }
            update { [weak forget] in forget?.isEnabled = answers.siteCount > 0 }
            row(id, control: forget, detail: { FormAnswers.sitesLine(answers.siteCount) })
        }
    }

    private func addressEditor(_ id: String?) {
        let book = AutofillBook.shared
        let drafts = drafts
        let fields: [(String, WritableKeyPath<AutofillAddress, String>)] = [
            ("Label", \.label), ("Name", \.name), ("Company", \.company), ("Street", \.line1), ("Apartment", \.line2), ("City", \.city),
            ("State", \.region), ("Postal code", \.postal), ("Country", \.country), ("Phone", \.phone),
        ]
        for (title, path) in fields {
            labeled(title, field(title, text: { drafts.address[keyPath: path] }, prompt: "", set: { drafts.address[keyPath: path] = $0 }))
        }
        editorButtons(save: {
            guard book.save(address: drafts.address) else { return }
            book.editing = nil
        }, cancel: { book.editing = nil }, remove: id.map { id in { [weak self] in
            let name = book.addresses.first { $0.id == id }?.note ?? ""
            SettingsQuestion.address(name).ask(over: self?.window) {
                book.forget(address: id)
                book.editing = nil
            }
        } })
    }

    private func cardEditor() {
        let book = AutofillBook.shared
        let drafts = drafts
        let fields: [(String, String, Bool)] = [
            ("Label", "label", false), ("Number", "number", true), ("Expires", "expiry", false), ("Name on card", "holder", false),
            ("Security code", "code", true),
        ]
        for (title, key, secret) in fields {
            labeled(title, field(title, text: { drafts.card[key] ?? "" }, prompt: "", secure: secret, set: { drafts.card[key] = $0 }))
        }
        if let trouble = drafts.cardTrouble { note(trouble) }
        editorButtons(save: { [weak self] in
            let number = drafts.card["number"] ?? ""
            let code = drafts.card["code"] ?? ""
            let digits = CardNumber.digits(code)
            if !CardNumber.valid(number) {
                drafts.cardTrouble = "That isn't a card number"
            } else if let expires = CardExpiry(drafts.card["expiry"] ?? "") {
                if !(code.isEmpty || (3...4).contains(digits.count) && digits.count == code.count) {
                    drafts.cardTrouble = "A security code is three or four digits"
                } else if !book.save(card: CardSecret(number: number, expiry: expires, holder: drafts.card["holder"] ?? "", securityCode: digits),
                                     label: drafts.card["label"] ?? "") {
                    drafts.cardTrouble = "The keychain wouldn't save it"
                } else {
                    drafts.card = drafts.card.mapValues { _ in "" }
                    book.editing = nil
                    return
                }
            } else {
                drafts.cardTrouble = "Use MM/YY for the expiry"
            }
            self?.rebuild()
        }, cancel: {
            drafts.card = drafts.card.mapValues { _ in "" }
            book.editing = nil
        })
    }

    private func editorButtons(save: @escaping () -> Void, cancel: @escaping () -> Void, remove: (() -> Void)? = nil) {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        if let remove { bar.addArrangedSubview(SettingsPill("Forget…", kind: .destructive, action: remove)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bar.addArrangedSubview(spacer)
        bar.addArrangedSubview(button("Cancel", act: cancel))
        bar.addArrangedSubview(button("Save", primary: true, act: save))
        let holder = SettingsRowView(id: "editor.buttons", symbol: nil, title: "", control: bar)
        holder.title.isHidden = true
        put(holder)
    }

    func snippetsRow() {
        let store = SnippetStore.shared
        row("field.snippets", control: button("Add Snippet…") { [weak self] in
            SettingsEditors.snippet(Snippet(), store: store, over: self?.window)
        })
    }

    func snippets() {
        let store = SnippetStore.shared
        snippetsRow()
        shape { store.snippets.map { "\($0.id)|\($0.title)|\($0.keyword)" } }
        for snippet in store.snippets {
            let edit = button("Edit…") { [weak self] in SettingsEditors.snippet(snippet, store: store, over: self?.window) }
            edit.kitAccess(label: "Edit \(snippet.title)")
            let delete = SettingsPill("Delete…", kind: .destructive) { [weak self] in
                SettingsQuestion.snippet(snippet.title, keyword: snippet.keyword).ask(over: self?.window) {
                    if let trouble = store.delete(snippet.id) { self?.browser.announce(trouble) }
                }
            }
            delete.kitAccess(label: "Delete \(snippet.title)")
            _ = line(snippet.title, ";" + snippet.keyword, id: "snippet.\(snippet.id)", control: pair(edit, delete))
        }
    }
}

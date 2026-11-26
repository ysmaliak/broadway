import AppKit

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
            settingRow("agents.signIn")
            settingRow("agents.give")
        }
        let signIns = AgentSignIns.shared
        shape { sites.rules.keys.sorted() + signIns.allowed.keys.sorted().flatMap { [$0] + (signIns.allowed[$0] ?? []) } }
        if !sites.rules.isEmpty || !signIns.allowed.isEmpty {
            section("Sites") {
                for site in sites.rules.keys.sorted() {
                    let never = sites.rules[site] == .never
                    _ = line(site, never ? "Never Here" : "Always Here", id: "agents.site." + site, control: button("Remove…") { [weak self] in
                        SettingsQuestion.agentSite(site, never: never).ask(over: self?.window) { sites.set(nil, for: site) }
                    })
                }
                let names = AgentSignInNames.names(for: signIns.allowed)
                for site in signIns.sites {
                    for digest in signIns.allowed[site] ?? [] {
                        let name = names[digest]
                        _ = line(site, name.map { "Signs in as \($0) without asking" } ?? "Signs in without asking, with a sign-in that is gone",
                                 id: "agents.signIn." + site + "." + digest, control: button("Remove…") { [weak self] in
                            SettingsQuestion.agentSite(site, never: false).ask(over: self?.window) { signIns.remove(digest, site: site) }
                        })
                    }
                }
            }
        }
        let connected = links.live.filter { $0.codex == nil }
        shape { links.live.filter { $0.codex == nil }.map(\.id) }
        if !connected.isEmpty {
            section("Connected") {
                for link in connected {
                    let tabs = AgentBoard.allTabs(of: link.id).count
                    let count = tabs == 1 ? "1 tab" : "\(tabs) tabs"
                    _ = line(link.title, link.program?.detail.map { "\($0) · \(count)" } ?? count, id: "agents.link.\(link.id)", control: button("Disconnect…") { [weak self] in
                        SettingsQuestion.agent(link.title).ask(over: self?.window) { links.end(link.id, .done(nil)) }
                    })
                }
            }
        }
        if let path = AgentCommand.path {
            section("Command line") {
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

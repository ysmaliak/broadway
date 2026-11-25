import AppKit
import BroadwayCLI
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PersonGiveTests {
    private var browser: Browser!
    private var socket: AgentSocket!
    private var made: [UUID] = []
    private var heard: [[String: Any]] = []
    private var asking = 0
    private let passwords = ["sam@example.com": "hunter2-swordfish", "work@example.com": "tr0mbone-otter"]
    private let testing = Ask.testing

    init() throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        keepSetting(Shared.prefs, \.agentsGivePasswords, "agents.give")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        socket = AgentSocket()
        socket.box.browser = browser
        browser.prefs.agentMode = .auto
        browser.prefs.agentsOn = true
        browser.prefs.agentsGivePasswords = true
        AgentSites.shared.reset()
        Ask.testing = true
    }

    private func tearDown() {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
        AgentSites.shared.reset()
        Ask.testing = testing
        browser?.closeAll()
        browser = nil
    }

    private func session() -> UUID {
        let link = AgentLinks.shared.join(.named(UUID().uuidString), name: "Claude Code")
        TaskLedger.shared.open(link.id, title: "Claude Code")
        AgentLinks.shared.setPatience(link.id, 30)
        made.append(link.id)
        return link.id
    }

    private func keep(_ users: [String], host: String = "example.com") {
        socket.box.logins = { _ in users.map { Kept(host: host, user: $0, used: nil) } }
        socket.box.loginSecret = { [passwords] kept in Login(host: kept.host, user: kept.user, password: passwords[kept.user] ?? "x-password-x", used: nil) }
    }

    private func give(_ site: String = "example.com", _ more: [String: Any] = [:], link: UUID?, request extra: [String: Any] = [:]) -> Task<[String: Any], Never> {
        var arguments: [String: Any] = ["site": site]
        arguments.merge(more) { _, new in new }
        var request: [String: Any] = ["op": "do", "noun": "logins", "verb": "give", "arguments": arguments, "wait": 30.0]
        request.merge(extra) { _, new in new }
        let browser = browser!
        let socket = socket!
        return Task { @MainActor in
            await PersonCommands.perform(request, browser: browser, socket: socket, channel: PersonChannel { [weak self] event in
                MainActor.assumeIsolated { self?.heard.append(event) }
            }) { link.flatMap { AgentLinks.shared.link($0) } }
        }
    }

    private func asked(after seen: UUID? = nil) async -> AgentQuestion? {
        for _ in 0..<600 {
            if let front = AgentDesk.shared.front, front.id != seen { return front }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }
    private func hint(_ reply: [String: Any]) -> String { (reply["error"] as? [String: Any])?["hint"] as? String ?? "" }
    private func message(_ reply: [String: Any]) -> String { (reply["error"] as? [String: Any])?["message"] as? String ?? "" }
    private func data(_ reply: [String: Any]) -> [String: Any] { reply["data"] as? [String: Any] ?? [:] }

    private func written(_ reply: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    @Test func withTheSwitchOffNothingIsAskedOrSaidAboutWhatIsKept() async throws {
        browser.prefs.agentsGivePasswords = false
        let link = session()
        keep(["sam@example.com"])
        let kept = await give(link: link).value
        keep([])
        let none = await give(link: link).value
        let bare = await give(link: nil).value

        #expect(code(kept) == "person_only", "\(kept)")
        #expect(hint(kept).contains("Settings › Agents › Let agents ask for a saved password"), "\(kept)")
        #expect(written(kept) == written(none))
        #expect(written(kept) == written(bare))
        #expect(!written(kept).contains("sam@example.com"))
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func theSwitchIsOffUntilThePersonTurnsItOn() throws {
        keepSettings("agents.give")
        Store.settings.removeObject(forKey: "agents.give")
        let fresh = Preferences()
        fresh.agentsGivePasswords = true
        let after = Preferences()

        #expect(!Preferences().agentsGivePasswords || after.agentsGivePasswords)
        #expect(after.agentsGivePasswords)
        Store.settings.removeObject(forKey: "agents.give")
        #expect(!Preferences().agentsGivePasswords)
    }

    @Test func theSwitchIsThePersonsAndSaysWhatItMeans() async throws {
        browser.prefs.agentsGivePasswords = false
        let link = session()
        let item = try #require(SettingsIndex.item("agents.give"))
        let set = await PersonCommands.perform(["noun": "settings", "verb": "set", "arguments": ["setting": "agents.give", "value": "true"]],
                                               browser: browser, socket: socket, channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }

        #expect(item.title == "Let agents ask for a saved password")
        #expect(item.detail == "An agent that gets a password can read it. Broadway asks with Touch ID every time.")
        #expect(item.group == "agents")
        #expect(code(set) == "person_only", "\(set)")
        #expect(PersonSettings.table["agents.give"]?.bar == .always)
        #expect(!browser.prefs.agentsGivePasswords)
    }

    @Test func fromAnotherMachineItIsRefusedBeforeAnything() async throws {
        let link = session()
        keep(["sam@example.com"])
        let forwarded = await give(link: link, request: ["agent": ["remote": true]]).value
        let viaSSH = await give(link: nil, request: ["agent": ["id": "ssh:10.0.0.2/claude", "name": "Claude Code"]]).value
        let carried = await give(link: link, request: ["over_ssh": true]).value
        AgentLinks.shared.setRemote(link)
        let remote = await give(link: link).value
        browser.prefs.agentsGivePasswords = false
        let off = await give(link: link).value

        for said in [forwarded, viaSSH, carried, remote, off] {
            #expect(code(said) == "person_only", "\(said)")
            #expect(message(said).contains("Only on the Mac that runs Broadway"), "\(said)")
            #expect(!written(said).contains("sam@example.com"))
        }
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func overMCPThereIsNoSuchToolAndMoreToolsSaysWhy() async throws {
        let link = session()
        keep(["sam@example.com"])
        let mcp = MCPServer(box: AgentSessionBox(socket: socket, browser: browser), task: link) { [weak self] message in
            MainActor.assumeIsolated { self?.heard.append(message) }
        }
        let browser = browser!
        let socket = socket!
        mcp.person = { tool, arguments in await PersonTools.call(tool, arguments, link: link, browser: browser, socket: socket) }
        let names = mcp.everything().compactMap { $0["name"] as? String }
        asking += 1
        mcp.handle(["jsonrpc": "2.0", "id": asking, "method": "tools/call", "params": ["name": MCPServer.moreTools, "arguments": ["query": "password"]] as [String: Any]])
        var more: [String: Any]?
        for _ in 0..<1000 where more == nil {
            more = heard.first { $0["id"] as? Int == asking }?["result"] as? [String: Any]
            try? await Task.sleep(for: .milliseconds(5))
        }
        let said = ((more?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let direct = await give(link: link, request: ["op": NSNull()]).value

        #expect(!names.contains { $0.contains("give") || $0.hasPrefix("logins") }, "\(names)")
        #expect(PersonTools.tool("logins_give") == nil)
        #expect(said.contains("broadway logins give"), "\(said)")
        #expect(said.contains("MCP"), "\(said)")
        #expect(code(direct) == "refused", "\(direct)")
        #expect(!written(direct).contains("hunter2-swordfish"))
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func theCardAsksInEveryModeAndNamesTheAgentAndItsSigner() async throws {
        let link = session()
        AgentLinks.shared.sign(link, .developer("Anthropic PBC"))
        AgentLinks.shared.asked(link, question: UUID())
        keep(["sam@example.com"])
        for mode in AgentMode.allCases {
            browser.prefs.agentMode = mode
            let reply = give(link: link)
            let question = try #require(await asked(), "\(mode)")
            let words = question.cardWords
            AgentDesk.shared.take(question.id, .no)
            let said = await reply.value

            #expect(question.title == "Give Claude Code the password for example.com?", "\(mode)")
            #expect(words.body == "It will be able to read the password of sam@example.com", "\(mode)")
            #expect(words.signer == "Claude Code, signed by Anthropic PBC", "\(mode)")
            #expect(!question.offersAlways, "\(mode)")
            #expect(code(said) == "said_no", "\(said)")
        }
    }

    @Test func aYesAndTouchIDGiveTheNameAndPasswordAndNothingElseHoldsThem() async throws {
        let link = session()
        keep(["sam@example.com"])
        let reply = give(link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value
        let answer = data(said)

        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(answer["user"] as? String == "sam@example.com")
        #expect(answer["password"] as? String == "hunter2-swordfish")
        #expect(!(answer["message"] as? String ?? "").contains("hunter2-swordfish"))
        #expect(!"\(heard)".contains("hunter2-swordfish"))
        #expect(!question.title.contains("hunter2") && !question.quote.contains("hunter2"))
        #expect(browser.announcement == nil)
        #expect(AgentLinks.shared.link(link)?.last?.contains("hunter2") != true)
    }

    @Test func aSealedPasswordStillComesBackWhole() async throws {
        let link = session()
        let sealed = "sealed-" + UUID().uuidString
        socket.box.logins = { _ in [Kept(host: "example.com", user: "work@example.com", used: nil)] }
        socket.box.loginSecret = { Login(host: $0.host, user: $0.user, password: sealed, used: nil) }
        AgentSeals.keep(sealed)
        let reply = give(link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value

        #expect(data(said)["password"] as? String == sealed, "\(said)")
    }

    @Test func withoutTouchIDNothingIsGiven() async throws {
        Ask.testing = false
        let link = session()
        keep(["sam@example.com"])
        let reply = give(link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value

        #expect(code(said) == "said_no", "\(said)")
        #expect(!written(said).contains("hunter2-swordfish"))
    }

    @Test func severalAccountsAreRowsAndAPickGivesThatOne() async throws {
        let link = session()
        keep(["sam@example.com", "work@example.com"])
        let reply = give(link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .picked(1))
        let said = await reply.value

        #expect(question.choices == ["sam@example.com", "work@example.com"])
        #expect(question.cardWords.body == "It will be able to read the password you pick")
        #expect(data(said)["user"] as? String == "work@example.com", "\(said)")
        #expect(data(said)["password"] as? String == "tr0mbone-otter")
    }

    @Test func anAccountNarrowsTheCardToOne() async throws {
        let link = session()
        keep(["sam@example.com", "work@example.com"])
        let reply = give("example.com", ["account": "work@example.com"], link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value

        #expect(question.choices.isEmpty)
        #expect(question.cardWords.body == "It will be able to read the password of work@example.com")
        #expect(data(said)["password"] as? String == "tr0mbone-otter", "\(said)")
    }

    @Test func everyCallAsksAgain() async throws {
        let link = session()
        keep(["sam@example.com"])
        var seen: UUID?
        for _ in 0..<2 {
            let reply = give(link: link)
            let question = try #require(await asked(after: seen))
            seen = question.id
            AgentDesk.shared.take(question.id, .yes)
            let said = await reply.value
            #expect(said["ok"] as? Bool == true, "\(said)")
        }
        let quiet = await give(link: link, request: ["person": "none"]).value
        #expect(code(quiet) == "needs_you", "\(quiet)")
    }

    @Test func theAnswerBeforeAYesIsTheSameKeptOrNot() async throws {
        let link = session()
        var answers: [[String: Any]] = []
        var unreached: [[String: Any]] = []
        for users in [["sam@example.com"], ["sam@example.com", "work@example.com"], []] {
            keep(users)
            let reply = give(link: link)
            let question = try #require(await asked())
            AgentDesk.shared.take(question.id, .no)
            answers.append(await reply.value)
            unreached.append(await give(link: link, request: ["person": "none"]).value)
        }

        for said in answers { #expect(written(said) == written(answers[0]), "\(said)") }
        for said in unreached { #expect(written(said) == written(unreached[0]), "\(said)") }
        #expect(code(answers[0]) == "said_no")
        #expect(code(unreached[0]) == "needs_you")
    }

    @Test func nothingKeptIsSaidOnTheCardAndOnlyAfterTheYes() async throws {
        let link = session()
        keep([])
        let reply = give(link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value

        #expect(question.cardWords.body == "Broadway keeps no password for example.com")
        #expect(code(said) == "nothing_kept", "\(said)")
    }

    @Test func onlyTheSiteAskedForIsOffered() async throws {
        let link = session()
        socket.box.logins = { _ in [Kept(host: "accounts.example.com", user: "other@example.com", used: nil),
                                    Kept(host: "www.example.com", user: "sam@example.com", used: nil)] }
        socket.box.loginSecret = { Login(host: $0.host, user: $0.user, password: "hunter2-swordfish", used: nil) }
        let reply = give("https://example.com/login", link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .no)
        _ = await reply.value

        #expect(question.title == "Give Claude Code the password for example.com?")
        #expect(question.cardWords.body == "It will be able to read the password of sam@example.com")
    }

    @Test func withNoneForTheHostAnotherHostOfTheSiteIsOfferedByName() async throws {
        let link = session()
        socket.box.logins = { _ in [Kept(host: "idmsa.apple.com", user: "sam@example.com", used: nil), Kept(host: "icloud.com", user: "other@example.com", used: nil)] }
        socket.box.loginSecret = { Login(host: $0.host, user: $0.user, password: "hunter2-swordfish", used: nil) }
        let reply = give("appleid.apple.com", link: link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value

        #expect(question.title == "Give Claude Code the password for appleid.apple.com?")
        #expect(question.cardWords.body == "It will be able to read the password of sam@example.com on idmsa.apple.com")
        #expect(data(said)["site"] as? String == "idmsa.apple.com", "\(said)")
        #expect(data(said)["user"] as? String == "sam@example.com")
    }

    @Test func aSiteThatIsNotAnAddressIsRefused() async throws {
        let link = session()
        keep(["sam@example.com"])
        for site in ["not a site", "javascript:alert(1)", "file:///etc/passwd", ""] {
            let said = await give(site, link: link).value
            #expect(code(said) == "usage", "\(site): \(said)")
        }
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aNeverHereSiteIsLeftAlone() async throws {
        let link = session()
        keep(["sam@example.com"])
        AgentSites.shared.set(.never, for: "example.com")
        let said = await give(link: link).value

        #expect(code(said) == "never_here", "\(said)")
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func accountNamesStayOffWhatAnAgentReads() async throws {
        let link = session()
        keep(["sam@example.com", "work@example.com"])
        let reply = give(link: link)
        let question = try #require(await asked())
        let listed = await PersonCommands.perform(["noun": "approvals", "verb": "list"], browser: browser, socket: socket,
                                                  channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }
        let status = await PersonCommands.perform(["noun": "agents", "verb": "status"], browser: browser, socket: socket,
                                                  channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }
        AgentDesk.shared.take(question.id, .no)
        let said = await reply.value

        for text in [written(listed), written(status), written(said), question.title, question.quote, "\(heard)"] {
            #expect(!text.contains("sam@example.com") && !text.contains("work@example.com"), "\(text)")
        }
    }

    @Test func aGiveIsRecordedWithTheSignInAndWordedForThePerson() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let at = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 14, minute: 2)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 25, hour: 9)))
        let given = AgentUse(agent: "Claude Code", folder: "garden", at: at, given: true)
        let used = AgentUse(agent: "Claude Code", folder: "garden", at: at)
        let row: [String: Any] = [kSecAttrServer as String: "appleid.apple.com", kSecAttrAccount as String: "sam@example.com", kSecAttrDescription as String: given.stored]

        #expect(given.words(now: now, calendar: calendar) == "Given to Claude Code in garden, 24 November 14:02")
        #expect(AgentUse(stored: given.stored) == given)
        #expect(AgentUse(stored: used.stored) == used)
        #expect(AgentUse(stored: used.stored)?.given == false)
        #expect(AgentUse(stored: used.stored + "\u{1}other") == nil)
        #expect(Vault.kept(from: row)?.agent?.given == true)
    }

    private var mcpAsked = 0

    private func server(_ link: UUID) -> MCPServer {
        let made = MCPServer(box: AgentSessionBox(socket: socket, browser: browser), task: link) { [weak self] message in
            MainActor.assumeIsolated { self?.heard.append(message) }
        }
        let browser = browser!
        let socket = socket!
        made.person = { tool, arguments in await PersonTools.call(tool, arguments, link: link, browser: browser, socket: socket) }
        return made
    }

    private func mcp(_ server: MCPServer, _ name: String, _ arguments: [String: Any] = [:]) async -> [String: Any] {
        mcpAsked += 1
        let id = 9000 + mcpAsked
        server.handle(["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": name, "arguments": arguments] as [String: Any]])
        for _ in 0..<1000 {
            if let found = heard.first(where: { $0["id"] as? Int == id }) { return found }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return [:]
    }

    private func refused(_ reply: [String: Any]) -> [String: Any] {
        let result = reply["result"] as? [String: Any]
        return (result?["_meta"] as? [String: Any])?[MCPServer.errorKey] as? [String: Any] ?? [:]
    }

    private func said(_ reply: [String: Any]) -> String {
        ((reply["result"] as? [String: Any])?["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private func perform(_ noun: String, _ verb: String, _ arguments: [String: Any], link: UUID) async -> [String: Any] {
        await PersonCommands.perform(["op": "do", "noun": noun, "verb": verb, "arguments": arguments], browser: browser, socket: socket,
                                     channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }
    }

    private func noCard() async -> Bool {
        try? await Task.sleep(for: .milliseconds(300))
        return AgentDesk.shared.front == nil
    }

    @Test func logins_giveIsRefusedOverMCPAndSaysWhy() async {
        let link = session()
        keep(["sam@example.com"])
        let server = server(link)
        let reply = await mcp(server, "logins_give", ["site": "example.com"])

        #expect(refused(reply)["code"] as? String == "person_only", "\(reply)")
        #expect(said(reply).contains("never given over MCP"), "\(reply)")
        #expect(!written(reply).contains("hunter2-swordfish"))
        #expect(await noCard())
    }

    @Test func moreToolsDoesNotOpenLoginsGive() async {
        let link = session()
        keep(["sam@example.com"])
        let server = server(link)
        let more = await mcp(server, "more_tools", ["query": "logins give"])
        let reply = await mcp(server, "logins_give", ["site": "example.com"])

        #expect(said(more).contains(PersonGive.mcpLine), "\(more)")
        #expect(!written(more).contains("\"logins_give\""), "\(more)")
        #expect(refused(reply)["code"] as? String == "person_only", "\(reply)")
        #expect(!written(reply).contains("hunter2-swordfish"))
        #expect(await noCard())
    }

    @Test func anMCPBatchStepCannotGiveAPassword() async {
        let link = session()
        keep(["sam@example.com"])
        let server = server(link)
        let reply = await mcp(server, "batch", ["steps": [["tool": "logins_give", "arguments": ["site": "example.com"]]]])

        #expect(refused(reply)["code"] as? String == "person_only", "\(reply)")
        #expect(said(reply).contains("never given over MCP"), "\(reply)")
        #expect(!written(reply).contains("hunter2-swordfish"))
        #expect(await noCard())
    }

    @Test func theSwitchIsThePersonsOverTheCommandLine() async {
        let link = session()
        browser.prefs.agentsGivePasswords = false
        let look = browser.prefs.look
        let one = await perform("settings", "set", ["setting": "agents.give", "value": "true"], link: link)
        let several = await perform("settings", "set", ["setting": "look", "value": look == .dark ? "light" : "dark", "values": ["agents.give", "true"]], link: link)

        #expect(code(one) == "person_only", "\(one)")
        #expect(code(several) == "person_only", "\(several)")
        #expect(message(several).hasSuffix("Nothing was changed."), "\(several)")
        #expect(browser.prefs.look == look)
        #expect(!browser.prefs.agentsGivePasswords)
        #expect(await noCard())
    }

    @Test func theSwitchIsThePersonsOverMCP() async {
        let link = session()
        browser.prefs.agentsGivePasswords = false
        let look = browser.prefs.look
        let server = server(link)
        let one = await mcp(server, "settings_set", ["setting": "agents.give", "value": "true"])
        let several = await mcp(server, "settings_set", ["setting": "look", "value": look == .dark ? "light" : "dark", "values": ["agents.give", "true"]])

        #expect(refused(one)["code"] as? String == "person_only", "\(one)")
        #expect(refused(several)["code"] as? String == "person_only", "\(several)")
        #expect(browser.prefs.look == look)
        #expect(!browser.prefs.agentsGivePasswords)
        #expect(await noCard())
    }

    @Test func theSwitchIsNotListedAsSomethingAnAgentCanSet() async {
        let link = session()
        let listed = await perform("settings", "list", ["can-set": true], link: link)
        let ids = (data(listed)["settings"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }

        #expect(!ids.isEmpty, "\(listed)")
        #expect(!ids.contains("agents.give"))
        #expect(ids.contains("look"))
    }

    @Test func aLaterFillDoesNotHideAGive() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let given = AgentUse(agent: "Claude Code", folder: "garden", at: at, given: true)
        let filled = AgentUse(agent: "Codex", folder: nil, at: at.addingTimeInterval(60))

        #expect(!filled.notes(over: given))
        #expect(filled.notes(over: filled))
        #expect(filled.notes(over: nil))
        #expect(given.notes(over: given))
        #expect(given.notes(over: filled))
    }

    @Test func onlyAGiveOnThisMacWithTheSwitchOnMakesASession() {
        let asked: [String: Any] = ["noun": "logins", "verb": "give"]

        #expect(PersonGive.creates(asked, on: true))
        #expect(!PersonGive.creates(asked, on: false))
        #expect(!PersonGive.creates(asked.merging(["over_ssh": true]) { _, new in new }, on: true))
        #expect(!PersonGive.creates(asked.merging(["agent": ["remote": true]]) { _, new in new }, on: true))
        #expect(!PersonGive.creates(asked.merging(["agent": ["id": "ssh:10.0.0.2"]]) { _, new in new }, on: true))
        #expect(!PersonGive.creates(["noun": "logins", "verb": "list"], on: true))
    }

    @Test func aPeerUnderSshOrMoshIsCarried() {
        let table: [Int32: AgentAncestor.Process] = [
            900: .init(parent: 800, name: "broadway", started: 9), 800: .init(parent: 700, name: "zsh", started: 8),
            700: .init(parent: 600, name: "sshd-session", started: 7), 600: .init(parent: 1, name: "sshd", started: 6),
            500: .init(parent: 400, name: "broadway", started: 5), 400: .init(parent: 300, name: "claude", started: 4),
            300: .init(parent: 1, name: "Terminal", started: 3),
            200: .init(parent: 100, name: "broadway", started: 2), 100: .init(parent: 1, name: "mosh-server", started: 1),
        ]

        #expect(PersonGive.carried(900) { table[$0] })
        #expect(!PersonGive.carried(500) { table[$0] })
        #expect(PersonGive.carried(200) { table[$0] })
        #expect(!PersonGive.carried(0) { table[$0] })
        #expect(PersonGive.stamp(["noun": "logins", "verb": "give", "over_ssh": true], peer: 0)["over_ssh"] as? Bool == false)
        #expect(PersonGive.stamp(["noun": "logins", "verb": "list"], peer: 0)["over_ssh"] == nil)
    }
}

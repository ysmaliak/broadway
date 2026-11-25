import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentSignInTests {
    private var browser: Browser!
    private var socket: AgentSocket!
    private var server: LocalPageServer!
    private var made: [UUID] = []
    private var heard: [[String: Any]] = []
    private let passwords = ["sam@example.com": "hunter2-swordfish", "work@example.com": "tr0mbone-otter"]

    private static let form = "<!doctype html><title>Sign in</title><form action='/landed' method='get'><input name=email autocomplete=username><input id=p name=pw type=password autocomplete=current-password><button type=submit>Sign in</button></form>"
    private static let landed = "<!doctype html><title>Home</title><h1>Welcome back</h1><p>Your projects</p>"
    private static let wrong = "<!doctype html><title>Sign in</title><p>Wrong password</p><form action='/landed' method='get'><input name=email autocomplete=username><input id=p name=pw type=password><button type=submit>Sign in</button></form>"
    private static let code = "<!doctype html><title>Check</title><form action='/landed' method='get'><label for=c>Verification code</label><input id=c name=code autocomplete=one-time-code><button>Verify</button></form>"
    private static let first = "<!doctype html><title>Sign in</title><form action='/second' method='get'><input id=e name=email type=email autocomplete=username><button type=submit>Next</button></form>"
    private static let second = "<!doctype html><title>Sign in</title><form action='/landed' method='get'><input id=p name=pw type=password autocomplete=current-password><button type=submit>Sign in</button></form>"

    init() throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
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
        AgentSites.shared.reset()
        AgentSignIns.shared.reset()
        server = try LocalPageServer([
            "/form": .init(type: "text/html", body: Self.form),
            "/landed": .init(type: "text/html", body: Self.landed),
            "/wrong": .init(type: "text/html", body: Self.wrong.replacingOccurrences(of: "'/landed'", with: "'/wrong'")),
            "/code": .init(type: "text/html", body: Self.code),
            "/form-code": .init(type: "text/html", body: Self.form.replacingOccurrences(of: "'/landed'", with: "'/code'")),
            "/first": .init(type: "text/html", body: Self.first),
            "/second": .init(type: "text/html", body: Self.second),
            "/framed": .init(type: "text/html", body: "<!doctype html><title>Framed</title><iframe id=f width=400 height=200></iframe>"),
            "/inner": .init(type: "text/html", body: Self.form),
            "/opener": .init(type: "text/html", body: "<!doctype html><title>Opener</title><button onclick=\"window.open(location.href.replace('127.0.0.1', 'localhost').replace('/opener', '/form'), 'signin', 'width=400,height=500')\">Open window</button>"),
        ])
    }

    private func tearDown() {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
        AgentWorkTabs.forget()
        AgentSites.shared.reset()
        AgentSignIns.shared.reset()
        server?.stop()
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

    private func keep(_ users: [String], host: String? = nil) {
        socket.box.logins = { [port = Int(server.port)] asked in users.map { Kept(host: host ?? asked, user: $0, used: nil, clear: true, port: port) } }
        socket.box.loginSecret = { [passwords] kept in Login(host: kept.host, user: kept.user, password: passwords[kept.user] ?? "x-password-x", used: nil, clear: true) }
    }

    private func open(_ path: String, _ link: UUID) async throws -> (tab: Tab, id: String) {
        let opened = await socket.session("open", ["url": "http://127.0.0.1:\(server.port)\(path)"], task: link, browser: browser).outcome
        let id = try #require(ToolReply.data(opened)["id"] as? String)
        let tab = try #require(socket.box.find(["tab": id])?.tab)
        _ = await socket.session("wait", ["tab": id], task: link, browser: browser).outcome
        return (tab, id)
    }

    private func person(_ verb: String, _ arguments: [String: Any], _ link: UUID, noun: String = "fill", wait: Double = 30) -> Task<[String: Any], Never> {
        let request: [String: Any] = ["noun": noun, "verb": verb, "arguments": arguments, "wait": wait]
        let browser = browser!
        let socket = socket!
        return Task { @MainActor in
            await PersonCommands.perform(request, browser: browser, socket: socket, channel: PersonChannel { [weak self] event in
                MainActor.assumeIsolated { self?.heard.append(event) }
            }) { AgentLinks.shared.link(link) }
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

    private func value(_ tab: Tab, _ selector: String = "#p") async -> String {
        (try? await tab.web.evaluateJavaScript("(document.querySelector('\(selector)') || {}).value || ''") as? String) ?? ""
    }

    private func written(_ reply: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private var wire: [[String: Any]] = []
    private var sent = 0

    private func mcp(_ link: UUID) -> MCPServer {
        let made = MCPServer(box: AgentSessionBox(socket: socket, browser: browser), task: link) { [weak self] message in
            MainActor.assumeIsolated { self?.wire.append(message) }
        }
        let browser = browser!
        let socket = socket!
        made.person = { tool, arguments in await PersonTools.call(tool, arguments, link: link, browser: browser, socket: socket) }
        return made
    }

    private func send(_ server: MCPServer, _ name: String, _ arguments: [String: Any]) -> Int {
        sent += 1
        server.handle(["jsonrpc": "2.0", "id": sent, "method": "tools/call", "params": ["name": name, "arguments": arguments] as [String: Any]])
        return sent
    }

    private func result(_ id: Int) async -> [String: Any]? {
        for _ in 0..<3000 {
            if let found = wire.first(where: { $0["id"] as? Int == id }) { return found["result"] as? [String: Any] }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    private func shown(_ result: [String: Any]?) -> String {
        ((result?["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    @Test func fillLoginOverMCPRaisesTheCardAndFillsAfterAYes() async throws {
        let link = session()
        let (tab, id) = try await open("/form", link)
        keep(["sam@example.com"])
        let server = mcp(link)

        let call = send(server, "fill_login", ["tab": id])
        let question = try #require(await asked())
        let before = written(["wire": wire])
        AgentDesk.shared.take(question.id, .yes)
        let said = try #require(await result(call))
        let after = written(["wire": wire])

        #expect(question.title == "Sign in on 127.0.0.1?")
        #expect(!before.contains("sam@example.com"))
        #expect(!before.contains("hunter2-swordfish"))
        #expect(said["isError"] as? Bool == false, "\(said)")
        #expect(shown(said).contains("sam@example.com"))
        #expect(!after.contains("hunter2-swordfish"))
        #expect(tab.pageAddress?.path == "/landed")
    }

    @Test func aSignInWallOverMCPNamesTheToolAndTheShellNamesTheCommand() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        let server = mcp(link)

        let overMCP = shown(await result(send(server, "snapshot", ["tab": id])))
        let shell = await socket.session("snapshot", ["tab": id], task: link, browser: browser).outcome

        #expect(overMCP.contains("needs: a password, so call fill_login"), "\(overMCP)")
        #expect(!overMCP.contains("broadway fill login"))
        #expect((shell.plain ?? shell.text ?? "").contains("needs: a password, so run broadway fill login"))
        #expect(AgentChange.Look.overMCP(AgentChange.Look.needsLine("code")).contains("call fill_code"))
        #expect(AgentChange.Look.overMCP(AgentChange.Look.needsLine("code")).contains("call handoff"))
    }

    @Test func severalAccountsAreRowsOnOneCardAndAPickSignsIn() async throws {
        let link = session()
        let (tab, id) = try await open("/form", link)
        keep(["sam@example.com", "work@example.com"])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        #expect(question.title == "Sign in on 127.0.0.1?")
        #expect(question.choices == ["sam@example.com", "work@example.com"])
        AgentDesk.shared.take(question.id, .picked(1))
        let said = await reply.value

        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(written(said).contains("Filled as work@example.com"))
        #expect(!written(said).contains("tr0mbone-otter"))
        #expect(AgentDesk.shared.pending.isEmpty)
        #expect(tab.pageAddress?.path == "/landed")
    }

    @Test func oneAccountIsALineOnTheCard() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com"])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        let words = question.cardWords
        AgentDesk.shared.take(question.id, .no)
        let said = await reply.value

        #expect(question.title == "Sign in on 127.0.0.1?")
        #expect(words.who == "Claude Code")
        #expect(words.body.contains("sam@example.com"))
        #expect(code(said) == "said_no")
    }

    @Test func accountNamesStayOffWhatAnAgentReads() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com", "work@example.com"])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        let listed = await PersonCommands.perform(["noun": "approvals", "verb": "list"], browser: browser, socket: socket,
                                                  channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }
        let status = await PersonCommands.perform(["noun": "agents", "verb": "status"], browser: browser, socket: socket,
                                                  channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }
        AgentDesk.shared.take(question.id, .no)
        let said = await reply.value
        let read = [written(listed), written(status), written(said), question.title, question.quote, question.site ?? "", "\(heard)"]

        for text in read {
            #expect(!text.contains("sam@example.com") && !text.contains("work@example.com"), "\(text)")
        }
    }

    @Test func theAnswerBeforeAYesIsTheSameKeptOrNot() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        var answers: [[String: Any]] = []
        var unreached: [[String: Any]] = []
        for users in [["sam@example.com"], ["sam@example.com", "work@example.com"], []] {
            keep(users)
            let reply = person("login", ["tab": id], link)
            let question = try #require(await asked())
            AgentDesk.shared.take(question.id, .no)
            answers.append(await reply.value)
            unreached.append(await PersonCommands.perform(["noun": "fill", "verb": "login", "arguments": ["tab": id], "person": "none"], browser: browser,
                                                          socket: socket, channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) })
        }

        for said in answers { #expect(written(said) == written(answers[0]), "\(said)") }
        for said in unreached { #expect(written(said) == written(unreached[0]), "\(said)") }
        #expect(code(answers[0]) == "said_no")
        #expect(code(unreached[0]) == "needs_you")
    }

    @Test func withNoSignInKeptTheCardSaysSoAndHandsTheTabOver() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep([])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        let body = question.cardWords.body
        AgentDesk.shared.take(question.id, .yes)
        let handed = try #require(await asked(after: question.id))
        AgentDesk.shared.take(handed.id, .picked(0))
        let said = await reply.value

        #expect(body.contains("no saved sign-in"), "\(body)")
        #expect(handed.choices == ["Done"])
        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(written(said).contains("The person"), "\(said)")
    }

    @Test func aHandOverAfterTheYesEndsWhenTheWaitForThePersonEnds() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep([])

        let reply = person("login", ["tab": id], link, wait: 2)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let handed = try #require(await asked(after: question.id))
        let said = await within(20, reply)

        #expect(handed.choices == ["Done"])
        #expect(said.flatMap(code) == "needs_you", "\(String(describing: said))")
        #expect(said.map(written)?.contains("2 s") == true, "\(String(describing: said))")
    }

    private func within(_ seconds: Double, _ reply: Task<[String: Any], Never>) async -> [String: Any]? {
        await withTaskGroup(of: [String: Any]?.self) { group in
            group.addTask { await reply.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    @Test func bypassSignsInWithOneAccountWithoutACardAndSaysSoOnTheTab() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (tab, id) = try await open("/form", link)
        keep(["sam@example.com"])

        let said = await person("login", ["tab": id], link).value

        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(written(said).contains("Filled as sam@example.com"))
        #expect(heard.isEmpty, "\(heard)")
        #expect(tab.pageAddress?.path == "/landed")
        #expect(browser.announcement == "Claude Code signed in as sam@example.com")
    }

    @Test func bypassAsksWhichWhenSeveralAreKept() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com", "work@example.com"])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .picked(0))
        let said = await reply.value
        _ = await socket.session("navigate", ["tab": id, "url": "http://127.0.0.1:\(server.port)/form"], task: link, browser: browser).outcome
        _ = await socket.session("wait", ["tab": id], task: link, browser: browser).outcome
        let narrowed = await person("login", ["tab": id, "account": "work@example.com"], link).value

        #expect(question.choices.count == 2)
        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(narrowed["ok"] as? Bool == true, "\(narrowed)")
        #expect(written(narrowed).contains("Filled as work@example.com"))
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func bypassWithNothingKeptSaysToHandOver() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (_, id) = try await open("/form", link)
        keep([])

        let said = await person("login", ["tab": id], link).value

        #expect(code(said) == "nothing_kept", "\(said)")
        #expect(written(said).contains("broadway handoff"))
        #expect(heard.isEmpty)
    }

    @Test func autoAsksOnceAndAlwaysHereCoversThatAccount() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com"])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .always)
        let first = await reply.value
        _ = await socket.session("navigate", ["tab": id, "url": "http://127.0.0.1:\(server.port)/form"], task: link, browser: browser).outcome
        _ = await socket.session("wait", ["tab": id], task: link, browser: browser).outcome
        let again = await person("login", ["tab": id], link).value
        keep(["sam@example.com", "work@example.com"])
        let other = person("login", ["tab": id, "account": "work@example.com"], link)
        let asksAgain = try #require(await asked())
        AgentDesk.shared.take(asksAgain.id, .no)
        _ = await other.value

        #expect(first["ok"] as? Bool == true, "\(first)")
        #expect(again["ok"] as? Bool == true, "\(again)")
        #expect(AgentSites.shared.rule(for: "127.0.0.1") == nil)
    }

    @Test func askModeAsksEveryTime() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com"])
        browser.prefs.agentMode = .ask
        AgentDesk.shared.grant(.tab, task: link, site: "127.0.0.1")

        for _ in 0..<2 {
            let reply = person("login", ["tab": id], link)
            let question = try #require(await asked())
            AgentDesk.shared.take(question.id, .always)
            let said = await reply.value
            #expect(said["ok"] as? Bool == true, "\(said)")
            _ = await socket.session("navigate", ["tab": id, "url": "http://127.0.0.1:\(server.port)/form"], task: link, browser: browser).outcome
        _ = await socket.session("wait", ["tab": id], task: link, browser: browser).outcome
        }
    }

    @Test func neverHereStillRefuses() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com"])
        AgentSites.shared.set(.never, for: "127.0.0.1")

        let said = await person("login", ["tab": id], link).value

        #expect(code(said) == "never_here")
    }

    @Test func aFillNeverGoesToAnotherHost() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (tab, id) = try await open("/form", link)
        keep(["sam@example.com"], host: "127.0.0.2")

        let said = await person("login", ["tab": id], link).value

        #expect(said["ok"] as? Bool != true, "\(said)")
        #expect(await value(tab) == "")
    }

    @Test func afterTheFillTheAnswerSaysWhatThePageWants() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        keep(["sam@example.com"])
        var said: [String: [String: Any]] = [:]
        for (path, landing) in [("/form", "landed"), ("/wrong", "wrong")] {
            let (_, id) = try await open(path, link)
            said[landing] = await person("login", ["tab": id], link).value
        }
        let (codeTab, codeID) = try await open("/form", link)
        _ = try await codeTab.web.evaluateJavaScript("document.forms[0].action = '/code'; 1")
        said["code"] = await person("login", ["tab": codeID], link).value

        #expect(written(said["landed"] ?? [:]).contains("no longer asks for a password"), "\(said["landed"] ?? [:])")
        #expect(written(said["wrong"] ?? [:]).contains("still asks for the password"), "\(said["wrong"] ?? [:])")
        #expect(written(said["code"] ?? [:]).contains("one-time code"), "\(said["code"] ?? [:])")
    }

    @Test func oneYesCarriesANameStepAndAPasswordStep() async throws {
        let link = session()
        let (tab, id) = try await open("/first", link)
        keep(["sam@example.com"])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value

        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(tab.pageAddress?.path == "/landed", "\(tab.pageAddress?.absoluteString ?? "")")
        #expect(tab.pageAddress?.query?.contains("hunter2-swordfish") == true)
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aFrameFromAnotherSiteGetsNothing() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (tab, id) = try await open("/framed", link)
        _ = try await tab.web.evaluateJavaScript("document.getElementById('f').src = 'http://localhost:\(server.port)/inner'; 1")
        try? await Task.sleep(for: .milliseconds(800))
        keep(["sam@example.com"])

        let said = await person("login", ["tab": id], link).value
        socket.box.logins = { [port = Int(server.port)] _ in [Kept(host: "localhost", user: "sam@example.com", used: nil, clear: true, port: port)] }
        let other = await person("login", ["tab": id], link).value
        let frame = try #require(socket.box.frameNames(tab).first?.frame)
        let inner = try await tab.web.evaluateJavaScript("document.querySelector('#p').value", in: frame, contentWorld: .page) as? String

        #expect(said["ok"] as? Bool != true, "\(said)")
        #expect(other["ok"] as? Bool != true, "\(other)")
        #expect(inner == "")
    }

    @Test func detailsAndCardAskBeforeSayingNothingIsKept() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        socket.box.book = AutofillBook(keeper: MemoryKeeper())

        var bodies: [String] = []
        var answers: [[String: Any]] = []
        for verb in ["card", "details"] {
            let reply = person(verb, ["tab": id], link)
            let question = try #require(await asked(), "\(verb)")
            bodies.append(question.cardWords.body)
            AgentDesk.shared.take(question.id, .no)
            answers.append(await reply.value)
        }

        #expect(bodies[0].contains("no saved card"), "\(bodies)")
        #expect(bodies[1].contains("no saved name or address"), "\(bodies)")
        for said in answers { #expect(code(said) == "said_no", "\(said)") }
    }

    @Test func theSwitchPutsTheCardUpInEveryMode() async throws {
        keepSetting(Shared.prefs, \.agentsAskSignIn, "agents.signIn")
        browser.prefs.agentMode = .bypass
        browser.prefs.agentsAskSignIn = true
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com"])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        AgentDesk.shared.take(question.id, .yes)
        let said = await reply.value

        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(!question.offersAlways)
        #expect(browser.announcement == nil)
    }

    @Test func theSwitchIsThePersonsAndFindASettingFindsIt() async throws {
        keepSetting(Shared.prefs, \.agentsAskSignIn, "agents.signIn")
        let link = session()
        let item = try #require(SettingsIndex.items.first { $0.id == "agents.signIn" })
        let set = await PersonCommands.perform(["noun": "settings", "verb": "set", "arguments": ["setting": "agents.signIn", "value": "false"]],
                                               browser: browser, socket: socket, channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }

        #expect(item.title == "Always ask before an agent signs in")
        #expect(item.group == "agents")
        #expect(code(set) == "person_only", "\(set)")
        #expect(PersonSettings.table["agents.signIn"] != nil)
        #expect(!browser.prefs.agentsAskSignIn)
    }

    @Test func aSignInFitsOnlyItsOwnHostPortAndScheme() {
        func kept(_ host: String, port: Int? = nil, clear: Bool = false) -> Kept { Kept(host: host, user: "sam", used: nil, clear: clear, port: port) }
        func page(_ text: String) -> URL { URL(string: text)! }

        #expect(AgentSignInMatch.fits(kept("example.com"), page: page("https://example.com/login")))
        #expect(AgentSignInMatch.fits(kept("example.com"), page: page("https://www.example.com/login")))
        #expect(AgentSignInMatch.fits(kept("www.example.com"), page: page("https://example.com/login")))
        #expect(!AgentSignInMatch.fits(kept("example.com"), page: page("https://examp1e.com/login")))
        #expect(!AgentSignInMatch.fits(kept("example.com"), page: page("https://example.com.evil.test/login")))
        #expect(!AgentSignInMatch.fits(kept("example.com"), page: page("https://login.example.com/")))
        #expect(!AgentSignInMatch.fits(kept("login.example.com"), page: page("https://example.com/")))
        #expect(!AgentSignInMatch.fits(kept("example.com"), page: page("https://example.com:8443/login")))
        #expect(AgentSignInMatch.fits(kept("example.com", port: 8443), page: page("https://example.com:8443/login")))
        #expect(AgentSignInMatch.fits(kept("example.com"), page: page("https://example.com:443/login")))
        #expect(!AgentSignInMatch.fits(kept("example.com"), page: page("http://example.com/login")))
        #expect(AgentSignInMatch.fits(kept("example.com", clear: true), page: page("http://example.com/login")))
        #expect(AgentSignInMatch.fits(kept("example.com", clear: true), page: page("https://example.com/login")))
    }

    @Test func aSignInKeptWithNoPortOnThisMacFitsAnyPort() {
        func kept(_ host: String, port: Int? = nil, clear: Bool = true) -> Kept { Kept(host: host, user: "sam", used: nil, clear: clear, port: port) }
        func page(_ text: String) -> URL { URL(string: text)! }

        #expect(AgentSignInMatch.fits(kept("localhost"), page: page("http://localhost:3000/login")))
        #expect(AgentSignInMatch.fits(kept("127.0.0.1"), page: page("http://127.0.0.1:5173/login")))
        #expect(AgentSignInMatch.fits(kept("::1"), page: page("http://[::1]:8080/login")))
        #expect(AgentSignInMatch.fits(kept("[::1]"), page: page("http://[::1]:8080/login")))
        #expect(AgentSignInMatch.fits(kept("app.localhost"), page: page("http://app.localhost:4000/login")))
        #expect(AgentSignInMatch.fits(kept("localhost", clear: false), page: page("https://localhost:8443/login")))
        #expect(!AgentSignInMatch.fits(kept("localhost", port: 3001), page: page("http://localhost:3000/login")))
        #expect(!AgentSignInMatch.fits(kept("localhost", clear: false), page: page("http://localhost:3000/login")))
        #expect(!AgentSignInMatch.fits(kept("example.com"), page: page("https://example.com:8443/login")))
        #expect(!AgentSignInMatch.fits(kept("notlocalhost"), page: page("http://notlocalhost:3000/login")))
        #expect(!AgentSignInMatch.fits(kept("localhost.example.com"), page: page("http://localhost.example.com:3000/login")))
    }

    private func onePassword(_ logins: [(id: String, user: String, password: String)], mode: String = "", otp: String? = nil) throws -> OnePasswordStandIn {
        keepSetting(Shared.prefs, \.onePassword, "passwords.onepassword")
        browser.prefs.onePassword = true
        let standIn = try OnePasswordStandIn(mode: mode)
        addTeardownBlock { standIn.done() }
        let href = "http://127.0.0.1:\(server.port)"
        try standIn.items(logins.map { standIn.login($0.id, user: $0.user, password: $0.password, href: href, otp: otp) })
        return standIn
    }

    @Test func accountsFromOnePasswordShowBesideBroadwaysOwnMarkedAndAPickSignsIn() async throws {
        let link = session()
        let (tab, id) = try await open("/form", link)
        keep(["sam@example.com"])
        let standIn = try onePassword([("i1", "op@example.com", "op-secret-pass-1"), ("i2", "sam@example.com", "op-other-pass-2")])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        let choices = question.choices
        AgentDesk.shared.take(question.id, .picked(1))
        let said = await reply.value

        #expect(choices == ["sam@example.com · Broadway", "op@example.com · 1Password"])
        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(written(said).contains("Filled as op@example.com"))
        #expect(written(said).contains("1password"))
        #expect(!written(said).contains("op-secret-pass-1"))
        #expect(tab.pageAddress?.path == "/landed")
        #expect(!standIn.calls.joined(separator: "\n").contains("op-secret-pass-1"))
        try await Task.sleep(for: .seconds(3))
        #expect(browser.offering == nil, "\(String(describing: browser.offering?.login.user))")
        #expect(standIn.calls.contains { $0.hasPrefix("item get i1 ") })
        #expect(!standIn.calls.contains { $0.hasPrefix("item get i2 ") })
    }

    @Test func oneAccountFromOnePasswordSaysWhereItIsFrom() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep([])
        _ = try onePassword([("i1", "op@example.com", "op-secret-pass-1")])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        let body = question.cardWords.body
        AgentDesk.shared.take(question.id, .no)
        let said = await reply.value

        #expect(body == "As op@example.com, from 1Password")
        #expect(!question.offersAlways)
        #expect(code(said) == "said_no")
    }

    @Test func onePasswordNamesStayOffWhatAnAgentReadsBeforeAYes() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep([])
        _ = try onePassword([("i1", "op@example.com", "op-secret-pass-1"), ("i2", "other@example.com", "op-other-pass-2")])

        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        let listed = await PersonCommands.perform(["noun": "approvals", "verb": "list"], browser: browser, socket: socket,
                                                  channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }
        AgentDesk.shared.take(question.id, .no)
        let said = await reply.value
        let away = await PersonCommands.perform(["noun": "fill", "verb": "login", "arguments": ["tab": id], "person": "none"], browser: browser,
                                                socket: socket, channel: PersonChannel { _ in }) { AgentLinks.shared.link(link) }

        for text in [written(listed), written(said), written(away), question.title, question.quote, "\(heard)"] {
            #expect(!text.contains("op@example.com") && !text.contains("other@example.com"), "\(text)")
        }
    }

    @Test func aOnePasswordThatDoesNotAnswerLeavesBroadwaysOwnAndSaysSo() async throws {
        let link = session()
        let (_, id) = try await open("/form", link)
        keep(["sam@example.com"])
        _ = try onePassword([("i1", "op@example.com", "op-secret-pass-1")], mode: "slow")
        OnePassword.listBound = 1

        let started = Date()
        let reply = person("login", ["tab": id], link)
        let question = try #require(await asked())
        let waited = Date().timeIntervalSince(started)
        let body = question.cardWords.body
        AgentDesk.shared.take(question.id, .no)
        _ = await reply.value

        #expect(body == "As sam@example.com. 1Password didn't answer within 1 s.")
        #expect(waited < 1.9)
    }

    @Test func bypassWithNothingKeptAndOnePasswordSilentSaysToTryAgain() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (_, id) = try await open("/form", link)
        keep([])
        _ = try onePassword([("i1", "op@example.com", "op-secret-pass-1")], mode: "locked")
        OnePassword.listBound = 1

        let said = await person("login", ["tab": id], link).value

        #expect(code(said) == "nothing_kept", "\(said)")
        #expect(written(said).contains("Broadway keeps no sign-in for this site. 1Password didn't answer within 1 s. Nothing was filled."), "\(said)")
        #expect(written(said).contains("Touch ID"))
    }

    @Test func bypassWithOnePasswordNotSetUpSaysSoAndHandsOver() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (_, id) = try await open("/form", link)
        keep([])
        _ = try onePassword([("i1", "op@example.com", "op-secret-pass-1")], mode: "noaccounts")

        let said = await person("login", ["tab": id], link).value

        #expect(code(said) == "nothing_kept", "\(said)")
        #expect(written(said).contains("Integrate with 1Password CLI"), "\(said)")
        #expect(!written(said).contains("Touch ID"))
        #expect(written(said).contains("broadway handoff"))
    }

    @Test func aCodeComesFromTheOnePasswordItemTheAgentSignedInWith() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (tab, id) = try await open("/form-code", link)
        keep([])
        let standIn = try onePassword([("i1", "op@example.com", "op-secret-pass-1")], otp: "482913")

        let signedIn = await person("login", ["tab": id], link).value
        let said = await person("code", ["tab": id], link).value

        #expect(signedIn["ok"] as? Bool == true, "\(signedIn)")
        #expect(said["ok"] as? Bool == true, "\(said)")
        #expect(written(said).contains("Filled the code"), "\(said)")
        #expect(!written(said).contains("482913"))
        #expect(tab.pageAddress?.path == "/landed")
        #expect(standIn.calls.contains { $0.hasPrefix("item get i1 --otp") })
    }

    @Test func aFillOnAnotherPortGetsNothing() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (tab, id) = try await open("/form", link)
        socket.box.logins = { [port = Int(server.port) + 1] in [Kept(host: $0, user: "sam@example.com", used: nil, clear: true, port: port)] }
        socket.box.loginSecret = { Login(host: $0.host, user: $0.user, password: "hunter2-swordfish", used: nil, clear: true) }

        let said = await person("login", ["tab": id], link).value

        #expect(code(said) == "nothing_kept", "\(said)")
        #expect(await value(tab) == "")
    }

    @Test func aPopUpGetsOnlyTheSignInKeptForItsOwnSite() async throws {
        browser.prefs.agentMode = .bypass
        let link = session()
        let (tab, id) = try await open("/opener", link)
        let before = Set(Browsers.all.flatMap(\.tabs).map(\.id) + browser.tabs.map(\.id))
        let shot = await socket.session("snapshot", ["tab": id], task: link, browser: browser).outcome.text ?? ""
        let ref = try #require(shot.split(separator: "\n").first { $0.contains("Open window") }?.split(separator: " ").first.map(String.init))
        _ = await socket.session("click", ["tab": id, "ref": ref], task: link, browser: browser).outcome
        var popup: Tab?
        for _ in 0..<300 where popup == nil {
            popup = (Browsers.all.flatMap(\.tabs) + browser.tabs).first { !before.contains($0.id) && $0.pageAddress?.host() == "localhost" }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let opened = try #require(popup, "\(shot)")
        for _ in 0..<300 where opened.loading || opened.pageAddress?.path != "/form" { try? await Task.sleep(for: .milliseconds(20)) }
        try? await Task.sleep(for: .milliseconds(300))
        let popupID = String(opened.id.uuidString.prefix(8)).lowercased()
        keep(["sam@example.com"], host: "127.0.0.1")

        let wrong = await person("login", ["tab": popupID], link).value
        let empty = await value(opened)
        keep(["sam@example.com"], host: "localhost")
        let right = await person("login", ["tab": popupID], link).value

        #expect(code(wrong) == "nothing_kept", "\(wrong)")
        #expect(empty == "")
        #expect(right["ok"] as? Bool == true, "\(right)")
        _ = tab
    }

    @Test func theAgentsUseRidesOnTheItemsAttributesWithItsPort() throws {
        let use = AgentUse(agent: "Claude Code", folder: "garden", at: Date(timeIntervalSince1970: 1_800_000_000))
        let row: [String: Any] = [kSecAttrServer as String: "shop.example", kSecAttrAccount as String: "sam@example.com",
                                  kSecAttrDescription as String: use.stored, kSecAttrPort as String: 8443]
        let kept = try #require(Vault.kept(from: row))
        let bare = try #require(Vault.kept(from: [kSecAttrServer as String: "shop.example", kSecAttrPort as String: 0]))

        #expect(kept.agent == use)
        #expect(kept.port == 8443)
        #expect(bare.agent == nil)
        #expect(bare.port == nil)
    }

    @Test func anAgentsUseIsWordedForThePerson() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let at = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 11, minute: 2)))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 9)))
        let use = AgentUse(agent: "Claude Code", folder: "garden", at: at)

        #expect(use.words(now: now, calendar: calendar) == "Used by Claude Code in garden, 19 November 11:02")
        #expect(AgentUse(stored: use.stored) == use)
        #expect(AgentUse(agent: "Codex", folder: nil, at: at).words(now: now, calendar: calendar) == "Used by Codex, 19 November 11:02")
    }

    @Test func aSignInWallNamesTheSpaceThatIsSignedIn() async throws {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        browser.prefs.usesSpaces = true
        let home = UUID()
        let work = browser.spaceID
        browser.spaces = [Space(id: work, name: "Work", colour: 0, icon: TabIcon(emoji: "💼")),
                          Space(id: home, name: "Home", colour: 1, icon: TabIcon(emoji: "🏠"))]
        let store = Spaces.store(for: home)
        let cookie = try #require(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "session_id", .value: "1"]))
        await store.httpCookieStore.setCookie(cookie)
        defer { Task { @MainActor in await store.httpCookieStore.deleteCookie(cookie) } }
        let link = session()
        let (_, id) = try await open("/form", link)

        let look = await socket.session("snapshot", ["tab": id], task: link, browser: browser).outcome.text ?? ""
        let line = "signed in in Home: broadway open http://127.0.0.1:\(server.port)/form --space Home"
        await store.httpCookieStore.deleteCookie(cookie)
        let bare = await socket.session("snapshot", ["tab": id], task: link, browser: browser).outcome.text ?? ""

        #expect(look.contains(line), "\(look)")
        #expect(!bare.contains("signed in in"), "\(bare)")
    }
}

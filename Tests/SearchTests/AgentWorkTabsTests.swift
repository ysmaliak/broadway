import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentWorkTabsTests {
    private var browser: Browser!
    private var socket: AgentSocket!
    private var server: LocalPageServer!
    private var made: [UUID] = []
    private let cap = AgentWorkTabs.loadCap

    init() throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
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
        browser.prefs.usesSpaces = true
        browser.prefs.agentsOn = true
        AgentSites.shared.reset()
        AgentWorkTabs.loadCap = 3
        let shop = "<!doctype html><title>Shop</title><h1>Shop</h1>"
            + "<a href='/gift' target='_blank'>Gift cards</a>"
            + "<button onclick=\"window.open('/help')\">Help</button>"
            + "<button onclick=\"window.open('http://localhost:' + location.port + '/help')\">Elsewhere</button>"
        server = try LocalPageServer([
            "/shop": .init(type: "text/html", body: shop),
            "/gift": .init(type: "text/html", body: "<!doctype html><title>Gift</title><p>Gift cards</p>"),
            "/help": .init(type: "text/html", body: "<!doctype html><title>Help</title><p>Help</p>"),
            "/basket": .init(type: "text/html", body: "<!doctype html><title>Basket</title><p>Basket</p>"),
        ])
    }

    private func tearDown() {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
        AgentWorkTabs.loadCap = cap
        AgentWorkTabs.forget()
        AgentSites.shared.reset()
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func session(_ name: String = "Claude Code") -> UUID {
        let link = AgentLinks.shared.join(.named(UUID().uuidString), name: name)
        TaskLedger.shared.open(link.id, title: name)
        made.append(link.id)
        return link.id
    }

    private func address(_ path: String) -> String { "http://127.0.0.1:\(server.port)\(path)" }

    private func call(_ name: String, _ arguments: [String: Any] = [:], _ link: UUID?, preferred: String? = nil) async -> ToolOutcome {
        await socket.session(name, arguments, task: link, browser: browser, preferred: preferred).outcome
    }

    private func data(_ outcome: ToolOutcome) -> [String: Any] { ToolReply.data(outcome) }

    private func open(_ path: String, _ link: UUID?) async -> String {
        let said = await call("open", ["url": address(path)], link)
        return data(said)["id"] as? String ?? ""
    }

    private func question() async -> AgentQuestion? {
        for _ in 0..<400 {
            if let front = AgentDesk.shared.front { return front }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func short(_ tab: Tab) -> String { AgentWorkTabs.short(tab.id) }

    private var front: String { short(browser.active!) }

    private func ref(_ tab: String, _ label: String, _ link: UUID) async throws -> String {
        let shot = await call("snapshot", ["tab": tab], link)
        let line = try #require(shot.plain?.split(separator: "\n").first { $0.contains("\"\(label)\"") })
        return String(line.split(separator: " ")[0])
    }

    private func until(_ done: () -> Bool) async {
        for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func theSameAddressIsTheSamePage() {
        let same = [
            ("https://www.shop.example/teas/", "https://shop.example/teas"),
            ("https://shop.example/teas?b=2&a=1", "https://shop.example/teas?a=1&b=2"),
            ("https://shop.example/teas?utm_source=x&a=1&fbclid=y", "https://shop.example/teas?a=1"),
            ("https://shop.example/teas#reviews", "https://shop.example/teas"),
            ("https://shop.example:443/teas", "http://shop.example/teas"),
        ]
        let different = [
            ("https://shop.example/teas", "https://shop.example/teas/green"),
            ("https://shop.example:8443/teas", "https://shop.example/teas"),
            ("https://shop.example/teas?a=1", "https://shop.example/teas?a=2"),
            ("https://shop.example/teas", "https://shop.example.org/teas"),
        ]

        for (one, other) in same { #expect(AgentAddress.same(URL(string: one), URL(string: other)), "\(one)") }
        for (one, other) in different { #expect(!AgentAddress.same(URL(string: one), URL(string: other)), "\(one)") }
    }

    @Test func openAlwaysOpensAndSaysWhatTheSessionHolds() async {
        let link = session()

        let first = await call("open", ["url": address("/shop")], link)
        let second = await call("open", ["url": address("/shop") + "#top"], link)
        let third = await call("open", ["url": address("/basket")], link)
        let one = data(first)
        let two = data(second)
        let three = data(third)
        let firstID = one["id"] as? String ?? ""

        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).count == 3)
        #expect(one["tabs"] as? Int == 1)
        #expect(two["tabs"] as? Int == 2)
        #expect(three["tabs"] as? Int == 3)
        #expect(one["same"] == nil)
        #expect(two["same"] as? [String] == [firstID])
        #expect(three["same"] == nil)
        #expect(one["did"] as? String == "open")
        #expect((one["page"] as? [String: Any])?["title"] as? String == "Shop")
        #expect(one["agent"] as? Bool == true)
        #expect(second.text?.contains("You already have this address in tab \(firstID). Use it: broadway tab \(firstID)") == true)
        #expect(socket.current(link) == three["id"] as? String)
    }

    @Test func tabNamesAndSwitchesTheCurrentTabAmongTheSessionsOwn() async {
        let link = session()
        let other = session("Codex")
        let first = await open("/shop", link)
        let second = await open("/basket", link)
        let theirs = await open("/help", other)

        let shown = await call("tab", [:], link)
        let switched = await call("tab", ["id": first], link)
        let refused = await call("tab", ["id": theirs], link)
        let person = await call("tab", ["id": front], link)
        let none = await call("tab", ["id": "ffffffff"], link)

        #expect(data(shown)["id"] as? String == second)
        #expect(!switched.failed)
        #expect(socket.current(link) == first)
        #expect(socket.current(other) == theirs)
        #expect(refused.code == "not_yours")
        #expect(person.code == "not_yours")
        #expect(none.code == "no_tab")
        #expect(socket.current(link) == first)
    }

    @Test func aSessionWithoutATabCannotActButReadsThePersonsTabAndSaysSo() async throws {
        let before = Front.shared.browser
        Front.shared.set(browser)
        defer { Front.shared.set(before) }
        let link = session()
        browser.arrive(server.url("/help"))
        let person = try #require(browser.active)
        await until { person.committed != nil && person.built?.isLoading == false }

        let acted = await call("press", ["key": "Tab"], link)
        let went = await call("navigate", ["url": address("/shop")], link)
        let none = await call("tab", [:], link)
        let read = await call("console", [:], link)

        #expect(acted.code == "no_tab")
        #expect(acted.text == "You have no tab. Open one with broadway open URL, or name one with --tab ID.")
        #expect(went.code == "no_tab")
        #expect(browser.active?.pageAddress?.path == "/help")
        #expect(none.code == "no_tab")
        #expect(!read.failed)
        #expect(data(read)["notice"] as? String == "Reading the person's tab \(front). Your own: broadway open URL.")
    }

    @Test func goMovesTheCurrentTabAndAnswersAfterTheLoad() async {
        let link = session()
        let id = await open("/shop", link)

        let went = await call("navigate", ["url": address("/basket")], link)
        let said = data(went)
        let tab = socket.box.find(["tab": id])?.tab

        #expect(!went.failed)
        #expect(said["tab"] as? String == id)
        #expect(said["did"] as? String == "go")
        #expect((said["page"] as? [String: Any])?["title"] as? String == "Basket")
        #expect(tab?.pageAddress?.path == "/basket")
        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).count == 1)
    }

    @Test func goWithATabStillSendsThatTab() async {
        let link = session()
        let first = await open("/shop", link)
        _ = await open("/help", link)

        let went = await call("navigate", ["url": address("/basket"), "tab": first], link)

        #expect(!went.failed)
        #expect(socket.box.find(["tab": first])?.tab.pageAddress?.path == "/basket")
        #expect(socket.current(link) == first)
    }

    @Test func goNeverTakesThePersonsTabElsewhere() async {
        let link = session()
        _ = await open("/shop", link)

        let went = await call("navigate", ["url": address("/basket"), "tab": front], link)

        #expect(went.failed)
        #expect(browser.active?.pageAddress?.path == "/mine")
    }

    @Test func closingTheCurrentTabMakesTheLastOneLeftCurrent() async {
        let link = session()
        let first = await open("/shop", link)
        let second = await open("/basket", link)

        let closed = await call("close", [:], link)
        let said = data(closed)

        #expect(!closed.failed)
        #expect(said["closed"] as? String == second)
        #expect(said["current"] as? String == first)
        #expect(socket.current(link) == first)
        #expect(closed.text?.contains("Your current tab is \(first)") == true)
    }

    @Test func closeOthersKeepsTheCurrentTabAndCloseAllEmptiesTheSession() async {
        let link = session()
        let other = session("Codex")
        _ = await open("/shop", link)
        _ = await open("/basket", link)
        let kept = await open("/help", link)
        let theirs = await open("/shop", other)

        let others = await call("close", ["others": true], link)
        let left = AgentWorkTabs.tabs(of: link, in: socket.box).map { short($0.tab) }
        let all = await call("close", ["all": true], link)

        #expect((data(others)["closed"] as? [String])?.count == 2)
        #expect(left == [kept])
        #expect((data(all)["closed"] as? [String]) == [kept])
        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).isEmpty)
        #expect(socket.current(link) == nil)
        #expect(socket.box.find(["tab": theirs]) != nil)
        #expect(browser.tabs.contains { $0.pageAddress?.path == "/mine" })
    }

    @Test func tidyingKeepsATabWithWorkInIt() async {
        let link = session()
        let busy = await open("/shop", link)
        let current = await open("/basket", link)
        socket.box.find(["tab": busy])?.tab.noisy = true

        let said = await call("close", ["others": true], link)
        let tidy = data(said)["tidy"] as? [String: Any]

        #expect((data(said)["closed"] as? [String])?.isEmpty == true)
        #expect((tidy?["kept"] as? [[String: Any]])?.first?["id"] as? String == busy)
        #expect(said.text?.contains("Kept \(busy): it is playing sound") == true)
        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).map { short($0.tab) } == [busy, current])
    }

    @Test func tabsListsTheSessionsOwnFirstAndCountsThePersons() async {
        let link = session()
        let other = session("Codex")
        let first = await open("/shop", link)
        let second = await open("/basket", link)
        _ = await open("/help", other)
        _ = await call("tab", ["id": first], link)

        let theirs = socket.box.visible.filter { !$0.tab.agent }.count
        let total = socket.box.visible.count
        let listed = await call("tabs", [:], link)
        let rows = data(listed)["tabs"] as? [[String: Any]] ?? []
        let everything = await call("tabs", ["all": true], link)

        #expect(rows.map { $0["id"] as? String } == [first, second])
        #expect(rows.map { $0["working"] as? Bool } == [true, false])
        #expect(data(listed)["others"] as? Int == theirs)
        #expect(listed.text?.hasPrefix("* \(first)") == true)
        #expect(listed.text?.contains("And \(theirs) tab\(theirs == 1 ? "" : "s") of the person's: broadway tabs --all") == true)
        #expect((data(everything)["tabs"] as? [[String: Any]])?.count == total)
    }

    @Test func theTabsNounGivesTheSessionViewToAnAgent() async throws {
        let link = session()
        let id = await open("/shop", link)
        let verb = try #require(PersonCommands.find("tabs", "list"))
        var call = PersonCall(noun: "tabs", verb: "list", arguments: ["mine": true], browser: browser, box: socket.box)
        call.link = AgentLinks.shared.link(link)

        let theirs = socket.box.visible.filter { !$0.tab.agent }.count
        let said = try await verb.run(call)
        call.arguments = ["mine": true, "all": true]
        let all = try await verb.run(call)
        call.arguments = [:]
        let spelled = try await verb.run(call)

        #expect((said["tabs"] as? [[String: Any]])?.map { $0["id"] as? String } == [id])
        #expect(said["others"] as? Int == theirs)
        #expect(said["message"] as? String == "Your current tab is \(id). And \(theirs) tab\(theirs == 1 ? "" : "s") of the person's: broadway tabs --all.")
        #expect((all["tabs"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true)
        #expect(((spelled["tabs"] as? [[String: Any]])?.count ?? 0) > 1)
    }

    @Test func twoSessionsNeverShareACurrentTab() async {
        let one = session()
        let two = session("Codex")

        let first = await open("/shop", one)
        let second = await open("/basket", two)
        let read = await socket.session("console", [:], task: one, browser: browser)

        #expect(socket.current(one) == first)
        #expect(socket.current(two) == second)
        #expect(read.used == first)
    }

    @Test func anMCPConnectionGetsACurrentTabLikeTheCommand() async {
        let link = session()
        let box = AgentSessionBox(socket: socket, browser: browser)

        let opened = await box.call("open", ["url": address("/shop")], task: link)
        let id = data(opened)["id"] as? String
        let read = await box.call("console", [:], task: link)
        let shown = await box.call("tab", [:], task: link)

        #expect(!opened.failed)
        #expect(!read.failed)
        #expect(data(read)["notice"] == nil)
        #expect(data(shown)["id"] as? String == id)
        #expect(box.tools.contains { $0.name == "tab" })
    }

    @Test func aTabFromTheEnvironmentComesBeforeTheCurrentOneAndChangesNothing() async {
        let link = session()
        let first = await open("/shop", link)
        let second = await open("/basket", link)

        let read = await socket.session("console", [:], task: link, browser: browser, preferred: first)

        #expect(read.used == first)
        #expect(socket.current(link) == second)
    }

    @Test func aLinkOrScriptOpensATabOfTheSameSession() async throws {
        let link = session()
        let id = await open("/shop", link)
        let opener = try #require(socket.box.find(["tab": id])?.tab)
        let gift = try await ref(id, "Gift cards", link)
        let help = try await ref(id, "Help", link)

        let clicked = await call("click", ["ref": gift], link)
        await until { AgentWorkTabs.tabs(of: link, in: socket.box).count == 2 }
        let scripted = await call("click", ["ref": help], link)
        await until { AgentWorkTabs.tabs(of: link, in: socket.box).count == 3 }
        let later = await call("console", [:], link)
        let mine = AgentWorkTabs.tabs(of: link, in: socket.box).map(\.tab)
        let popups = mine.filter { $0.id != opener.id }
        let reported = [clicked, scripted, later].flatMap { outcome -> [[String: Any]] in
            let tabs = data(outcome)["tabs"] as? [String: Any]
            return tabs?["opened"] as? [[String: Any]] ?? []
        }

        #expect(popups.count == 2)
        #expect(popups.allSatisfy { $0.agent && $0.bench && $0.agentTask == link && $0.opener == opener.id })
        #expect(!browser.tabsInSession.contains { id in popups.contains { $0.id == id } })
        #expect(browser.active?.pageAddress?.path == "/mine")
        #expect(Set(reported.compactMap { $0["id"] as? String }) == Set(popups.map(short)))
        #expect(socket.current(link) == id)
    }

    @Test func aPopupToASiteThePersonRefusedCloses() async throws {
        AgentSites.shared.set(.never, for: "localhost")
        let link = session()
        let id = await open("/shop", link)
        let elsewhere = try await ref(id, "Elsewhere", link)

        let clicked = await call("click", ["ref": elsewhere], link)
        try? await Task.sleep(for: .milliseconds(300))
        let later = await call("console", [:], link)
        let blocked = [clicked, later].flatMap { outcome -> [String] in
            ((data(outcome)["tabs"] as? [String: Any])?["blocked"] as? [String]) ?? []
        }
        let text = [clicked, later].compactMap(\.text).joined(separator: "\n")

        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).count == 1)
        #expect(!browser.tabs.contains { $0.pageAddress?.host() == "localhost" })
        #expect(blocked == ["localhost"])
        #expect(text.contains("A new tab for localhost was closed. The person never lets agents use that site."))
    }

    @Test func openStillAsksInAskMode() async throws {
        browser.prefs.agentMode = .ask
        let link = session()

        let opening = Task { await call("open", ["url": address("/shop")], link) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let said = await opening.value

        #expect(asked?.kind == .approval(.tab))
        #expect(said.failed)
        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).isEmpty)
    }

    @Test func goToANewSiteStillAsksInAskMode() async throws {
        let link = session()
        let id = await open("/shop", link)
        browser.prefs.agentMode = .ask

        let going = Task { await call("navigate", ["url": "http://localhost:\(server.port)/basket"], link) }
        let here = await question()
        AgentDesk.shared.take(try #require(here).id, .yes)
        try? await Task.sleep(for: .milliseconds(50))
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let said = await going.value

        #expect(here?.site == "127.0.0.1")
        #expect(asked?.kind == .approval(.tab))
        #expect(asked?.site == "localhost")
        #expect(said.failed)
        #expect(socket.box.find(["tab": id])?.tab.pageAddress?.path == "/shop")
    }

    @Test func agentsDoneKeepsTheTabsAndListsThem() async throws {
        let link = session()
        let first = await open("/shop", link)
        let second = await open("/basket", link)
        let verb = try #require(PersonCommands.find("agents", "done"))
        var call = PersonCall(noun: "agents", verb: "done", arguments: ["summary": "Looked at the shop"], browser: browser, box: socket.box)
        call.link = AgentLinks.shared.link(link)

        let said = try await verb.run(call)

        #expect((said["tabs"] as? [[String: Any]])?.map { $0["id"] as? String } == [first, second])
        #expect((said["message"] as? String)?.components(separatedBy: "\n").first == "Ended. 2 tabs of yours left open for the person: \(first), \(second).")
        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).count == 2)
    }

    @Test func agentsDoneCloseClosesOnlyWhatThePersonNeverSaw() async throws {
        let link = session()
        let seen = await open("/shop", link)
        let unseen = await open("/basket", link)
        socket.box.find(["tab": seen])?.tab.agentSeen = true
        let verb = try #require(PersonCommands.find("agents", "done"))
        var call = PersonCall(noun: "agents", verb: "done", arguments: ["close": true], browser: browser, box: socket.box)
        call.link = AgentLinks.shared.link(link)

        let said = try await verb.run(call)

        #expect(said["closed"] as? [String] == [unseen])
        #expect((said["tabs"] as? [[String: Any]])?.map { $0["id"] as? String } == [seen])
        #expect((said["message"] as? String)?.hasPrefix("Ended. 1 tab of yours left open for the person: \(seen).") == true)
        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).map { short($0.tab) } == [seen])
    }

    @Test func agentsDoneRefusesCloseWithKeep() async throws {
        let link = session()
        let verb = try #require(PersonCommands.find("agents", "done"))
        var call = PersonCall(noun: "agents", verb: "done", arguments: ["close": true, "keep": true], browser: browser, box: socket.box)
        call.link = AgentLinks.shared.link(link)

        await #expect(throws: PersonRefusal.self) { try await verb.run(call) }
        #expect(AgentLinks.shared.link(link)?.live == true)
    }

    private func agent(_ id: String) -> UUID? {
        AgentLinks.wire()
        let request: [String: Any] = ["agent": ["session": "claude:\(id)", "pid": 4242, "started": 1]]
        guard let found = socket.link(for: request, create: true) else { return nil }
        made.append(found.id)
        return found.id
    }

    private func done(_ link: UUID) async throws -> [String: Any] {
        let verb = try #require(PersonCommands.find("agents", "done"))
        var call = PersonCall(noun: "agents", verb: "done", arguments: [:], browser: browser, box: socket.box)
        call.link = AgentLinks.shared.link(link)
        return try await verb.run(call)
    }

    private func ids(_ outcome: ToolOutcome) -> [String] {
        (data(outcome)["tabs"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    @Test func afterDoneTheSameAgentsNextCommandTakesBackItsTabs() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        let first = await open("/shop", old)
        let second = await open("/basket", old)
        let said = try await done(old)

        let next = try #require(agent(key))
        let listed = await call("tabs", [:], next)
        let went = await call("navigate", ["url": address("/help")], next)
        let closed = await call("close", ["others": true], next)

        #expect(next != old)
        #expect((said["tabs"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [first, second])
        #expect((said["message"] as? String)?.hasPrefix("Ended. 2 tabs of yours left open for the person: \(first), \(second).") == true)
        #expect(ids(listed) == [first, second])
        #expect(data(listed)["current"] as? String == second)
        #expect(!went.failed)
        #expect(socket.box.find(["tab": second])?.tab.address?.path == "/help")
        #expect(!closed.failed)
        #expect(AgentWorkTabs.tabs(of: next, in: socket.box).map { short($0.tab) } == [second])
        #expect(AgentWorkTabs.tabs(of: old, in: socket.box).isEmpty)
        #expect(socket.box.find(["tab": first]) == nil)
    }

    @Test func afterTheHookEndsTheSessionTheNextCommandTakesBackItsTabsWithTheLastCurrent() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        let first = await open("/shop", old)
        _ = await open("/basket", old)
        _ = await call("tab", ["id": first], old)

        AgentLinks.shared.end(old, .done(nil))
        let next = try #require(agent(key))
        let listed = await call("tabs", [:], next)

        #expect(data(listed)["current"] as? String == first)
        #expect(ids(listed).count == 2)
        #expect(AgentWorkTabs.tabs(of: next, in: socket.box).allSatisfy { $0.tab.agentFinished == nil })
    }

    @Test func aTabsCallAloneTakesBackTheTabsButMakesNoSessionForANewAgent() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        let mine = await open("/shop", old)
        _ = try await done(old)
        let request: [String: Any] = ["agent": ["session": "claude:\(key)", "pid": 4242, "started": 1]]
        let stranger: [String: Any] = ["agent": ["session": "claude:\(UUID().uuidString)", "pid": 4343, "started": 1]]

        let plain = socket.link(for: request, create: false)
        let back = try #require(socket.link(for: request, create: false, rejoin: true))
        made.append(back.id)
        let none = socket.link(for: stranger, create: false, rejoin: true)
        let listed = await call("tabs", [:], back.id)

        #expect(plain == nil)
        #expect(none == nil)
        #expect(ids(listed) == [mine])
        #expect(data(listed)["current"] as? String == mine)
    }

    @Test func aTabThePersonKeptStaysTheirsWhenTheAgentComesBack() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        let kept = await open("/shop", old)
        let left = await open("/basket", old)
        _ = try await done(old)
        let found = try #require(socket.box.find(["tab": kept]))
        found.browser.keepAgentTab(found.tab)

        let next = try #require(agent(key))
        let listed = await call("tabs", [:], next)
        _ = await call("close", ["others": true], next)

        #expect(ids(listed) == [left])
        #expect(!found.tab.agent)
        #expect(found.tab.agentTask == nil)
        #expect(socket.box.find(["tab": kept]) != nil)
    }

    private func asked(_ path: String, _ link: UUID, answer: AgentAnswer) async -> (asked: Bool, outcome: ToolOutcome) {
        let opening = Task { await call("open", ["url": address(path)], link) }
        let shown = await question()
        if let shown { AgentDesk.shared.take(shown.id, answer) }
        return (shown != nil, await opening.value)
    }

    @Test func aNoFromTheEndedSessionStillHoldsForTheSameAgentsNextTry() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        _ = await open("/shop", old)
        browser.prefs.agentMode = .ask
        AgentSites.shared.reset()
        let first = await asked("/basket", old, answer: .no)

        _ = try await done(old)
        let next = try #require(agent(key))
        let again = await call("open", ["url": address("/basket")], next)
        let quiet = AgentDesk.shared.pending.isEmpty
        let stranger = await asked("/basket", try #require(agent(UUID().uuidString)), answer: .no)

        #expect(first.asked)
        #expect(first.outcome.failed)
        #expect(again.failed)
        #expect(again.code == ToolCode.saidNo.rawValue)
        #expect(quiet)
        #expect(stranger.asked)
    }

    @Test func aYesAndAPassFromTheEndedSessionAreNotInherited() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        _ = await open("/shop", old)
        browser.prefs.agentMode = .ask
        AgentSites.shared.reset()
        let first = await asked("/basket", old, answer: .yes)
        AgentLinks.shared.giveActPass(old, .send, site: "shop.example", quote: "Send")

        _ = try await done(old)
        let next = try #require(agent(key))
        let passed = AgentLinks.shared.takeActPass(next, .send, site: "shop.example", quote: "Send")
        let again = await asked("/basket", next, answer: .no)

        #expect(first.asked)
        #expect(!first.outcome.failed)
        #expect(!passed)
        #expect(again.asked)
    }

    @Test func aQuestionStillUpFromTheEndedSessionIsNeitherAnsweredNorDroppedByTheTakeBack() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        let mine = await open("/shop", old)
        let tab = try #require(socket.box.find(["tab": mine])?.tab)
        _ = try await done(old)
        let up = AgentQuestion(kind: .approval(.send), title: "Send the order?", task: nil, tab: tab.id, site: "shop.example")
        let waiting = Task { await AgentDesk.shared.ask(up) }
        await until { AgentDesk.shared.pending.contains { $0.id == up.id } }

        let next = try #require(agent(key))
        let listed = await call("tabs", [:], next)
        let still = AgentDesk.shared.pending.contains { $0.id == up.id }
        AgentDesk.shared.take(up.id, .no)
        let answer = await waiting.value

        #expect(ids(listed) == [mine])
        #expect(still)
        #expect(answer == .no)
    }

    @Test func afterDoneCloseThereIsNothingToTakeBack() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        _ = await open("/shop", old)
        let verb = try #require(PersonCommands.find("agents", "done"))
        var ending = PersonCall(noun: "agents", verb: "done", arguments: ["close": true], browser: browser, box: socket.box)
        ending.link = AgentLinks.shared.link(old)
        let said = try await verb.run(ending)
        let request: [String: Any] = ["agent": ["session": "claude:\(key)", "pid": 4242, "started": 1]]

        let back = socket.link(for: request, create: false, rejoin: true)

        #expect((said["closed"] as? [String])?.count == 1)
        #expect(back == nil)
        #expect(AgentWorkTabs.tabs(of: old, in: socket.box).isEmpty)
    }

    @Test func afterTheSessionEndHookTheNextCommandTakesBackTheTabs() async throws {
        let key = UUID().uuidString
        let old = try #require(agent(key))
        let mine = await open("/shop", old)
        let hook: [String: Any] = ["hook": true, "agent": ["session": "claude:\(key)", "pid": 4242, "started": 1]]
        let verb = try #require(PersonCommands.find("agents", "done"))
        var ending = PersonCall(noun: "agents", verb: "done", arguments: [:], browser: browser, box: socket.box)
        ending.link = socket.link(for: hook, create: false, rejoin: false)
        let found = ending.link?.id
        _ = try await verb.run(ending)
        let again = socket.link(for: hook, create: false, rejoin: false)

        let next = try #require(agent(key))
        let listed = await call("tabs", [:], next)

        #expect(found == old)
        #expect(again == nil)
        #expect(AgentLinks.shared.link(old)?.live == false)
        #expect(ids(listed) == [mine])
        #expect(data(listed)["current"] as? String == mine)
    }

    @Test func afterTheAgentsProcessExitsTheNextCommandTakesBackTheTabs() async throws {
        let key = UUID().uuidString
        let request: [String: Any] = ["agent": ["session": "claude:\(key)", "pid": 4545, "started": 7, "executable": "claude"]]
        let old = try #require(socket.link(for: request, create: true)).id
        made.append(old)
        let mine = await open("/shop", old)
        let alive = AgentLinks.shared.alive
        defer { AgentLinks.shared.alive = alive }
        AgentLinks.shared.alive = { pid, started in pid == 4545 ? false : alive(pid, started) }

        let gone = AgentLinks.shared.sweep()
        AgentLinks.shared.alive = alive
        let next = try #require(socket.link(for: request, create: true)).id
        made.append(next)
        let listed = await call("tabs", [:], next)

        #expect(gone.contains(old))
        #expect(next != old)
        #expect(ids(listed) == [mine])
        #expect(data(listed)["current"] as? String == mine)
    }

    @Test func theShellAndTheMCPOfOneAgentShareASession() async {
        let id = UUID().uuidString
        let shell: [String: Any] = ["agent": ["session": "claude:\(id)", "pid": 4242, "started": 1, "executable": "claude"]]
        let server: [String: Any] = ["agent": ["session": "claude:\(id)", "pid": 4343, "started": 1]]

        let first = socket.link(for: shell, create: true)
        let second = socket.link(for: server, create: true)
        if let first { made.append(first.id) }

        #expect(first != nil)
        #expect(first?.id == second?.id)
        #expect(first?.name == "Claude Code")
    }

    @Test func severalAddressesOpenTogetherWithOneWait() async {
        let link = session()

        let said = await call("open", ["url": address("/shop"), "urls": [address("/shop"), address("/basket"), address("/help")]], link)
        let rows = data(said)["opened"] as? [[String: Any]] ?? []
        let mine = AgentWorkTabs.tabs(of: link, in: socket.box).map { short($0.tab) }

        #expect(!said.failed)
        #expect(rows.map { $0["id"] as? String } == mine)
        #expect(rows.map { $0["title"] as? String } == ["Shop", "Basket", "Help"])
        #expect(rows.allSatisfy { $0["loading"] as? Bool == false })
        #expect(socket.current(link) == mine.last)
        #expect(said.text?.components(separatedBy: "\n").first?.hasPrefix(mine[0] + "  Shop  127.0.0.1") == true)
    }

    @Test func severalAddressesStillPassTheGateEachAndAreCapped() async throws {
        let link = session()
        let many = (0..<21).map { address("/shop?n=\($0)") }
        let capped = await call("open", ["urls": many], link)
        browser.prefs.agentMode = .ask

        let opening = Task { await call("open", ["urls": [address("/shop"), address("/basket")]], link) }
        let asked = await question()
        AgentDesk.shared.take(try #require(asked).id, .no)
        let said = await opening.value

        #expect(capped.code == "usage")
        #expect(asked?.kind == .approval(.tab))
        #expect(said.failed)
        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).isEmpty)
    }

    @Test func openWithASpaceAsksWhatOpenAsks() async throws {
        browser.prefs.agentMode = .ask
        let link = session()
        let verb = try #require(PersonCommands.find("tabs", "open"))
        var call = PersonCall(noun: "tabs", verb: "open", arguments: ["url": address("/shop"), "space": browser.space.name], browser: browser, box: socket.box)
        call.link = AgentLinks.shared.link(link)

        let spaced = Task { try? await verb.run(call) }
        let first = await question()
        AgentDesk.shared.take(try #require(first).id, .no)
        _ = await spaced.value
        let other = session("Codex")
        let plain = Task { await self.call("open", ["url": address("/shop")], other) }
        let second = await question()
        AgentDesk.shared.take(try #require(second).id, .no)
        _ = await plain.value

        #expect(first?.kind == second?.kind)
        #expect(first?.title == second?.title)
        #expect(first?.site == second?.site)
        #expect(first?.task == link)
        #expect(second?.task == other)
    }

    @Test func openWithASpaceIsTheSessionsTab() async throws {
        let link = session()
        let verb = try #require(PersonCommands.find("tabs", "open"))
        var call = PersonCall(noun: "tabs", verb: "open", arguments: ["url": address("/shop"), "space": browser.space.name], browser: browser, box: socket.box)
        call.link = AgentLinks.shared.link(link)
        let said = try await verb.run(call)

        #expect(AgentWorkTabs.tabs(of: link, in: socket.box).map { short($0.tab) } == [said["id"] as? String])
        #expect(socket.current(link) == said["id"] as? String)
    }

    @Test func batchStepsWorkInTheSessionsCurrentTab() async {
        let link = session()
        let bare = await socket.batch(["steps": [["tool": "press", "arguments": ["key": "Tab"], "line": "press Tab"]]], browser: browser, link: link)
        let reply = await socket.batch(["steps": [
            ["tool": "open", "arguments": ["url": address("/shop")], "line": "open"],
            ["tool": "navigate", "arguments": ["url": address("/basket")], "line": "go"],
        ]], browser: browser, link: link)
        let mine = AgentWorkTabs.tabs(of: link, in: socket.box)

        #expect((bare["error"] as? [String: Any])?["code"] as? String == "no_tab")
        #expect(reply["ok"] as? Bool == true)
        #expect(mine.count == 1)
        #expect(mine.first.map { AgentWorkTabs.title($0.tab) } == "Basket")
        #expect(socket.current(link) == mine.first.map { short($0.tab) })
    }

    @Test func batchStepsOverMCPLandInTheSessionsCurrentTab() async {
        let link = session()
        let box = AgentSessionBox(socket: socket, browser: browser)
        let server = MCPServer(box: box, task: link) { _ in }
        _ = await box.call("open", ["url": address("/shop")], task: link)

        let said = await server.batch(["steps": [
            ["tool": "navigate", "arguments": ["url": address("/basket")], "line": "go"],
            ["tool": "text", "arguments": [:], "line": "read"],
        ]])
        let mine = AgentWorkTabs.tabs(of: link, in: socket.box)

        #expect(!said.failed)
        #expect(mine.count == 1)
        #expect(mine.first.map { AgentWorkTabs.title($0.tab) } == "Basket")
        #expect(socket.current(link) == mine.first.map { short($0.tab) })
    }

    private func atWork(_ link: UUID) -> Bool {
        AgentLinks.shared.link(link).map(AgentAwake.atWork) ?? false
    }

    @Test func aFinishedSessionWithTabsLeftReleasesTheHoldAndTheNextCommandTakesIt() async {
        let link = session()
        _ = await open("/shop", link)
        await until { AgentAwake.holding }
        let working = atWork(link)

        AgentLinks.shared.finish(link)
        let finished = atWork(link)
        let released = AgentAwake.holding == AgentAwake.anyAtWork
        AgentLinks.shared.heard(link)
        _ = await call("snapshot", [:], link)

        #expect(working)
        #expect(!finished)
        #expect(!AgentBoard.allTabs(of: link).isEmpty)
        #expect(released)
        #expect(atWork(link))
        #expect(AgentAwake.holding)
    }

    @Test func anIdleSessionWithTabsLeftReleasesTheHoldAndTheNextCommandTakesIt() async {
        let link = session()
        _ = await open("/shop", link)
        let limit = AgentLinks.shared.quietLimit
        defer { AgentLinks.shared.quietLimit = limit }
        AgentLinks.shared.quietLimit = 0

        AgentLinks.shared.sweep(at: Date().addingTimeInterval(1))
        let idle = AgentLinks.shared.link(link)?.rest == .quiet
        let resting = atWork(link)
        let released = AgentAwake.holding == AgentAwake.anyAtWork
        AgentLinks.shared.heard(link)
        _ = await call("tab", [:], link)

        #expect(idle)
        #expect(!resting)
        #expect(released)
        #expect(atWork(link))
        #expect(AgentAwake.holding)
    }

    @Test func anEndedSessionWithTabsLeftReleasesTheHoldAndANewCommandTakesIt() async {
        let link = session()
        _ = await open("/shop", link)

        AgentLinks.shared.end(link, .done(nil))
        let ended = atWork(link)
        let released = AgentAwake.holding == AgentAwake.anyAtWork
        let next = session()
        _ = await open("/basket", next)
        await until { AgentAwake.holding }

        #expect(!ended)
        #expect(!AgentBoard.allTabs(of: link).isEmpty)
        #expect(released)
        #expect(atWork(next))
    }

    @Test func aQuestionUpForThePersonCountsAsAtWork() async throws {
        let link = session()
        _ = await open("/shop", link)
        browser.prefs.agentMode = .ask
        AgentSites.shared.reset()

        let opening = Task { await call("open", ["url": address("/basket")], link) }
        let asked = try #require(await question())
        AgentLinks.shared.finish(link)
        let waiting = atWork(link)
        let holding = AgentAwake.holding
        AgentDesk.shared.take(asked.id, .no)
        _ = await opening.value
        AgentLinks.shared.finish(link)

        #expect(waiting)
        #expect(holding)
        #expect(!atWork(link))
        #expect(AgentAwake.holding == AgentAwake.anyAtWork)
    }

    @Test func closeAndTabsGainTheirFlagsAndTabIsACommand() {
        let tools = socket.box.tools
        let close = tools.first { $0.name == "close" }
        let tabs = tools.first { $0.name == "tabs" }
        let command = AgentCatalog.commands(tools).first { $0["name"] as? String == "tab" }

        #expect(close?.properties["others"] != nil)
        #expect(close?.properties["all"] != nil)
        #expect(close?.required.isEmpty == true)
        #expect(tabs?.properties["all"] != nil)
        #expect((command?["positional"] as? [[String: Any]])?.first?["name"] as? String == "id")
        #expect(command?["tabbed"] as? Bool == false)
    }
}

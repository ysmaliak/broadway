import AppKit
import Testing
@testable import Search

final class RemoteJudge: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    let remote: OpenRouterDecider
    let namer = FakeGroupEngine()

    init(_ remote: OpenRouterDecider) {
        self.remote = remote
    }

    var batch: Int { remote.batch }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        try await remote.decide(ask)
    }

    func fits(_ tab: AIGroupTab, in group: AIGroupInfo) async throws -> AIGroupFit {
        try await remote.fits(tab, in: group)
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        try await namer.name(ask)
    }
}

final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var asked: Int { lock.withLock { count } }

    func ask(_ link: String?) -> MacGroupEngine.Probe {
        { _, _, _ in
            self.lock.withLock { self.count += 1 }
            guard let link else { throw ProviderError.failed("The model is busy") }
            return ["folder": "a trip", "tab": "a page", "link": link]
        }
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AIGroupJudgeTests {
    private func browser(_ pages: [(String, String)]) -> Browser {
        keepSetting(AIGroups.shared, \.on, AIGroups.onKey)
        keepSetting(AIGroups.shared, \.emoji, AIGroups.emojiKey)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        for (index, page) in pages.enumerated() {
            if index > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: page.1)!, title: page.0)
            browser.tabs.last?.cameBack = false
        }
        let groups = AIGroups.shared
        groups.on = true
        groups.emoji = true
        groups.quiet = 0.05
        groups.gap = 0.3
        groups.timeout = 5
        addTeardownBlock { @MainActor in
            AIGroups.shared.standIn = nil
            AIGroups.shared.quiet = 1.5
            AIGroups.shared.gap = 4
            AIGroups.shared.timeout = 25
            AIGroups.shared.stop = 8
            browser.closeAll()
        }
        return browser
    }

    private func titled(_ browser: Browser, _ title: String) -> Tab {
        browser.tabs.first { $0.title == title }!
    }

    private func settle(_ seconds: Double = 0.8) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func lisbon() -> Browser {
        browser([("Lisbon flights", "https://booking.com/flights"),
                 ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                 ("Lisbon museums", "https://visitlisboa.com/museums"),
                 ("Swift docs", "https://developer.apple.com/documentation/swift")])
    }

    @discardableResult
    private func folder(_ browser: Browser, _ titles: [String], name: String = "Lisbon", change: (inout TabGroup) -> Void = { _ in }) -> UUID {
        var group = TabGroup(id: UUID(), name: name, collapsed: false)
        group.ai = true
        group.pinned = false
        change(&group)
        browser.tabGroups.append(group)
        for title in titles { titled(browser, title).groupID = group.id }
        browser.arrangeGroupedTabs()
        return group.id
    }

    private func born(_ browser: Browser, _ title: String, _ address: String, from source: String, lands: Bool = true) -> Tab {
        let url = URL(string: address)!
        let tab = browser.open(url, foreground: false, from: titled(browser, source), mayWait: true, link: true)
        tab.restore(url: url, title: title)
        tab.cameBack = false
        if lands { AIGroups.shared.landed(tab, in: browser) }
        return tab
    }

    @Test func aClearNoPutsTheTabOutRightUnderTheFolder() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
        let front = browser.active

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        #expect(pasta.groupID == id)
        await settle()

        #expect(pasta.groupID == nil)
        #expect(browser.tabs.map(\.title) == ["Lisbon flights", "Lisbon hotels", "Lisbon museums", "Pasta recipes", "Swift docs"])
        #expect(browser.listItems(browser.tabs).map(\.id) == [id, pasta.id, titled(browser, "Swift docs").id])
        #expect(browser.active === front)
        #expect(browser.tabGroups.first { $0.id == id }?.aiRefused == [])
        #expect(engine.fitAsks.map(\.tab.title) == ["Pasta recipes"])
        #expect(engine.fitAsks.first?.group.members.map(\.title) == ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
    }

    @Test func aYesOrAnUnsureAnswerKeepsTheTab() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        engine.verdicts = ["Tram 28 timetable": .unsure]
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let trams = born(browser, "Lisbon trams", "https://carris.example/trams", from: "Lisbon hotels")
        let timetable = born(browser, "Tram 28 timetable", "https://carris.example/28", from: "Lisbon hotels")
        await settle()

        #expect(trams.groupID == id)
        #expect(timetable.groupID == id)
        #expect(Set(engine.fitAsks.map(\.tab.title)) == ["Lisbon trams", "Tram 28 timetable"])
        #expect(trams.bornIn == nil)
        #expect(timetable.bornIn == nil)
    }

    @Test func aFailingEngineKeepsTheTab() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        engine.failing = true
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        await settle()

        #expect(engine.fitAsks.count == 1)
        #expect(pasta.groupID == id)
    }

    @Test func aSlowEngineKeepsTheTab() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        engine.delay = 2
        AIGroups.shared.standIn = engine
        AIGroups.shared.timeout = 0.2
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        await settle(1.2)

        #expect(engine.fitAsks.count == 1)
        #expect(pasta.groupID == id)
    }

    @Test func offlineOnOpenRouterKeepsTheTab() async {
        let browser = lisbon()
        DecisionsStub.answer("offline.test") { _, _ in DecisionsStub.Reply(failure: URLError(.notConnectedToInternet)) }
        AIGroups.shared.standIn = RemoteJudge(OpenRouterDeciderTests.decider("offline.test"))
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        await settle()

        #expect(DecisionsStub.seen("offline.test").count >= 1)
        #expect(pasta.groupID == id)
    }

    @Test func aClearNoOnOpenRouterPutsTheTabOutAndAMiddleChanceKeepsIt() async {
        let browser = lisbon()
        DecisionsStub.answer("judged.test", DecisionsStub.chances { tab, _ in tab == "Pasta recipes" ? 0.1 : 0.55 })
        AIGroups.shared.standIn = RemoteJudge(OpenRouterDeciderTests.decider("judged.test"))
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        let cafes = born(browser, "Cafés near Rossio", "https://cafes.example/rossio", from: "Lisbon flights")
        await settle()

        #expect(pasta.groupID == nil)
        #expect(cafes.groupID == id)
    }

    @Test func thisMacsFailureIsNotCachedAsANo() async throws {
        MacGroupEngine.forget()
        let group = AIGroupInfo(id: UUID(), name: "Lisbon", members: [OpenRouterDeciderTests.tab("Lisbon flights", "booking.com"),
                                                                       OpenRouterDeciderTests.tab("Lisbon hotels", "airbnb.com")])
        let tab = OpenRouterDeciderTests.tab("Belém tower tickets", "torrebelem.pt")
        let counter = ProbeCounter()

        #expect(try await MacGroupEngine.fitting(group, tab, probe: counter.ask(nil)) == .unsure)
        #expect(try await MacGroupEngine.fitting(group, tab, probe: counter.ask("")) == .unsure)
        #expect(try await MacGroupEngine.fitting(group, tab, probe: counter.ask("the same specific thing")) == .yes)
        #expect(try await MacGroupEngine.fitting(group, tab, probe: counter.ask(nil)) == .yes)
        #expect(counter.asked == 3)
        MacGroupEngine.forget()
    }

    @Test func thisMacSaysNoOnNothingInCommonAndNeverAgainstATogether() async throws {
        let group = AIGroupInfo(id: UUID(), name: "Kyoto", members: [OpenRouterDeciderTests.tab("Hotels in Gion", "booking.com"),
                                                                      OpenRouterDeciderTests.tab("Kyoto in three days", "japan-guide.com")])
        let elsewhere = OpenRouterDeciderTests.tab("Fushimi Inari crowds", "insidekyoto.com")
        let sameSite = OpenRouterDeciderTests.tab("Hotels in Lisbon", "booking.com")
        let cases: [([String], AIGroupTab, AIGroupFit)] = [
            (["nothing", "nothing"], elsewhere, .no),
            (["nothing", "the same specific thing"], elsewhere, .unsure),
            (["the same errand or task"], elsewhere, .yes),
            (["only the website", "only the website"], elsewhere, .unsure),
            (["only the website", "only the website"], sameSite, .no),
            (["only the kind of page", "only the kind of page"], elsewhere, .unsure),
            (["nothing", "only the website"], elsewhere, .no),
        ]
        for (answers, tab, wanted) in cases {
            MacGroupEngine.forget()
            let said = ProbeCounter()
            let answer: MacGroupEngine.Probe = { instructions, prompt, fields in
                try await said.ask(answers[min(said.asked, answers.count - 1)])(instructions, prompt, fields)
            }
            #expect(try await MacGroupEngine.stays(group, tab, probe: answer) == wanted, "\(answers) \(tab.host)")
            #expect(said.asked == answers.count, "\(answers)")
        }
        MacGroupEngine.forget()
    }

    @Test func aProvisionalFolderKeepsTheTabUnasked() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
        AIGroups.shared.grouper(for: browser).nameSoon(id)

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        await settle()

        #expect(engine.fitAsks.isEmpty)
        #expect(pasta.groupID == id)
    }

    @Test func aFolderWithOneOtherTabKeepsTheTabUnasked() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights"])

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        await settle()

        #expect(engine.fitAsks.isEmpty)
        #expect(pasta.groupID == id)
    }

    @Test func fiveUnrelatedTabsOpenedInARowDoNotKeepEachOtherIn() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
        let pages = [("Pasta recipes", "https://food.example/food/pasta"), ("Chess openings", "https://chess.example/openings"),
                     ("Tax deadlines", "https://tax.example/tax"), ("Rust ownership", "https://rust.example/book/ch04"),
                     ("Yoga for runners", "https://yoga.example/runners")]

        let tabs = pages.map { born(browser, $0.0, $0.1, from: "Lisbon flights", lands: false) }
        for tab in tabs { AIGroups.shared.landed(tab, in: browser) }
        await settle(1.2)

        #expect(tabs.allSatisfy { $0.groupID == nil })
        #expect(browser.tabs(in: id).map(\.title) == ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
        #expect(engine.fitAsks.count == 5)
        #expect(engine.fitAsks.allSatisfy { $0.group.members.map(\.title) == ["Lisbon flights", "Lisbon hotels", "Lisbon museums"] })
        #expect(!browser.tabGroups.contains { $0.id != id })
    }

    @Test func aTabPutOutIsNotPutBackInThatFolder() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        engine.verdicts = ["Lisbon sourdough bakeries": .no]
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
        let grouper = AIGroups.shared.grouper(for: browser)

        let bread = born(browser, "Lisbon sourdough bakeries", "https://bread.example/lisbon", from: "Lisbon flights")
        await settle()
        #expect(bread.groupID == nil)
        #expect(engine.asks.last?.fresh.map(\.title) == ["Lisbon sourdough bakeries"])
        #expect(engine.asks.last?.groups.map(\.id) == [id])

        await grouper.regroup()
        let trams = born(browser, "Lisbon trams", "https://carris.example/trams", from: "Swift docs")
        await settle()

        #expect(trams.groupID == id)
        #expect(bread.groupID == nil)
        #expect(grouper.away[bread.id] == [id])
        #expect(browser.tabGroups.first { $0.id == id }?.aiRefused == [])
    }

    @Test func aTabMovedByHandIsNeverJudged() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights", lands: false)
        browser.move(pasta, toGroup: nil)
        browser.move(pasta, toGroup: id)
        let chess = born(browser, "Chess openings", "https://chess.example/openings", from: "Swift docs", lands: false)
        browser.move(chess, toGroup: id)
        AIGroups.shared.landed(pasta, in: browser)
        AIGroups.shared.landed(chess, in: browser)
        await settle()

        #expect(engine.fitAsks.isEmpty)
        #expect(pasta.groupID == id)
        #expect(chess.groupID == id)
    }

    @Test func aTabDraggedBackAfterBeingPutOutStays() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
        let grouper = AIGroups.shared.grouper(for: browser)
        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        await settle()
        #expect(pasta.groupID == nil)

        browser.move(pasta, toGroup: id)
        pasta.restore(url: URL(string: "https://food.example/food/pasta/carbonara")!, title: "Carbonara")
        AIGroups.shared.landed(pasta, in: browser)
        await settle()
        await grouper.regroup()

        #expect(pasta.groupID == id)
        #expect(engine.fitAsks.count == 1)
    }

    @Test func aTabIsJudgedOnceOnItsFirstLanding() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let trams = born(browser, "Lisbon trams", "https://carris.example/trams", from: "Lisbon flights")
        await settle()
        trams.restore(url: URL(string: "https://food.example/food/pasta")!, title: "Pasta recipes")
        AIGroups.shared.landed(trams, in: browser)
        await settle()

        #expect(trams.groupID == id)
        #expect(engine.fitAsks.count == 1)
    }

    @Test func handMadeLiveAndSearchFoldersAreNeverJudged() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let hand = browser.addTabGroup(containing: titled(browser, "Lisbon flights"))
        let search = folder(browser, ["Lisbon museums", "Lisbon hotels", "Swift docs"], name: "Lisbon search") { $0.query = "lisbon" }
        var feed = TabGroup(id: UUID(), name: "Feed", collapsed: false)
        feed.ai = true
        feed.live = true

        let one = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        let two = born(browser, "Tax deadlines", "https://tax.example/tax", from: "Lisbon museums")
        await settle()

        #expect(engine.fitAsks.isEmpty)
        #expect(one.groupID == hand)
        #expect(two.groupID == search)
        #expect(!AIGrouper.automatic(feed))
        #expect(!AIGrouper.automatic(browser.tabGroups.first { $0.id == search }!))
        #expect(!AIGrouper.automatic(browser.tabGroups.first { $0.id == hand }!))
    }

    @Test func aDuplicatedTabIsNeverJudged() async throws {
        let browser = browser([("Lisbon flights", "https://flights.example/lisbon"),
                               ("Lisbon hotels", "https://hotels.example/lisbon"),
                               ("Lisbon museums", "https://museums.example/lisbon")])
        let engine = FakeGroupEngine()
        engine.verdicts = ["Lisbon flights": .no]
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])
        let flights = titled(browser, "Lisbon flights")
        browser.select(flights)

        browser.duplicate()
        let copy = try #require(browser.active)
        copy.restore(url: URL(string: "https://flights.example/lisbon")!, title: "Lisbon flights")
        copy.cameBack = false
        AIGroups.shared.landed(copy, in: browser)
        await settle()

        #expect(copy !== flights)
        #expect(copy.groupID == id)
        #expect(engine.fitAsks.isEmpty)
    }

    @Test func aTabThatLandsWhileLeftOutLosesItsMark() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights", lands: false)
        pasta.agent = true
        AIGroups.shared.landed(pasta, in: browser)
        pasta.agent = false
        pasta.restore(url: URL(string: "https://food.example/food/pizza")!, title: "Pizza dough")
        AIGroups.shared.landed(pasta, in: browser)
        await settle()

        #expect(pasta.bornIn == nil)
        #expect(pasta.groupID == id)
        #expect(engine.fitAsks.isEmpty)
    }

    @Test func afterOneFailureThePassAsksNoMore() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        engine.failing = true
        AIGroups.shared.standIn = engine
        let id = folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"])

        let tabs = [("Pasta recipes", "https://food.example/pasta"), ("Chess openings", "https://chess.example/openings"),
                    ("Tax deadlines", "https://tax.example/tax")].map { born(browser, $0.0, $0.1, from: "Lisbon flights", lands: false) }
        for tab in tabs { AIGroups.shared.landed(tab, in: browser) }
        await settle()

        #expect(engine.fitAsks.count == 1)
        #expect(tabs.allSatisfy { $0.groupID == id && $0.bornIn == nil })
    }

    @Test func aRenamedAutomaticFolderIsStillJudged() async {
        let browser = lisbon()
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        folder(browser, ["Lisbon flights", "Lisbon hotels", "Lisbon museums"], name: "Holiday") { $0.userNamed = true }

        let pasta = born(browser, "Pasta recipes", "https://food.example/food/pasta", from: "Lisbon flights")
        await settle()

        #expect(engine.fitAsks.count == 1)
        #expect(pasta.groupID == nil)
    }

    @Test func theJudgeAsksOpenRouterWhatGroupingAsks() async throws {
        let decider = OpenRouterDeciderTests.decider("fits.test")
        let flights = OpenRouterDeciderTests.tab("Flights to Lisbon", "skyscanner.net", by: "Skyscanner")
        let hotels = OpenRouterDeciderTests.tab("Hotels in Lisbon", "booking.com")
        let trams = OpenRouterDeciderTests.tab("Tram 28", "carris.pt")
        let group = AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [flights, hotels, trams], refused: ["x"])
        let video = OpenRouterDeciderTests.tab("Pasta at home", "youtube.com", "/watch", query: "v=1", by: "Sam Rowe")
        DecisionsStub.answer("fits.test", DecisionsStub.chances { _, _ in 0.1 })

        let fit = try await decider.fits(video, in: group)

        let seen = DecisionsStub.seen("fits.test")
        #expect(fit == .no)
        #expect(seen.count == 1)
        let body = try #require(seen.first?.body)
        let wanted = try #require(decider.requests(AIGroupAsk(groups: [group], loose: [], fresh: [video])).first)
        #expect(body == (try OpenRouterDecider.encoded(wanted.body)))
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(sent.keys) == ["model", "state", "questions"])
        let questions = try #require(sent["questions"] as? [String: [String: Any]])
        var people: [[String: Any]] = [((sent["state"] as? [String: Any])?["tab"] as? [String: Any]) ?? [:]]
        for question in questions.values {
            let instructions = question["instructions"] as? [String: Any] ?? [:]
            #expect(Set(instructions.keys).isSubset(of: ["question", "other", "folder"]))
            if let other = instructions["other"] as? [String: Any] { people.append(other) }
            people += ((instructions["folder"] as? [String: Any])?["tabs"] as? [[String: Any]]) ?? []
            let asked = instructions["question"] as? String
            #expect([OpenRouterDecider.sameFolder, OpenRouterDecider.sameTab, OpenRouterDecider.sameCreator].contains(asked))
        }
        #expect(people.count > 3)
        for seen in people { #expect(Set(seen.keys).isSubset(of: ["title", "site", "by"])) }
        let text = String(decoding: body, as: UTF8.self)
        for leak in ["/watch", "v=1", "https"] { #expect(!text.contains(leak), "\(leak) in \(text)") }
    }

    @Test func openRouterChancesReadAsYesStayOrNo() async throws {
        let decider = OpenRouterDeciderTests.decider("bars.test")
        let group = AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [OpenRouterDeciderTests.tab("Flights to Lisbon", "skyscanner.net"),
                                                                            OpenRouterDeciderTests.tab("Hotels in Lisbon", "booking.com")])
        let tab = OpenRouterDeciderTests.tab("Cafés near Rossio", "timeout.com")
        var said: [Double: AIGroupFit] = [:]
        for chance in [0.1, 0.49, 0.5, 0.59, 0.6, 0.9] {
            DecisionsStub.answer("bars.test", DecisionsStub.chances { _, _ in chance })
            said[chance] = try await decider.fits(tab, in: group)
        }

        #expect(said == [0.1: .no, 0.49: .no, 0.5: .unsure, 0.59: .unsure, 0.6: .yes, 0.9: .yes])
    }

    @Test func aRefusalOnOpenRouterIsNotANo() async throws {
        let decider = OpenRouterDeciderTests.decider("refuses.test")
        let group = AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [OpenRouterDeciderTests.tab("Flights to Lisbon", "skyscanner.net"),
                                                                            OpenRouterDeciderTests.tab("Hotels in Lisbon", "booking.com")])
        let tab = OpenRouterDeciderTests.tab("Cafés near Rossio", "timeout.com")
        DecisionsStub.answer("refuses.test") { _, body in
            var answers: [String: Any] = [:]
            for id in DecisionsStub.asked(body).questions.keys { answers[id] = ["type": "refusal"] }
            return DecisionsStub.Reply(body: DecisionsStub.nouls(answers))
        }

        #expect(try await decider.fits(tab, in: group) == .unsure)
    }

    @Test func theChainSendsOpenRouterNoPathAndAFailureIsNotTakenToThisMac() async throws {
        let mac = FakeGroupEngine()
        let remote = FakeGroupEngine()
        remote.failing = true
        let chain = AIGroupDeciderChain(remote: remote, mac: mac, report: { _ in })
        let group = AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [OpenRouterDeciderTests.tab("Lisbon flights", "booking.com", "/flights")])
        let tab = OpenRouterDeciderTests.tab("Pasta recipes", "bbc.co.uk", "/food/pasta", query: "a=1")

        await #expect(throws: (any Error).self) { try await chain.fits(tab, in: group) }

        #expect(mac.fitAsks.isEmpty)
        #expect(remote.fitAsks.first?.tab.path == "")
        #expect(remote.fitAsks.first?.tab.query == "")
        #expect(remote.fitAsks.first?.group.members.first?.path == "")
    }
}

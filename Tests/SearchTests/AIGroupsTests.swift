import AppKit
import Testing
@testable import Search

final class ScriptedGroupEngine: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    private let lock = NSLock()
    private var decided: [AIGroupAsk] = []
    private var named: [AIGroupNameAsk] = []
    var picking: @Sendable (AIGroupAsk) -> [UUID: AIGroupPick]
    var naming: @Sendable (AIGroupNameAsk) -> AIGroupName

    init(picking: @escaping @Sendable (AIGroupAsk) -> [UUID: AIGroupPick],
         naming: @escaping @Sendable (AIGroupNameAsk) -> AIGroupName) {
        self.picking = picking
        self.naming = naming
    }

    var asks: [AIGroupAsk] { lock.withLock { decided } }
    var nameAsks: [AIGroupNameAsk] { lock.withLock { named } }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        lock.withLock { decided.append(ask) }
        return picking(ask)
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        lock.withLock { named.append(ask) }
        return naming(ask)
    }
}

final class HeldNamer: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    private let lock = NSLock()
    private var answer: AIGroupName?
    private var asked = 0

    var nameAsks: Int { lock.withLock { asked } }

    func give(_ name: AIGroupName) {
        lock.withLock { answer = name }
    }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        guard let first = ask.fresh.first else { return [:] }
        return Dictionary(uniqueKeysWithValues: ask.fresh.dropFirst().map { ($0.id, AIGroupPick.tab(first.id)) })
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        lock.withLock { asked += 1 }
        while true {
            if let given = lock.withLock({ answer }) { return given }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AIGroupsTests {
    private func tab(_ title: String, _ address: String) -> AIGroupTab {
        AIGroupTab(id: UUID(), title: title, url: URL(string: address))!
    }

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

    private func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test func aNewTabJoinsTheGroupItBelongsIn() {
        let docs = tab("Swift docs", "https://developer.apple.com/documentation/swift")
        let group = AIGroupInfo(id: UUID(), name: "Swift", members: [docs])
        let fresh = tab("SwiftData", "https://developer.apple.com/documentation/swiftdata")
        let ask = AIGroupAsk(groups: [group], loose: [], fresh: [fresh])

        let plan = AIGroupRules.plan(ask, picks: [fresh.id: .group(group.id)])

        #expect(plan.joins == [fresh.id: group.id])
        #expect(plan.formed.isEmpty)
    }

    @Test func aNewTabStartsAGroupWithALooseTab() {
        let flights = tab("Flights to Lisbon", "https://booking.com/flights")
        let hotels = tab("Hotels in Lisbon", "https://airbnb.com/s/lisbon")
        let ask = AIGroupAsk(groups: [], loose: [flights], fresh: [hotels])

        let plan = AIGroupRules.plan(ask, picks: [hotels.id: .tab(flights.id)])

        #expect(plan.formed.map(Set.init) == [Set([flights.id, hotels.id])])
        #expect(plan.joins.isEmpty)
    }

    @Test func chainedPicksMakeOneGroup() {
        let flights = tab("Flights to Lisbon", "https://booking.com/flights")
        let hotels = tab("Hotels in Lisbon", "https://airbnb.com/s/lisbon")
        let museums = tab("Lisbon museums", "https://visitlisboa.com/museums")
        let ask = AIGroupAsk(groups: [], loose: [flights], fresh: [hotels, museums])

        let plan = AIGroupRules.plan(ask, picks: [hotels.id: .tab(flights.id), museums.id: .tab(hotels.id)])

        #expect(plan.formed.map(Set.init) == [Set([flights.id, hotels.id, museums.id])])
    }

    @Test func aTabStaysLooseWhenNothingFitsOrTheAnswerIsNonsense() {
        let news = tab("Hacker News", "https://news.ycombinator.com/")
        let other = tab("YouTube", "https://youtube.com/")
        let ask = AIGroupAsk(groups: [], loose: [], fresh: [news, other])

        let plan = AIGroupRules.plan(ask, picks: [news.id: .none, other.id: .group(UUID())])

        #expect(plan.isEmpty)
    }

    @Test func aTabTheUserTookOutNeverGoesBack() {
        let docs = tab("Swift docs", "https://developer.apple.com/documentation/swift")
        let taken = tab("SwiftUI", "https://developer.apple.com/documentation/swiftui")
        let group = AIGroupInfo(id: UUID(), name: "Swift", members: [docs], refused: [taken.key])
        let ask = AIGroupAsk(groups: [group], loose: [], fresh: [taken])

        let plan = AIGroupRules.plan(ask, picks: [taken.id: .group(group.id)])

        #expect(plan.isEmpty)
    }

    @Test func tabsTheUserUngroupedDontComeBackTogether() {
        let flights = tab("Flights to Lisbon", "https://booking.com/flights")
        let hotels = tab("Hotels in Lisbon", "https://airbnb.com/s/lisbon")
        let ask = AIGroupAsk(groups: [], loose: [flights], fresh: [hotels])

        let plan = AIGroupRules.plan(ask, picks: [hotels.id: .tab(flights.id)], dismissed: [[flights.key, hotels.key]])

        #expect(plan.isEmpty)
    }

    @Test func thePromptHoldsOnlyTitleHostAndPath() throws {
        let shown = try #require(AIGroupTab(id: UUID(), title: "Inbox (3)",
                                             url: URL(string: "https://me:pw@www.mail.example.com/u/0/inbox?token=SECRET#frag")))
        let ask = AIGroupAsk(groups: [AIGroupInfo(id: UUID(), name: "Mail", members: [shown])], loose: [shown], fresh: [shown])

        let texts = [AIGroupPrompt.deciding(ask), AIGroupPrompt.jsonDeciding(ask),
                     AIGroupPrompt.naming(AIGroupNameAsk(tabs: [shown], current: nil, currentEmoji: nil, emoji: true))]

        #expect(shown.host == "mail.example.com")
        #expect(shown.path == "/u/0/inbox")
        for text in texts {
            #expect(text.contains("Inbox (3)"))
            #expect(text.contains("mail.example.com"))
            for leak in ["SECRET", "token", "frag", "pw@", "me:pw", "https"] { #expect(!text.contains(leak), "\(leak) in \(text)") }
        }
    }

    @Test func aBlankOrUntitledTabIsNotAsked() {
        #expect(AIGroupTab(id: UUID(), title: "", url: URL(string: "https://example.com/")) == nil)
        #expect(AIGroupTab(id: UUID(), title: "New Tab", url: nil) == nil)
        #expect(AIGroupTab(id: UUID(), title: "Settings", url: URL(string: "search://settings")) == nil)
    }

    @Test func thisMacNeverRunsInATest() async {
        let ask = AIGroupAsk(groups: [], loose: [], fresh: [tab("Hacker News", "https://news.ycombinator.com/")])

        do {
            _ = try await MacGroupEngine().decide(ask)
            Issue.record("a test ran the on-device model")
        } catch {
            #expect((error as? ProviderError) == .refused("A test run never calls a real model"))
        }
    }

    @Test func aNameIsKeptWhileItStillFitsEveryTab() {
        let flights = tab("Flights from Berlin to Lisbon", "https://booking.com/flights")
        let hotels = tab("Hotels in Lisbon, Alfama district", "https://airbnb.com/s/lisbon")
        let food = tab("Lisbon food guide", "https://timeout.com/lisbon/food")
        let algarve = tab("Algarve beaches guide", "https://visitalgarve.pt/beaches")
        let charts = tab("Swift Charts | Apple Developer Documentation", "https://developer.apple.com/documentation/charts")
        let views = tab("NavigationSplitView | Apple Developer Documentation", "https://developer.apple.com/documentation/swiftui")

        #expect(AIGroupPrompt.fits("Lisbon trip", [flights, hotels, food]))
        #expect(!AIGroupPrompt.fits("Lisbon trip", [flights, hotels, algarve]))
        #expect(!AIGroupPrompt.fits("SwiftUI", [views, charts]))
        #expect(!AIGroupPrompt.fits("🧳", [flights]))
    }

    @Test func namesAreCleanedAndEmojiIsOne() {
        let name = AIGroupName.cleaned(name: "  \"Planning a trip to Lisbon in December\". ", emoji: "✈️🧳 travel", keep: false)

        #expect(name?.name == "Planning a trip to Lisbon in December")
        #expect(name?.emoji == "✈️")
        #expect(AIGroupName.cleaned(name: "", emoji: nil, keep: false) == nil)
        #expect(AIGroupName.emoji(in: "plain") == nil)
        #expect(AIGroupName.cleaned(name: "Lisbon Journey ✈️", emoji: "✈️", keep: false)?.name == "Lisbon Journey")
    }

    @Test func relatedTabsFormANamedGroupWithAnEmoji() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                               ("Swift docs", "https://developer.apple.com/documentation/swift")])
        AIGroups.shared.standIn = FakeGroupEngine()

        let outcome = await AIGroups.shared.grouper(for: browser).regroup()

        #expect(outcome.formed == 1)
        let group = browser.tabGroups.first { $0.ai }
        #expect(group?.name == "Lisbon")
        #expect(group?.icon?.emoji == "✈️")
        #expect(browser.tabs(in: group?.id).map { $0.title }.sorted() == ["Lisbon flights", "Lisbon hotels"])
        #expect(titled(browser, "Swift docs").groupID == nil)
    }

    @Test func noEmojiWhenItIsTurnedOff() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        AIGroups.shared.standIn = FakeGroupEngine()
        AIGroups.shared.emoji = false
        defer { AIGroups.shared.emoji = true }

        await AIGroups.shared.grouper(for: browser).regroup()

        let group = browser.tabGroups.first { $0.ai }
        #expect(group?.name == "Lisbon")
        #expect(group?.icon == nil)
    }

    @Test func aTabDraggedOutStaysOutAndOthersStillJoin() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                               ("Lisbon museums", "https://visitlisboa.com/museums")])
        AIGroups.shared.standIn = FakeGroupEngine()
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!
        let museums = titled(browser, "Lisbon museums")

        browser.move(museums, toGroup: nil)
        browser.newTab()
        browser.tabs.last?.restore(url: URL(string: "https://lisbon.example/food")!, title: "Lisbon food")
        browser.tabs.last?.cameBack = false
        let outcome = await grouper.regroup()

        #expect(outcome.joined == 1)
        #expect(titled(browser, "Lisbon food").groupID == group.id)
        #expect(museums.groupID == nil)
        #expect(browser.tabGroups.first { $0.id == group.id }?.aiRefused == ["visitlisboa.com/museums"])
    }

    @Test func aFolderDissolvedByADragOutIsNotFormedAgain() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        AIGroups.shared.standIn = FakeGroupEngine()
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!
        let hotels = titled(browser, "Lisbon hotels")

        browser.move(hotels, toGroup: nil)
        let outcome = await grouper.regroup()

        #expect(!browser.tabGroups.contains { $0.id == group.id })
        #expect(outcome.formed == 0)
        #expect(outcome.joined == 0)
        #expect(!browser.tabGroups.contains { $0.ai })
        #expect(browser.tabs.allSatisfy { $0.groupID == nil })
    }

    @Test func theTabLeftByACloseIsNeverPutInAFolderOfOne() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                               ("Swift docs", "https://developer.apple.com/documentation/swift")])
        AIGroups.shared.standIn = FakeGroupEngine()
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!

        browser.close(titled(browser, "Lisbon hotels"))
        let outcome = await grouper.regroup()

        #expect(!browser.tabGroups.contains { $0.id == group.id })
        #expect(outcome.formed == 0)
        #expect(titled(browser, "Lisbon flights").groupID == nil)
        #expect(browser.tabGroups.filter(\.ai).allSatisfy { folder in browser.tabs(in: folder.id).count >= 2 })
    }

    @Test func aGroupTheUserRenamedKeepsItsName() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!
        browser.renameTabGroup(group.id, to: "December")

        browser.newTab()
        browser.tabs.last?.restore(url: URL(string: "https://lisbon.example/food")!, title: "Lisbon food")
        browser.tabs.last?.cameBack = false
        let outcome = await grouper.regroup()

        #expect(outcome.joined == 1)
        #expect(outcome.renamed == 0)
        #expect(browser.tabGroups.first { $0.id == group.id }?.name == "December")
        #expect(engine.nameAsks.allSatisfy { $0.current != "December" })
    }

    @Test func aGroupIsRenamedWhenItsTabsChange() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                               ("Porto trains", "https://cp.pt/porto")])
        let engine = ScriptedGroupEngine(picking: { ask in
            var out: [UUID: AIGroupPick] = [:]
            for tab in ask.fresh {
                if tab.title.hasPrefix("Porto"), let group = ask.groups.first { out[tab.id] = .group(group.id) }
                if tab.title == "Lisbon hotels", let other = ask.fresh.first(where: { $0.title == "Lisbon flights" }) { out[tab.id] = .tab(other.id) }
            }
            return out
        }, naming: { ask in
            ask.tabs.contains { $0.title.hasPrefix("Porto") }
                ? AIGroupName(name: "Portugal trip", emoji: "🧳")
                : AIGroupName(name: "Lisbon", emoji: "✈️")
        })
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!
        #expect(group.name == "Lisbon")

        let outcome = await grouper.regroup()

        #expect(outcome.joined == 1)
        #expect(outcome.renamed == 1)
        let now = browser.tabGroups.first { $0.id == group.id }
        #expect(now?.name == "Portugal Trip")
        #expect(now?.icon?.emoji == "🧳")
    }

    @Test func aGroupThatGainsALinkedTabIsReconsidered() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        let engine = ScriptedGroupEngine(picking: { ask in
            var out: [UUID: AIGroupPick] = [:]
            if let one = ask.fresh.first, let two = ask.fresh.last, one.id != two.id { out[one.id] = .tab(two.id) }
            return out
        }, naming: { ask in
            ask.tabs.contains { $0.title.hasPrefix("Porto") }
                ? AIGroupName(name: "Portugal trip", emoji: "🧳")
                : AIGroupName(name: "Lisbon", emoji: "✈️")
        })
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!

        browser.newTab()
        let linked = browser.tabs.last!
        linked.restore(url: URL(string: "https://cp.pt/porto")!, title: "Porto trains")
        linked.cameBack = false
        linked.groupID = group.id
        grouper.landed(linked)
        await settle()

        #expect(browser.tabGroups.first { $0.id == group.id }?.name == "Portugal Trip")
        #expect(engine.asks.count == 1)
    }

    @Test func anUngroupedGroupDoesntComeBackWithTheSameTabs() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        AIGroups.shared.standIn = FakeGroupEngine()
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!

        browser.removeTabGroup(group.id)
        let outcome = await grouper.regroup()

        #expect(outcome == AIGrouper.Outcome())
        #expect(!browser.tabGroups.contains { $0.ai })
    }

    @Test func manualFoldersPinsAndPrivateTabsAreLeftAlone() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                               ("Lisbon maps", "https://maps.example/lisbon")])
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let folder = browser.addTabGroup(containing: titled(browser, "Lisbon flights"))
        let maps = titled(browser, "Lisbon maps")
        browser.pin(maps)
        addTeardownBlock { @MainActor in browser.unpin(maps) }

        let outcome = await AIGroups.shared.grouper(for: browser).regroup()

        #expect(outcome == AIGrouper.Outcome())
        #expect(titled(browser, "Lisbon flights").groupID == folder)
        #expect(engine.asks.allSatisfy { ask in ask.groups.isEmpty && !(ask.loose + ask.fresh).contains { $0.title != "Lisbon hotels" } })
    }

    @Test func tabsOpenedTogetherGetOneDecisionAndPassesAreSpacedOut() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                               ("Swift docs", "https://developer.apple.com/documentation/swift")])
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        AIGroups.shared.gap = 1.0
        let grouper = AIGroups.shared.grouper(for: browser)

        for tab in browser.tabs { grouper.landed(tab) }
        await settle(0.5)
        browser.newTab()
        browser.tabs.last?.restore(url: URL(string: "https://lisbon.example/food")!, title: "Lisbon food")
        browser.tabs.last?.cameBack = false
        grouper.landed(browser.tabs.last!)
        await settle(0.3)
        let early = engine.asks.count
        await settle(1.2)

        #expect(engine.asks.first?.fresh.count == 3)
        #expect(early == 1)
        #expect(engine.asks.count == 2)
        #expect(engine.asks.last?.fresh.map(\.title) == ["Lisbon food"])
        #expect(grouper.passes == 2)
    }

    @Test func theSameAddressIsAnsweredFromTheCache() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = browser.tabGroups.first { $0.ai }!
        let asked = engine.asks.count

        browser.newTab()
        browser.tabs.last?.restore(url: URL(string: "https://airbnb.com/s/lisbon")!, title: "Lisbon hotels again")
        browser.tabs.last?.cameBack = false
        grouper.landed(browser.tabs.last!)
        await settle()

        #expect(engine.asks.count == asked)
        #expect(browser.tabs.last?.groupID == group.id)
    }

    @Test func aFailingOrSlowEngineLeavesTabsAlone() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        let engine = FakeGroupEngine()
        engine.delay = 2
        AIGroups.shared.standIn = engine
        AIGroups.shared.timeout = 0.2

        let started = Date()
        let outcome = await AIGroups.shared.grouper(for: browser).regroup()

        #expect(Date().timeIntervalSince(started) < 1.5)
        #expect(outcome == AIGrouper.Outcome())
        #expect(!browser.tabGroups.contains { $0.ai })
        #expect(AIGroups.shared.note != nil)
    }

    @Test func nothingRunsWhileGroupingIsOff() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        let engine = FakeGroupEngine()
        AIGroups.shared.standIn = engine
        AIGroups.shared.on = false
        defer { AIGroups.shared.on = true }

        for tab in browser.tabs { AIGroups.shared.landed(tab, in: browser) }
        await settle()

        #expect(engine.asks.isEmpty)
    }

    @Test func aGroupSurvivesTheSession() throws {
        var group = TabGroup(id: UUID(), name: "Lisbon", collapsed: false)
        group.ai = true
        group.userNamed = true
        group.aiEmoji = "✈️"
        group.aiRefused = ["visitlisboa.com/museums"]

        let back = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        let old = try JSONDecoder().decode(TabGroup.self, from: Data(#"{"id":"\#(UUID().uuidString)","name":"Old"}"#.utf8))

        #expect(back == group)
        #expect(!old.ai)
        #expect(old.aiRefused.isEmpty)
    }

    private let shotQuery = "Runner смотреть онлайн на английском"

    private func shotPair() -> (search: AIGroupTab, result: AIGroupTab) {
        (tab("Runner смотреть онлайн на английском - Поиск в Google", "https://www.google.com/search?q=Runner"),
         tab("Бегущий в лабиринте (2014) бесплатно смотреть онлайн в хорошем качестве", "https://kinogo.example/1234-begushchij-v-labirinte.html"))
    }

    @Test func aNameIsOneToThreeWordsAndNeverACopy() {
        let (search, result) = shotPair()
        let tabs = [search, result]
        let hotels = tab("Lisbon hotels", "https://airbnb.com/s/lisbon")

        #expect(AIGroupNames.problem("Maze Runner", tabs: tabs, query: shotQuery) == nil)
        #expect(AIGroupNames.problem("Бегущий в лабиринте", tabs: tabs, query: shotQuery) == nil)
        #expect(AIGroupNames.problem("Lisbon Trip", tabs: [hotels]) == nil)
        #expect(AIGroupNames.problem(shotQuery, tabs: tabs, query: shotQuery) == "it has more than three words")
        #expect(AIGroupNames.problem("Runner смотреть онлайн", tabs: tabs, query: shotQuery) == "it has words like watch online, free or download")
        #expect(AIGroupNames.problem("Maze Runner watch", tabs: tabs) == "it has words like watch online, free or download")
        #expect(AIGroupNames.problem("Free Movies", tabs: tabs) == "it has words like watch online, free or download")
        #expect(AIGroupNames.problem("Бегущий (2014)", tabs: tabs) == "it reads like a page title or a sentence")
        #expect(AIGroupNames.problem("Lisbon. Hotels", tabs: [hotels]) == "it reads like a page title or a sentence")
        #expect(AIGroupNames.problem("Lisbon hotels", tabs: [hotels]) == "it copies a page title")
        #expect(AIGroupNames.problem("pizza rome", tabs: [hotels], query: "Pizza Rome") == "it copies the search")
        #expect(AIGroupNames.problem("Google", tabs: tabs) == "it is only a site's name")
        #expect(AIGroupNames.problem("Airbnb", tabs: [hotels]) == "it is only a site's name")
        #expect(AIGroupNames.problem("Tabs", tabs: tabs) == "it is too generic")
        #expect(AIGroupNames.problem("2014", tabs: tabs) == "it is only a year")
        #expect(AIGroupNames.problem("", tabs: tabs) == "it is empty")
        let borsch = [tab("Борщ классический — пошаговый рецепт с фото", "https://eda.ru/recepty/supy/borsch")]
        #expect(AIGroupNames.problem("Borsh", tabs: borsch) == "it is not in the language and alphabet of the tab titles")
        #expect(AIGroupNames.problem("Борщ", tabs: borsch) == nil)
        #expect(AIGroupNames.problem("Lisbon Trip", tabs: [hotels]) == nil)
    }

    @Test func namesAreTitleCasedWhereTheLanguageHasIt() {
        #expect(AIGroupNames.cased("maze runner") == "Maze Runner")
        #expect(AIGroupNames.cased("lord of the rings") == "Lord of the Rings")
        #expect(AIGroupNames.cased("SwiftUI layout") == "SwiftUI Layout")
        #expect(AIGroupNames.cased("бегущий в лабиринте") == "Бегущий в лабиринте")
        #expect(AIGroupNames.cased("Бегущий В Лабиринте") == "Бегущий В Лабиринте")
        #expect(AIGroupNames.cased("maze runner 2014") == "Maze Runner")
        #expect(AIGroupNames.cased("budget 2026") == "Budget 2026")
        #expect(AIGroupNames.cased("東京 旅行") == "東京 旅行")
    }

    @Test func theFallbackDropsQueryFillerInsteadOfCuttingATitle() {
        let (search, result) = shotPair()
        let flights = tab("Flights from Berlin to Lisbon", "https://booking.com/flights")
        let hotels = tab("Hotels in Lisbon, Alfama district", "https://airbnb.com/s/lisbon")
        let one = tab("Swift docs", "https://developer.apple.com/documentation/swift")
        let two = tab("SwiftData", "https://developer.apple.com/documentation/swiftdata")
        let news = tab("Hacker News", "https://news.ycombinator.com/")

        #expect(AIGroupNames.fallback([search, result], query: shotQuery) == "Runner")
        #expect(AIGroupNames.fromQuery("the maze runner watch online free") == "Maze Runner")
        #expect(AIGroupNames.fromQuery("бегущий в лабиринте смотреть онлайн бесплатно в хорошем качестве") == "Бегущий в лабиринте")
        #expect(AIGroupNames.fromQuery("pizza rome") == "Pizza Rome")
        #expect(AIGroupNames.fromQuery("смотреть онлайн бесплатно") == nil)
        #expect(AIGroupNames.fallback([flights, hotels]) == "Lisbon")
        #expect(AIGroupNames.fallback([one, two]) == "Apple")
        #expect(AIGroupNames.fallback([news, flights]) == "Tabs")
    }

    @Test func anEchoedNameIsAskedAgainWithTheReason() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights")])
        let (search, result) = shotPair()
        let engine = ScriptedGroupEngine(picking: { _ in [:] }, naming: { ask in
            ask.rejected.isEmpty ? AIGroupName(name: "Runner смотреть онлайн на английском", emoji: "🎬")
                                 : AIGroupName(name: "maze runner", emoji: "🎬")
        })
        let grouper = AIGroups.shared.grouper(for: browser)
        let ask = AIGroupNameAsk(tabs: [search, result], current: nil, currentEmoji: nil, emoji: true, query: shotQuery)

        let said = await grouper.resolve(engine, ask)

        #expect(said.name == AIGroupName(name: "Maze Runner", emoji: "🎬"))
        #expect(said.how == "model on a second ask")
        #expect(engine.nameAsks.count == 2)
        #expect(engine.nameAsks.last?.rejected == ["“Runner смотреть онлайн на английском”, because it has more than three words"])
        #expect(AIGroupPrompt.naming(engine.nameAsks.last!).contains("Not allowed: “Runner смотреть онлайн на английском”"))
        #expect(AIGroupPrompt.naming(engine.nameAsks.last!).contains("Searched for: \(shotQuery)"))
    }

    @Test func twoBadNamesGiveTheCleanedFallback() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights")])
        let (search, result) = shotPair()
        let engine = ScriptedGroupEngine(picking: { _ in [:] }, naming: { _ in
            AIGroupName(name: "Runner смотреть онлайн на…", emoji: "🎬")
        })
        let grouper = AIGroups.shared.grouper(for: browser)

        let fresh = await grouper.resolve(engine, AIGroupNameAsk(tabs: [search, result], current: nil, currentEmoji: nil, emoji: true, query: shotQuery))
        let kept = await grouper.resolve(engine, AIGroupNameAsk(tabs: [search, result], current: "Maze Runner", currentEmoji: nil, emoji: true, query: shotQuery))
        let broken = await grouper.resolve(engine, AIGroupNameAsk(tabs: [search, result], current: shotQuery, currentEmoji: nil, emoji: true, query: shotQuery))

        #expect(fresh.name == AIGroupName(name: "Runner", emoji: "🎬"))
        #expect(fresh.how.hasPrefix("fallback: rejected twice"), "\(fresh.how)")
        #expect(kept.name == nil)
        #expect(broken.name == AIGroupName(name: "Runner", emoji: "🎬"))
        #expect(engine.nameAsks.count == 6)
    }

    @Test func aKeptNameThatBreaksTheRulesIsNotKept() async {
        let browser = browser([("Lisbon flights", "https://booking.com/flights")])
        let (search, result) = shotPair()
        let engine = ScriptedGroupEngine(picking: { _ in [:] }, naming: { ask in
            ask.rejected.isEmpty ? AIGroupName(name: "", emoji: nil, keep: true) : AIGroupName(name: "Бегущий в лабиринте", emoji: "🎬")
        })
        let ask = AIGroupNameAsk(tabs: [search, result], current: shotQuery, currentEmoji: nil, emoji: true, query: shotQuery)

        let said = await AIGroups.shared.grouper(for: browser).resolve(engine, ask)

        #expect(said.name == AIGroupName(name: "Бегущий в лабиринте", emoji: "🎬"))
    }

    @Test func aSearchPageGoesWhereItsResultGoes() {
        let (search, result) = shotPair()
        let other = tab("Maze Runner (2014) - IMDb", "https://imdb.com/title/tt1790864")
        let group = AIGroupInfo(id: UUID(), name: "Maze Runner", members: [other])

        let formed = AIGroupRules.plan(AIGroupAsk(groups: [], loose: [search, other], fresh: [result]),
                                       picks: [result.id: .tab(other.id)], openers: [result.id: search.id])
        let joined = AIGroupRules.plan(AIGroupAsk(groups: [group], loose: [search], fresh: [result]),
                                       picks: [result.id: .group(group.id)], openers: [result.id: search.id])
        let loose = AIGroupRules.plan(AIGroupAsk(groups: [], loose: [search], fresh: [result]),
                                      picks: [result.id: AIGroupPick.none], openers: [result.id: search.id])
        let refused = AIGroupRules.plan(AIGroupAsk(groups: [AIGroupInfo(id: group.id, name: "Maze Runner", members: [other], refused: [search.key])],
                                                   loose: [search], fresh: [result]),
                                        picks: [result.id: .group(group.id)], openers: [result.id: search.id])

        #expect(formed.formed.map(Set.init) == [Set([result.id, other.id, search.id])])
        #expect(joined.joins == [result.id: group.id, search.id: group.id])
        #expect(loose.isEmpty)
        #expect(refused.joins == [result.id: group.id])
    }

    @Test func aSearchPageThatChoseItsOwnPlaceKeepsIt() {
        let (search, result) = shotPair()
        let other = tab("Maze Runner (2014) - IMDb", "https://imdb.com/title/tt1790864")
        let group = AIGroupInfo(id: UUID(), name: "Films", members: [other])

        let plan = AIGroupRules.plan(AIGroupAsk(groups: [group], loose: [], fresh: [search, result]),
                                     picks: [search.id: .group(group.id), result.id: AIGroupPick.none], openers: [result.id: search.id])

        #expect(plan.joins == [search.id: group.id])
    }

    @Test func theSearchTabJoinsTheGroupItsResultFormed() async throws {
        let browser = browser([("Runner смотреть онлайн на английском - Поиск в Google", "https://www.google.com/search?q=Runner+смотреть+онлайн+на+английском"),
                               ("Maze Runner (2014) - IMDb", "https://imdb.com/title/tt1790864")])
        let search = titled(browser, "Runner смотреть онлайн на английском - Поиск в Google")
        let result = browser.open(URL(string: "https://kinogo.example/1234-begushchij-v-labirinte.html")!, foreground: false,
                                  from: search, mayWait: true, link: true)
        result.restore(url: URL(string: "https://kinogo.example/1234-begushchij-v-labirinte.html")!,
                       title: "Бегущий в лабиринте (2014) бесплатно смотреть онлайн")
        result.cameBack = false
        let engine = ScriptedGroupEngine(picking: { ask in
            var out: [UUID: AIGroupPick] = [:]
            for tab in ask.fresh where tab.title.hasPrefix("Бегущий") {
                if let imdb = (ask.loose + ask.fresh).first(where: { $0.title.hasPrefix("Maze") }) { out[tab.id] = .tab(imdb.id) }
            }
            return out
        }, naming: { ask in
            AIGroupName(name: ask.query == nil ? "Unknown" : "Maze Runner", emoji: "🎬")
        })
        AIGroups.shared.standIn = engine

        let outcome = await AIGroups.shared.grouper(for: browser).regroup()

        #expect(outcome.formed == 1)
        let group = try #require(browser.tabGroups.first { $0.ai })
        #expect(Set(browser.tabs(in: group.id).map { $0.id }) == Set([search.id, result.id, titled(browser, "Maze Runner (2014) - IMDb").id]))
        #expect(group.name == "Maze Runner")
        #expect(engine.nameAsks.first?.query == shotQuery)
    }

    @Test func aCommandClickedResultAndItsSearchShareAnAINamedFolder() async throws {
        let browser = browser([("Runner смотреть онлайн на английском - Поиск в Google", "https://www.google.com/search?q=Runner+смотреть+онлайн+на+английском")])
        let search = try #require(browser.tabs.first)
        let engine = ScriptedGroupEngine(picking: { _ in [:] }, naming: { ask in
            ask.tabs.count > 1 ? AIGroupName(name: "Maze Runner", emoji: "🎬") : AIGroupName(name: "Runner", emoji: "🏃")
        })
        AIGroups.shared.standIn = engine

        let result = browser.open(URL(string: "https://kinogo.example/1234-begushchij-v-labirinte.html")!, foreground: false,
                                  from: search, mayWait: true, link: true)
        browser.fileSearchResult(result, from: search)
        let made = try #require(browser.tabGroups.first)
        result.restore(url: URL(string: "https://kinogo.example/1234-begushchij-v-labirinte.html")!,
                       title: "Бегущий в лабиринте (2014) бесплатно смотреть онлайн")
        AIGroups.shared.grouper(for: browser).landed(result)
        await settle()

        #expect(made.name == "Runner")
        #expect(made.query == shotQuery)
        #expect(made.ai)
        #expect(search.groupID == made.id)
        #expect(result.groupID == made.id)
        let now = try #require(browser.tabGroups.first { $0.id == made.id })
        #expect(now.name == "Maze Runner")
        #expect(now.icon?.emoji == "🎬")
        #expect(engine.nameAsks.last?.query == shotQuery)
    }

    @Test func aFolderNamedFromTheQueryIsNamedAfreshByTheModel() async throws {
        let browser = browser([("Runner смотреть онлайн на английском - Поиск в Google", "https://www.google.com/search?q=Runner+смотреть+онлайн+на+английском")])
        let search = try #require(browser.tabs.first)
        let engine = ScriptedGroupEngine(picking: { _ in [:] }, naming: { ask in
            ask.current == nil ? AIGroupName(name: "Бегущий в лабиринте", emoji: "🎬") : AIGroupName(name: "", emoji: nil, keep: true)
        })
        AIGroups.shared.standIn = engine

        let result = browser.open(URL(string: "https://kinogo.example/1234-begushchij-v-labirinte.html")!, foreground: false,
                                  from: search, mayWait: true, link: true)
        browser.fileSearchResult(result, from: search)
        await settle()

        #expect(browser.tabGroups.first?.name == "Бегущий в лабиринте")
        #expect(engine.nameAsks.first?.current == nil)
        #expect(!AIGroups.shared.grouper(for: browser).provisional.contains(try #require(browser.tabGroups.first?.id)))
    }

    private func lisbonGroup() async throws -> (Browser, ScriptedGroupEngine, TabGroup) {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon"),
                               ("Sintra palace tickets", "https://parquesdesintra.pt/pena"),
                               ("Porto wine cellars", "https://taylor.pt/cellars")])
        let engine = ScriptedGroupEngine(picking: { ask in
            var out: [UUID: AIGroupPick] = [:]
            if let flights = ask.fresh.first(where: { $0.title == "Lisbon flights" }),
               let hotels = ask.fresh.first(where: { $0.title == "Lisbon hotels" }) { out[hotels.id] = .tab(flights.id) }
            return out
        }, naming: { ask in
            ask.tabs.allSatisfy { $0.title.hasPrefix("Lisbon") } ? AIGroupName(name: "Lisbon", emoji: "✈️") : AIGroupName(name: "Portugal trip", emoji: "🧳")
        })
        AIGroups.shared.standIn = engine
        await AIGroups.shared.grouper(for: browser).regroup()
        return (browser, engine, try #require(browser.tabGroups.first { $0.ai }))
    }

    @Test func aTabDraggedInGetsTheNameRechecked() async throws {
        let (browser, engine, group) = try await lisbonGroup()
        let asked = engine.nameAsks.count

        browser.move(titled(browser, "Sintra palace tickets"), toGroup: group.id)
        await settle()

        #expect(browser.tabGroups.first { $0.id == group.id }?.name == "Portugal Trip")
        #expect(browser.tabGroups.first { $0.id == group.id }?.icon?.emoji == "🧳")
        #expect(engine.nameAsks.count == (asked + 1))
        #expect(engine.nameAsks.last?.current == "Lisbon")
    }

    @Test func aBurstOfChangesAsksOnce() async throws {
        let (browser, engine, group) = try await lisbonGroup()
        let asked = engine.nameAsks.count

        browser.move(titled(browser, "Sintra palace tickets"), toGroup: group.id)
        browser.move(titled(browser, "Porto wine cellars"), toGroup: group.id)
        await settle()

        #expect(engine.nameAsks.count == (asked + 1))
        #expect(engine.nameAsks.last?.tabs.count == 4)
        #expect(browser.tabGroups.first { $0.id == group.id }?.name == "Portugal Trip")
    }

    @Test func closingATabGetsTheNameRechecked() async throws {
        let (browser, engine, group) = try await lisbonGroup()
        browser.move(titled(browser, "Sintra palace tickets"), toGroup: group.id)
        await settle()
        let asked = engine.nameAsks.count

        browser.close(titled(browser, "Sintra palace tickets"))
        await settle()

        #expect(browser.tabGroups.first { $0.id == group.id }?.name == "Lisbon")
        #expect(engine.nameAsks.count == (asked + 1))
    }

    @Test func aNameThatStillFitsIsKeptWithoutAsking() async throws {
        let (browser, engine, group) = try await lisbonGroup()
        browser.newTab()
        let food = try #require(browser.tabs.last)
        food.restore(url: URL(string: "https://timeout.com/lisbon/food")!, title: "Lisbon food guide")
        browser.move(food, toGroup: group.id)
        await settle()
        let asked = engine.nameAsks.count

        browser.move(titled(browser, "Lisbon hotels"), toGroup: nil)
        await settle()

        #expect(engine.nameAsks.count == asked)
        #expect(browser.tabGroups.first { $0.id == group.id }?.name == "Lisbon")
    }

    @Test func aUserNamedGroupIsNeverRecheckedOnChange() async throws {
        let (browser, engine, group) = try await lisbonGroup()
        browser.renameTabGroup(group.id, to: "December")
        let asked = engine.nameAsks.count

        browser.move(titled(browser, "Sintra palace tickets"), toGroup: group.id)
        await settle()

        #expect(engine.nameAsks.count == asked)
        #expect(browser.tabGroups.first { $0.id == group.id }?.name == "December")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_REAL_MODEL"] == "1", "Set SEARCH_REAL_MODEL=1 to ask This Mac's model"))
    func thisMacNamesSampleGroups() async throws {
        let browser = browser([("Lisbon flights", "https://booking.com/flights")])
        let grouper = AIGroups.shared.grouper(for: browser)
        AIGroups.shared.timeout = 60
        let (search, result) = shotPair()
        let samples: [(String, [AIGroupTab], String?)] = [
            ("the shot's pair", [search, result], shotQuery),
            ("the shot's result alone", [result], shotQuery),
            ("Lisbon trip", [tab("Flights from Berlin to Lisbon", "https://booking.com/flights"),
                             tab("Hotels in Lisbon, Alfama district", "https://airbnb.com/s/lisbon"),
                             tab("Lisbon food: where to eat pastéis de nata", "https://timeout.com/lisbon/food")], nil),
            ("Swift docs", [tab("NavigationSplitView | Apple Developer Documentation", "https://developer.apple.com/documentation/swiftui/navigationsplitview"),
                            tab("ModelContainer | SwiftData | Apple Developer Documentation", "https://developer.apple.com/documentation/swiftdata/modelcontainer")], nil),
            ("a Russian recipe", [tab("Борщ классический — пошаговый рецепт с фото", "https://eda.ru/recepty/supy/borsch"),
                                  tab("Как сварить борщ: 5 ошибок", "https://dzen.ru/a/borsch")], nil),
            ("a laptop purchase", [tab("MacBook Air 13 M4 - Apple", "https://apple.com/macbook-air"),
                                   tab("MacBook Air M4 review: the best laptop - The Verge", "https://theverge.com/macbook-air-m4-review"),
                                   tab("Apple MacBook Air 13 M4 16GB price - Amazon.de", "https://amazon.de/dp/B0DZ")], nil),
        ]

        var lines: [String] = []
        for (label, tabs, query) in samples {
            let said = await grouper.resolve(MacGroupEngine(), AIGroupNameAsk(tabs: tabs, current: nil, currentEmoji: nil, emoji: true, query: query))
            lines.append("\(label): \(said.name?.emoji ?? "") \(said.name?.name ?? "kept") (\(said.how))")
        }

        print("THIS MAC NAMES\n" + lines.joined(separator: "\n"))
        #expect(lines.count == samples.count)
    }

    @Test func aNewGroupStandsVeiledUntilItsNameArrives() async throws {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        let namer = HeldNamer()
        AIGroups.shared.standIn = namer
        let grouper = AIGroups.shared.grouper(for: browser)

        let running = Task { await grouper.regroup() }
        for _ in 0..<100 where namer.nameAsks == 0 { await settle(0.02) }
        let formed = try #require(browser.tabGroups.first { $0.ai })

        #expect(AIGroups.shared.veils(formed, in: browser))
        #expect(formed.icon == nil)
        #expect(browser.tabs(in: formed.id).count == 2)

        namer.give(AIGroupName(name: "Lisbon trip", emoji: "🧳"))
        _ = await running.value

        let named = try #require(browser.tabGroups.first { $0.id == formed.id })
        #expect(named.name == "Lisbon Trip")
        #expect(named.icon?.emoji == "🧳")
        #expect(!AIGroups.shared.veils(named, in: browser))
        #expect(!grouper.provisional.contains(formed.id))
    }

    @Test func theVeilLiftsByItselfAfterTheStopUnlessHeld() async throws {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        AIGroups.shared.stop = 0.1
        let free = browser.addTabGroup(containing: titled(browser, "Lisbon flights"))
        let held = browser.addTabGroup(containing: titled(browser, "Lisbon hotels"))

        AIGroups.shared.veil(free)
        AIGroups.shared.veil(held, held: true)
        await settle(0.3)

        #expect(!AIGroups.shared.veiled.contains(free))
        #expect(AIGroups.shared.veiled.contains(held))
        AIGroups.shared.unveil(held)
        #expect(!AIGroups.shared.veiled.contains(held))
    }

    @Test func renamingByHandLiftsTheVeil() {
        let browser = browser([("Lisbon flights", "https://booking.com/flights")])
        let id = browser.addTabGroup(containing: titled(browser, "Lisbon flights"))
        browser.editingGroupID = nil
        AIGroups.shared.veil(id, held: true)
        defer { AIGroups.shared.unveil(id) }

        browser.editingGroupID = id

        #expect(!AIGroups.shared.veiled.contains(id))
        browser.editingGroupID = nil
    }

    @Test func onlyAIGroupsAndUnnamedHandMadeFoldersAreVeiled() {
        var ai = TabGroup(id: UUID(), name: "Lisbon", collapsed: false)
        ai.ai = true
        var live = ai
        live.live = true
        var userNamed = ai
        userNamed.userNamed = true
        var search = ai
        search.query = "lisbon hotels"
        var handMade = TabGroup(id: UUID(), name: "Folder 2", collapsed: false)
        handMade.madeName = "Folder 2"
        var renamed = handMade
        renamed.name = "Trip"
        let plain = TabGroup(id: UUID(), name: "Work", collapsed: false)
        let veiled: Set<UUID> = [ai.id, handMade.id, plain.id]

        #expect(AIGroups.veils(ai, veiled: veiled, editing: nil))
        #expect(!AIGroups.veils(ai, veiled: [], editing: nil))
        #expect(!AIGroups.veils(ai, veiled: veiled, editing: ai.id))
        #expect(!AIGroups.veils(live, veiled: veiled, editing: nil))
        #expect(!AIGroups.veils(userNamed, veiled: veiled, editing: nil))
        #expect(!AIGroups.veils(search, veiled: veiled, editing: nil))
        #expect(AIGroups.veils(handMade, veiled: veiled, editing: nil))
        #expect(!AIGroups.veils(renamed, veiled: veiled, editing: nil))
        #expect(!AIGroups.veils(plain, veiled: veiled, editing: nil))
    }

    @Test func theBarIsAsWideAsANameAndFitsTheRoom() {
        let ids = (0..<200).map { _ in UUID() }

        let widths = ids.map { GroupNameReveal.width(for: $0, room: 500) }

        #expect(widths.allSatisfy { $0 >= 64 && $0 <= 104 })
        #expect(Set(widths).count > 10)
        #expect(ids.allSatisfy { GroupNameReveal.width(for: $0, room: 500) == GroupNameReveal.width(for: $0, room: 500) })
        #expect(ids.allSatisfy { GroupNameReveal.width(for: $0, room: 40) == 40 })
        #expect(abs(0.14 + GroupNameReveal.shineOverlay() * 0.86 - 0.26) < 0.0001)
    }

    @Test func aVeiledHeadingSaysItIsNamingAndShowsTheNameAfter() {
        let browser = browser([("Lisbon flights", "https://booking.com/flights")])
        let id = browser.addTabGroup(containing: titled(browser, "Lisbon flights"))
        if let index = browser.tabGroups.firstIndex(where: { $0.id == id }) {
            browser.tabGroups[index].ai = true
            browser.tabGroups[index].madeName = nil
            browser.tabGroups[index].name = "Lisbon"
        }
        browser.editingGroupID = nil
        let heading = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 240, height: GroupHeadingView.height))
        AIGroups.shared.veil(id, held: true)
        defer { AIGroups.shared.unveil(id) }

        heading.show(browser.tabGroups.first { $0.id == id }!, in: browser)

        #expect(heading.veiled)
        #expect(heading.accessibilityLabel() == "Naming group…")

        AIGroups.shared.unveil(id)
        heading.show(browser.tabGroups.first { $0.id == id }!, in: browser)

        #expect(!heading.veiled)
        #expect(heading.accessibilityLabel() == "Lisbon")
    }

    @Test func aFirstNameThatArrivesWhileTheRenameFieldIsOpenIsAskedForAgainWhenItCloses() async throws {
        let browser = browser([("Lisbon flights", "https://booking.com/flights"),
                               ("Lisbon hotels", "https://airbnb.com/s/lisbon")])
        let namer = HeldNamer()
        AIGroups.shared.standIn = namer
        let grouper = AIGroups.shared.grouper(for: browser)
        let running = Task { await grouper.regroup() }
        for _ in 0..<100 where namer.nameAsks == 0 { await settle(0.02) }
        let formed = try #require(browser.tabGroups.first { $0.ai })
        browser.editingGroupID = formed.id
        namer.give(AIGroupName(name: "Lisbon trip", emoji: "🧳"))
        _ = await running.value
        let whileOpen = browser.tabGroups.first { $0.id == formed.id }?.name

        browser.editingGroupID = nil
        await settle(0.6)

        #expect(whileOpen == formed.name)
        #expect(browser.tabGroups.first { $0.id == formed.id }?.name == "Lisbon Trip")
        #expect(!AIGroups.shared.veiled.contains(formed.id))
    }
}

import AppKit
import Testing
import WebKit
@testable import Search

final class JudgeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var asked: [String] { lock.withLock { seen } }

    func note(_ one: AIGroupTab, _ two: AIGroupTab) {
        lock.withLock { seen.append("\(one.title) | \(two.title)") }
    }
}

final class SortingEngine: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    private let lock = NSLock()
    private var decided: [AIGroupAsk] = []
    private var named: [AIGroupNameAsk] = []
    let local: Bool
    let batch: Int
    let failing: Int
    let picking: @Sendable (AIGroupAsk) -> [UUID: AIGroupPick]
    let naming: @Sendable (AIGroupNameAsk) -> AIGroupName

    init(local: Bool, batch: Int = 8, failing: Int = 0, picking: @escaping @Sendable (AIGroupAsk) -> [UUID: AIGroupPick],
         naming: @escaping @Sendable (AIGroupNameAsk) -> AIGroupName = { _ in AIGroupName(name: "Heat Pump", emoji: nil) }) {
        self.local = local
        self.batch = batch
        self.failing = failing
        self.picking = picking
        self.naming = naming
    }

    var asks: [AIGroupAsk] { lock.withLock { decided } }
    var nameAsks: [AIGroupNameAsk] { lock.withLock { named } }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        let turn = lock.withLock {
            decided.append(ask)
            return decided.count
        }
        if turn <= failing { throw ProviderError.failed("It took too long") }
        return picking(ask)
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        lock.withLock { named.append(ask) }
        return naming(ask)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AIGroupEvidenceTests {
    private func tab(_ title: String, _ address: String, by: String = "") -> AIGroupTab {
        AIGroupTab(id: UUID(), title: title, url: URL(string: address), by: by)!
    }

    private func browser(_ pages: [(String, String)]) -> Browser {
        keepSetting(AIGroups.shared, \.on, AIGroups.onKey)
        keepSetting(AIGroups.shared, \.emoji, AIGroups.emojiKey)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        for (index, page) in pages.enumerated() {
            if index > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: page.1)!, title: page.0)
            browser.tabs.last?.cameBack = false
        }
        let groups = AIGroups.shared
        groups.on = true
        groups.emoji = false
        groups.quiet = 0.05
        groups.gap = 0
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

    private func pairing(_ words: String) -> @Sendable (AIGroupAsk) -> [UUID: AIGroupPick] {
        { ask in
            var out: [UUID: AIGroupPick] = [:]
            let mine = ask.fresh.filter { $0.title.contains(words) }
            if let group = ask.groups.first {
                for tab in mine { out[tab.id] = .group(group.id) }
            } else if let first = mine.first {
                for tab in mine.dropFirst() { out[tab.id] = .tab(first.id) }
            }
            return out
        }
    }

    @Test func tabsOnDifferentSitesShareTheirDistinctiveWords() {
        let review = tab("Mitsubishi heat pump review 2025", "https://hvac.example/reviews/mitsubishi")
        let sizing = tab("Heat pumps: how to size one for your home", "https://energy.example/guides/sizing")
        let bread = tab("Sourdough starter in seven days", "https://bread.example/starter")

        let related = AIGroupEvidence.shared(review, sizing)
        let unrelated = AIGroupEvidence.shared(review, bread)

        #expect(related == ["heat", "pump"])
        #expect(unrelated.isEmpty)
    }

    @Test func aSiteAndItsTitleSuffixAreNotEvidence() {
        let rust = tab("Rust lifetimes explained - YouTube", "https://www.youtube.com/watch?v=aaa")
        let bread = tab("Sourdough for beginners - YouTube", "https://www.youtube.com/watch?v=bbb")
        let parser = tab("Fix the parser crash · Issue #12 · octo/parser · GitHub", "https://github.com/octo/parser/issues/12")
        let fonts = tab("Add variable fonts · Issue #40 · acme/fonts · GitHub", "https://github.com/acme/fonts/issues/40")

        let plan = tab("Helios – Q1 roadmap", "https://www.notion.so/acme/Helios-Q1-roadmap-1a2b3c4d5e6f")
        let retro = tab("Helios – launch retro", "https://www.notion.so/acme/Helios-launch-retro-0a9b8c7d6e5f")

        let videos = AIGroupEvidence.shared(rust, bread)
        let issues = AIGroupEvidence.shared(parser, fonts)
        let project = AIGroupEvidence.shared(plan, retro)

        #expect(videos.isEmpty)
        #expect(issues.isEmpty)
        #expect(project == ["helios"])
        #expect(AIGroupEvidence.common([plan, retro]) == ["helios"])
    }

    @Test func wordsMatchAcrossEndingsButNumbersMustBeEqual() {
        #expect(AIGroupEvidence.same("pump", "pumps"))
        #expect(AIGroupEvidence.same("дюна", "дюны"))
        #expect(AIGroupEvidence.same("kubernetes", "kubernete"))
        #expect(!AIGroupEvidence.same("kyoto", "kyiv"))
        #expect(!AIGroupEvidence.same("rav4", "rav5"))
        #expect(!AIGroupEvidence.same("1234", "1235"))
        #expect(AIGroupEvidence.tokens("The 2024 review of PROJ-1234 and RAV4") == ["proj", "1234", "rav4"])
    }

    @Test func twoVideosOnOneSiteAreTwoAddresses() {
        let one = tab("Rust lifetimes explained - YouTube", "https://www.youtube.com/watch?v=aaa")
        let two = tab("Sourdough for beginners - YouTube", "https://www.youtube.com/watch?v=bbb")

        let keys = [one.key, two.key]

        #expect(keys == ["youtube.com/watch?v=aaa", "youtube.com/watch?v=bbb"])
        #expect(one.sent.key == "youtube.com/watch")
    }

    @Test func aChannelIsWhoMadeThePageUnlessItIsTheSiteItself() {
        let light = tab("Why light slows down - YouTube", "https://www.youtube.com/watch?v=aaa", by: "Veritasium")
        let dice = tab("The trouble with dice - YouTube", "https://www.youtube.com/watch?v=bbb", by: "Veritasium")
        let other = tab("Dice towers compared - YouTube", "https://www.youtube.com/watch?v=ccc", by: "Shut Up & Sit Down")
        let elsewhere = tab("Veritasium on light", "https://vimeo.com/123456", by: "Veritasium")
        let phones = tab("The best phones this year", "https://www.theverge.com/phones", by: "The Verge")
        let laptops = tab("Laptops worth buying", "https://www.theverge.com/laptops", by: "The Verge")

        #expect(AIGroupEvidence.channel(light, dice))
        #expect(!AIGroupEvidence.channel(dice, other))
        #expect(!AIGroupEvidence.channel(light, elsewhere))
        #expect(!AIGroupEvidence.channel(phones, laptops))
        #expect(AIGroupEvidence.by(phones).isEmpty)
    }

    @Test func whatEveryTabHoldsIsFoundInItsOwnSpelling() {
        let book = tab("Dune by Frank Herbert", "https://books.example/dune")
        let film = tab("Dune: Part Two showtimes", "https://cinema.example/dune-part-two")
        let wiki = tab("Dune (franchise) - Wikipedia", "https://en.wikipedia.org/wiki/Dune_(franchise)")
        let docs = tab("Accept a payment | Stripe Documentation", "https://docs.stripe.com/payments/accept-a-payment")
        let answer = tab("Stripe webhook signature fails", "https://stackoverflow.com/questions/1/stripe-webhook")
        let panel = tab("Webhooks – Stripe Dashboard", "https://dashboard.stripe.com/webhooks")

        let dune = AIGroupEvidence.common([book, film, wiki])
        let stripe = AIGroupEvidence.common([docs, answer])
        let oneSite = AIGroupEvidence.common([docs, panel])

        #expect(dune == ["dune"])
        #expect(AIGroupEvidence.written("dune", in: [book, film, wiki]) == "Dune")
        #expect(stripe == ["stripe"])
        #expect(oneSite.isEmpty)
    }

    @Test func theModelMustAgreeInBothOrders() async throws {
        let sizing = tab("Heat pump sizing guide", "https://energy.example/sizing")
        let installers = tab("Heat pump installers near Boston", "https://local.example/boston")
        let ask = AIGroupAsk(groups: [], loose: [], fresh: [sizing, installers])
        let log = JudgeLog()
        let oneWay = AIGroupSorter { one, two in
            log.note(one, two)
            return one.id == sizing.id
        }
        let bothWays = AIGroupSorter { _, _ in true }

        let refused = try await oneWay.decide(ask)
        let agreed = try await bothWays.decide(ask)

        #expect(refused == [sizing.id: .none, installers.id: .none])
        #expect(log.asked.contains("Heat pump sizing guide | Heat pump installers near Boston"))
        #expect(log.asked.contains("Heat pump installers near Boston | Heat pump sizing guide"))
        #expect(agreed[sizing.id] == .tab(installers.id))
    }

    @Test func tabsThatShareNoWordAreNeverPutToTheModel() async throws {
        let pump = tab("Heat pump sizing guide", "https://energy.example/sizing")
        let bread = tab("Sourdough starter in seven days", "https://bread.example/starter")
        let rust = tab("Rust lifetimes explained - YouTube", "https://www.youtube.com/watch?v=aaa")
        let knots = tab("Eight knots worth knowing - YouTube", "https://www.youtube.com/watch?v=bbb")
        let log = JudgeLog()
        let sorter = AIGroupSorter { one, two in
            log.note(one, two)
            return true
        }

        let picks = try await sorter.decide(AIGroupAsk(groups: [], loose: [pump], fresh: [bread, rust, knots]))

        #expect(picks == [bread.id: .none, rust.id: .none, knots.id: .none])
        #expect(log.asked.isEmpty)
    }

    @Test func oneChannelGroupsWithoutTheModel() async throws {
        let light = tab("Why light slows down - YouTube", "https://www.youtube.com/watch?v=aaa", by: "Veritasium")
        let dice = tab("The trouble with dice - YouTube", "https://www.youtube.com/watch?v=bbb", by: "Veritasium")
        let log = JudgeLog()
        let sorter = AIGroupSorter { one, two in
            log.note(one, two)
            return false
        }

        let picks = try await sorter.decide(AIGroupAsk(groups: [], loose: [light], fresh: [dice]))

        #expect(picks == [dice.id: .tab(light.id)])
        #expect(log.asked.isEmpty)
    }

    @Test func aTabJoinsAFolderOnlyWhenEnoughOfItAgrees() async throws {
        let flights = tab("Kyoto flights in April", "https://air.example/kyoto")
        let hotels = tab("Kyoto hotels near Gion", "https://stay.example/kyoto")
        let temples = tab("Kyoto temples to see", "https://guide.example/kyoto")
        let fresh = tab("Kyoto protocol explained", "https://climate.example/kyoto-protocol")
        let folder = AIGroupInfo(id: UUID(), name: "Kyoto Trip", members: [flights, hotels, temples])
        let pair = AIGroupInfo(id: UUID(), name: "Kyoto Trip", members: [flights, hotels])
        let onlyFlights = AIGroupSorter { one, two in [one.id, two.id].contains(flights.id) }
        let twoOfThree = AIGroupSorter { one, two in ![one.id, two.id].contains(temples.id) }

        let one = try await onlyFlights.decide(AIGroupAsk(groups: [folder], loose: [], fresh: [fresh]))
        let two = try await twoOfThree.decide(AIGroupAsk(groups: [folder], loose: [], fresh: [fresh]))
        let small = try await onlyFlights.decide(AIGroupAsk(groups: [pair], loose: [], fresh: [fresh]))

        #expect(one == [fresh.id: .none])
        #expect(two == [fresh.id: .group(folder.id)])
        #expect(small == [fresh.id: .group(pair.id)])
    }

    @Test func aTabOneMemberLeansToIsPutToTheWholeFolder() async throws {
        let flights = tab("Berlin to Porto flights", "https://air.example/berlin-porto")
        let hotels = tab("The 10 best hotels in Porto", "https://stay.example/porto")
        let metro = tab("Porto airport to the centre by metro", "https://metro.example/porto")
        let cellars = tab("Port wine cellars worth a tour", "https://guide.example/port-wine")
        let folder = AIGroupInfo(id: UUID(), name: "Porto Trip", members: [flights, hotels])
        let fresh = AIGroupInfo(id: UUID(), name: "Porto", members: [flights, hotels], settled: false)
        let log = JudgeLog()
        let oneWay: @Sendable (AIGroupTab, AIGroupTab) async throws -> Bool = { one, two in one.id == metro.id && two.id == hotels.id }
        let whole: @Sendable (AIGroupInfo, AIGroupTab) async throws -> Bool = { group, tab in
            log.note(group.members[0], tab)
            return true
        }

        let joined = try await AIGroupSorter(judge: oneWay, belongs: whole).decide(AIGroupAsk(groups: [folder], loose: [], fresh: [metro]))
        let noLean = try await AIGroupSorter(judge: oneWay, belongs: whole).decide(AIGroupAsk(groups: [folder], loose: [], fresh: [cellars]))
        let unnamed = try await AIGroupSorter(judge: oneWay, belongs: whole).decide(AIGroupAsk(groups: [fresh], loose: [], fresh: [metro]))
        let refused = try await AIGroupSorter(judge: oneWay, belongs: { _, _ in false })
            .decide(AIGroupAsk(groups: [folder], loose: [], fresh: [metro]))
        let oneOrder = try await AIGroupSorter(judge: oneWay, belongs: { group, _ in group.members.first?.id == flights.id })
            .decide(AIGroupAsk(groups: [folder], loose: [], fresh: [metro]))
        let pairsOnly = try await AIGroupSorter(judge: oneWay).decide(AIGroupAsk(groups: [folder], loose: [], fresh: [metro]))

        #expect(joined == [metro.id: .group(folder.id)])
        #expect(noLean == [cellars.id: .none])
        #expect(unnamed == [metro.id: .none])
        #expect(refused == [metro.id: .none])
        #expect(oneOrder == [metro.id: .none])
        #expect(pairsOnly == [metro.id: .none])
        #expect(log.asked == ["Berlin to Porto flights | Porto airport to the centre by metro",
                              "The 10 best hotels in Porto | Porto airport to the centre by metro"])
    }

    @Test func aFolderTheTabWasTakenOutOfIsNotOffered() async throws {
        let flights = tab("Kyoto flights in April", "https://air.example/kyoto")
        let hotels = tab("Kyoto hotels near Gion", "https://stay.example/kyoto")
        let fresh = tab("Kyoto temples to see", "https://guide.example/kyoto")
        let folder = AIGroupInfo(id: UUID(), name: "Kyoto Trip", members: [flights, hotels], refused: [fresh.key])
        let log = JudgeLog()
        let sorter = AIGroupSorter { one, two in
            log.note(one, two)
            return true
        }

        let picks = try await sorter.decide(AIGroupAsk(groups: [folder], loose: [], fresh: [fresh]))

        #expect(picks == [fresh.id: .none])
        #expect(log.asked.isEmpty)
    }

    @Test func aTabGoesToTheFolderBeforeALooseTabWithTheSameWords() async throws {
        let flights = tab("Kyoto flights in April", "https://air.example/kyoto")
        let hotels = tab("Kyoto hotels near Gion", "https://stay.example/kyoto")
        let stray = tab("Kyoto temples and Kyoto gardens to see", "https://guide.example/kyoto")
        let fresh = tab("Kyoto temples opening hours", "https://hours.example/kyoto")
        let folder = AIGroupInfo(id: UUID(), name: "Kyoto Trip", members: [flights, hotels])
        let sorter = AIGroupSorter { _, _ in true }

        let picks = try await sorter.decide(AIGroupAsk(groups: [folder], loose: [stray], fresh: [fresh]))

        #expect(picks == [fresh.id: .group(folder.id)])
    }

    @Test func aNameNeedNotRepeatWhatEveryTabShares() {
        let flat = tab("Как я купил квартиру - YouTube", "https://www.youtube.com/watch?v=aaa", by: "Самоделкин")
        let car = tab("Пикап за копейки - YouTube", "https://www.youtube.com/watch?v=bbb", by: "Самоделкин")
        let book = tab("Dune by Frank Herbert", "https://books.example/dune")
        let film = tab("Dune: Part Two showtimes", "https://cinema.example/dune-part-two")
        let flights = tab("Lisbon flights", "https://booking.com/flights")
        let rail = tab("Porto trains", "https://cp.pt/porto")

        #expect(AIGroupNames.problem("Пикап", tabs: [flat, car]) == nil)
        #expect(AIGroupNames.problem("Самоделкин", tabs: [flat, car]) == nil)
        #expect(AIGroupNames.problem("Sci Fi Films", tabs: [book, film]) == nil)
        #expect(AIGroupNames.problem("Dune", tabs: [book, film]) == nil)
        #expect(AIGroupNames.problem("Portugal Trip", tabs: [flights, rail]) == nil)
        #expect(AIGroupNames.problem("Sci Fi Films", tabs: [book, film], query: "dune film") == nil)
    }

    @Test func aSharedNameThatIsAlsoASiteIsANameAcrossSites() {
        let docs = tab("Accept a payment | Stripe Documentation", "https://docs.stripe.com/payments/accept-a-payment")
        let answer = tab("Stripe webhook signature fails", "https://stackoverflow.com/questions/1/stripe-webhook")
        let panel = tab("Webhooks – Stripe Dashboard", "https://dashboard.stripe.com/webhooks")

        #expect(AIGroupNames.problem("Stripe", tabs: [docs, answer]) == nil)
        #expect(AIGroupNames.problem("Payment Intent", tabs: [docs, answer]) == nil)
        #expect(AIGroupNames.fallback([docs, answer]) == "Stripe")
        #expect(AIGroupNames.problem("Stripe", tabs: [docs, panel]) == "it is only a site's name")
    }

    @Test func aNameIsSpelledTheWayItsTabsSpellIt() {
        let car = tab("2026 Toyota RAV4 review: the hybrid to buy", "https://cars.example/rav4")
        let moon = tab("Artemis III: NASA names the landing crew", "https://space.example/artemis")
        let phone = tab("iPhone 17 review", "https://phones.example/iphone-17")
        let loud = tab("Меняю ПИКАП на ДОМ У МОРЯ - YouTube", "https://www.youtube.com/watch?v=bbb")

        #expect(AIGroupNames.spelled("Toyota Rav4", like: [car]) == "Toyota RAV4")
        #expect(AIGroupNames.spelled("Artemis Iii Moon", like: [moon]) == "Artemis III Moon")
        #expect(AIGroupNames.spelled("Iphone 17", like: [phone]) == "iPhone 17")
        #expect(AIGroupNames.spelled("Пикап", like: [loud]) == "Пикап")
        #expect(AIGroupNames.spelled("Nasa Crew", like: [moon]) == "Nasa Crew")
    }

    @Test func theFallbackIsTheChannelOrTheSharedWord() {
        let flat = tab("Как я купил квартиру - YouTube", "https://www.youtube.com/watch?v=aaa", by: "Самоделкин")
        let car = tab("Пикап за копейки - YouTube", "https://www.youtube.com/watch?v=bbb", by: "Самоделкин")
        let book = tab("Dune by Frank Herbert", "https://books.example/dune")
        let film = tab("Dune: Part Two showtimes", "https://cinema.example/dune-part-two")
        let rust = tab("Rust lifetimes explained - YouTube", "https://www.youtube.com/watch?v=ccc")
        let knots = tab("Eight knots worth knowing - YouTube", "https://www.youtube.com/watch?v=ddd")

        #expect(AIGroupNames.fallback([flat, car]) == "Самоделкин")
        #expect(AIGroupNames.fallback([book, film]) == "Dune")
        #expect(AIGroupNames.fallback([rust, knots]) == "Youtube")
    }

    @Test func theNamerIsToldWhatEveryTabHasAndWhoMadeIt() {
        let light = tab("Why light slows down - YouTube", "https://www.youtube.com/watch?v=aaa", by: "Veritasium")
        let dice = tab("The trouble with dice - YouTube", "https://www.youtube.com/watch?v=bbb", by: "Veritasium")
        let ask = AIGroupNameAsk(tabs: [light, dice], current: nil, currentEmoji: nil, emoji: false)

        let here = AIGroupPrompt.naming(ask)
        let away = AIGroupPrompt.naming(ask.sent)

        #expect(here.contains("— by Veritasium"))
        #expect(here.contains("Every tab has: Veritasium"))
        #expect(!away.contains("Veritasium"))
        #expect(!away.contains("v=aaa"))
    }

    @Test func whoMadeAPageAndItsQueryNeverLeaveThisMac() async {
        let browser = browser([("Why light slows down - YouTube", "https://www.youtube.com/watch?v=aaa"),
                               ("The trouble with dice - YouTube", "https://www.youtube.com/watch?v=bbb")])
        for tab in browser.tabs { tab.madeBy = (tab.pageAddress!, "Veritasium") }
        let away = SortingEngine(local: false, picking: pairing("YouTube"))
        AIGroups.shared.standIn = away

        await AIGroups.shared.grouper(for: browser).regroup()

        let sentTabs = away.asks.flatMap { $0.fresh + $0.loose + $0.groups.flatMap(\.members) } + away.nameAsks.flatMap(\.tabs)
        #expect(!sentTabs.isEmpty)
        #expect(sentTabs.allSatisfy { $0.by.isEmpty && $0.query.isEmpty })
        #expect(browser.tabGroups.filter(\.ai).count == 1)
    }

    @Test func anEngineOnThisMacIsToldWhoMadeAPage() async {
        let browser = browser([("Why light slows down - YouTube", "https://www.youtube.com/watch?v=aaa"),
                               ("The trouble with dice - YouTube", "https://www.youtube.com/watch?v=bbb")])
        for tab in browser.tabs { tab.madeBy = (tab.pageAddress!, "Veritasium") }
        let here = SortingEngine(local: true, picking: pairing("YouTube"), naming: { _ in AIGroupName(name: "Veritasium", emoji: nil) })
        AIGroups.shared.standIn = here

        await AIGroups.shared.grouper(for: browser).regroup()

        #expect(here.asks.first?.fresh.map(\.by) == ["Veritasium", "Veritasium"])
        #expect(here.asks.first?.fresh.map(\.query) == ["v=aaa", "v=bbb"])
        #expect(here.nameAsks.first?.tabs.map(\.by) == ["Veritasium", "Veritasium"])
        #expect(browser.tabGroups.first { $0.ai }?.name == "Veritasium")
    }

    @Test func whoMadeAPageIsForgottenWhenTheTabMovesOn() {
        let browser = browser([("Why light slows down - YouTube", "https://www.youtube.com/watch?v=aaa")])
        let tab = browser.tabs[0]
        tab.madeBy = (tab.pageAddress!, "Veritasium")
        #expect(tab.by == "Veritasium")

        tab.restore(url: URL(string: "https://www.youtube.com/watch?v=bbb")!, title: "The trouble with dice - YouTube")

        #expect(tab.by.isEmpty)
    }

    private func read(_ html: String, at address: String) async throws -> String {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.loadHTMLString(html, baseURL: URL(string: address))
        for _ in 0..<200 where view.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        return try await view.evaluateJavaScript(AIGroupReader.script, contentWorld: Web.world) as? String ?? ""
    }

    @Test func whoMadeAPageIsReadFromThePageItself() async throws {
        let video = """
        <div itemscope itemtype="http://schema.org/VideoObject"><meta itemprop="identifier" content="aaa">
        <span itemprop="author" itemscope itemtype="http://schema.org/Person"><link itemprop="url" href="http://www.youtube.com/@veritasium">
        <link itemprop="name" content="Veritasium"></span></div>
        """
        let article = """
        <script type="application/ld+json">{"@type": "NewsArticle", "headline": "Rates hold", "author": [{"@type": "Person", "name": "Ada  Example"}]}</script>
        <meta name="author" content="Someone Else">
        """
        let post = "<meta name=\"author\" content=\"Grace Example\"><p>Hello</p>"

        let channel = try await read(video, at: "https://www.youtube.com/watch?v=aaa")
        let moved = try await read(video, at: "https://www.youtube.com/watch?v=bbb")
        let writer = try await read(article, at: "https://news.example/rates-hold")
        let named = try await read(post, at: "https://blog.example/hello")
        let nobody = try await read("<p>Hello</p>", at: "https://blog.example/hello")

        #expect(channel == "Veritasium")
        #expect(moved.isEmpty)
        #expect(writer == "Ada Example")
        #expect(named == "Grace Example")
        #expect(nobody.isEmpty)
    }

    @Test func aLooseTabIsOfferedToAFolderThatJustFormed() async {
        let browser = browser([("Heat pump rebates by state", "https://energy.example/rebates"),
                               ("Sourdough starter in seven days", "https://bread.example/starter")])
        let engine = SortingEngine(local: false, picking: { ask in
            var out: [UUID: AIGroupPick] = [:]
            let pumps = ask.fresh.filter { $0.title.contains("Heat pump") }
            if let group = ask.groups.first {
                for tab in pumps { out[tab.id] = .group(group.id) }
            } else if pumps.count == 2 {
                out[pumps[0].id] = .tab(pumps[1].id)
            }
            return out
        })
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        #expect(browser.tabGroups.isEmpty)
        let alone = engine.asks.count

        for page in [("Heat pump sizing guide", "https://hvac.example/sizing"), ("Heat pump installers near Boston", "https://local.example/boston")] {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: page.1)!, title: page.0)
            browser.tabs.last?.cameBack = false
            grouper.landed(browser.tabs.last!)
        }
        await settle()

        let group = browser.tabGroups.first { $0.ai }
        #expect(browser.tabs(in: group?.id).map(\.title).sorted()
                == ["Heat pump installers near Boston", "Heat pump rebates by state", "Heat pump sizing guide"])
        #expect(titled(browser, "Sourdough starter in seven days").groupID == nil)
        #expect(engine.asks.count == alone + 2)
        #expect(engine.asks.last?.fresh.map(\.title) == ["Heat pump rebates by state"])
        #expect(engine.asks.last?.loose.isEmpty == true)
        #expect(engine.nameAsks.last?.tabs.count == 3)
    }

    @Test func aTabTakenOutOfAFolderIsNotGatheredBackIn() async throws {
        let browser = browser([("Heat pump sizing guide", "https://hvac.example/sizing"),
                               ("Heat pump installers near Boston", "https://local.example/boston"),
                               ("Heat pump rebates by state", "https://energy.example/rebates")])
        let engine = SortingEngine(local: false, picking: pairing("Heat pump"))
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)
        await grouper.regroup()
        let group = try #require(browser.tabGroups.first { $0.ai })
        #expect(browser.tabs(in: group.id).count == 3)
        let rebates = titled(browser, "Heat pump rebates by state")

        browser.move(rebates, toGroup: nil)
        browser.newTab()
        browser.tabs.last?.restore(url: URL(string: "https://maker.example/heat-pump-models")!, title: "Heat pump models compared")
        browser.tabs.last?.cameBack = false
        await grouper.regroup()

        #expect(titled(browser, "Heat pump models compared").groupID == group.id)
        #expect(rebates.groupID == nil)
        #expect(browser.tabGroups.first { $0.id == group.id }?.aiRefused == ["energy.example/rebates"])
    }

    @Test func anEngineOnThisMacThatFailsIsAskedOnceMore() async {
        let here = browser([("Heat pump sizing guide", "https://hvac.example/sizing"),
                            ("Heat pump installers near Boston", "https://local.example/boston")])
        let slow = SortingEngine(local: true, failing: 1, picking: pairing("Heat pump"))
        AIGroups.shared.standIn = slow
        let grouper = AIGroups.shared.grouper(for: here)

        for tab in here.tabs { grouper.landed(tab) }
        await settle()

        #expect(slow.asks.count == 2)
        #expect(here.tabGroups.filter(\.ai).count == 1)
    }

    @Test func anEngineOnThisMacThatKeepsFailingIsLeftAloneAfterTwoAsks() async {
        let here = browser([("Heat pump sizing guide", "https://hvac.example/sizing"),
                            ("Heat pump installers near Boston", "https://local.example/boston")])
        let broken = SortingEngine(local: true, failing: 9, picking: pairing("Heat pump"))
        AIGroups.shared.standIn = broken
        let grouper = AIGroups.shared.grouper(for: here)

        for tab in here.tabs { grouper.landed(tab) }
        await settle(1.0)

        #expect(broken.asks.count == 2)
        #expect(here.tabGroups.isEmpty)
        #expect((grouper.pending[here.spaceID] ?? [:]).isEmpty)
    }

    @Test func tabsThatLandTogetherAreAskedInTheColumnsOrder() async {
        let browser = browser([("Heat pump sizing guide", "https://hvac.example/sizing"),
                               ("Sourdough starter in seven days", "https://bread.example/starter"),
                               ("Kyoto temples to see", "https://guide.example/kyoto"),
                               ("Rust lifetimes explained", "https://rust.example/lifetimes")])
        let engine = SortingEngine(local: false, picking: { _ in [:] })
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)

        for tab in browser.tabs.reversed() { grouper.landed(tab) }
        await settle()

        #expect(engine.asks.count == 1)
        #expect(engine.asks.first?.fresh.map(\.title) == browser.tabs.map(\.title))
    }

    @Test func groupingNowAsksInBatchesUntilEveryTabWasAsked() async {
        let browser = browser([("Heat pump sizing guide", "https://hvac.example/sizing"),
                               ("Sourdough starter in seven days", "https://bread.example/starter"),
                               ("Kyoto temples to see", "https://guide.example/kyoto"),
                               ("Rust lifetimes explained", "https://rust.example/lifetimes"),
                               ("Heat pump installers near Boston", "https://local.example/boston")])
        let engine = SortingEngine(local: false, batch: 2, picking: { ask in
            var out: [UUID: AIGroupPick] = [:]
            for tab in ask.fresh where tab.title.contains("Heat pump") {
                if let other = (ask.loose + ask.fresh).first(where: { $0.id != tab.id && $0.title.contains("Heat pump") }) {
                    out[tab.id] = .tab(other.id)
                }
            }
            return out
        })
        AIGroups.shared.standIn = engine
        let grouper = AIGroups.shared.grouper(for: browser)

        let outcome = await grouper.regroup()

        #expect(engine.asks.allSatisfy { $0.fresh.count <= 2 })
        #expect(engine.asks.count >= 2)
        #expect(Set(engine.asks.flatMap(\.fresh).map(\.title)).isSuperset(of: browser.tabs(in: nil).map(\.title)))
        #expect((grouper.pending[browser.spaceID] ?? [:]).isEmpty)
        #expect(outcome.formed == 1)
        #expect(browser.tabs(in: browser.tabGroups.first { $0.ai }?.id).map(\.title).sorted()
                == ["Heat pump installers near Boston", "Heat pump sizing guide"])
    }

    @Test func aNameThatLeavesOutTheSharedWordIsTakenAndTheSharedWordIsAHint() async {
        let browser = browser([("Dune by Frank Herbert", "https://books.example/dune"),
                               ("Dune: Part Two showtimes", "https://cinema.example/dune-part-two")])
        let engine = SortingEngine(local: false, picking: pairing("Dune"), naming: { ask in
            AIGroupName(name: ask.rejected.isEmpty ? "Sci Fi Films" : "Dune", emoji: nil)
        })
        AIGroups.shared.standIn = engine

        await AIGroups.shared.grouper(for: browser).regroup()

        #expect(browser.tabGroups.first { $0.ai }?.name == "Sci Fi Films")
        #expect(engine.nameAsks.count == 1)
        #expect(AIGroupPrompt.naming(engine.nameAsks[0]).contains("Every tab has: Dune"))
    }
}

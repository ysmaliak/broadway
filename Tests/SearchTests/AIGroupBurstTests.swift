import AppKit
import Testing
@testable import Search

struct BurstDice {
    var state: UInt64

    init(_ seed: UInt64) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
    }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        mixed ^= mixed >> 31
        return Double(mixed >> 11) / Double(UInt64(1) << 53)
    }

    static func roll(_ text: String) -> Double {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        var dice = BurstDice(hash)
        return dice.next()
    }
}

final class BurstJev: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    let decider: OpenRouterDecider
    let namer = FakeGroupEngine()

    var batch: Int { decider.batch }

    init(host: String) {
        decider = OpenRouterDecider(key: "test-key-1234", model: OpenRouterDecider.jev, base: URL(string: "https://\(host)/api")!,
                                    session: DecisionsStub.session)
    }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        try await decider.decide(ask)
    }

    func fits(_ tab: AIGroupTab, in group: AIGroupInfo) async throws -> AIGroupFit {
        try await decider.fits(tab, in: group)
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        try await namer.name(ask)
    }

    static func city(_ title: String) -> String {
        title.split(separator: ":").first.map(String.init) ?? title
    }

    static func chance(_ seed: UInt64, _ one: String, _ two: String, salt: String = "") -> Double {
        let roll = BurstDice.roll("\(seed)|\(one)|\(two)|\(salt)")
        let spread = BurstDice.roll("\(seed)|\(two)|\(one)|\(salt)|spread")
        guard city(one) == city(two) else { return 0.03 + 0.2 * spread }
        return roll < 0.25 ? 0.35 + 0.2 * spread : 0.62 + 0.35 * spread
    }

    static func answering(seed: UInt64, instant: Bool = false) -> @Sendable (URLRequest, Data) -> DecisionsStub.Reply {
        let dice = BurstDiceBox(seed)
        return { _, body in
            let found = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let tab = ((found["state"] as? [String: Any])?["tab"] as? [String: Any])?["title"] as? String ?? ""
            var answers: [String: Any] = [:]
            for (id, question) in found["questions"] as? [String: Any] ?? [:] {
                let instructions = (question as? [String: Any])?["instructions"] as? [String: Any] ?? [:]
                var said = 0.02
                if let other = (instructions["other"] as? [String: Any])?["title"] as? String {
                    said = chance(seed, tab, other)
                } else if let folder = instructions["folder"] as? [String: Any] {
                    let titles = (folder["tabs"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
                    let same = titles.filter { city($0) == city(tab) }.count
                    let name = folder["name"] as? String ?? ""
                    said = same * 2 >= titles.count && same > 0
                        ? chance(seed, tab, city(tab), salt: "folder \(name) \(titles.count)")
                        : 0.03 + 0.2 * BurstDice.roll("\(seed)|\(tab)|\(name)")
                }
                answers[id] = ["type": "noul", "noul": said]
            }
            return DecisionsStub.Reply(body: DecisionsStub.nouls(answers), delay: instant ? 0 : dice.pause())
        }
    }
}

final class BurstDiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var dice: BurstDice

    init(_ seed: UInt64) {
        dice = BurstDice(seed &+ 7)
    }

    func pause() -> Double {
        lock.withLock { 0.3 + 0.6 * dice.next() }
    }
}

struct BurstOutcome: CustomStringConvertible {
    var engine: String
    var seed: UInt64
    var settled: Double
    var passes: Int
    var asks: Int
    var questions: Int
    var fits: Int
    var names: Int
    var twins: [String]
    var lost: [String]
    var jumps: [String]
    var vanished: Int
    var folders: [String]

    var description: String {
        let tail = "twins=\(twins) lost=\(lost.count) jumps=\(jumps.count) vanished=\(vanished) folders=\(folders)"
        return "BURST engine=\(engine) seed=\(seed) settled=\(String(format: "%.2f", settled))s passes=\(passes) asks=\(asks) questions=\(questions) fits=\(fits) names=\(names) " + tail
    }
}

@MainActor
enum Burst {
    static let cities: [(String, Int)] = [("Boston", 16), ("Miami", 18), ("Austin", 16), ("Sacramento", 9), ("San Francisco", 16), ("Philadelphia", 5)]
    static let streets = ["Market St", "Hyde St", "Beacon St", "Ocean Dr", "Congress Ave", "J St", "Walnut St", "Valencia St", "Brickell Ave", "Lamar Blvd"]
    static let sites = ["zillow.com/homedetails", "apartments.com/listing", "redfin.com/home", "hotpads.com/unit", "trulia.com/p"]

    static func pages() -> [(title: String, url: String)] {
        var out: [(title: String, url: String)] = []
        for (city, count) in cities {
            for index in 0..<count {
                let number = 100 + (out.count * 37) % 3900
                let street = streets[(out.count * 7 + index) % streets.count]
                let site = sites[(out.count + index) % sites.count]
                out.append(("\(city): \(1 + index % 4) bed at \(number) \(street)", "https://\(site)/\(out.count + 1000)"))
            }
        }
        return out
    }

    static func browser(_ pages: [(title: String, url: String)]) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        for (index, page) in pages.enumerated() {
            if index > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: page.url)!, title: "")
            browser.tabs.last?.cameBack = false
        }
        return browser
    }

    static func snapshot(_ browser: Browser) -> String {
        browser.tabGroups.map { "\($0.id) \($0.name)" }.joined(separator: ",") + "|"
            + browser.tabs.map { "\($0.groupID?.uuidString ?? "-")" }.joined(separator: ",")
    }

    static func run(seed: UInt64, jev: Bool, mixed: Bool = false, waves: Bool = false, instant: Bool = false, late: Double = 0.1, quiet: Double = 1.5, gap: Double = 4,
                    prepare: (Browser) -> Void = { _ in }) async -> BurstOutcome {
        var pages = pages()
        if mixed {
            var shuffle = BurstDice(seed &+ 99)
            for index in pages.indices.reversed() {
                pages.swapAt(index, Int(shuffle.next() * Double(index + 1)))
            }
        }
        let browser = browser(pages)
        let groups = AIGroups.shared
        groups.on = true
        groups.emoji = true
        groups.quiet = quiet
        groups.gap = gap
        groups.timeout = 25
        let host = "burst-\(seed)-\(UUID().uuidString.prefix(6).lowercased()).test"
        let fake = FakeGroupEngine()
        let dice = BurstDiceBox(seed)
        if !instant { fake.pause = { dice.pause() } }
        if jev {
            DecisionsStub.answer(host, BurstJev.answering(seed: seed, instant: instant))
            groups.standIn = BurstJev(host: host)
        } else {
            groups.standIn = fake
        }
        prepare(browser)
        let tracing = ProcessInfo.processInfo.environment["BURST_TRACE"]
        if tracing != nil { AIGroupTrace.begin() }
        let grouper = groups.grouper(for: browser)
        var order = BurstDice(seed)
        let tabs = browser.tabs
        var times = tabs.indices.map { index in
            waves ? (index % 2 == 0 ? 0.3 + 2.7 * order.next() : 6 + 6 * order.next()) : 0.3 + 4.0 * order.next()
        }
        times.sort()
        var landing = Array(tabs.indices)
        for index in landing.indices.reversed() {
            let other = Int(order.next() * Double(index + 1))
            landing.swapAt(index, other)
        }
        let unready = Set(landing.prefix(Int(Double(tabs.count) * late)))
        let titles = Dictionary(uniqueKeysWithValues: zip(tabs.map(\.id), pages))
        var events: [(at: Double, tab: Tab, titled: Bool)] = []
        for (slot, index) in landing.enumerated() {
            let tab = tabs[index]
            if unready.contains(index) {
                events.append((times[slot], tab, false))
                events.append((times[slot] + 0.5 + 1.5 * order.next(), tab, true))
            } else {
                events.append((times[slot], tab, true))
            }
        }
        events.sort { $0.at < $1.at }
        let started = Date()
        var history: [Tab.ID: [UUID]] = [:]
        var seenGroups: [UUID: Int] = [:]
        var lastChange = Date()
        var last = snapshot(browser)
        func look() {
            let now = snapshot(browser)
            guard now != last else { return }
            last = now
            lastChange = Date()
            for tab in browser.tabs {
                guard let id = tab.groupID else { continue }
                if history[tab.id]?.last != id { history[tab.id, default: []].append(id) }
            }
            for group in browser.tabGroups {
                seenGroups[group.id] = max(seenGroups[group.id] ?? 0, browser.tabs(in: group.id).count)
            }
        }
        var lastLanding = started
        for event in events {
            let wait = event.at - Date().timeIntervalSince(started)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            look()
            guard let page = titles[event.tab.id], let url = URL(string: page.url) else { continue }
            if event.titled {
                event.tab.restore(url: url, title: page.title)
                event.tab.cameBack = false
            }
            if !event.titled || !unready.contains(tabs.firstIndex { $0 === event.tab } ?? -1) {
                grouper.landed(event.tab)
                lastLanding = Date()
            }
        }
        lastLanding = max(lastLanding, Date())
        let until = Date().addingTimeInterval(180)
        while Date() < until {
            try? await Task.sleep(for: .milliseconds(25))
            look()
            let idle = !grouper.busy && (grouper.pending[browser.spaceID] ?? [:]).isEmpty
            if idle, Date().timeIntervalSince(lastChange) > max(6, gap + quiet + 1) { break }
        }
        var subjects: [String: Set<UUID>] = [:]
        var lost: [String] = []
        for tab in browser.tabs {
            let city = BurstJev.city(tab.title)
            if let id = browser.group(of: tab) { subjects[city, default: []].insert(id) }
        }
        for tab in browser.tabs where browser.group(of: tab) == nil {
            let city = BurstJev.city(tab.title)
            if subjects[city] != nil, cities.first(where: { $0.0 == city })?.1 ?? 0 > 2 { lost.append(tab.title) }
        }
        let twins = subjects.filter { $0.value.count > 1 }.map { city, ids in
            "\(city): " + ids.map { id in "\(browser.tabGroups.first { $0.id == id }?.name ?? "?") \(browser.tabs(in: id).count)" }.sorted().joined(separator: " + ")
        }.sorted()
        let jumps = history.filter { $0.value.count > 1 }.compactMap { id, _ in browser.tabs.first { $0.id == id }?.title }
        let vanished = seenGroups.filter { id, most in most >= 2 && !browser.tabGroups.contains { $0.id == id } }.count
        let folders = browser.tabGroups.map { "\($0.name) \(browser.tabs(in: $0.id).count)" }
        var asks = fake.asks.count
        var questions = fake.asks.reduce(0) { $0 + $1.fresh.count }
        var fits = fake.fitAsks.count
        var names = fake.nameAsks.count
        if jev, let engine = groups.standIn as? BurstJev {
            let seen = DecisionsStub.seen(host)
            asks = seen.count
            questions = seen.reduce(0) { $0 + DecisionsStub.asked($1.body).questions.count }
            fits = 0
            names = engine.namer.nameAsks.count
        }
        let outcome = BurstOutcome(engine: (jev ? "jev" : "fake") + (mixed ? " mixed" : "") + (waves ? " waves" : "") + (instant ? " instant" : ""), seed: seed, settled: lastChange.timeIntervalSince(lastLanding),
                                   passes: grouper.passes, asks: asks, questions: questions, fits: fits, names: names,
                                   twins: twins, lost: lost, jumps: jumps, vanished: vanished, folders: folders.sorted())
        print(outcome)
        if let tracing {
            let events = AIGroupTrace.end().filter { ["pass", "gather", "together", "twins"].contains($0["kind"] as? String ?? "") }
            let path = URL(fileURLWithPath: tracing).appending(path: "\(outcome.engine.replacingOccurrences(of: " ", with: "-"))-\(seed).json")
            if let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted]) { try? data.write(to: path) }
        }
        groups.standIn = nil
        browser.closeAll()
        return outcome
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(10)), .serialized)
@MainActor
final class AIGroupBurstTests {
    init() {
        keepSetting(AIGroups.shared, \.on, AIGroups.onKey)
        keepSetting(AIGroups.shared, \.emoji, AIGroups.emojiKey)
        addTeardownBlock { @MainActor in
            AIGroups.shared.standIn = nil
            AIGroups.shared.quiet = 1.5
            AIGroups.shared.gap = 4
            AIGroups.shared.timeout = 25
            AIGroups.shared.stop = 8
        }
    }

    @Test(arguments: [UInt64(1), 2, 3])
    func aBurstWithTheFakeMakesOneFolderPerSubject(seed: UInt64) async {
        let outcome = await Burst.run(seed: seed, jev: false)

        #expect(outcome.twins.isEmpty)
        #expect(outcome.lost.isEmpty)
        #expect(outcome.jumps.isEmpty)
        #expect(outcome.vanished == 0)
        #expect(outcome.folders.count == 6)
        #expect(outcome.passes == 1)
        #expect(outcome.asks <= 10)
        #expect(outcome.settled < 20)
    }

    @Test(arguments: [false, true])
    func aBurstAnsweredAtOnceMakesOneFolderPerSubject(jev: Bool) async {
        let outcome = await Burst.run(seed: 1, jev: jev, instant: true)

        #expect(outcome.twins.isEmpty)
        #expect(outcome.lost.isEmpty)
    }

    @Test(arguments: [(false, true, false), (false, false, true), (true, true, false), (true, false, true)])
    func aBurstInMixedRowsOrInTwoWavesMakesOneFolderPerSubject(jev: Bool, mixed: Bool, waves: Bool) async {
        let outcome = await Burst.run(seed: mixed ? 4 : 5, jev: jev, mixed: mixed, waves: waves)

        #expect(outcome.twins.isEmpty)
        #expect(outcome.lost.isEmpty)
        #expect(outcome.folders.count == 6)
        if !jev {
            #expect(outcome.jumps.isEmpty)
            #expect(outcome.vanished == 0)
        }
    }

    @Test(arguments: [UInt64(1), 2, 3])
    func aBurstWithJevMakesOneFolderPerSubject(seed: UInt64) async {
        let outcome = await Burst.run(seed: seed, jev: true)

        #expect(outcome.twins.isEmpty)
        #expect(outcome.lost.isEmpty)
        #expect(outcome.passes == 1)
        #expect(outcome.questions < 3000)
        #expect(outcome.settled < 38)
    }
}


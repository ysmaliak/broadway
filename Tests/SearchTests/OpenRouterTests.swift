import AppKit
import Testing
@testable import Search

final class OpenRouterStubProtocol: URLProtocol {
    typealias Answer = @Sendable (URLRequest, [String: Any]?) -> (Int, Any)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Answer] = [:]
    nonisolated(unsafe) private static var seen: [String: [(URLRequest, [String: Any]?)]] = [:]

    static func route(_ host: String, _ answer: @escaping Answer) {
        lock.withLock { routes[host] = answer }
    }

    static func requests(_ host: String) -> [(URLRequest, [String: Any]?)] {
        lock.withLock { seen[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let answer = Self.lock.withLock { () -> Answer? in
            Self.seen[host, default: []].append((request, body))
            return Self.routes[host]
        }
        let (status, payload) = answer?(request, body) ?? (404, ["error": ["code": 404]])
        let out = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: out)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct OpenRouterStub {
    let host = "stub-\(UUID().uuidString.prefix(8).lowercased()).test"
    let session: URLSession

    init(_ answer: @escaping OpenRouterStubProtocol.Answer) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenRouterStubProtocol.self]
        session = URLSession(configuration: configuration)
        OpenRouterStubProtocol.route(host, answer)
    }

    var client: OpenRouterClient { OpenRouterClient(base: URL(string: "https://\(host)/api/v1")!, session: session, seconds: 5) }
    var requests: [(URLRequest, [String: Any]?)] { OpenRouterStubProtocol.requests(host) }

    static func naming(_ name: String, keep: Bool = false) -> OpenRouterStub {
        OpenRouterStub { request, _ in
            guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer sk-or-good") == true else {
                return (401, ["error": ["code": 401, "message": "No auth credentials found for \(request.value(forHTTPHeaderField: "Authorization") ?? "")"]])
            }
            if request.url?.path().hasSuffix("/key") == true { return (200, ["data": ["label": "stub"]]) }
            let said = "{\"name\": \"\(name)\", \"emoji\": \"🗂️\", \"keep\": \(keep)}"
            return (200, ["choices": [["message": ["role": "assistant", "content": said]]], "usage": ["cost": 0.00002]])
        }
    }
}

final class TroubleNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [OpenRouterTrouble?] = []
    var all: [OpenRouterTrouble?] { lock.withLock { said } }
    func add(_ trouble: OpenRouterTrouble?) { lock.withLock { said.append(trouble) } }
}

final class NamingStub: AIGroupNamer, @unchecked Sendable {
    let local: Bool
    private let lock = NSLock()
    private var asked: [AIGroupNameAsk] = []
    let answer: @Sendable (AIGroupNameAsk) throws -> AIGroupName

    init(local: Bool, _ answer: @escaping @Sendable (AIGroupNameAsk) throws -> AIGroupName) {
        self.local = local
        self.answer = answer
    }

    var asks: [AIGroupNameAsk] { lock.withLock { asked } }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        lock.withLock { asked.append(ask) }
        return try answer(ask)
    }
}

final class DecidingStub: AIGroupDecider, @unchecked Sendable {
    let local: Bool
    let fails: Bool
    private let lock = NSLock()
    private var asked: [AIGroupAsk] = []

    init(local: Bool, fails: Bool) {
        self.local = local
        self.fails = fails
    }

    var asks: [AIGroupAsk] { lock.withLock { asked } }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        lock.withLock { asked.append(ask) }
        if fails { throw URLError(.notConnectedToInternet) }
        return Dictionary(uniqueKeysWithValues: ask.fresh.map { ($0.id, AIGroupPick.none) })
    }
}

struct ThrowingDecider: AIGroupDecider {
    let local = false
    let error: any Error & Sendable

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        throw error
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class OpenRouterTests {
    private func tab(_ title: String, _ address: String, by: String = "") -> AIGroupTab {
        AIGroupTab(id: UUID(), title: title, url: URL(string: address), by: by)!
    }

    private var kyoto: [AIGroupTab] {
        [tab("The 10 best hotels in Kyoto - Booking.com", "https://www.booking.com/city/jp/kyoto.html?aid=356980&label=private-token", by: "Booking Writer"),
         tab("Kyoto Travel Guide - japan-guide.com", "https://www.japan-guide.com/e/e2158.html#secret")]
    }

    private func browser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let groups = AIGroups.shared
        let before = (groups.openRouter, groups.macAvailable, groups.macNamer, groups.remoteNamer, groups.macDecider, groups.remoteDecider)
        groups.timeout = 5
        addTeardownBlock { @MainActor in
            groups.standIn = nil
            groups.namerStandIn = nil
            (groups.openRouter, groups.macAvailable, groups.macNamer, groups.remoteNamer, groups.macDecider, groups.remoteDecider) = before
            groups.timeout = 25
            browser.closeAll()
        }
        return browser
    }

    private func useKey(_ key: String?) -> OpenRouterKey {
        let made = OpenRouterKey(store: OpenRouterMemoryStore(key))
        AIGroups.shared.openRouter = made
        return made
    }

    @Test func theNamerSendsOnlyTitlesSiteNamesAndTheSearch() async throws {
        let stub = OpenRouterStub.naming("Kyoto Trip")
        let namer = OpenRouterNamer(key: "sk-or-good-1", client: stub.client, report: { _ in })
        let ask = AIGroupNameAsk(tabs: kyoto, current: "Japan", currentEmoji: "🗾", emoji: true, query: "kyoto trip")

        let said = try await namer.name(ask)

        #expect(said.name == "Kyoto Trip")
        let (request, sent) = try #require(stub.requests.first)
        let body = try #require(sent)
        #expect(request.url?.absoluteString == "https://\(stub.host)/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-or-good-1")
        #expect(Set(body.keys) == ["model", "messages", "max_tokens", "reasoning", "response_format", "usage"])
        #expect(body["model"] as? String == OpenRouterModels.naming)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.map { $0["role"] } == ["system", "user"])
        #expect(messages[1]["content"] == """
        Tabs:
        - "The 10 best hotels in Kyoto - Booking.com" — booking.com
        - "Kyoto Travel Guide - japan-guide.com" — japan-guide.com
        Every tab has: Kyoto
        Searched for: kyoto trip
        Current name: Japan
        Current emoji: 🗾
        """)
        let everything = messages.compactMap { $0["content"] }.joined()
        for private_ in ["city/jp", "kyoto.html", "aid=", "private-token", "secret", "e2158", "Booking Writer"] {
            #expect(!everything.contains(private_))
        }
    }

    @Test func theModelsAreFixedInCodeAndTheLatestOfEach() {
        #expect(OpenRouterModels.naming == "~deepseek/deepseek-flash-latest")
        #expect(OpenRouterModels.grouping == "~typesafe/jev-latest")
        #expect(OpenRouterModels.namingEffort == "none")
    }

    @Test func aTestRunNeverReachesOpenRouterItself() async {
        let client = OpenRouterClient(base: OpenRouterClient.real)

        await #expect(throws: OpenRouterTrouble.testRun) { try await client.check(key: "sk-or-good-1") }
        await #expect(throws: OpenRouterTrouble.testRun) {
            _ = try await client.chat(key: "sk-or-good-1", model: OpenRouterModels.naming, system: "", prompt: "")
        }
    }

    @Test func troubleIsSaidInPlainWordsAndNeverRepeatsTheServer() async {
        let answers: [(Int, OpenRouterTrouble)] = [(401, .refused), (403, .refused), (402, .noCredit), (429, .busy), (503, .busy), (500, .nonsense)]
        for (status, trouble) in answers {
            let stub = OpenRouterStub { _, _ in (status, ["error": ["code": status, "message": "sk-or-bad-SECRET leaked"]]) }
            await #expect(throws: trouble) { try await stub.client.check(key: "sk-or-bad-SECRET") }
            #expect(!trouble.words.contains("sk-or"))
            #expect(!trouble.words.contains(";"))
            #expect(!trouble.words.hasSuffix("."))
        }
        let empty = OpenRouterStub { _, _ in (200, ["choices": [["message": ["content": "  "]]]]) }
        await #expect(throws: OpenRouterTrouble.nonsense) {
            _ = try await empty.client.chat(key: "sk-or-good-1", model: "m", system: "", prompt: "")
        }
    }

    @Test func aKeyIsCheckedBeforeItIsKeptAndRemovingItForgetsIt() async {
        let stub = OpenRouterStub.naming("Kyoto Trip")
        let store = OpenRouterMemoryStore()
        let keys = OpenRouterKey(store: store)
        keys.client = { stub.client }

        let refused = await keys.save("sk-or-bad-SECRET")

        #expect(!refused)
        #expect(!keys.present)
        #expect(store.read() == nil)
        #expect(keys.trouble == "OpenRouter turned this key down")

        let saved = await keys.save("  sk-or-good-2\n")

        #expect(saved)
        #expect(keys.present)
        #expect(keys.trouble == nil)
        #expect(store.read() == "sk-or-good-2")
        #expect(stub.requests.allSatisfy { $0.0.url?.path().hasSuffix("/key") == true && $0.0.httpMethod == "GET" })

        keys.remove()

        #expect(!keys.present)
        #expect(store.read() == nil)
    }

    @Test func theKeyNeverAppearsInTracesHowOrNotes() async {
        let browser = browser()
        let stub = OpenRouterStub.naming("Kyoto Trip")
        let notes = TroubleNotes()
        let namer = OpenRouterNamer(key: "sk-or-bad-SECRET", client: stub.client, report: { notes.add($0) })
        let grouper = AIGroups.shared.grouper(for: browser)
        AIGroupTrace.begin()

        let said = await grouper.resolve(namer, AIGroupNameAsk(tabs: kyoto, current: nil, currentEmoji: nil, emoji: true))

        let trace = AIGroupTrace.end()
        let written = String(describing: trace) + said.how + (said.name?.name ?? "") + notes.all.map { $0?.words ?? "" }.joined()
        #expect(!written.contains("SECRET"))
        #expect(!written.contains("sk-or"))
        #expect(said.how.hasPrefix("fallback: the namer on OpenRouter failed: OpenRouter turned this key down"))
        #expect(notes.all == [.refused])
    }

    @Test func withoutAKeyNothingTurnsToOpenRouter() {
        _ = browser()
        _ = useKey(nil)
        let groups = AIGroups.shared
        groups.macAvailable = { true }
        groups.remoteDecider = { _, _ in DecidingStub(local: false, fails: false) }

        #expect(groups.naming == .thisMac)
        #expect(groups.deciding == .thisMac)
        #expect(groups.namers().count == 1)
        #expect(groups.namers().map(\.local) == [true])
        #expect(!(groups.decider() is AIGroupDeciderChain))
        #expect(groups.sends == "Related tabs find each other as you open them. Runs on this Mac. Nothing leaves it.")
    }

    @Test func aKeyNamesFirstThenThisMacThenTheStandInName() async {
        let browser = browser()
        _ = useKey("sk-or-good-3")
        let groups = AIGroups.shared
        groups.macAvailable = { true }
        let remote = NamingStub(local: false) { _ in throw OpenRouterTrouble.noCredit }
        let mac = NamingStub(local: true) { _ in AIGroupName(name: "Kyoto Trip", emoji: "⛩️") }
        groups.remoteNamer = { _ in remote }
        groups.macNamer = { mac }
        let grouper = groups.grouper(for: browser)
        let ask = AIGroupNameAsk(tabs: kyoto, current: nil, currentEmoji: nil, emoji: true)

        let fellBack = await grouper.resolve(groups.namerEngine(), ask)

        #expect(groups.naming == .openRouter)
        #expect(fellBack.name?.name == "Kyoto Trip")
        #expect(fellBack.how == "model on this Mac")
        #expect(remote.asks.count == 1)
        #expect(remote.asks[0].tabs.allSatisfy { $0.query.isEmpty && $0.by.isEmpty })
        #expect(mac.asks[0].tabs.contains { !$0.path.isEmpty })

        let broken = NamingStub(local: true) { _ in throw OpenRouterTrouble.nonsense }
        groups.macNamer = { broken }

        let standIn = await grouper.resolve(groups.namerEngine(), ask)

        #expect(standIn.how.hasPrefix("fallback: the namer on this Mac failed"))
        #expect(standIn.name?.name == AIGroupNames.fallback(kyoto))

        let named = NamingStub(local: false) { _ in AIGroupName(name: "Kyoto Trip", emoji: "⛩️") }
        groups.remoteNamer = { _ in named }

        let first = await grouper.resolve(groups.namerEngine(), ask)

        #expect(first.how == "model on OpenRouter")
        #expect(broken.asks.count == 1)
    }

    @Test func aRemoteNameRejectedTwiceGoesToThisMac() async {
        let browser = browser()
        _ = useKey("sk-or-good-4")
        let groups = AIGroups.shared
        groups.macAvailable = { true }
        let tabs = kyoto
        let remote = NamingStub(local: false) { _ in AIGroupName(name: tabs[1].title, emoji: nil) }
        let mac = NamingStub(local: true) { _ in AIGroupName(name: "Kyoto", emoji: nil) }
        groups.remoteNamer = { _ in remote }
        groups.macNamer = { mac }

        let said = await groups.grouper(for: browser).resolve(groups.namerEngine(), AIGroupNameAsk(tabs: tabs, current: nil, currentEmoji: nil, emoji: false))

        #expect(remote.asks.count == 2)
        #expect(said.name?.name == "Kyoto")
        #expect(said.how == "model on this Mac")
    }

    @Test func removingTheKeyGoesStraightBackToThisMac() {
        _ = browser()
        let keys = useKey("sk-or-good-5")
        let groups = AIGroups.shared
        groups.macAvailable = { true }

        #expect(groups.namers().map(\.local) == [false, true])

        keys.remove()

        #expect(groups.namers().map(\.local) == [true])
        #expect(groups.naming == .thisMac)
    }

    @Test func noAuthorGoesToOpenRouterEvenOneReadEarlierOnThisMac() async throws {
        let remote = DecidingStub(local: false, fails: false)
        let chain = AIGroupDeciderChain(remote: remote, mac: nil, report: { _ in })
        let fresh = tab("Pasta at home - YouTube", "https://www.youtube.com/watch?v=1", by: "Sam Rowe")
        let loose = tab("Bread at home - YouTube", "https://www.youtube.com/watch?v=2", by: "Sam Rowe")

        _ = try await chain.decide(AIGroupAsk(groups: [], loose: [loose], fresh: [fresh]))

        let asked = try #require(remote.asks.first)
        #expect((asked.fresh + asked.loose).map(\.by) == ["", ""])
        #expect(AIGroupNameAsk(tabs: [fresh, loose], current: nil, currentEmoji: nil, emoji: false).bare.tabs.map(\.by) == ["", ""])
    }

    @Test func groupingGoesToOpenRouterOnlyWithAKeyAndFallsBackToThisMac() async throws {
        _ = browser()
        let keys = useKey("sk-or-good-6")
        let groups = AIGroups.shared
        groups.macAvailable = { true }
        let remote = DecidingStub(local: false, fails: true)
        let mac = DecidingStub(local: true, fails: false)
        var models: [String] = []
        groups.remoteDecider = { _, model in
            models.append(model)
            return remote
        }
        groups.macDecider = { mac }
        let fresh = tab("Kyoto hotels", "https://www.booking.com/city/jp/kyoto.html?aid=1")

        #expect(groups.deciding == .openRouter)
        let decider = try #require(groups.decider())
        _ = try await decider.decide(AIGroupAsk(groups: [], loose: [], fresh: [fresh]))

        #expect(models == [OpenRouterModels.grouping])
        #expect(remote.asks.first?.fresh.first?.path == "")
        #expect(remote.asks.first?.fresh.first?.query == "")
        #expect(mac.asks.first?.fresh.first?.path == "/city/jp/kyoto.html")
        #expect(keys.trouble == "Broadway couldn't reach OpenRouter")

        groups.macAvailable = { false }
        let alone = try #require(groups.decider())

        await #expect(throws: OpenRouterTrouble.unreachable) { _ = try await alone.decide(AIGroupAsk(groups: [], loose: [], fresh: [fresh])) }
        #expect(groups.deciding == .openRouter)
        #expect(groups.sends == "Related tabs find each other as you open them. OpenRouter sorts and names them with your key.")
    }

    @Test func theDecidersFailuresAreSaidInTheKeyRowsWords() async {
        let ask = AIGroupAsk(groups: [], loose: [], fresh: [tab("Kyoto hotels", "https://www.booking.com/city/jp/kyoto.html")])
        let decider = OpenRouterDecider(key: "sk-or-good-7", model: OpenRouterModels.grouping)
        let cases: [(any Error & Sendable, OpenRouterTrouble)] = [
            (decider.reason(status: 401), .refused),
            (decider.reason(status: 403), .refused),
            (decider.reason(status: 402), .noCredit),
            (decider.reason(status: 429), .busy),
            (decider.reason(status: 503), .busy),
            (decider.reason(status: 404), .nonsense),
            (decider.reason(status: 400), .nonsense),
            (decider.reason(status: 500), .nonsense),
            (OpenRouterDecider.reason(URLError(.notConnectedToInternet)), .unreachable),
            (ProviderError.failed("The answer from \(OpenRouterModels.grouping) couldn't be read"), .nonsense),
        ]
        for (error, wanted) in cases {
            let notes = TroubleNotes()
            let chain = AIGroupDeciderChain(remote: ThrowingDecider(error: error), mac: nil, report: { notes.add($0) })

            await #expect(throws: wanted) { _ = try await chain.decide(ask) }
            #expect(notes.all == [wanted])
        }
    }

    @Test func aCancelledOrTestRunDecisionSaysNoTrouble() async throws {
        let ask = AIGroupAsk(groups: [], loose: [], fresh: [tab("Kyoto hotels", "https://www.booking.com/city/jp/kyoto.html")])
        let notes = TroubleNotes()
        let mac = DecidingStub(local: true, fails: false)
        let cancelled = AIGroupDeciderChain(remote: ThrowingDecider(error: ProviderError.cancelled), mac: mac, report: { notes.add($0) })

        await #expect(throws: ProviderError.cancelled) { _ = try await cancelled.decide(ask) }
        #expect(mac.asks.isEmpty)

        let pair = AIGroupAsk(groups: [], loose: [tab("Kyoto rail pass", "https://www.japan-guide.com/e/e2361.html")], fresh: ask.fresh)
        let real = AIGroupDeciderChain(remote: OpenRouterDecider(key: "sk-or-good-8", model: OpenRouterModels.grouping), mac: mac, report: { notes.add($0) })
        _ = try await real.decide(pair)

        #expect(mac.asks.count == 1)
        #expect(notes.all.isEmpty)
    }

    @Test func aNameStaysWhileItStillSaysTheSubject() async {
        let browser = browser()
        let tabs = kyoto + [tab("Fushimi Inari opening hours - Inside Kyoto", "https://www.insidekyoto.com/fushimi-inari")]
        let answers = NamingStub(local: false) { _ in AIGroupName(name: "Kyoto Hotels Guide", emoji: nil) }

        let said = await AIGroups.shared.grouper(for: browser).resolve(answers, AIGroupNameAsk(tabs: tabs, current: "Kyoto Trip", currentEmoji: nil, emoji: false))

        #expect(said.name == nil)
        #expect(said.how.hasPrefix("kept: the model"))
        #expect(AIGroupNames.sameSubject("Kyoto Hotels Guide", "Kyoto Trip"))
        #expect(!AIGroupNames.sameSubject("Porto Trip", "Lisbon Trip"))
        #expect(!AIGroupNames.sameSubject("Flagship Phones", "iPhone 17"))
    }

    @Test func thisMacMayKeepANameOnlyWhileMostTabsStillSayIt() async {
        let browser = browser()
        let phones = [tab("iPhone 17 review - The Verge", "https://www.theverge.com/iphone-17"),
                      tab("Buy iPhone 17 - Apple", "https://www.apple.com/shop/buy-iphone"),
                      tab("Google Pixel 10 review - The Verge", "https://www.theverge.com/pixel-10"),
                      tab("Samsung Galaxy S26 review - GSMArena", "https://www.gsmarena.com/galaxy-s26"),
                      tab("Which flagship should you buy? - Tom's Guide", "https://www.tomsguide.com/flagships")]
        let mac = NamingStub(local: true) { ask in
            ask.rejected.isEmpty ? AIGroupName(name: "", emoji: nil, keep: true) : AIGroupName(name: "Flagship Phones", emoji: nil)
        }

        let said = await AIGroups.shared.grouper(for: browser).resolve(mac, AIGroupNameAsk(tabs: phones, current: "iPhone 17", currentEmoji: nil, emoji: false))

        #expect(said.name?.name == "Flagship Phones")
        #expect(mac.asks.last?.rejected == ["“iPhone 17”, because it no longer says what most of the tabs share"])
        #expect(!AIGroupNames.describes("iPhone 17", phones))
        #expect(AIGroupNames.describes("Kyoto Trip", kyoto))
    }

    @Test func theMacPromptTellsTheCurrentNameAndThatItMayStay() {
        let ask = AIGroupNameAsk(tabs: kyoto, current: "Kyoto Trip", currentEmoji: nil, emoji: false)

        #expect(AIGroupPrompt.naming(ask).contains("Current name: Kyoto Trip"))
        #expect(AIGroupPrompt.naming(emoji: false).contains("keep it"))
        #expect(AIGroupPrompt.remoteNaming(emoji: false).contains("\"keep\""))
    }

    @Test func theSettingsWordsSayWhatLeavesTheMac() {
        let words = [
            AIGroupWords.line(mac: true, key: false),
            AIGroupWords.line(mac: true, key: true),
            AIGroupWords.line(mac: false, key: false),
            AIGroupWords.keyLine(state: .none, trouble: nil),
            AIGroupWords.keyLine(state: .saved, trouble: nil),
            AIGroupWords.keyLine(state: .checking, trouble: nil),
            AIGroupWords.keyLine(state: .saved, trouble: OpenRouterTrouble.noCredit.words),
            AIGroupWords.stepLine(mac: true),
            AIGroupWords.stepLine(mac: false),
        ]
        for line in words {
            #expect(!line.contains(";"))
            #expect(!line.contains("…"))
            let sentences = line.split(separator: ".").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            if sentences == 1 { #expect(!line.hasSuffix(".")) }
            #expect(!line.lowercased().contains("deepseek"))
            #expect(!line.lowercased().contains("jev"))
            #expect(!line.lowercased().contains("luna"))
        }
        #expect(AIGroupWords.line(mac: true, key: true) == "Related tabs find each other as you open them. OpenRouter sorts and names them with your key.")
        #expect(AIGroupWords.line(mac: false, key: false) == AIGroupWords.needs)
        #expect(AIGroupWords.keyLine(state: .saved, trouble: nil)
                == "Tab titles, site names, folder names and searches go to OpenRouter, never addresses, authors or pages")
        #expect(AIGroupWords.keyLine(state: .none, trouble: nil)
                == "Add your own key and OpenRouter sorts and names folders. The key stays in this Mac's Keychain.")
        #expect(AIGroupWords.keyLine(state: .saved, trouble: "Your OpenRouter account is out of credit")
                == "Your OpenRouter account is out of credit")
        #expect(AIGroupWords.stepLine(mac: true)
                == "OpenRouter sorts and names your folders. Only tab titles, site names and searches are sent. It costs a fraction of a cent a folder on your account, and the key stays in this Mac's Keychain.")
        let row = SettingsIndex.item("groups.openrouter")
        #expect(row?.detail == "Add your own key and OpenRouter names folders. The key stays in this Mac's Keychain.")
        #expect(row?.title == "OpenRouter key")
        #expect(row?.group == "tabs")
        #expect(row?.words.contains("openrouter") == true)
    }

    @Test func addOnTheKeyRowChecksTheKeyKeepsItAndEmptiesTheField() async throws {
        let stub = OpenRouterStub.naming("Kyoto Trip")
        let keys = OpenRouterKey.shared
        let client = keys.client
        keys.remove()
        keys.client = { stub.client }
        addTeardownBlock { @MainActor in
            keys.remove()
            keys.note(nil)
            keys.client = client
        }
        let shell = SettingsShell()
        shell.go(to: .tabs)
        let page = SettingsPageView(browser: browser(), shell: shell)
        page.rebuild()

        page.drafts.openRouterKey = "sk-or-bad-row"
        page.saveOpenRouterKey()
        for _ in 0..<250 where keys.trouble == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!keys.present)
        #expect(keys.trouble == "OpenRouter turned this key down")
        #expect(page.drafts.openRouterKey == "sk-or-bad-row")

        page.drafts.openRouterKey = "sk-or-good-row"
        page.saveOpenRouterKey()
        for _ in 0..<250 where !page.drafts.openRouterKey.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(keys.present)
        #expect(keys.key == "sk-or-good-row")
        #expect(keys.trouble == nil)
        #expect(page.drafts.openRouterKey.isEmpty)
        #expect(stub.requests.count == 2)
        #expect(stub.requests.allSatisfy { $0.0.httpMethod == "GET" && $0.0.url?.path().hasSuffix("/key") == true })
    }

    @Test func troubleOnTheKeyRowClearsOnTheNextSuccess() {
        let keys = OpenRouterKey(store: OpenRouterMemoryStore("sk-or-good-7"))

        keys.note(.noCredit)

        #expect(keys.trouble == "Your OpenRouter account is out of credit")

        keys.note(nil)

        #expect(keys.trouble == nil)
    }
}

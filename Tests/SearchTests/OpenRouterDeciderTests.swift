import Foundation
import Testing
@testable import Search

final class DecisionsStub: URLProtocol {
    struct Reply {
        var status = 200
        var body = Data()
        var failure: URLError?
        var delay: Double = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: @Sendable (URLRequest, Data) -> Reply] = [:]
    nonisolated(unsafe) private static var heard: [String: [(request: URLRequest, body: Data)]] = [:]

    static func answer(_ host: String, _ reply: @escaping @Sendable (URLRequest, Data) -> Reply) {
        lock.withLock {
            replies[host] = reply
            heard[host] = []
        }
    }

    static func seen(_ host: String) -> [(request: URLRequest, body: Data)] {
        lock.withLock { heard[host] ?? [] }
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DecisionsStub.self]
        return URLSession(configuration: configuration)
    }()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        let reply = Self.lock.withLock { () -> Reply? in
            Self.heard[host, default: []].append((request, body))
            return Self.replies[host].map { $0(request, body) }
        } ?? Reply(failure: URLError(.cannotFindHost))
        if reply.delay > 0 {
            nonisolated(unsafe) let loading = self
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { loading.deliver(reply) }
            return
        }
        deliver(reply)
    }

    private func deliver(_ reply: Reply) {
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func asked(_ body: Data) -> (tab: String, questions: [String: String]) {
        let found = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let tab = ((found["state"] as? [String: Any])?["tab"] as? [String: Any])?["title"] as? String ?? ""
        var questions: [String: String] = [:]
        for (id, question) in found["questions"] as? [String: Any] ?? [:] {
            let instructions = (question as? [String: Any])?["instructions"] as? [String: Any] ?? [:]
            let other = (instructions["other"] as? [String: Any])?["title"] as? String
            let folder = (instructions["folder"] as? [String: Any])?["name"] as? String
            questions[id] = other ?? folder ?? ""
        }
        return (tab, questions)
    }

    static func nouls(_ answers: [String: Any], cost: Double? = 0.0000421) -> Data {
        var usage: [String: Any] = ["input_tokens": 1000, "output_tokens": 20]
        if let cost { usage["cost"] = cost }
        let whole: [String: Any] = ["id": "gen-dec-1", "model": "typesafe/jev-1.14-20261014", "provider": "TypeSafe",
                                    "answers": answers, "usage": usage]
        return try! JSONSerialization.data(withJSONObject: whole)
    }

    static func chances(_ chance: @escaping @Sendable (String, String) -> Double) -> @Sendable (URLRequest, Data) -> Reply {
        { _, body in
            let asked = asked(body)
            var answers: [String: Any] = [:]
            for (id, about) in asked.questions { answers[id] = ["type": "noul", "noul": chance(asked.tab, about)] }
            return Reply(body: nouls(answers))
        }
    }

    static func failing(_ status: Int) -> @Sendable (URLRequest, Data) -> Reply {
        { _, _ in Reply(status: status, body: Data("{\"error\":{\"code\":\(status),\"message\":\"test-key-1234 was refused\"}}".utf8)) }
    }
}

@Suite struct OpenRouterDeciderTests {
    static let key = "test-key-1234"

    static func decider(_ host: String, model: String = OpenRouterDecider.jev) -> OpenRouterDecider {
        OpenRouterDecider(key: key, model: model, base: URL(string: "https://\(host)/api")!, session: DecisionsStub.session)
    }

    static func tab(_ title: String, _ host: String, _ path: String = "", query: String = "", by: String = "") -> AIGroupTab {
        AIGroupTab(id: UUID(), title: title, host: host, path: path, query: query, by: by)
    }

    static func pair(_ chances: [String: Double]) -> @Sendable (String, String) -> Double {
        { tab, about in chances["\(tab)|\(about)"] ?? 0.02 }
    }

    @Test func theBodyIsPinned() async throws {
        let hotel = Self.tab("Hotels in Lisbon", "booking.com", "/city/pt/lisbon.html", query: "aid=304142", by: "Sam Rowe")
        let flight = Self.tab("Flights to Lisbon", "skyscanner.net", "/transport/flights/lis", query: "adults=2", by: "Skyscanner")
        let pasta = Self.tab("Pasta recipes", "bbc.co.uk", "/food/pasta")
        let ask = AIGroupAsk(groups: [AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [flight])], loose: [pasta], fresh: [hotel])
        DecisionsStub.answer("pinned.test", DecisionsStub.chances { _, _ in 0.1 })
        _ = try await Self.decider("pinned.test").decide(ask)
        let seen = DecisionsStub.seen("pinned.test")
        #expect(seen.count == 1)
        let request = try #require(seen.first)
        #expect(request.request.url?.absoluteString == "https://pinned.test/api/alpha/decisions")
        #expect(request.request.httpMethod == "POST")
        #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.key)")
        #expect(request.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.request.value(forHTTPHeaderField: "HTTP-Referer") == nil)
        #expect(request.request.value(forHTTPHeaderField: "X-Title") == nil)
        #expect(request.request.timeoutInterval == 12)
        let yes = "They all serve that one task"
        let no = "They only share a website, a kind of page such as two videos or two articles, a broad field, or a word, or they serve different tasks"
        let tasks = "such as planning one trip, choosing one purchase, finding one flat, applying for one job, fixing one bug, following one story or learning one subject"
        let criteria = "{\"true\":\"\(yes)\",\"false\":\"\(no)\"}"
        let creator = "{\"true\":\"The same channel, podcast or writer made both\","
            + "\"false\":\"Different creators, or one news outlet, shop, company or site publishing about different things\"}"
        let flightSeen = "{\"title\":\"Flights to Lisbon\",\"site\":\"skyscanner.net\",\"by\":\"Skyscanner\"}"
        let expected = "{\"model\":\"~typesafe/jev-latest\","
            + "\"state\":{\"tab\":{\"title\":\"Hotels in Lisbon\",\"site\":\"booking.com\",\"by\":\"Sam Rowe\"}},\"questions\":{"
            + "\"folder1\":{\"type\":\"noul\",\"instructions\":{\"question\":\"Would a person with `tab` and the tabs in `folder` open be using them all for one task, \(tasks)?\","
            + "\"folder\":{\"name\":\"Lisbon trip\",\"tabs\":[\(flightSeen)]}},\"criteria\":\(criteria)},"
            + "\"folder1tab1\":{\"type\":\"noul\",\"instructions\":{\"question\":\"Would a person with `tab` and `other` open be using them for one task, \(tasks)?\","
            + "\"other\":\(flightSeen)},\"criteria\":\(criteria)},"
            + "\"folder1tab1by\":{\"type\":\"noul\",\"instructions\":{\"question\":\"Are `tab` and `other` made by one creator the person follows, such as one YouTube channel, one podcast or one writer?\","
            + "\"other\":\(flightSeen)},\"criteria\":\(creator)},"
            + "\"tab1\":{\"type\":\"noul\",\"instructions\":{\"question\":\"Would a person with `tab` and `other` open be using them for one task, \(tasks)?\","
            + "\"other\":{\"title\":\"Pasta recipes\",\"site\":\"bbc.co.uk\"}},\"criteria\":\(criteria)}}}"
        #expect(String(decoding: request.body, as: UTF8.self) == expected)
        let sent = String(decoding: request.body, as: UTF8.self)
        for hidden in ["/city", "lisbon.html", "aid=", "/transport", "adults", "/food", Self.key] {
            #expect(!sent.contains(hidden))
        }
    }

    @Test(arguments: [(0.6, true), (0.59, false), (0.97, true), (0.5, false), (0.3, false)])
    func aPairJoinsAtTheBar(chance: Double, joins: Bool) async throws {
        let host = "edge-\(Int(chance * 100)).test"
        let fresh = Self.tab("Самоделкин – покупка дома", "youtube.com", "/watch")
        let loose = Self.tab("Самоделкин меняет пикап на дом", "youtube.com", "/watch")
        DecisionsStub.answer(host, DecisionsStub.chances { _, _ in chance })
        let picks = try await Self.decider(host).decide(AIGroupAsk(groups: [], loose: [loose], fresh: [fresh]))
        #expect(picks[fresh.id] == (joins ? .tab(loose.id) : AIGroupPick.none))
        #expect(OpenRouterDecider.Thresholds.standard(for: OpenRouterDecider.jev).yes == 0.6)
    }

    @Test func theLikeliestPlaceWins() async throws {
        let group = AIGroupInfo(id: UUID(), name: "Heat pumps", members: [Self.tab("Heat Pump Systems", "energy.gov")])
        let fresh = Self.tab("Mitsubishi heat pump prices", "homedepot.com")
        let loose = Self.tab("Heat pump regrets in a cold climate", "reddit.com")
        DecisionsStub.answer("likeliest.test", DecisionsStub.chances(Self.pair([
            "Mitsubishi heat pump prices|Heat pumps": 0.88, "Mitsubishi heat pump prices|Heat pump regrets in a cold climate": 0.93,
            "Heat pump regrets in a cold climate|Mitsubishi heat pump prices": 0.94, "Mitsubishi heat pump prices|Heat Pump Systems": 0.7,
        ])))
        var picks = try await Self.decider("likeliest.test").decide(AIGroupAsk(groups: [group], loose: [loose], fresh: [fresh]))
        #expect(picks[fresh.id] == .group(group.id))
        DecisionsStub.answer("folder-first.test", DecisionsStub.chances(Self.pair([
            "Mitsubishi heat pump prices|Heat pumps": 0.9, "Mitsubishi heat pump prices|Heat pump regrets in a cold climate": 0.9,
            "Heat pump regrets in a cold climate|Mitsubishi heat pump prices": 0.9, "Mitsubishi heat pump prices|Heat Pump Systems": 0.7,
        ])))
        picks = try await Self.decider("folder-first.test").decide(AIGroupAsk(groups: [group], loose: [loose], fresh: [fresh]))
        #expect(picks[fresh.id] == .group(group.id))
    }

    @Test func severalNewTabsAskAboutAFoldersTabsOnlyAfterItsOwnAnswer() async throws {
        let flight = Self.tab("Flights to Lisbon", "skyscanner.net")
        let group = AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [flight])
        let hotel = Self.tab("Hotels in Lisbon", "booking.com")
        let pasta = Self.tab("Pasta recipes", "bbc.co.uk")
        DecisionsStub.answer("asked-after.test", DecisionsStub.chances(Self.pair([
            "Hotels in Lisbon|Lisbon trip": 0.8, "Hotels in Lisbon|Flights to Lisbon": 0.9, "Pasta recipes|Lisbon trip": 0.1,
        ])))
        let picks = try await Self.decider("asked-after.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [hotel, pasta]))
        #expect(picks[hotel.id] == .group(group.id))
        #expect(picks[pasta.id] == AIGroupPick.none)
        let asked = DecisionsStub.seen("asked-after.test").map { DecisionsStub.asked($0.body) }
        #expect(asked.count == 3)
        #expect(asked.filter { $0.questions.keys.contains("folder1") }.map(\.tab).sorted() == ["Hotels in Lisbon", "Pasta recipes"])
        #expect(asked.filter { $0.questions.keys.contains("folder1tab1") }.map(\.tab) == ["Hotels in Lisbon"])
        #expect(asked.allSatisfy { !($0.questions.keys.contains("folder1") && $0.questions.keys.contains("folder1tab1")) })
    }

    @Test func twoNewTabsJoinOnlyWhenBothWaysSayYes() async throws {
        let one = Self.tab("SwiftUI Layout protocol", "developer.apple.com")
        let two = Self.tab("Custom layouts in SwiftUI", "swiftwithmajid.com")
        DecisionsStub.answer("both-ways.test", DecisionsStub.chances(Self.pair([
            "SwiftUI Layout protocol|Custom layouts in SwiftUI": 0.92, "Custom layouts in SwiftUI|SwiftUI Layout protocol": 0.55,
        ])))
        var picks = try await Self.decider("both-ways.test").decide(AIGroupAsk(groups: [], loose: [], fresh: [one, two]))
        #expect(picks[one.id] == AIGroupPick.none)
        #expect(picks[two.id] == AIGroupPick.none)
        #expect(DecisionsStub.seen("both-ways.test").count == 2)
        DecisionsStub.answer("both-yes.test", DecisionsStub.chances(Self.pair([
            "SwiftUI Layout protocol|Custom layouts in SwiftUI": 0.92, "Custom layouts in SwiftUI|SwiftUI Layout protocol": 0.85,
        ])))
        picks = try await Self.decider("both-yes.test").decide(AIGroupAsk(groups: [], loose: [], fresh: [one, two]))
        #expect(picks[one.id] == .tab(two.id))
        #expect(picks[two.id] == .tab(one.id))
    }

    static func together(_ picks: [UUID: AIGroupPick], _ tabs: [AIGroupTab]) -> Set<Set<UUID>> {
        var parent = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0.id) })
        func root(_ id: UUID) -> UUID {
            var at = id
            while let up = parent[at], up != at { at = up }
            return at
        }
        for tab in tabs {
            guard case .tab(let other) = picks[tab.id] ?? AIGroupPick.none, parent[other] != nil else { continue }
            parent[root(other)] = root(tab.id)
        }
        return Set(Dictionary(grouping: tabs.map(\.id), by: root).values.map(Set.init))
    }

    @Test func twoPairsThatAllAgreeBecomeOneFolder() async throws {
        let flights = Self.tab("Berlin to Osaka | Google Flights", "google.com")
        let rail = Self.tab("Kansai Area Pass: Osaka, Kyoto, Nara by train", "jr-west.co.jp")
        let hotel = Self.tab("The 10 best hotels in Kyoto", "booking.com")
        let guide = Self.tab("Kyoto Travel Guide", "japan-guide.com")
        let tabs = [flights, rail, hotel, guide]
        func chances(_ weakest: Double) -> @Sendable (String, String) -> Double {
            { tab, about in
                let pair = Set([tab, about])
                if pair == [flights.title, rail.title] || pair == [hotel.title, guide.title] { return 0.92 }
                if pair == [flights.title, hotel.title] { return weakest }
                return 0.86
            }
        }
        DecisionsStub.answer("pairs-agree.test", DecisionsStub.chances(chances(0.77)))
        var picks = try await Self.decider("pairs-agree.test").decide(AIGroupAsk(groups: [], loose: [], fresh: tabs))
        #expect(Self.together(picks, tabs) == [Set(tabs.map(\.id))])
        DecisionsStub.answer("pairs-split.test", DecisionsStub.chances(chances(0.55)))
        picks = try await Self.decider("pairs-split.test").decide(AIGroupAsk(groups: [], loose: [], fresh: tabs))
        #expect(Self.together(picks, tabs) == [[flights.id, rail.id], [hotel.id, guide.id]])
    }

    @Test func aNewPairThatAllFitsAFolderJoinsIt() async throws {
        let review = Self.tab("iPhone 17 review", "theverge.com")
        let store = Self.tab("Buy iPhone 17", "apple.com")
        let group = AIGroupInfo(id: UUID(), name: "iPhone 17", members: [review, store])
        let pixel = Self.tab("Google Pixel 10 review", "theverge.com")
        let versus = Self.tab("iPhone 17 vs Pixel 10 vs Galaxy S26", "tomsguide.com")
        let fits: [String: Double] = [
            "Google Pixel 10 review|iPhone 17 vs Pixel 10 vs Galaxy S26": 0.94, "iPhone 17 vs Pixel 10 vs Galaxy S26|Google Pixel 10 review": 0.95,
            "Google Pixel 10 review|iPhone 17": 0.48, "Google Pixel 10 review|iPhone 17 review": 0.67, "Google Pixel 10 review|Buy iPhone 17": 0.71,
            "iPhone 17 vs Pixel 10 vs Galaxy S26|iPhone 17": 0.85, "iPhone 17 vs Pixel 10 vs Galaxy S26|iPhone 17 review": 0.93,
            "iPhone 17 vs Pixel 10 vs Galaxy S26|Buy iPhone 17": 0.91,
        ]
        DecisionsStub.answer("pair-fits.test", DecisionsStub.chances(Self.pair(fits)))
        var picks = try await Self.decider("pair-fits.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [pixel, versus]))
        #expect(picks[pixel.id] == .group(group.id))
        #expect(picks[versus.id] == .group(group.id))
        var short = fits
        short["Google Pixel 10 review|Buy iPhone 17"] = 0.55
        short["Google Pixel 10 review|iPhone 17 review"] = 0.5
        DecisionsStub.answer("pair-short.test", DecisionsStub.chances(Self.pair(short)))
        picks = try await Self.decider("pair-short.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [pixel, versus]))
        #expect(picks[pixel.id] == .tab(versus.id))
    }

    @Test func aTabInNoFolderIsAskedBackBeforeTheyPair() async throws {
        let weather = Self.tab("Wetter München: 14-Tage-Vorhersage - wetter.com", "wetter.com")
        let venues = Self.tab("Die 12 schönsten Hochzeitslocations rund um München", "hochzeitsportal24.de")
        let bank = Self.tab("Online-Banking Login - Sparkasse", "sparkasse.de")
        DecisionsStub.answer("asked-back.test", DecisionsStub.chances(Self.pair([
            "Die 12 schönsten Hochzeitslocations rund um München|Wetter München: 14-Tage-Vorhersage - wetter.com": 0.74,
            "Wetter München: 14-Tage-Vorhersage - wetter.com|Die 12 schönsten Hochzeitslocations rund um München": 0.52,
        ])))
        var picks = try await Self.decider("asked-back.test").decide(AIGroupAsk(groups: [], loose: [weather, bank], fresh: [venues]))
        #expect(picks[venues.id] == AIGroupPick.none)
        let asked = DecisionsStub.seen("asked-back.test").map { DecisionsStub.asked($0.body) }
        #expect(asked.count == 2)
        #expect(asked.contains { $0.tab == weather.title && $0.questions == ["tab1": venues.title] })
        #expect(!asked.contains { $0.tab == bank.title })
        DecisionsStub.answer("agrees-back.test", DecisionsStub.chances(Self.pair([
            "Die 12 schönsten Hochzeitslocations rund um München|Wetter München: 14-Tage-Vorhersage - wetter.com": 0.74,
            "Wetter München: 14-Tage-Vorhersage - wetter.com|Die 12 schönsten Hochzeitslocations rund um München": 0.7,
        ])))
        picks = try await Self.decider("agrees-back.test").decide(AIGroupAsk(groups: [], loose: [weather, bank], fresh: [venues]))
        #expect(picks[venues.id] == .tab(weather.id))
    }

    @Test func aChainThroughATabBreaksAtItsWeakestLink() async throws {
        let loose = Self.tab("Porto", "wikipedia.org")
        let wine = Self.tab("Port wine cellars tour in Porto", "getyourguide.com")
        let football = Self.tab("FC Porto fixtures", "fcporto.pt")
        DecisionsStub.answer("chain.test", DecisionsStub.chances(Self.pair([
            "Port wine cellars tour in Porto|Porto": 0.9, "FC Porto fixtures|Porto": 0.82,
            "Porto|Port wine cellars tour in Porto": 0.88, "Porto|FC Porto fixtures": 0.8,
            "Port wine cellars tour in Porto|FC Porto fixtures": 0.05, "FC Porto fixtures|Port wine cellars tour in Porto": 0.05,
        ])))
        let picks = try await Self.decider("chain.test").decide(AIGroupAsk(groups: [], loose: [loose], fresh: [wine, football]))
        #expect(picks[wine.id] == .tab(loose.id))
        #expect(picks[football.id] == AIGroupPick.none)
    }

    @Test func aTabPulledTowardAFolderItDoesNotFitStaysOut() async throws {
        let group = AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [Self.tab("Flights to Lisbon", "skyscanner.net")])
        let hotel = Self.tab("Hotels in Lisbon", "booking.com")
        let fado = Self.tab("Fado music history", "wikipedia.org")
        DecisionsStub.answer("pulled.test", DecisionsStub.chances(Self.pair([
            "Hotels in Lisbon|Lisbon trip": 0.95, "Hotels in Lisbon|Flights to Lisbon": 0.8, "Fado music history|Hotels in Lisbon": 0.81, "Hotels in Lisbon|Fado music history": 0.81,
            "Fado music history|Lisbon trip": 0.1,
        ])))
        let picks = try await Self.decider("pulled.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [hotel, fado]))
        #expect(picks[hotel.id] == .group(group.id))
        #expect(picks[fado.id] == AIGroupPick.none)
    }

    @Test func aFolderNeedsOneMemberThatAgrees() async throws {
        let group = AIGroupInfo(id: UUID(), name: "Hochzeit", members: [Self.tab("Schloss Nymphenburg: Hochzeit feiern", "schloss-nymphenburg.de"),
                                                                       Self.tab("Hochzeit auf der Alm", "daskranzbach.de")])
        let weather = Self.tab("Wetter München: 14-Tage-Vorhersage", "wetter.com")
        DecisionsStub.answer("member-veto.test", DecisionsStub.chances(Self.pair([
            "Wetter München: 14-Tage-Vorhersage|Hochzeit": 0.64, "Wetter München: 14-Tage-Vorhersage|Schloss Nymphenburg: Hochzeit feiern": 0.37,
            "Wetter München: 14-Tage-Vorhersage|Hochzeit auf der Alm": 0.35,
        ])))
        var picks = try await Self.decider("member-veto.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [weather]))
        #expect(picks[weather.id] == AIGroupPick.none)
        let asked = DecisionsStub.asked(try #require(DecisionsStub.seen("member-veto.test").first).body)
        #expect(asked.questions == ["folder1": "Hochzeit", "folder1tab1": "Schloss Nymphenburg: Hochzeit feiern", "folder1tab2": "Hochzeit auf der Alm"])
        let venue = Self.tab("Die 12 schönsten Hochzeitslocations rund um München", "hochzeitsportal24.de")
        DecisionsStub.answer("member-agrees.test", DecisionsStub.chances(Self.pair([
            "Die 12 schönsten Hochzeitslocations rund um München|Hochzeit": 0.73,
            "Die 12 schönsten Hochzeitslocations rund um München|Hochzeit auf der Alm": 0.62,
        ])))
        picks = try await Self.decider("member-agrees.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [venue]))
        #expect(picks[venue.id] == .group(group.id))
        let chat = Self.tab("general (Channel) - Hochzeit - Slack", "app.slack.com")
        DecisionsStub.answer("member-short.test", DecisionsStub.chances(Self.pair([
            "general (Channel) - Hochzeit - Slack|Hochzeit": 0.6, "general (Channel) - Hochzeit - Slack|Hochzeit auf der Alm": 0.53,
        ])))
        picks = try await Self.decider("member-short.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [chat]))
        #expect(picks[chat.id] == AIGroupPick.none)
    }

    @Test func oneChannelIsAskedOnlyWhenBothHaveAnAuthor() async throws {
        let entropy = Self.tab("The Most Misunderstood Concept in Physics - YouTube", "youtube.com", "/watch", query: "v=DxL2", by: "Veritasium")
        let light = Self.tab("Why No One Has Measured The Speed Of Light - YouTube", "youtube.com", "/watch", query: "v=pTn6", by: "Veritasium")
        let pizza = Self.tab("How to Make Neapolitan Pizza Dough at Home - YouTube", "youtube.com", "/watch")
        DecisionsStub.answer("channel.test") { _, body in
            let found = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            var answers: [String: Any] = [:]
            for id in (found["questions"] as? [String: Any] ?? [:]).keys {
                answers[id] = ["type": "noul", "noul": id.hasSuffix("by") ? 0.93 : 0.2]
            }
            return DecisionsStub.Reply(body: DecisionsStub.nouls(answers))
        }
        let picks = try await Self.decider("channel.test").decide(AIGroupAsk(groups: [], loose: [light, pizza], fresh: [entropy]))
        #expect(picks[entropy.id] == .tab(light.id))
        let asked = DecisionsStub.asked(try #require(DecisionsStub.seen("channel.test").first).body)
        #expect(Set(asked.questions.keys) == ["tab1", "tab1by", "tab2"])
        let sent = String(decoding: try #require(DecisionsStub.seen("channel.test").first).body, as: UTF8.self)
        #expect(sent.contains("\"by\":\"Veritasium\""))
        #expect(!sent.contains("v=") && !sent.contains("/watch"))
    }

    @Test func aTabThatAgreesWithTwoOfAFolderJoinsIt() async throws {
        let entropy = Self.tab("The Most Misunderstood Concept in Physics", "youtube.com", by: "Veritasium")
        let light = Self.tab("Why No One Has Measured The Speed Of Light", "youtube.com", by: "Veritasium")
        let math = Self.tab("The Man Who Almost Broke Math", "youtube.com", by: "Veritasium")
        let group = AIGroupInfo(id: UUID(), name: "Veritasium", members: [entropy, light])
        DecisionsStub.answer("two-agree.test") { _, body in
            let found = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            var answers: [String: Any] = [:]
            for id in (found["questions"] as? [String: Any] ?? [:]).keys {
                answers[id] = ["type": "noul", "noul": id == "folder1" ? 0.3 : id == "folder1tab1by" ? 0.9 : id == "folder1tab2by" ? 0.85 : 0.2]
            }
            return DecisionsStub.Reply(body: DecisionsStub.nouls(answers))
        }
        var picks = try await Self.decider("two-agree.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [math]))
        #expect(picks[math.id] == .group(group.id))
        DecisionsStub.answer("one-agrees.test") { _, body in
            let found = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            var answers: [String: Any] = [:]
            for id in (found["questions"] as? [String: Any] ?? [:]).keys {
                answers[id] = ["type": "noul", "noul": id == "folder1" ? 0.3 : id == "folder1tab1by" ? 0.9 : 0.2]
            }
            return DecisionsStub.Reply(body: DecisionsStub.nouls(answers))
        }
        picks = try await Self.decider("one-agrees.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [math]))
        #expect(picks[math.id] == AIGroupPick.none)
    }

    @Test func aRefusedFolderIsNeverOfferedOrPicked() async throws {
        let fresh = Self.tab("Hotels in Lisbon", "booking.com", "/city/pt/lisbon.html")
        let loose = Self.tab("Lisbon tram 28", "visitlisboa.com")
        let group = AIGroupInfo(id: UUID(), name: "Lisbon trip", members: [Self.tab("Flights to Lisbon", "skyscanner.net")],
                                refused: [fresh.key])
        DecisionsStub.answer("refused.test", DecisionsStub.chances { _, _ in 0.99 })
        var picks = try await Self.decider("refused.test").decide(AIGroupAsk(groups: [group], loose: [], fresh: [fresh]))
        #expect(picks[fresh.id] == AIGroupPick.none)
        #expect(DecisionsStub.seen("refused.test").isEmpty)
        picks = try await Self.decider("refused.test").decide(AIGroupAsk(groups: [group], loose: [loose], fresh: [fresh]))
        #expect(picks[fresh.id] == .tab(loose.id))
        let asked = DecisionsStub.asked(try #require(DecisionsStub.seen("refused.test").first).body)
        #expect(asked.questions == ["tab1": "Lisbon tram 28"])
    }

    @Test func aRefusalCountsAsNo() async throws {
        let fresh = Self.tab("Heat pump rebates", "energystar.gov")
        let loose = Self.tab("Heat pump sizing", "energy.gov")
        DecisionsStub.answer("refusal.test") { _, body in
            let answers = DecisionsStub.asked(body).questions.keys.reduce(into: [String: Any]()) { $0[$1] = ["type": "refusal"] }
            return DecisionsStub.Reply(body: DecisionsStub.nouls(answers))
        }
        let picks = try await Self.decider("refusal.test").decide(AIGroupAsk(groups: [], loose: [loose], fresh: [fresh]))
        #expect(picks[fresh.id] == AIGroupPick.none)
    }

    @Test(arguments: [
        "{\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}",
        "{\"answers\":{\"tab1\":{\"type\":\"noul\",\"noul\":\"high\"}}}",
        "{\"answers\":{\"tab1\":{\"type\":\"noul\",\"noul\":1.4}}}",
        "{\"answers\":{\"tab1\":{\"type\":\"noul\",\"noul\":true}}}",
        "{\"answers\":{\"tab1\":{\"type\":\"choice\",\"choice\":\"yes\"}}}",
        "{\"answers\":{}}",
        "not json",
    ])
    func aMalformedAnswerFails(body: String) async throws {
        let host = "malformed-\(abs(body.hashValue)).test"
        DecisionsStub.answer(host) { _, _ in DecisionsStub.Reply(body: Data(body.utf8)) }
        let ask = AIGroupAsk(groups: [], loose: [Self.tab("One", "a.com")], fresh: [Self.tab("Two", "b.com")])
        await #expect(throws: OpenRouterTrouble.nonsense) {
            _ = try await Self.decider(host).decide(ask)
        }
    }

    @Test func wholeNumbersAreProbabilities() {
        let said = OpenRouterDecider.read(Data("{\"answers\":{\"tab1\":{\"type\":\"noul\",\"noul\":1},\"tab2\":{\"type\":\"noul\",\"noul\":0}}}".utf8),
                                          asked: ["tab1", "tab2"])
        #expect(said?.yes == ["tab1": 1, "tab2": 0])
        #expect(said?.cost == nil)
        #expect(OpenRouterDecider.read(DecisionsStub.nouls(["tab1": ["type": "noul", "noul": 0.5]]), asked: ["tab1"])?.cost == 0.0000421)
    }

    @Test(arguments: [
        (401, OpenRouterTrouble.refused),
        (402, OpenRouterTrouble.noCredit),
        (403, OpenRouterTrouble.refused),
        (404, OpenRouterTrouble.gone),
        (400, OpenRouterTrouble.nonsense),
        (429, OpenRouterTrouble.busy),
        (500, OpenRouterTrouble.down),
        (503, OpenRouterTrouble.down),
        (524, OpenRouterTrouble.down),
    ])
    func aRefusedRequestSaysWhyWithoutTheKey(status: Int, expected: OpenRouterTrouble) async throws {
        let host = "status-\(status).test"
        DecisionsStub.answer(host, DecisionsStub.failing(status))
        let ask = AIGroupAsk(groups: [], loose: [Self.tab("One", "a.com")], fresh: [Self.tab("Two", "b.com")])
        do {
            _ = try await Self.decider(host).decide(ask)
            Issue.record("no error for \(status)")
        } catch let error as OpenRouterTrouble {
            #expect(error == expected)
            #expect(!(error.errorDescription ?? "").contains("test-key"))
            #expect(!(error.errorDescription ?? "").contains(";"))
        }
    }

    @Test(arguments: [
        (URLError.Code.timedOut, ProviderError.failed("OpenRouter took too long")),
        (URLError.Code.notConnectedToInternet, ProviderError.failed("Can't reach OpenRouter")),
        (URLError.Code.cannotFindHost, ProviderError.failed("Can't reach OpenRouter")),
        (URLError.Code.cancelled, ProviderError.cancelled),
    ])
    func aBrokenConnectionSaysWhy(code: URLError.Code, expected: ProviderError) async throws {
        let host = "network-\(code.rawValue).test"
        DecisionsStub.answer(host) { _, _ in DecisionsStub.Reply(failure: URLError(code)) }
        let ask = AIGroupAsk(groups: [], loose: [Self.tab("One", "a.com")], fresh: [Self.tab("Two", "b.com")])
        await #expect(throws: expected) {
            _ = try await Self.decider(host).decide(ask)
        }
    }

    @Test func aTestRunNeverReachesOpenRouter() async throws {
        DecisionsStub.answer("openrouter.ai", DecisionsStub.chances { _, _ in 0.99 })
        let decider = OpenRouterDecider(key: Self.key, model: OpenRouterDecider.jev, session: DecisionsStub.session)
        #expect(decider.endpoint.absoluteString == "https://openrouter.ai/api/alpha/decisions")
        let ask = AIGroupAsk(groups: [], loose: [Self.tab("One", "a.com")], fresh: [Self.tab("Two", "b.com")])
        await #expect(throws: ProviderError.refused("A test run never calls a real model")) {
            _ = try await decider.decide(ask)
        }
        #expect(DecisionsStub.seen("openrouter.ai").isEmpty)
    }

    @Test func noKeyNoRequest() async throws {
        DecisionsStub.answer("nokey.test", DecisionsStub.chances { _, _ in 0.99 })
        let decider = OpenRouterDecider(key: " ", model: OpenRouterDecider.jev, base: URL(string: "https://nokey.test/api")!,
                                        session: DecisionsStub.session)
        let ask = AIGroupAsk(groups: [], loose: [Self.tab("One", "a.com")], fresh: [Self.tab("Two", "b.com")])
        await #expect(throws: ProviderError.refused("There's no OpenRouter key")) {
            _ = try await decider.decide(ask)
        }
        #expect(DecisionsStub.seen("nokey.test").isEmpty)
    }

    @Test func aTabWithNothingToJoinCostsNothing() async throws {
        DecisionsStub.answer("alone.test", DecisionsStub.chances { _, _ in 0.99 })
        let fresh = Self.tab("Alone", "a.com")
        let picks = try await Self.decider("alone.test").decide(AIGroupAsk(groups: [], loose: [], fresh: [fresh]))
        #expect(picks == [fresh.id: AIGroupPick.none])
        #expect(DecisionsStub.seen("alone.test").isEmpty)
    }

    @Test func aLongAskStaysInTheShortMode() throws {
        let long = String(repeating: "Lisbon apartment listing with a long title ", count: 3)
        let groups = (1...18).map { index in
            AIGroupInfo(id: UUID(), name: "Folder \(index)", members: (1...6).map { Self.tab("\(long)\(index)-\($0)", "site\($0).com") })
        }
        let ask = AIGroupAsk(groups: groups, loose: (1...15).map { Self.tab("Loose \($0)", "loose.com") },
                             fresh: (1...8).map { Self.tab("Fresh \($0)", "fresh.com") })
        let made = Self.decider("long.test").requests(ask)
        #expect(made.count == 8)
        for request in made {
            #expect(try OpenRouterDecider.encoded(request.body).count <= OpenRouterDecider.longest)
            let shown = try #require(request.body.questions["folder1"]?.instructions.folder?.tabs.count)
            let paired = request.asked.keys.filter { $0.hasPrefix("folder1tab") }.count
            #expect(shown < 6)
            #expect(paired <= shown)
            #expect(request.asked.count == 18 * (1 + paired) + 15 + 7)
        }
        let short = Self.decider("long.test").requests(AIGroupAsk(groups: Array(groups.prefix(2)), loose: [], fresh: [Self.tab("Fresh", "fresh.com")]))
        #expect(short.first?.body.questions["folder1"]?.instructions.folder?.tabs.count == 6)
    }

    @Test func thresholdsLiveInOnePlace() {
        #expect(OpenRouterDecider.Thresholds.standard(for: "typesafe/jev-1.14") == .jev)
        #expect(OpenRouterDecider.Thresholds.standard(for: "~typesafe/jev-latest") == .jev)
        #expect(OpenRouterDecider.Thresholds.standard(for: "openai/gpt-6-luna-decisions") == .unmeasured)
        #expect(OpenRouterDecider.Thresholds.jev == OpenRouterDecider.Thresholds(yes: 0.6, no: 0.5))
        #expect(OpenRouterDecider.Thresholds.unmeasured.yes > OpenRouterDecider.Thresholds.jev.yes)
        let decider = OpenRouterDecider(key: Self.key, model: OpenRouterDecider.jev)
        #expect(decider.thresholds == .jev)
        #expect(decider.base == OpenRouterDecider.home)
        #expect(OpenRouterDecider.home.absoluteString == "https://openrouter.ai/api")
        #expect(OpenRouterClient.real.absoluteString == "https://openrouter.ai/api/v1")
        #expect(OpenRouterDecider.jev == "~typesafe/jev-latest")
        #expect(decider.local == false)
        #expect(decider.batch == 8)
    }

    @Test func theEvalCanMoveTheBar() {
        #expect(OpenRouterBench([:]) == nil)
        #expect(OpenRouterBench(["key": ""]) == nil)
        let bench = OpenRouterBench(["key": Self.key, "yes": 0.65, "namer": "fake", "model": "~typesafe/jev-latest", "base": "http://127.0.0.1:9/api"])
        #expect(bench?.decider.thresholds == OpenRouterDecider.Thresholds(yes: 0.65, no: 0.5))
        #expect(bench?.decider.model == "~typesafe/jev-latest")
        #expect(bench?.decider.endpoint.absoluteString == "http://127.0.0.1:9/api/alpha/decisions")
        #expect(bench?.said["namer"] as? String == "fake")
        #expect(!(bench?.said.values.contains { "\($0)".contains("test-key") } ?? true))
    }
}

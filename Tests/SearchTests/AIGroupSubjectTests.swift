import AppKit
import Testing
@testable import Search

final class SubjectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []

    var asked: [String] { lock.withLock { seen } }

    func note(_ tab: AIGroupTab) {
        lock.withLock { seen.append(tab.title) }
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AIGroupSubjectTests {
    private func tab(_ title: String, _ address: String) -> AIGroupTab {
        AIGroupTab(id: UUID(), title: title, url: URL(string: address))!
    }

    private func about(_ table: [UUID: AIGroupSubject], log: SubjectLog = SubjectLog())
        -> @Sendable (AIGroupTab) async throws -> AIGroupSubject? {
        { tab in
            log.note(tab)
            return table[tab.id]
        }
    }

    @Test func aSubjectKeepsTheThingAndThePlaceButNotTheKindOfPage() {
        let flights = AIGroupSubject(subject: "Flights to Lisbon", city: "Lisbon, Portugal")
        let oslo = AIGroupSubject(subject: "Flight booking", city: "none")
        let rome = AIGroupSubject(subject: "buying a hotel room", city: "Rome")

        #expect(flights.words == ["lisbon", "portugal"])
        #expect(flights.line == "Flights to Lisbon, in Lisbon, Portugal")
        #expect(oslo.words.isEmpty)
        #expect(oslo.line == "Flight booking")
        #expect(rome.words == ["room", "rome"])
    }

    @Test func oneSubjectIsFoundAcrossSitesByItsWordsOrTheOtherTabsTitle() {
        let flights = tab("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights")
        let airline = tab("TAP Air Portugal: manage your booking", "https://www.flytap.com/manage-booking")
        let loft = tab("Alfama loft with river view - Airbnb", "https://www.airbnb.com/rooms/1")
        let rome = tab("Hotel Artemide, Rome", "https://www.hotelartemide.it/")
        let search = AIGroupSubject(subject: "flight search", city: "Berlin")
        let booking = AIGroupSubject(subject: "manage booking", city: "Lisbon")
        let trip = AIGroupSubject(subject: "trip to Lisbon", city: "Lisbon")
        let hotel = AIGroupSubject(subject: "Hotel booking", city: "Rome")

        #expect(AIGroupSubject.shared(flights, search, loft, trip) == ["lisbon"])
        #expect(AIGroupSubject.shared(airline, booking, loft, trip) == ["lisbon"])
        #expect(AIGroupSubject.shared(flights, search, rome, hotel).isEmpty)
        #expect(AIGroupSubject.shared(flights, nil, rome, nil).isEmpty)
    }

    @Test func subjectsOnOneSiteAreNoEvidence() {
        let shop = tab("Zalando – Schuhe und Mode online kaufen", "https://www.zalando.de/")
        let sneaker = tab("Nike Air Max 90 – Sneaker low – white - Zalando.de", "https://www.zalando.de/nike-air-max-90.html")
        let shoes = AIGroupSubject(subject: "buying shoes and sneakers", city: "Berlin")
        let pair = AIGroupSubject(subject: "buying sneakers", city: "Berlin")

        #expect(AIGroupSubject.shared(shop, shoes, sneaker, pair).isEmpty)
    }

    @Test func tabsThatShareNoWordButOneSubjectArePutToTheModelInBothOrders() async throws {
        let flights = tab("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights")
        let airline = tab("TAP Air Portugal: manage your booking", "https://www.flytap.com/manage-booking")
        let rome = tab("Hotel Artemide, Rome", "https://www.hotelartemide.it/")
        let table = [flights.id: AIGroupSubject(subject: "Flights to Lisbon", city: "Lisbon, Portugal"),
                     airline.id: AIGroupSubject(subject: "TAP Air Portugal booking", city: "Portugal"),
                     rome.id: AIGroupSubject(subject: "Hotel Artemide", city: "Rome")]
        let log = JudgeLog()
        let sorter = AIGroupSorter(judge: { one, two in
            log.note(one, two)
            return true
        }, belongs: nil, subject: about(table))

        let picks = try await sorter.decide(AIGroupAsk(groups: [], loose: [flights, rome], fresh: [airline]))

        #expect(picks == [airline.id: .tab(flights.id)])
        #expect(log.asked == ["TAP Air Portugal: manage your booking | Berlin to Lisbon | Google Flights",
                              "Berlin to Lisbon | Google Flights | TAP Air Portugal: manage your booking"])
    }

    @Test func aPairFoundBySubjectIsJudgedWithItsSubjectsAndAPairWithAWordAsBefore() async throws {
        let flights = tab("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights")
        let airline = tab("TAP Air Portugal: manage your booking", "https://www.flytap.com/manage-booking")
        let hotels = tab("The 10 best hotels in Lisbon - Booking.com", "https://www.booking.com/city/pt/lisbon.html")
        let table = [flights.id: AIGroupSubject(subject: "flight search", city: "Lisbon"),
                     airline.id: AIGroupSubject(subject: "manage booking", city: "Lisbon"),
                     hotels.id: AIGroupSubject(subject: "hotels", city: "Lisbon")]
        let judged = JudgeLog()
        let meant = SubjectLog()
        let sorter = AIGroupSorter(judge: { one, two in
            judged.note(one, two)
            return true
        }, belongs: nil, subject: about(table), meant: { one, mine, two, theirs in
            meant.note(AIGroupTab(id: one.id, title: "\(one.title) (\(mine.line)) | \(two.title) (\(theirs.line))", host: one.host, path: one.path))
            return true
        })

        let byMeaning = try await sorter.decide(AIGroupAsk(groups: [], loose: [flights], fresh: [airline]))
        let byWord = try await sorter.decide(AIGroupAsk(groups: [], loose: [flights], fresh: [hotels]))

        #expect(byMeaning == [airline.id: .tab(flights.id)])
        #expect(byWord == [hotels.id: .tab(flights.id)])
        #expect(meant.asked == [
            "TAP Air Portugal: manage your booking (manage booking, in Lisbon) | Berlin to Lisbon | Google Flights (flight search, in Lisbon)",
            "Berlin to Lisbon | Google Flights (flight search, in Lisbon) | TAP Air Portugal: manage your booking (manage booking, in Lisbon)",
        ])
        #expect(judged.asked == ["The 10 best hotels in Lisbon - Booking.com | Berlin to Lisbon | Google Flights",
                                 "Berlin to Lisbon | Google Flights | The 10 best hotels in Lisbon - Booking.com"])
    }

    @Test func oneSubjectStillNeedsTheModelToAgreeBothWays() async throws {
        let flights = tab("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights")
        let airline = tab("TAP Air Portugal: manage your booking", "https://www.flytap.com/manage-booking")
        let table = [flights.id: AIGroupSubject(subject: "Flights to Lisbon", city: "Portugal"),
                     airline.id: AIGroupSubject(subject: "TAP Air Portugal booking", city: "Portugal")]
        let oneWay = AIGroupSorter(judge: { one, _ in one.id == airline.id }, belongs: nil, subject: about(table))

        let picks = try await oneWay.decide(AIGroupAsk(groups: [], loose: [flights], fresh: [airline]))

        #expect(picks == [airline.id: .none])
    }

    @Test func aShopsFrontPageAndOneOfItsProductsAreNotOneSubject() {
        let home = tab("IKEA Deutschland – Möbel, Deko & Inspiration", "https://www.ikea.com/de/de/")
        let shelf = tab("BILLY Bücherregal, weiß, 80x28x202 cm - IKEA Deutschland", "https://www.ikea.com/de/de/p/billy-00263850/")

        #expect(AIGroupEvidence.shared(home, shelf).isEmpty)
    }

    @Test func subjectsThatShareOnlyAKindOfPageAreNeverPutToTheModel() async throws {
        let rome = tab("Hotel Artemide, Rome", "https://www.hotelartemide.it/")
        let oslo = tab("Oslo to Tromsø | Norwegian", "https://www.norwegian.com/oslo-tromso")
        let table = [rome.id: AIGroupSubject(subject: "Hotel booking", city: "Rome"),
                     oslo.id: AIGroupSubject(subject: "Flight booking", city: "Tromsø")]
        let log = JudgeLog()
        let sorter = AIGroupSorter(judge: { one, two in
            log.note(one, two)
            return true
        }, belongs: nil, subject: about(table))

        let picks = try await sorter.decide(AIGroupAsk(groups: [], loose: [rome], fresh: [oslo]))

        #expect(picks == [oslo.id: .none])
        #expect(log.asked.isEmpty)
    }

    @Test func withoutASubjectTabsThatShareNoWordNeverMeetTheModel() async throws {
        let flights = tab("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights")
        let airline = tab("TAP Air Portugal: manage your booking", "https://www.flytap.com/manage-booking")
        let log = JudgeLog()
        let sorter = AIGroupSorter(judge: { one, two in
            log.note(one, two)
            return true
        }, belongs: nil, subject: about([:]))

        let picks = try await sorter.decide(AIGroupAsk(groups: [], loose: [flights], fresh: [airline]))

        #expect(picks == [airline.id: .none])
        #expect(log.asked.isEmpty)
    }

    @Test func aTabAboutAFoldersSubjectJoinsItWithoutASharedWord() async throws {
        let flights = tab("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights")
        let flat = tab("Alfama loft with river view - Airbnb", "https://www.airbnb.com/rooms/1")
        let tram = tab("Tram 28: route, stops and tips", "https://www.visitlisboa.com/tram-28")
        let hotel = tab("The 10 best hotels in Oslo, Norway", "https://www.booking.com/city/no/oslo.html")
        let table = [flights.id: AIGroupSubject(subject: "Flights to Lisbon", city: "Lisbon"),
                     flat.id: AIGroupSubject(subject: "Alfama loft", city: "Lisbon"),
                     tram.id: AIGroupSubject(subject: "Tram 28", city: "Lisbon"),
                     hotel.id: AIGroupSubject(subject: "Hotels", city: "Oslo")]
        let folder = AIGroupInfo(id: UUID(), name: "Lisbon Trip", members: [flights, flat])
        let log = JudgeLog()
        let sorter = AIGroupSorter(judge: { one, two in
            log.note(one, two)
            return true
        }, belongs: nil, subject: about(table))
        let refusing = AIGroupSorter(judge: { _, _ in false }, belongs: nil, subject: about(table))

        let joined = try await sorter.decide(AIGroupAsk(groups: [folder], loose: [], fresh: [tram, hotel]))
        let refused = try await refusing.decide(AIGroupAsk(groups: [folder], loose: [], fresh: [tram]))

        #expect(joined == [tram.id: .group(folder.id), hotel.id: .none])
        #expect(refused == [tram.id: .none])
        #expect(!log.asked.contains { $0.contains("Oslo") })
    }

    @Test func freshTabsAreDescribedFirstAndEachTabOnce() async throws {
        let fresh = tab("Tram 28: route, stops and tips", "https://www.visitlisboa.com/tram-28")
        let loose = (0..<30).map { tab("Loose tab \($0)", "https://loose.example/\($0)") }
        let log = SubjectLog()
        let sorter = AIGroupSorter(judge: { _, _ in false }, belongs: nil, subject: about([:], log: log))

        _ = try await sorter.decide(AIGroupAsk(groups: [], loose: loose + [loose[29]], fresh: [fresh]))

        #expect(log.asked.first == "Tram 28: route, stops and tips")
        #expect(log.asked.count == 1 + AIGroupSorter.described)
        #expect(Set(log.asked).count == log.asked.count)
        #expect(log.asked.dropFirst().first == "Loose tab 29")
    }

    @Test func subjectsAlreadyKnownCostNoAskAndLeaveRoomForTheRest() async throws {
        let fresh = tab("Tram 28: route, stops and tips", "https://www.visitlisboa.com/tram-28")
        let members = (0..<6).map { tab("Member \($0)", "https://member.example/\($0)") }
        let loose = (0..<3).map { tab("Loose tab \($0)", "https://loose.example/\($0)") }
        let folder = AIGroupInfo(id: UUID(), name: "Folder", members: members)
        let known = Dictionary(uniqueKeysWithValues: members.map { ($0.id, AIGroupSubject(subject: $0.title, city: "none")) })
        let log = SubjectLog()
        let sorter = AIGroupSorter(judge: { _, _ in false }, belongs: nil, subject: about([:], log: log),
                                   recalled: { known[$0.id] })

        _ = try await sorter.decide(AIGroupAsk(groups: [folder], loose: loose, fresh: [fresh]))

        #expect(log.asked == ["Tram 28: route, stops and tips", "Loose tab 2", "Loose tab 1", "Loose tab 0"])
    }

    @Test func aSubjectIsKeptPerAddressAndTitleAndForgotten() {
        let flights = tab("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights")
        let same = AIGroupTab(id: UUID(), title: flights.title, host: flights.host, path: flights.path, query: flights.query)
        var renamed = same
        renamed.title = "Berlin to Porto | Google Flights"
        let flat = tab("Alfama loft with river view - Airbnb", "https://www.airbnb.com/rooms/1")
        defer { AIGroupSubjects.forget() }

        AIGroupSubjects.remember(AIGroupSubject(subject: "Flights to Lisbon", city: "Lisbon"), for: flights)
        AIGroupSubjects.remember(AIGroupSubject(subject: "Alfama loft", city: "Lisbon"), for: flat)

        #expect(AIGroupSubjects.known(same)?.subject == "Flights to Lisbon")
        #expect(AIGroupSubjects.known(renamed) == nil)
        #expect(AIGroupSubjects.near(same, flat))
        AIGroupSubjects.forget()
        #expect(!AIGroupSubjects.near(same, flat))
    }

    @Test func aLooseTabAboutAFolderThatJustFormedIsGatheredWithoutASharedWord() async {
        keepSetting(AIGroups.shared, \.on, AIGroups.onKey)
        keepSetting(AIGroups.shared, \.emoji, AIGroups.emojiKey)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        let pages = [("Alfama loft with river view - Airbnb", "https://www.airbnb.com/rooms/1"),
                     ("Sourdough starter in seven days", "https://bread.example/starter"),
                     ("Berlin to Lisbon | Google Flights", "https://www.google.com/travel/flights"),
                     ("TAP Air Portugal: manage your booking", "https://www.flytap.com/manage-booking")]
        let places = ["Alfama loft": "Lisbon", "Sourdough starter": "none", "Berlin to Lisbon": "Lisbon", "TAP Air Portugal": "Lisbon"]
        for (title, address) in pages {
            let place = places.first { title.hasPrefix($0.key) }?.value ?? "none"
            AIGroupSubjects.remember(AIGroupSubject(subject: title, city: place), for: tab(title, address))
        }
        let groups = AIGroups.shared
        groups.on = true
        groups.emoji = false
        groups.quiet = 0.05
        groups.gap = 0
        groups.timeout = 5
        defer {
            AIGroupSubjects.forget()
            AIGroups.shared.standIn = nil
            AIGroups.shared.quiet = 1.5
            AIGroups.shared.gap = 4
            AIGroups.shared.timeout = 25
            AIGroups.shared.stop = 8
            browser.closeAll()
        }
        let engine = SortingEngine(local: false, picking: { ask in
            var out: [UUID: AIGroupPick] = [:]
            let trip = ask.fresh.filter { AIGroupSubjects.known($0)?.city == "Lisbon" }
            if let group = ask.groups.first {
                for tab in trip { out[tab.id] = .group(group.id) }
            } else if trip.count == 2 {
                out[trip[0].id] = .tab(trip[1].id)
            }
            return out
        })
        groups.standIn = engine
        for (index, page) in pages.prefix(2).enumerated() {
            if index > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: page.1)!, title: page.0)
            browser.tabs.last?.cameBack = false
        }
        let grouper = groups.grouper(for: browser)
        await grouper.regroup()
        #expect(browser.tabGroups.isEmpty)

        for page in pages.suffix(2) {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: page.1)!, title: page.0)
            browser.tabs.last?.cameBack = false
            grouper.landed(browser.tabs.last!)
        }
        try? await Task.sleep(for: .seconds(0.6))

        let group = browser.tabGroups.first { $0.ai }
        #expect(browser.tabs(in: group?.id).map(\.title).sorted()
                == ["Alfama loft with river view - Airbnb", "Berlin to Lisbon | Google Flights", "TAP Air Portugal: manage your booking"])
        #expect(browser.tabs.first { $0.title.hasPrefix("Sourdough") }?.groupID == nil)
        #expect(engine.asks.last?.fresh.map(\.title) == ["Alfama loft with river view - Airbnb"])
    }
}

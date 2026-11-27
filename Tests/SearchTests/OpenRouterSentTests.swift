import Foundation
import Testing
@testable import Search

@Suite struct OpenRouterSentTests {
    private func tab(_ title: String, _ address: String) -> AIGroupTab {
        AIGroupTab(id: UUID(), title: title, url: URL(string: address), by: "Authormark")!
    }

    private var ferries: AIGroupTab { tab("Ferry times to Zeltwind", "https://ferries.example/routes/pathmark-one?q=querymark") }
    private var hotels: AIGroupTab { tab("Harbour hotels in Zeltwind", "https://hotels.example/pathmark-two?ref=querymark") }
    private var weather: AIGroupTab { tab("Zeltwind weather this week", "https://weather.example/pathmark-three?x=querymark") }
    private var folder: AIGroupInfo {
        AIGroupInfo(id: UUID(), name: "Foldermark Trip", members: [
            tab("Zeltwind museum tickets", "https://museum.example/pathmark-four?y=querymark"),
            tab("Zeltwind old town walk", "https://walks.example/pathmark-five?z=querymark"),
        ])
    }

    private func chain(_ host: String) -> AIGroupDeciderChain {
        DecisionsStub.answer(host) { _, body in
            let found = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            var answers: [String: Any] = [:]
            for id in (found["questions"] as? [String: Any] ?? [:]).keys {
                answers[id] = ["type": "noul", "noul": id == "folder1" ? 0.4 : 0.7]
            }
            return DecisionsStub.Reply(body: DecisionsStub.nouls(answers))
        }
        let remote = OpenRouterDecider(key: OpenRouterDeciderTests.key, model: OpenRouterDecider.jev,
                                       base: URL(string: "https://\(host)/api")!, session: DecisionsStub.session)
        return AIGroupDeciderChain(remote: remote, mac: nil, report: { _ in })
    }

    private func bodies(_ host: String) -> [String] {
        DecisionsStub.seen(host).map { String(decoding: $0.body, as: UTF8.self) }
    }

    private func carriesNoAddressAuthorOrTabSearch(_ sent: String) {
        for kept in ["pathmark", "querymark", "Authormark", "\"by\"", "/routes", "ref="] {
            #expect(!sent.contains(kept), "\(kept) in \(sent)")
        }
    }

    @Test func theSortingAskCarriesTitlesSitesAndFolderNamesOnly() async throws {
        let host = "sent-sorting.test"
        let (fresh, other, loose, group) = (ferries, hotels, weather, folder)

        _ = try await chain(host).decide(AIGroupAsk(groups: [group], loose: [loose], fresh: [fresh, other]))

        let sent = bodies(host)
        let main = sent.filter { $0.contains("\"folder1\":") }
        #expect(main.count == 2)
        for body in main {
            for title in [fresh.title, other.title, loose.title] + group.members.map(\.title) { #expect(body.contains(title)) }
            for site in ["ferries.example", "hotels.example", "weather.example", "museum.example", "walks.example"] { #expect(body.contains(site)) }
            #expect(body.contains("\"name\":\"Foldermark Trip\""))
        }
        #expect(sent.allSatisfy { !$0.contains("Searchmark") })
        sent.forEach(carriesNoAddressAuthorOrTabSearch)
    }

    @Test func theMemberAndConfirmingAsksCarryTitlesAndSitesOnly() async throws {
        let host = "sent-members.test"
        let (fresh, other, loose, group) = (ferries, hotels, weather, folder)

        _ = try await chain(host).decide(AIGroupAsk(groups: [group], loose: [loose], fresh: [fresh, other]))

        let sent = bodies(host)
        let members = sent.filter { $0.contains("\"folder1tab1\":") && !$0.contains("\"folder1\":") }
        let confirming = sent.filter { $0.contains("\"state\":{\"tab\":{\"title\":\"\(loose.title)\"") }
        #expect(members.count == 2)
        #expect(confirming.count == 1)
        for body in members {
            #expect(body.contains(group.members[0].title) && body.contains("museum.example"))
            #expect(!body.contains("Foldermark"))
        }
        for body in confirming {
            #expect(body.contains(fresh.title) && body.contains("ferries.example") && body.contains(other.title))
        }
        (members + confirming).forEach(carriesNoAddressAuthorOrTabSearch)
    }

    @Test func theFitsAskCarriesTheTabTheFolderNameAndItsTabsTitlesAndSitesOnly() async throws {
        let host = "sent-fits.test"
        let (fresh, group) = (ferries, folder)

        _ = try await chain(host).fits(fresh, in: group)

        let sent = bodies(host)
        #expect(sent.count == 1)
        let body = try #require(sent.first)
        for title in [fresh.title] + group.members.map(\.title) { #expect(body.contains(title)) }
        for site in ["ferries.example", "museum.example", "walks.example"] { #expect(body.contains(site)) }
        #expect(body.contains("\"name\":\"Foldermark Trip\""))
        carriesNoAddressAuthorOrTabSearch(body)
    }

    @Test func theNamingRequestCarriesTitlesSitesTheSearchAndTheFolderNameOnly() async throws {
        let stub = OpenRouterStub.naming("Zeltwind Trip")
        let namer = OpenRouterNamer(key: "sk-or-good-1", client: stub.client, report: { _ in })
        let tabs = [ferries, hotels, weather]

        _ = try await namer.name(AIGroupNameAsk(tabs: tabs, current: "Foldermark Trip", currentEmoji: nil, emoji: false, query: "Searchmark ferries"))

        let body = try #require(stub.requests.first?.1)
        let sent = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        for title in tabs.map(\.title) { #expect(sent.contains(title)) }
        for site in ["ferries.example", "hotels.example", "weather.example"] { #expect(sent.contains(site)) }
        #expect(sent.contains("Searched for: Searchmark ferries"))
        #expect(sent.contains("Current name: Foldermark Trip"))
        for kept in ["pathmark", "querymark", "Authormark", "/routes", "ref="] {
            #expect(!sent.contains(kept), "\(kept) in \(sent)")
        }
    }
}

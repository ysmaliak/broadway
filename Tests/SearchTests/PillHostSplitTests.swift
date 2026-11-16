import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PillHostSplitTests {
    private let suffixes: Set<String> = ["com", "uk", "co.uk", "io", "github.io", "jp", "de"]
    private var isSuffix: (String) -> Bool { { suffixes.contains($0) } }

    private func split(_ host: String) -> (lead: String, name: String) {
        Hosts.split(host, isSuffix: isSuffix)
    }

    @Test func subdomainsComeApartFromTheSite() {
        #expect(split("acme.okta.com") == ("acme.", "okta.com"))
        #expect(split("mail.example.com") == ("mail.", "example.com"))
        #expect(split("docs.example.co.uk") == ("docs.", "example.co.uk"))
        #expect(split("a.b.example.co.uk") == ("a.b.", "example.co.uk"))
        #expect(split("a.very.long.subdomain.chain.example.com") == ("a.very.long.subdomain.chain.", "example.com"))
    }

    @Test func aBareSiteHasNoLead() {
        #expect(split("example.com") == ("", "example.com"))
        #expect(split("example.co.uk") == ("", "example.co.uk"))
        #expect(split("acme.github.io") == ("", "acme.github.io"))
        #expect(split("b.acme.github.io") == ("b.", "acme.github.io"))
    }

    @Test func addressesAndLocalNamesStayWhole() {
        #expect(split("localhost") == ("", "localhost"))
        #expect(split("app.localhost") == ("", "app.localhost"))
        #expect(split("192.168.1.20") == ("", "192.168.1.20"))
        #expect(split("[::1]") == ("", "[::1]"))
        #expect(split("intranet.corp") == ("", "intranet.corp"))
        #expect(split("") == ("", ""))
        #expect(split("example.com.") == ("", "example.com."))
        #expect(Hosts.split("acme.okta.com", isSuffix: nil) == ("", "acme.okta.com"))
    }

    @Test func internationalNamesSplitByTheirLabels() {
        #expect(split("news.xn--wgv71a119e.jp") == ("news.", "xn--wgv71a119e.jp"))
        #expect(split("news.日本語.jp") == ("news.", "日本語.jp"))
        #expect(split("shop.xn--bcher-kva.de") == ("shop.", "xn--bcher-kva.de"))
    }

    @Test func theTwoPartsAlwaysMakeTheHost() {
        for host in ["acme.okta.com", "a.b.example.co.uk", "example.com", "acme.github.io", "localhost", "192.168.1.20", "news.日本語.jp", "x.y"] {
            let parts = split(host)
            #expect(parts.lead + parts.name == host)
        }
    }

    @Test func thePillDrawsTheLeadInTheSecondaryColour() throws {
        if AtRest.systemSuffix == nil { try Test.cancel("The Mac's public suffix list isn't reachable here") }
        let words = AddressWordsView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        words.host = .some("acme.okta.com")
        let runs = words.label.runs
        #expect(runs.map(\.text) == ["acme.", "okta.com"])
        #expect(runs.first?.color === KitColor.muted)
        #expect(runs.last?.color == nil)
        #expect(words.label.color === KitColor.title)
        #expect(words.label.accessibilityValue() as? String == "acme.okta.com")

        words.host = .some("example.com")
        #expect(words.label.runs.map(\.text) == ["example.com"])
        #expect(words.label.runs.first?.color == nil)

        words.host = .some(nil)
        #expect(words.label.color === KitColor.muted)
    }

    @Test func theFullAddressStaysOneColour() throws {
        if AtRest.systemSuffix == nil { try Test.cancel("The Mac's public suffix list isn't reachable here") }
        let words = AddressWordsView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
        words.whole = true
        words.host = .some("acme.okta.com")
        #expect(words.label.runs.map(\.text) == ["acme.okta.com"])
        words.whole = false
        #expect(words.label.runs.map(\.text) == ["acme.", "okta.com"])
        words.whole = true
        #expect(words.label.runs.count == 1)
    }

    @Test func theLeadGivesWayBeforeTheSite() throws {
        if AtRest.systemSuffix == nil { try Test.cancel("The Mac's public suffix list isn't reachable here") }
        let words = AddressWordsView(frame: NSRect(x: 0, y: 0, width: 260, height: 30))
        words.host = .some("a.very.long.subdomain.chain.example.com")
        words.fadeAt = 190
        words.layoutSubtreeIfNeeded()
        let runs = words.label.runs.map(\.text)
        #expect(runs.count == 2)
        #expect(runs.last == "example.com")
        #expect(runs.first?.hasPrefix("…") == true)
        #expect(runs.first?.hasSuffix("chain.") == true)
        #expect(runs.first?.dropFirst().first != ".")
        #expect(words.label.frame.maxX <= 190 - SideLook.pillFade + 0.5)
        #expect(words.label.accessibilityValue() as? String == "a.very.long.subdomain.chain.example.com")

        words.fadeAt = 110
        words.layoutSubtreeIfNeeded()
        #expect(words.label.runs.map(\.text) == ["…", "example.com"])

        words.fadeAt = nil
        words.frame.size.width = 600
        words.layoutSubtreeIfNeeded()
        #expect(words.label.runs.map(\.text) == ["a.very.long.subdomain.chain.", "example.com"])
    }

    @Test func theLeadIsCutAtWholeLabels() {
        let split = (lead: "a.very.long.subdomain.chain.", name: "example.com")
        #expect(AddressWordsView.lead(split, room: 1000) == split.lead)
        #expect(AddressWordsView.lead(split, room: 0) == "…")
        for room in stride(from: CGFloat(80), through: 260, by: 10) {
            let lead = AddressWordsView.lead(split, room: room)
            #expect(lead == split.lead || lead == "…" || (lead.hasPrefix("…") && split.lead.hasSuffix(lead.dropFirst()) && lead.dropFirst().first != "."))
        }
    }
}

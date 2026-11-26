import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct WithoutWWWTests {
    @Test func onlyOneLeadingWWWLabelIsDroppedWhateverItsCase() {
        #expect(Address.withoutWWW("www.example.com") == "example.com")
        #expect(Address.withoutWWW("WWW.example.com") == "example.com")
        #expect(Address.withoutWWW("www.www.example.com") == "www.example.com")
        #expect(Address.withoutWWW("wwwexample.com") == "wwwexample.com")
        #expect(Address.withoutWWW("www.") == "")
        #expect(Address.withoutWWW("shop.example") == "shop.example")
    }

    @Test func everySiteNameDropsTheSameWWW() {
        #expect(Vault.host(of: "www.example.com") == "example.com")
        #expect(Vault.host(of: "https://WWW.Example.com/login") == "example.com")
        #expect(Vault.host(of: "wwwexample.com") == "wwwexample.com")
        #expect(AgentSignInMatch.bare("[WWW.example.com]") == "example.com")
        #expect(AgentSignInMatch.bare("www.www.example.com") == "www.example.com")
        #expect(SiteCard.site(URL(string: "https://www.example.com/a")!) == "example.com")
        #expect(SiteCard.site(URL(string: "https://wwwexample.com/")!) == "wwwexample.com")
        #expect(Shared.curtain.host(of: URL(string: "https://www.shop.example/a")) == "shop.example")
        #expect(SavedAlready.sameSite("www.example.com", "EXAMPLE.com", registrable: { $0 }))
        #expect(!SavedAlready.sameSite("wwwexample.com", "example.com", registrable: { $0 }))
        #expect(ApplePasswords.belongs(["https://www.example.com"], to: "example.com", wide: false))
        #expect(SiteSearch.sameSite("https://www.shop.example/find?q=%s", "www.shop.example"))
    }
}

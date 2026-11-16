import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SiteSearchListTests {
    private let added: [(String, String)] = [
        ("pplx", "Perplexity"), ("img", "Google Images"), ("tr", "Google Translate"), ("hn", "Hacker News"),
        ("ph", "Product Hunt"), ("gmail", "Gmail"), ("drive", "Google Drive"), ("li", "LinkedIn"), ("npm", "npm"),
        ("music", "Apple Music"), ("twitch", "Twitch"), ("netflix", "Netflix"), ("pin", "Pinterest"), ("dribbble", "Dribbble"),
    ]

    @Test func everyNewSiteIsNamedByItsAlias() {
        let sites = SiteSearch.builtIn

        for (alias, name) in added {
            let site = sites.first { $0.name == name }
            #expect(site?.aliases.contains(alias) == true, "\(name)")
            #expect(SiteSearch.exact(alias)?.name == (SiteSearch.spaceAliases.contains(alias) ? name : nil), "\(alias)")
            #expect(SiteSearch.match(alias)?.name == name, "\(alias)")
        }
    }

    @Test func everyBuiltInSiteHasItsOwnHost() {
        let hosts = SiteSearch.builtIn.map(\.host)

        let unique = Set(hosts)

        #expect(unique.count == hosts.count)
    }

    @Test func noAliasNamesTwoSites() {
        let aliases = SiteSearch.builtIn.flatMap(\.aliases)

        let unique = Set(aliases)

        #expect(unique.count == aliases.count)
    }

    @Test func everyBuiltInAddressIsOneAKeywordWouldAccept() {
        let sites = SiteSearch.builtIn

        for site in sites {
            #expect(Keyword.accepts(site.template), "\(site.name)")
            #expect(site.url(for: "two words") != nil, "\(site.name)")
        }
    }

    @Test func theWordsGoWhereEachSiteSearches() {
        let wanted: [String: String] = [
            "Google Images": "https://www.google.com/search?udm=2&q=cats",
            "Hacker News": "https://hn.algolia.com/?q=cats",
            "Gmail": "https://mail.google.com/mail/u/0/#search/cats",
            "Dribbble": "https://dribbble.com/search/cats",
            "Apple Music": "https://music.apple.com/search?term=cats",
        ]

        for (name, address) in wanted {
            let site = SiteSearch.builtIn.first { $0.name == name }
            #expect(site?.url(for: "cats")?.absoluteString == address, "\(name)")
        }
    }
}

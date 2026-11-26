import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct FilterListsTests {
    private func convert(_ text: String, strict: Bool = false) -> FilterLists.Converted {
        FilterLists.convert([FilterLists.Input(text: text, strict: strict)])
    }

    private func matches(_ filter: String, _ url: String) throws -> Bool {
        let regex = try NSRegularExpression(pattern: filter, options: .caseInsensitive)
        return regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    @Test @MainActor func commentsAndHeadersAreNotCounted() {
        let text = "[Adblock Plus 2.0]\n! Title: EasyList\n\n"

        let out = convert(text)

        #expect(out.lines == 0)
        #expect(out.ruleCount == 0)
    }

    @Test @MainActor func hostAnchorMatchesTheHostAndItsSubdomainsOnly() throws {
        let out = convert("||ads.example.com^")

        let filter = try #require(out.blocks.first?.filter)

        #expect(try matches(filter, "https://ads.example.com/x.js"))
        #expect(try matches(filter, "http://a.ads.example.com:8080/x.js"))
        #expect(try !matches(filter, "https://notads.example.com/x.js"))
        #expect(try !matches(filter, "https://ads.example.com.evil.org/x.js"))
        #expect(try !matches(filter, "https://example.org/ads.example.com/"))
    }

    @Test @MainActor func trailingSeparatorAfterAPathAlsoMatchesTheEndOfTheAddress() throws {
        let out = convert("/banner/ad^")

        let filters = out.blocks.map(\.filter)

        #expect(filters.count == 2)
        #expect(try filters.contains { try matches($0, "https://x.org/banner/ad") })
        #expect(try filters.contains { try matches($0, "https://x.org/banner/ad?x=1") })
        #expect(try !filters.contains { try matches($0, "https://x.org/banner/adult") })
    }

    @Test @MainActor func wildcardsAndMetacharactersAreTranslated() throws {
        let out = convert("/ads/*.gif?size=|")

        let filter = try #require(out.blocks.first?.filter)

        #expect(try matches(filter, "https://x.org/ads/a/b.gif?size="))
        #expect(try !matches(filter, "https://x.org/ads/a/bXgif?size="))
        #expect(try !matches(filter, "https://x.org/ads/a/b.gif?size=2"))
    }

    @Test @MainActor func optionsBecomeTriggers() throws {
        let out = convert("||t.example^$script,image,third-party,domain=a.com|b.org,match-case")

        let rule = try #require(out.blocks.first)

        #expect(rule.types == ["image", "script"])
        #expect(rule.load == "third-party")
        #expect(rule.only == ["*a.com", "*b.org"])
        #expect(rule.caseSensitive)
    }

    @Test @MainActor func negatedTypesListEveryOtherType() throws {
        let out = convert("||t.example^$~image")

        let rule = try #require(out.blocks.first)

        #expect(!rule.types.contains("image"))
        #expect(rule.types.contains("script"))
    }

    @Test @MainActor func linesWebKitCannotExpressAreSkippedAndCounted() {
        let lines = [
            "||a.example^$csp=script-src 'self'", "||b.example^$redirect=noop.js", "/ad[0-9]+\\.js/",
            "||c.example^$removeparam=utm", "||d.example^$domain=a.com|~b.a.com",
            "example.com##+js(aopr, ads)", "example.com#?#div:has-text(Sponsored)", "##div:style(color: red)",
            "example.com##^script:has-text(ads)", "||e.example^$to=a.com", "ab",
        ]

        let out = convert(lines.joined(separator: "\n"))

        #expect(out.ruleCount == 0)
        #expect(out.skipped == lines.count)
    }

    @Test @MainActor func badfilterCancelsTheFilterItNames() {
        let text = "||gone.example^$image\n||gone.example^$image,badfilter\n||stays.example^"

        let out = convert(text)

        #expect(out.blocks.count == 1)
        #expect(out.blocks[0].filter.contains("stays"))
    }

    @Test @MainActor func exceptionsGoIntoEveryBlockPart() {
        let blocks = (0..<2500).map { "||host\($0).example^" }.joined(separator: "\n")
        let out = convert(blocks + "\n@@||host1.example^$script")

        let parts = FilterLists.parts(out, limit: 1000)

        #expect(parts.count > 2)
        for part in parts {
            #expect(part.rules.count <= 1100)
            #expect(part.rules.filter { $0.action == .ignore && $0.filter.contains("host1") }.count == 1)
            #expect(part.rules.last?.action == .ignore)
        }
    }

    @Test @MainActor func anOpenedPageIsNeverBlockedButABadwarePageIs() throws {
        let out = convert("||plain.example^")
        let bad = convert("||bad.example^", strict: true)

        let part = try #require(FilterLists.parts(out).first)
        let badPart = try #require(FilterLists.parts(bad).first)

        #expect(part.tail.contains { $0.topFrameOnly && $0.action == .ignore })
        #expect(bad.blocks.count == 0)
        #expect(bad.pageBlocks.count == 1)
        #expect(!badPart.rules.contains { $0.topFrameOnly })
    }

    @Test @MainActor func pageExceptionsReachEveryPart() throws {
        let out = convert("||ads.example^\n##.ad\nnews.example##.promo\n@@||friend.example^$document")

        let parts = FilterLists.parts(out)

        #expect(parts.count == 3)
        for part in parts {
            #expect(part.rules.last?.only == ["*friend.example"])
            #expect(part.rules.last?.action == .ignore)
        }
    }

    @Test @MainActor func selectorsAreBatchedAndExcusesHonoured() throws {
        let text = """
        ##.one
        ##.two
        ##.excused
        ##.everywhere
        site.example#@#.excused
        #@#.everywhere
        a.example,b.example##.pair
        ~c.example##.notc
        """

        let out = convert(text)

        let plain = try #require(out.genericHides.first { $0.except.isEmpty })
        #expect(plain.action == .hide(".one, .two"))
        let excused = try #require(out.genericHides.first { !$0.except.isEmpty })
        #expect(excused.action == .hide(".excused"))
        #expect(excused.except == ["*site.example"])
        #expect(out.siteHides.contains { $0.only == ["*a.example", "*b.example"] && $0.action == .hide(".pair") })
        #expect(out.siteHides.contains { $0.except == ["*c.example"] && $0.action == .hide(".notc") })
    }

    @Test @MainActor func selectorsThatCouldEscapeTheirRuleAreRefused() {
        #expect(!FilterLists.usable(".a { color: red }"))
        #expect(!FilterLists.usable("div[class"))
        #expect(!FilterLists.usable("div:contains(ad)"))
        #expect(FilterLists.usable("div[class^=\"ad-\"] > a:not(.keep)"))
        #expect(FilterLists.usable("div:has(> a)"))
        #expect(!FilterLists.usable("div:has(> div:has(> .ad))"))
    }

    @Test @MainActor func idnDomainsBecomePunycodeOrAreRefused() throws {
        let out = convert("пример.рф##.ad")

        let site = try #require(out.siteHides.first?.only.first)

        #expect(site.allSatisfy { $0.isASCII })
    }

    @MainActor
    @Test func convertedPartsCompileInWebKit() async throws {
        let text = """
        ||ads.example^
        /banner/ad^$image
        ||t.example^$script,third-party,domain=a.com
        ##.ad-slot
        news.example##.promo
        @@||ads.example/ok.js$script
        @@||friend.example^$document
        @@||friend2.example^$generichide
        """
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))

        let parts = FilterLists.parts(convert(text))

        #expect(!parts.isEmpty)
        for (index, part) in parts.enumerated() {
            let json = try #require(FilterLists.encoded(part.rules))
            let list = try await store.compileContentRuleList(forIdentifier: "fixture-\(index)", encodedContentRuleList: json)
            #expect(list != nil)
        }
    }

    @Test @MainActor func popupFiltersBlockWindowsAndCompile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("filters-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))

        let out = convert("||popads.example^$popup,third-party")
        let rule = try #require(out.blocks.first)
        let json = try #require(FilterLists.encoded(FilterLists.parts(out).first?.rules ?? []))

        #expect(rule.types == ["popup"])
        #expect(try matches(rule.filter, "https://popads.example/go"))
        let list = try await store.compileContentRuleList(forIdentifier: "popup-fixture", encodedContentRuleList: json)
        #expect(list != nil)
    }

    @Test @MainActor func refreshIsDueAfterAWeek() {
        let now = Date()

        #expect(ShieldLists.due(checked: nil, now: now))
        #expect(!ShieldLists.due(checked: now.addingTimeInterval(-3600), now: now))
        #expect(ShieldLists.due(checked: now.addingTimeInterval(-8 * 24 * 3600), now: now))
    }

    @Test @MainActor func theCookieNoticeListIsFetchedFromItsPublisherWithTheOthers() throws {
        let source = try #require(FilterLists.sources.first { $0.id == "easylist-cookie" })

        #expect(source.name == "EasyList Cookie List")
        #expect(source.address == "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt")
        #expect(!source.strict)
        #expect(ShieldLists.shared.sources.contains(source))
    }

    @Test @MainActor func aListNeverFetchedIsDueRightAway() {
        let now = Date()

        #expect(ShieldLists.due(checked: now.addingTimeInterval(-3600), missing: true, now: now))
        #expect(!ShieldLists.due(checked: now.addingTimeInterval(-3600), missing: false, now: now))
    }

    @Test @MainActor func cookieNoticeRulesBecomeHidingAndBlockingRules() throws {
        let out = convert("""
        ###onetrust-consent-sdk
        cnn.com,apnews.com##.onetrust-pc-dark-filter
        /js/onetrust/*
        """)

        let generic = try #require(out.genericHides.first)
        let site = try #require(out.siteHides.first)
        let block = try #require(out.blocks.first)

        #expect(generic.action == .hide("#onetrust-consent-sdk"))
        #expect(site.action == .hide(".onetrust-pc-dark-filter"))
        #expect(site.only == ["*apnews.com", "*cnn.com"])
        #expect(try matches(block.filter, "https://www.example.com/js/onetrust/otSDKStub.js"))
    }

    @Test @MainActor func onlyTextThatLooksLikeAListIsKept() {
        #expect(!ShieldLists.usable(Data("<!doctype html><html>captive portal</html>".utf8)))
        #expect(!ShieldLists.usable(Data("{\"error\": \"rate limited\"}".utf8)))
        #expect(!ShieldLists.usable(Data("x".utf8)))
        #expect(ShieldLists.usable(Data("[Adblock Plus 2.0]\n! Title: EasyList\n||a.example^\n".utf8)))
    }

    @Test @MainActor func aListThatCannotBeFetchedLeavesTroubleThatSaysTheBuiltInListIsInUse() async {
        let lists = ShieldLists.shared
        let before = lists.sources
        lists.sources = [FilterLists.Source(id: "unreachable-fixture", name: "Example List", address: "")]

        await lists.refresh(force: true)
        let trouble = lists.trouble
        let fallingBack = lists.fallingBack

        lists.sources = []
        await lists.refresh(force: true)
        lists.sources = before
        #expect(trouble == "Couldn't fetch Example List")
        #expect(fallingBack == Shield.shared.downloaded.isEmpty)
        #expect(lists.trouble == nil)
        #expect(!lists.fallingBack)
    }

    @Test @MainActor func twoRefreshesAtOnceBothWaitForTheSameFetch() async {
        let lists = ShieldLists.shared
        let before = lists.sources
        lists.sources = [FilterLists.Source(id: "unreachable-fixture", name: "Example List", address: "")]

        async let first: Void = lists.refresh(force: true)
        async let second: Void = lists.refresh(force: true)
        _ = await (first, second)
        let trouble = lists.trouble
        let busy = lists.busy

        lists.sources = []
        await lists.refresh(force: true)
        lists.sources = before
        #expect(trouble == "Couldn't fetch Example List")
        #expect(!busy)
    }

    @MainActor
    @Test func threeReloadsWithinTwentySecondsOfferToAllowAds() {
        let now = Date()

        #expect(Shield.offersAfter([now.addingTimeInterval(-19), now.addingTimeInterval(-9), now], now: now))
        #expect(!Shield.offersAfter([now.addingTimeInterval(-21), now.addingTimeInterval(-9), now], now: now))
        #expect(!Shield.offersAfter([now.addingTimeInterval(-1), now], now: now))
    }
}

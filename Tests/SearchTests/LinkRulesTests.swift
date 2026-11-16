import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class LinkRulesTests {
    private var browser: Browser!
    private var window: NSWindow!
    private var first = UUID()
    private var second = UUID()
    private let store = LinkRules.shared

    init() async throws {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.usesTabGroups, "tabs.groups")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesSpaces = true
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        first = browser.spaceID
        browser.addSpace(named: "Work")
        second = browser.spaceID
        browser.switchSpace(to: first)
        store.replaceAll([])
        LinkArrivals.arrived = [:]
        LinkArrivals.offered = []
    }

    private func tearDown() async {
        store.replaceAll([])
        browser.showLinkNotice(nil)
        if let space = browser.spaces.first(where: { $0.id == second }) {
            browser.spaces.removeAll { $0.id == space.id }
            Spaces.write(browser.spaces)
        }
        window.contentView = nil
        window.close()
        browser.closeAll()
        browser = nil
    }

    private func page(_ text: String) -> Tab {
        browser.newTab()
        let tab = browser.active!
        tab.restore(url: URL(string: text)!, title: "Here")
        return tab
    }

    private func outside(_ text: String, from source: IncomingLink.Source = .unknownApp) -> IncomingLink {
        IncomingLink(url: URL(string: text)!, source: source)
    }

    private func parked(_ space: UUID) -> [String] {
        (browser.parked[space]?.tabs ?? []).compactMap { $0.address?.host() }
    }

    @Test func oldSiteRoutesBecomeRulesForOtherAppsInTheSameOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("link-rules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let space = UUID(), window = UUID(), id = UUID()
        let old = """
        [{"id":"\(id.uuidString)","site":"notion.so","target":{"space":{"_0":"\(space.uuidString)"}}},
         {"id":"\(UUID().uuidString)","site":"figma.com","target":{"window":{"_0":"\(window.uuidString)"}}},
         {"id":"\(UUID().uuidString)","site":"linear.app","target":{"window":{}}},
         {"id":"\(UUID().uuidString)","site":"x.com","target":{"peek":{}}}]
        """
        let routes = folder.appendingPathComponent("routes.json")
        let links = folder.appendingPathComponent("links.json")
        try Data(old.utf8).write(to: routes)

        let moved = LinkRules(file: links, old: routes)
        Disk.drain()
        let again = LinkRules(file: links, old: routes)

        #expect(moved.rules.map(\.match) == [.site("notion.so"), .site("figma.com"), .site("linear.app"), .site("x.com")])
        #expect(moved.rules.map(\.target) == [.space(space, folder: nil), .window(window), .window(nil), .peek])
        #expect(moved.rules.allSatisfy { $0.from == .otherApps && $0.on })
        #expect(moved.rules.first?.id == id)
        #expect(FileManager.default.fileExists(atPath: routes.path))
        #expect(FileManager.default.fileExists(atPath: links.path))
        #expect(again.rules == moved.rules)
    }

    @Test func alwaysOpenReplacesASiteRuleAndForgetRemovesIt() {
        store.always("notion.so", to: .peek)

        store.always("notion.so", to: .window(nil))

        #expect(store.rules.map(\.target) == [.window(nil)])
        #expect(store.rules.first?.from == .anywhere)
        store.forget("notion.so")
        #expect(store.rules.isEmpty)
    }

    @Test func aRuleSendsALinkFromAnotherAppToItsSpaceAndSaysSo() throws {
        _ = page("https://example.com")
        let rule = store.add(LinkRule(match: .site("linear.app"), target: .space(second, folder: nil)))

        let landing = Browsers.place(outside("https://linear.app/a", from: .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")),
                                     from: browser)

        #expect(browser.spaceID == second)
        #expect(landing.forward)
        #expect(browser.active?.address?.host() == "linear.app")
        #expect(browser.linkNotice?.text == "Opened in Work by a rule")
        #expect(store.recent.first?.site == "linear.app")
        #expect(store.recent.first?.from == "Slack")
        #expect(store.recent.first?.rule == rule.id)
    }

    @Test func theNoticesUndoPutsTheTabWhereItWouldHaveGone() throws {
        _ = page("https://example.com")
        store.add(LinkRule(match: .site("linear.app"), target: .space(second, folder: nil)))
        let landing = Browsers.place(outside("https://linear.app/a"), from: browser)
        let tab = try #require(landing.tab)
        let undo = try #require(browser.linkNotice?.choices.first { $0.title == "Undo" })

        undo.run()

        #expect(browser.spaceID == first)
        #expect(browser.active?.id == tab.id)
        #expect(browser.linkNotice == nil)
        #expect(!parked(second).contains("linear.app"))
        #expect(LinkArrivals.offered.isEmpty)
    }

    @Test func aBackgroundRuleLeavesYouWhereYouAre() {
        _ = page("https://example.com")
        var rule = LinkRule(match: .site("linear.app"), target: .space(second, folder: nil))
        rule.background = true
        store.add(rule)

        let landing = Browsers.place(outside("https://linear.app/a"), from: browser)

        #expect(browser.spaceID == first)
        #expect(!landing.forward)
        #expect(parked(second).contains("linear.app"))
        #expect(browser.active?.address?.host() == "example.com")
    }

    @Test func noRuleArrivesAsItAlwaysDidAndSaysNothing() {
        browser.newTab()

        let landing = Browsers.place(outside("https://example.com"), from: browser)

        #expect(landing.browser === browser)
        #expect(browser.spaceID == first)
        #expect(browser.peekTab == nil)
        #expect(browser.active?.address?.host() == "example.com")
        #expect(browser.linkNotice == nil)
        #expect(store.recent.isEmpty)
    }

    @Test func aPeekRuleLeavesTheTabYouAreOn() {
        _ = page("https://example.com")
        let count = browser.tabs.count
        store.always("notion.so", to: .peek)

        Browsers.place(outside("https://www.notion.so/page"), from: browser)

        #expect(browser.tabs.count == count)
        #expect(browser.peekTab?.address?.host() == "www.notion.so")
    }

    @Test func aRuleIntoAFolderPutsTheTabInIt() throws {
        browser.prefs.usesTabGroups = true
        _ = page("https://example.com")
        let folder = try #require(browser.newFolder(editing: false, pinned: false))
        store.add(LinkRule(match: .site("linear.app"), target: .space(first, folder: folder)))

        let landing = Browsers.place(outside("https://linear.app/a"), from: browser)

        #expect(landing.tab?.groupID == folder)
        #expect(browser.linkNotice == nil)
    }

    @Test func aCommandClickOnAPageFollowsARuleForPagesInBroadway() {
        let source = page("https://example.com")
        store.add(LinkRule(match: .site("linear.app"), from: .insideBroadway, target: .space(second, folder: nil)))

        let routed = browser.routeClicked(URL(string: "https://linear.app/a")!, foreground: false, from: source)

        guard case .yes = routed else { Issue.record("not routed"); return }
        #expect(browser.spaceID == first)
        #expect(browser.active?.id == source.id)
        #expect(parked(second).contains("linear.app"))
        #expect(browser.linkNotice?.text == "Opened in Work by a rule")
    }

    @Test func linksOnPagesIgnoreRulesForOtherAppsAndPrivateWindowsIgnoreEveryRule() {
        let source = page("https://example.com")
        store.add(LinkRule(match: .site("linear.app"), from: .otherApps, target: .space(second, folder: nil)))
        let hidden = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { hidden.closeAll() }
        hidden.newTab()
        let secret = hidden.active!
        secret.restore(url: URL(string: "https://example.com")!, title: "Secret")
        store.add(LinkRule(match: .site("figma.com"), target: .space(second, folder: nil)))

        let mine = browser.routeClicked(URL(string: "https://linear.app/a")!, foreground: false, from: source)
        let theirs = hidden.routeClicked(URL(string: "https://figma.com/a")!, foreground: false, from: secret)

        guard case .no = mine, case .no = theirs else { Issue.record("routed"); return }
        #expect(parked(second).isEmpty)
    }

    @Test func onlyAClickedLinkToAnotherSiteAskingForAWindowIsRouted() {
        let other = URL(string: "https://linear.app/a")
        let same = URL(string: "https://docs.example.com/a")
        let here = URL(string: "https://example.com/page")

        #expect(Browser.routesNewWindow(clicked: true, navigation: .linkActivated, popup: false, beside: false, shy: false, url: other, page: here))
        #expect(!Browser.routesNewWindow(clicked: true, navigation: .linkActivated, popup: false, beside: false, shy: false, url: same, page: here))
        #expect(!Browser.routesNewWindow(clicked: false, navigation: .linkActivated, popup: false, beside: false, shy: false, url: other, page: here))
        #expect(!Browser.routesNewWindow(clicked: true, navigation: .other, popup: false, beside: false, shy: false, url: other, page: here))
        #expect(!Browser.routesNewWindow(clicked: true, navigation: .linkActivated, popup: true, beside: false, shy: false, url: other, page: here))
        #expect(!Browser.routesNewWindow(clicked: true, navigation: .linkActivated, popup: false, beside: true, shy: false, url: other, page: here))
        #expect(!Browser.routesNewWindow(clicked: true, navigation: .linkActivated, popup: false, beside: false, shy: true, url: other, page: here))
        #expect(!Browser.routesNewWindow(clicked: true, navigation: .linkActivated, popup: false, beside: false, shy: false,
                                         url: URL(string: "about:blank"), page: here))
        #expect(Browser.routesNewWindow(clicked: false, navigation: .other, popup: false, beside: false, shy: false, url: same, page: here,
                                        menu: true))
        #expect(!Browser.routesNewWindow(clicked: true, navigation: .other, popup: false, beside: false, shy: true, url: other, page: here,
                                         menu: true))
    }

    @Test func theChooserPicksARowByItsNumberAndEscapeOpensItHere() throws {
        _ = page("https://example.com")
        let world = Browsers.linkWorld(from: browser)
        let link = outside("https://linear.app/a")
        let chooser = LinkChooser(link: link, url: link.url, browser: browser, world: world, browsers: [])
        let staying = LinkChooser(link: link, url: link.url, browser: browser, world: world, browsers: [])

        let work = try #require(chooser.rows.firstIndex(of: .space(second, name: "Work")))

        staying.key(53, nil)
        let here = browser.active?.address?.host()
        chooser.key(0, "\(work + 1)")

        #expect(staying.done)
        #expect(chooser.done)
        #expect(here == "linear.app")
        #expect(parked(first).contains("linear.app"))
        #expect(browser.spaceID == second)
        #expect(browser.active?.address?.host() == "linear.app")
        #expect(store.recent.count == 1)
        #expect(store.recent.first?.rule == nil)
    }

    @Test func theChoosersArrowsAndReturnAndAlways() {
        var choosing = LinkChoosing(count: 3)

        #expect(choosing.key(125, nil) == .none)
        #expect(choosing.lit == 1)
        #expect(choosing.key(125, nil) == .none)
        #expect(choosing.key(125, nil) == .none)
        #expect(choosing.lit == 2)
        #expect(choosing.key(126, nil) == .none)
        #expect(choosing.key(36, nil) == .pick(1))
        #expect(choosing.key(0, "9") == .none)
        #expect(choosing.key(0, "3") == .pick(2))
        #expect(choosing.key(53, nil) == .here)
        #expect(choosing.key(49, " ") == .flip)
    }

    @Test func choosingAlwaysMakesASiteRule() {
        _ = page("https://example.com")
        let link = outside("https://linear.app/a")
        let chooser = LinkChooser(link: link, url: link.url, browser: browser, world: Browsers.linkWorld(from: browser), browsers: [])
        let work = chooser.rows.firstIndex(of: .space(second, name: "Work"))!

        chooser.always = true
        chooser.finish(work)

        #expect(store.siteRule("linear.app")?.target == .space(second, folder: nil))
    }

    @Test func movingALinksTabByHandOffersARuleOncePerSite() throws {
        _ = page("https://example.com")
        let landing = Browsers.place(outside("https://linear.app/a"), from: browser)
        let tab = try #require(landing.tab)

        browser.move(tab, toSpace: second)

        #expect(browser.linkNotice?.text == "Always open linear.app in Work?")
        try #require(browser.linkNotice?.choices.first { $0.title == "Always" }).run()
        #expect(store.siteRule("linear.app")?.target == .space(second, folder: nil))
        #expect(LinkArrivals.offered.contains("linear.app"))
    }

    @Test func theLinksPageListsEachRuleAsASentence() throws {
        store.add(LinkRule(match: .pattern("github.com/*/pull/*"), from: .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
                           target: .space(second, folder: nil), background: true))
        store.add(LinkRule(match: .regex("(broken"), target: .peek))
        let shell = SettingsShell()
        shell.go(to: .links)
        let view = SettingsPageView(browser: browser, shell: shell)

        view.rebuild()

        let rows = view.kitSubviews(of: SettingsRowView.self)
        let firstRule = try #require(rows.first { $0.rowID == "link.rule.0" })
        let secondRule = try #require(rows.first { $0.rowID == "link.rule.1" })
        #expect(firstRule.title.stringValue == "github.com/*/pull/* → Work")
        #expect(firstRule.detail.stringValue == "From Slack · in the background")
        #expect(secondRule.detail.stringValue == "⚠︎ The expression doesn't read")
        #expect(rows.contains { $0.rowID == "links.open" })
        #expect(rows.contains { $0.rowID == "links.unwrap" })
    }

    @Test func theRulePageSavesWhatYouChange() throws {
        let rule = store.add(LinkRule(match: .site("linear.app"), target: .peek))
        let shell = SettingsShell()
        shell.openLinkRule(rule.id)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.linkDraft.more[rule.id] = true
        view.rebuild()
        let kind = try #require(view.kitSubviews(of: NSPopUpButton.self).first { $0.accessibilityIdentifier() == "settings.link.kind" })
        let target = try #require(view.kitSubviews(of: NSPopUpButton.self).first { $0.accessibilityIdentifier() == "settings.link.target" })

        kind.selectItem(withTitle: "A Pattern with *")
        kind.sendAction(kind.action, to: kind.target)
        target.selectItem(withTitle: "Work")
        target.sendAction(target.action, to: target.target)

        #expect(store.rule(rule.id)?.match == .pattern("linear.app"))
        #expect(store.rule(rule.id)?.target == .space(second, folder: nil))
    }

    @Test func tryingALinkShowsTheStepsInPlainWords() throws {
        store.add(LinkRule(match: .site("linear.app"), target: .space(second, folder: nil)))
        let shell = SettingsShell()
        shell.go(to: .links)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.linkDraft.tried = "https://www.google.com/url?q=https://linear.app/a"

        view.rebuild()

        let result = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "links.try.result" })
        #expect(result.title.stringValue == "Opens in Work")
        #expect(result.detail.stringValue.contains("Unwrapped a Google redirect"))
        #expect(result.detail.stringValue.contains("Matched rule 1: linear.app"))
    }
}

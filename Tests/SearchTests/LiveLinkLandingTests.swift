import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class LiveLinkLandingTests {
    private var browser: Browser!
    private var window: NSWindow!
    private var first = UUID()
    private var second = UUID()
    private let store = LinkRules.shared
    private let base = "http://127.0.0.1:9/acme/rocket/pull/"

    init() async throws {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.usesTabGroups, "tabs.groups")
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        keepSetting(Shared.prefs, \.splitView, "splitView")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesSpaces = true
        browser.prefs.usesTabGroups = true
        browser.prefs.liveFolders = true
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        first = browser.spaceID
        browser.addSpace(named: "Work")
        second = browser.spaceID
        browser.switchSpace(to: first)
        store.replaceAll([])
        store.clearRecent()
        store.set { $0 = LinkSettings() }
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        store.replaceAll([])
        store.clearRecent()
        store.set { $0 = LinkSettings() }
        browser.showLinkNotice(nil)
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        if let space = browser.spaces.first(where: { $0.id == second }) {
            browser.spaces.removeAll { $0.id == space.id }
            Spaces.write(browser.spaces)
        }
        window.contentView = nil
        window.close()
        browser.closeAll()
        browser = nil
    }

    private func pull(_ number: Int, stack: Int? = nil) -> LiveItem {
        LiveItem(key: base + "\(number)", title: "PR \(number)",
                 branch: stack.map { LiveBranch(repository: "acme/rocket", base: "main", head: "b\(number)", stack: $0, position: number) })
    }

    private func folder(_ items: [LiveItem], in space: UUID? = nil, named name: String = "PRs") -> LiveFolder {
        let made = LiveFolders.shared.add(name: name, source: LiveSource(kind: .pullRequests, address: "http://127.0.0.1:9/pulls"),
                                          space: space ?? browser.spaceID)
        LiveFolders.shared.apply(.items(items, nil), to: made.id)
        browser.syncLive()
        return made
    }

    private func page(_ text: String) -> Tab {
        browser.newTab()
        let tab = browser.active!
        tab.restore(url: URL(string: text)!, title: "Here")
        return tab
    }

    private func outside(_ text: String, chooses: Bool = false) -> IncomingLink {
        IncomingLink(url: URL(string: text)!, source: .app(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"), chooses: chooses)
    }

    private func click(_ text: String, on source: Tab, front: Bool = false, in window: Browser? = nil) -> Bool {
        if case .yes(let tab) = (window ?? browser).routeClicked(URL(string: text)!, foreground: front, from: source) {
            #expect(tab == nil)
            return true
        }
        return false
    }

    @Test func aLinkToARowSelectsItAtTheAddressAskedWithoutANewTab() throws {
        _ = page("https://example.com")
        let made = folder([pull(1), pull(2)])
        let before = browser.tabs.count
        let folded = browser.tabGroups.first { $0.id == made.id }?.collapsed

        let landing = Browsers.place(outside(base + "2/files?utm_source=slack#diff-1"), from: browser)

        #expect(folded == true)
        #expect(browser.tabs.count == before)
        #expect(browser.active?.liveKey == base + "2")
        #expect(browser.active?.address?.absoluteString == base + "2/files#diff-1")
        #expect(landing.forward)
        #expect(landing.tab?.id == browser.active?.id)
        #expect(browser.tabGroups.first { $0.id == made.id }?.collapsed == false)
        #expect(browser.linkNotice == nil)
        #expect(store.recent.first?.live == "PRs")
        #expect(store.recent.first?.from == "Slack")
        #expect(store.recent.first?.went == "Shown there")
    }

    @Test func aRowInsideAFoldedStackIsUnfoldedForIt() throws {
        _ = page("https://example.com")
        let made = folder(LiveStacks.arranged([pull(1, stack: 7), pull(2, stack: 7), pull(3, stack: 7)]))
        browser.unfoldFolder(made.id)
        let group = try #require(browser.tabGroups.first { $0.id == made.id })
        let top = try #require(browser.drawnTabs(in: group).first)
        browser.toggleStack(top.id, in: made.id)
        let hidden = try #require(browser.tabGroups.first { $0.id == made.id }).map { browser.visibleTabs(in: $0).map(\.liveKey) }

        Browsers.place(outside(base + "1/commits/abc"), from: browser)

        let now = try #require(browser.tabGroups.first { $0.id == made.id })
        #expect(hidden == [base + "3"])
        #expect(browser.active?.liveKey == base + "1")
        #expect(browser.visibleTabs(in: now).compactMap(\.liveKey) == [base + "3", base + "2", base + "1"])
    }

    @Test func aRowInAnotherSpaceBringsThatSpaceAndSaysSoWithAWayBack() throws {
        let here = page("https://example.com")
        let made = folder([pull(1), pull(2)], in: second)
        let rule = store.add(LinkRule(match: .pattern("127.0.0.1:9/*"), target: .space(first, folder: nil)))

        let landing = Browsers.place(outside(base + "1/files"), from: browser)

        #expect(browser.spaceID == second)
        #expect(landing.forward)
        #expect(browser.active?.liveKey == base + "1")
        #expect(browser.active?.groupID == made.id)
        #expect(browser.active?.address?.absoluteString == base + "1/files")
        #expect(browser.tabs.filter { $0.address?.path().contains("/pull/1") == true }.count == 1)
        #expect(browser.linkNotice?.text == "Shown in PRs")
        #expect(store.recent.first?.rule == nil)
        #expect(store.recent.first?.live == "PRs")
        #expect(store.index(of: rule.id) == 0)

        let back = try #require(browser.linkNotice?.choices.first { $0.title == "Open in New Tab" })
        back.run()

        #expect(browser.spaceID == first)
        #expect(browser.active?.liveKey == nil)
        #expect(browser.active?.address?.absoluteString == base + "1/files")
        #expect(here.address?.absoluteString == "https://example.com")
        #expect(browser.linkNotice == nil)
    }

    @Test func withStackedSpacesTheRowsSpaceIsJumpedToAndUnfolded() throws {
        let previous = browser.prefs.stackedSpaces
        defer {
            browser.prefs.stackedSpaces = previous
            StackedFolds.shared.forget(second)
        }
        browser.prefs.stackedSpaces = true
        StackedFolds.shared.set(second, folded: true)
        _ = page("https://example.com")
        let made = folder([pull(1), pull(2)], in: second)
        let before = browser.stackedScroll.count

        let landing = Browsers.place(outside(base + "2/files"), from: browser)

        #expect(browser.stacked)
        #expect(browser.spaceID == second)
        #expect(!StackedFolds.shared.isFolded(second))
        #expect(browser.stackedScroll == StackedScroll(space: second, count: before + 1))
        #expect(landing.tab?.liveKey == base + "2")
        #expect(browser.active?.groupID == made.id)
        #expect(browser.active?.address?.absoluteString == base + "2/files")
        #expect(browser.tabs.filter { $0.address?.path().contains("/pull/2") == true }.count == 1)
    }

    @Test func aLinkBehindPointsTheRowWithoutSelectingItAndLeavesAnExactPageAlone() throws {
        let here = page("https://example.com")
        let made = folder([pull(1), pull(2)])
        let one = try #require(browser.tabs(in: made.id).first { $0.liveKey == base + "1" })
        let two = try #require(browser.tabs(in: made.id).first { $0.liveKey == base + "2" })
        let before = browser.tabs.count

        Browsers.placeBehind(outside(base + "1"), from: browser)
        Browsers.placeBehind(outside(base + "2/files"), from: browser)

        #expect(browser.tabs.count == before)
        #expect(browser.active?.id == here.id)
        #expect(one.asleep)
        #expect(one.address?.absoluteString == base + "1")
        #expect(!two.asleep)
        #expect(two.address?.absoluteString == base + "2/files")
        #expect(browser.tabGroups.first { $0.id == made.id }?.collapsed == true)
    }

    @Test func aLinkBehindPointsARowInASpaceThatIsNotOnScreenAndStaysWhereYouAre() throws {
        let here = page("https://example.com")
        browser.switchSpace(to: second)
        let made = folder([pull(1), pull(2)])
        browser.switchSpace(to: first)
        let before = browser.tabs.count

        Browsers.placeBehind(outside(base + "2/files"), from: browser)

        let row = try #require(browser.parked[second]?.tabs.first { $0.groupID == made.id && $0.liveKey == base + "2" })
        #expect(browser.spaceID == first)
        #expect(browser.active?.id == here.id)
        #expect(browser.tabs.count == before)
        #expect(row.address?.absoluteString == base + "2/files")
        #expect(browser.linkNotice == nil)
    }

    @Test func aLinkBehindForARowNotMadeYetStillOpens() throws {
        let here = page("https://example.com")
        _ = folder([pull(1)], in: second)
        let before = browser.tabs.count

        Browsers.placeBehind(outside(base + "1/files"), from: browser)

        #expect(browser.spaceID == first)
        #expect(browser.active?.id == here.id)
        #expect(browser.tabs.count == before + 1)
        #expect(browser.tabs.last?.address?.absoluteString == base + "1/files")
        #expect(store.recent.isEmpty)
    }

    @Test func aRowHiddenFromItsFolderIsNoLongerThere() throws {
        _ = page("https://example.com")
        let made = folder([pull(1), pull(2)])
        let one = try #require(browser.tabs(in: made.id).first { $0.liveKey == base + "1" })
        browser.close(one)
        LiveFolders.shared.apply(.items([pull(1), pull(2)], nil), to: made.id)
        browser.syncLive()
        let before = browser.tabs.count

        Browsers.place(outside(base + "1/files"), from: browser)

        #expect(browser.tabs(in: made.id).map(\.liveKey) == [base + "2"])
        #expect(browser.active?.liveKey == nil)
        #expect(browser.active?.address?.absoluteString == base + "1/files")
        #expect(browser.tabs.count == before + 1)
        #expect(store.recent.isEmpty)
    }

    @Test func withLiveFoldersOffALinkOpensTheOrdinaryWay() throws {
        _ = page("https://example.com")
        _ = folder([pull(1)])
        browser.prefs.liveFolders = false
        browser.syncLive()

        Browsers.place(outside(base + "1"), from: browser)

        #expect(browser.active?.liveKey == nil)
        #expect(browser.active?.address?.absoluteString == base + "1")
    }

    @Test func aLinkOpenedBehindOnAPagePointsItsRowAndStaysOnThePage() throws {
        let here = page("https://example.com")
        let made = folder([pull(1), pull(2)])
        let two = try #require(browser.tabs(in: made.id).first { $0.liveKey == base + "2" })
        let before = browser.tabs.count

        let routed = click(base + "2/files#diff-1", on: here)

        #expect(routed)
        #expect(browser.tabs.count == before)
        #expect(browser.active?.id == here.id)
        #expect(two.address?.absoluteString == base + "2/files#diff-1")
        #expect(two.linkedFrom == nil)
        #expect(browser.tabGroups.first { $0.id == made.id }?.collapsed == true)
        #expect(browser.linkNotice?.text == "Opened in its row in PRs")
        #expect(store.recent.first?.from == "A page on example.com")
        #expect(store.recent.first?.live == "PRs")
        #expect(store.recent.first?.went == "Its row goes there in the background")

        let again = try #require(browser.linkNotice?.choices.first { $0.title == "Open in New Tab" })
        again.run()

        let at = try #require(browser.tabs.firstIndex { $0.id == here.id })
        #expect(browser.tabs.count == before + 1)
        #expect(browser.active?.id == here.id)
        #expect(browser.tabs[at + 1].address?.absoluteString == base + "2/files#diff-1")
        #expect(browser.tabs[at + 1].linkedFrom == here.id)
        #expect(browser.tabs[at + 1].liveKey == nil)
        #expect(two.address?.absoluteString == base + "2/files#diff-1")
        #expect(browser.linkNotice == nil)
    }

    @Test func aLinkOpenedInFrontOnAPageSelectsItsRow() throws {
        let here = page("https://example.com")
        let made = folder([pull(1), pull(2)])
        let before = browser.tabs.count
        let earlier = click(base + "2/files", on: here)
        let said = browser.linkNotice?.text

        let routed = click(base + "1/commits/abc", on: here, front: true)

        #expect(earlier)
        #expect(said == "Opened in its row in PRs")
        #expect(routed)
        #expect(browser.tabs.count == before)
        #expect(browser.active?.liveKey == base + "1")
        #expect(browser.active?.address?.absoluteString == base + "1/commits/abc")
        #expect(browser.tabGroups.first { $0.id == made.id }?.collapsed == false)
        #expect(browser.linkNotice == nil)
        #expect(store.recent.first?.went == "Shown there")
    }

    @Test func aLinkOpenedBehindForARowInAnotherSpacePointsItThereAndSaysWhere() throws {
        let here = page("https://example.com")
        browser.switchSpace(to: second)
        let made = folder([pull(1), pull(2)])
        browser.switchSpace(to: first)
        let before = browser.tabs.count

        let routed = click(base + "2/files", on: here)

        let row = try #require(browser.parked[second]?.tabs.first { $0.groupID == made.id && $0.liveKey == base + "2" })
        #expect(routed)
        #expect(browser.spaceID == first)
        #expect(browser.active?.id == here.id)
        #expect(browser.tabs.count == before)
        #expect(row.address?.absoluteString == base + "2/files")
        #expect(browser.linkNotice?.text == "Opened in its row in PRs in Work")
    }

    @Test func aLinkOpenedInFrontForARowInAnotherSpaceGoesThereWithAWayBack() throws {
        let here = page("https://example.com")
        _ = folder([pull(1), pull(2)], in: second)

        let routed = click(base + "1", on: here, front: true)

        #expect(routed)
        #expect(browser.spaceID == second)
        #expect(browser.active?.liveKey == base + "1")
        #expect(browser.linkNotice?.text == "Shown in PRs")

        let back = try #require(browser.linkNotice?.choices.first { $0.title == "Open in New Tab" })
        back.run()

        #expect(browser.spaceID == first)
        #expect(browser.active?.liveKey == nil)
        #expect(browser.active?.address?.absoluteString == base + "1")
        #expect(browser.active?.linkedFrom == here.id)
    }

    @Test func aLinkToTheRowYouAreReadingOrTheOneBesideItIsNotTaken() throws {
        browser.prefs.splitView = true
        let made = folder([pull(1), pull(2)])
        let one = try #require(browser.tabs(in: made.id).first { $0.liveKey == base + "1" })
        let two = try #require(browser.tabs(in: made.id).first { $0.liveKey == base + "2" })
        let other = page("https://example.com")
        browser.select(one)
        let before = browser.tabs.count

        let own = click(base + "1/files", on: one)
        let sibling = click(base + "2/files", on: one)
        browser.pair(other, with: two, onLeft: false)
        let beside = click(base + "2/commits/abc", on: other)

        #expect(!own)
        #expect(sibling)
        #expect(!beside)
        #expect(one.address?.absoluteString == base + "1")
        #expect(two.address?.absoluteString == base + "2/files")
        #expect(browser.tabs.count == before)
    }

    @Test func aPrivateWindowAnAgentsTabAPeekAndTheSwitchOffLeaveALinkAlone() throws {
        let here = page("https://example.com")
        let made = folder([pull(1), pull(2)])
        let one = try #require(browser.tabs(in: made.id).first { $0.liveKey == base + "1" })
        let hidden = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { hidden.closeAll() }
        hidden.newTab()
        let secret = try #require(hidden.active)
        secret.restore(url: URL(string: "https://example.com")!, title: "Secret")
        let helper = page("https://example.org")
        helper.agent = true
        let peeked = browser.makeTab()
        peeked.restore(url: URL(string: "https://example.net")!, title: "Peek")
        defer { peeked.close() }
        browser.select(here)

        let fromPrivate = click(base + "1/files", on: secret, in: hidden)
        let fromAgent = click(base + "1/files", on: helper)
        let fromPeek = click(base + "1/files", on: peeked)
        store.set { $0.goesToLiveRow = false }
        let switchedOff = click(base + "1/files", on: here)
        store.set { $0.goesToLiveRow = true }
        let switchedOn = click(base + "1/files", on: here)

        #expect(!fromPrivate)
        #expect(!fromAgent)
        #expect(!fromPeek)
        #expect(!switchedOff)
        #expect(switchedOn)
        #expect(one.address?.absoluteString == base + "1/files")
    }

    @Test func aLinkOpenedOnAPageForARowNotMadeYetOpensTheOrdinaryWayOrByItsRule() throws {
        let here = page("https://example.com")
        _ = folder([pull(1)], in: second)
        let before = browser.tabs.count

        let plain = click(base + "1/files", on: here)
        store.add(LinkRule(match: .pattern("127.0.0.1:9/*"), from: .insideBroadway, target: .space(second, folder: nil)))
        let ruled = browser.routeClicked(URL(string: base + "1/files")!, foreground: false, from: here)

        #expect(!plain)
        guard case .yes(let tab) = ruled else { Issue.record("the rule did not take it"); return }
        #expect(tab?.liveKey == nil)
        #expect(browser.tabs.count == before)
        #expect(browser.parked[second]?.tabs.contains { $0.liveKey == nil && $0.address?.absoluteString == base + "1/files" } == true)
        #expect(browser.linkNotice?.text == "Opened in Work by a rule")
    }

    @Test func holdingOptionOnALinkFromAnotherAppGoesToTheRowWithNoChooser() throws {
        _ = page("https://example.com")
        _ = folder([pull(1), pull(2)])
        let before = browser.tabs.count

        let landing = Browsers.place(outside(base + "2/files", chooses: true), from: browser)

        #expect(LinkChooser.shown == nil)
        #expect(landing.tab?.liveKey == base + "2")
        #expect(browser.active?.liveKey == base + "2")
        #expect(browser.active?.address?.absoluteString == base + "2/files")
        #expect(browser.tabs.count == before)
        #expect(store.recent.first?.went == "Shown there")
    }
}

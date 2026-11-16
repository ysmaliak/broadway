import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FoldedSignInTests {
    private var browsers: [Browser] = []
    private var made: [UUID] = []
    private let source = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")
    private let sso = LiveSSO(org: "Octo Corp", url: "https://github.com/orgs/octocorp/sso")
    private static let long = "GitHub Pull Requests for Review"

    init() {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "folded-sign-in-\(getpid())", 1)
    }

    private func tearDown() async {
        for id in made { LiveFolders.shared.remove(id) }
        for browser in browsers { browser.closeAll() }
        made = []
        browsers = []
    }

    private func folder(_ name: String) -> UUID {
        let folder = LiveFolders.shared.add(name: name, source: source, space: UUID())
        made.append(folder.id)
        let items = (1...18).map { LiveItem(key: "https://github.com/octocorp/ios/pull/\($0)", title: "Pull \($0)") }
        LiveFolders.shared.apply(.items(items, nil), to: folder.id)
        return folder.id
    }

    private func heading(_ id: UUID, _ name: String, width: CGFloat) -> GroupHeadingView {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let view = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: width, height: GroupHeadingView.height))
        view.count = 18
        view.show(TabGroup(id: id, name: name, collapsed: true, live: true), in: browser)
        settle(view)
        return view
    }

    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
    }

    private func settled(_ view: NSView) async throws {
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func pill(of heading: GroupHeadingView) -> LiveSignInPill? {
        (heading.status as? LiveStatusView)?.pill
    }

    private func expectButton(_ heading: GroupHeadingView, _ said: String) throws {
        let pill = try #require(pill(of: heading), "\(said): no pill")
        let frame = heading.convert(pill.bounds, from: pill)
        #expect(!pill.isHiddenOrHasHiddenAncestor, "\(said): pill hidden")
        #expect(frame.width > 0 && heading.bounds.contains(frame), "\(said): \(frame) outside \(heading.bounds)")
        #expect(frame.minX >= heading.nameHost.frame.maxX, "\(said): \(frame.minX) left of the name's end \(heading.nameHost.frame.maxX)")
        #expect(!heading.showsCount, "\(said): the count shows beside the pill")
        #expect(pill.accessibilityLabel() == "Single sign-on for Octo Corp", "\(said)")
        #expect(pill.toolTip == "Single sign-on for Octo Corp", "\(said)")
    }

    @Test(arguments: [245, 227, 200, 182] as [CGFloat])
    func aFoldedFolderAskingForSingleSignOnShowsItsButtonInPlaceOfTheCount(width: CGFloat) throws {
        for name in ["PRs", Self.long] {
            let id = folder(name)
            LiveFolders.shared.apply(.sso(sso, []), to: id)
            let view = heading(id, name, width: width)

            try expectButton(view, "\(name) at \(width)")
            if name == "PRs" { #expect(pill(of: view)?.title == "Single sign-on", "\(width)") }
        }
    }

    @Test(arguments: [200, 182] as [CGFloat])
    func aLongNameAtANarrowWidthShortensTheButtonToSignIn(width: CGFloat) throws {
        let id = folder(Self.long)
        LiveFolders.shared.apply(.sso(sso, []), to: id)
        let view = heading(id, Self.long, width: width)

        try expectButton(view, "\(width)")
        #expect(pill(of: view)?.title == "Sign in")
    }

    @Test func aLongNameWithRoomKeepsTheFullWording() throws {
        let id = folder(Self.long)
        LiveFolders.shared.apply(.sso(sso, []), to: id)
        let view = heading(id, Self.long, width: 320)

        try expectButton(view, "320")
        #expect(pill(of: view)?.title == "Single sign-on")
    }

    @Test func fineThenSignInThenFineSwapsTheCountAndTheButtonWhileFolded() async throws {
        let id = folder("PRs")
        let view = heading(id, "PRs", width: 227)
        #expect(pill(of: view) == nil)
        #expect(view.showsCount)

        LiveFolders.shared.apply(.sso(sso, []), to: id)
        try await settled(view)
        try expectButton(view, "signed out")

        LiveFolders.shared.apply(.items([LiveItem(key: "https://github.com/octocorp/ios/pull/1", title: "Pull 1")], nil), to: id)
        try await settled(view)
        #expect(pill(of: view) == nil)
        #expect(view.showsCount)
        #expect(view.chipFold.frame.width > 0)

        LiveFolders.shared.apply(.signIn, to: id)
        try await settled(view)
        #expect(!view.showsCount)
        #expect(pill(of: view)?.title == "Sign in")
    }

    @Test func pausedAndFailedFoldersStillGiveWayToTheNameAndKeepTheCount() {
        for (state, words) in [("paused", "Paused"), ("failed", "Can't read")] {
            let id = folder(Self.long)
            if state == "paused" { LiveFolders.shared.pause(id, true) } else { LiveFolders.shared.apply(.failed, to: id) }
            #expect(LiveFolders.shared.folder(id)?.status == words)
            let narrow = heading(id, Self.long, width: 200)
            let wide = heading(id, "PRs", width: 320)

            #expect(pill(of: narrow) == nil, "\(state)")
            #expect(narrow.showsCount, "\(state)")
            #expect(narrow.status?.isHidden == true, "\(state): the status should give way to the long name")
            #expect(wide.showsCount, "\(state)")
            #expect(wide.status?.isHidden == false, "\(state): the status should show beside a short name")
        }
    }

    @Test(arguments: [245, 200] as [CGFloat])
    func aPressOnTheFoldedButtonOpensTheSignOnPage(width: CGFloat) throws {
        let local = LiveSSO(org: "Octo Corp", url: "http://127.0.0.1:9/orgs/octocorp/sso")
        let id = folder(Self.long)
        LiveFolders.shared.apply(.sso(local, []), to: id)
        let view = heading(id, Self.long, width: width)
        let browser = try #require(browsers.last)
        let pill = try #require(pill(of: view))
        let centre = view.convert(NSPoint(x: pill.bounds.midX, y: pill.bounds.midY), from: pill)

        let hit = try #require(view.hitTest(centre))
        let pressed = pill.accessibilityPerformPress()

        #expect(hit === pill || hit.isDescendant(of: pill))
        #expect(pressed)
        #expect(browser.tabs.contains { ($0.pending ?? $0.address)?.absoluteString == local.url })
        #expect(view.group?.collapsed == true)
    }

    @Test func anOpenFolderAskingForSignInKeepsItsNoteAndNoPill() {
        let id = folder("PRs")
        LiveFolders.shared.apply(.sso(sso, []), to: id)
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        let view = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 227, height: GroupHeadingView.height))
        view.count = 18
        view.show(TabGroup(id: id, name: "PRs", collapsed: false, live: true), in: browser)
        settle(view)

        #expect(pill(of: view) == nil)
        #expect(LiveFolders.shared.folder(id)?.note == .sso(sso))
    }
}

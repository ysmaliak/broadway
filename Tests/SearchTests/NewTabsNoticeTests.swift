import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class NewTabsNoticeTests {
    private var window: NSWindow?
    private var browser: Browser?
    private var restore: (() -> Void)?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        if let browser { ContentView.forget(browser); browser.dropNewTabs(); browser.closeAll() }
        window?.contentView = nil
        window?.close()
        restore?()
    }

    @Test func oneTabSaysNewTabOpened() {
        let notice = NewTabsNotice().adding(UUID())

        #expect(notice.text == "New tab opened")
    }

    @Test func threeTabsAreCountedInOneNotice() {
        let notice = NewTabsNotice().adding(UUID()).adding(UUID()).adding(UUID())

        #expect(notice.text == "3 new tabs opened")
    }

    @Test func showGoesToTheNewestTab() {
        let newest = UUID()
        let notice = NewTabsNotice().adding(UUID()).adding(newest)

        #expect(notice.newest == newest)
    }

    @Test func aClosedTabLeavesTheCount() throws {
        let one = UUID(), two = UUID(), three = UUID()
        let notice = NewTabsNotice().adding(one).adding(two).adding(three)

        let kept = try #require(notice.kept(in: [one, three], active: nil))

        #expect(kept.text == "2 new tabs opened")
        #expect(kept.newest == three)
    }

    @Test func choosingOneOfTheTabsEndsTheNotice() {
        let one = UUID(), two = UUID()
        let notice = NewTabsNotice().adding(one).adding(two)

        #expect(notice.kept(in: [one, two], active: one) == nil)
    }

    @Test func theNoticeEndsWhenEveryTabIsClosed() {
        let notice = NewTabsNotice().adding(UUID())

        #expect(notice.kept(in: [UUID()], active: nil) == nil)
    }

    @Test func aTabOpenedBehindWhileTheSidebarIsHiddenIsNoticed() async throws {
        let browser = try await scene(folded: true)

        let tab = opened(browser)
        try await settle()

        #expect(browser.newTabsShown?.text == "New tab opened")
        #expect(browser.newTabsShown?.newest == tab.id)
        #expect(notes().contains("New tab opened"))
    }

    @Test func tabsOpenedOneAfterAnotherMergeIntoOneNoticeThatCounts() async throws {
        let browser = try await scene(folded: true)

        _ = opened(browser)
        try await settle()
        _ = opened(browser)
        let last = opened(browser)
        try await settle()

        #expect(browser.newTabsShown?.text == "3 new tabs opened")
        #expect(browser.newTabsShown?.newest == last.id)
        #expect(notes().filter { $0.hasSuffix("opened") } == ["3 new tabs opened"])
    }

    @Test func showSelectsTheNewestTabAndTheNoticeGoes() async throws {
        let browser = try await scene(folded: true)
        _ = opened(browser)
        let last = opened(browser)
        try await settle()

        browser.showNewTabs()
        try await settle()

        #expect(browser.activeID == last.id)
        #expect(browser.newTabsShown == nil)
        #expect(browser.newTabs == nil)
    }

    @Test func noNoticeWhileTheSidebarIsShowing() async throws {
        let browser = try await scene(folded: false)

        _ = opened(browser)
        try await settle()

        #expect(browser.newTabs == nil)
        #expect(!notes().contains("New tab opened"))
    }

    @Test func noNoticeWhileTheHiddenSidebarIsSlidOut() async throws {
        let browser = try await scene(folded: true)
        browser.peek(true)

        _ = opened(browser)
        try await settle()

        #expect(browser.newTabs == nil)
    }

    @Test func theNoticeGoesWhenTheSidebarComesOut() async throws {
        let browser = try await scene(folded: true)
        _ = opened(browser)
        try await settle()
        #expect(browser.newTabsShown != nil)

        browser.peek(true)
        try await settle()
        browser.peek(false)
        try await settle()

        #expect(browser.newTabs == nil)
        #expect(browser.newTabsShown == nil)
    }

    @Test func noNoticeForATabAnAgentOpens() async throws {
        let browser = try await scene(folded: true)

        let tab = opened(browser)
        tab.agent = true
        try await settle()
        _ = browser.benchOpen(URL(string: "about:blank#agent")!)
        try await settle()

        #expect(browser.newTabs == nil)
    }

    @Test func noNoticeForATabOpenedInFront() async throws {
        let browser = try await scene(folded: true)

        _ = browser.open(URL(string: "about:blank#front")!, foreground: true, atEnd: true, mayWait: true)
        try await settle()

        #expect(browser.newTabs == nil)
    }

    @Test func noNoticeForATabOpenedInAnotherWindow() async throws {
        let browser = try await scene(folded: true)
        let other = Browser(record: WindowRecord())
        other.folded = true
        defer { other.closeAll() }

        _ = other.open(URL(string: "about:blank#elsewhere")!, foreground: false, atEnd: true, mayWait: true)
        try await settle()

        #expect(browser.newTabs == nil)
        #expect(other.newTabs == nil)
    }

    private func opened(_ browser: Browser) -> Tab {
        browser.open(URL(string: "about:blank#behind-\(UUID().uuidString)")!, foreground: false, atEnd: true, mayWait: true)
    }

    private func notes() -> [String] {
        guard let root = window?.contentView else { return [] }
        return all(CapsuleNote.self, in: root).filter { !$0.isHiddenOrHasHiddenAncestor && $0.superview != nil }.map(\.label.text)
    }

    private func scene(folded: Bool) async throws -> Browser {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = prefs.splitView
        restore = { prefs.splitView = saved }
        prefs.splitView = false
        for index in 0..<2 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        browser.select(browser.tabs[0])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ContentView(browser: browser)
        window.orderFrontRegardless()
        self.browser = browser
        self.window = window
        browser.folded = folded
        try await settle()
        return browser
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
    }

    private func settle() async throws {
        for _ in 0..<4 {
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct WindowMergeTests {
    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        keepSetting(Shared.prefs, \.newTabPlace, "tabs.newPlace")
        keepSetting(Shared.prefs, \.newTabsAtBottom, Preferences.newAtBottomKey)
        keepSetting(Shared.prefs, \.splitView)
        keepSetting(Shared.prefs, \.usesTabGroups)
    }

    private func window(_ names: [String]) -> Browser {
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.closeAll()
        browser.record.rows = [:]
        browser.parked = [:]
        browser.tabGroups = []
        for name in names {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "https://merge-\(name).example/")!, title: name)
        }
        return browser
    }

    private func names(_ tabs: [Tab]) -> [String] { tabs.map(\.title) }

    private func both(_ front: [String], _ other: [String], _ body: (Browser, Browser) throws -> Void) rethrows {
        let a = window(front), b = window(other)
        defer { a.closeAll(); b.closeAll() }
        try body(a, b)
    }

    @Test func anOrdinaryWindowJoinsTheOrdinaryWindowInFront() {
        let plain = WindowMerge.Kind(open: true, popup: false, privateWindow: false)

        #expect(WindowMerge.joins(plain, into: plain))
    }

    @Test func aPrivateWindowNeverJoinsAnOrdinaryOneNorTakesOne() {
        let plain = WindowMerge.Kind(open: true, popup: false, privateWindow: false)
        let quiet = WindowMerge.Kind(open: true, popup: false, privateWindow: true)

        #expect(!WindowMerge.joins(quiet, into: plain))
        #expect(!WindowMerge.joins(plain, into: quiet))
        #expect(!WindowMerge.joins(quiet, into: quiet))
    }

    @Test func aPopupOrAClosedWindowIsNotMerged() {
        let plain = WindowMerge.Kind(open: true, popup: false, privateWindow: false)

        #expect(!WindowMerge.joins(WindowMerge.Kind(open: true, popup: true, privateWindow: false), into: plain))
        #expect(!WindowMerge.joins(WindowMerge.Kind(open: false, popup: false, privateWindow: false), into: plain))
        #expect(!WindowMerge.joins(plain, into: WindowMerge.Kind(open: true, popup: true, privateWindow: false)))
    }

    @Test func nothingToMergeWithNoOtherOpenWindow() {
        let lone = window(["lone"])
        defer { lone.closeAll() }

        #expect(!WindowMerge.canMerge(into: lone))
    }

    @Test func theOtherWindowsTabsGoToTheEndInTheirOrderWithNewTabsAtTheBottom() {
        both(["a", "b"], ["c", "d", "e"]) { front, other in
            front.prefs.newTabPlace = .end
            front.select(front.tabs[0])

            WindowMerge.carry(from: other, into: front)

            #expect(names(front.tabs) == ["a", "b", "c", "d", "e"])
            #expect(other.tabs.isEmpty)
        }
    }

    @Test func theOtherWindowsTabsKeepTheirOrderWithNewTabsAtTheTop() {
        both(["a", "b"], ["c", "d"]) { front, other in
            front.prefs.newTabPlace = .top

            WindowMerge.carry(from: other, into: front)

            #expect(names(front.tabs) == ["c", "d", "a", "b"])
        }
    }

    @Test func theOtherWindowsTabsGoAfterTheTabInFrontWithNewTabsNextToIt() {
        both(["a", "b"], ["c", "d"]) { front, other in
            front.prefs.newTabPlace = .next
            front.select(front.tabs[0])

            WindowMerge.carry(from: other, into: front)

            #expect(names(front.tabs) == ["a", "c", "d", "b"])
        }
    }

    @Test func twoOtherWindowsFollowEachOtherInTheOrderTheyWereOpened() {
        let front = window(["a", "b"]), second = window(["c", "d"]), third = window(["e"])
        defer { front.closeAll(); second.closeAll(); third.closeAll() }
        front.prefs.newTabPlace = .next
        front.select(front.tabs[0])

        let last = WindowMerge.carry(from: second, into: front)
        WindowMerge.carry(from: third, into: front, after: last)

        #expect(names(front.tabs) == ["a", "c", "d", "e", "b"])
    }

    @Test func theTabInFrontStaysInFrontAndMovedTabsStayAsleep() throws {
        try both(["a", "b"], ["c", "d"]) { front, other in
            let shown = try #require(front.tabs.last)
            front.select(shown)
            let moving = other.tabs
            let slept = moving.map(\.asleep)

            WindowMerge.carry(from: other, into: front)

            #expect(front.activeID == shown.id)
            #expect(moving.map(\.asleep) == slept)
            #expect(moving.allSatisfy { ($0.delegate as? Browser) === front })
        }
    }

    @Test func aSplitViewPairStaysAPair() throws {
        try both(["a"], ["b", "c", "d"]) { front, other in
            front.prefs.splitView = true
            front.prefs.newTabPlace = .end
            let left = other.tabs[1], right = other.tabs[2]
            other.putBackSplit(TabSplit(tabs: [left.id, right.id]))

            WindowMerge.carry(from: other, into: front)

            let pair = try #require(front.split(for: left))
            #expect(pair.tabs == [left.id, right.id])
            #expect(names(front.tabs) == ["a", "b", "c", "d"])
        }
    }

    @Test func aFolderAndTheFolderInsideItStayFolders() throws {
        try both(["a"], ["b", "c", "d"]) { front, other in
            front.prefs.usesTabGroups = true
            let outer = other.addTabGroup(containing: other.tabs[0])
            let inner = other.addTabGroup(containing: other.tabs[1], inside: outer)
            other.editingGroupID = nil
            let b = try #require(other.tabs.first { $0.title == "b" })
            let c = try #require(other.tabs.first { $0.title == "c" })

            WindowMerge.carry(from: other, into: front)

            #expect(front.tabGroups.contains { $0.id == outer })
            #expect(front.tabGroups.first { $0.id == inner }?.parent == outer)
            #expect(b.groupID == outer)
            #expect(c.groupID == inner)
            #expect(front.group(of: c) == inner)
        }
    }

    @Test func aPinStaysWithItsWindowAndIsNotMoved() throws {
        try both(["a"], ["b", "c"]) { front, other in
            let pin = try #require(other.tabs.first)
            pin.pin = "P"

            WindowMerge.carry(from: other, into: front)

            #expect(!front.tabs.contains { $0 === pin })
            #expect(other.tabs.map(\.title) == ["b"])
            #expect(names(front.tabs) == ["a", "c"] || names(front.tabs) == ["c", "a"])
        }
    }

    @Test func tabsOfAnotherSpaceGoToThatSpacesRowInTheWindowInFront() throws {
        try both(["a"], ["b"]) { front, other in
            let away = UUID()
            let tab = other.makeTab(space: away)
            tab.restore(url: URL(string: "https://merge-away.example/")!, title: "away")
            other.parked[away] = Parked(tabs: [tab], active: tab.id)

            WindowMerge.carry(from: other, into: front)

            let row = try #require(front.parked[away])
            #expect(row.tabs.map(\.title) == ["away"])
            #expect(row.active == tab.id)
            #expect(other.parked[away]?.tabs.isEmpty ?? true)
            #expect(!front.tabs.contains { $0 === tab })
        }
    }
}

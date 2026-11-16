import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class TabOutOfFolderTests {
    private let a = UUID(), b = UUID(), c = UUID(), m1 = UUID(), m2 = UUID(), source = UUID()
    private let open = TabGroup(id: UUID(), name: "Open", collapsed: false)
    private let shut = TabGroup(id: UUID(), name: "Shut", collapsed: true)

    private func row(_ y: CGFloat, indent: CGFloat = 0) -> CGRect { CGRect(x: 8 + indent, y: y, width: 240 - indent, height: 28) }

    private var items: [(item: Browser.ListItem, rect: CGRect)] {
        [(.tab(a), row(100)), (.folder(open.id), CGRect(x: 8, y: 131, width: 240, height: 90)),
         (.tab(b), row(224)), (.folder(shut.id), row(255)), (.tab(c), row(286))]
    }

    private var frames: [UUID: GroupDropFrame] {
        [open.id: GroupDropFrame(group: open.id, rect: row(131)),
         m1: GroupDropFrame(group: open.id, tab: m1, rect: row(162, indent: 16)),
         m2: GroupDropFrame(group: open.id, tab: m2, rect: row(193, indent: 16)),
         shut.id: GroupDropFrame(group: shut.id, rect: row(255))]
    }

    private func drop(_ y: CGFloat, x: CGFloat = 120, top: CGFloat = 60) -> ListDrop? {
        ListDrop.resolve(CGPoint(x: x, y: y), items: items, below: top, frames: frames, groups: [open, shut], excluding: source)
    }

    private func loose(_ before: Browser.ListItem?) -> ListDrop { .loose(LoosePlace(before: before)) }

    @Test func overALooseTabTheLineGoesAboveOrBelowItByItsMiddle() {
        #expect(drop(105) == loose(.tab(a)))
        #expect(drop(122) == loose(.folder(open.id)))
        #expect(drop(240) == loose(.folder(shut.id)))
    }

    @Test func theGapBetweenTwoItemsIsAPlaceAmongTheLooseTabs() {
        #expect(drop(129.5) == loose(.folder(open.id)))
        #expect(drop(222.5) == loose(.tab(b)))
    }

    @Test func theTopOfTheListAboveItsFirstItemIsAPlace() {
        #expect(drop(70) == loose(.tab(a)))
        #expect(drop(99) == loose(.tab(a)))
    }

    @Test func theEndOfTheListBelowItsLastItemIsAPlace() {
        #expect(drop(310) == loose(nil))
        #expect(drop(600) == loose(nil))
    }

    @Test func aHeadingsUpperEdgeIsAboveTheFolderAndTheRestOfItGoesInside() {
        #expect(drop(132) == loose(.folder(open.id)))
        #expect(drop(131 + ListDrop.edge - 0.5) == loose(.folder(open.id)))
        #expect(drop(150) == .folder(GroupDropTarget(group: open.id)))
    }

    @Test func aLooseTabCarriedOntoAHeadingsEdgeGoesInsideAndTheGapsStayPlaces() {
        func carried(_ y: CGFloat) -> ListDrop? {
            ListDrop.resolve(CGPoint(x: 120, y: y), items: items, below: 60, frames: frames, groups: [open, shut], excluding: source, band: 0)
        }
        #expect(carried(134) == .folder(GroupDropTarget(group: open.id)))
        #expect(carried(258) == .folder(GroupDropTarget(group: shut.id)))
        #expect(carried(129.5) == loose(.folder(open.id)))
        #expect(carried(253) == loose(.folder(shut.id)))
        #expect(carried(105) == loose(.tab(a)))
    }

    @Test func aFoldersLastRowTakesItsEndAndBelowItIsAfterTheFolder() {
        #expect(drop(212) == .folder(GroupDropTarget(group: open.id, member: m2, after: true)))
        #expect(drop(170) == .folder(GroupDropTarget(group: open.id, member: m1)))
        #expect(drop(222) == loose(.tab(b)))
        #expect(drop(230) == loose(.tab(b)))
    }

    @Test func aFoldedFolderHasAPlaceAboveAndBelowItsHeading() {
        #expect(drop(256) == loose(.folder(shut.id)))
        #expect(drop(268) == .folder(GroupDropTarget(group: shut.id)))
        #expect(drop(281) == loose(.tab(c)))
    }

    @Test func aFolderThatIsTheLastItemHasAPlaceBelowIt() {
        let list = Array(items.prefix(2))
        let place = ListDrop.resolve(CGPoint(x: 120, y: 240), items: list, below: 60, frames: frames, groups: [open, shut], excluding: source)
        #expect(place == loose(nil))
    }

    @Test func aFolderOfTheCarriedTabAloneKeepsItOnItsOwnSlotAndLetsItOutBelow() {
        let alone: [UUID: GroupDropFrame] = [open.id: GroupDropFrame(group: open.id, rect: row(131)),
                                             source: GroupDropFrame(group: open.id, tab: source, rect: row(162, indent: 16))]
        let list: [(item: Browser.ListItem, rect: CGRect)] = [(.folder(open.id), CGRect(x: 8, y: 131, width: 240, height: 63)),
                                                               (.tab(b), row(197))]
        func place(_ y: CGFloat) -> ListDrop? {
            ListDrop.resolve(CGPoint(x: 120, y: y), items: list, below: 60, frames: alone, groups: [open], excluding: source)
        }
        #expect(place(170) == nil)
        #expect(place(189) == nil)
        #expect(place(193) == loose(.tab(b)))
        #expect(place(200) == loose(.tab(b)))
        #expect(place(150) == .folder(GroupDropTarget(group: open.id)))
    }

    @Test func theLastRowLetGoOnItsOwnSlotGoesNowhere() {
        var mine = frames
        mine[m2] = nil
        mine[source] = GroupDropFrame(group: open.id, tab: source, rect: row(193, indent: 16))
        let place = ListDrop.resolve(CGPoint(x: 120, y: 205), items: items, below: 60, frames: mine, groups: [open, shut], excluding: source)
        #expect(place == nil)
        let below = ListDrop.resolve(CGPoint(x: 120, y: 222), items: items, below: 60, frames: mine, groups: [open, shut], excluding: source)
        #expect(below == loose(.tab(b)))
    }

    @Test func aNestedFoldersRowsAreItsOwn() {
        let inner = TabGroup(id: UUID(), name: "Inner", collapsed: false, parent: open.id)
        var nested = frames
        nested[inner.id] = GroupDropFrame(group: inner.id, rect: row(162, indent: 16))
        nested[m1] = GroupDropFrame(group: inner.id, tab: m1, rect: row(193, indent: 32))
        nested[m2] = nil
        let place = ListDrop.resolve(CGPoint(x: 120, y: 200), items: items, below: 60, frames: nested,
                                     groups: [open, inner, shut], excluding: source)
        #expect(place == .folder(GroupDropTarget(group: inner.id, member: m1)))
    }

    @Test func aboveTheListOnlyTheRaisedFoldersCount() {
        #expect(drop(50) == nil)
        #expect(drop(20, top: 60) == nil)
    }

    @Test func besideTheColumnNothingIsAPlace() {
        #expect(drop(105, x: 300) == nil)
        #expect(drop(105, x: -10) == nil)
    }

    @Test func aRowOrOutlineCrossingAnEdgeOfTheListIsCut() {
        let top: CGFloat = 100, bottom: CGFloat = 500
        #expect(SidePageView.crossing([CGRect(x: 0, y: 90, width: 10, height: 28)], top: top, bottom: bottom) == (true, false))
        #expect(SidePageView.crossing([CGRect(x: 0, y: 100, width: 10, height: 28)], top: top, bottom: bottom) == (false, false))
        #expect(SidePageView.crossing([CGRect(x: 0, y: 99.5, width: 10, height: 28)], top: top, bottom: bottom) == (false, false))
        #expect(SidePageView.crossing([CGRect(x: 0, y: 480, width: 10, height: 28)], top: top, bottom: bottom) == (false, true))
        #expect(SidePageView.crossing([], top: top, bottom: bottom) == (false, false))
    }

    private func browser(_ count: Int) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        for number in 0..<count {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        addTeardownBlock { @MainActor in browser.closeAll() }
        return browser
    }

    private func listed(_ browser: Browser) -> [String] {
        browser.listItems(browser.displayedTabs).map { item in
            switch item {
            case .tab(let id): browser.tabs.first { $0.id == id }?.title ?? "?"
            case .folder(let id): "[" + (browser.tabGroups.first { $0.id == id }?.name ?? "?") + "]"
            }
        }
    }

    private func world() throws -> (Browser, [Tab], UUID, UUID) {
        let browser = browser(8)
        let tabs = browser.tabs
        let first = try #require(browser.newFolder(with: [tabs[0], tabs[1]], named: "One", editing: false))
        let second = try #require(browser.newFolder(with: [tabs[3], tabs[4]], named: "Two", editing: false))
        #expect(listed(browser) == ["[One]", "2", "[Two]", "5", "6", "7"])
        return (browser, tabs, first, second)
    }

    @Test func aTabOutOfAFolderLandsBetweenTwoLooseTabs() throws {
        let (browser, tabs, _, _) = try world()
        browser.moveOut(tabs[1], before: .tab(tabs[6].id))
        #expect(listed(browser) == ["[One]", "2", "[Two]", "5", "1", "6", "7"])
        #expect(browser.group(of: tabs[1]) == nil)
    }

    @Test func aTabOutOfAFolderLandsAtTheTopAboveTheFirstFolder() throws {
        let (browser, tabs, first, _) = try world()
        browser.moveOut(tabs[0], before: .folder(first))
        #expect(listed(browser) == ["0", "[One]", "2", "[Two]", "5", "6", "7"])
    }

    @Test func aTabOutOfAFolderLandsAtTheEnd() throws {
        let (browser, tabs, _, _) = try world()
        browser.moveOut(tabs[0], before: nil)
        #expect(listed(browser) == ["[One]", "2", "[Two]", "5", "6", "7", "0"])
    }

    @Test func aTabOutOfAFolderLandsJustAfterAnotherFolderOrJustBeforeIt() throws {
        let (browser, tabs, _, second) = try world()
        browser.moveOut(tabs[0], before: .tab(tabs[5].id))
        #expect(listed(browser) == ["[One]", "2", "[Two]", "0", "5", "6", "7"])
        browser.moveOut(tabs[3], before: .folder(second))
        #expect(listed(browser) == ["[One]", "2", "3", "[Two]", "0", "5", "6", "7"])
    }

    @Test func theLastTabOutOfAFolderLandsWhereTheFolderWas() throws {
        let (browser, tabs, first, _) = try world()
        browser.moveOut(tabs[0], before: .tab(tabs[2].id))
        browser.moveOut(tabs[1], before: .folder(first))
        #expect(listed(browser) == ["1", "0", "2", "[Two]", "5", "6", "7"])
        #expect(!browser.tabGroups.contains { $0.id == first })
    }

    @Test func aTabOutOfANestedFolderLandsAmongTheLooseTabs() throws {
        let (browser, tabs, first, _) = try world()
        let inner = try #require(browser.newFolder(with: [tabs[1]], inside: first, named: "Inner", editing: false))
        #expect(browser.group(of: tabs[1]) == inner)
        browser.moveOut(tabs[1], before: .tab(tabs[7].id))
        #expect(listed(browser) == ["[One]", "2", "[Two]", "5", "6", "1", "7"])
    }

    @Test func aPairOutOfAFolderGoesTogether() throws {
        let (browser, tabs, first, _) = try world()
        let split = browser.prefs.splitView
        defer { browser.prefs.splitView = split }
        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.moveOut(tabs[0], before: .tab(tabs[6].id))
        #expect(browser.group(of: tabs[0]) == nil && browser.group(of: tabs[1]) == nil)
        #expect(browser.split(for: tabs[0])?.contains(tabs[1].id) == true)
        #expect(!browser.tabGroups.contains { $0.id == first })
    }

    @Test func aLooseTabIsNotMovedOut() throws {
        let (browser, tabs, _, _) = try world()
        let before = browser.tabs.map(\.id)
        browser.moveOut(tabs[2], before: nil)
        #expect(browser.tabs.map(\.id) == before)
    }

    @Test func undoPutsTheTabBackInItsFolderWhereItWas() throws {
        let (browser, tabs, first, _) = try world()
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer {
            browser.window = nil
            window.close()
        }
        let undo = try #require(window.undoManager)
        undo.removeAllActions()
        undo.groupsByEvent = false
        let order = browser.tabs.map(\.id)
        undo.beginUndoGrouping()
        browser.beginGesture()
        browser.move(tabs[1], within: first, to: 0)
        browser.moveOut(tabs[1], before: .tab(tabs[6].id))
        browser.endGesture()
        undo.endUndoGrouping()
        #expect(listed(browser) == ["[One]", "2", "[Two]", "5", "1", "6", "7"])
        #expect(undo.undoMenuItemTitle == "Undo Remove from Folder")
        undo.undo()
        #expect(browser.tabs.map(\.id) == order)
        #expect(browser.group(of: tabs[1]) == first)
        #expect(listed(browser) == ["[One]", "2", "[Two]", "5", "6", "7"])
    }
}

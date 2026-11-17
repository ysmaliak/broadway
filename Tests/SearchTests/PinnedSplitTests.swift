import AppKit
import Foundation
import Testing
@testable import Search

struct PinnedSplitRuleTests {
    private struct ReleasedPinDef: Codable {
        var id: UUID
        var letter: String
        var home: String
        var title: String
        var name: String?
        var icon: TabIcon? = nil
    }

    private func def(_ letter: String, split: PinSplit? = nil) -> PinDef {
        PinDef(id: UUID(), letter: letter, home: "https://\(letter.lowercased()).example/", title: letter, name: nil, split: split)
    }

    @Test func twoPinsSideBySideWithOneSplitStayASplit() {
        let pair = PinSplit(id: UUID(), axis: .horizontal, size: 0.4)
        let defs = [def("A"), def("B", split: pair), def("C", split: pair)]

        #expect(PinSplit.whole(defs) == defs)
        #expect(PinSplit.groups(defs).map(\.ids) == [[defs[1].id, defs[2].id]])
    }

    @Test func aPinLeftAloneWithASplitIsAnOrdinaryPin() {
        let pair = PinSplit(id: UUID())
        let defs = [def("A", split: pair), def("B")]

        #expect(PinSplit.whole(defs).allSatisfy { $0.split == nil })
        #expect(PinSplit.groups(defs).isEmpty)
    }

    @Test func twoPinsOfOneSplitWithAPinBetweenAreOrdinaryPins() {
        let pair = PinSplit(id: UUID())
        let defs = [def("A", split: pair), def("B"), def("C", split: pair)]

        #expect(PinSplit.whole(defs).allSatisfy { $0.split == nil })
    }

    @Test func eachPagesShareIsKeptInOrder() throws {
        let pair = PinSplit(id: UUID(), axis: .vertical, size: 0.3)
        var second = pair
        second.size = 0.7
        let defs = [def("A", split: pair), def("B", split: second)]

        let group = try #require(PinSplit.groups(defs).first)
        #expect(group.sizes == [0.3, 0.7])
        #expect(group.split.axis == .vertical)
    }

    @Test func aSplitAllPinnedIsWholeAndOneHalfPinnedIsMixed() {
        let a = UUID(), b = UUID()
        let pair = TabSplit(tabs: [a, b])

        #expect(PinnedSplits.whole(pair) { _ in true })
        #expect(!PinnedSplits.whole(pair) { $0 == a })
        #expect(PinnedSplits.mixed(pair) { $0 == a })
        #expect(!PinnedSplits.mixed(pair) { _ in false })
    }

    @Test func aPageLeavingAPinnedSplitIsUnpinnedAndTheOtherKeepsItsPin() {
        let a = UUID(), b = UUID()
        let left = PinnedSplits.leaving(TabSplit(tabs: [a, b]), page: b) { _ in true }

        #expect(left.unpin == b)
        #expect(left.keepsPin == [a])
    }

    @Test func aPageLeavingAnOrdinarySplitUnpinsNothing() {
        let a = UUID(), b = UUID()
        let left = PinnedSplits.leaving(TabSplit(tabs: [a, b]), page: b) { _ in false }

        #expect(left.unpin == nil)
        #expect(left.keepsPin.isEmpty)
    }

    @Test func aFileWrittenBeforePinnedSplitsReadsAsItDid() throws {
        let space = UUID()
        let json = """
        {"\(space.uuidString)": [{"id": "\(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A"},
                                 {"id": "\(UUID().uuidString)", "letter": "B", "home": "https://b.example/", "title": "B", "name": "Reeds"}]}
        """

        let read = try #require(Pins.decode(Data(json.utf8)))

        #expect(read.bySpace[space]?.map(\.letter) == ["A", "B"])
        #expect(read.bySpace[space]?.allSatisfy { $0.split == nil } == true)
        #expect(read.bySpace[space]?.last?.name == "Reeds")
    }

    @Test func aFileWithAPinnedSplitReadsItsSplitBack() throws {
        let space = UUID()
        let pair = PinSplit(id: UUID(), axis: .vertical, size: 0.35)
        var second = pair
        second.size = 0.65
        let written = try #require(Pins.encode(bySpace: [space: [def("A", split: pair), def("B", split: second)]], shared: []))

        let read = try #require(Pins.decode(written))

        #expect(read.bySpace[space]?.map(\.split) == [pair, second])
    }

    @Test func theReleasedBuildReadsAPinnedSplitAsTwoPins() throws {
        let space = UUID()
        let pair = PinSplit(id: UUID(), axis: .horizontal, size: 0.4)
        let written = try #require(Pins.encode(bySpace: [space: [def("A", split: pair), def("B", split: pair)]], shared: []))

        let read = try JSONDecoder().decode([String: [ReleasedPinDef]].self, from: written)

        #expect(read[space.uuidString]?.map(\.letter) == ["A", "B"])
        #expect(read[space.uuidString]?.map(\.home) == ["https://a.example/", "https://b.example/"])
    }

    @Test func aSplitThatMakesNoSenseLeavesItsPinWhole() throws {
        let space = UUID()
        let json = """
        {"\(space.uuidString)": [{"id": "\(UUID().uuidString)", "letter": "A", "home": "https://a.example/", "title": "A", "split": "sideways"},
                                 {"id": "\(UUID().uuidString)", "letter": "B", "home": "https://b.example/", "title": "B",
                                  "split": {"id": "\(UUID().uuidString)", "axis": "diagonal", "size": "half"}}]}
        """

        let read = try #require(Pins.decode(Data(json.utf8)))

        #expect(read.bySpace[space]?.map(\.letter) == ["A", "B"])
        #expect(read.bySpace[space]?.first?.split == nil)
        #expect(read.bySpace[space]?.last?.split?.axis == .horizontal)
        #expect(read.bySpace[space]?.last?.split?.size == 0.5)
    }

    @Test func aSessionWrittenBeforeReadsWithNoNewKeys() throws {
        let json = """
        {"tabs": [{"url": "https://a.example/", "title": "A", "pin": "A", "home": "https://a.example/", "pinID": "\(UUID().uuidString)"}],
         "active": 0}
        """

        let shape = try JSONDecoder().decode(Session.Shape.self, from: Data(json.utf8))

        #expect(shape.tabs.map(\.pin) == ["A"])
        #expect(shape.splits.isEmpty)
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PinnedSplitWorldTests {
    private var browser: Browser!
    private var others: [Browser] = []
    private var old: (split: Bool, spaces: Bool, shares: Bool) = (false, false, false)

    init() {
        keepSettings("splitView", "spaces")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        old = (browser.prefs.splitView, browser.prefs.usesSpaces, browser.prefs.sharesPins)
        browser.prefs.splitView = true
        browser.closeAll()
    }

    private func tearDown() {
        for other in others { other.closeAll() }
        others = []
        browser?.closeAll()
        if let prefs = browser?.prefs { (prefs.splitView, prefs.usesSpaces, prefs.sharesPins) = old }
        browser = nil
    }

    private func page(_ name: String) -> Tab {
        let tab = browser.makeTab()
        browser.prepare(tab)
        tab.restore(url: URL(string: "https://\(name).example/")!, title: name)
        return tab
    }

    private func row() -> (left: Tab, right: Tab, loose: Tab, pair: TabSplit) {
        let left = page("pond"), right = page("reeds"), loose = page("frogs")
        browser.showRow([left, right, loose], active: left.id)
        let pair = TabSplit(tabs: [left.id, right.id], sizes: [0.3, 0.7], focused: left.id)
        browser.putBackSplit(pair)
        return (left, right, loose, pair)
    }

    private func pinned() throws -> (left: Tab, right: Tab, loose: Tab, pair: TabSplit) {
        let made = row()
        browser.pinSplit(made.pair)
        try #require(browser.pinnedSplit(of: made.left) != nil)
        return made
    }

    private func window() -> Browser {
        let other = Browser(record: WindowRecord())
        others.append(other)
        return other
    }

    @Test func pinningASplitKeepsBothPagesAsOneItemAmongThePins() throws {
        let (left, right, _, pair) = try pinned()

        #expect(left.pin != nil && right.pin != nil)
        #expect(browser.splits.first { $0.id == pair.id }?.sizes == [0.3, 0.7])
        #expect(browser.squarePins.map(\.id) == [left.id])
        #expect(browser.tabs.prefix(2).map(\.id) == [left.id, right.id])
        let defs = Pins.defs(browser.spaceID)
        #expect(defs.map(\.split?.id) == [pair.id, pair.id])
        #expect(defs.map(\.split?.size) == [0.3, 0.7])
        #expect(defs.map(\.home) == ["https://pond.example/", "https://reeds.example/"])
    }

    @Test func aSplitWithAnEmptyPageCannotBePinned() {
        let left = page("pond")
        let empty = browser.makeTab()
        browser.showRow([left, empty], active: left.id)
        let pair = TabSplit(tabs: [left.id, empty.id])
        browser.putBackSplit(pair)

        #expect(!browser.canPinSplit(pair))
        browser.pinSplit(pair)

        #expect(left.pin == nil)
    }

    @Test func thePinCommandWithASplitInFrontPinsAndUnpinsTheSplit() throws {
        let (left, right, _, _) = row()
        browser.select(right)

        browser.togglePinFront()
        #expect(left.pin != nil && right.pin != nil)
        #expect(browser.pinnedSplit(of: right) != nil)

        browser.togglePinFront()
        #expect(left.pin == nil && right.pin == nil)
        #expect(browser.split(for: right) != nil)
    }

    @Test func aSecondWindowHasTheSameSplitAmongItsPins() throws {
        let (_, _, _, pair) = try pinned()

        let other = window()

        let there = try #require(other.splits.first { $0.id == pair.id })
        #expect(there.sizes == [0.3, 0.7])
        #expect(there.tabs.compactMap { id in other.tabs.first { $0.id == id }?.pin }.count == 2)
        #expect(other.squarePins.count == 1)
    }

    @Test func aSecondWindowFollowsWhenTheSplitIsUnpinned() throws {
        let (_, _, _, pair) = try pinned()
        let other = window()
        try #require(other.splits.contains { $0.id == pair.id })

        browser.unpinSplit(pair)

        #expect(other.tabs.allSatisfy { $0.pin == nil } || !other.splits.contains { $0.id == pair.id })
        #expect(Pins.defs(browser.spaceID).isEmpty)
    }

    @Test func aRestartFindsThePinnedSplitBackWithItsSizes() throws {
        let (_, _, _, pair) = try pinned()
        browser.setSplitFraction(pair.id, fraction: 0.25)
        browser.writeSession(now: true)
        Disk.drain()
        Pins.unload()

        let after = window()

        let back = try #require(after.splits.first { $0.id == pair.id })
        #expect(back.sizes == [0.25, 0.75])
        #expect(back.axis == pair.axis)
        let pages = back.tabs.compactMap { id in after.tabs.first { $0.id == id } }
        #expect(pages.map { $0.home?.absoluteString } == ["https://pond.example/", "https://reeds.example/"])
        #expect(pages.allSatisfy { $0.pin != nil })
    }

    @Test func theSessionKeepsAPinnedSplitOutOfItsSplits() throws {
        _ = try pinned()

        let shape = try #require(browser.allRows()[browser.spaceID.uuidString])

        #expect(shape.splits.isEmpty)
        #expect(shape.tabs.filter { $0.pin != nil }.count == 2)
    }

    @Test func unpinningASplitLeavesAnOrdinarySplitInTheTabList() throws {
        let (left, right, loose, pair) = try pinned()

        browser.unpinSplit(pair)

        #expect(left.pin == nil && right.pin == nil)
        #expect(browser.split(for: left)?.tabs == [left.id, right.id])
        #expect(browser.tabs.map(\.id) == [left.id, right.id, loose.id])
        #expect(Pins.defs(browser.spaceID).isEmpty)
    }

    @Test func separatingAPinnedSplitLeavesThePageInFrontAsATabAndTheOtherAsAPin() throws {
        let (left, right, _, _) = try pinned()

        browser.detachSplit(right)

        #expect(right.pin == nil)
        #expect(left.pin != nil)
        #expect(browser.splits.isEmpty)
        #expect(Pins.defs(browser.spaceID).map(\.split) == [nil])
    }

    @Test func closingAPaneOfAPinnedSplitLeavesThatPageAsATab() throws {
        let (left, right, _, _) = try pinned()
        browser.select(left)

        browser.leaveSplit(left)

        #expect(left.pin == nil)
        #expect(right.pin != nil)
        #expect(browser.tabs.contains { $0.id == left.id })
        #expect(browser.activeID == right.id)
    }

    @Test func draggingAPageOutIntoTheTabsLeavesItAnOrdinaryTab() throws {
        let (left, right, loose, _) = try pinned()

        browser.dropTabIntoStrip(right, before: nil)

        #expect(right.pin == nil)
        #expect(left.pin != nil)
        #expect(browser.splits.isEmpty)
        #expect(browser.tabs.contains { $0.id == loose.id })
    }

    @Test func unpinningOnePageTakesItOutOfTheSplit() throws {
        let (left, right, _, _) = try pinned()

        browser.unpin(left)

        #expect(left.pin == nil)
        #expect(right.pin != nil)
        #expect(browser.splits.isEmpty)
    }

    @Test func pinningAPageOfAPinnedSplitAgainChangesNothing() throws {
        let (left, _, _, pair) = try pinned()

        browser.pin(left)

        #expect(browser.splits.contains { $0.id == pair.id })
    }

    @Test func closeOnAPinnedSplitPutsBothPagesDownAndKeepsThePin() throws {
        let (left, right, loose, pair) = try pinned()
        browser.select(right)

        browser.close(right)

        #expect(left.pin != nil && right.pin != nil)
        #expect(browser.splits.contains { $0.id == pair.id })
        #expect(browser.tabs.contains { $0.id == right.id })
        #expect(browser.tabs.contains { $0.id == loose.id })
        #expect(!pair.contains(try #require(browser.activeID)))
    }

    @Test func aTabDroppedOnAPinnedSplitMakesASplitOfItsOwnBesideACopy() throws {
        let (left, _, loose, pair) = try pinned()

        browser.replacePage(left, with: loose)

        #expect(browser.splits.first { $0.id == pair.id }?.tabs == pair.tabs)
        let made = try #require(browser.split(for: loose))
        #expect(made.id != pair.id)
        #expect(made.tabs.allSatisfy { id in browser.tabs.first { $0.id == id }?.pin == nil })
    }

    @Test func aPinnedSplitKeptInEverySpaceTakesBothPagesWithIt() throws {
        browser.prefs.usesSpaces = true
        browser.prefs.sharesPins = true
        let (left, right, _, pair) = try pinned()

        browser.shareSplit(pair, everywhere: true)

        #expect(left.everywhere && right.everywhere)
        #expect(browser.splits.contains { $0.id == pair.id })
        #expect(Pins.shared().map(\.split?.id) == [pair.id, pair.id])
        #expect(Pins.defs(browser.spaceID).isEmpty)

        browser.shareSplit(pair, everywhere: false)

        #expect(!left.everywhere && !right.everywhere)
        #expect(browser.splits.contains { $0.id == pair.id })
        #expect(Pins.defs(browser.spaceID).map(\.split?.id) == [pair.id, pair.id])
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PinnedSplitPressTests {
    private var browser: Browser!

    init() {
        keepSettings("splitView")
        addTeardownBlock { self.browser?.closeAll(); self.browser = nil }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.splitView = true
        browser.closeAll()
    }

    private func page(_ name: String) -> Tab {
        let tab = browser.makeTab()
        browser.prepare(tab)
        tab.restore(url: URL(string: "https://\(name).example/")!, title: name)
        return tab
    }

    @Test func pressingThePinnedSplitComesBackToThePageLastFocused() throws {
        let left = page("pond"), right = page("reeds"), loose = page("frogs")
        browser.showRow([left, right, loose], active: left.id)
        let pair = TabSplit(tabs: [left.id, right.id], focused: right.id)
        browser.putBackSplit(pair)
        browser.pinSplit(pair)
        browser.select(loose)

        browser.select(browser.pinTarget(left))

        #expect(browser.activeID == right.id)
        #expect(browser.activeSplit?.id == pair.id)
    }
}

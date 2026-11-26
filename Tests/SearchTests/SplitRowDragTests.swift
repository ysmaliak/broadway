import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SplitRowDragTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var stages: [SplitStageView] = []
    private var restorePreferences: (() -> Void)?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for stage in stages { stage.returnBorrowedPages() }
        for window in windows {
            window.contentView = nil
            window.close()
        }
        for browser in browsers {
            browser.window = nil
            browser.cancelTabEdit()
            for tab in browser.tabs where tab.pin != nil { browser.unpin(tab) }
            browser.closeAll()
        }
        restorePreferences?()
        windows.removeAll()
        browsers.removeAll()
    }

    private struct World {
        let browser: Browser
        let loose: [Tab]
        let left: Tab
        let right: Tab
        let work: UUID
        let workTabs: [Tab]
        let outer: UUID
        let inner: UUID
        let innerTab: Tab
    }

    private func makeBrowser() -> Browser {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.addressBar, prefs.sideWidth, prefs.newTabPlace,
                            prefs.newTabsAtBottom)
            restorePreferences = {
                (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.addressBar, prefs.sideWidth, prefs.newTabPlace,
                 prefs.newTabsAtBottom) = previous
            }
        }
        prefs.usesTabGroups = true
        prefs.splitView = true
        prefs.usesSpaces = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        prefs.newTabsAtBottom = true
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Split drag fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        return browser
    }

    private func world(window undoable: Bool = true) throws -> World {
        let browser = makeBrowser()
        let names = ["Loose A", "Left", "Right", "Loose B", "Work 1", "Work 2", "Outer 1", "Inner 1"]
        for (index, name) in names.enumerated() {
            if index > 0 || browser.tabs.isEmpty { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(name.replacingOccurrences(of: " ", with: "-"))")!, title: name)
        }
        let tabs = browser.tabs
        let named = { (name: String) in tabs.first { $0.title == name }! }
        let work = try #require(browser.quietly { browser.newFolder(with: [named("Work 1"), named("Work 2")], named: "Work", editing: false) })
        let outer = try #require(browser.quietly { browser.newFolder(with: [named("Outer 1")], named: "Outer", editing: false) })
        let inner = try #require(browser.quietly { browser.newFolder(with: [named("Inner 1")], named: "Inner", editing: false) })
        browser.quietly { browser.nest(inner, in: outer) }
        browser.quietly { browser.pair(named("Right"), with: named("Left"), onLeft: false) }
        browser.editingGroupID = nil
        browser.select(named("Loose A"))
        if undoable {
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 400),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            windows.append(window)
            browser.window = window
        }
        let world = World(browser: browser, loose: [named("Loose A"), named("Loose B")], left: named("Left"), right: named("Right"),
                          work: work, workTabs: [named("Work 1"), named("Work 2")], outer: outer, inner: inner, innerTab: named("Inner 1"))
        #expect(paired(world))
        #expect(browser.group(of: world.left) == nil)
        return world
    }

    private func paired(_ world: World) -> Bool {
        world.browser.splits.contains { $0.tabs == [world.left.id, world.right.id] }
            && Browser.holds(world.browser.splits.first { $0.contains(world.left.id) }!, in: world.browser.tabs)
    }

    private func members(_ world: World, _ group: UUID) -> [Tab.ID] {
        world.browser.tabs(in: group).map(\.id)
    }

    private func gesture(_ browser: Browser, _ body: () -> Void) {
        let undo = browser.window?.undoManager
        undo?.beginUndoGrouping()
        browser.beginGesture()
        body()
        browser.endGesture()
        undo?.endUndoGrouping()
    }

    private func undone(_ world: World, back before: Browser.Arrangement) throws {
        let undo = try #require(world.browser.window?.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        let now = world.browser.arrangement
        #expect(now.order == before.order)
        #expect(now.placings == before.placings)
        #expect(paired(world), "the pair is a pair again")
    }

    @Test func aPairLetGoOnAFolderGoesInWholeAndStaysAPair() throws {
        let world = try world()
        let before = world.browser.arrangement
        gesture(world.browser) { world.browser.move(world.left, toGroup: GroupDropTarget(group: world.work)) }
        #expect(world.browser.group(of: world.left) == world.work)
        #expect(world.browser.group(of: world.right) == world.work)
        #expect(paired(world))
        #expect(members(world, world.work).suffix(2) == [world.left.id, world.right.id])
        try undone(world, back: before)
        #expect(world.browser.group(of: world.left) == nil)
    }

    @Test func eitherHalfCarriesThePair() throws {
        let world = try world()
        world.browser.move(world.right, toGroup: GroupDropTarget(group: world.work, member: world.workTabs[0].id))
        #expect(members(world, world.work) == [world.left.id, world.right.id] + world.workTabs.map(\.id))
        #expect(paired(world))
    }

    @Test func aPairGoesBetweenTheRowsOfAFolder() throws {
        let world = try world()
        world.browser.move(world.left, toGroup: GroupDropTarget(group: world.work, member: world.workTabs[0].id, after: true))
        #expect(members(world, world.work) == [world.workTabs[0].id, world.left.id, world.right.id, world.workTabs[1].id])
        #expect(paired(world))
    }

    @Test func aPairGoesIntoAFolderInsideAFolder() throws {
        let world = try world()
        let before = world.browser.arrangement
        gesture(world.browser) { world.browser.move(world.left, toGroup: GroupDropTarget(group: world.inner)) }
        #expect(world.browser.group(of: world.left) == world.inner)
        #expect(world.browser.group(of: world.right) == world.inner)
        #expect(paired(world))
        try undone(world, back: before)
    }

    @Test func aPairGoesFromOneFolderToAnother() throws {
        let world = try world()
        world.browser.quietly { world.browser.move(world.left, toGroup: GroupDropTarget(group: world.work)) }
        let before = world.browser.arrangement
        gesture(world.browser) { world.browser.move(world.left, toGroup: GroupDropTarget(group: world.outer)) }
        #expect(world.browser.group(of: world.left) == world.outer)
        #expect(world.browser.group(of: world.right) == world.outer)
        #expect(members(world, world.work) == world.workTabs.map(\.id))
        #expect(paired(world))
        try undone(world, back: before)
        #expect(world.browser.group(of: world.right) == world.work)
    }

    @Test func aPairComesOutOfAFolderIntoTheLooseList() throws {
        let world = try world()
        world.browser.quietly { world.browser.move(world.left, toGroup: GroupDropTarget(group: world.work)) }
        let before = world.browser.arrangement
        gesture(world.browser) { world.browser.moveOut(world.left, before: .tab(world.loose[1].id)) }
        #expect(world.browser.group(of: world.left) == nil)
        #expect(world.browser.group(of: world.right) == nil)
        let loose = world.browser.tabs(in: nil).map(\.id)
        #expect(loose.firstIndex(of: world.right.id).map { loose[$0 + 1] } == world.loose[1].id)
        #expect(paired(world))
        try undone(world, back: before)
    }

    @Test func aPairMovesUpAndDownAmongTheRowsOfItsFolder() throws {
        let world = try world()
        world.browser.quietly { world.browser.move(world.left, toGroup: GroupDropTarget(group: world.work)) }
        let before = world.browser.arrangement
        gesture(world.browser) {
            world.browser.move(world.left, toGroup: GroupDropTarget(group: world.work, member: world.workTabs[0].id))
        }
        #expect(members(world, world.work) == [world.left.id, world.right.id] + world.workTabs.map(\.id))
        #expect(paired(world))
        try undone(world, back: before)
        #expect(members(world, world.work) == world.workTabs.map(\.id) + [world.left.id, world.right.id])
    }

    @Test func aPairMovesAmongTheLooseRows() throws {
        let world = try world()
        let before = world.browser.arrangement
        gesture(world.browser) { world.browser.moveLoose(world.left, before: nil) }
        let loose = world.browser.tabs(in: nil).map(\.id)
        #expect(loose.suffix(2) == [world.left.id, world.right.id])
        #expect(paired(world))
        try undone(world, back: before)
    }

    @Test func aPairHeldOnATabMakesAFolderOfAllThree() throws {
        let world = try world()
        let before = world.browser.arrangement
        var made: UUID?
        gesture(world.browser) { made = world.browser.newFolder(with: [world.loose[1], world.left], editing: false) }
        let folder = try #require(made)
        #expect(Set(members(world, folder)) == [world.loose[1].id, world.left.id, world.right.id])
        #expect(paired(world))
        try undone(world, back: before)
        #expect(!world.browser.tabGroups.contains { $0.id == folder })
    }

    @Test func aPairShiftedALevelGoesWhole() throws {
        let world = try world()
        world.browser.quietly { world.browser.move(world.left, toGroup: GroupDropTarget(group: world.inner)) }
        let before = world.browser.arrangement
        gesture(world.browser) { #expect(world.browser.shiftLevel(world.left, by: -1)) }
        #expect(world.browser.group(of: world.left) == world.outer)
        #expect(world.browser.group(of: world.right) == world.outer)
        #expect(paired(world))
        try undone(world, back: before)
    }

    @Test func aLiveFolderTakesNoPairByHand() throws {
        let world = try world()
        var live = TabGroup(id: UUID(), name: "News", collapsed: false)
        live.live = true
        world.browser.tabGroups.append(live)
        world.browser.move(world.left, toGroup: GroupDropTarget(group: live.id))
        world.browser.move(world.left, toGroup: live.id)
        #expect(world.browser.group(of: world.left) == nil)
        #expect(paired(world))
    }

    @Test func thePairsMenuMovesItToAFolderAndBackOut() throws {
        let world = try world()
        for half in [world.right, world.left] {
            let menu = TabMenuItems.menu(browser: world.browser, tab: half, close: {})
            let folder = try #require(menuEntry("Folder", in: menu)?.submenu)
            let item = try #require(folder.items.first { $0.title.trimmingCharacters(in: .whitespaces) == "Inner" })
            #expect(item.isEnabled)
            NSApp.sendAction(try #require(item.action), to: item.target, from: item)
            #expect(world.browser.group(of: world.left) == world.inner)
            #expect(world.browser.group(of: world.right) == world.inner)
            #expect(paired(world))
            let again = TabMenuItems.menu(browser: world.browser, tab: half, close: {})
            let out = try #require(menuEntry("Remove from Folder", in: again))
            NSApp.sendAction(try #require(out.action), to: out.target, from: out)
            #expect(world.browser.group(of: world.left) == nil)
            #expect(world.browser.group(of: world.right) == nil)
            #expect(paired(world))
        }
    }

    private func menuEntry(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        for entry in menu.items {
            if entry.title == title { return entry }
            if let inner = entry.submenu, let found = menuEntry(title, in: inner) { return found }
        }
        return nil
    }

    @Test func aPairTornOutGoesToTheOtherWindowAsAPair() throws {
        let world = try world()
        let other = makeBrowser()
        other.newTab()
        other.tabs.last?.restore(url: URL(string: "about:blank#elsewhere")!, title: "Elsewhere")
        let pair = try #require(world.browser.split(for: world.left))
        world.browser.moveToWindow(pairOf: world.right, other)
        #expect(!world.browser.tabs.contains { $0 === world.left || $0 === world.right })
        let landed = try #require(other.split(for: world.left))
        #expect(landed.tabs == pair.tabs)
        #expect(Browser.holds(landed, in: other.tabs))
    }

    @Test func everyPickedTabGoesToTheOtherWindowInItsOrderAndOnlyTheFirstWakes() throws {
        let world = try world()
        let browser = world.browser
        let other = makeBrowser()
        Shared.prefs.newTabsAtBottom = false
        other.newTab()
        other.tabs.last?.restore(url: URL(string: "about:blank#elsewhere")!, title: "Elsewhere")
        browser.extendTabSelection(to: world.loose[1], modifiers: .command)
        let chosen = browser.menuTabs(for: world.loose[1])
        #expect(chosen.map(\.id) == world.loose.map(\.id))

        browser.moveToWindow(chosen, other)

        #expect(!browser.tabs.contains { $0 === world.loose[0] || $0 === world.loose[1] })
        #expect(other.tabs.filter { $0 === world.loose[0] || $0 === world.loose[1] }.map(\.id) == world.loose.map(\.id))
        #expect(other.active === world.loose[0])
        #expect(world.loose[1].asleep)
    }

    private func otherWindow(_ names: [String], folder: String) throws -> (Browser, [Tab], UUID) {
        let other = makeBrowser()
        for (index, name) in names.enumerated() {
            if index > 0 || other.tabs.isEmpty { other.newTab() }
            other.tabs.last?.restore(url: URL(string: "about:blank#\(name.replacingOccurrences(of: " ", with: "-"))")!, title: name)
        }
        let made = other.tabs
        let id = try #require(other.quietly { other.newFolder(with: [made.last!], named: folder, editing: false) })
        other.editingGroupID = nil
        return (other, made, id)
    }

    @Test func aPairTornOutIsPutIntoAFolderInTheOtherWindow() throws {
        let world = try world()
        let (other, made, there) = try otherWindow(["There A", "There B", "There 1"], folder: "There")
        world.browser.moveToWindow(pairOf: world.left, other)
        other.placeTorn(world.left, .folder(GroupDropTarget(group: there)))
        #expect(other.tabs(in: there).map(\.id) == [made[2].id, world.left.id, world.right.id])
        let landed = try #require(other.split(for: world.left))
        #expect(landed.tabs == [world.left.id, world.right.id])
        #expect(Browser.holds(landed, in: other.tabs))
        #expect(!world.browser.tabs.contains { $0 === world.left || $0 === world.right })
        #expect(world.browser.split(for: world.left) == nil)
    }

    @Test func aPairTornOutIsPutBeforeALooseRowInTheOtherWindow() throws {
        let world = try world()
        let (other, made, _) = try otherWindow(["There A", "There B", "There 1"], folder: "There")
        world.browser.moveToWindow(pairOf: world.right, other)
        other.placeTorn(world.left, .loose(LoosePlace(before: .tab(made[1].id))))
        #expect(other.tabs(in: nil).map(\.id) == [made[0].id, world.left.id, world.right.id, made[1].id])
        let landed = try #require(other.split(for: world.left))
        #expect(landed.tabs == [world.left.id, world.right.id])
        #expect(Browser.holds(landed, in: other.tabs))
        #expect(!world.browser.tabs.contains { $0 === world.left || $0 === world.right })
    }

    private func forms(_ tab: Tab, unsaved: Bool) async {
        await withCheckedContinuation { continuation in
            tab.web.evaluateInSearch("window.__officeForms = {unsaved: () => \(unsaved)}") { _ in continuation.resume() }
        }
    }

    private func separateSpace(_ world: World) -> Space {
        let browser = world.browser
        let second = Space(id: UUID(), name: "Clients", colour: 1, sharesSignIns: false)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        Spaces.known[second.id] = second
        return second
    }

    private func arrived(_ world: World, in space: Space) -> Bool {
        world.browser.parked[space.id]?.tabs.contains { $0 === world.left } == true
            && world.browser.parked[space.id]?.tabs.contains { $0 === world.right } == true
    }

    @Test func aPairGoesWholeToASpaceWithItsOwnAccountsAndOneUndoBringsItBack() async throws {
        let world = try world()
        let browser = world.browser
        let second = separateSpace(world)
        defer { Spaces.known[second.id] = nil; Ask.testing = nil; Ask.asked = [] }
        Ask.testing = false
        Ask.asked = []
        await forms(world.left, unsaved: false)
        await forms(world.right, unsaved: false)
        #expect(world.left.store !== Spaces.store(for: second.id))
        let pair = try #require(browser.split(for: world.left))
        let before = browser.arrangement
        gesture(browser) { browser.stackedDrop(world.left, onto: second.id) }
        try await waitUntil("the pair did not reach the other space") { self.arrived(world, in: second) }
        #expect(Ask.asked.isEmpty)
        #expect(!browser.tabs.contains { $0 === world.left || $0 === world.right })
        let row = try #require(browser.parked[second.id])
        #expect(row.splits.contains { $0.id == pair.id })
        #expect(Browser.holds(pair, in: row.tabs))
        try undone(world, back: before)
        #expect(browser.parked[second.id]?.tabs.contains { $0 === world.left || $0 === world.right } != true)
    }

    @Test func aPairWithUnsavedEntriesInOneHalfAsksOnceAndMovesWholeOrNotAtAll() async throws {
        let world = try world()
        let browser = world.browser
        let second = separateSpace(world)
        defer { Spaces.known[second.id] = nil; Ask.testing = nil; Ask.asked = [] }
        await forms(world.left, unsaved: false)
        await forms(world.right, unsaved: true)
        let pair = try #require(browser.split(for: world.left))
        let before = browser.arrangement

        Ask.testing = false
        Ask.asked = []
        gesture(browser) { browser.stackedDrop(world.left, onto: second.id) }
        try await waitUntil("the question was not asked") { !Ask.asked.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        #expect(Ask.asked == ["Move tabs?"])
        #expect(browser.tabs.contains { $0 === world.left } && browser.tabs.contains { $0 === world.right })
        #expect(paired(world))
        #expect(browser.arrangement.order == before.order)
        #expect(browser.parked[second.id]?.tabs.contains { $0 === world.left || $0 === world.right } != true)

        Ask.testing = true
        Ask.asked = []
        gesture(browser) { browser.stackedDrop(world.right, onto: second.id) }
        try await waitUntil("the pair did not reach the other space") { self.arrived(world, in: second) }
        #expect(Ask.asked == ["Move tabs?"])
        let row = try #require(browser.parked[second.id])
        #expect(row.splits.contains { $0.id == pair.id })
        #expect(Browser.holds(pair, in: row.tabs))
        try undone(world, back: before)
    }

    @Test func aPairWithAnExtensionPageIsRefusedWhole() async throws {
        let world = try world()
        let browser = world.browser
        let second = Space(id: UUID(), name: "Elsewhere", colour: 1, sharesSignIns: true)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        world.right.restore(url: URL(string: "chrome-extension://abcdefghijklmnop/popup.html")!, title: "Right")
        let before = browser.arrangement
        gesture(browser) { browser.stackedDrop(world.left, onto: second.id) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(browser.tabs.contains { $0 === world.left } && browser.tabs.contains { $0 === world.right })
        #expect(paired(world))
        #expect(browser.arrangement.order == before.order)
        #expect(browser.parked[second.id]?.tabs.isEmpty != false)
    }

    @Test func aPairLetGoOnAnotherSpaceGoesThereAsAPairAndUndoBringsItBack() async throws {
        let world = try world()
        let browser = world.browser
        let second = Space(id: UUID(), name: "Elsewhere", colour: 1, sharesSignIns: true)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        let pair = try #require(browser.split(for: world.left))
        let before = browser.arrangement
        gesture(browser) { browser.stackedDrop(world.left, onto: second.id) }
        try await waitUntil("the pair did not reach the other space") {
            browser.parked[second.id]?.tabs.contains { $0 === world.right } == true
        }
        #expect(!browser.tabs.contains { $0 === world.left || $0 === world.right })
        let row = try #require(browser.parked[second.id])
        #expect(row.splits.contains { $0.id == pair.id })
        #expect(Browser.holds(pair, in: row.tabs))
        try undone(world, back: before)
    }

    @Test func theMenusSpaceItemMovesThePairWholeAndUndoBringsItBack() async throws {
        let world = try world()
        let browser = world.browser
        let second = Space(id: UUID(), name: "Elsewhere", colour: 1, sharesSignIns: true)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        let pair = try #require(browser.split(for: world.left))
        let before = browser.arrangement
        let menu = TabMenuItems.menu(browser: browser, tab: world.right, close: {})
        let item = try #require(menuEntry("Elsewhere", in: menu))

        gesture(browser) { NSApp.sendAction(item.action!, to: item.target, from: item) }

        try await waitUntil("the pair did not reach the other space") { self.arrived(world, in: second) }
        #expect(!browser.tabs.contains { $0 === world.left || $0 === world.right })
        let row = try #require(browser.parked[second.id])
        #expect(row.splits.contains { $0.id == pair.id })
        #expect(Browser.holds(pair, in: row.tabs))
        try undone(world, back: before)
    }

    @Test func aPickedTabWithOneHalfOfAPairTakesTheWholePairToTheSpace() async throws {
        let world = try world()
        let browser = world.browser
        let second = Space(id: UUID(), name: "Elsewhere", colour: 1, sharesSignIns: true)
        browser.prefs.usesSpaces = true
        browser.spaces.append(second)
        let pair = try #require(browser.split(for: world.left))
        browser.select(world.loose[1])
        browser.extendTabSelection(to: world.right, modifiers: .command)

        browser.move(browser.menuTabs(for: world.right), toSpace: second.id)

        try await waitUntil("the tabs did not reach the other space") {
            self.arrived(world, in: second) && browser.parked[second.id]?.tabs.contains { $0 === world.loose[1] } == true
        }
        let row = try #require(browser.parked[second.id])
        #expect(row.splits.contains { $0.id == pair.id })
        #expect(Browser.holds(pair, in: row.tabs))
        #expect(!browser.tabs.contains { $0 === world.left || $0 === world.right || $0 === world.loose[1] })
    }

    @Test func theMenusWindowItemMovesThePairWhole() throws {
        let world = try world()
        let other = makeBrowser()
        other.newTab()
        other.tabs.last?.restore(url: URL(string: "about:blank#elsewhere")!, title: "Elsewhere")
        let pair = try #require(world.browser.split(for: world.left))

        world.browser.moveToWindow([world.right], other)

        #expect(!world.browser.tabs.contains { $0 === world.left || $0 === world.right })
        let landed = try #require(other.split(for: world.left))
        #expect(landed.tabs == pair.tabs)
        #expect(Browser.holds(landed, in: other.tabs))
    }

    private func column(_ world: World) async throws -> NSWindow {
        world.browser.window = nil
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: world.browser.prefs.sideWidth, height: 640),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: world.browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        try await settle(window)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        var previous: [NSRect] = []
        var since = ProcessInfo.processInfo.systemUptime
        try await waitUntil("the column did not settle") {
            window.contentView?.layoutSubtreeIfNeeded()
            let now = (window.contentView?.kitSubviews(of: SplitSignView.self) ?? []).map { $0.convert($0.bounds, to: nil) }
            guard !now.isEmpty else { return false }
            if now != previous {
                previous = now
                since = ProcessInfo.processInfo.systemUptime
            }
            return ProcessInfo.processInfo.systemUptime - since >= 0.3
        }
    }

    private func waitUntil(_ message: String, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("\(message)", sourceLocation: sourceLocation)
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }

    private func sign(_ window: NSWindow) throws -> SplitSignView {
        try #require(window.contentView?.kitSubviews(of: SplitSignView.self).first { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0 })
    }

    private func heading(_ name: String, in window: NSWindow) -> NSRect? {
        let view = window.contentView?.kitSubviews(of: GroupHeadingView.self).first { $0.group?.name == name && !$0.isHiddenOrHasHiddenAncestor }
        return view.map { $0.convert($0.bounds, to: nil) }
    }

    private func row(_ tab: Tab, in window: NSWindow) throws -> NSRect {
        let view = try #require(window.contentView?.kitSubviews(of: TabRowView.self).first { $0.tab?.id == tab.id && !$0.isHiddenOrHasHiddenAncestor })
        return view.convert(view.bounds, to: nil)
    }

    private func chip(_ half: Int, in window: NSWindow) throws -> NSPoint {
        let sign = try sign(window)
        let chip = sign.item.chips[half]
        let rect = chip.convert(chip.bounds, to: nil)
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func drag(from start: NSPoint, to end: NSPoint, in window: NSWindow) async throws {
        try await drag(from: start, toward: { end }, in: window)
    }

    private func drag(from start: NSPoint, toward aim: () throws -> NSPoint, in window: NSWindow) async throws {
        try await send(.leftMouseDown, at: start, in: window)
        var last = start
        let lifted = NSPoint(x: start.x, y: start.y - 8)
        for step in 1...4 {
            try await send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - 2 * CGFloat(step)), in: window)
        }
        last = lifted
        try await Task.sleep(for: .milliseconds(300))
        window.contentView?.layoutSubtreeIfNeeded()
        let end = try aim()
        for target in [end] {
            let steps = max(1, Int((hypot(target.x - last.x, target.y - last.y) / 4).rounded(.up)))
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                try await send(.leftMouseDragged, at: NSPoint(x: last.x + (target.x - last.x) * f, y: last.y + (target.y - last.y) * f), in: window)
            }
            last = target
        }
        try await Task.sleep(for: .milliseconds(150))
        try await send(.leftMouseUp, at: last, in: window)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) async throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(30))
    }

    @Test func theSplitRowDraggedOntoAFolderHeadingGoesIn() async throws {
        let world = try world(window: false)
        let window = try await column(world)
        let work = try #require(heading("Work", in: window))
        try await drag(from: try chip(0, in: window), to: NSPoint(x: work.midX, y: work.midY), in: window)
        try await waitUntil("the pair did not land in Work") { world.browser.group(of: world.left) == world.work }
        #expect(world.browser.group(of: world.right) == world.work)
        #expect(paired(world))
        #expect(world.browser.activeID == world.loose[0].id || world.browser.split(for: world.left)?.contains(world.browser.activeID ?? UUID()) == true)
        try await settle(window)
        #expect(try sign(window).alphaValue == 1, "the row is shown again where it landed")
    }

    @Test func theSplitRowInFrontDraggedByItsFocusedHalfGoesInAndOpensNoAddress() async throws {
        let world = try world(window: false)
        world.browser.select(world.left)
        world.browser.focusPane(world.left)
        let window = try await column(world)
        let work = try #require(heading("Work", in: window))
        try await drag(from: try chip(0, in: window), to: NSPoint(x: work.midX, y: work.midY), in: window)
        try await waitUntil("the pair did not land in Work") { world.browser.group(of: world.left) == world.work }
        #expect(paired(world))
        #expect(world.browser.activeID == world.left.id)
        #expect(world.browser.editingTab == nil)
    }

    @Test func theSplitRowPressedOnItsRightHalfStillMovesWhole() async throws {
        let world = try world(window: false)
        let window = try await column(world)
        let inner = try #require(heading("Inner", in: window))
        try await drag(from: try chip(1, in: window), to: NSPoint(x: inner.midX, y: inner.midY), in: window)
        try await waitUntil("the pair did not land in Inner") { world.browser.group(of: world.left) == world.inner }
        #expect(world.browser.group(of: world.right) == world.inner)
        #expect(paired(world))
    }

    @Test func theSplitRowDraggedAboveTheFirstLooseRowMovesThere() async throws {
        let world = try world(window: false)
        let window = try await column(world)
        try await drag(from: try chip(0, in: window), toward: {
            let a = try self.row(world.loose[0], in: window)
            return NSPoint(x: a.midX, y: a.maxY - 4)
        }, in: window)
        try await waitUntil("the pair did not move above Loose A") {
            world.browser.tabs(in: nil).map(\.id) == [world.left.id, world.right.id, world.loose[0].id, world.loose[1].id]
        }
        #expect(paired(world))
    }

    private func columnBesideStage(_ world: World) async throws -> (NSWindow, SplitStageView) {
        world.browser.window = nil
        let side = world.browser.prefs.sideWidth
        let size = NSSize(width: side + 600, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        let column = SideColumnView(browser: world.browser)
        column.frame = NSRect(x: 0, y: 0, width: side, height: size.height)
        let stage = SplitStageView(browser: world.browser)
        stage.frame = NSRect(x: side, y: 0, width: 600, height: size.height)
        content.addSubview(column)
        content.addSubview(stage)
        window.contentView = content
        world.browser.window = window
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        stages.append(stage)
        stage.update(find: world.browser.findState, corner: Metrics.pageRadius, immersed: nil, hold: nil, card: nil)
        try await settle(window)
        return (window, stage)
    }

    private func sendAtOnce(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        window.sendEvent(event)
    }

    @Test func aTabFlungToThePagesEdgeAndHeldStillSplitsThePageThoughThePageCameBackAfterTheLastMove() async throws {
        let world = try world(window: false)
        let (window, stage) = try await columnBesideStage(world)
        let front = world.loose[0], carried = world.loose[1]
        #expect(world.browser.activeID == front.id)
        let start = try row(carried, in: window)
        let press = NSPoint(x: start.midX, y: start.midY)
        try await send(.leftMouseDown, at: press, in: window)
        for step in 1...4 {
            try await send(.leftMouseDragged, at: NSPoint(x: press.x, y: press.y - 2 * CGFloat(step)), in: window)
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(world.browser.activeID == carried.id, "pressing the row brings its page forward")
        let lifted = NSPoint(x: press.x, y: press.y - 8)
        let page = stage.convert(stage.bounds, to: nil)
        let edge = NSPoint(x: page.maxX - 40, y: page.midY)
        for step in 1...12 {
            let f = CGFloat(step) / 12
            try sendAtOnce(.leftMouseDragged, at: NSPoint(x: lifted.x + (edge.x - lifted.x) * f, y: lifted.y + (edge.y - lifted.y) * f), in: window)
        }
        #expect(world.browser.activeID == front.id, "the page in front came back under the hand")
        try await Task.sleep(for: .milliseconds(500))
        let side = try #require(window.contentView?.kitSubviews(of: SidePageView.self).first { !$0.embedded && !$0.isHiddenOrHasHiddenAncestor })
        #expect(side.morphCarried == carried.id)
        #expect(abs((side.morphView?.alphaValue ?? 1) - 0.4) < 0.01, "held still over the split it shows, the carried row is faded as over a page")
        try await send(.leftMouseUp, at: edge, in: window)
        try await Task.sleep(for: .milliseconds(300))
        let split = world.browser.split(for: carried)
        #expect(split?.contains(front.id) == true, "let go on the page's right edge, the tab is beside that page")
        #expect(split?.tabs.last == carried.id)
    }

    @Test func aLiveFolderRefusesTheSplitRow() async throws {
        let world = try world(window: false)
        var live = TabGroup(id: UUID(), name: "News", collapsed: false)
        live.live = true
        world.browser.tabGroups.append(live)
        let window = try await column(world)
        let order = world.browser.tabs.map(\.id)
        guard let news = heading("News", in: window) else { return }
        try await drag(from: try chip(0, in: window), to: NSPoint(x: news.midX, y: news.midY), in: window)
        try await Task.sleep(for: .milliseconds(400))
        #expect(world.browser.group(of: world.left) == nil)
        #expect(world.browser.tabs.map(\.id) == order)
        #expect(paired(world))
    }
}

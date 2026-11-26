import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ManualFolderTests {
    private func browser(_ count: Int) -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        for number in 0..<count {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        addTeardownBlock { @MainActor in browser.closeAll() }
        return browser
    }

    private func names(_ browser: Browser) -> [String] { browser.tabs.map(\.title) }

    private func items(_ browser: Browser) -> [Browser.ListItem] { browser.listItems(browser.displayedTabs) }

    private func group(_ id: UUID, in browser: Browser) -> TabGroup? { browser.tabGroups.first { $0.id == id } }

    @Test func newFolderFromTheMenuIsInTheListAtTheTopOfTheLooseTabs() throws {
        let browser = browser(3)
        let tabs = browser.tabs

        Command.named("tabs.newFolder")?.run(browser)

        let made = try #require(browser.tabGroups.last)
        #expect(!made.pinned)
        #expect(!FolderTree.raised(made.id, in: browser.tabGroups))
        #expect(browser.pinnedFolders().isEmpty)
        #expect(items(browser) == [.folder(made.id)] + tabs.map { .tab($0.id) })
        #expect(browser.editingGroupID == made.id)
        #expect(names(browser) == ["0", "1", "2"])
    }

    @Test func theNewestEmptyFolderIsAboveAnOlderOneAndAboveAFolderWithTabs() throws {
        let browser = browser(3)
        let tabs = browser.tabs
        let filled = browser.addTabGroup(containing: tabs[1])
        let older = try #require(browser.newFolder(named: "Older", editing: false))

        let newer = try #require(browser.newFolder(named: "Newer", editing: false))

        #expect(items(browser) == [.folder(newer), .folder(older), .tab(tabs[0].id), .folder(filled), .tab(tabs[2].id)])
    }

    @Test func aNewFolderStaysBelowTheRaisedOnes() throws {
        let browser = browser(3)
        let tabs = browser.tabs
        let raised = browser.addTabGroup(containing: tabs[2], pinned: true)

        let made = try #require(browser.newFolder(named: "Made", editing: false))

        #expect(browser.pinnedFolders().map(\.id) == [raised])
        #expect(items(browser) == [.folder(made), .tab(tabs[0].id), .tab(tabs[1].id)])
        #expect(FolderTree.ordered(browser.tabGroups).map(\.id) == [raised, made])
    }

    @Test func aFolderMadeFromATabSitsWhereThatTabWas() {
        let browser = browser(4)
        let tabs = browser.tabs

        let made = browser.addTabGroup(containing: tabs[2])

        #expect(names(browser) == ["0", "1", "2", "3"])
        #expect(items(browser) == [.tab(tabs[0].id), .tab(tabs[1].id), .folder(made), .tab(tabs[3].id)])
        #expect(group(made, in: browser)?.pinned == false)
    }

    @Test func aFolderMadeFromPickedTabsSitsWhereTheFirstPickedWas() throws {
        let browser = browser(4)
        let tabs = browser.tabs

        let made = try #require(browser.newFolder(with: [tabs[2], tabs[0]], named: "Picked", editing: false))

        #expect(names(browser) == ["1", "2", "0", "3"])
        #expect(items(browser) == [.tab(tabs[1].id), .folder(made), .tab(tabs[3].id)])
    }

    @Test func aFolderMadeInsideARaisedFolderIsRaisedAndInsideOneInTheListIsNot() throws {
        let browser = browser(3)
        let tabs = browser.tabs
        let raised = browser.addTabGroup(containing: tabs[0], pinned: true)
        let listed = browser.addTabGroup(containing: tabs[1])

        let high = try #require(browser.newFolder(inside: raised, named: "High", editing: false))
        let low = try #require(browser.newFolder(inside: listed, named: "Low", editing: false))

        #expect(group(high, in: browser)?.pinned == true)
        #expect(FolderTree.raised(high, in: browser.tabGroups))
        #expect(group(low, in: browser)?.pinned == false)
        #expect(!FolderTree.raised(low, in: browser.tabGroups))
        #expect(items(browser) == [.folder(listed), .tab(tabs[2].id)])
    }

    @Test func aTabMovedIntoAnEmptyFolderInTheListGoesToTheTopWithIt() throws {
        let browser = browser(4)
        let tabs = browser.tabs
        _ = browser.addTabGroup(containing: tabs[0], pinned: true)
        let made = try #require(browser.newFolder(named: "Made", editing: false))

        browser.move(tabs[3], toGroup: made)

        #expect(names(browser) == ["0", "3", "1", "2"])
        #expect(items(browser) == [.folder(made), .tab(tabs[1].id), .tab(tabs[2].id)])
        #expect(group(made, in: browser)?.held == false)
    }

    @Test func aFolderDroppedBeforeAnEmptyOneLandsAtTheTopOfTheTabs() throws {
        let browser = browser(4)
        let tabs = browser.tabs
        let filled = browser.addTabGroup(containing: tabs[3])
        let empty = try #require(browser.newFolder(named: "Empty", editing: false))

        browser.placeFolder(filled, pinned: false, before: .folder(empty))

        #expect(names(browser) == ["3", "0", "1", "2"])
        #expect(items(browser) == [.folder(empty), .folder(filled), .tab(tabs[0].id), .tab(tabs[1].id), .tab(tabs[2].id)])
    }

    @Test func anEmptyRaisedFolderUnpinnedLeadsTheList() throws {
        let browser = browser(2)
        let tabs = browser.tabs
        let older = try #require(browser.newFolder(named: "Older", editing: false))
        let raised = try #require(browser.newFolder(named: "Raised", editing: false, pinned: true))

        browser.setFolderPinned(raised, false)

        #expect(items(browser) == [.folder(raised), .folder(older), .tab(tabs[0].id), .tab(tabs[1].id)])
    }

    @Test func theOnlyTabOfAListFolderChangingLevelLeavesTheFolderWhereItIs() throws {
        let browser = browser(4)
        let tabs = browser.tabs
        let made = try #require(browser.newFolder(with: [tabs[2]], named: "Made", editing: false))
        let child = try #require(browser.newFolder(inside: made, named: "Child", editing: false))
        let before = items(browser)

        browser.move(tabs[2], toGroup: child)
        let inChild = items(browser)
        browser.move(tabs[2], toGroup: made)

        #expect(before == [.tab(tabs[0].id), .tab(tabs[1].id), .folder(made), .tab(tabs[3].id)])
        #expect(inChild == before)
        #expect(items(browser) == before)
        #expect(names(browser) == ["0", "1", "2", "3"])
    }

    @Test func aTabMovedIntoAFolderThatHasTabsJoinsItWhereItIs() throws {
        let browser = browser(4)
        let tabs = browser.tabs
        let made = try #require(browser.newFolder(with: [tabs[2]], named: "Made", editing: false))

        browser.move(tabs[0], toGroup: made)

        #expect(names(browser) == ["1", "2", "0", "3"])
        #expect(items(browser) == [.tab(tabs[1].id), .folder(made), .tab(tabs[3].id)])
    }

    @Test func aSavedEmptyFolderInTheListStaysAfterTheTabs() throws {
        let browser = browser(2)
        let tabs = browser.tabs
        let saved = #"{"id":"00000000-0000-0000-0000-00000000000C","name":"Old","held":true,"pinned":false}"#
        let old = try JSONDecoder().decode(TabGroup.self, from: Data(saved.utf8))
        browser.tabGroups.append(old)

        let made = try #require(browser.newFolder(named: "Made", editing: false))
        let listed = items(browser)
        browser.move(tabs[1], toGroup: old.id)

        #expect(listed == [.folder(made), .tab(tabs[0].id), .tab(tabs[1].id), .folder(old.id)])
        #expect(!old.leads)
        #expect(group(made, in: browser)?.leads == true)
        #expect(names(browser) == ["0", "1"])
        #expect(items(browser) == [.folder(made), .tab(tabs[0].id), .folder(old.id)])
    }

    @Test func theMarkOfAFolderThatLeadsSurvivesASave() throws {
        let browser = browser(1)
        let made = try #require(browser.newFolder(named: "Made", editing: false))

        let data = try JSONEncoder().encode(try #require(group(made, in: browser)))
        let back = try JSONDecoder().decode(TabGroup.self, from: data)

        #expect(back.leads)
        #expect(!back.pinned)
    }

    @Test func aSavedHandMadeFolderKeepsItsRaisedPlace() throws {
        let saved = #"{"id":"00000000-0000-0000-0000-00000000000A","name":"Work","held":true}"#
        let flagged = #"{"id":"00000000-0000-0000-0000-00000000000B","name":"Read","pinned":true}"#

        let old = try JSONDecoder().decode(TabGroup.self, from: Data(saved.utf8))
        let kept = try JSONDecoder().decode(TabGroup.self, from: Data(flagged.utf8))

        #expect(old.pinned)
        #expect(kept.pinned)
        #expect(!old.leads)
        #expect(!kept.leads)
    }

    @Test func aPreviewedSpaceListsItsEmptyFolderFirstToo() throws {
        let browser = browser(2)
        let tabs = browser.tabs
        let made = try #require(browser.newFolder(named: "Made", editing: false))
        let old = TabGroup(id: UUID(), name: "Old", collapsed: false, held: true, pinned: false)

        let listed = FolderTree.listed(tabs, group: { _ in nil }, in: browser.tabGroups + [old]) { .tab($0.id) }

        #expect(listed == [.folder(made), .tab(tabs[0].id), .tab(tabs[1].id), .folder(old.id)])
    }

    @Test func aHeadingsIconAndNameSitOnTheTabRowGridAtEveryDepth() {
        let column = Metrics.sideInset
        let pad = Metrics.folderPad
        let step = GroupHeadingView.indent

        for depth in 0...FolderTree.deepest - 1 {
            let heading = column + pad + (depth == 0 ? 0 : SidePageView.cardLead)
            let sibling = depth == 0 ? column : column + pad + CGFloat(depth - 1) * step + SidePageView.cardLead
            let member = column + pad + CGFloat(depth) * step + SidePageView.cardLead
            let icon = heading + GroupHeadingView.markLead(depth: depth) + SideLook.rowMark / 2
            let name = heading + GroupHeadingView.nameLead(depth: depth)

            #expect(icon == sibling + TabRowView.iconLead + SideLook.rowMark / 2, "depth \(depth)")
            #expect(name == sibling + TabRowView.iconLead + SideLook.rowMark + SideLook.markGap, "depth \(depth)")
            #expect(member - sibling == step, "depth \(depth)")
        }
    }

    @Test func aLaidHeadingPutsItsPartsOnTheGrid() throws {
        let browser = browser(1)
        let kinds: [TabGroup] = [
            TabGroup(id: UUID(), name: "Hand", collapsed: false),
            { var made = TabGroup(id: UUID(), name: "Trip", collapsed: false); made.ai = true; made.pinned = false; made.icon = TabIcon(emoji: "✈️"); return made }(),
            { var made = TabGroup(id: UUID(), name: "Query", collapsed: true); made.query = "query"; made.pinned = false; return made }(),
        ]

        for group in kinds {
            for depth in 0...2 {
                let heading = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 220, height: GroupHeadingView.height))
                heading.depth = depth
                heading.count = 2
                heading.show(group, in: browser)
                heading.layoutSubtreeIfNeeded()
                let parts = heading.benchParts
                let mark = try #require(parts["mark"]).frame
                let name = try #require(parts["nameHost"]).frame
                let ground = try #require(parts["ground"]).frame

                #expect(mark.midX == GroupHeadingView.markLead(depth: depth) + SideLook.rowMark / 2, "\(group.name) \(depth)")
                #expect(mark.midY == GroupHeadingView.height / 2, "\(group.name) \(depth)")
                #expect(name.minX == GroupHeadingView.nameLead(depth: depth), "\(group.name) \(depth)")
                #expect(name.midY == GroupHeadingView.height / 2, "\(group.name) \(depth)")
                #expect(name.height == SideLook.titleLine, "\(group.name) \(depth)")
                #expect(ground.minX == GroupHeadingView.inset(depth: depth), "\(group.name) \(depth)")
            }
        }
    }

    @Test func theRenameFieldPutsItsTextWhereTheNameIs() throws {
        let browser = browser(1)
        let id = try #require(browser.newFolder(named: "Made", editing: true))
        let group = try #require(group(id, in: browser))

        for depth in 0...2 {
            let heading = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 220, height: GroupHeadingView.height))
            heading.depth = depth
            heading.show(group, in: browser)
            heading.layoutSubtreeIfNeeded()
            let parts = heading.benchParts
            let field = try #require(parts["field"]).frame
            let well = try #require(parts["well"]).frame
            let name = GroupHeadingView.nameLead(depth: depth)

            #expect(field.minX + FolderEditField.textInset == name, "depth \(depth)")
            #expect(field.minY == (GroupHeadingView.height - GroupHeadingView.nameLine) / 2, "depth \(depth)")
            #expect(well.minX == name - SideLook.fieldLead, "depth \(depth)")
            #expect(well.minX > GroupHeadingView.markLead(depth: depth) + SideLook.rowMark, "depth \(depth)")
            #expect(parts["nameHost"]?.isHidden == true, "depth \(depth)")
        }
        #expect((FolderEditField().font?.fontDescriptor.symbolicTraits.contains(.bold)) == true)
    }

    @Test func aDropOnAHeadingGoesInsideFromItsNameOnAtEveryDepth() {
        for depth in 0...3 {
            #expect(FolderHeadingMetrics.inside(x: GroupHeadingView.nameLead(depth: depth), depth: depth), "depth \(depth)")
            #expect(!FolderHeadingMetrics.inside(x: GroupHeadingView.markLead(depth: depth) + SideLook.rowMark, depth: depth), "depth \(depth)")
        }
    }

    @Test func anEmptyFolderInTheListIsOneHeadingTall() throws {
        #expect(GroupHeadingView.height + 2 * Metrics.folderPad == Metrics.sideRowHeight)
        #expect(SideAir.between(.folder, .row) == Metrics.sideGap)
        #expect(SideAir.between(.divider, .folder) == Metrics.sideDividerGap)
    }
}

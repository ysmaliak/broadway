import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TabGroupDropTests {
    @Test func positionalMovesAndSourceCleanup() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        let grouped = browser.prefs.usesTabGroups
        let split = browser.prefs.splitView
        defer {
            browser.prefs.usesTabGroups = grouped
            browser.prefs.splitView = split
        }
        browser.prefs.usesTabGroups = true
        for number in 0..<6 {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(number).example/")!, title: "\(number)")
        }
        let tabs = browser.tabs
        let group = browser.addTabGroup(containing: tabs[0])
        for tab in tabs[1...2] { browser.move(tab, toGroup: group) }
        browser.move(tabs[3], toGroup: GroupDropTarget(group: group, member: tabs[0].id))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: tabs[1].id))
        let source = browser.addTabGroup(containing: tabs[5])
        let active = browser.activeID
        browser.move(tabs[5], toGroup: GroupDropTarget(group: group, member: tabs[2].id, after: true))
        #expect(browser.tabs(in: group).map(\.id) == [3, 0, 4, 1, 2, 5].map { tabs[$0].id })
        #expect(!browser.tabGroups.contains { $0.id == source })
        #expect(browser.activeID == active)

        browser.move(tabs[3], toGroup: GroupDropTarget(group: group, member: tabs[5].id, after: true))
        browser.move(tabs[3], toGroup: GroupDropTarget(group: group, member: tabs[0].id))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: tabs[1].id, after: true))
        let order = [3, 0, 1, 4, 2, 5].map { tabs[$0].id }
        #expect(browser.tabs.map(\.id) == order)
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: tabs[4].id))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: UUID()))
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group, member: UUID()))
        #expect(browser.tabs.map(\.id) == order)
        let foreign = Tab(configuration: Web.configuration())
        browser.move(foreign, toGroup: GroupDropTarget(group: group))
        tabs[4].pin = "pin"
        browser.move(tabs[4], toGroup: GroupDropTarget(group: group))
        tabs[4].pin = nil
        #expect(browser.tabs.map(\.id) == order)
        browser.toggleTabGroup(group)
        browser.move(tabs[3], toGroup: GroupDropTarget(group: group))
        #expect(!browser.tabGroups[0].collapsed)
        #expect(browser.tabs.last?.id == tabs[3].id)

        browser.prefs.splitView = true
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.move(tabs[0], toGroup: GroupDropTarget(group: group))
        #expect(Array(browser.tabs.suffix(2)).map(\.id) == [tabs[0].id, tabs[1].id])
        let besideTheFifth = GroupDropTarget(group: group, member: tabs[4].id)
        browser.move(tabs[1], toGroup: besideTheFifth, detaching: true)
        #expect(browser.tabs.first?.id == tabs[1].id)
        #expect(browser.tabs.last?.id == tabs[0].id)
        #expect(browser.split(for: tabs[1]) == nil)
        browser.leaveFiles()
        let saved = try #require(browser.record.rows[browser.spaceID.uuidString])
        let restored = Browser(record: browser.record)
        #expect(restored.tabs.map { $0.address?.absoluteString } == saved.tabs.map { Optional($0.url) })
        #expect(restored.tabs.map(\.groupID) == saved.tabs.map { $0.groupID })
    }

    @Test func visibleGeometryInBothLayouts() {
        let group = TabGroup(id: UUID(), name: "Group", collapsed: false)
        let first = UUID(), last = UUID(), source = UUID()
        // Unequal lengths and a negative origin also exercise scrolled coordinates.
        for vertical in [false, true] {
            let rect: (CGFloat, CGFloat) -> CGRect = { start, length in
                vertical ? CGRect(x: 10, y: start, width: 80, height: length)
                    : CGRect(x: start, y: 10, width: length, height: 80)
            }
            let point: (CGFloat) -> CGPoint = { position in
                vertical ? CGPoint(x: 30, y: position) : CGPoint(x: position, y: 30)
            }
            let frames = [
                group.id: GroupDropFrame(group: group.id, rect: rect(-40, 20)),
                first: GroupDropFrame(group: group.id, tab: first, rect: rect(-10, 30)),
                last: GroupDropFrame(group: group.id, tab: last, rect: rect(30, 80)),
                source: GroupDropFrame(group: group.id, tab: source, rect: rect(120, 30))
            ]
            for (position, target) in [
                (-30.0, GroupDropTarget(group: group.id)),
                (-5.0, GroupDropTarget(group: group.id, member: first)),
                (25.0, GroupDropTarget(group: group.id, member: last)),
                (100.0, GroupDropTarget(group: group.id, member: last, after: true))
            ] {
                #expect(GroupDropFrames.resolve(point(position), frames: frames, groups: [group],
                                                       excluding: source, vertical: vertical) == target)
            }
            #expect(GroupDropFrames.resolve(point(140), frames: frames, groups: [group],
                                                 excluding: source, vertical: vertical) == nil)
            var collapsed = group
            collapsed.collapsed = true
            #expect(GroupDropFrames.resolve(point(40), frames: frames, groups: [collapsed],
                                                    excluding: source, vertical: vertical) == GroupDropTarget(group: group.id))
        }
    }
}

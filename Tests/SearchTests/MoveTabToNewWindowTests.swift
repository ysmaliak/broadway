import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class MoveTabToNewWindowTests {
    private var browser: Browser!
    private var tabs: [Tab] = []
    private var other: Browser!

    init() {
        keepSetting(Shared.prefs, \.splitView, "splitView")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        other = Browser(record: WindowRecord())
        browser.prefs.splitView = true
        tabs = (1...3).map { number in
            let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.restore(url: URL(string: "https://example.com/\(number)")!, title: "Tab \(number)")
            return tab
        }
        browser.showRow(tabs, active: tabs[0].id)
    }

    private func tearDown() {
        other?.closeAll()
        other = nil
        for tab in tabs where tab.pin != nil { browser?.unpin(tab) }
        browser?.closeAll()
        browser = nil
    }

    private func run() throws {
        let command = try #require(Command.named("tabs.toNewWindow"))
        command.run(browser)
    }

    private func move() {
        guard let tab = browser.active else { return }
        browser.moveToNewWindow(tab, into: other)
    }

    @Test func theShortcutMovesASplitViewWhole() throws {
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[0])

        move()

        #expect(browser.tabs.map(\.id) == [tabs[2].id])
        #expect(other.tabs.contains { $0.id == tabs[0].id } && other.tabs.contains { $0.id == tabs[1].id })
        #expect(other.split(for: tabs[0])?.tabs.count == 2)
    }

    @Test func aSplitViewWithAHalfThatCannotMoveStaysWhole() throws {
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        tabs[1].bench = true
        defer { tabs[1].bench = false }
        browser.select(tabs[0])

        try run()

        #expect(browser.tabs.count == 3)
        #expect(browser.split(for: tabs[0]) != nil)
    }

    @Test func aWindowHoldingOnlyOneSplitViewDoesNotMoveIt() throws {
        browser.showRow([tabs[0], tabs[1]], active: tabs[0].id)
        browser.pair(tabs[1], with: tabs[0], onLeft: false)
        browser.select(tabs[0])

        try run()

        #expect(browser.tabs.count == 2)
        #expect(browser.split(for: tabs[0]) != nil)
    }
}

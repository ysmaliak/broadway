import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FolderTabCloseTests {
    private var browser: Browser!
    private var savedGroups = false

    init() {
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.closeAll()
    }

    private func tearDown() {
        browser?.closeAll()
        browser?.tabGroups = []
        browser = nil
    }

    private func tab(_ name: String) -> Tab {
        let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: "https://\(name).example/")!, title: name)
        _ = tab.wake()
        return tab
    }

    private func folder(pinned: Bool) -> (inside: Tab, other: Tab) {
        let (inside, other) = (tab("inside"), tab("other"))
        browser.showRow([inside, other], active: inside.id)
        let id = browser.newFolder(with: [inside], editing: false)!
        if let index = browser.tabGroups.firstIndex(where: { $0.id == id }) {
            browser.tabGroups[index].pinned = pinned
        }
        return (inside, other)
    }

    @Test func aTabInAnUnpinnedFolderCloses() {
        let (inside, _) = folder(pinned: false)

        browser.closeTab(inside)

        #expect(!browser.tabs.contains { $0.id == inside.id })
    }

    @Test func commandWClosesTheSelectedTabInAnUnpinnedFolder() {
        let (inside, other) = folder(pinned: false)
        browser.select(inside)

        browser.closeFront()

        #expect(!browser.tabs.contains { $0.id == inside.id })
        #expect(browser.activeID == other.id)
    }

    @Test func aTabInAPinnedFolderIsPutAwayThenClosed() {
        let (inside, _) = folder(pinned: true)
        #expect(browser.putsAway(inside))

        browser.closeTab(inside)

        #expect(browser.tabs.contains { $0.id == inside.id })
        #expect(inside.asleep)
        #expect(!browser.putsAway(inside))

        browser.closeTab(inside)

        #expect(!browser.tabs.contains { $0.id == inside.id })
    }

    @Test func theRowsCloseButtonClosesATabInAPinnedFolderAtOnce() throws {
        let (inside, _) = folder(pinned: true)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        defer {
            window.contentView = nil
            window.close()
        }
        let row = try #require(column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == inside.label && $0.window != nil })
        #expect(browser.putsAway(inside))

        row.close()

        #expect(!browser.tabs.contains { $0.id == inside.id })
        #expect(row.kitSubviews(of: CloseSpotView.self).allSatisfy { $0.symbol != "minus" })
    }

    @Test func closeFromTheMenuClosesATabInAPinnedFolderAtOnce() {
        let (inside, _) = folder(pinned: true)

        browser.close(inside)

        #expect(!browser.tabs.contains { $0.id == inside.id })
    }
}

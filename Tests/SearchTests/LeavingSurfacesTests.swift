import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct LeavingSurfacesTests {
    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    @Test func theFindBarKeepsItsWordsWhileItLeaves() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let host = FindHost(browser: browser)
        host.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        let window = window(host)
        defer { window.close() }

        browser.finding = true
        browser.needle = "tunnel"
        host.layoutSubtreeIfNeeded()
        let open = host.bar.shown
        let width = host.bar.frame.width
        browser.closeFind()
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let leaving = host.bar.shown
        browser.finding = true
        host.needsLayout = true
        host.layoutSubtreeIfNeeded()
        let again = host.bar.shown

        #expect(open.needle == "tunnel")
        #expect(browser.needle.isEmpty)
        #expect(leaving == open)
        #expect(host.bar.frame.width == width)
        #expect(again.needle.isEmpty)
        #expect(browser.active?.built == nil, "Finding builds no page to search")
    }

    @Test func theBookmarkCardKeepsItsFolderWhileItLeavesAfterRemove() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let bookmarks = Bookmarks()
        let before = Set(bookmarks.roots.map(\.id))
        defer { for node in bookmarks.roots where !before.contains(node.id) { bookmarks.remove(node.id) } }
        let shelf = bookmarks.insert(.folder("Reading", []), into: nil)
        let made = bookmarks.insert(Bookmark(id: UUID(), title: "Swift Forums", url: "https://forums.swift.org", children: nil), into: shelf.id)
        let card = BookmarkCardView(browser: browser, bookmarks: bookmarks, id: made.id, close: {})
        card.frame = NSRect(origin: .zero, size: card.intrinsicContentSize)
        let open = (card.folder.title, card.name.field.placeholderString)

        bookmarks.remove(made.id)
        try await Task.sleep(for: .milliseconds(100))

        #expect(open.0 == "Reading")
        #expect(open.1 == "forums.swift.org")
        #expect(card.folder.title == open.0)
        #expect(card.name.field.placeholderString == open.1)
    }
}

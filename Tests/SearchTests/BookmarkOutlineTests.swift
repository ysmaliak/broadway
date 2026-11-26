import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BookmarkOutlineTests {
    private func filled() -> Bookmarks {
        let bookmarks = Bookmarks()
        for node in bookmarks.roots { bookmarks.remove(node.id) }
        for node in BookmarksSurface.fixture { bookmarks.insert(node, into: nil) }
        return bookmarks
    }

    private func emptied(_ bookmarks: Bookmarks) {
        for node in bookmarks.roots { bookmarks.remove(node.id) }
    }

    @Test func thePageThePlaceAndTheSuggestionsSearchOneHaystack() {
        _ = NSApplication.shared
        let bookmarks = Bookmarks()
        emptied(bookmarks)
        defer { emptied(bookmarks) }
        let plans = Bookmark(title: "Plans", url: "https://www.docs.example/plans")
        _ = bookmarks.insert(Bookmark(title: "Work", url: nil, children: [plans]), into: nil)

        for typed in ["plans work", "docs.example plans", "work"] {
            let page = bookmarks.matches(typed).filter { !$0.node.isFolder }.map(\.node.title)
            let place = bookmarks.listed(matching: typed, limit: 10).map(\.title)
            let suggested = bookmarks.places(for: typed, limit: 10).map(\.title)
            #expect(page == ["Plans"], "\(typed)")
            #expect(place == ["Plans"], "\(typed)")
            #expect(suggested == ["Plans"], "\(typed)")
        }
        #expect(bookmarks.matches("https").isEmpty)
        #expect(bookmarks.places(for: "https", limit: 10).isEmpty)
    }

    @Test func heightCountsRowsAndTheEmptyFolderHint() {
        _ = NSApplication.shared
        let bookmarks = filled()
        defer { emptied(bookmarks) }

        let outline = BookmarkOutlineView(bookmarks: bookmarks, expanded: BookmarksSurface.opened, open: { _ in }, openInNewTab: { _ in })

        let rows: CGFloat = 8
        let expected = rows * BookmarkOutlineView.rowHeight + BookmarkOutlineView.hintHeight + 8 * BookmarkOutlineView.spacing
        #expect(outline.fittingHeight() == expected)
    }

    @Test func toggleOpensAFolderAndReportsIt() {
        _ = NSApplication.shared
        let bookmarks = filled()
        defer { emptied(bookmarks) }
        let outline = BookmarkOutlineView(bookmarks: bookmarks, open: { _ in }, openInNewTab: { _ in })
        var reported: Set<Bookmark.ID>?
        outline.onExpand = { reported = $0 }
        let work = BookmarksSurface.fixture[1].id
        let closed = outline.fittingHeight()

        outline.toggle(work)

        #expect(reported == [work])
        #expect(outline.fittingHeight() == closed + 3 * (BookmarkOutlineView.rowHeight + BookmarkOutlineView.spacing))
        outline.frame = NSRect(x: 0, y: 0, width: 280, height: outline.fittingHeight())
        outline.layoutSubtreeIfNeeded()
        #expect(outline.rect(of: BookmarksSurface.fixture[1].children![0].id) != nil)
    }

    @Test func theDropdownListsALoneFolderUnderItsName() {
        let folder = Bookmark.folder("Only", [])
        let site = Bookmark.site("Site", URL(string: "https://example.com")!)

        let lone = BookmarksDropdown.lone([folder])
        let none = BookmarksDropdown.lone([folder, site])

        #expect(lone?.id == folder.id)
        #expect(none == nil)
    }

    @Test func theDropdownIsAMenuOfFoldersAndBookmarksWithItsFoot() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let bookmarks = Bookmarks()
        emptied(bookmarks)
        defer { emptied(bookmarks) }
        let inner = Bookmark.site("Inner", URL(string: "https://example.com/inner")!)
        bookmarks.insert(Bookmark.folder("Folder", [inner]), into: nil)
        bookmarks.insert(Bookmark.site("Site", URL(string: "https://example.com/site")!), into: nil)

        let dropdown = BookmarksDropdown(browser: browser, bookmarks: bookmarks)
        dropdown.fillAll()

        let items = dropdown.menu.items
        #expect(items[0].title == "Folder")
        #expect(items[0].submenu?.items.first?.title == "Inner")
        #expect(items[1].title == "Site")
        #expect(items[1].image != nil)
        #expect(items[1].keyEquivalentModifierMask.isEmpty)
        #expect(items[2].isAlternate)
        #expect(items[2].keyEquivalentModifierMask == .command)
        #expect(items[2].title == "Open \u{201C}Site\u{201D} in New Tab")
        #expect(items[3].isSeparatorItem)
        #expect(items.suffix(2).map(\.title).last == "Manage Bookmarks")
    }

    @Test func anEmptyDropdownSaysSo() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let bookmarks = Bookmarks()
        emptied(bookmarks)

        let menu = BookmarksDropdown(browser: browser, bookmarks: bookmarks).menu

        #expect(menu.items.first?.title == "No bookmarks yet")
        #expect(menu.items.first?.isEnabled == false)
        #expect(menu.items.count == 4)
    }

    @Test func cardRenameTrimsAndSkipsAnUnchangedName() {
        _ = NSApplication.shared
        let bookmarks = filled()
        defer { emptied(bookmarks) }
        let id = BookmarksSurface.carded

        BookmarkCardView.rename(id, "  Forums  ", in: bookmarks)

        #expect(bookmarks.bookmark(id)?.title == "Forums")
    }
}

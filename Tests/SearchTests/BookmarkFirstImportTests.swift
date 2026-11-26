import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BookmarkFirstImportTests {
    @Test func theFirstImportIntoAnEmptyListLeavesOutRepeatsAcrossProfiles() {
        let bookmarks = Bookmarks()
        for node in bookmarks.roots { bookmarks.remove(node.id) }
        defer {
            for node in bookmarks.roots { bookmarks.remove(node.id) }
            Disk.drain()
        }
        let shared = URL(string: "https://shop.example/")!
        let work = [Bookmark.site("Shop", shared), Bookmark.folder("Other", [Bookmark.site("Docs", URL(string: "https://example.com/docs")!)])]
        let home = [Bookmark.site("Shop", shared), Bookmark.folder("Other", [Bookmark.site("Docs", URL(string: "https://example.com/docs")!), Bookmark.site("News", URL(string: "https://example.com/news")!)])]

        let taken = bookmarks.takeNoting(work + home, from: "Chrome")

        #expect(Bookmarks.urls(bookmarks.roots).filter { $0 == shared }.count == 1)
        #expect(bookmarks.roots.filter { $0.isFolder && $0.title == "Other" }.count == 1)
        #expect(Bookmarks.count(bookmarks.roots) == taken.added)
        #expect(taken.already == 2)
    }
}

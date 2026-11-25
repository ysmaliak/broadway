import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct PageHeadersTests {
    @Test func everyPageInATabSharesOneColumnAndTitle() throws {
        let browser = Browser(record: WindowRecord())
        let pages: [NSView] = [BookmarksPageView(browser: browser, bookmarks: browser.bookmarks),
                               FilesPageView(browser: browser, loot: Loot()),
                               PasswordsPageView(browser: browser),
                               HistoryPage(browser: browser)]

        let plates = try pages.map { page in
            page.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            page.layoutSubtreeIfNeeded()
            return try #require(page.kitSubviews(of: KitPlatePage.self).first)
        }

        for plate in plates {
            #expect(plate.width == KitPlatePage.standardWidth)
            #expect(plate.title.frame.minX == plates[0].title.frame.minX)
            #expect(plate.title.frame.minY == 32)
            #expect(plate.title.font == KitPlatePage.titleFont)
            #expect(plate.content.frame.minY == plates[0].content.frame.minY)
            #expect(plate.content.frame.width == KitPlatePage.columnWidth)
            #expect(plate.content.frame.minX == 280)
        }
    }
}

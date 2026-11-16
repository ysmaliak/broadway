import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FolderCountTests {
    @Test func aFoldedFolderShowsItsCountAndAnOpenOneDoesNot() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let folded = TabGroup(id: UUID(), name: "Reading", collapsed: true)
        let open = TabGroup(id: UUID(), name: "Design", collapsed: false)
        let shut = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 240, height: GroupHeadingView.height))
        let wide = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 240, height: GroupHeadingView.height))

        shut.show(folded, in: browser)
        shut.count = 4
        wide.show(open, in: browser)
        wide.count = 3

        #expect(shut.showsCount)
        #expect(!wide.showsCount)
    }

    @Test func anEmptyFoldedFolderShowsNoCount() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let folded = TabGroup(id: UUID(), name: "Empty", collapsed: true)
        let heading = GroupHeadingView(frame: NSRect(x: 0, y: 0, width: 240, height: GroupHeadingView.height))

        heading.show(folded, in: browser)
        heading.count = 0

        #expect(!heading.showsCount)
    }
}

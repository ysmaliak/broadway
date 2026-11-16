import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class StackGutterTests {
    private var browser: Browser!
    private let page = SideDocumentView(frame: NSRect(x: 0, y: 0, width: 258, height: 400))
    private let card = NSRect(x: 8, y: 0, width: 242, height: 400)

    init() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let browser = browser!
        addTeardownBlock { @MainActor in browser.closeAll() }
    }

    private func tab(_ number: Int, checks: LiveChecks?, author: String?, stack: LiveStack? = nil, draft: Bool = false) -> Search.Tab {
        if number > 0 || browser.tabs.last?.isBlank == false { browser.newTab() }
        let tab = browser.tabs.last!
        tab.restore(url: URL(string: "https://github.com/acme/rocket/pull/\(number)")!, title: "PR \(number)")
        tab.liveItem = LiveItem(key: "pr-\(number)", title: "PR \(number)", author: author, checks: checks, stack: stack, draft: draft)
        return tab
    }

    private func row(_ tab: Search.Tab, at index: Int) -> TabRowView {
        let row = TabRowView.take(in: page)
        page.addSubview(row)
        row.frame = NSRect(x: card.minX + Metrics.folderPad, y: CGFloat(index) * 36, width: card.width - 2 * Metrics.folderPad,
                           height: Metrics.sideRowHeight)
        var state = RowState()
        state.interactive = false
        row.show(tab, in: browser, state: state)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        for sub in view.subviews {
            if let found = sub as? T { return found }
            if let found = first(type, in: sub) { return found }
        }
        return nil
    }

    private func frame(of view: NSView?, in row: NSView) throws -> NSRect {
        let view = try #require(view)
        return view.convert(view.bounds, to: page)
    }

    @Test func aStackLeavesEveryIconWhereAnyRowsIconIs() throws {
        let tabs = [tab(0, checks: .failing, author: "dana"),
                    tab(1, checks: .pending, author: "octo", stack: LiveStack(position: 3, count: 3), draft: true),
                    tab(2, checks: .failing, author: "octo", stack: LiveStack(position: 2, count: 3)),
                    tab(3, checks: nil, author: nil)]

        let rows = tabs.enumerated().map { row($1, at: $0) }
        let icons = try rows.map { try frame(of: first(RowMarkView.self, in: $0), in: $0) }

        #expect(Set(icons.map(\.minX)).count == 1, "\(icons.map(\.minX))")
        #expect(icons.first?.minX == rows[0].frame.minX + TabRowView.iconLead)
    }

    @Test func theStackChevronIsAChipOnTheFaviconsTopLeadingCorner() throws {
        let top = tab(0, checks: .pending, author: "octo", stack: LiveStack(position: 2, count: 2))
        let laid = row(top, at: 0)
        let icon = try frame(of: first(RowMarkView.self, in: laid), in: laid)
        let badge = try frame(of: first(ChecksMarkView.self, in: laid), in: laid)
        let title = try frame(of: first(RowTitleView.self, in: laid), in: laid)

        let chevron = StackFoldButton.frame(row: laid.frame)

        #expect(chevron.width == StackFoldButton.width && chevron.height == StackFoldButton.width)
        #expect(abs(chevron.midX - (icon.minX + 1)) < 0.01 && abs(chevron.midY - (icon.minY + 1)) < 0.01)
        #expect(laid.frame.contains(chevron))
        #expect(!chevron.intersects(badge))
        #expect(chevron.maxX < title.minX)
    }

    @Test(arguments: [LiveChecks.passing, .failing, .pending])
    func theChecksBadgeSitsOnTheFaviconsCornerAndNeverOnTheByline(_ checks: LiveChecks) throws {
        let cases: [(author: String?, draft: Bool)] = [("dana", false), ("octo", true), (nil, false)]

        for (index, made) in cases.enumerated() {
            let laid = row(tab(index, checks: checks, author: made.author, draft: made.draft), at: index)
            let mark = try #require(first(RowMarkView.self, in: laid))
            let icon = try frame(of: mark, in: laid)
            let badge = try frame(of: first(ChecksMarkView.self, in: laid), in: laid)
            let title = try frame(of: first(RowTitleView.self, in: laid), in: laid)
            let ring = ChecksMarkView.ring

            #expect(icon.insetBy(dx: -ring, dy: -ring).contains(badge), "\(checks) \(made): \(badge) on \(icon)")
            #expect(badge.midX > icon.midX && badge.midY > icon.midY, "on the bottom-trailing corner")
            #expect(first(ChecksMarkView.self, in: mark) == nil, "a draft's dimmed favicon doesn't dim the badge")
            #expect(badge.insetBy(dx: -ring, dy: -ring).maxX + 3 <= title.minX, "\(checks) \(made): clear of the text")
            if made.author != nil {
                let byline = try frame(of: first(BylineView.self, in: laid), in: laid)
                #expect(byline.minX == title.minX)
                #expect(!badge.insetBy(dx: -ring, dy: -ring).intersects(byline))
            }
        }
    }
}

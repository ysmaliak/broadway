import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PageMeasuresTests {
    private let width = KitPlatePage.columnWidth
    private let then = Date(timeIntervalSince1970: 100)

    private func laid<T: NSView>(_ view: T, height: CGFloat = KitPageRow.height) -> T {
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= 0.5 }

    @Test func thePageColumnIsAsWideAsTheNewTabField() {
        let size = NSSize(width: 1200, height: 800)

        let wide = KitPlatePage.column(in: size)
        let narrow = KitPlatePage.column(in: NSSize(width: 400, height: 300))
        let field = NewTabPageView.layout(in: size)
        let tight = NewTabPageView.layout(in: NSSize(width: 400, height: 300))

        #expect(wide.minX == 280)
        #expect(wide.width == 640)
        #expect(narrow.minX == 24)
        #expect(narrow.width == 352)
        #expect(field.fieldWidth == wide.width)
        #expect(tight.fieldWidth == narrow.width)
    }

    @Test func historyDownloadsAndFilesRowsShareTheirMeasures() throws {
        let trace = History.Trace(key: "k", address: "https://example.com/a", title: "Example",
                                  url: try #require(URL(string: "https://example.com/a")), last: then, count: 1)
        let history = laid(HistoryLineView(trace: trace, note: nil, go: {}, forget: {}))
        let kept = laid(KeptLineView(keep: Keep(name: "a.pdf", from: "a.example", path: "/tmp/pages-none.pdf", date: then),
                                     open: {}, reveal: {}, forget: {}))
        let file = FileRowView(frame: .zero)
        file.show(FileItem(id: "a", kind: .downloaded, name: "a.pdf", source: "a.example", path: "/tmp/pages-none.pdf", date: then), last: false)
        _ = laid(file)

        #expect(history.rowHeight == 40)
        #expect(kept.rowHeight == 40)
        #expect(FileListView.rowHeight == 40)
        #expect(FileListView.inset == 0)
        for row in [history, kept, file] as [NSView] {
            let words = row.subviews.compactMap { $0 as? KitLabel }.filter { !$0.isHidden }
            let icon = try #require(row.subviews.first { $0 is MarkView || $0 is KitSymbol || $0 is NSImageView })
            #expect(words.map(\.frame.minX).min() == KitPageRow.textX)
            #expect(near(icon.frame.midX, KitPageRow.iconSlot / 2))
            #expect(near(icon.frame.midY, KitPageRow.height / 2))
        }
        let time = try #require(history.subviews.compactMap { $0 as? KitLabel }.max { $0.frame.maxX < $1.frame.maxX })
        #expect(near(time.frame.maxX, width))
        #expect(history.rule.frame.minX == KitPageRow.textX)
        #expect(history.rule.frame.maxX == width)
        #expect(kept.rule.frame == history.rule.frame)
    }

    @Test func aHoveredRowsLastButtonEndsItsWordsOnTheEdge() throws {
        let trace = History.Trace(key: "k", address: "https://example.com/a", title: "Example",
                                  url: try #require(URL(string: "https://example.com/a")), last: then, count: 1)
        let history = laid(HistoryLineView(trace: trace, note: nil, go: {}, forget: {}))
        let kept = laid(KeptLineView(keep: Keep(name: "a.pdf", from: "a.example", path: "/tmp/pages-none.pdf", date: then),
                                     open: {}, reveal: {}, forget: {}))

        for row in [history, kept] as [NSView] {
            row.mouseEntered(with: NSEvent())
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            let last = try #require(row.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }.max { $0.frame.maxX < $1.frame.maxX })
            let words = ceil(last.attributedTitle.size().width)

            #expect(KitPageRow.overhang(last) > 0)
            #expect(near(last.frame.midX + words / 2, width))
        }
    }

    @Test func aRowsTwoLinesSitAsOneBlockInItsMiddle() {
        let tops = KitPageRow.lines(NSSize(width: 10, height: 16), NSSize(width: 10, height: 14), in: KitPageRow.height)
        let icon = KitPageRow.icon(NSSize(width: 16, height: 16), in: KitPageRow.height)

        #expect(tops.title == 4)
        #expect(tops.detail == 22)
        #expect(icon == NSRect(x: 2, y: 12, width: 16, height: 16))
    }

    @Test func aDownloadFromThisMinuteSaysJustNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(When.said(now.addingTimeInterval(-2), now: now) == "just now")
        #expect(When.said(now.addingTimeInterval(1), now: now) == "just now")
        #expect(When.said(now.addingTimeInterval(-3600), now: now) != "just now")
    }

    @Test func anEmptyStatesLineBreaksEvenly() {
        let limit = KitEmptyView.lineWidth
        let long = KitParagraph("Files you download, and files you give to sites, show up here.", font: .systemFont(ofSize: 13), alignment: .center, maxWidth: limit)
        let short = KitParagraph("No file by that name.", font: .systemFont(ofSize: 13), alignment: .center, maxWidth: limit)

        let even = long.balancedWidth(within: limit)

        #expect(even < limit - 40)
        #expect(ceil(long.measure(width: even).height) == ceil(long.measure(width: limit).height))
        #expect(ceil(long.measure(width: even - 2).height) > ceil(long.measure(width: even).height))
        #expect(short.balancedWidth(within: limit) == limit)
    }

    @Test func theClearCardFillsItsColumn() throws {
        let back = KitBroadwayButton("Back") {}
        let sweeps = RecallSweeps(rows: [
            ("History", "Everywhere you have been", KitBroadwayButton("Clear", kind: .destructive, small: true) {}),
            ("Cache", "Only what was fetched to draw pages", KitBroadwayButton("Clear", kind: .destructive, small: true) {}),
        ], back: back)

        _ = laid(sweeps, height: sweeps.intrinsicContentSize.height)
        let card = try #require(sweeps.subviews.first as? KitBox)
        let words = sweeps.subviews.compactMap { $0 as? KitLabel }

        #expect(card.frame == NSRect(x: 0, y: 0, width: width, height: RecallSweeps.rowHeight * 2))
        #expect(words.map(\.frame.minX).min() == RecallSweeps.pad)
        #expect(back.frame.maxX == width)
        #expect(back.frame.minY == card.frame.maxY + RecallSweeps.pad)
        #expect(sweeps.intrinsicContentSize.height == back.frame.maxY)
    }

    @Test func everySearchFieldSitsAtTheTopOfItsColumn() throws {
        let browser = Browser(record: WindowRecord())
        let pages: [NSView] = [BookmarksPageView(browser: browser, bookmarks: browser.bookmarks),
                               FilesPageView(browser: browser, loot: Loot()),
                               PasswordsPageView(browser: browser),
                               HistoryPage(browser: browser)]

        for page in pages {
            page.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            page.layoutSubtreeIfNeeded()
            let plate = try #require(page.kitSubviews(of: KitPlatePage.self).first)
            let field = try #require(page.kitSubviews(of: KitSearchField.self).first { !$0.isHiddenOrHasHiddenAncestor })
            let frame = plate.convert(field.bounds, from: field)

            #expect(near(frame.minY, plate.content.frame.minY))
            #expect(near(frame.minX, plate.content.frame.minX))
            #expect(near(frame.height, KitPageRow.fieldHeight))
        }
    }

    @Test func anEmptyStateSitsAtTheSameHeightWhateverTheFoot() throws {
        let bare = KitFlippedView()
        let footed = KitFlippedView()
        let foot = KitFlippedView()
        foot.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let plates = [KitPlatePage("Files", content: bare), KitPlatePage("Passwords", content: footed, foot: foot)]
        let middles = plates.map { plate -> CGFloat in
            plate.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            plate.layoutSubtreeIfNeeded()
            let empty = KitEmptyView("No files yet", line: "Files you download, and files you give to sites, show up here.", symbol: "doc")
            plate.content.addSubview(empty)
            empty.frame = KitPageRow.emptyFrame(for: empty, in: plate.content, fieldHeight: KitPageRow.fieldHeight)
            return plate.convert(empty.bounds, from: empty).midY
        }
        let short = plates[1]
        short.frame = NSRect(x: 0, y: 0, width: 1200, height: 360)
        short.layoutSubtreeIfNeeded()
        let empty = try #require(short.content.subviews.first as? KitEmptyView)

        let squeezed = KitPageRow.emptyFrame(for: empty, in: short.content, fieldHeight: KitPageRow.fieldHeight)

        #expect(middles[0] == middles[1])
        #expect(plates[0].content.frame.maxY > plates[1].content.frame.maxY)
        #expect(squeezed.maxY == short.content.bounds.maxY)
    }
}

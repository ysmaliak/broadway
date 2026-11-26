import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ColumnPeekLookTests {
    private var window: NSWindow?
    private var browser: Browser?
    private var restore: (() -> Void)?

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        if let browser { ContentView.forget(browser); browser.closeAll() }
        window?.contentView = nil
        window?.close()
        restore?()
    }

    @Test func thePeekLaysOutItsRowsWhereTheDockedColumnDoes() async throws {
        let (browser, window) = try await scene()
        let root = try #require(window.contentView)
        let docked = places(in: root, card: false)
        #expect(docked.count >= 6)

        browser.folded = true
        try await settle(window)
        browser.peek(true)
        try await settle(window)

        let peeked = places(in: root, card: true)
        #expect(peeked.keys.sorted() == docked.keys.sorted())
        for (name, frame) in docked {
            let seen = try #require(peeked[name])
            #expect(abs(seen.minY - frame.minY) < 0.5, "\(name) sits at the docked height")
            #expect(abs(seen.minX - frame.minX - Metrics.floatGap) < 0.5, "\(name) sits one card inset in")
            #expect(abs(seen.width - frame.width) < 0.5 && abs(seen.height - frame.height) < 0.5, "\(name) keeps its size")
        }
    }

    @Test func thePeekFloatsOverThePageOnTheDockedGround() async throws {
        let (browser, window) = try await scene()
        let root = try #require(window.contentView)

        browser.folded = true
        try await settle(window)
        browser.peek(true)
        try await settle(window)

        let card = try #require(all(FoldColumnCardView.self, in: root).first)
        let box = card.convert(card.bounds, to: root)
        let gap = Metrics.floatGap
        #expect(abs(box.minX - gap) < 0.5 && abs(box.minY - gap) < 0.5)
        #expect(abs(box.height - (root.bounds.height - 2 * gap)) < 0.5)
        let ground = try #require(all(ShellGroundLayer.self, in: card).first)
        let canvas = ground.convert(ground.bounds, to: root)
        #expect(abs(canvas.minX) < 0.5 && abs(canvas.minY) < 0.5, "the ground is painted on the window's canvas")
        #expect(abs(canvas.width - root.bounds.width) < 0.5 && abs(canvas.height - root.bounds.height) < 0.5)
        #expect(ground.alphaValue < 1, "the page shows faintly through the card")
        #expect(!all(KitGlass.self, in: card).isEmpty, "the page behind is blurred")
        #expect(card.column.floating)
    }

    private func scene() async throws -> (Browser, NSWindow) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.splitView, prefs.sideWidth, prefs.sidePosition)
        restore = { (prefs.splitView, prefs.sideWidth, prefs.sidePosition) = saved }
        prefs.splitView = false
        prefs.sideWidth = 258
        prefs.sidePosition = .left
        for index in 0..<4 {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        browser.select(browser.tabs[1])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1000, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ContentView(browser: browser)
        window.orderFrontRegardless()
        self.browser = browser
        self.window = window
        try await settle(window)
        return (browser, window)
    }

    private func places(in root: NSView, card: Bool) -> [String: CGRect] {
        let columns = all(SideColumnView.self, in: root).filter { column in
            let inCard = sequence(first: column as NSView, next: \.superview).contains { $0 is FoldColumnCardView }
            return inCard == card && !column.isHiddenOrHasHiddenAncestor
        }
        guard let column = columns.first else { return [:] }
        var out: [String: CGRect] = [:]
        for row in all(TabRowView.self, in: column) where !row.isHiddenOrHasHiddenAncestor {
            if let tab = row.tab { out["row \(tab.id)"] = row.convert(row.bounds, to: root) }
        }
        if let helm = all(HelmView.self, in: column).first { out["helm"] = helm.convert(helm.bounds, to: root) }
        if let address = all(SideAddressView.self, in: column).first { out["address"] = address.convert(address.bounds, to: root) }
        if let titles = all(SpaceTitlesView.self, in: column).first { out["titles"] = titles.convert(titles.bounds, to: root) }
        return out
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}

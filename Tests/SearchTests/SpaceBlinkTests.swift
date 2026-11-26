import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpaceBlinkTests {
    private func until(_ what: String, within seconds: TimeInterval = 5, sourceLocation: SourceLocation = #_sourceLocation,
                       _ done: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !done() {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Issue.record("timed out: \(what)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fill(_ browser: Browser, _ name: String) {
        for index in 0..<4 {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#\(name)-\(index)")!, title: "\(name) \(index)")
        }
    }

    private func twoSpaces(_ body: (Browser, NSWindow, UUID, UUID) async throws -> Void) async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.splitView, prefs.sharesPins)
        (prefs.usesSpaces, prefs.splitView, prefs.sharesPins) = (true, false, false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.splitView, prefs.sharesPins) = previous
            NSApp.setActivationPolicy(policy)
        }
        let first = browser.spaceID
        fill(browser, "First")
        browser.addSpace(named: "Second")
        try await until("the second space is on screen") { browser.spaceID != first }
        fill(browser, "Second")
        try await body(browser, window, first, browser.spaceID)
    }

    @Test func theIncomingColumnHoldsDrawableTitledRowsBeforeTheSwipeMoves() async throws {
        try await twoSpaces { browser, window, first, _ in
            window.setContentSize(NSSize(width: browser.prefs.columnWidth, height: 600))
            window.contentView = SideColumnView(browser: browser)
            window.orderFrontRegardless()
            func incoming() -> SidePageView? {
                window.contentView?.kitSubviews(of: SidePageView.self).first { $0.preview?.space == first && !$0.isHidden }
            }

            let target = try #require(browser.spaces.firstIndex { $0.id == first })

            browser.spaceNext = target
            window.contentView?.needsLayout = true
            try await until("the first space's rows are beside the column") { incoming() != nil }
            window.contentView?.layoutSubtreeIfNeeded()

            #expect(browser.spaceMotion.offset == 0)
            let page = try #require(incoming())
            let rows = page.kitSubviews(of: TabRowView.self).filter { !$0.isHiddenOrHasHiddenAncestor && $0.tab != nil }
            let titles = Set(rows.compactMap { $0.tab?.label })
            #expect(titles.isSuperset(of: ["First 0", "First 1", "First 2", "First 3"]), "\(titles)")
            for row in rows {
                let labels = row.kitSubviews(of: KitLabel.self).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.text.isEmpty }
                #expect(labels.contains { $0.text == row.tab?.label }, "\(row.tab?.label ?? "-")")
                #expect(labels.allSatisfy { !$0.visibleRect.isEmpty }, "\(row.tab?.label ?? "-") would not draw")
            }
        }
    }

    @Test func theLandedSpacePreviewStaysUntilTheLivePageHasDrawn() async throws {
        try await twoSpaces { browser, window, first, _ in
            var ready = false
            let stage = SpaceStageView(browser: browser, motion: browser.spaceMotion, corner: 0, content: NSView())
            stage.makePreview = { _, _ in NSView() }
            stage.pageReady = { ready }
            stage.frame = window.contentView!.bounds
            window.contentView?.addSubview(stage)
            window.orderFrontRegardless()
            browser.spaceNext = try #require(browser.spaces.firstIndex { $0.id == first })
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()

            browser.spaceID = first
            browser.spaceNext = nil
            stage.needsLayout = true
            stage.layoutSubtreeIfNeeded()

            #expect(SpaceStageView.covers(browser.active))
            #expect(stage.cover?.space == first)
            try await Task.sleep(for: .milliseconds(100))
            #expect(stage.cover?.space == first)
            #expect(stage.cover?.rider.superview != nil)
            ready = true
            try await until("the preview leaves once the page has drawn", within: 0.3) { stage.cover == nil }
            #expect(stage.cover == nil)
        }
    }
}

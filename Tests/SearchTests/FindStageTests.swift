import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FindStageTests {
    @Test func findBarFollowsFocusedPaneAndStageLayout() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        var pair = TabSplit(left: left.id, right: right.id)
        stage.show([left, right], split: pair, focused: right.id)
        browser.finding = true
        stage.showFind(browser)
        let window = makeWindow(stage)
        defer { window.close() }
        stage.layoutSubtreeIfNeeded()
        let bar = try #require(stage.subviews.compactMap { $0 as? FindHost }.first)
        #expect(bar.superview === stage)
        #expect(abs(bar.frame.maxX - 1000) <= 0.1)
        #expect(bar.frame.minY == Metrics.paneBar)
        try await assertControlsHit(in: bar, stage: stage)

        pair.fraction = 0.35
        stage.show([left, right], split: pair, focused: left.id)
        stage.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        #expect(abs(bar.frame.maxX - ((1000 - PaneStage.gutter) * 0.35 * scale).rounded() / scale) <= 0.1)
        try await assertControlsHit(in: bar, stage: stage)

        stage.frame.size.width = 520
        stage.layoutSubtreeIfNeeded()
        try await assertControlsHit(in: bar, stage: stage, narrow: true)

        stage.frame.size = CGSize(width: 420, height: 250)
        stage.layoutSubtreeIfNeeded()
        #expect(abs(bar.frame.maxX - 420) <= 0.1)
        #expect(!bar.isHidden)
        try await assertControlsHit(in: bar, stage: stage)
        stage.showFind(nil)
        #expect(bar.superview != nil)
        try await Task.sleep(for: .milliseconds(400))
        #expect(bar.superview == nil)
    }

    @Test func closingTheBarKeepsTheSearchAndEscapeWithTheBarShutClearsThePaint() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(URL(string: "about:blank")!)
        browser.activeID = tab.id
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        stage.show([tab], split: nil, focused: tab.id)
        let window = makeWindow(stage)
        defer { browser.closeFind(); window.close() }
        let web = tab.web
        web.loadHTMLString("<body>orchid orchid orchid<script>window.findFixtureReady = true;</script></body>",
                           baseURL: URL(string: "https://find-shut.invalid/"))
        try await waitUntil("the fixture page loads") {
            (try? await web.evaluateJavaScript("window.findFixtureReady")) as? Bool == true
        }
        browser.openFind()
        browser.needle = "orchid"
        try await waitUntil("find answers") { !browser.findBusy && browser.findResult != nil }

        browser.closeFind()
        let kept = browser.needle
        let again = browser.canFindAgain
        browser.look(forward: true)
        try await waitUntil("find next answers with the bar shut") { !browser.findBusy && browser.findResult != nil }
        let painted = try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0") as? Int
        let escaped = browser.escapeShutFind()
        try await waitUntil("Escape clears the page's paint") {
            (try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0")) as? Int == 0
        }

        #expect(painted == 3)
        #expect(kept == "orchid")
        #expect(again)
        #expect(!browser.finding)
        #expect(escaped)
        #expect(browser.findResult == nil)
        #expect(!browser.escapeShutFind())
    }

    @Test func openingTheBarAgainFindsTheKeptWordsOnThePage() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(URL(string: "about:blank")!)
        browser.activeID = tab.id
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        stage.show([tab], split: nil, focused: tab.id)
        let window = makeWindow(stage)
        defer { browser.closeFind(); window.close() }
        let web = tab.web
        web.loadHTMLString("<body>orchid orchid orchid<script>window.findFixtureReady = true;</script></body>",
                           baseURL: URL(string: "https://find-again.invalid/"))
        try await waitUntil("the fixture page loads") {
            (try? await web.evaluateJavaScript("window.findFixtureReady")) as? Bool == true
        }
        browser.openFind()
        browser.needle = "orchid"
        try await waitUntil("find answers") { !browser.findBusy && browser.findResult != nil }
        browser.closeFind()
        try await waitUntil("closing clears the page's paint") {
            (try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0")) as? Int == 0
        }

        browser.openFind()
        let asked = browser.findBusy
        try await waitUntil("the kept words are found again") { browser.findStatus != nil && !browser.findBusy }
        try await waitUntil("the page is painted again") {
            (try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0")) as? Int == 3
        }
        let selected = try await web.evaluateJavaScript("String(getSelection())") as? String

        #expect(asked)
        #expect(browser.needle == "orchid")
        #expect(browser.findStatus == "1 of 3")
        #expect(selected == "orchid")

        browser.closeFind()
        browser.finding = true
        try await waitUntil("the bar shown again without ⌘F finds them too") { browser.findStatus != nil && !browser.findBusy }
        #expect(browser.findStatus == "1 of 3")

        browser.closeFind()
        browser.look(forward: true)
        try await waitUntil("find next answers with the bar shut") { !browser.findBusy && browser.findResult != nil }
        browser.takeForFind("lily", board: NSPasteboard.withUniqueName())
        browser.openFind()
        try await waitUntil("words taken while the bar was shut are found when it opens") {
            !browser.findBusy && browser.findStatus != "1 of 3"
        }
        #expect(browser.needle == "lily")
        #expect(browser.findStatus == "No matches")
    }

    @Test func closeButtonClearsFindWithoutClickingPageAfterStatusChanges() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(URL(string: "about:blank")!)
        browser.activeID = tab.id
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        stage.show([tab], split: nil, focused: tab.id)
        let window = makeWindow(stage)
        defer { browser.closeFind(); window.close() }
        let web = tab.web
        web.loadHTMLString("""
            <body style="margin:0;min-height:100vh" onclick="window.pageClicks++">
            orchid orchid orchid
            <script>window.pageClicks = 0; window.findFixtureReady = true;</script>
            </body>
            """, baseURL: URL(string: "https://find-stage.invalid/"))
        try await waitUntil("the fixture page loads") {
            (try? await web.evaluateJavaScript("window.findFixtureReady")) as? Bool == true
        }
        browser.openFind()
        stage.showFind(browser)
        stage.layoutSubtreeIfNeeded()
        let bar = try #require(stage.subviews.compactMap { $0 as? FindHost }.first)
        try await assertControlsHit(in: bar, stage: stage)

        for query in ["orchid", "missing", "", "orchid"] {
            browser.needle = query
            try await waitUntil("find finishes searching for \(query)") {
                !browser.findBusy && (query.isEmpty || browser.findResult != nil)
            }
            #expect(browser.findStatus == (query.isEmpty ? nil : query == "missing" ? "No matches" : "1 of 3"))
            try await assertControlsHit(in: bar, stage: stage)
        }
        let highlighted = try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0")
        #expect((highlighted as? Int) == 3)

        let point = bar.convert(closePoint(in: bar), to: nil)
        let target = try #require(stage.hitTest(stage.superview!.convert(point, from: nil)))
        #expect(target === bar || target.isDescendant(of: bar), "X must receive the press before the page")
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
            ))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(20))
        }
        try await waitUntil("X closes Find and clears page highlights") {
            guard !browser.finding else { return false }
            return (try await web.evaluateJavaScript("CSS.highlights.get('search-find-match')?.size ?? 0")) as? Int == 0
        }
        #expect(browser.needle == "orchid")
        #expect(browser.findResult == nil)
        #expect(browser.findStatus == nil)
        let clicks = try await web.evaluateJavaScript("window.pageClicks")
        #expect((clicks as? Int) == 0)
    }

    private func makeWindow(_ stage: PaneStage) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000,
                                                 width: stage.frame.width, height: stage.frame.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stage
        window.orderFrontRegardless()
        return window
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.compactMap { textField(in: $0) }.first
    }

    private func control(_ label: String, in view: NSView) -> NSView? {
        if view.accessibilityLabel() == label, !view.isHiddenOrHasHiddenAncestor { return view }
        return view.subviews.lazy.compactMap { self.control(label, in: $0) }.first
    }

    private func closePoint(in bar: FindHost, narrow: Bool = false) -> NSPoint {
        guard let close = control("Close Find on Page", in: bar) else { return NSPoint(x: bar.pillFrame.maxX - 20, y: bar.pillFrame.midY) }
        return close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: bar)
    }

    private func assertControlsHit(in bar: FindHost, stage: PaneStage,
                                   narrow: Bool = false) async throws {
        try await Task.sleep(for: .milliseconds(250))
        stage.layoutSubtreeIfNeeded()
        let field = try #require(textField(in: bar))
        let fieldPoint = field.convert(NSPoint(x: 2, y: field.bounds.midY), to: stage.superview)
        let fieldHit = stage.hitTest(fieldPoint)
        #expect(fieldHit === bar || fieldHit?.isDescendant(of: bar) == true, "Find field must keep its click")
        let beforeField = field.convert(NSPoint(x: -24, y: field.bounds.midY), to: stage)
        #expect(bar.hitTest(beforeField) == nil, "empty space left of the pill must pass through after resizing")
        let labels = ["Close Find on Page", "Search Options"] + (narrow ? [] : ["Next Match", "Previous Match"])
        for label in labels {
            let button = try #require(control(label, in: bar), "\(label) must be shown")
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: stage.superview)
            let hit = stage.hitTest(point)
            #expect(hit === bar || hit?.isDescendant(of: bar) == true, "\(label) must keep its click")
        }
        for point in [NSPoint(x: 2, y: 32), NSPoint(x: bar.bounds.midX, y: 2),
                      NSPoint(x: bar.bounds.maxX - 15, y: 13), NSPoint(x: bar.bounds.maxX - 2, y: 32),
                      NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY - 2)] {
            #expect(bar.hitTest(bar.convert(point, to: stage)) == nil, "empty padding must pass through")
        }
    }

    private func waitUntil(_ message: String, _ predicate: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for \(message)")
        throw NSError(domain: "FindStageTests", code: 1)
    }
}

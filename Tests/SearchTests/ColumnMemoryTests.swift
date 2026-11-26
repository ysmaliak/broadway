import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ColumnMemoryTests {
    @Test func restorationKeepsTheLatestScroll() {
        let memory = ColumnMemory()
        let space = UUID()
        memory.note(.list, value: 80, in: space)
        let ticket = memory.begin(space)

        memory.note(.list, value: 80, in: space)
        memory.note(.list, value: 125, in: space)
        memory.finish(ticket)

        #expect(!memory.restoring)
        #expect(memory.saved[space]?.list == 125)
    }

    @Test func leavingSamplesTheNativeViewportBeforeBeginningAnotherRestore() {
        let memory = ColumnMemory()
        let first = UUID(), second = UUID()
        memory.note(.list, value: 0, in: first)
        memory.watch(.list) { 285 }

        memory.capture(first)
        _ = memory.begin(second)

        #expect(memory.saved[first]?.list == 285)
    }

    @Test func readerSamplesTheNativeOffsetWithoutWaitingForGeometryCallbacks() async throws {
        _ = NSApplication.shared
        let memory = ColumnMemory()
        let space = UUID()
        memory.note(.list, value: 0, in: space)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let document = KitFlippedView(frame: NSRect(x: 0, y: 0, width: 260, height: 900))
        let reader = ColumnScrollReaderView(frame: document.bounds)
        reader.memory = memory
        reader.part = .list
        document.addSubview(reader)
        scroll.documentView = document
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 285))
        scroll.reflectScrolledClipView(scroll.contentView)
        memory.capture(space)

        #expect(memory.saved[space]?.list == 285)
    }

    @Test func destinationOffsetIsAppliedBeforeTheFirstDrawingPass() {
        _ = NSApplication.shared
        let memory = ColumnMemory(), space = UUID()
        memory.note(.list, value: 80, in: space)
        let generation = memory.begin(space)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 900))
        let reader = ColumnScrollReaderView(frame: document.bounds)
        document.addSubview(reader)
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        reader.memory = memory
        reader.destination = (generation, 80)
        reader.viewport = scroll.contentView.bounds.height
        reader.restore()
        #expect(scroll.contentView.bounds.minY == 0)

        reader.viewWillDraw()

        #expect(scroll.contentView.bounds.minY == 80)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        reader.viewWillDraw()
        #expect(scroll.contentView.bounds.minY == 120)
    }

    @Test func returningFromAFittingColumnRestoresTheOverflowingList() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.splitView, prefs.sharesPins)
        (prefs.usesSpaces, prefs.splitView, prefs.sharesPins) = (true, false, false)
        let first = browser.spaceID
        for index in 0..<26 {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "Row \(index)")
        }
        let tabs = browser.tabs
        let group = browser.addTabGroup(containing: tabs[0], pinned: true)
        for tab in tabs[1..<9] { browser.move(tab, toGroup: group) }
        browser.editingGroupID = nil
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: prefs.columnWidth, height: 760), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.splitView, prefs.sharesPins) = previous
            NSApp.setActivationPolicy(policy)
        }
        func scrolls(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
        }
        func liveList() -> NSScrollView? {
            guard let root = window.contentView else { return nil }
            let all = scrolls(root)
            let tallest = all.map { $0.documentView?.frame.height ?? 0 }.max() ?? 0
            return all.filter { ($0.documentView?.frame.height ?? 0) == tallest }.first { scroll in
                let centre = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
                return root.hitTest(centre)?.enclosingScrollView === scroll
            }
        }
        let target: CGFloat = 80
        func near(_ value: CGFloat) -> Bool { abs((browser.columnMemory.offset(.list) ?? -1) - value) <= 1 }
        try await until("the list overflows") {
            guard let list = liveList(), let height = list.documentView?.frame.height else { return false }
            return height > list.contentView.bounds.height + target
        }
        let list = try #require(liveList())
        list.contentView.scroll(to: NSPoint(x: 0, y: target))
        list.reflectScrolledClipView(list.contentView)
        try await until("the list reads its offset") { near(target) }
        #expect(near(target))

        browser.addSpace(named: "Short")
        try await until("the short space is on screen") { browser.spaceID != first && !browser.columnMemory.restoring }
        browser.switchSpace(to: first)
        try await until("the list lands where it was") {
            abs(browser.columnMemory.landing.list - target) <= 1 && near(target) && liveList() != nil
                && !browser.columnMemory.restoring
        }

        #expect(abs(browser.columnMemory.landing.list - target) <= 1)
        #expect(near(target))
        let returned = try #require(liveList())
        returned.contentView.scroll(to: NSPoint(x: 0, y: 40))
        returned.reflectScrolledClipView(returned.contentView)
        try await until("the list reads its new offset") { near(40) }
        browser.columnMemory.capture(first)
        window.contentView = SideColumnView(browser: browser)
        try await until("a rebuilt column lands where it was left") { near(40) && liveList() != nil }
        #expect(near(40), "\(browser.columnMemory.offset(.list) ?? -1)")
        browser.askForSpace()
        try await until("the new space page shows") { browser.makingSpace }
        #expect(browser.makingSpace)
        browser.leaveSpaceCreation()
        try await until("the list is back where it was left") { !browser.makingSpace && near(40) }
        #expect(!browser.makingSpace)
        #expect(near(40), "\(browser.columnMemory.offset(.list) ?? -1)")
    }

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

    @Test func anInvalidatedReaderCannotReplaceTheLiveViewport() {
        let memory = ColumnMemory()
        let space = UUID()
        var transient: CGFloat? = 0
        memory.watch(.list) { 285 }
        memory.watch(.list) { transient }

        transient = nil
        memory.capture(space)

        #expect(memory.saved[space]?.list == 285)
    }

    @Test func anOldCompletionCannotFinishANewerHandoff() {
        let memory = ColumnMemory()
        let first = UUID(), second = UUID()
        let old = memory.begin(first)
        memory.note(.list, value: 45, in: first)
        let new = memory.begin(second)
        memory.note(.list, value: 90, in: second)

        memory.finish(old)

        #expect(memory.restoring)
        #expect(memory.saved[first]?.list == 45)
        memory.finish(new)
        #expect(!memory.restoring)
        #expect(memory.saved[second]?.list == 90)
    }
}

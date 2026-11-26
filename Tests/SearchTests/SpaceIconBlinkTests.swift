import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpaceIconBlinkTests {
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

    private static func picture(_ colour: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        colour.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        NSColor.white.setFill()
        NSRect(x: 8, y: 8, width: 16, height: 16).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private static let colours: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange]

    private func fill(_ browser: Browser, _ name: String) async {
        for index in 0..<4 {
            let host = "\(name.lowercased())-\(index).example"
            await Favicons.shared.adopt(Self.picture(Self.colours[index]), for: host)
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://\(host)/")!, title: "\(name) \(index)")
        }
        browser.newTab()
        browser.tabs.last?.restore(url: URL(string: "https://\(name.lowercased())-unknown.example/")!, title: "\(name) unknown")
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
        let reduced = Store.settings.object(forKey: "motion.testReduced")
        Store.settings.set(false, forKey: "motion.testReduced")
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.splitView, prefs.sharesPins) = previous
            Store.settings.set(reduced, forKey: "motion.testReduced")
            NSApp.setActivationPolicy(policy)
        }
        let first = browser.spaceID
        await fill(browser, "First")
        browser.addSpace(named: "Second")
        try await until("the second space is on screen") { browser.spaceID != first }
        await fill(browser, "Second")
        try await body(browser, window, first, browser.spaceID)
    }

    private func shownRows(in window: NSWindow) -> [TabRowView] {
        (window.contentView?.kitSubviews(of: TabRowView.self) ?? []).filter {
            $0.tab != nil && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty
        }
    }

    @Test func rowsWithAKnownIconDrawItOnEveryFrameOfFiveSwitches() async throws {
        try await twoSpaces { browser, window, first, second in
            window.setContentSize(NSSize(width: browser.prefs.columnWidth, height: 600))
            window.contentView = SideColumnView(browser: browser)
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(800))

            let known = (browser.tabs + browser.parkedTabs).filter { !$0.label.hasSuffix("unknown") && !$0.isBlank }
            #expect(known.count == 8)
            #expect(known.allSatisfy { $0.icon != nil }, "\(known.filter { $0.icon == nil }.map(\.label))")

            var blinks: [String] = []
            var samples = 0
            var unknownShown = 0
            var targets: [UUID] = []
            for step in 0..<5 {
                let target = step % 2 == 0 ? first : second
                targets.append(target)
                let to = try #require(browser.spaces.firstIndex { $0.id == target })
                let from = try #require(browser.spaces.firstIndex { $0.id == browser.spaceID })
                let start = ProcessInfo.processInfo.systemUptime
                SpaceSwipe.shared.slide(browser, to: to, from: from)
                var landedAt: TimeInterval?
                while true {
                    let now = ProcessInfo.processInfo.systemUptime
                    if landedAt == nil, browser.spaceID == target, browser.spaceNext == nil, !browser.spaceMotion.moving { landedAt = now }
                    if let landedAt, now - landedAt > 0.5 { break }
                    if now - start > 4 {
                        Issue.record("switch \(step) did not land")
                        break
                    }
                    for row in shownRows(in: window) {
                        guard let read = row.benchIcon else { continue }
                        samples += 1
                        if (read["label"] as? String)?.hasSuffix("unknown") == true {
                            unknownShown += 1
                            #expect(read["monogram"] as? Bool == true)
                        }
                        if !TabRowView.iconDrawn(read) {
                            let ms = Int((now - start) * 1000)
                            blinks.append("switch \(step) +\(ms)ms \(read)")
                        }
                    }
                    try await Task.sleep(for: .milliseconds(2))
                }
            }
            #expect(samples > 100)
            #expect(unknownShown > 0)
            #expect(blinks.isEmpty, "\(blinks.count) row samples without their icon:\n\(blinks.prefix(40).joined(separator: "\n"))")
        }
    }

    @Test func aPooledRowShowsItsNewTabsIconAtOnceWhateverItShowedBefore() async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            NSApp.setActivationPolicy(policy)
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        root.wantsLayer = true
        window.contentView = root
        window.orderFrontRegardless()
        await Favicons.shared.adopt(Self.picture(.systemRed), for: "pooled-red.example")
        func tab(_ address: String, _ title: String) -> Tab {
            if browser.tabs.last?.isBlank == false { browser.newTab() }
            let made = browser.tabs.last!
            made.restore(url: URL(string: address)!, title: title)
            return made
        }
        let plain = tab("file:///nowhere/notes.html", "Notes")
        let red = tab("https://pooled-red.example/", "Red")
        #expect(plain.icon == nil)
        #expect(red.icon != nil)
        let shown: [Tab] = [plain, red, plain, red]
        var row = TabRowView.take(in: root)
        root.addSubview(row)
        var turns: [String] = []
        for (step, next) in shown.enumerated() {
            if step > 0 {
                row.recycle()
                row = TabRowView.take(in: root)
                if row.superview !== root { root.addSubview(row) }
            }
            row.frame = NSRect(x: 0, y: 40, width: 260, height: 30)
            row.show(next, in: browser, state: RowState())
            row.settleFromPool()
            try await Task.sleep(for: .milliseconds(40))
            let read = try #require(row.benchIcon)
            if !TabRowView.iconDrawn(read) || !((read["fading"] as? [String]) ?? []).isEmpty {
                turns.append("step \(step) \(next.label): \(read)")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        #expect(turns.isEmpty, "\(turns.joined(separator: "\n"))")
    }

    @Test func aSettledMarkTurnsAtOnceAndAnArrivalStillFadesInAsBefore() async throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 120), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 120))
        root.wantsLayer = true
        window.contentView = root
        let mark = RowMarkView(frame: NSRect(x: 20, y: 20, width: 16, height: 16))
        mark.letter = "A"
        root.addSubview(mark)
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(150))
        let icon = NSImage(data: Self.picture(.systemRed))!
        func moving() -> [String] { (mark.layer?.sublayers ?? []).flatMap { $0.animationKeys() ?? [] } }
        for step in 0..<4 {
            mark.settle()
            mark.icon = step % 2 == 0 ? icon : nil
            try await Task.sleep(for: .milliseconds(30))
            #expect(moving().isEmpty, "step \(step): \(moving())")
            let read = mark.benchPicture
            if step % 2 == 0 {
                #expect(read["shownContents"] as? Bool == true && read["shownHidden"] as? Bool == false, "step \(step): \(read)")
            } else {
                #expect(read["monogram"] as? Bool == true, "step \(step): \(read)")
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        mark.icon = icon
        try await Task.sleep(for: .milliseconds(30))
        #expect(moving().contains("transition"), "\(moving())")
    }
}

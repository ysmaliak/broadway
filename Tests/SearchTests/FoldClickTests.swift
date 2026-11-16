import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FoldClickTests {
    private var browsers: [Browser] = []
    private var windows: [NSWindow] = []
    private var restorePreferences: (() -> Void)?
    private var activationPolicy: NSApplication.ActivationPolicy?
    private var live: [UUID] = []

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        for id in live { LiveFolders.shared.remove(id) }
        restorePreferences?()
        if let activationPolicy { NSApp.setActivationPolicy(activationPolicy) }
        windows.removeAll()
        browsers.removeAll()
    }

    enum Kind: String, CaseIterable, Sendable { case handMade, live }
    enum Moment: String, CaseIterable, Sendable { case midUnfold, justLanded, midFold }

    @Test(arguments: Kind.allCases, Moment.allCases)
    func aQuickSecondClickFoldsBackWithoutARenameField(kind: Kind, moment: Moment) async throws {
        let (browser, folder, window) = try scene(kind, shut: moment != .midFold)
        let heading = try #require(heading(folder, in: window))
        let point = heading.convert(NSPoint(x: heading.bounds.width * 0.55, y: heading.bounds.midY), to: nil)
        let start = ProcessInfo.processInfo.systemUptime
        let gap = moment == .justLanded ? 0.3 : 0.09
        if let path = ProcessInfo.processInfo.environment["FOLD_FILM"] {
            let folder = URL(fileURLWithPath: path).appendingPathComponent("\(kind)-\(moment)")
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            filmed = folder
        }

        window.sendEvent(try event(.leftMouseDown, at: point, in: window, clicks: 1, stamped: start))
        window.sendEvent(try event(.leftMouseUp, at: point, in: window, clicks: 1, stamped: start + 0.03))
        let openedFirst = browser.tabGroups.first { $0.id == folder }?.collapsed
        var seen = pump(window, folder, for: gap)
        window.sendEvent(try event(.leftMouseDown, at: point, in: window, clicks: 2, stamped: start + gap))
        window.sendEvent(try event(.leftMouseUp, at: point, in: window, clicks: 2, stamped: start + gap + 0.03))
        seen += pump(window, folder, for: 0.6)

        #expect(openedFirst == (moment == .midFold), "the first click toggled the folder")
        #expect(browser.tabGroups.first { $0.id == folder }?.collapsed == (moment != .midFold), "the second click toggled it back")
        #expect(browser.editingGroupID == nil, "\(kind) \(moment): a quick second click does not start a rename")
        #expect(seen.fields == 0, "\(kind) \(moment): a rename field was shown in \(seen.fields) samples")
        #expect(seen.hiddenChevrons == 0, "\(kind) \(moment): the chevron was hidden in \(seen.hiddenChevrons) samples")
    }

    @Test(arguments: Kind.allCases)
    func aDoubleClickOnTheNameStillRenames(kind: Kind) throws {
        let (browser, folder, window) = try scene(kind, shut: true)
        let heading = try #require(heading(folder, in: window))
        let label = try #require(all(KitLabel.self, in: heading).first { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 })
        let point = label.convert(NSPoint(x: min(label.bounds.width / 2, 8), y: label.bounds.midY), to: nil)
        let start = ProcessInfo.processInfo.systemUptime

        window.sendEvent(try event(.leftMouseDown, at: point, in: window, clicks: 1, stamped: start))
        window.sendEvent(try event(.leftMouseUp, at: point, in: window, clicks: 1, stamped: start + 0.03))
        window.sendEvent(try event(.leftMouseDown, at: point, in: window, clicks: 2, stamped: start + 0.09))
        window.sendEvent(try event(.leftMouseUp, at: point, in: window, clicks: 2, stamped: start + 0.12))
        settle(window)

        #expect(browser.editingGroupID == folder)
        #expect(browser.tabGroups.first { $0.id == folder }?.collapsed == true)
        #expect(all(FolderEditField.self, in: heading).count == 1)
    }

    private struct Seen {
        var fields = 0
        var hiddenChevrons = 0
        static func += (lhs: inout Seen, rhs: Seen) {
            lhs.fields += rhs.fields
            lhs.hiddenChevrons += rhs.hiddenChevrons
        }
    }

    private func pump(_ window: NSWindow, _ folder: UUID, for seconds: TimeInterval) -> Seen {
        var seen = Seen()
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            window.contentView?.layoutSubtreeIfNeeded()
            CATransaction.flush()
            film(window)
            if let shown = heading(folder, in: window) {
                if !all(FolderEditField.self, in: shown).isEmpty { seen.fields += 1 }
                if all(KitTurnView.self, in: shown).allSatisfy(\.isHidden) { seen.hiddenChevrons += 1 }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))
        }
        return seen
    }

    private var filmed: URL?
    private var shots = 0

    private func film(_ window: NSWindow) {
        guard let filmed, let layer = window.contentView?.layer, shots < 400 else { return }
        let scale: CGFloat = 2
        let size = CGSize(width: layer.bounds.width * scale, height: 470 * scale)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        (layer.presentation() ?? layer).render(in: context)
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        let name = String(format: "%04d-%.4f.png", shots, CACurrentMediaTime())
        try? rep.representation(using: .png, properties: [:])?.write(to: filmed.appendingPathComponent(name))
        shots += 1
    }

    private func scene(_ kind: Kind, shut: Bool) throws -> (Browser, UUID, NSWindow) {
        let browser = makeBrowser(count: 6)
        let tabs = browser.tabs
        var folder = browser.addTabGroup(containing: tabs[1])
        for tab in tabs[2...3] { browser.move(tab, toGroup: folder) }
        if kind == .live {
            browser.removeTabGroup(folder)
            keepSetting(browser.prefs, \.liveFolders, "live.on")
            browser.prefs.liveFolders = true
            let made = LiveFolders.shared.add(name: "PRs", source: LiveSource(kind: .feed, address: "https://example.com/feed.xml"),
                                              space: browser.spaceID)
            live.append(made.id)
            let items = (1...3).map { LiveItem(key: "https://example.com/\($0)", title: "PR \($0)") }
            LiveFolders.shared.apply(.items(items, nil), to: made.id)
            browser.syncLive()
            folder = made.id
            if browser.tabGroups.first(where: { $0.id == folder })?.collapsed == true { browser.toggleTabGroup(folder) }
        }
        browser.editingGroupID = nil
        browser.select(tabs[5])
        let window = makeWindow(browser)
        settle(window)
        if shut {
            browser.toggleTabGroup(folder)
            settle(window)
        }
        return (browser, folder, window)
    }

    private func heading(_ folder: UUID, in window: NSWindow) -> GroupHeadingView? {
        guard let root = window.contentView else { return nil }
        return all(GroupHeadingView.self, in: root).first { $0.group?.id == folder && !$0.isHiddenOrHasHiddenAncestor }
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clicks: Int,
                       stamped timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: timestamp,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseUp ? 0 : 1
        ))
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + all(type, in: sub) }
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
    }

    private func makeBrowser(count: Int) -> Browser {
        _ = NSApplication.shared
        activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let prefs = Shared.prefs
        if restorePreferences == nil {
            let previous = (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                            prefs.addressBar, prefs.sideWidth, prefs.newTabPlace)
            restorePreferences = {
                (prefs.usesTabGroups, prefs.splitView, prefs.usesSpaces, prefs.sharesPins,
                 prefs.addressBar, prefs.sideWidth, prefs.newTabPlace) = previous
            }
        }
        prefs.usesTabGroups = true
        prefs.splitView = false
        prefs.usesSpaces = false
        prefs.sharesPins = false
        prefs.addressBar = true
        prefs.sideWidth = 258
        prefs.newTabPlace = .end
        let browser = Browser(record: WindowRecord())
        browser.closeAll()
        let space = Space(id: UUID(), name: "Click fixture", colour: 0, sharesSignIns: true)
        browser.spaces = [space]
        browser.spaceID = space.id
        browsers.append(browser)
        for index in 0..<count {
            browser.newTab()
            browser.tabs.last?.restore(url: URL(string: "about:blank#row-\(index)")!, title: "row \(index)")
        }
        return browser
    }

    private func makeWindow(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: browser.prefs.sideWidth, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = SideColumnView(browser: browser)
        window.orderFrontRegardless()
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) }, "never on a screen")
        windows.append(window)
        return window
    }
}

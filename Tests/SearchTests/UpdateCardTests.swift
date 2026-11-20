import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct UpdateCardTests {
    private let updates = Updates.shared

    init() {
        _ = NSApplication.shared
        Updates.shared.unpretend()
        Ask.testing = nil
        Ask.asked = []
    }

    private func column(_ browser: Browser, width: CGFloat = 258) -> (SideColumnView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 640), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let made = SideColumnView(browser: browser)
        window.contentView = made
        made.layoutSubtreeIfNeeded()
        return (made, window)
    }

    private func card(in view: NSView) -> UpdateCardView? {
        view.kitSubviews(of: UpdateCardView.self).first { !$0.isHiddenOrHasHiddenAncestor && $0.frame.height > 0 }
    }

    private func settle(_ view: NSView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
    }

    private func playing() -> MiniPlayer {
        MiniPlayer(surface: MiniPlayer.Item(id: UUID(), title: "Midnight City", detail: "M83", site: "example.com", art: nil, playing: true,
                                            pair: .tracks, previous: true, next: true, position: nil, live: false, rate: 1, speed: false,
                                            seekable: false, muted: false, skip: 15))
    }

    private func waitFor(_ check: () -> Bool, within seconds: Double = 3) async {
        let end = Date().addingTimeInterval(seconds)
        while !check(), Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func spin(_ check: () -> Bool, within seconds: Double = 3) {
        let end = Date().addingTimeInterval(seconds)
        while !check(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @Test func theCardShowsOnlyWhileAnUpdateIsAvailable() throws {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let (view, window) = column(browser)
        defer { window.close() }
        let bare = view.footHeight

        let before = card(in: view)
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        settle(view)
        let after = try #require(card(in: view))

        #expect(before == nil)
        #expect(view.footHeight == bare + UpdateCardView.foot)
        #expect(after.accessibilityRole() == .group)
        #expect(after.accessibilityLabel() == "Update available, version 0.1")
        #expect(after.toolTip == "Version 0.1")
        #expect(after.benchState["title"] as? String == "Update Available")
        #expect(after.benchState["buttonTitle"] as? String == "Install")
        #expect(after.benchState["button"] as? String == "Install Update")
        #expect(after.benchState["hide"] as? String == "Hide")
        updates.unpretend()
        settle(view)
        spin { card(in: view) == nil }
        #expect(card(in: view) == nil)
        #expect(view.footHeight == bare)
    }

    @Test func theCardHasNoIconAndItsTitleStartsAsFarInAsInstallEnds() throws {
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        for width in [Metrics.sideMin, 258, Metrics.sideMax] {
            let (view, window) = column(browser, width: width)
            defer { window.close() }
            let update = try #require(card(in: view))
            let state = update.benchState
            let inner = try #require(update.subviews.first)
            let shown = inner.subviews.filter { !($0 is NSGlassEffectView) && !$0.isHidden }
            let title = try #require(shown.compactMap { $0 as? KitLabel }.first)

            #expect(state["titleStart"] as? CGFloat == UpdateCardView.pad)
            #expect(state["trailingEnd"] as? CGFloat == UpdateCardView.pad)
            #expect(UpdateCardView.pad == SideLook.rowLead)
            #expect(state["titleCut"] as? Bool == false, "\(state)")
            #expect(shown.count == 3)
            #expect(shown.filter { $0.accessibilityLabel() != "Hide" && $0.frame.minX >= 0 && $0.frame.minX < title.frame.minX }.isEmpty)
            #expect(update.kitSubviews(of: KitSymbol.self).map(\.name) == ["xmark"])
            #expect(UpdateCardView.textRoom(card: inner.frame.width) == title.frame.width)
        }
    }

    @Test func everyStateHasItsWordsAtTheNarrowestAndWidestSidebar() throws {
        defer { updates.unpretend() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let states: [(UpdatePhase, Double?, String, String)] = [
            (.available, nil, "Update Available", "button"),
            (.checking, nil, "Checking for Updates", "spinner"),
            (.downloading, 0.42, "Downloading", "percent"),
            (.downloading, nil, "Downloading", "spinner"),
            (.installing, nil, "Installing", "spinner"),
            (.failed, nil, "Couldn't Update", "button"),
        ]

        for width in [Metrics.sideMin, Metrics.sideMax] {
            let (view, window) = column(browser, width: width)
            defer { window.close() }
            for (phase, progress, title, trailing) in states {
                updates.pretend(version: "0.7", build: "700", phase: phase, progress: progress, trouble: phase == .failed ? "The disk is full" : nil)
                settle(view)
                let update = try #require(card(in: view), "\(phase) \(width)")
                let state = update.benchState
                let called = "\(phase) \(progress ?? -1) at \(width)"
                let needs = try #require(state["titleNeeds"] as? CGFloat)
                let room = try #require(state["textRoom"] as? CGFloat)
                let box = try #require(state["card"] as? [CGFloat])
                let line = try #require(state["lineBox"] as? [CGFloat])

                #expect(state["title"] as? String == title, "\(called)")
                #expect(state["trailing"] as? String == trailing, "\(called)")
                #expect(state["titleCut"] as? Bool == (needs > room + 0.5), "\(called)")
                #expect(state["trailingEnd"] as? CGFloat == UpdateCardView.pad, "\(called)")
                #expect(state["titleStart"] as? CGFloat == UpdateCardView.pad, "\(called)")
                if width == Metrics.sideMax { #expect(state["titleCut"] as? Bool == false, "\(called)") }
                switch (phase, progress) {
                case (.downloading, .some(let part)):
                    #expect(state["percent"] as? String == "42%", "\(called)")
                    #expect(state["percentCut"] as? Bool == false, "\(called)")
                    #expect(state["lineShown"] as? Bool == true, "\(called)")
                    #expect(abs(line[2] - (box[2] * part).rounded()) <= 1, "\(called) \(line)")
                    #expect(line[3] == UpdateCardView.lineHeight && line[1] == UpdateCardView.height - UpdateCardView.lineHeight, "\(called) \(line)")
                    #expect(state["label"] as? String == "Downloading, 42%", "\(called)")
                case (.downloading, nil):
                    #expect(state["line"] as? Int == -1, "\(called)")
                    #expect(state["spinner"] as? Bool == true, "\(called)")
                case (.installing, _):
                    #expect(state["lineShown"] as? Bool == true && abs(line[2] - box[2]) <= 1, "\(called) \(line)")
                case (.failed, _):
                    #expect(state["buttonTitle"] as? String == "Try Again", "\(called)")
                    #expect(state["tip"] as? String == "The disk is full", "\(called)")
                case (.checking, _):
                    #expect(state["spinner"] as? Bool == true, "\(called)")
                    #expect(state["lineShown"] as? Bool == false, "\(called)")
                default:
                    #expect(state["buttonTitle"] as? String == "Install", "\(called)")
                    #expect(state["lineShown"] as? Bool == false, "\(called)")
                }
            }
        }
    }

    @Test func theProgressLineIsTheAccentColour() throws {
        updates.pretend(version: "0.7", build: "700", phase: .downloading, progress: 0.5)
        defer { updates.unpretend() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let (view, window) = column(browser)
        defer { window.close() }
        let update = try #require(card(in: view))
        var accent = NSColor.controlAccentColor
        update.effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent }

        let colour = try #require(update.benchState["lineColour"] as? [CGFloat])

        #expect(colour.count == 4)
        #expect(abs(colour[0] - accent.redComponent) < 0.02 && abs(colour[1] - accent.greenComponent) < 0.02
            && abs(colour[2] - accent.blueComponent) < 0.02, "\(colour)")
    }

    @Test func theCrossHidesItUntilANewerUpdateIsFound() {
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        let flow = updates.flow

        flow.hide()
        let hidden = flow.card
        updates.pretend(version: "0.1", build: "200")
        let same = flow.card
        updates.pretend(version: "0.1", build: "201")

        #expect(!hidden)
        #expect(!same)
        #expect(flow.card)
    }

    @Test func aPrivateWindowAndAFoldedColumnHaveNoCard() {
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        let folded = Browser(record: WindowRecord())
        defer {
            quiet.closeAll()
            folded.closeAll()
        }

        let (quietView, quietWindow) = column(quiet)
        folded.folded = true
        let (foldedView, foldedWindow) = column(folded)
        defer {
            quietWindow.close()
            foldedWindow.close()
        }

        #expect(card(in: quietView) == nil)
        #expect(card(in: foldedView) == nil)
        folded.folded = false
        settle(foldedView)
        #expect(card(in: foldedView) != nil)
    }

    @Test func itSitsUnderTheMiniPlayerNearestTheFoot() throws {
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.mini = playing()

        let (view, window) = column(browser, width: Metrics.sideMin)
        defer { window.close() }

        let mini = try #require(view.kitSubviews(of: MiniPlayerView.self).first { !$0.isHidden })
        let update = try #require(card(in: view))
        let foot = try #require(view.kitSubviews(of: SpaceFootView.self).first)
        #expect(update.frame.minY + UpdateCardView.closeOut == mini.frame.maxY)
        #expect(update.frame.maxY == foot.frame.minY)
        #expect(mini.frame.height == MiniPlayerView.full)
        let box = try #require(update.benchState["card"] as? [CGFloat])
        #expect(box[2] == Metrics.sideMin - Metrics.sideInset * 2)
        #expect(update.benchState["titleCut"] as? Bool == false, "\(update.benchState)")
    }

    @Test func installAsksFirstOnlyWhenSomethingWouldBeLost() {
        let cases: [(RestartLoss, String?)] = [
            (RestartLoss(), nil),
            (RestartLoss(privateWindows: 1), "Restarting now closes your private window"),
            (RestartLoss(downloads: 1), "Restarting now stops a download"),
            (RestartLoss(live: 1), "Restarting now ends a call or recording"),
            (RestartLoss(typed: true), "Restarting now loses what you typed on a page and haven't sent"),
            (RestartLoss(privateWindows: 2, downloads: 3, live: 1),
             "Restarting now closes your private windows, stops 3 downloads and ends a call or recording"),
        ]
        let was = UpdateRestart.gather
        defer { UpdateRestart.gather = was }
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        Ask.testing = false
        defer { Ask.testing = nil }

        var results: [(asked: Bool, restarted: Bool)] = []
        for (loss, _) in cases {
            UpdateRestart.gather = { done in done(loss) }
            Ask.asked = []
            let before = updates.restartsAsked
            updates.install(over: nil)
            results.append((!Ask.asked.isEmpty, updates.restartsAsked > before))
        }

        for (index, (loss, words)) in cases.enumerated() {
            #expect(loss.sentence == words)
            #expect(results[index].asked == (words != nil))
            #expect(results[index].restarted == (words == nil))
            #expect(!(words ?? "").contains(";"))
        }
        Ask.testing = true
        UpdateRestart.gather = { done in done(RestartLoss(downloads: 1)) }
        let before = updates.restartsAsked
        updates.install(over: nil)
        #expect(Ask.asked.last == RestartLoss.title)
        #expect(updates.restartsAsked == before + 1)
    }

    @Test func theLossIsReadFromPrivateWindowsAndDownloads() {
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        let plain = Browser(record: WindowRecord())
        defer {
            quiet.closeAll()
            plain.closeAll()
        }
        let fetches = Fetches()

        var calm: RestartLoss?
        RestartLoss.gather(browsers: [plain], fetches: fetches) { calm = $0 }
        var found: RestartLoss?
        RestartLoss.gather(browsers: [plain, quiet], fetches: fetches) { found = $0 }
        spin { calm != nil && found != nil }

        #expect(calm?.nothing == true)
        #expect(found?.privateWindows == 1)
        #expect(RestartLoss.counted([FetchEntry(name: "a.zip", request: nil, webView: nil)]) == 1)
    }

    private func versionRow(_ browser: Browser, query: String = "") throws -> (SettingsRowView, KitBroadwayButton) {
        let shell = SettingsShell()
        if query.isEmpty { shell.go(to: .general) } else { shell.query = query }
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "updates.version" })
        let button = try #require(row.kitSubviews(of: KitBroadwayButton.self).first)
        return (row, button)
    }

    @Test func theMenuItemAndTheSettingsButtonDoTheSameInstall() async throws {
        let item = updates.installItem()
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        UpdateRestart.gather = { done in done(RestartLoss()) }
        defer { UpdateRestart.gather = { done in RestartLoss.gather(browsers: Browsers.all, fetches: Shared.fetches, then: done) } }

        let hiddenBefore = item.isHidden
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        await waitFor { !item.isHidden }
        let shownWhenOffered = !item.isHidden
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        let fromMenu = updates.restartsAsked
        var pressed: [String] = []
        for query in ["", "version"] {
            let (row, button) = try versionRow(browser, query: query)
            pressed.append(button.title)
            #expect(button.isEnabled)
            button.action?()
            let said = row.kitSubviews(of: NSTextField.self).map(\.stringValue)
            #expect(said.contains { $0.hasSuffix(" · Broadway 0.1 is available") }, "\(said)")
        }

        #expect(hiddenBefore)
        #expect(shownWhenOffered)
        #expect(item.title == "Install Update")
        #expect(fromMenu == 1)
        #expect(pressed == ["Install", "Install"])
        #expect(updates.restartsAsked == 3)
        updates.unpretend()
        await waitFor { item.isHidden }
        #expect(item.isHidden)
    }

    @Test func theMenuItemAndTheSettingsRowFollowEachState() async throws {
        let item = updates.installItem()
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        defer { updates.unpretend() }
        let states: [(UpdatePhase, Double?, String, Bool)] = [
            (.available, nil, "Broadway 0.7 is available", true),
            (.checking, nil, "Checking for updates", false),
            (.downloading, 0.42, "Downloading 42%", false),
            (.downloading, nil, "Downloading", false),
            (.installing, nil, "Installing", false),
            (.failed, nil, "Couldn't update · The disk is full", true),
        ]

        for (phase, progress, line, enabled) in states {
            updates.pretend(version: "0.7", build: "700", phase: phase, progress: progress, trouble: phase == .failed ? "The disk is full" : nil)
            await waitFor { !item.isHidden }
            let (row, button) = try versionRow(browser)
            let said = row.kitSubviews(of: NSTextField.self).map(\.stringValue)
            let menuOn = updates.validateMenuItem(item)

            #expect(!item.isHidden, "\(phase)")
            #expect(menuOn == enabled, "\(phase)")
            #expect(button.title == "Install", "\(phase)")
            #expect(button.isEnabled == enabled, "\(phase)")
            #expect(said.contains { $0.hasSuffix(" · " + line) }, "\(phase) \(said)")
            #expect(updates.line.hasSuffix(" · " + line), "\(phase) \(updates.line)")
        }
    }

    @Test func notNowLeavesTheUpdateAvailable() {
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        let was = UpdateRestart.gather
        defer { UpdateRestart.gather = was }
        UpdateRestart.gather = { done in done(RestartLoss(privateWindows: 1)) }
        Ask.testing = false
        defer { Ask.testing = nil }

        updates.install(over: nil)

        #expect(Ask.asked.last == RestartLoss.title)
        #expect(updates.restartsAsked == 0)
        #expect(updates.flow.shown == .available)
        #expect(!updates.flow.pressed)
    }

    private func keyInside(_ update: UpdateCardView, _ window: NSWindow, _ called: String) throws {
        let size = try #require(window.contentView?.bounds.size)
        let reach = (UpdateCardView.closeReach - UpdateCardView.closeSize) / 2
        update.benchHover(true)
        defer { update.benchHover(false) }
        let state = update.benchState
        let plain = try #require(state["close"] as? [CGFloat])
        let drawn = try #require(state["closeDrawn"] as? [CGFloat])
        #expect(state["closeShown"] as? Bool == true, "\(called)")
        #expect(drawn[2] > plain[2], "\(called) \(drawn) \(plain)")
        for (box, kind) in [(plain, "plain"), (drawn, "grown")] {
            #expect(box[0] >= UpdateCardView.closeEdge, "\(called) \(kind) \(box)")
            #expect(box[1] >= UpdateCardView.closeEdge, "\(called) \(kind) \(box)")
            #expect(box[0] + box[2] <= size.width - UpdateCardView.closeEdge, "\(called) \(kind) \(box)")
            #expect(box[1] + box[3] <= size.height - UpdateCardView.closeEdge, "\(called) \(kind) \(box)")
            #expect(box[0] >= 26 || box[1] >= 26, "\(called) \(kind) \(box)")
        }
        #expect(plain[0] - reach >= 0, "\(called) \(plain)")
    }

    @Test func theCloseKeyStaysFourPointsInsideTheWindowAtEveryWidth() throws {
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        for width in [Metrics.sideMin, 258, Metrics.sideMax] {
            let browser = Browser(record: WindowRecord())
            defer { browser.closeAll() }
            let (view, window) = column(browser, width: width)
            defer { window.close() }
            let update = try #require(card(in: view))
            let box = try #require(update.benchState["card"] as? [CGFloat])
            let plain = try #require(update.benchState["close"] as? [CGFloat])
            #expect(abs(plain[1] + plain[3] - (box[1] + box[3] + UpdateCardView.closeOut)) < 0.5)
            #expect(box[0] == Metrics.sideInset)
            try keyInside(update, window, "column \(width)")
        }
    }

    @Test func theCrossShowsOnHoverHangsOutsideTheCornerAndHidesTheCard() throws {
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let (view, window) = column(browser)
        defer { window.close() }
        let update = try #require(card(in: view))
        let buttons = update.kitSubviews(of: KitButton.self)
        let hide = try #require(buttons.first { $0.accessibilityLabel() == "Hide" })
        let install = try #require(buttons.first { $0.accessibilityLabel() == "Install Update" })
        let box = try #require(update.benchState["card"] as? [CGFloat])
        let closeBox = try #require(update.benchState["close"] as? [CGFloat])
        let cross = NSPoint(x: closeBox[0] + closeBox[2] / 2, y: closeBox[1] + closeBox[3] - 3)
        let beside = NSPoint(x: box[0] + box[2] / 2, y: box[1] + box[3] + 3)
        let before = view.hitTest(cross)
        let keys = KitFocus.keyboardAccess
        defer {
            KitFocus.keyboardAccess = keys
            KitHoverView.pointerStandIn = nil
        }

        KitHoverView.pointerStandIn = (window, NSPoint(x: box[0] + 20, y: box[1] + box[3] / 2))
        update.settleHover()
        KitFocus.keyboardAccess = { true }
        let shown = update.benchState["closeShown"] as? Bool
        let hit = view.hitTest(cross)
        let passed = view.hitTest(beside)
        let rim = view.hitTest(NSPoint(x: closeBox[0] + closeBox[2] + 2, y: closeBox[1] + 4))
        let landed = hit.map { $0 === hide || $0.isDescendant(of: hide) } ?? false
        if landed { hide.action?() }
        settle(view)
        spin { card(in: view) == nil }

        #expect(closeBox[2] == UpdateCardView.closeSize)
        #expect(abs(closeBox[0] - (box[0] - UpdateCardView.closeAside(card: box[2]))) < 0.5)
        #expect(abs(closeBox[1] + closeBox[3] - (box[1] + box[3] + UpdateCardView.closeOut)) < 0.5)
        #expect(before !== hide)
        #expect(shown == true)
        #expect(landed)
        #expect(passed.map { !$0.isDescendant(of: update) } ?? true)
        #expect(rim === hide)
        #expect(hide.acceptsFirstResponder && install.acceptsFirstResponder)
        #expect(!updates.flow.card)
        #expect(card(in: view) == nil)
    }
}

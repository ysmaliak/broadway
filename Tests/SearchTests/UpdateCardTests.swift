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

    private func waitFor(_ check: () -> Bool, within seconds: Double = 3) {
        let end = Date().addingTimeInterval(seconds)
        while !check(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    @Test func theCardShowsOnlyWhileAnUpdateWaits() throws {
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
        #expect(after.accessibilityLabel() == "Update Ready")
        #expect(after.benchState["button"] as? String == "Restart to Update")
        #expect(after.benchState["hide"] as? String == "Hide")
        updates.unpretend()
        settle(view)
        #expect(card(in: view) == nil)
        #expect(view.footHeight == bare)
    }

    @Test func theCardHasNoIconAndItsTitleStartsAsFarInAsRestartEnds() throws {
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
            #expect(state["restartEnd"] as? CGFloat == UpdateCardView.pad)
            #expect(UpdateCardView.pad == SideLook.rowLead)
            #expect(state["titleCut"] as? Bool == false, "\(state)")
            #expect(shown.count == 3)
            #expect(shown.filter { $0.frame.minX >= 0 && $0.frame.minX < title.frame.minX }.isEmpty)
            #expect(update.kitSubviews(of: KitSymbol.self).map(\.name) == ["xmark"])
            #expect(UpdateCardView.textRoom(card: inner.frame.width) == title.frame.width)
        }
    }

    @Test func theCrossHidesItUntilANewerUpdateIsStaged() {
        let wait = UpdateWait()
        wait.stage(StagedUpdate(version: "0.1", build: "200")) {}

        wait.hide()
        let hidden = wait.card
        wait.stage(StagedUpdate(version: "0.1", build: "200")) {}
        let same = wait.card
        wait.stage(StagedUpdate(version: "0.1", build: "201")) {}

        #expect(!hidden)
        #expect(!same)
        #expect(wait.card)
        #expect(wait.arrivals == 2)
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

    @Test func theRestartAsksFirstOnlyWhenSomethingWouldBeLost() {
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
            updates.restart(over: nil)
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
        updates.restart(over: nil)
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
        waitFor { calm != nil && found != nil }

        #expect(calm?.nothing == true)
        #expect(found?.privateWindows == 1)
        #expect(RestartLoss.counted([FetchEntry(name: "a.zip", request: nil, webView: nil)]) == 1)
    }

    @Test func theMenuItemAndTheSettingsButtonDoTheSameRestart() throws {
        let item = updates.restartItem()
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        UpdateRestart.gather = { done in done(RestartLoss()) }
        defer { UpdateRestart.gather = { done in RestartLoss.gather(browsers: Browsers.all, fetches: Shared.fetches, then: done) } }

        let hiddenBefore = item.isHidden
        updates.pretend(version: "0.1", build: "200")
        defer { updates.unpretend() }
        waitFor { !item.isHidden }
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
        let fromMenu = updates.restartsAsked
        var pressed: [String] = []
        for query in ["", "version"] {
            let shell = SettingsShell()
            if query.isEmpty { shell.go(to: .general) } else { shell.query = query }
            let view = SettingsPageView(browser: browser, shell: shell)
            view.rebuild()
            let row = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "updates.version" })
            let button = try #require(row.kitSubviews(of: KitBroadwayButton.self).first)
            pressed.append(button.title)
            #expect(button.isEnabled)
            button.action?()
            let said = row.kitSubviews(of: NSTextField.self).map(\.stringValue)
            #expect(said.contains { $0.hasSuffix(" · " + UpdateWords.ready) })
        }

        #expect(hiddenBefore)
        #expect(item.title == "Restart to Update")
        #expect(fromMenu == 1)
        #expect(pressed == ["Restart to Update", "Restart to Update"])
        #expect(updates.restartsAsked == 3)
        updates.unpretend()
        waitFor { item.isHidden }
        #expect(item.isHidden)
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
        let restart = try #require(buttons.first { $0.accessibilityLabel() == "Restart to Update" })
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
        let landed = hit.map { $0 === hide || $0.isDescendant(of: hide) } ?? false
        if landed { hide.action?() }
        settle(view)

        #expect(closeBox[2] == UpdateCardView.closeSize)
        #expect(abs(closeBox[0] - (box[0] - UpdateCardView.closeOut)) < 0.5)
        #expect(abs(closeBox[1] + closeBox[3] - (box[1] + box[3] + UpdateCardView.closeOut)) < 0.5)
        #expect(before !== hide)
        #expect(shown == true)
        #expect(landed)
        #expect(passed.map { !$0.isDescendant(of: update) } ?? true)
        #expect(hide.acceptsFirstResponder && restart.acceptsFirstResponder)
        #expect(!updates.wait.card)
        #expect(card(in: view) == nil)
    }
}

import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class MergedTurnTests {
    private var browser: Browser!
    private let reader = LiveFolders.shared.reader

    init() async throws {
        _ = NSApplication.shared
        keepSetting(Shared.prefs, \.liveFolders, "live.on")
        keepSettings("motion.testReduced")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesTabGroups = true
        browser.prefs.liveFolders = true
        LiveFolders.shared.reader = { _ in .failed }
        LiveFolders.shared.stackStagger = 0
        LiveFolders.shared.settles = 0
        MergedCrowd.forget()
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func tearDown() async {
        MergedCrowd.forget()
        LiveFolders.shared.mergedHold = LiveFolders.hold
        LiveFolders.shared.stackStagger = LiveFolders.stagger
        LiveFolders.shared.settles = LiveFolders.settles
        LiveFolders.shared.reader = reader
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
        LiveRefs.known = [:]
        browser.prefs.liveFolders = false
        browser.closeAll()
        browser = nil
    }

    private func key(_ number: Int) -> String { "https://github.com/acme/rocket/pull/\(number)" }

    private func pull(_ number: Int, position: Int? = nil, label: String? = "Approved") -> LiveItem {
        LiveItem(key: key(number), title: "PR \(number)", label: label, author: "dana", checks: .passing,
                 branch: LiveBranch(repository: "acme/rocket", base: "base-\(number)", head: "head-\(number)",
                                    stack: position == nil ? nil : 21, position: position, stackRead: true))
    }

    private var rail: [LiveItem] { [pull(61, position: 1), pull(62, position: 2), pull(63, position: 3), pull(64, position: 4), pull(70)] }

    private func prs(_ items: [LiveItem]) -> LiveFolder {
        let made = LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: browser.spaceID)
        LiveFolders.shared.apply(.items(LiveStacks.arranged(items), nil), to: made.id)
        browser.syncLive()
        return made
    }

    private func tab(_ made: LiveFolder, _ number: Int) -> Tab? {
        browser.tabs(in: made.id).first { $0.liveKey == key(number) }
    }

    private func shown(_ made: LiveFolder) -> (SideColumnView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 258, height: 700), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        browser.sightForBench = true
        browser.unfoldFolder(made.id)
        let column = SideColumnView(browser: browser)
        window.contentView = column
        column.layoutSubtreeIfNeeded()
        return (column, window)
    }

    private func row(_ number: Int, in column: NSView) -> TabRowView? {
        column.kitSubviews(of: TabRowView.self).first { $0.accessibilityLabel() == "PR \(number)" && $0.window != nil }
    }

    private func settle(_ column: NSView) {
        browser.syncLive()
        column.needsLayout = true
        column.layoutSubtreeIfNeeded()
    }

    private func merge(_ number: Int, column: NSView) {
        LiveFolders.shared.pageMerged(URL(string: key(number))!, space: browser.spaceID)
        settle(column)
    }

    private func sign(_ row: TabRowView) -> [CAShapeLayer] {
        row.kitSubviews(of: MergedCanvas.self).flatMap { $0.layer?.sublayers ?? [] }.compactMap { $0 as? CAShapeLayer }
    }

    private func badge(_ row: TabRowView) -> ChecksMarkView? {
        row.kitSubviews(of: ChecksMarkView.self).first
    }

    @Test func theRowThatTurnsDrawsTheBranchesJoiningInPlaceOfItsIcon() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let turned = try #require(row(1, in: column))

        merge(1, column: column)

        #expect(turned.mergedForm == .full)
        #expect(turned.plays == 1)
        #expect(turned.mergedLayers == 4)
        #expect(sign(turned).count == 4)
        #expect(turned.mergedTraces == 2)
        #expect(turned.mergedMoving > 0)
        #expect(badge(turned)?.isHidden == true)
        #expect(turned.arrivals == 1)
        let other = try #require(row(2, in: column))
        #expect(other.mergedForm == nil)
        #expect(other.mergedTraces == 0)
        #expect(other.plays == 0)
    }

    @Test func theJoinPlaysOnceHoweverOftenTheRowIsDrawnAgain() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let turned = try #require(row(1, in: column))

        merge(1, column: column)
        let moving = turned.mergedMoving
        merge(1, column: column)
        browser.select(try #require(tab(made, 2)))
        settle(column)

        #expect(turned.plays == 1)
        #expect(turned.mergedForm == .full)
        #expect(turned.mergedMoving == moving)
        #expect(sign(turned).count == 4)
    }

    @Test func theSignIsDrawnInTheColourOfTheWord() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let turned = try #require(row(1, in: column))

        merge(1, column: column)

        let word = try #require(turned.kitSubviews(of: BylineView.self).first?.stateTint).cgColor
        let drawn = sign(turned)
        #expect(drawn.count == 4)
        #expect(drawn.filter { $0.strokeColor == word }.count == 3)
        #expect(drawn.filter { $0.fillColor == word }.count == 1)
    }

    @Test func theSignKeepsThreeToOneOnEveryGroundARowCanHave() {
        var looks: [(String, SpaceLook)] = SpaceLook.themes.map { ($0.name, $0.look) }
        looks += SpaceLook.palette.map { ($0.name, SpaceLook(colour: $0.id)) }
        looks += ["000000", "000354", "3139FB", "FB3A4D", "39FF14", "FFFFFF", "E8FF1A", "FFD3E0"].flatMap { hex in
            [0.8, 2.0].map { strength -> (String, SpaceLook) in
                var look = SpaceLook(colour: "custom", custom: hex)
                look.intensity = strength
                return ("\(hex) \(strength)", look)
            }
        }

        var failing: [String] = []
        for (name, look) in looks {
            for dark in [false, true] {
                let ground = look.ground(dark: dark)
                let ink = ChecksTint.colour(.passing, merged: true, dark: ground.lightInk, stops: ground.stops, frame: true, lift: ground.lift)
                let all = ChecksTint.grounds(ground.stops, frame: true, dark: ground.lightInk, lift: ground.lift)
                if ChecksTint.worst(ink, on: all) < ChecksTint.minimum { failing.append("\(name) \(dark)") }
            }
        }
        for dark in [false, true] {
            let ink = ChecksTint.colour(.passing, merged: true, dark: dark, stops: nil, frame: false, lift: 0)
            if ChecksTint.worst(ink, on: ChecksTint.grounds(nil, frame: false, dark: dark, lift: 0)) < ChecksTint.minimum { failing.append("plain \(dark)") }
        }

        #expect(failing.isEmpty, "\(failing)")
    }

    @Test func aRowThatIsMergedButNotTurningKeepsThePurpleCheckAndTheWord() throws {
        let made = prs([pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        LiveFolders.shared.apply(.items([pull(1, label: "Merged"), pull(2)], nil), to: made.id)
        settle(column)

        let found = try #require(row(1, in: column))
        #expect(!LiveFolders.shared.turning(key(1)))
        #expect(found.mergedForm == nil)
        #expect(found.mergedTraces == 0)
        #expect(found.plays == 0)
        #expect(badge(found)?.isHidden == false)
        #expect(badge(found)?.merged == true)
        #expect(tab(made, 1)?.liveItem?.byline == "dana • Merged")
    }

    @Test func theRowThatLeavesAfterTheHoldLeavesNothingBehind() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        _ = browser.open(try #require(URL(string: "about:blank")), foreground: true)
        settle(column)

        merge(1, column: column)
        let worn = row(1, in: column)?.mergedForm
        try await Task.sleep(for: .milliseconds(400))
        settle(column)
        try await Task.sleep(for: .milliseconds(400))
        settle(column)

        #expect(worn == .full)
        #expect(tab(made, 1) == nil)
        #expect(row(1, in: column) == nil)
        #expect(!LiveFolders.shared.turning(key(1)))
        #expect(column.kitSubviews(of: MergedCanvas.self).isEmpty)
        let stayed = try #require(row(2, in: column))
        #expect(stayed.mergedForm == nil)
        #expect(stayed.mergedTraces == 0)
    }

    @Test func theRowKeptOpenIsAnOrdinaryRowAfterTheHold() async throws {
        LiveFolders.shared.mergedHold = 0.05
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let page = try #require(tab(made, 1))
        browser.select(page)
        settle(column)

        merge(1, column: column)
        let worn = row(1, in: column)?.mergedForm
        try await Task.sleep(for: .milliseconds(400))
        settle(column)

        let kept = try #require(row(1, in: column))
        #expect(worn == .full)
        #expect(page.liveItem == nil)
        #expect(kept.mergedForm == nil)
        #expect(kept.mergedLayers == 0)
        #expect(kept.mergedTraces == 0)
        #expect(kept.mergedMoving == 0)
    }

    @Test func aStackMemberTurnsQuietlyAndIsOrdinaryAgainWhenItComesBackOpen() throws {
        LiveFolders.shared.mergedHold = 5
        let made = prs(rail)
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        merge(63, column: column)
        let lead = try #require(row(63, in: column))
        let member = try #require(row(62, in: column))
        let worn = (lead.mergedForm, member.mergedForm, member.mergedLayers, member.plays)
        LiveRefs.known[LiveRefs.slot(key(62), space: browser.spaceID)] = LiveRefs.Known(updated: nil, branch: pull(62, position: 2).branch, read: Date(),
                                                                                         state: .open)
        LiveFolders.shared.apply(.items(LiveStacks.arranged(rail.filter { $0.key != key(63) }), nil), to: made.id)
        settle(column)

        #expect(worn.0 == .full)
        #expect(worn.1 == .quiet)
        #expect(worn.2 == 4)
        #expect(worn.3 == 0)
        #expect(!LiveFolders.shared.turning(key(62)))
        let back = try #require(row(62, in: column))
        #expect(back.mergedForm == nil)
        #expect(back.mergedLayers == 0)
        #expect(back.mergedTraces == 0)
        #expect(back.mergedMoving == 0)
        #expect(badge(back)?.isHidden == false)
        #expect(try #require(row(63, in: column)).mergedForm == .full)
    }

    @Test func ofSeveralUnrelatedRowsFoundMergedInOneReadOnlyOnePlays() throws {
        let made = prs([pull(1), pull(2), pull(3), pull(4)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        LiveFolders.shared.apply(.items([pull(1, label: "Merged"), pull(2, label: "Merged"), pull(3, label: "Merged"), pull(4)], nil), to: made.id)
        settle(column)

        let rows = try [1, 2, 3, 4].map { try #require(row($0, in: column)) }
        let forms = rows.prefix(3).map(\.mergedForm)
        #expect(forms.filter { $0 == .full }.count == 1)
        #expect(forms.filter { $0 == .quiet }.count == 2)
        #expect(rows.map(\.plays).reduce(0, +) == 1)
        #expect(rows.prefix(3).allSatisfy { $0.mergedLayers == 4 && badge($0)?.isHidden == true })
        #expect(rows.map(\.arrivals) == [1, 1, 1, 0])
        #expect(rows[3].mergedForm == nil)
        #expect(rows[3].mergedTraces == 0)
    }

    @Test func underReduceMotionTheRowTakesItsStillForm() throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        merge(1, column: column)

        let turned = try #require(row(1, in: column))
        #expect(turned.mergedForm == .still)
        #expect(turned.mergedLayers == 4)
        #expect(turned.mergedTraces == 2)
        #expect(turned.mergedMoving == 0)
        #expect(turned.plays == 0)
        #expect(turned.arrivals == 0)
    }

    @Test func aRowThatTurnsWhileTheWindowIsOutOfSightTakesItsStillForm() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        browser.sightForBench = false

        merge(1, column: column)

        let turned = try #require(row(1, in: column))
        #expect(turned.mergedForm == .still)
        #expect(turned.mergedLayers == 4)
        #expect(turned.mergedMoving == 0)
        #expect(turned.plays == 0)
        #expect(tab(made, 1)?.leads == false)
    }

    @Test func aClickDuringTheMomentLandsWhereItDidBefore() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let turned = try #require(row(1, in: column))
        let spots = [0.06, 0.1, 0.5, 0.9].map { share in
            turned.convert(NSPoint(x: turned.bounds.width * share, y: turned.bounds.midY), to: column.superview)
        }
        let before = spots.map { column.hitTest($0) }

        merge(1, column: column)

        let during = spots.map { column.hitTest($0) }
        #expect(turned.mergedForm == .full)
        #expect(before.allSatisfy { $0 != nil })
        #expect(zip(before, during).allSatisfy { $0 === $1 })
        #expect(during.allSatisfy { !($0 is MergedCanvas) })
    }

    @Test func theBenchSetsTheHoldAndPicksNoLook() async {
        let answer = await withCheckedContinuation { (done: CheckedContinuation<[String: Any], Never>) in
            BenchMergedTurn.run(["hold": 2.0, "style": "fuse"], browser: browser) { done.resume(returning: $0) }
        }

        #expect(answer["hold"] as? Double == 2)
        #expect(LiveFolders.shared.mergedHold == 2)
        #expect(answer["style"] == nil)
        #expect(answer["picked"] == nil)
    }

    @Test func onlyTheFirstRowOfACrowdPlays() {
        MergedCrowd.forget()
        #expect(MergedCrowd.first(now: 10))
        #expect(!MergedCrowd.first(now: 10.1))
        #expect(!MergedCrowd.first(now: 10.4))
        #expect(MergedCrowd.first(now: 11))
        MergedCrowd.forget()
        #expect(MergedCrowd.first(now: 11.1))
    }
}

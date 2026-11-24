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

    private func canvas(_ row: TabRowView) -> MergedCanvas? {
        row.kitSubviews(of: MergedCanvas.self).first
    }

    private func fill(_ row: TabRowView) -> CALayer? {
        canvas(row)?.layer?.sublayers?.first { !($0 is CAGradientLayer) }
    }

    private func band(_ row: TabRowView) -> CAGradientLayer? {
        canvas(row)?.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first
    }

    private func pump(_ column: NSView, for seconds: Double) async throws {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            settle(column)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static var looks: [(String, SpaceLook)] {
        var looks: [(String, SpaceLook)] = SpaceLook.themes.map { ($0.name, $0.look) }
        looks += SpaceLook.palette.map { ($0.name, SpaceLook(colour: $0.id)) }
        looks += ["000000", "000354", "3139FB", "FB3A4D", "39FF14", "FFFFFF", "E8FF1A", "FFD3E0", "F2EEE6", "8A8F98", "D0342C",
                  "1E7A46", "8250DF"].flatMap { hex in
            [0.8, 2.0].map { strength -> (String, SpaceLook) in
                var look = SpaceLook(colour: "custom", custom: hex)
                look.intensity = strength
                return ("\(hex) \(strength)", look)
            }
        }
        return looks
    }

    private struct Ground {
        let name: String
        let stops: [Oklch?]
        let frame: Bool
        let dark: Bool
        let lift: Double
        let ink: Oklch
    }

    private static var grounds: [Ground] {
        var out: [Ground] = []
        for (name, look) in looks {
            for dark in [false, true] {
                let ground = look.ground(dark: dark)
                let ink = ChecksTint.colour(.passing, merged: true, dark: ground.lightInk, stops: ground.stops, frame: true, lift: ground.lift)
                let average = Paint.Ground(stops: ground.stops, lightInk: ground.lightInk).average
                out.append(Ground(name: "\(name) \(dark)", stops: ground.stops + [average], frame: true, dark: ground.lightInk,
                                  lift: ground.lift, ink: ink))
            }
        }
        for dark in [false, true] {
            let ink = ChecksTint.colour(.passing, merged: true, dark: dark, stops: nil, frame: false, lift: 0)
            out.append(Ground(name: "plain \(dark)", stops: [nil], frame: false, dark: dark, lift: 0, ink: ink))
        }
        return out
    }

    private static let pills: [ChecksTint.Pill] = [.none, .hover, .picked, .live, .pickedLive]

    private static func distance(_ a: ChecksTint.RGB, _ b: ChecksTint.RGB) -> Double {
        let x = KitMesh.lab(NSColor(srgbRed: a.r, green: a.g, blue: a.b, alpha: 1))
        let y = KitMesh.lab(NSColor(srgbRed: b.r, green: b.g, blue: b.b, alpha: 1))
        return ((x.l - y.l) * (x.l - y.l) + (x.a - y.a) * (x.a - y.a) + (x.b - y.b) * (x.b - y.b)).squareRoot()
    }

    private func badge(_ row: TabRowView) -> ChecksMarkView? {
        row.kitSubviews(of: ChecksMarkView.self).first
    }

    @Test func theRowThatTurnsIsWashedInMergePurpleFromItsLeadingEdge() throws {
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
        #expect(turned.mergedLayers == 2)
        #expect(turned.mergedTraces == 1)
        let grow = try #require(fill(turned)?.animation(forKey: "merged.grow") as? CABasicAnimation)
        #expect(grow.keyPath == "bounds.size.width")
        #expect(grow.fromValue as? Int == 0)
        #expect(grow.toValue as? CGFloat == turned.bounds.width)
        #expect(grow.duration == MergedWash.sweep)
        func point(_ index: Int) -> [Swift.Float] {
            var out: [Swift.Float] = [0, 0]
            grow.timingFunction?.getControlPoint(at: index, values: &out)
            return out
        }
        #expect(point(1) == [0.3, 0])
        #expect(point(2) == [0.7, 1])
        #expect(fill(turned)?.anchorPoint == CGPoint(x: 0, y: 0.5))
        #expect(fill(turned)?.animation(forKey: "merged.transform.scale.x") == nil)
        let pass = try #require(band(turned)?.animation(forKey: "merged.band") as? CAAnimationGroup)
        #expect(abs(pass.duration - MergedWash.sweep - MergedWash.settle) < 0.001)
        #expect(band(turned)?.bounds.width == MergedWash.reach)
        #expect(band(turned)?.anchorPoint == CGPoint(x: 1, y: 0.5))
        #expect(band(turned)?.opacity == 0)
        #expect(badge(turned)?.isHidden == false)
        #expect(badge(turned)?.merged == true)
        #expect(turned.arrivals == 1)
        let other = try #require(row(2, in: column))
        #expect(other.mergedForm == nil)
        #expect(other.mergedTraces == 0)
        #expect(other.plays == 0)
    }

    @Test func theWashPlaysOnceHoweverOftenTheRowIsDrawnAgain() throws {
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
        #expect(turned.mergedTraces == 1)
    }

    @Test func theWashIsMergePurpleAndTheCheckAndTheWordShareOneInk() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let turned = try #require(row(1, in: column))

        merge(1, column: column)

        let word = try #require(turned.kitSubviews(of: BylineView.self).first?.stateTint?.usingColorSpace(.sRGB))
        let check = try #require(badge(turned)?.glyphColour?.usingColorSpace(.sRGB))
        #expect(abs(word.redComponent - check.redComponent) < 0.002 && abs(word.blueComponent - check.blueComponent) < 0.002)
        let ground = try #require(fill(turned)?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        #expect(ground.blueComponent > ground.greenComponent)
        #expect(ground.redComponent > ground.greenComponent)
        let alpha = Double(ground.alphaComponent)
        #expect([false, true].contains { abs(alpha - MergedWash.plain(dark: $0)) < 0.001 }, "\(alpha) \(column.kitDark)")
    }

    @Test func theWashKeepsTheCheckAndTheWordAtThreeToOneOnEveryGroundARowCanHave() {
        var failing: [String] = []
        for ground in Self.grounds {
            for stop in ground.stops {
                let side = ChecksTint.ground(stop, pill: .none, frame: ground.frame, dark: ground.dark, lift: ground.lift)
                for pill in Self.pills {
                    let under = ChecksTint.ground(stop, pill: pill, frame: ground.frame, dark: ground.dark, lift: ground.lift)
                    let scene = MergedScene(bounds: .zero, radius: 0, ink: ground.ink, under: under, side: side, pill: pill, dark: ground.dark)
                    let washed = scene.ground
                    let glyph = ChecksTint.rgb(scene.glyph)
                    let worst = min(ChecksTint.contrast(glyph, washed), ChecksTint.contrast(glyph, under), ChecksTint.contrast(glyph, scene.crest))
                    if worst < ChecksTint.minimum { failing.append("\(ground.name) \(pill) \((worst * 100).rounded() / 100)") }
                }
            }
        }

        #expect(failing.isEmpty, "\(failing)")
    }

    @Test func aSaturatedTintsPickedPlateKeepsTheWashedCheckReadable() {
        for dark in [false, true] {
            let stops = [Oklch(hex: "3139FB")]
            let ink = ChecksTint.colour(.passing, merged: true, dark: dark, stops: stops, frame: true, lift: 0)
            let under = ChecksTint.ground(stops[0], pill: .picked, frame: true, dark: dark, lift: 0)
            let side = ChecksTint.ground(stops[0], pill: .none, frame: true, dark: dark, lift: 0)
            let scene = MergedScene(bounds: .zero, radius: 0, ink: ink, under: under, side: side, pill: .picked, dark: dark)

            #expect(ChecksTint.contrast(ChecksTint.rgb(scene.glyph), scene.ground) >= ChecksTint.minimum)
        }
    }

    @Test func theRowInFrontIsWashedAtLeastAsClearlyAsAPlainRow() {
        var failing: [String] = []
        for ground in Self.grounds {
            for stop in ground.stops {
                let side = ChecksTint.ground(stop, pill: .none, frame: ground.frame, dark: ground.dark, lift: ground.lift)
                let plain = Self.distance(MergedScene(bounds: .zero, radius: 0, ink: ground.ink, under: side, side: side, pill: .none, dark: ground.dark).ground, side)
                for pill in [ChecksTint.Pill.picked, .live, .pickedLive] {
                    let plate = ChecksTint.ground(stop, pill: pill, frame: ground.frame, dark: ground.dark, lift: ground.lift)
                    let scene = MergedScene(bounds: .zero, radius: 0, ink: ground.ink, under: plate, side: side, pill: pill, dark: ground.dark)
                    let washed = scene.ground
                    if scene.strength < MergedWash.lit(dark: ground.dark) { failing.append("\(ground.name) \(pill) below the lit floor") }
                    let apart = Self.distance(washed, side)
                    let own = Self.distance(washed, plate)
                    if min(apart, own) < plain * 0.999 { failing.append("\(ground.name) \(pill) \((apart / plain * 1000).rounded() / 1000) \((own / plain * 1000).rounded() / 1000)") }
                }
            }
        }

        #expect(failing.isEmpty, "\(failing.count) \(failing.prefix(12))")
        for dark in [false, true] {
            #expect(MergedWash.lit(dark: dark) > MergedWash.plain(dark: dark))
        }
    }

    @Test func theSelectedRowTakesTheStrongerWash() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        browser.select(try #require(tab(made, 1)))
        settle(column)
        let turned = try #require(row(1, in: column))

        merge(1, column: column)

        let ground = try #require(fill(turned)?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        #expect(turned.mergedForm == .full)
        let alpha = Double(ground.alphaComponent)
        #expect(alpha >= MergedWash.lit(dark: false) - 0.001 && alpha <= MergedWash.most + 0.001, "\(alpha) \(column.kitDark)")
    }

    @Test func aRowDrawnWithLettersInPlaceOfIconsIsWashedToo() throws {
        keepSetting(Shared.prefs, \.glyph, "glyph")
        browser.prefs.glyph = .letters
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let turned = try #require(row(1, in: column))

        merge(1, column: column)

        #expect(badge(turned)?.isHidden != false)
        #expect(turned.mergedForm == .full)
        #expect(turned.mergedLayers == 2)
        #expect(turned.plays == 1)
        #expect(turned.kitSubviews(of: BylineView.self).first?.stateTint != nil)
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

    @Test func theRowKeptOpenFadesItsWashOutAndIsAnOrdinaryRowAfterTheHold() async throws {
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
        let fading = try #require(row(1, in: column))
        let worn = fading.mergedForm
        let end = CACurrentMediaTime() + 2
        while CACurrentMediaTime() < end, fading.mergedForm != nil {
            settle(column)
            try await Task.sleep(for: .milliseconds(5))
        }
        let waning = (fading.mergedLayers, fading.mergedTraces, canvas(fading)?.layer?.animation(forKey: "merged.opacity") != nil)
        try await Task.sleep(for: .milliseconds(400))
        settle(column)

        let kept = try #require(row(1, in: column))
        #expect(worn == .full)
        #expect(page.liveItem == nil)
        #expect(waning.0 == 0)
        #expect(waning.1 == 1)
        #expect(waning.2)
        #expect(kept.mergedForm == nil)
        #expect(kept.mergedLayers == 0)
        #expect(kept.mergedTraces == 0)
        #expect(kept.mergedMoving == 0)
    }

    @Test func underReduceMotionALeavingWashedRowFadesOutInPlace() async throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        LiveFolders.shared.mergedHold = 0.05
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        browser.select(try #require(tab(made, 2)))
        settle(column)
        let turned = try #require(row(1, in: column))

        merge(1, column: column)
        let worn = turned.mergedForm
        let end = CACurrentMediaTime() + 2
        while CACurrentMediaTime() < end, !turned.isHidden, turned.layer?.animation(forKey: "retire.opacity") == nil {
            settle(column)
            try await Task.sleep(for: .milliseconds(10))
        }
        let fading = (!turned.isHidden, turned.layer?.animation(forKey: "retire.opacity") != nil, turned.alphaValue == 0)
        try await Task.sleep(for: .milliseconds(400))

        #expect(worn == .still)
        #expect(fading.0)
        #expect(fading.1)
        #expect(fading.2)
        #expect(turned.pooled)
        #expect(turned.alphaValue == 1)
        #expect(turned.mergedTraces == 0)
        #expect(tab(made, 1) == nil)
    }

    @Test func aStackMemberFollowsTheWipeAndIsOrdinaryAgainWhenItComesBackOpen() async throws {
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
        let worn = (lead.mergedForm, member.mergedForm, member.mergedLayers, member.plays,
                    fill(member)?.animation(forKey: "merged.grow")?.duration, band(member)?.animation(forKey: "merged.band") != nil)
        LiveRefs.known[LiveRefs.slot(key(62), space: browser.spaceID)] = LiveRefs.Known(updated: nil, branch: pull(62, position: 2).branch, read: Date(),
                                                                                         state: .open)
        LiveFolders.shared.apply(.items(LiveStacks.arranged(rail.filter { $0.key != key(63) }), nil), to: made.id)
        settle(column)
        try await Task.sleep(for: .milliseconds(400))
        settle(column)

        #expect(worn.0 == .full)
        #expect(worn.1 == .follow)
        #expect(worn.2 == 2)
        #expect(worn.3 == 0)
        #expect(worn.4 == MergedWash.sweep)
        #expect(worn.5)
        #expect(!LiveFolders.shared.turning(key(62)))
        let back = try #require(row(62, in: column))
        #expect(back.mergedForm == nil)
        #expect(back.mergedLayers == 0)
        #expect(back.mergedTraces == 0)
        #expect(back.mergedMoving == 0)
        #expect(badge(back)?.isHidden == false)
        #expect(try #require(row(63, in: column)).mergedForm == .full)
    }

    @Test func eachRowOfAStackKeepsItsOwnRoundedWashWithTheListsGap() throws {
        LiveFolders.shared.mergedHold = 5
        let made = prs(rail)
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        merge(63, column: column)

        let rows = try [63, 62, 61].map { try #require(row($0, in: column)) }
        let boxes = try rows.map { row in row.convert(try #require(row.washFrame), to: column) }
        let sorted = boxes.sorted { $0.minY < $1.minY }
        #expect(rows.map(\.mergedLayers) == [2, 2, 2])
        for (row, box) in zip(rows, boxes) {
            #expect(box == row.convert(row.bounds, to: column))
            #expect((canvas(row)?.layer?.cornerRadius ?? 0) > 0)
            #expect(canvas(row)?.layer?.masksToBounds == true)
        }
        for (upper, lower) in zip(sorted, sorted.dropFirst()) {
            #expect(abs(lower.minY - upper.maxY - Metrics.sideGap) < 0.5)
        }
    }

    @Test func theStackWashesOneRowAfterAnotherFromTheTop() async throws {
        LiveFolders.shared.mergedHold = 5
        LiveFolders.shared.stackStagger = LiveFolders.stagger
        let made = prs(rail)
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        merge(63, column: column)
        try await pump(column, for: 0.5)

        let rows = try [63, 62, 61].map { try #require(row($0, in: column)) }
        let tops = rows.map { $0.convert($0.bounds, to: column).minY }
        let times = try rows.map { try #require($0.wornAt) }
        #expect(rows.map(\.mergedForm) == [.full, .follow, .follow])
        #expect(rows.map(\.plays) == [1, 0, 0])
        #expect(tops == tops.sorted() || tops == tops.sorted().reversed())
        let order = zip(tops, times).sorted { column.isFlipped ? $0.0 < $1.0 : $0.0 > $1.0 }.map(\.1)
        #expect(order == order.sorted())
        #expect(order.last! > order.first!)
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
        #expect(rows.prefix(3).allSatisfy { $0.mergedLayers == 2 && badge($0)?.isHidden == false })
        #expect(rows.map(\.arrivals) == [1, 1, 1, 0])
        #expect(rows[3].mergedForm == nil)
        #expect(rows[3].mergedTraces == 0)
    }

    @Test func underReduceMotionTheRowTakesTheTintedGroundAtOnce() throws {
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
        #expect(turned.mergedLayers == 2)
        #expect(turned.mergedTraces == 1)
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
        #expect(turned.mergedLayers == 2)
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

    @Test func theBandsFrontIsAboutOnePointEightTimesTheRestingWashAndNeverAboveTheMost() {
        for strength in [0.14, 0.22, 0.27, 0.33, 0.36, 0.5, 0.6] {
            let front = strength + MergedWash.rise(strength) * (1 - strength)
            #expect(abs(front - min(MergedWash.most, strength * MergedWash.lift)) < 0.0001, "\(strength) \(front)")
            #expect(front >= strength - 0.0001)
            #expect(front <= MergedWash.most + 0.0001)
        }
        #expect(abs(MergedWash.peak(0.14) - 0.252) < 0.0001)
        #expect(MergedWash.peak(0.36) == MergedWash.most)
    }

    @Test func aFollowerThatStartsLateShortensItsFillToEndBeforeTheHold() {
        #expect(MergedWash.lasts(elapsed: 0, hold: LiveFolders.hold) == MergedWash.sweep)
        #expect(MergedWash.lasts(elapsed: 0.18, hold: LiveFolders.hold) == MergedWash.sweep)
        #expect(abs(MergedWash.lasts(elapsed: 0.27, hold: LiveFolders.hold) - 1.18) < 0.0001)
        #expect(MergedWash.lasts(elapsed: 2, hold: LiveFolders.hold) == 0)
        #expect(MergedWash.lasts(elapsed: 0, hold: 0.05) == 0)
    }

    @Test func aTallStacksLowerRowsEndTheirFillBeforeTheRowsLeave() async throws {
        LiveFolders.shared.mergedHold = LiveFolders.hold
        LiveFolders.shared.stackStagger = 0.5
        let made = prs(rail)
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        merge(64, column: column)
        let end = CACurrentMediaTime() + 1.45
        while CACurrentMediaTime() < end, row(62, in: column)?.mergedForm == nil {
            settle(column)
            try await Task.sleep(for: .milliseconds(10))
        }

        let lead = try #require(row(64, in: column))
        let start = try #require(lead.wornAt)
        #expect(lead.mergedForm == .full)
        #expect(lead.mergedLasts == MergedWash.sweep)
        for number in [63, 62] {
            let follower = try #require(row(number, in: column))
            let began = try #require(follower.mergedBegan)
            #expect(follower.mergedForm == .follow)
            #expect(follower.mergedLasts < MergedWash.sweep)
            #expect(follower.mergedLasts > 0)
            #expect(began + follower.mergedLasts <= start + LiveFolders.hold - MergedWash.spare + 0.02, "\(number) \(began - start) \(follower.mergedLasts)")
            #expect(fill(follower)?.animation(forKey: "merged.grow")?.duration == follower.mergedLasts)
        }
    }

    @Test func aStackMergedThroughALateReadStillGivesItsFollowersTheWholeFill() throws {
        LiveFolders.shared.mergedHold = LiveFolders.hold
        let made = prs(rail)
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }

        LiveFolders.shared.pageMerged(try #require(URL(string: key(63))), space: browser.spaceID, now: Date().addingTimeInterval(-3))
        settle(column)

        let rows = try [63, 62, 61].map { try #require(row($0, in: column)) }
        #expect(rows.map(\.mergedForm) == [.full, .follow, .follow])
        #expect(rows.map(\.mergedLasts) == [MergedWash.sweep, MergedWash.sweep, MergedWash.sweep])
    }

    @Test func thePageInFrontThatSaysMergedPlaysTheFullFillThroughARereadWhileTurning() throws {
        let made = prs([pull(1), pull(2)])
        let (column, window) = shown(made)
        defer {
            window.contentView = nil
            window.close()
        }
        let page = try #require(tab(made, 1))
        browser.select(page)
        settle(column)
        let turned = try #require(row(1, in: column))

        browser.livePullState(page, at: try #require(URL(string: key(1))), said: .merged)
        settle(column)

        #expect(browser.activeID == page.id)
        #expect(turned.mergedForm == .full)
        #expect(turned.plays == 1)
        #expect(turned.mergedLasts == MergedWash.sweep)
        let grow = fill(turned)?.animation(forKey: "merged.grow")
        #expect(grow != nil)

        LiveFolders.shared.apply(.items([pull(1), pull(2)], nil), to: made.id)
        settle(column)

        let after = try #require(row(1, in: column))
        #expect(after === turned)
        #expect(after.mergedForm == .full)
        #expect(after.plays == 1)
        #expect(fill(after)?.animation(forKey: "merged.grow") === grow || fill(after)?.animation(forKey: "merged.grow")?.beginTime == grow?.beginTime)
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

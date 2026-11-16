import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PaneBarLookTests {
    private let near = SpaceLook(colours: ["000000"], intensity: 1)
    private let pale = SpaceLook(colours: ["F2EEE6"], intensity: 1)
    private let vivid = SpaceLook(colours: ["3139FB"], intensity: 1)
    private let clear = SpaceLook(colours: ["000000"], intensity: 2, transparency: 0.4, grain: 0.3)

    private func alpha(_ colour: NSColor) -> CGFloat { colour.usingColorSpace(.sRGB)?.alphaComponent ?? 0 }

    private func apart(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return 0 }
        return max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                   abs(a.blueComponent - b.blueComponent)) * 255
    }

    private func bar(_ look: SpaceLook, dark: Bool, focused: Bool, carrying: Bool = false) -> (PaneBarView, NSWindow, Browser) {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let bar = PaneBarView(browser: browser, tab: browser.tabs[0])
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: Metrics.paneBar),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = bar
        bar.show(tab: browser.tabs[0], focused: focused, carrying: carrying, corner: Metrics.pageRadius, look: look)
        bar.layoutSubtreeIfNeeded()
        return (bar, window, browser)
    }

    @Test func aBarAtRestIsTheCardsOwnSolidGroundWithNothingPaintedOverIt() throws {
        for look in [near, pale, vivid, clear] {
            for dark in [true, false] {
                let (bar, window, browser) = bar(look, dark: dark, focused: false)
                defer { window.close(); browser.closeAll() }

                let ground = bar.ground
                #expect(ground.base.isHidden)
                #expect(ground.subviews.isEmpty)
                let parts = try #require(ground.layer?.sublayers)
                #expect(parts.count == 2)
                #expect(parts.allSatisfy { !($0 is CAGradientLayer) && $0.shadowOpacity == 0 })
                #expect(ground.shown == PaneBarLook.made(look.page(dark: dark), strong: false))
                #expect(ground.shown?.fill == look.page(dark: dark).flat)
                #expect(alpha(ground.shown?.fill ?? .clear) == 1)
            }
        }
    }

    @Test func aCarriedBarIsBackedWithTheSameSolidAndAsStrongAsAFocusedOne() {
        let (bar, window, browser) = bar(near, dark: true, focused: false, carrying: true)
        defer { window.close(); browser.closeAll() }

        #expect(!bar.ground.base.isHidden)
        #expect(bar.ground.base.opacity == 1)
        #expect(bar.ground.base.fillColor == near.page(dark: true).flat.cgColor)
        #expect(bar.ground.shown == PaneBarLook.made(near.page(dark: true), strong: true))
        #expect(!bar.ground.outlined)
    }

    @Test func theLineIsOpaqueAndStandsOffTheFillInEveryLook() {
        for look in [near, pale, vivid, clear] {
            for dark in [true, false] {
                let ground = look.page(dark: dark)

                let strong = PaneBarLook.made(ground, strong: true)
                let quiet = PaneBarLook.made(ground, strong: false)

                #expect(strong.fill == quiet.fill)
                #expect(alpha(strong.line) == 1 && alpha(quiet.line) == 1)
                #expect(apart(quiet.line, quiet.fill) >= 18)
                #expect(apart(strong.line, strong.fill) > apart(quiet.line, quiet.fill))
                #expect(apart(strong.line, strong.fill) <= 60)
                #expect(strong.dark == ground.dark)
            }
        }
    }

    @Test func theLineTakesItsInkFromTheSpace() throws {
        let blue = PaneBarLook.made(vivid.page(dark: true), strong: true)
        let grey = PaneBarLook.made(near.page(dark: true), strong: true)
        let paper = PaneBarLook.made(pale.page(dark: false), strong: true)

        let blueLine = try #require(blue.line.usingColorSpace(.sRGB))
        let blueFill = try #require(blue.fill.usingColorSpace(.sRGB))
        let greyLine = try #require(grey.line.usingColorSpace(.sRGB))
        let greyFill = try #require(grey.fill.usingColorSpace(.sRGB))
        let paperLine = try #require(paper.line.usingColorSpace(.sRGB))
        let paperFill = try #require(paper.fill.usingColorSpace(.sRGB))

        #expect(blue.dark && grey.dark && !paper.dark)
        #expect(blueLine.blueComponent > blueLine.redComponent)
        #expect(blueLine.blueComponent > blueFill.blueComponent)
        #expect(greyLine.redComponent > greyFill.redComponent)
        #expect(abs(greyLine.redComponent - greyLine.blueComponent) < 0.01)
        #expect(paperLine.redComponent < paperFill.redComponent)
        #expect(blue != grey)
    }

    @Test func theBarsInkFollowsThePageGroundNotTheWindow() {
        let (bar, window, browser) = bar(near, dark: false, focused: true)
        defer { window.close(); browser.closeAll() }

        #expect(near.page(dark: false).dark)
        #expect(bar.surface.dark)
        let inked = bar.subviews.filter { !($0 is PaneBarGround) }
        #expect(inked.count == 6)
        #expect(inked.allSatisfy { $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua })
    }

    @Test func aNewLookAloneRepaintsTheBar() {
        let (bar, window, browser) = bar(near, dark: true, focused: true)
        defer { window.close(); browser.closeAll() }
        let before = bar.ground.shown

        bar.show(tab: browser.tabs[0], focused: true, carrying: false, corner: Metrics.pageRadius, look: vivid)

        #expect(bar.ground.shown != before)
        #expect(bar.ground.shown == PaneBarLook.made(vivid.page(dark: true), strong: true))
        #expect(bar.ground.line.backgroundColor == PaneBarLook.made(vivid.page(dark: true), strong: true).line.cgColor)
    }

    @Test func theOneHairlineLiesOnThePagesFirstDevicePixelAndNothingElseLeavesTheBar() throws {
        let (bar, window, browser) = bar(pale, dark: false, focused: false)
        defer { window.close(); browser.closeAll() }

        let ground = bar.ground
        let hair = 1 / max(1, window.backingScaleFactor)
        #expect(ground.frame == bar.bounds)
        #expect(ground.line.frame.minY == bar.bounds.height)
        #expect(ground.line.frame.height == hair)
        #expect(ground.line.frame.minX == 0)
        #expect(ground.line.frame.width == bar.bounds.width)
        #expect(ground.base.frame == bar.bounds)
        let reach = try #require(ground.layer?.sublayers).map(\.frame.maxY).max()
        #expect(reach == bar.bounds.height + hair)
        #expect(bar.hitTest(NSPoint(x: bar.bounds.midX, y: bar.bounds.midY)) == nil)
    }

    @Test func theFocusedBarsLineStopsShortOfTheFocusOutline() {
        let (bar, window, browser) = bar(pale, dark: false, focused: true)
        defer { window.close(); browser.closeAll() }

        bar.layoutSubtreeIfNeeded()

        #expect(bar.ground.outlined)
        #expect(bar.ground.line.frame.minX == FocusCue.width)
        #expect(bar.ground.line.frame.maxX == bar.bounds.width - FocusCue.width)

        bar.show(tab: browser.tabs[0], focused: false, carrying: false, corner: Metrics.pageRadius, look: pale)
        bar.layoutSubtreeIfNeeded()

        #expect(!bar.ground.outlined)
        #expect(bar.ground.line.frame.minX == 0)
        #expect(bar.ground.line.frame.maxX == bar.bounds.width)
    }

    private func stage(_ look: SpaceLook, dark: Bool) -> (PaneStage, NSWindow) {
        _ = NSApplication.shared
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 1000, height: 600))
        stage.corner = Metrics.pageRadius
        stage.look = look
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: 1000, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = stage
        window.orderFrontRegardless()
        return (stage, window)
    }

    private func edges(_ stage: PaneStage) -> [PaneEdge] { stage.rims.subviews.compactMap { $0 as? PaneEdge } }

    @Test func theUnfocusedCardWearsTheEdgeAndTheFocusedOneItsOutlineInstead() {
        for look in [near, pale, vivid, clear] {
            for dark in [true, false] {
                let left = Tab(bench: true)
                let right = Tab(bench: true)
                let (stage, window) = stage(look, dark: dark)
                defer { window.close() }

                stage.show([left, right], split: TabSplit(left: left.id, right: right.id), focused: right.id)
                stage.layoutSubtreeIfNeeded()

                let cues = stage.rims.subviews.compactMap { $0 as? FocusCue }
                let edges = edges(stage)
                #expect(cues.count == 2 && edges.count == 2)
                for (cue, edge) in zip(cues, edges) {
                    #expect(edge.frame == cue.frame)
                    #expect(edge.frame.minY == 0 && edge.frame.height == 600)
                    #expect(edge.alphaValue == 1 - cue.alphaValue)
                    #expect(edge.corner == Metrics.pageRadius)
                    #expect(edge.ink == PaneEdge.ink(look, dark: dark))
                    #expect(alpha(edge.ink) == 1)
                    #expect(edge.line == PaneEdge.width)
                    #expect(edge.line == stage.edgeWidth)
                    #expect(edge.line <= FocusCue.width)
                    #expect(edge.card == cue.card)
                    #expect(edge.card?.size == edge.frame.size)
                    #expect(edge.cut == stage.bounds.offsetBy(dx: -edge.frame.minX, dy: -edge.frame.minY))
                    #expect(cue.cut == edge.cut)
                    #expect(edge.hitTest(NSPoint(x: edge.frame.midX, y: edge.frame.midY)) == nil)
                    #expect((edge.layer?.animationKeys() ?? []).isEmpty)
                }
                #expect(edges.map(\.alphaValue) == [1, 0])
                #expect(stage.rims.hitTest(NSPoint(x: 10, y: 10)) == nil)
                #expect(stage.rims.frame == stage.bounds)
            }
        }
    }

    @Test func aNewLookAloneRepaintsTheEdge() {
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let (stage, window) = stage(near, dark: true)
        defer { window.close() }
        stage.show([left, right], split: TabSplit(left: left.id, right: right.id), focused: right.id)
        stage.layoutSubtreeIfNeeded()
        let edges = edges(stage)
        let before = edges.map(\.ink)

        stage.look = vivid

        #expect(edges.count == 2)
        #expect(edges.map(\.ink) != before)
        #expect(edges.allSatisfy { $0.ink == PaneEdge.ink(vivid, dark: true) })
    }

    @Test func aPairAtRestLeavesItsOuterCornersToItsHostsClipAndASlidingOneItsOuterSidesToTheFrame() {
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let (stage, window) = stage(near, dark: true)
        defer { window.close() }
        stage.show([left, right], split: TabSplit(left: left.id, right: right.id), focused: right.id)
        stage.layoutSubtreeIfNeeded()

        let edges = edges(stage)
        #expect(edges.count == 2)
        for edge in edges {
            #expect(edge.cut == stage.bounds.offsetBy(dx: -edge.frame.minX, dy: -edge.frame.minY))
        }
        let first = CardRim.shape(edges[0].card ?? .zero, in: edges[0].bounds, cut: edges[0].cut, corner: edges[0].corner, line: edges[0].line)
        #expect(first.outer.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(first.outer.contains(CGPoint(x: 0.5, y: edges[0].bounds.maxY - 0.5)))
        #expect(!first.outer.contains(CGPoint(x: edges[0].bounds.maxX - 0.5, y: 0.5)))
        #expect(!first.outer.contains(CGPoint(x: edges[0].bounds.maxX - 0.5, y: edges[0].bounds.maxY - 0.5)))
        let second = CardRim.shape(edges[1].card ?? .zero, in: edges[1].bounds, cut: edges[1].cut, corner: edges[1].corner, line: edges[1].line)
        #expect(!second.outer.contains(CGPoint(x: 0.5, y: 0.5)))
        #expect(second.outer.contains(CGPoint(x: edges[1].bounds.maxX - 0.5, y: 0.5)))

        stage.sliding = true
        stage.layoutSubtreeIfNeeded()

        #expect(edges.allSatisfy { $0.cut == nil })
        let past = Metrics.pageRadius * 2 + PaneEdge.width + 2
        #expect(edges[0].card?.minX == -past && edges[0].card?.maxX == edges[0].bounds.maxX)
        #expect(edges[1].card?.minX == 0 && edges[1].card?.maxX == edges[1].bounds.maxX + past)
        #expect(edges.allSatisfy { $0.card?.minY == 0 && $0.card?.height == $0.bounds.height })
        #expect(edges.map(\.frame.minX) == [0, edges[1].frame.minX] && edges[1].frame.maxX == stage.bounds.maxX)

        stage.sliding = false
        stage.layoutSubtreeIfNeeded()

        #expect(edges.allSatisfy { $0.cut != nil && $0.card?.size == $0.frame.size })
    }

    @Test func aPageAloneLeavesItsEdgeAndItsCornersToTheFrameItPassesThrough() throws {
        let tab = Tab(bench: true)
        let (stage, window) = stage(near, dark: true)
        defer { window.close() }

        stage.show([tab], split: nil, focused: tab.id)
        stage.layoutSubtreeIfNeeded()

        let edges = edges(stage)
        #expect(edges.count == 1)
        #expect(edges.first?.alphaValue == 0)
        #expect(stage.framed)
        #expect(stage.rims.subviews.compactMap { $0 as? FocusCue }.allSatisfy { $0.alphaValue == 0 })
        let frame = try #require(stage.subviews.compactMap { $0 as? PageFrame }.first?.layer)
        #expect(frame.borderWidth == 0)
        #expect(frame.cornerRadius == 0)
    }

    @Test func pagesEdgeToEdgeHaveNoEdge() {
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let (stage, window) = stage(near, dark: true)
        defer { window.close() }
        stage.corner = 0

        stage.show([left, right], split: TabSplit(left: left.id, right: right.id), focused: right.id)
        stage.layoutSubtreeIfNeeded()

        let edges = edges(stage)
        #expect(edges.count == 2)
        #expect(edges.allSatisfy { $0.alphaValue == 0 })
        #expect(stage.edgeWidth == 0)
    }
}

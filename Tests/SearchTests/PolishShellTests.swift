import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class PolishShellTests {
    private var windows: [NSWindow] = []
    private var marks: [Bookmark.ID] = []

    init() {
        addTeardownBlock { try await self.tearDown() }
    }

    private func tearDown() async throws {
        for id in marks { Shared.bookmarks.remove(id) }
        marks.removeAll()
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func theAgentPointerIsInvisibleUntilAPointerArrives() throws {
        _ = NSApplication.shared
        let tab = Tab(bench: true)
        let view = AgentPointerView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.tab = tab.id
        let arrow = try #require(view.subviews.first { $0 is AgentArrowView })

        view.layout()

        #expect(view.layer?.opacity == 0)
        #expect(arrow.isHidden)

        AgentPointers.shared.point(tab.id, AgentPointer(target: CGRect(x: 40, y: 40, width: 100, height: 20), kind: .click,
                                                        at: Date(), name: "Claude", accent: 1))
        view.layout()

        #expect(view.layer?.opacity == 1)
        #expect(!arrow.isHidden)

        AgentPointers.shared.clear(tab.id)
        view.layout()

        #expect(view.layer?.opacity == 0)
    }

    @Test func eachPeekKnobDrawsItsGlyphInsideItsGlass() {
        let knobs = PeekKnobsView(split: true, close: {}, open: {}, beside: {})

        let buttons = knobs.descendants(PeekKnob.self)

        #expect(buttons.count == 3)
        for button in buttons {
            let glass = button.glass
            #expect(glass != nil)
            if let glass, let content = glass.contentView {
                #expect(glass.face is KitSymbol)
                #expect(glass.face.isDescendant(of: content))
                #expect(glass.tintColor != nil)
            }
        }
    }

    @Test func theWindowBorderIsLighterAndStillNests() {
        #expect(Metrics.cardGap == 6)
        #expect(Metrics.pageRadius == 11)
        #expect(Metrics.sideInset == Metrics.cardGap)
        #expect((17...18).contains(Metrics.cardGap + Metrics.pageRadius))
        #expect(Metrics.sideRowHeight == 34)
        #expect(Metrics.sidePill == 34)
        #expect(Metrics.paneBar == 32)
    }

    @Test func theCardEdgeIsOnePointMixedFromTheSidebarsOwnColourOnEveryGround() throws {
        let pale = SpaceLook(colours: ["F2EEE6"], intensity: 1)
        let vivid = SpaceLook(colours: ["3139FB"], intensity: 1)
        let night = SpaceLook(colours: ["000000"], intensity: 1)
        func parts(_ colour: NSColor) throws -> [CGFloat] {
            let colour = try #require(colour.usingColorSpace(.sRGB))
            return [colour.redComponent, colour.greenComponent, colour.blueComponent]
        }

        let card = PaneStage.edge(card: true)
        let flat = PaneStage.edge(card: false)

        #expect(card == 1)
        #expect(card == PaneEdge.width)
        #expect(flat == 0)
        for look in [SpaceLook(), pale, vivid, night] {
            for dark in [true, false] {
                let ground = look.ground(dark: dark)
                let ink = PaneEdge.ink(look, dark: dark)
                let side = try parts(ground.average.color)
                let made = try parts(ink)
                let off = zip(made, side).map { abs($0 - $1) }.max() ?? 0
                #expect(ink.usingColorSpace(.sRGB)?.alphaComponent == 1)
                #expect(PaneEdge.side(look, dark: dark) == ground.average.color)
                #expect(off > 0.015 && off < 0.07)
                #expect(ground.lightInk ? made.reduce(0, +) > side.reduce(0, +) : made.reduce(0, +) < side.reduce(0, +))
                let page = look.page(dark: dark)
                let bar = zip(try parts(PaneBarLook.made(page, strong: true).line), try parts(page.flat)).map { abs($0 - $1) }.max() ?? 0
                #expect(off < bar)
            }
        }
    }

    @Test func aSeeThroughSidebarsEdgeIsMixedFromWhatShowsOfIt() throws {
        let solid = SpaceLook(colours: ["000000"], intensity: 2)
        let clear = SpaceLook(colours: ["000000"], intensity: 2, transparency: 0.4, grain: 0.3)
        let glass = SpaceLook(colours: ["000000"], intensity: 2, glass: true)
        func grey(_ colour: NSColor) throws -> CGFloat { try #require(colour.usingColorSpace(.sRGB)).redComponent }

        let paint = try grey(PaneEdge.side(solid, dark: true, blurred: true))
        let through = try grey(PaneEdge.side(clear, dark: true, blurred: true))
        let glassy = try grey(PaneEdge.side(glass, dark: true, blurred: true))
        let reduced = try grey(PaneEdge.side(clear, dark: true, blurred: false))

        #expect(abs(through - (paint + (PaneEdge.behind.dark - paint) * 0.4)) < 0.001)
        #expect(glassy > paint && glassy < PaneEdge.behind.dark)
        #expect(reduced == paint)
        #expect(PaneEdge.ink(clear, dark: true).usingColorSpace(.sRGB)?.alphaComponent == 1)
        #expect(try grey(PaneEdge.ink(clear, dark: true)) > through)
    }

    @Test func thePeekAndTheSwitcherDimTheSame() {
        #expect(KitColor.dim == 0.16)
    }

    @Test func addressesWithoutANameWearTheNetworkSymbol() throws {
        let bare = ["http://127.0.0.1:63954/inbox", "http://[::1]:8080/", "http://localhost:3000/", "https://app.localhost/",
                    "http://192.168.1.20/"]
        let named = ["https://example.com/", "http://10.0.0/", "http://1234.1.1.1/", "file:///tmp/a.html", "https://999.1.1.1/"]

        for text in bare { #expect(Tab.bareHost(URL(string: text)), "\(text)") }
        for text in named { #expect(!Tab.bareHost(URL(string: text)), "\(text)") }
        let mark = try #require(Tab.networkMark)
        #expect(mark.isTemplate)
    }

    @Test func theBookmarksBarDrawsItsButtonsInsideItsBand() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        for index in 0..<3 {
            let url = try #require(URL(string: "https://polish-bar-\(index).example/"))
            if let made = browser.bookmarks.add(url, title: "Site \(index)") { marks.append(made.id) }
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 600, height: 300),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.contentView = root
        windows.append(window)
        let bar = BookmarksBar(browser: browser)
        root.addSubview(bar)

        bar.frame = NSRect(x: 0, y: root.bounds.height - BookmarksBar.height, width: 600, height: BookmarksBar.height)
        bar.refresh()
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
        let shown = BookmarksBar.seen(in: root)

        let items = try #require(shown["items"] as? [[String: Any]])
        #expect(items.count >= marks.count)
        for item in items {
            let box = try #require(item["inBar"] as? [Double])
            #expect(box[2] > 0)
            #expect(box[1] >= 0)
            #expect(box[1] + box[3] <= Double(BookmarksBar.height))
        }
    }
}

private extension NSView {
    func descendants<T: NSView>(_ type: T.Type) -> [T] {
        subviews.flatMap { view -> [T] in ((view as? T).map { [$0] } ?? []) + view.descendants(type) }
    }
}

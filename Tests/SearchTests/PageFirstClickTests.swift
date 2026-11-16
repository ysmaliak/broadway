import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)), .serialized)
@MainActor
final class PageFirstClickTests {
    private var windows: [NSWindow] = []
    private var tabs: [Tab] = []

    init() {
        addTeardownBlock { try await self.tearDown() }
    }

    private func tearDown() async throws {
        PageView.webKitDecidesFirstMouse = false
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        tabs.removeAll()
        try await Task.sleep(for: .milliseconds(100))
    }

    private static let html = """
    <!doctype html><style>html,body{margin:0;height:100%} button{position:fixed;inset:0;width:100%;height:100%}</style>
    <script>window.clicks = 0; addEventListener('click', () => clicks++, true);</script><button>page</button>
    """

    private func page() async throws -> (NSWindow, PageView) {
        _ = NSApplication.shared
        let tab = Tab(configuration: Web.configuration(space: UUID()))
        tabs.append(tab)
        let page = tab.web
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 400, height: 300),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        page.frame = root.bounds.insetBy(dx: 40, dy: 30)
        root.addSubview(page)
        window.contentView = root
        window.orderFrontRegardless()
        windows.append(window)
        page.loadHTMLString(Self.html, baseURL: URL(string: "https://example.com/"))
        for _ in 0..<300 {
            if try await page.evaluateJavaScript("typeof clicks") as? String == "number" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        window.makeFirstResponder(nil)
        return (window, page)
    }

    private func click(_ point: NSPoint, in window: NSWindow) throws {
        let number = Int.random(in: 1...Int(Int32.max))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
        }
    }

    private func clicks(_ page: PageView, reaching wanted: Int) async throws -> Int {
        var seen = 0
        for _ in 0..<100 {
            seen = try await page.evaluateJavaScript("clicks") as? Int ?? 0
            if seen >= wanted { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        return seen
    }

    @Test func aPageInAWindowThatIsNotKeyTakesTheFirstClick() async throws {
        let (window, page) = try await page()
        #expect(window.canBecomeKey && !window.isKeyWindow)
        let rect = page.convert(page.bounds, to: nil)
        let points = [NSPoint(x: rect.midX, y: rect.midY), NSPoint(x: rect.minX + 4, y: rect.minY + 4),
                      NSPoint(x: rect.maxX - 4, y: rect.maxY - 4)]

        for (index, point) in points.enumerated() {
            let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point)

            #expect(hit.map { $0 === page || $0.isDescendant(of: page) } == true)
            #expect(hit?.acceptsFirstMouse(for: nil) == true)

            try click(point, in: window)

            #expect(try await clicks(page, reaching: index + 1) == index + 1)
        }
        #expect(window.firstResponder === page)
    }

    @Test func webKitsOwnAnswerLosesThatClick() async throws {
        let (window, page) = try await page()
        #expect(window.canBecomeKey && !window.isKeyWindow)
        PageView.webKitDecidesFirstMouse = true
        let rect = page.convert(page.bounds, to: nil)

        try click(NSPoint(x: rect.midX, y: rect.midY), in: window)
        try await Task.sleep(for: .milliseconds(400))

        #expect(try await page.evaluateJavaScript("clicks") as? Int == 0)
        #expect(window.firstResponder !== page)
    }
}

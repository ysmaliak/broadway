import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BenchRoomTests {
    @Test func closingTheLastBrowserDropsTheRoomAndTheNextPageGetsANewOne() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let first = Browser(record: WindowRecord())
        let second = Browser(record: WindowRecord())
        defer { first.closeAll(); second.closeAll() }
        let a = first.open(URL(string: "about:blank")!, foreground: false)
        let b = second.open(URL(string: "about:blank")!, foreground: false)
        a.bench = true
        b.bench = true
        Bench.shared.house(a)
        Bench.shared.house(b)
        let room = try #require(a.web.window)
        #expect(b.web.window === room)

        first.closeAll()

        #expect(room is AgentPageRoom)
        #expect(!room.isVisible)
        #expect(b.web.window === room)

        second.closeAll()

        #expect(!room.isVisible)
        #expect(room.contentView?.subviews.isEmpty == true)

        let c = first.open(URL(string: "about:blank")!, foreground: false)
        c.bench = true
        Bench.shared.house(c)

        #expect(c.web.window != nil)
        #expect(!(c.web.window === room))
    }
}

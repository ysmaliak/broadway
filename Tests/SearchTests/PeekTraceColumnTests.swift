import AppKit
import Testing
@testable import Search

@MainActor
struct PeekTraceColumnTests {
    @Test func aPeekIsTracedOnTheColumnInsideTheCardNotOnTheTallerDockedOne() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        let docked = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
        root.addSubview(docked)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 580))
        let carded = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 580))
        host.addSubview(carded)
        let card = PeekCardView(host: host)
        card.frame = NSRect(x: 10, y: 10, width: 250, height: 580)
        root.addSubview(card)

        #expect(PeekTrace.column(in: window) === carded)
    }

    @Test func withNoCardThereIsNoPeekColumn() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = root
        root.addSubview(NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 600)))

        #expect(PeekTrace.column(in: window) == nil)
    }
}

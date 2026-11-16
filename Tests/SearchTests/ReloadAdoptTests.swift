import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct ReloadAdoptTests {
    private func shown() -> (NSWindow, ReloadDoorView) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 60, height: 60), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let door = ReloadDoorView(size: 15, loading: false, reloads: 0, stops: 0)
        door.wantsLayer = true
        door.frame = NSRect(x: 0, y: 0, width: 30, height: 30)
        window.contentView?.addSubview(door)
        window.orderFrontRegardless()
        door.layoutSubtreeIfNeeded()
        return (window, door)
    }

    private func turning(_ view: NSView) -> Bool {
        func keys(_ layer: CALayer) -> [String] { (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(keys) }
        return view.layer.map(keys)?.contains { $0.hasPrefix("turn") } ?? false
    }

    @Test func anotherTabsReloadsDoNotSpinTheArrow() {
        let (window, door) = shown()
        defer { window.close() }

        door.adopt(loading: false, reloads: 7, stops: 2)

        #expect(!turning(door))
        #expect(door.face.phase == .idle)
    }

    @Test func aReloadOfTheSameTabStillStarts() {
        let (window, door) = shown()
        defer { window.close() }
        door.adopt(loading: false, reloads: 7, stops: 2)

        door.see(loading: true, reloads: 8, stops: 2)

        #expect(door.face.phase == .starting)
    }

    @Test func adoptingALoadingTabShowsStopAtOnce() {
        let (window, door) = shown()
        defer { window.close() }

        door.adopt(loading: true, reloads: 3, stops: 0)

        #expect(door.face.showsStop)
        #expect(!turning(door))
    }
}

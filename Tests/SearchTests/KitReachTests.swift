import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct KitReachTests {
    private func row(_ keys: [NSView], gap: CGFloat = 8) -> (KitFlippedView, NSWindow) {
        let size = NSSize(width: 320, height: 40)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = KitFlippedView(frame: NSRect(origin: .zero, size: size))
        window.contentView = stage
        let row = KitFlippedView(frame: stage.bounds)
        stage.addSubview(row)
        var x: CGFloat = 20
        for key in keys {
            let fit = key.intrinsicContentSize
            key.frame = NSRect(x: x, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height)
            row.addSubview(key)
            x += fit.width + gap
        }
        stage.layoutSubtreeIfNeeded()
        return (row, window)
    }

    private func lands(_ hit: NSView?, on key: NSView) -> Bool {
        hit.map { $0 === key || $0.isDescendant(of: key) } ?? false
    }

    private func drag(_ key: NSView, to point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDragged, location: key.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func aSmallGlassKeyIsDrawn22TallAndTakesAClickOver24() {
        let key = KitGlassKey(title: "Allow")
        let (row, window) = row([key])
        defer { window.close() }
        let frame = key.frame

        let above = row.hitTest(NSPoint(x: frame.midX, y: frame.minY - 0.5))
        let below = row.hitTest(NSPoint(x: frame.midX, y: frame.maxY + 0.5))
        let past = row.hitTest(NSPoint(x: frame.midX, y: frame.minY - 1.5))

        #expect(frame.height == 22)
        #expect(lands(above, on: key))
        #expect(lands(below, on: key))
        #expect(!lands(past, on: key))
    }

    @Test func aRoundGlassKeyTakesAClickOver24BothWays() {
        let key = KitGlassKey(symbol: "xmark", circle: 20)
        let (row, window) = row([key])
        defer { window.close() }
        let frame = key.frame

        let beside = row.hitTest(NSPoint(x: frame.minX - 1.5, y: frame.midY))
        let above = row.hitTest(NSPoint(x: frame.midX, y: frame.minY - 1.5))
        let past = row.hitTest(NSPoint(x: frame.minX - 2.5, y: frame.midY))

        #expect(frame.size == NSSize(width: 20, height: 20))
        #expect(lands(beside, on: key))
        #expect(lands(above, on: key))
        #expect(!lands(past, on: key))
    }

    @Test func aPressHeldInTheExtraPointStillFires() {
        var fired = 0
        let key = KitGlassKey(title: "Allow") { fired += 1 }
        let (_, window) = row([key])
        defer { window.close() }
        let press = drag(key, to: NSPoint(x: key.bounds.midX, y: key.bounds.midY), in: window)

        key.mouseDown(with: press)
        key.mouseDragged(with: drag(key, to: NSPoint(x: key.bounds.midX, y: -0.5), in: window))
        key.mouseUp(with: press)

        #expect(fired == 1)
    }

    @Test func aPressDraggedPastTheReachDoesNotFire() {
        var fired = 0
        let key = KitGlassKey(title: "Allow") { fired += 1 }
        let (_, window) = row([key])
        defer { window.close() }
        let press = drag(key, to: NSPoint(x: key.bounds.midX, y: key.bounds.midY), in: window)

        key.mouseDown(with: press)
        key.mouseDragged(with: drag(key, to: NSPoint(x: key.bounds.midX, y: -3), in: window))
        key.mouseUp(with: press)

        #expect(fired == 0)
    }

    @Test func aKeysReachNeverCoversItsNeighbour() {
        let first = KitGlassKey(symbol: "xmark", circle: 20)
        let second = KitGlassKey(symbol: "plus", circle: 20)
        let (row, window) = row([first, second], gap: 0)
        defer { window.close() }

        let onSecond = row.hitTest(NSPoint(x: second.frame.minX + 0.5, y: second.frame.midY))
        let onFirst = row.hitTest(NSPoint(x: first.frame.maxX - 0.5, y: first.frame.midY))

        #expect(lands(onSecond, on: second))
        #expect(lands(onFirst, on: first))
    }

    @Test func theSystemsSmallButtonTakesAClickOver24() {
        let stop = KitPushButton("Stop", prominent: true, size: .small) {}
        let (row, window) = row([stop])
        defer { window.close() }
        let frame = stop.frame
        let short = (24 - frame.height) / 2

        let above = row.hitTest(NSPoint(x: frame.midX, y: frame.minY - short + 0.5))
        let past = row.hitTest(NSPoint(x: frame.midX, y: frame.minY - short - 0.5))

        #expect(frame.height < 24)
        #expect(above === stop)
        #expect(past !== stop)
    }

    @Test func aGlassKeyBuiltByHandTakesAClickOver24Too() {
        let key = KitButton(.keycap(.secondary), label: "Hand Back")
        key.content = KitLabel("Hand Back", font: .systemFont(ofSize: 12))
        key.padding = 9
        key.height = 22
        let (row, window) = row([key])
        defer { window.close() }
        let frame = key.frame

        let above = row.hitTest(NSPoint(x: frame.midX, y: frame.minY - 0.5))
        let below = row.hitTest(NSPoint(x: frame.midX, y: frame.maxY + 0.5))
        let past = row.hitTest(NSPoint(x: frame.midX, y: frame.maxY + 1.5))

        #expect(frame.height == 22)
        #expect(lands(above, on: key))
        #expect(lands(below, on: key))
        #expect(!lands(past, on: key))
    }

    @Test func aPlainKitButtonKeepsItsOwnReach() {
        let key = KitButton(title: "Plain", font: .systemFont(ofSize: 12), look: .plain(press: 1))
        key.height = 18
        let (row, window) = row([key])
        defer { window.close() }

        let above = row.hitTest(NSPoint(x: key.frame.midX, y: key.frame.minY - 0.5))

        #expect(!lands(above, on: key))
    }
}

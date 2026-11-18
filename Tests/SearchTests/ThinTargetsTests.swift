import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ThinTargetsTests {
    private func stage(_ size: NSSize) -> (KitFlippedView, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let stage = KitFlippedView(frame: NSRect(origin: .zero, size: size))
        window.contentView = stage
        let row = KitFlippedView(frame: stage.bounds)
        stage.addSubview(row)
        return (row, window)
    }

    private func sign() -> TranslateSignView {
        let tab = Tab(bench: true)
        tab.translation = TranslationMark(from: "fr", to: "en", phase: .done)
        return TranslateSignView(tab: tab)
    }

    @Test func aSignInThePillIsDrawn17By15AndTakesAClickOver24By24() {
        let (row, window) = stage(NSSize(width: 120, height: 34))
        defer { window.close() }
        let sign = sign()
        sign.frame = NSRect(x: 40, y: 9.5, width: 17, height: 15)
        row.addSubview(sign)

        let beside = row.hitTest(NSPoint(x: 37, y: 17))
        let above = row.hitTest(NSPoint(x: 48, y: 5.5))
        let below = row.hitTest(NSPoint(x: 48, y: 28.5))
        let past = row.hitTest(NSPoint(x: 48, y: 4.5))
        let far = row.hitTest(NSPoint(x: 36, y: 17))

        #expect(sign.intrinsicContentSize == NSSize(width: 17, height: 15))
        #expect(beside === sign)
        #expect(above === sign)
        #expect(below === sign)
        #expect(past !== sign)
        #expect(far !== sign)
    }

    @Test func aSignsReachStopsAtAKeyBesideIt() {
        let (row, window) = stage(NSSize(width: 120, height: 34))
        defer { window.close() }
        let sign = sign()
        sign.frame = NSRect(x: 40, y: 9.5, width: 17, height: 15)
        let key = KitGlassKey(symbol: "xmark", circle: 20)
        key.frame = NSRect(x: 59, y: 7, width: 20, height: 20)
        row.addSubview(key)
        row.addSubview(sign)

        let onKey = row.hitTest(NSPoint(x: 59.5, y: 17))
        let between = row.hitTest(NSPoint(x: 58, y: 17))

        #expect(onKey.map { $0 === key || $0.isDescendant(of: key) } ?? false)
        #expect(between === sign)
    }

    @Test func twoSignsSideBySideKeepTheirOwnHalves() {
        let (row, window) = stage(NSSize(width: 120, height: 34))
        defer { window.close() }
        let first = sign()
        let second = sign()
        first.frame = NSRect(x: 30, y: 9.5, width: 17, height: 15)
        second.frame = NSRect(x: 55, y: 9.5, width: 17, height: 15)
        row.addSubview(first)
        row.addSubview(second)

        let nearFirst = row.hitTest(NSPoint(x: 49, y: 17))
        let nearSecond = row.hitTest(NSPoint(x: 53, y: 17))

        #expect(nearFirst === first)
        #expect(nearSecond === second)
    }

    @Test func aRowOfATitleOverAFieldGivesItsClicksToTheField() {
        let (row, window) = stage(NSSize(width: 200, height: 90))
        defer { window.close() }
        let list = KitFieldRows(fill: nil)
        list.frame = row.bounds
        row.addSubview(list)
        var rows: [(title: NSView, field: NSTextField)] = []
        for index in 0..<2 {
            let top = CGFloat(index) * 42
            let title = KitLabel("Question \(index + 1)", font: .systemFont(ofSize: 12))
            let field = NSTextField(string: "An answer")
            title.frame = NSRect(x: 0, y: top, width: 100, height: 15)
            field.frame = NSRect(x: 0, y: top + 18, width: 200, height: 15)
            list.addSubview(title)
            list.addSubview(field)
            rows.append((title, field))
        }
        list.rows = rows

        let onTitle = list.hitTest(NSPoint(x: 20, y: 6))
        let afterFirst = list.hitTest(NSPoint(x: 150, y: 35))
        let beforeSecond = list.hitTest(NSPoint(x: 150, y: 40))
        let onSecondTitle = list.hitTest(NSPoint(x: 20, y: 48))

        #expect(rows[0].field.frame.height < 24)
        #expect(onTitle === rows[0].field)
        #expect(afterFirst === rows[0].field)
        #expect(beforeSecond === rows[1].field)
        #expect(onSecondTitle === rows[1].field)
    }
}

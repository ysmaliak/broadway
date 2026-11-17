import AppKit

enum TearRules {
    static let margin: CGFloat = 12
    static let push: CGFloat = 12
    static let grab = CGSize(width: 120, height: 20)
    static let newWindowSize = NSSize(width: 1180, height: 780)

    struct Facts: Equatable {
        var pin = false
        var bench = false
        var live = false
        var agent = false
    }

    static func mayLeave(_ facts: Facts) -> Bool {
        !facts.pin && !facts.bench && !facts.live && !facts.agent
    }

    static func takes(sourcePrivate: Bool, targetPrivate: Bool, targetPopup: Bool) -> Bool {
        !targetPopup && sourcePrivate == targetPrivate
    }

    static func beyond(_ point: NSPoint, _ frame: NSRect) -> Bool {
        !frame.insetBy(dx: -margin, dy: -margin).contains(point)
    }

    static func inside(_ point: NSPoint, _ frame: NSRect) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    static func fills(_ frame: NSRect, _ visible: NSRect) -> Bool {
        frame.minX <= visible.minX + 1 && frame.maxX >= visible.maxX - 1
            && frame.minY <= visible.minY + 1 && frame.maxY >= visible.maxY - 1
    }

    static func outward(from start: NSPoint?, to point: NSPoint, moved delta: CGVector, screen: NSRect) -> CGFloat? {
        let start = start ?? point
        let left = screen.minX + 1, right = screen.maxX - 1, bottom = screen.minY + 1, top = screen.maxY - 1
        var out: CGFloat = 0
        var edge = false
        if point.x <= left { edge = true; out += max(0, -delta.dx - max(0, start.x - left)) }
        if point.x >= right { edge = true; out += max(0, delta.dx - max(0, right - start.x)) }
        if point.y <= bottom { edge = true; out += max(0, -delta.dy - max(0, start.y - bottom)) }
        if point.y >= top { edge = true; out += max(0, delta.dy - max(0, top - start.y)) }
        return edge ? out : nil
    }

    static func aims(_ point: NSPoint, leaving window: NSRect) -> Bool {
        !inside(point, window)
    }

    struct State: Equatable {
        var out = false
        var pushed: CGFloat = 0
    }

    struct Screen: Equatable {
        var frame: NSRect
        var visible: NSRect
    }

    static func step(_ state: State, from start: NSPoint? = nil, point: NSPoint, moved delta: CGVector, window: NSRect, screen: Screen?) -> State {
        var next = state
        if let screen, fills(window, screen.visible), let out = outward(from: start, to: point, moved: delta, screen: screen.frame) {
            next.pushed += out
            if next.pushed >= push { next.out = true }
            return next
        }
        next.pushed = 0
        if beyond(point, window) {
            next.out = true
        } else if inside(point, window) {
            next.out = false
        }
        return next
    }

    static func clamp(_ frame: NSRect, into visible: NSRect) -> NSRect {
        var placed = frame
        placed.origin.x = max(visible.minX, min(frame.minX, visible.maxX - frame.width))
        placed.origin.y = min(visible.maxY - frame.height, max(frame.minY, visible.minY))
        return placed
    }

    static func newWindow(at point: NSPoint, leaving: NSSize?, zoomed: Bool, visible: NSRect?) -> NSRect {
        let size = zoomed ? newWindowSize : leaving ?? newWindowSize
        let frame = NSRect(x: point.x - grab.width, y: point.y - size.height + grab.height, width: size.width, height: size.height)
        return visible.map { clamp(frame, into: $0) } ?? frame
    }
}

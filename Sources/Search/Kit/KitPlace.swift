import AppKit

extension NSView {
    func kitPlace(_ rect: NSRect) -> NSRect {
        Self.kitPlace(rect, scale: window?.backingScaleFactor ?? 2, flipped: isFlipped)
    }

    static func kitPlace(_ rect: NSRect, scale: CGFloat, flipped: Bool) -> NSRect {
        let x = (rect.minX * scale).rounded(.toNearestOrAwayFromZero) / scale
        let y = flipped ? (rect.minY * scale - 0.5).rounded(.up) / scale : (rect.minY * scale).rounded(.toNearestOrAwayFromZero) / scale
        return NSRect(x: x, y: y, width: rect.width, height: rect.height)
    }
}

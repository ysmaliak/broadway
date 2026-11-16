import AppKit

extension NSView {
    func kitPlace(_ rect: NSRect) -> NSRect {
        let scale = window?.backingScaleFactor ?? 2
        let x = (rect.minX * scale).rounded(.toNearestOrAwayFromZero) / scale
        let y = isFlipped ? (rect.minY * scale - 0.5).rounded(.up) / scale : (rect.minY * scale).rounded(.toNearestOrAwayFromZero) / scale
        return NSRect(x: x, y: y, width: rect.width, height: rect.height)
    }
}

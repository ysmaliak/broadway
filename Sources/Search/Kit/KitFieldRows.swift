import AppKit

final class KitFieldRows: KitBox {
    var rows: [(title: NSView, field: NSTextField)] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, !isHidden, frame.contains(point) else { return nil }
        let hit = super.hitTest(point)
        if let hit, hit !== self, !rows.contains(where: { hit === $0.title || hit.isDescendant(of: $0.title) }) { return hit }
        let local = convert(point, from: superview)
        func gap(_ row: (title: NSView, field: NSTextField)) -> CGFloat {
            let box = row.title.frame.union(row.field.frame)
            return local.y < box.minY ? box.minY - local.y : max(0, local.y - box.maxY)
        }
        guard let row = rows.min(by: { gap($0) < gap($1) }) else { return hit }
        return KitReach.field(row.field)
    }
}

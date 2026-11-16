import AppKit

enum KitFlex {
    struct Item: Equatable {
        var least: CGFloat
        var most: CGFloat

        static func fixed(_ width: CGFloat) -> Item { Item(least: width, most: width) }
        static func spacer(_ least: CGFloat = 8) -> Item { Item(least: least, most: .greatestFiniteMagnitude) }
    }

    static func widths(_ items: [Item], spacing: CGFloat, in available: CGFloat) -> [CGFloat] {
        guard !items.isEmpty else { return [] }
        var widths = Array(repeating: CGFloat(0), count: items.count)
        let open = items.indices.filter { items[$0].most == .greatestFiniteMagnitude }
        let bounded = items.indices.filter { items[$0].most != .greatestFiniteMagnitude }
        var remaining = available - spacing * CGFloat(items.count - 1) - open.reduce(0) { $0 + items[$1].least }
        let order = bounded.sorted { (items[$0].most - items[$0].least, $0) < (items[$1].most - items[$1].least, $1) }
        for (done, index) in order.enumerated() {
            let offer = remaining / CGFloat(order.count - done)
            let width = min(max(offer, items[index].least), items[index].most)
            widths[index] = width
            remaining -= width
        }
        for (done, index) in open.enumerated() {
            let share = max(0, remaining) / CGFloat(open.count - done)
            widths[index] = items[index].least + share
            remaining -= share
        }
        return widths
    }

    static func lay(_ views: [NSView?], _ items: [Item], spacing: CGFloat, in rect: NSRect, snap: (NSRect) -> NSRect = { $0 }) {
        let widths = widths(items, spacing: spacing, in: rect.width)
        var x = rect.minX
        for (index, view) in views.enumerated() {
            if let view {
                let height = min(rect.height, view.intrinsicContentSize.height > 0 ? view.intrinsicContentSize.height : rect.height)
                view.frame = snap(NSRect(x: x, y: rect.minY + (rect.height - height) / 2, width: widths[index], height: height))
            }
            x += widths[index] + spacing
        }
    }
}

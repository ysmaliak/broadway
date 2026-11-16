import AppKit

/// A tab carried across the line between the pins and the tabs, as in Arc:
/// a tab let go over the grid becomes a pin there, a pin let go among the
/// tabs becomes a tab there, and the block it is over makes room for it on
/// the way — a place opened in the grid, a line opened among the rows —
/// so where it will land is seen before it is let go.
///
/// The gestures stay each row's and each square's own (Carried,
/// PinCarried); this is only where in the column the hand is, worked out
/// in one space every block is measured in (the page's, "column").
enum PinDrop {
    /// Where a carried tab would land.
    enum Target: Equatable {
        /// Among the squares, at this place.
        case squares(Int)
        /// Among the tabs in no group.
        case loose(Int)
        /// Into a group, over its heading.
        case group(UUID)
    }

    /// The tab being carried and where it would land: what the column
    /// shows while it is over a block that would take it.
    struct Crossing: Equatable {
        let tab: Tab.ID
        let target: Target
    }

    enum Zone: Equatable { case squares, loose, none }

    /// The half of the margin under the grid that still counts as the
    /// grid, so the hand needn't reach a square to aim between two.
    static let gridSlack: CGFloat = 5
    /// How far beside the column the hand may stray and still be in it.
    static let sideSlack: CGFloat = 10

    static func zone(_ point: CGPoint, width: CGFloat, gridBottom: CGFloat?) -> Zone {
        guard point.x >= -sideSlack, point.x <= width + sideSlack else { return .none }
        let edge = gridBottom.map { $0 + gridSlack } ?? 0
        if point.y < edge { return .squares }
        return .loose
    }

    /// The place among the squares a point is over, once the grid has made
    /// room for one more: the nearest of `cells`, laid out for that many.
    /// The place opened is one of them, so the hand over it keeps it.
    static func gridSlot(_ point: CGPoint, cells: [CGRect]) -> Int {
        func distance(_ cell: CGRect) -> CGFloat { hypot(cell.midX - point.x, cell.midY - point.y) }
        return cells.indices.min { distance(cells[$0]) < distance(cells[$1]) } ?? 0
    }

    /// The place among rows of `heights` (top to bottom, `gap` between) a
    /// point `y` down from the first is over: before the first row whose
    /// middle it is above. `ghost`: the line already opened, at its place
    /// and of its height — the hand anywhere on it keeps it, and the rows
    /// after it are measured where they now are, below it.
    static func rowSlot(y: CGFloat, heights: [CGFloat], gap: CGFloat, ghost: (at: Int, height: CGFloat)?) -> Int {
        var top: CGFloat = 0
        for (index, height) in heights.enumerated() {
            if let ghost, ghost.at == index {
                if y < top + ghost.height { return index }
                top += ghost.height + gap
            }
            if y < top + height / 2 { return index }
            top += height + gap
        }
        return heights.count
    }

    static func slot(y: CGFloat, rows: [CGRect], ghost: (at: Int, rect: CGRect)?) -> Int {
        for (index, row) in rows.enumerated() {
            if let ghost, ghost.at == index, y < ghost.rect.maxY { return index }
            if y < row.midY { return index }
        }
        return rows.count
    }
}

enum PinPlaces {
    static let height: CGFloat = 40
    static let narrowest: CGFloat = 36
    static let most = 5
    static let gap: CGFloat = 6
    static let mark: CGFloat = SideLook.pinMark
    static let radius: CGFloat = SideLook.pinRadius

    static func across(_ room: CGFloat) -> Int {
        (1...most).reversed().first { (room - CGFloat($0 - 1) * gap) / CGFloat($0) >= narrowest } ?? 1
    }

    static func rows(_ count: Int, most: Int) -> [Int] {
        guard count > 0 else { return [] }
        let most = max(1, most)
        let lines = (count + most - 1) / most
        let base = count / lines
        let extra = count % lines
        return (0..<lines).map { $0 < extra ? base + 1 : base }
    }

    static func cells(_ count: Int, room: CGFloat) -> [CGRect] {
        var cells: [CGRect] = []
        for (line, across) in rows(count, most: across(room)).enumerated() {
            let width = (room - CGFloat(across - 1) * gap) / CGFloat(across)
            for place in 0..<across {
                cells.append(CGRect(x: CGFloat(place) * (width + gap), y: CGFloat(line) * (height + gap),
                                    width: width, height: height))
            }
        }
        return cells
    }
}

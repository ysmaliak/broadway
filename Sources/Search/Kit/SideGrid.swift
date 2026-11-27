import Foundation

enum SideGrid {
    static let mark: CGFloat = 16
    static let gap: CGFloat = mark / 2
    static let tail: CGFloat = gap / 2
    static let keyGap: CGFloat = tail / 2
    static let edge: CGFloat = 6
    static let pad: CGFloat = edge / 2
    static let row: CGFloat = Metrics.sideRowHeight
    static let lead: CGFloat = (row - mark) / 2
    static let words: CGFloat = lead + mark + gap
    static let step: CGFloat = mark + gap
    static let key: CGFloat = row - 2 * tail
    static let bar: CGFloat = row - 2 * pad
}

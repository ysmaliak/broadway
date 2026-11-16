import AppKit

enum ColumnEdges {
    static let fade: CGFloat = 22
    static let clear: CGFloat = 6
    @MainActor static var seen: [String: CGFloat] = [:]
    @MainActor static var marks: [String: [CGFloat]] = [:]
}

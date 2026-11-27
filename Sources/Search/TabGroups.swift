import AppKit

struct GroupDropFrame: Equatable {
    let group: UUID
    var tab: UUID? = nil
    let rect: CGRect
}

struct GroupDropTarget: Equatable {
    let group: UUID
    var member: UUID? = nil
    var after = false
}

struct GroupDropFrames {
    static var defaultValue: [UUID: GroupDropFrame] = [:]

    static func reduce(value: inout [UUID: GroupDropFrame], nextValue: () -> [UUID: GroupDropFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }

    static func resolve(_ point: CGPoint, frames: [UUID: GroupDropFrame],
                        groups: [TabGroup], excluding source: UUID, vertical: Bool) -> GroupDropTarget? {
        let inward = groups.enumerated().sorted { a, b in
            let (one, two) = (FolderTree.depth(of: a.element.id, in: groups), FolderTree.depth(of: b.element.id, in: groups))
            return one != two ? one > two : a.offset < b.offset
        }.map(\.element)
        for group in inward {
            let heading = frames[group.id]?.rect
            let members = frames.values.filter { $0.group == group.id && $0.tab != nil && $0.tab != source }
                .sorted { vertical ? $0.rect.minY < $1.rect.minY : $0.rect.minX < $1.rect.minX }
            let extent = members.reduce(heading ?? .null) { $0.union($1.rect) }
            guard extent.contains(point) else { continue }
            if heading?.contains(point) == true || group.collapsed || members.isEmpty {
                return GroupDropTarget(group: group.id)
            }
            let position = vertical ? point.y : point.x
            if let next = members.first(where: { position < (vertical ? $0.rect.midY : $0.rect.midX) }) {
                return GroupDropTarget(group: group.id, member: next.tab)
            }
            return GroupDropTarget(group: group.id, member: members.last?.tab, after: true)
        }
        return nil
    }
}

enum FolderHeadingMetrics {
    static let height: CGFloat = Metrics.sideRowHeight
    static let indent: CGFloat = SideGrid.step
    static var closeInset: CGFloat { (height - Metrics.closeSquare(height)) / 2 }

    static func inset(depth: Int) -> CGFloat { CGFloat(max(0, depth - 1)) * indent }

    static func inside(x: CGFloat, depth: Int) -> Bool {
        x > inset(depth: depth) + SideGrid.step + SideGrid.tail
    }
}

struct LoosePlace: Equatable {
    var before: Browser.ListItem?
}

enum ListDrop: Equatable {
    case folder(GroupDropTarget)
    case loose(LoosePlace)

    static let edge: CGFloat = 9
    static let slack: CGFloat = 10

    static func resolve(_ point: CGPoint, items: [(item: Browser.ListItem, rect: CGRect)], below top: CGFloat,
                        frames: [UUID: GroupDropFrame], groups: [TabGroup], excluding source: UUID, band: CGFloat = edge) -> ListDrop? {
        let inward = GroupDropFrames.resolve(point, frames: frames, groups: groups, excluding: source, vertical: true).map(ListDrop.folder)
        guard let first = items.first, point.y >= top,
              point.x >= first.rect.minX - slack, point.x <= first.rect.maxX + slack else { return inward }
        for (index, entry) in items.enumerated() {
            let next = items.indices.contains(index + 1) ? items[index + 1].item : nil
            let rect = entry.rect
            guard case .folder(let id) = entry.item else {
                if point.y < rect.midY { return .loose(LoosePlace(before: entry.item)) }
                continue
            }
            if point.y < rect.minY + band { return .loose(LoosePlace(before: entry.item)) }
            guard point.y <= rect.maxY else { continue }
            if inward == nil, frames[source]?.rect.contains(point) == true { return nil }
            let filled = frames.values.contains { frame in
                frame.tab != source && (frame.tab != nil || frame.group != id) && rect.contains(CGPoint(x: frame.rect.midX, y: frame.rect.midY))
            }
            if !filled, band > 0, point.y >= rect.maxY - band { return .loose(LoosePlace(before: next)) }
            if let inward { return inward }
            return .loose(LoosePlace(before: point.y < rect.midY ? entry.item : next))
        }
        return .loose(LoosePlace(before: nil))
    }
}

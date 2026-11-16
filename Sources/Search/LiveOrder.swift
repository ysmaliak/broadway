import Foundation

enum LiveOrder {
    static let kept = 300

    static func blocks(_ items: [LiveItem]) -> [[LiveItem]] {
        let tops = LiveStackRuns.tops(items)
        var out: [[LiveItem]] = []
        for (index, item) in items.enumerated() {
            if let top = tops[index], top != index, !out.isEmpty { out[out.count - 1].append(item) } else { out.append([item]) }
        }
        return out
    }

    static func shown(_ items: [LiveItem], by order: [String]?) -> [LiveItem] {
        guard let order, !order.isEmpty else { return items }
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let ranked = blocks(items).enumerated().map { index, block in
            (block: block, rank: block.compactMap { rank[LiveIdentity.of($0.key)] }.min(), index: index)
        }
        return ranked.sorted { a, b in
            switch (a.rank, b.rank) {
            case (nil, nil): return a.index < b.index
            case (nil, _): return true
            case (_, nil): return false
            case let (one?, two?): return one != two ? one < two : a.index < b.index
            }
        }.flatMap(\.block)
    }

    static func noted(_ order: [String], items: [LiveItem]) -> [String] {
        merged(identities(shown(items, by: order)), into: order)
    }

    static func moved(_ items: [LiveItem], by order: [String]?, key: String, to anchor: String?, after: Bool) -> [String]? {
        let before = shown(items, by: order)
        var blocks = blocks(before)
        let identity = LiveIdentity.of(key)
        func holds(_ block: [LiveItem], _ wanted: String) -> Bool { block.contains { LiveIdentity.of($0.key) == wanted } }
        guard let from = blocks.firstIndex(where: { holds($0, identity) }) else { return nil }
        let target = anchor.map(LiveIdentity.of)
        if let target, holds(blocks[from], target) { return nil }
        let block = blocks.remove(at: from)
        var at = 0
        if let target {
            guard let found = blocks.firstIndex(where: { holds($0, target) }) else { return nil }
            at = found + (after ? 1 : 0)
        }
        blocks.insert(block, at: at)
        let now = identities(blocks.flatMap { $0 })
        guard now != identities(before) else { return nil }
        return merged(now, into: order ?? [])
    }

    static func identities(_ items: [LiveItem]) -> [String] {
        var out: [String] = []
        for item in items {
            let identity = LiveIdentity.of(item.key)
            if !out.contains(identity) { out.append(identity) }
        }
        return out
    }

    static func merged(_ present: [String], into old: [String]) -> [String] {
        var out = present
        let here = Set(present)
        var last: Int?
        for key in old where !out.contains(key) || here.contains(key) {
            if here.contains(key) {
                last = out.firstIndex(of: key)
                continue
            }
            let at = last.map { $0 + 1 } ?? 0
            out.insert(key, at: at)
            last = at
        }
        while out.count > kept, let gone = out.lastIndex(where: { !here.contains($0) }) { out.remove(at: gone) }
        return out
    }

    static func keep(_ folder: inout LiveFolder) {
        guard let order = folder.order else { return }
        folder.order = noted(order, items: folder.items)
    }
}

extension Browser {
    func liveDrop(_ target: GroupDropTarget, carrying tab: Tab) -> GroupDropTarget? {
        guard let group = tabGroups.first(where: { $0.id == target.group }), group.live else { return target }
        guard tab.groupID == group.id, tab.liveKey != nil else { return nil }
        guard let member = target.member else { return target }
        let drawn = Self.unfoldedStacks(drawnTabs(in: group), in: group, front: activeSplit?.left ?? activeID)
        let runs = LiveStackRuns.tops(drawn.map(\.liveItem))
        guard let at = drawn.firstIndex(where: { $0.id == member }), let top = runs[at] else { return target }
        if let mine = drawn.firstIndex(where: { $0.id == tab.id }), runs[mine] == top { return nil }
        var end = at
        while end + 1 < drawn.count, runs[end + 1] == top { end += 1 }
        let above = at - top + (target.after ? 1 : 0)
        let below = end - at + (target.after ? 0 : 1)
        return above <= below ? GroupDropTarget(group: group.id, member: drawn[top].id)
            : GroupDropTarget(group: group.id, member: drawn[end].id, after: true)
    }

    func reorderLive(_ tab: Tab, to target: GroupDropTarget) -> Bool {
        guard let group = tabGroups.first(where: { $0.id == target.group }), group.live,
              tab.groupID == group.id, let key = tab.liveKey else { return false }
        let live = LiveFolders.shared
        guard let folder = live.folder(group.id) else { return true }
        let anchor = target.member.flatMap { id in tabs.first { $0.id == id } }?.liveKey
        if target.member != nil, anchor == nil { return true }
        guard let order = LiveOrder.moved(folder.items, by: folder.order, key: key, to: anchor, after: target.after) else { return true }
        live.setOrder(folder.id, order)
        syncLive()
        return true
    }
}

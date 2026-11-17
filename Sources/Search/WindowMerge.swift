import AppKit

@MainActor
enum WindowMerge {
    struct Kind: Equatable {
        var open: Bool
        var popup: Bool
        var privateWindow: Bool
    }

    static func joins(_ other: Kind, into front: Kind) -> Bool {
        guard !front.popup, !front.privateWindow else { return false }
        return other.open && !other.popup && !other.privateWindow
    }

    static func kind(of browser: Browser) -> Kind {
        Kind(open: browser.isOpen, popup: browser.isPopup, privateWindow: browser.isPrivate)
    }

    static func sources(into front: Browser) -> [Browser] {
        let target = kind(of: front)
        return Browsers.all.filter { $0 !== front && joins(kind(of: $0), into: target) }
    }

    static func canMerge(into front: Browser) -> Bool { !sources(into: front).isEmpty }

    static func moves(_ tab: Tab, groups: [TabGroup]) -> Bool {
        guard tab.pin == nil, !tab.bench else { return false }
        if tab.liveKey != nil, let id = tab.groupID, groups.contains(where: { $0.id == id && $0.live }) { return false }
        return true
    }

    static func run(into front: Browser) {
        let others = sources(into: front)
        guard !others.isEmpty else { return }
        var last: Tab.ID?
        for other in others { last = carry(from: other, into: front, after: last) ?? last }
        for other in others {
            Browsers.closeUnremembered(other)
        }
    }

    @discardableResult
    static func carry(from source: Browser, into front: Browser, after previous: Tab.ID? = nil) -> Tab.ID? {
        if let floating = source.floating, source.tabs.contains(where: { $0.id == floating }) {
            source.land(covering: false)
        }
        source.cancelTabEdit()
        var last: Tab.ID?
        for space in rowSpaces(of: source) {
            let row = takeRow(space, from: source)
            guard !row.tabs.isEmpty || !row.groups.isEmpty else { continue }
            give(row, space: space, to: front, after: previous)
            if space == front.spaceID, let end = row.tabs.last { last = end.id }
        }
        return last
    }

    private struct Row {
        var tabs: [Tab] = []
        var splits: [TabSplit] = []
        var groups: [TabGroup] = []
    }

    private static func rowSpaces(of browser: Browser) -> [UUID] {
        var spaces = [browser.spaceID]
        for space in browser.spaces.map(\.id) where space != browser.spaceID {
            if browser.parked[space] != nil || !browser.readRow(space).tabs.isEmpty { spaces.append(space) }
        }
        for space in browser.parked.keys where !spaces.contains(space) { spaces.append(space) }
        return spaces
    }

    private static func takeRow(_ space: UUID, from source: Browser) -> Row {
        if space == source.spaceID {
            let groups = source.tabGroups
            let movers = source.tabs.filter { moves($0, groups: groups) }
            let ids = Set(movers.map(\.id))
            let splits = source.splits.filter { $0.tabs.allSatisfy(ids.contains) }
            for tab in movers {
                if let web = tab.built { source.cancelDisplay(for: web) }
                if source.split(for: tab) != nil { source.detachSplit(tab) }
            }
            source.replaceRow(source.tabs.filter { !ids.contains($0.id) })
            return Row(tabs: movers, splits: splits, groups: groups.filter { !$0.live })
        }
        var row = source.parked[space] ?? source.loadRow(space)
        let groups = row.groups ?? source.readRow(space).groups ?? []
        let movers = row.tabs.filter { moves($0, groups: groups) }
        let ids = Set(movers.map(\.id))
        let splits = row.splits.filter { $0.tabs.allSatisfy(ids.contains) }
        row.tabs.removeAll { ids.contains($0.id) }
        row.splits.removeAll { $0.tabs.contains(where: ids.contains) }
        if let active = row.active, ids.contains(active) { row.active = row.tabs.first?.id }
        source.parked[space] = row
        return Row(tabs: movers, splits: splits, groups: groups.filter { !$0.live })
    }

    private static func give(_ row: Row, space: UUID, to front: Browser, after previous: Tab.ID?) {
        for tab in row.tabs {
            front.prepare(tab)
            tab.rehome(in: space)
        }
        if space == front.spaceID {
            let following = previous.flatMap { id in front.tabs.firstIndex { $0.id == id } }.map { $0 + 1 }
            let at = min(max(following ?? front.placeForNew(), front.pinnedCount), front.tabs.count)
            var tabs = front.tabs
            tabs.insert(contentsOf: row.tabs, at: at)
            front.tabGroups = joined(front.tabGroups, row.groups)
            front.replaceRow(tabs)
            for pair in row.splits { front.putBackSplit(pair) }
            front.writeSession(now: true)
            return
        }
        var kept = front.parked[space] ?? front.loadRow(space)
        kept.tabs += row.tabs
        kept.splits += row.splits
        kept.groups = joined(kept.groups ?? front.readRow(space).groups ?? [], row.groups)
        if kept.active == nil { kept.active = kept.tabs.first { $0.pin == nil }?.id }
        front.parked[space] = kept
        front.writeSession(now: true, space: space, row: kept)
    }

    private static func joined(_ have: [TabGroup], _ added: [TabGroup]) -> [TabGroup] {
        let known = Set(have.map(\.id))
        let all = have + added.filter { !known.contains($0.id) }
        let ids = Set(all.map(\.id))
        return all.map { group in
            var group = group
            if let parent = group.parent, !ids.contains(parent) { group.parent = nil }
            return group
        }
    }
}

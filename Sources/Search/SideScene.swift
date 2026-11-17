import AppKit

struct SidePreview {
    let space: UUID
    var row: Parked
    var rest: ColumnRest

    var signature: [UUID] {
        var out = row.tabs.map(\.id)
        out += (row.groups ?? []).map(\.id)
        out += (row.groups ?? []).filter(\.collapsed).map(\.id)
        out += row.splits.map(\.id)
        if let active = row.active { out.append(active) }
        return out
    }
}

struct SideScene {
    var live: Bool
    var pins: [Tab]
    var tabs: [Tab]
    var groups: [TabGroup]
    var tops: [TabGroup]
    var listFolders: [TabGroup]
    var tasks: [TaskFolder]
    var loose: [Tab]
    var items: [Browser.ListItem]
    var splits: [TabSplit]
    var active: UUID?
    var lit: Set<UUID>
    var numbers: [UUID: Int]
    var visible: (TabGroup) -> [Tab]

    func group(_ id: UUID) -> TabGroup? { groups.first { $0.id == id } }

    @MainActor
    static func live(_ browser: Browser) -> SideScene {
        let groupsOn = browser.prefs.usesTabGroups
        let gathered = browser.gatheredTabs
        let displayed = browser.displayedTabs
        let shown = displayed.filter { !gathered.contains($0.id) }
        return SideScene(
            live: true,
            pins: browser.squarePins,
            tabs: browser.tabs,
            groups: browser.tabGroups,
            tops: groupsOn ? browser.folderRows.filter { $0.kind == .heading && $0.depth == 0 && $0.group.isPinned }.map(\.group) : [],
            listFolders: groupsOn ? browser.tabGroups.filter { $0.parent == nil && !$0.isPinned } : [],
            tasks: browser.taskFolders,
            loose: displayed.filter { $0.pin == nil && !gathered.contains($0.id) && (!groupsOn || browser.group(of: $0) == nil) },
            items: browser.listItems(shown),
            splits: browser.splits,
            active: browser.activeID,
            lit: RowRun.lit(picked: browser.selectedTabIDs, active: browser.activeID),
            numbers: browser.tabShortcutNumbers,
            visible: { [unowned browser] in browser.visibleTabs(in: $0) })
    }

    @MainActor
    static func parked(_ row: Parked, prefs: Preferences) -> SideScene {
        let groupsOn = prefs.usesTabGroups
        let splitOn = prefs.splitView
        let stands: (Tab) -> Bool = { tab in
            !splitOn || !row.splits.contains { $0.tabs.contains(tab.id) && $0.tabs.first != tab.id }
        }
        let kept = groupsOn ? FolderTree.ordered(FolderTree.lasting(row.groups ?? [], holding: Set(row.tabs.compactMap(\.groupID)))) : []
        let ids = Set(kept.map(\.id))
        let front = row.splits.first { pair in row.active.map(pair.tabs.contains) ?? false }?.tabs.first ?? row.active
        let tabs = row.tabs
        let items = FolderTree.listed(tabs.filter { $0.pin == nil && stands($0) },
                                      group: { tab in tab.groupID.flatMap { ids.contains($0) ? $0 : nil } }, in: kept) { .tab($0.id) }
        return SideScene(
            live: false,
            pins: tabs.filter { $0.pin != nil && stands($0) },
            tabs: tabs,
            groups: kept,
            tops: kept.filter { $0.parent == nil && $0.isPinned },
            listFolders: kept.filter { $0.parent == nil && !$0.isPinned },
            tasks: [],
            loose: tabs.filter { $0.pin == nil && stands($0) && !($0.groupID.map(ids.contains) ?? false) },
            items: items,
            splits: row.splits,
            active: row.active,
            lit: [],
            numbers: [:],
            visible: { group in
                if FolderTree.ancestors(of: group.id, in: kept).contains(where: \.collapsed) { return [] }
                if group.collapsed {
                    let inside = Set([group.id] + FolderTree.descendants(of: group.id, in: kept).map(\.id))
                    return tabs.filter { $0.pin == nil && $0.groupID.map(inside.contains) == true && stands($0) && $0.id == front }
                }
                return Browser.unfoldedStacks(tabs.filter { $0.pin == nil && $0.groupID == group.id && stands($0) }, in: group, front: front)
            })
    }
}

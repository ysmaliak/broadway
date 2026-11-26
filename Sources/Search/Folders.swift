import AppKit

enum FolderTree {
    static let deepest = 5

    struct Row: Identifiable, Equatable {
        enum Kind { case heading, tabs }
        let group: TabGroup
        let depth: Int
        let kind: Kind
        var id: String { "\(group.id.uuidString)-\(kind == .heading ? "h" : "t")" }
    }

    static func ordered(_ groups: [TabGroup]) -> [TabGroup] {
        let ids = Set(groups.map(\.id))
        var fixed = groups.map { group -> TabGroup in
            var group = group
            if let parent = group.parent, !ids.contains(parent) || parent == group.id { group.parent = nil }
            return group
        }
        for index in fixed.indices {
            var seen: Set<UUID> = [fixed[index].id]
            var at = fixed[index].parent
            while let parent = at {
                guard seen.insert(parent).inserted else {
                    fixed[index].parent = nil
                    break
                }
                at = fixed.first { $0.id == parent }?.parent
            }
        }
        func walk(_ parent: UUID?) -> [TabGroup] {
            fixed.filter { $0.parent == parent }.flatMap { [$0] + walk($0.id) }
        }
        let roots = fixed.filter { $0.parent == nil }
        let raised = roots.filter(\.live) + roots.filter { !$0.live && $0.pinned } + roots.filter { !$0.isPinned }
        return raised.flatMap { [$0] + walk($0.id) }
    }

    static func root(of id: UUID, in groups: [TabGroup]) -> UUID {
        ancestors(of: id, in: groups).last?.id ?? id
    }

    static func raised(_ id: UUID, in groups: [TabGroup]) -> Bool {
        let top = root(of: id, in: groups)
        return groups.first { $0.id == top }?.isPinned ?? true
    }

    static func tabOrder(_ groups: [TabGroup]) -> [TabGroup] {
        func walk(_ parent: UUID?) -> [TabGroup] {
            groups.filter { $0.parent == parent }.flatMap { walk($0.id) + [$0] }
        }
        return walk(nil)
    }

    static func ancestors(of id: UUID, in groups: [TabGroup]) -> [TabGroup] {
        var found: [TabGroup] = []
        var at = groups.first { $0.id == id }?.parent
        while let parent = at, let group = groups.first(where: { $0.id == parent }),
              !found.contains(where: { $0.id == parent }) {
            found.append(group)
            at = group.parent
        }
        return found
    }

    static func depth(of id: UUID, in groups: [TabGroup]) -> Int {
        ancestors(of: id, in: groups).count
    }

    static func descendants(of id: UUID, in groups: [TabGroup]) -> [TabGroup] {
        groups.filter { $0.parent == id }.flatMap { [$0] + descendants(of: $0.id, in: groups) }
    }

    static func height(of id: UUID, in groups: [TabGroup]) -> Int {
        1 + (groups.filter { $0.parent == id }.map { height(of: $0.id, in: groups) }.max() ?? 0)
    }

    static func canNest(_ id: UUID, in parent: UUID?, groups: [TabGroup]) -> Bool {
        guard let parent else { return true }
        guard parent != id, !descendants(of: id, in: groups).contains(where: { $0.id == parent }) else { return false }
        return depth(of: parent, in: groups) + 1 + height(of: id, in: groups) <= deepest
    }

    static func canAddChild(to parent: UUID?, groups: [TabGroup]) -> Bool {
        guard let parent else { return true }
        return depth(of: parent, in: groups) + 2 <= deepest
    }

    static func lasting(_ groups: [TabGroup], holding: Set<UUID>) -> [TabGroup] {
        func lasts(_ group: TabGroup) -> Bool {
            group.held || holding.contains(group.id) || groups.contains { $0.parent == group.id && lasts($0) }
        }
        return groups.filter(lasts)
    }

    static func newPlace(of made: TabGroup, in groups: [TabGroup]) -> Int {
        guard made.parent == nil, !made.isPinned, made.leads else { return groups.count }
        return groups.firstIndex { $0.parent == nil && !$0.isPinned } ?? groups.count
    }

    static func leads(_ id: UUID, in groups: [TabGroup]) -> Bool {
        let top = root(of: id, in: groups)
        return groups.first { $0.id == top }.map { !$0.isPinned && $0.leads } ?? false
    }

    static func listed<Member>(_ members: [Member], group: (Member) -> UUID?, in groups: [TabGroup],
                               tab: (Member) -> Browser.ListItem) -> [Browser.ListItem] {
        var items: [Browser.ListItem] = []
        var gathered = Set<UUID>()
        for member in members {
            guard let id = group(member) else {
                items.append(tab(member))
                continue
            }
            guard !raised(id, in: groups) else { continue }
            let top = root(of: id, in: groups)
            if gathered.insert(top).inserted { items.append(.folder(top)) }
        }
        let empty = groups.filter { $0.parent == nil && !$0.isPinned && !gathered.contains($0.id) }
        return empty.filter(\.leads).map { .folder($0.id) } + items + empty.filter { !$0.leads }.map { .folder($0.id) }
    }

    static func rows(_ groups: [TabGroup]) -> [Row] {
        func walk(_ parent: UUID?, _ depth: Int) -> [Row] {
            groups.filter { $0.parent == parent }.flatMap { group -> [Row] in
                let inside = group.collapsed ? [] : walk(group.id, depth + 1)
                return [Row(group: group, depth: depth, kind: .heading)] + inside
                    + [Row(group: group, depth: depth, kind: .tabs)]
            }
        }
        return walk(nil, 0)
    }

    static func level(from group: UUID?, by steps: Int, groups: [TabGroup]) -> (moves: Bool, to: UUID?) {
        var at = group
        var moved = false
        for _ in 0..<abs(steps) {
            if steps < 0 {
                guard let here = at else { break }
                at = groups.first { $0.id == here }?.parent
                moved = true
            } else {
                guard let next = groups.last(where: { $0.parent == at }) else { break }
                at = next.id
                moved = true
            }
        }
        return (moved, at)
    }

    static func heldNeighbour(shift: CGFloat, step: CGFloat, index: Int, count: Int) -> Int? {
        guard abs(shift) > step * 0.22, abs(shift) < step * 0.5 else { return nil }
        let neighbour = shift > 0 ? index + 1 : index - 1
        return (0..<count).contains(neighbour) ? neighbour : nil
    }
}

@MainActor
final class FolderSpring {
    private var waiting: UUID?
    private var work: DispatchWorkItem?

    func over(_ id: UUID?, open: @escaping (UUID) -> Void) {
        guard id != waiting else { return }
        work?.cancel()
        work = nil
        waiting = id
        guard let id else { return }
        let next = DispatchWorkItem { [weak self] in
            self?.waiting = nil
            open(id)
        }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: next)
    }
}

@MainActor
final class FolderHold {
    private(set) var ready: Tab.ID?
    private var waiting: Tab.ID?
    private var work: DispatchWorkItem?

    func over(_ id: Tab.ID?, changed: @escaping (Tab.ID?) -> Void) {
        guard id != waiting else { return }
        work?.cancel()
        work = nil
        waiting = id
        if ready != nil {
            ready = nil
            changed(nil)
        }
        guard let id else { return }
        let next = DispatchWorkItem { [weak self] in
            self?.ready = id
            changed(id)
        }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: next)
    }

    func take() -> Tab.ID? {
        let id = ready
        work?.cancel()
        work = nil
        waiting = nil
        ready = nil
        return id
    }
}

extension Browser {
    var folderRows: [FolderTree.Row] { FolderTree.rows(tabGroups) }

    func folderDepth(_ id: UUID) -> Int { FolderTree.depth(of: id, in: tabGroups) }

    func folderFamily(_ id: UUID) -> [TabGroup] {
        tabGroups.filter { $0.id == id } + FolderTree.descendants(of: id, in: tabGroups)
    }

    func folderTabs(_ id: UUID) -> [Tab] {
        let ids = Set(folderFamily(id).map(\.id))
        return tabs.filter { tab in tab.pin == nil && tab.groupID.map(ids.contains) == true }
    }

    func unfoldFolder(_ id: UUID) {
        let open = Set([id] + FolderTree.ancestors(of: id, in: tabGroups).map(\.id))
        guard tabGroups.contains(where: { open.contains($0.id) && $0.collapsed }) else { return }
        for index in tabGroups.indices where open.contains(tabGroups[index].id) {
            tabGroups[index].collapsed = false
        }
    }

    var frontFolder: TabGroup? {
        guard let tab = active, let id = group(of: tab) else { return nil }
        return tabGroups.first { $0.id == id }
    }

    @discardableResult
    func newFolder(inside parent: UUID? = nil, named name: String? = nil, editing: Bool = true, pinned: Bool = false) -> UUID? {
        let mark = beginStep("New Folder")
        defer { endStep(mark) }
        guard FolderTree.canAddChild(to: parent, groups: tabGroups) else {
            announce("Folders go \(FolderTree.deepest) deep")
            return nil
        }
        let id = UUID()
        var made = TabGroup(id: id, name: name ?? "Folder \(tabGroups.count + 1)", collapsed: false,
                            parent: parent, held: true)
        if name == nil { made.madeName = made.name }
        made.pinned = parent.map { FolderTree.raised($0, in: tabGroups) } ?? pinned
        made.leads = parent == nil && !made.pinned
        tabGroups.insert(made, at: FolderTree.newPlace(of: made, in: tabGroups))
        if let parent { unfoldFolder(parent) }
        if editing { editingGroupID = id }
        writeSession(now: true)
        FolderEmojis.shared.add(to: id, in: self)
        return id
    }

    @discardableResult
    func newFolder(with picked: [Tab], inside parent: UUID? = nil, named name: String? = nil, editing: Bool = true) -> UUID? {
        let mark = beginStep("New Folder")
        defer { endStep(mark) }
        let chosen = picked.filter { tab in
            tab.pin == nil && !tab.shy && !tab.bench && tabs.contains { $0.id == tab.id }
        }
        let first = chosen.min { a, b in
            (tabs.firstIndex { $0.id == a.id } ?? 0) < (tabs.firstIndex { $0.id == b.id } ?? 0)
        }
        let pinned = parent.map { FolderTree.raised($0, in: tabGroups) } ?? first.flatMap { group(of: $0) }.map { FolderTree.raised($0, in: tabGroups) } ?? false
        guard !chosen.isEmpty, let id = newFolder(inside: parent, named: name, editing: editing, pinned: pinned) else { return nil }
        for tab in chosen { move(tab, toGroup: id, staying: true) }
        return id
    }

    func nest(_ id: UUID, in parent: UUID?, before sibling: UUID? = nil) {
        let mark = beginStep("Move Folder")
        defer { endStep(mark) }
        guard tabGroups.contains(where: { $0.id == id }), id != sibling,
              FolderTree.canNest(id, in: parent, groups: tabGroups) else { return }
        if parent == nil {
            let pinned = sibling.map { FolderTree.raised($0, in: tabGroups) } ?? FolderTree.raised(id, in: tabGroups)
            placeFolder(id, pinned: pinned, before: sibling.map { .folder(FolderTree.root(of: $0, in: tabGroups)) })
            return
        }
        var groups = tabGroups
        guard var moving = groups.first(where: { $0.id == id }) else { return }
        groups.removeAll { $0.id == id }
        moving.parent = parent
        if let parent { moving.pinned = FolderTree.raised(parent, in: tabGroups) }
        let place = sibling.flatMap { target in groups.firstIndex { $0.id == target } }
        groups.insert(moving, at: place ?? groups.count)
        tabGroups = groups
        if let parent { unfoldFolder(parent) }
        arrangeGroupedTabs()
        writeSession(now: true)
    }

    func placeFolder(_ id: UUID, pinned: Bool, before item: ListItem? = nil) {
        let mark = beginStep("Move Folder")
        defer { endStep(mark) }
        guard let index = tabGroups.firstIndex(where: { $0.id == id }),
              !tabGroups[index].live, item != .folder(id) else { return }
        let items = listItems(displayedTabs).filter { $0 != .folder(id) }
        var groups = tabGroups
        var moving = groups.remove(at: index)
        moving.parent = nil
        moving.pinned = pinned
        let inside = Set(FolderTree.descendants(of: id, in: tabGroups).map(\.id))
        for at in groups.indices where inside.contains(groups[at].id) { groups[at].pinned = pinned }
        var sibling: UUID?
        if pinned, case .folder(let target)? = item { sibling = target }
        var row = tabs
        let family = Set([id] + inside)
        let members = row.filter { $0.pin == nil && $0.groupID.map(family.contains) == true }
        if !pinned, members.isEmpty { moving.leads = true }
        let place = sibling.flatMap { target in groups.firstIndex { $0.id == target } }
            ?? (pinned ? groups.lastIndex { $0.parent == nil && $0.isPinned }.map { $0 + 1 }
                : moving.leads ? FolderTree.newPlace(of: moving, in: groups) : nil)
        groups.insert(moving, at: place ?? groups.count)
        if !pinned {
            let ids = Set(members.map(\.id))
            row.removeAll { ids.contains($0.id) }
            let anchor: Int? = switch item.flatMap({ items.contains($0) ? $0 : nil }) {
            case .tab(let tab)?: row.firstIndex { $0.id == tab }
            case .folder(let other)?: row.firstIndex { tab in
                tab.pin == nil && tab.groupID.map { FolderTree.root(of: $0, in: groups) == other } == true
            } ?? (FolderTree.leads(other, in: groups) ? listTop(row, groups: groups) : nil)
            case nil: nil
            }
            row.insert(contentsOf: members, at: anchor ?? row.count)
        }
        if editingGroupID == id { editingGroupID = nil }
        tabGroups = groups
        if row.elementsEqual(tabs, by: { $0.id == $1.id }) { arrangeGroupedTabs() } else { setRow(row) }
        writeSession(now: true)
    }

    func moveOut(_ tab: Tab, before item: ListItem?) {
        let mark = beginStep("Remove from Folder")
        defer { endStep(mark) }
        guard tabs.contains(where: { $0 === tab }), group(of: tab) != nil else { return }
        placeInList(tab, before: item, leaving: true)
    }

    func moveLoose(_ tab: Tab, before item: ListItem?) {
        let mark = beginStep("Move Tab")
        defer { endStep(mark) }
        guard tabs.contains(where: { $0 === tab }), tab.pin == nil, group(of: tab) == nil else { return }
        if case .tab(let id)? = item, id == tab.id { return }
        placeInList(tab, before: item, leaving: false)
    }

    private func placeInList(_ tab: Tab, before item: ListItem?, leaving: Bool) {
        let moving = split(for: tab).map { pair in pair.tabs.compactMap { id in tabs.first { $0.id == id } } } ?? [tab]
        guard moving.allSatisfy({ $0.pin == nil && !$0.shy && !$0.bench }) else { return }
        let ids = Set(moving.map(\.id))
        let anchor: Int? = switch item {
        case .tab(let id)?: tabs.firstIndex { $0.id == id }
        case .folder(let id)?: tabs.firstIndex { tab in
            tab.pin == nil && tab.groupID.map { FolderTree.root(of: $0, in: tabGroups) == id } == true
        } ?? listTop(tabs, groups: tabGroups)
        case nil: nil
        }
        var row = tabs.filter { !ids.contains($0.id) }
        let insertion = anchor.map { at in tabs[..<at].filter { !ids.contains($0.id) }.count } ?? row.count
        let previous = Dictionary(moving.map { ($0.id, $0.groupID) }, uniquingKeysWith: { first, _ in first })
        if leaving {
            for member in moving {
                member.groupID = nil
                letGoLive(member, from: previous[member.id] ?? nil)
            }
        }
        row.insert(contentsOf: moving, at: insertion)
        guard row.map(\.id) != tabs.map(\.id) || leaving else { return }
        setRow(row)
        if leaving { for id in Set(previous.values.compactMap { $0 }) { removeEmptyGroup(id) } }
        if tab.liveKey != nil { syncLive() }
        writeSession(now: true)
    }

    func listTop(_ row: [Tab], groups: [TabGroup]) -> Int? {
        row.firstIndex { tab in
            guard tab.pin == nil else { return false }
            guard let id = tab.groupID, groups.contains(where: { $0.id == id }) else { return true }
            return !FolderTree.raised(id, in: groups)
        }
    }

    func setFolderPinned(_ id: UUID, _ pinned: Bool) {
        guard let group = tabGroups.first(where: { $0.id == id }), !group.live, group.parent == nil,
              group.pinned != pinned else { return }
        placeFolder(id, pinned: pinned, before: pinned ? nil : listItems(displayedTabs).first)
    }

    func dropFolder(_ id: UUID, on target: UUID, inside: Bool) {
        guard id != target, let over = tabGroups.first(where: { $0.id == target }) else { return }
        if inside {
            nest(id, in: target)
        } else {
            nest(id, in: over.parent, before: target)
        }
    }

    func toggleFolderWhole(_ id: UUID) {
        let family = Set(folderFamily(id).map(\.id))
        let shut = !tabGroups.contains { family.contains($0.id) && $0.collapsed }
        KitChange.eased {
            for index in tabGroups.indices where family.contains(tabGroups[index].id) {
                tabGroups[index].collapsed = shut
            }
        }
        writeSession(now: true)
    }

    func sleepFolder(_ id: UUID) {
        for tab in folderTabs(id) { sleep(tab) }
    }

    @discardableResult
    func shiftLevel(_ tab: Tab, by steps: Int) -> Bool {
        guard steps != 0, tab.pin == nil, !tab.shy, !tab.bench else { return false }
        let shift = FolderTree.level(from: group(of: tab), by: steps, groups: tabGroups)
        guard shift.moves else { return false }
        move(tab, toGroup: shift.to)
        return true
    }

    func showPlusMenu() {
        guard plusDoor.width > 0 else {
            PlusMenu.menu(for: self).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        plusOpen.toggle()
    }
}

@MainActor
enum PlusMenu {
    static func item(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        KitMenu.item(.action(title, run: run))
    }

    static func column(for browser: Browser) -> NSMenu {
        let menu = NSMenu()
        let prefs = browser.prefs
        menu.addItem(item("New Tab") { browser.launch() }.symbol(MenuSymbol.newTab))
        menu.addItem(item("New Folder") { browser.newFolder() }.symbol(MenuSymbol.newFolder))
        menu.addItem(.separator())
        menu.addItem(item("Hide Sidebar") { browser.toggleFold() }.symbol(MenuSymbol.sidebar))
        menu.addItem(item(prefs.sidePosition == .right ? "Sidebar on Left" : "Sidebar on Right") {
            prefs.sidePosition = prefs.sidePosition == .right ? .left : .right
        })
        menu.addItem(item("Sidebar Settings") { browser.openSettings(.appearance) })
        return menu
    }

    static func menu(for browser: Browser) -> NSMenu {
        let menu = NSMenu()
        let newTab = item("New Tab") { browser.launch() }.symbol(MenuSymbol.newTab)
        if let key = ShortcutStore.shared.key(for: "file.newTab")?.menuKey {
            newTab.keyEquivalent = key.key
            newTab.keyEquivalentModifierMask = key.mask
        }
        menu.addItem(newTab)
        menu.addItem(item("New Folder") { browser.newFolder() }.symbol(MenuSymbol.newFolder))
        menu.addItem(item("New Folder from Search…") { browser.askForFolderFromSearch() }.symbol(MenuSymbol.folderFromSearch))
        if browser.prefs.liveFolders {
            let live = NSMenuItem(title: "New Live Folder", action: nil, keyEquivalent: "")
            live.submenu = LiveMenu.menu(for: browser)
            menu.addItem(live.symbol(MenuSymbol.liveFolder))
        }
        menu.addItem(item("New Space…") { browser.askForSpace() }.symbol(MenuSymbol.newSpace))
        return menu
    }
}

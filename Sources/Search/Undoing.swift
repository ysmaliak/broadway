import AppKit

@MainActor
final class UndoStep {}

@MainActor
final class UndoScope {
    var name: String?
    let before: Browser.Arrangement
    let gesture: Bool
    var carried: (tabs: [Tab.ID], space: UUID)?
    var depth = 0

    init(name: String?, before: Browser.Arrangement, gesture: Bool) {
        self.name = name
        self.before = before
        self.gesture = gesture
    }
}

@MainActor
struct UndoMark {
    let scope: UndoScope
    let outer: Bool
    let name: String
    let before: Browser.Arrangement?
}

extension Browser {
    static let undoLength = 30

    struct Placing: Equatable {
        var pin: String?
        var home: URL?
        var pinID: UUID?
        var everywhere: Bool
        var groupID: UUID?
        var name: String?

        @MainActor init(_ tab: Tab) {
            pin = tab.pin
            home = tab.home
            pinID = tab.pinID
            everywhere = tab.everywhere
            groupID = tab.groupID
            name = tab.name
        }
    }

    struct Arrangement {
        var space: UUID
        var order: [Tab.ID]
        var placings: [Tab.ID: Placing]
        var groups: [TabGroup]
        var splits: [TabSplit]
        var active: Tab.ID?

        func differs(from other: Arrangement) -> Bool {
            order != other.order || placings != other.placings || groups != other.groups || splits != other.splits
        }
    }

    var arrangement: Arrangement {
        Arrangement(space: spaceID, order: tabs.map(\.id),
                    placings: Dictionary(tabs.map { ($0.id, Placing($0)) }, uniquingKeysWith: { first, _ in first }),
                    groups: tabGroups, splits: splits, active: activeID)
    }

    private var takesUndo: Bool {
        undoQuiet == 0 && !closingNow && window?.undoManager != nil
    }

    func quietly<T>(_ body: () -> T) -> T {
        undoQuiet += 1
        defer { undoQuiet -= 1 }
        return body()
    }

    func offerStep(_ name: String, _ run: @escaping @MainActor (Browser) -> Void) {
        guard let undo = window?.undoManager, !undo.isUndoing else { return }
        if !undo.canUndo { undoSteps.removeAll() }
        let step = UndoStep()
        undo.registerUndo(withTarget: step) { [weak self] step in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.undoSteps.removeAll { $0 === step }
                self.quietly { run(self) }
            }
        }
        undo.setActionName(name)
        undoSteps.append(step)
        while undoSteps.count > Browser.undoLength {
            undo.removeAllActions(withTarget: undoSteps.removeFirst())
        }
    }

    func beginStep(_ name: String, carrying moving: [Tab.ID] = [], to space: UUID? = nil) -> UndoMark? {
        guard takesUndo else { return nil }
        if let scope = undoScope {
            if !moving.isEmpty, let space, scope.carried.map({ $0.space == space }) ?? true {
                scope.carried = ((scope.carried?.tabs ?? []) + moving, space)
            }
            scope.depth += 1
            let watched = scope.gesture && scope.depth == 1
            return UndoMark(scope: scope, outer: false, name: name, before: watched ? arrangement : nil)
        }
        let scope = UndoScope(name: name, before: arrangement, gesture: false)
        if !moving.isEmpty, let space { scope.carried = (moving, space) }
        scope.depth = 1
        undoScope = scope
        return UndoMark(scope: scope, outer: true, name: name, before: nil)
    }

    func endStep(_ mark: UndoMark?) {
        guard let mark else { return }
        mark.scope.depth -= 1
        if let before = mark.before, arrangement.differs(from: before) { mark.scope.name = mark.name }
        guard mark.outer else { return }
        if undoScope === mark.scope { undoScope = nil }
        offer(mark.scope)
    }

    func beginGesture() {
        if let open = undoScope, open.gesture { endGesture() }
        guard takesUndo, undoScope == nil else { return }
        undoScope = UndoScope(name: nil, before: arrangement, gesture: true)
    }

    func endGesture() {
        guard let scope = undoScope, scope.gesture else { return }
        undoScope = nil
        offer(scope)
    }

    private func offer(_ scope: UndoScope) {
        guard let name = scope.name else { return }
        let after = arrangement
        guard after.differs(from: scope.before) else { return }
        let before = scope.before
        let carried = scope.carried
        offerStep(name) { browser in
            browser.putBack(before, after: after, carried: carried)
        }
    }

    func noteCameBack(_ was: Tab.ID?, as tab: Tab) {
        guard let was else { return }
        cameBackAs[was] = tab.id
    }

    func resolved(_ id: Tab.ID) -> Tab.ID {
        var id = id
        var seen = Set<Tab.ID>()
        while let next = cameBackAs[id], seen.insert(id).inserted { id = next }
        return id
    }

    private func putBack(_ before: Arrangement, after: Arrangement, carried: (tabs: [Tab.ID], space: UUID)?) {
        guard spaces.contains(where: { $0.id == before.space }) || before.space == spaceID else { return }
        if spaceID != before.space {
            guard showsSpaces else { return }
            enter(before.space)
            guard spaceID == before.space else { return }
        }
        if let carried {
            let fetched = carried.tabs.filter { fetch($0, from: carried.space) }
            guard !fetched.isEmpty else { return }
        }
        restore(before, after: after)
        guard carried != nil else { return }
        let made = Set(after.order).subtracting(before.order)
        for tab in tabs where made.contains(tab.id) && tab.isBlank && tab.id != activeID { close(tab) }
    }

    private func fetch(_ id: Tab.ID, from space: UUID) -> Bool {
        let id = resolved(id)
        guard var row = parked[space], let index = row.tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = row.tabs.remove(at: index)
        row.splits = row.splits.filter { Browser.holds($0, in: row.tabs) }
        if row.active == tab.id { row.active = row.tabs.first { $0.pin == nil }?.id ?? row.tabs.first?.id }
        if tab.pin != nil, !tab.everywhere, let pin = tab.pinID {
            Pins.set(space, Pins.defs(space).filter { $0.id != pin }, from: self)
        }
        parked[space] = row
        writeSession(now: true, space: space, row: row)
        tab.rehome(in: spaceID)
        setRow(tabs + [tab])
        return true
    }

    private func restore(_ before: Arrangement, after: Arrangement) {
        restoreGroups(before.groups, after: after.groups)
        let present = Dictionary(tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (old, was) in before.placings {
            guard let tab = present[resolved(old)] else { continue }
            restorePlacing(tab, was: was, after: after.placings[old])
        }
        let stayed = Set(Browser.unmoved(before.order, after.order).map(resolved))
        let order = Browser.ordered(tabs, id: \.id, like: before.order.map(resolved), anchors: stayed)
        if !order.elementsEqual(tabs, by: { $0.id == $1.id }) { setRow(order) }
        for pair in before.splits where !splits.contains(where: { Set($0.tabs) == Set(pair.tabs) }) {
            let members = pair.tabs.map(resolved)
            guard members == pair.tabs, members.allSatisfy({ id in present[id].map { split(for: $0) == nil } ?? false }) else { continue }
            putBackSplit(pair)
        }
        arrangeGroupedTabs()
        if before.active != after.active, let want = before.active.map(resolved),
           activeID == after.active.map(resolved), want != activeID, let tab = present[want] {
            select(tab, floatPrevious: false)
        }
        for old in before.groups where old.live {
            guard let was = after.groups.first(where: { $0.id == old.id }), was.name != old.name else { continue }
            LiveFolders.shared.rename(old.id, to: old.name)
        }
        revision &+= 1
        writeSession(now: true)
    }

    private func restoreGroups(_ before: [TabGroup], after: [TabGroup]) {
        let beforeIDs = Set(before.map(\.id))
        let afterIDs = Set(after.map(\.id))
        var groups = tabGroups
        for made in after where !beforeIDs.contains(made.id) {
            guard let current = groups.first(where: { $0.id == made.id }) else { continue }
            for index in groups.indices where groups[index].parent == made.id { groups[index].parent = current.parent }
            for tab in tabs where tab.groupID == made.id { tab.groupID = current.parent }
            groups.removeAll { $0.id == made.id }
            if editingGroupID == made.id { editingGroupID = nil }
        }
        for old in before {
            guard afterIDs.contains(old.id) else {
                if !groups.contains(where: { $0.id == old.id }) { groups.append(old) }
                continue
            }
            guard let was = after.first(where: { $0.id == old.id }), was != old,
                  let at = groups.firstIndex(where: { $0.id == old.id }) else { continue }
            groups[at] = Browser.merged(groups[at], before: old, after: was)
        }
        let order = Browser.ordered(groups, id: \.id, like: before.map(\.id),
                                    anchors: Set(Browser.unmoved(before.map(\.id), after.map(\.id))))
        if order != tabGroups { tabGroups = order }
    }

    private static func merged(_ now: TabGroup, before: TabGroup, after: TabGroup) -> TabGroup {
        var now = now
        func take<V: Equatable>(_ path: WritableKeyPath<TabGroup, V>) {
            if before[keyPath: path] != after[keyPath: path] { now[keyPath: path] = before[keyPath: path] }
        }
        take(\.name)
        take(\.userNamed)
        take(\.madeName)
        take(\.parent)
        take(\.pinned)
        take(\.leads)
        take(\.collapsed)
        take(\.held)
        take(\.icon)
        take(\.userIcon)
        take(\.userFilled)
        return now
    }

    private func restorePlacing(_ tab: Tab, was: Placing, after: Placing?) {
        func changed<V: Equatable>(_ path: KeyPath<Placing, V>) -> Bool {
            after.map { $0[keyPath: path] != was[keyPath: path] } ?? true
        }
        if changed(\.pin), was.pin == nil, tab.pin != nil {
            unpin(tab)
        } else if changed(\.pin), let letter = was.pin, tab.pin == nil {
            detachSplit(tab)
            tab.groupID = nil
            tab.pin = letter
            tab.home = was.home
            tab.pinID = was.pinID
            tab.everywhere = was.everywhere
        } else if tab.pin != nil {
            if changed(\.pin), tab.pin != was.pin { tab.pin = was.pin }
            if changed(\.home), tab.home != was.home { tab.home = was.home }
            if changed(\.pinID), tab.pinID != was.pinID { tab.pinID = was.pinID }
            if changed(\.everywhere), tab.everywhere != was.everywhere { tab.everywhere = was.everywhere }
        }
        if changed(\.groupID), tab.groupID != was.groupID, was.pin == nil {
            let live = was.groupID.flatMap { id in tabGroups.first { $0.id == id } }?.live == true
            if !live || tab.liveKey != nil { tab.groupID = was.groupID }
        }
        if changed(\.name), tab.name != was.name { tab.name = was.name }
    }

    static func ordered<Item>(_ items: [Item], id: (Item) -> UUID, like order: [UUID], anchors: Set<UUID>) -> [Item] {
        let byID = Dictionary(items.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
        var out: [Item] = []
        var placed = Set<UUID>()
        for each in order {
            guard let item = byID[each], placed.insert(each).inserted else { continue }
            out.append(item)
        }
        let old = placed
        var anchors = anchors
        for (index, item) in items.enumerated().reversed() where !old.contains(id(item)) {
            let next = items[(index + 1)...].first { anchors.contains(id($0)) && placed.contains(id($0)) }.map(id)
            let at = next.flatMap { next in out.firstIndex { id($0) == next } } ?? out.count
            out.insert(item, at: at)
            placed.insert(id(item))
            anchors.insert(id(item))
        }
        return out
    }

    static func unmoved(_ before: [UUID], _ after: [UUID]) -> [UUID] {
        guard !before.isEmpty, !after.isEmpty else { return [] }
        var lengths = Array(repeating: Array(repeating: 0, count: after.count + 1), count: before.count + 1)
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[i][j] = before[i] == after[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var out: [UUID] = []
        var i = 0, j = 0
        while i < before.count, j < after.count {
            if before[i] == after[j] {
                out.append(before[i])
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return out
    }
}

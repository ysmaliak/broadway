import Foundation

enum TabReturn {
    case untilLeft
    case front
    case behind
}

@MainActor
extension Browser {
    func noteReturn(_ tab: Tab, front: Bool, from source: Tab?, once: Bool = false) {
        let owner = front ? (active ?? source) : source
        guard let owner, owner.id != tab.id, !owner.agent, !owner.bench, !tab.agent, !tab.bench else {
            tab.returnTo = nil
            return
        }
        tab.returnTo = owner.id
        tab.returnWay = once ? .untilLeft : front ? .front : .behind
    }

    func carryReturn(from old: Tab, to fresh: Tab) {
        fresh.returnTo = old.returnTo
        fresh.returnWay = old.returnWay
        for tab in tabs where tab.returnTo == old.id { tab.returnTo = fresh.id }
    }

    func keepReturns(leaving old: Tab.ID?) {
        guard let old, old != activeID, let leaving = tabs.first(where: { $0.id == old }) else { return }
        let arriving = activeID.flatMap { id in tabs.first { $0.id == id } }
        let related = arriving.map { here in
            here.returnTo == leaving.id || leaving.returnTo == here.id
                || (here.returnTo != nil && here.returnTo == leaving.returnTo && here.returnWay == .behind && leaving.returnWay == .behind)
        } ?? false
        if leaving.returnWay == .untilLeft { leaving.returnTo = nil }
        guard !related else { return }
        for tab in tabs { tab.returnTo = nil }
    }

    func successor(of tab: Tab, without gone: Set<Tab.ID> = []) -> Tab? {
        let gone = gone.union([tab.id])
        let lands: (Tab) -> Bool = { !gone.contains($0.id) && !$0.agent && !$0.bench }
        if let pair = split(for: tab), let partner = tabs.first(where: { $0.id == pair.partner(of: tab.id) }), lands(partner) {
            return partner
        }
        if tab.agent {
            return lastLooked(besides: tab, without: gone) ?? tabs.first(where: lands)
        }
        let order = landingOrder(around: tab)
        if let back = returning(from: tab, in: order, lands: lands) { return back }
        if tab.page != nil, let back = tabBefore(tab), lands(back) { return back }
        guard let (row, at) = order else { return tabs.first(where: lands) }
        if let folder = group(of: tab), let same = nearest(in: row, at: at, where: { lands($0) && self.group(of: $0) == folder }) {
            return same
        }
        return nearest(in: row, at: at, where: lands) ?? tabs.first(where: lands)
    }

    func landing(after tab: Tab, at index: Int, partner: Tab?) -> Tab? {
        partner ?? successor(of: tab) ?? (tabs.count > 1 ? tabs[index == tabs.count - 1 ? index - 1 : index + 1] : nil)
    }

    func lastLooked(besides tab: Tab, without gone: Set<Tab.ID> = [], bench: Bool = false, loose: Bool = false) -> Tab? {
        let others = tabs.filter { $0.id != tab.id && !gone.contains($0.id) && !$0.asleep && !$0.agent && (bench || !$0.bench) }
        let pool = loose && others.contains(where: { $0.pin == nil }) ? others.filter { $0.pin == nil } : others
        return pool.max { $0.touched < $1.touched }
    }

    func returning(from tab: Tab, without gone: Set<Tab.ID> = []) -> Tab? {
        let gone = gone.union([tab.id])
        return returning(from: tab, in: landingOrder(around: tab)) { !gone.contains($0.id) && !$0.agent && !$0.bench }
    }

    private func returning(from tab: Tab, in order: (row: [Tab], at: Int)?, lands: (Tab) -> Bool) -> Tab? {
        guard let owner = tab.returnTo, let home = tabs.first(where: { $0.id == owner }) else { return nil }
        if tab.returnWay == .behind, let (row, at) = order,
           let sibling = nearest(in: row, at: at, where: { lands($0) && $0.returnTo == owner && $0.returnWay == .behind }) {
            return sibling
        }
        return lands(home) ? home : nil
    }

    private func landingOrder(around tab: Tab) -> (row: [Tab], at: Int)? {
        let anchor = split(for: tab)?.left ?? tab.id
        let shown = shownTabs
        if let at = shown.firstIndex(where: { $0.id == anchor }) { return (shown, at) }
        if let at = tabs.firstIndex(where: { $0.id == tab.id }) { return (tabs, at) }
        return nil
    }

    private func nearest(in row: [Tab], at: Int, where fits: (Tab) -> Bool) -> Tab? {
        if at + 1 < row.count, let below = row[(at + 1)...].first(where: fits) { return below }
        return row[..<min(at, row.count)].last(where: fits)
    }
}

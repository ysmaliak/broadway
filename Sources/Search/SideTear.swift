import AppKit

extension SidePageView {
    @discardableResult
    func tearAim(_ tab: Tab?, at point: NSPoint?) -> ListDrop? {
        guard let tab, let point, bounds.contains(point), preview == nil else {
            clearListDrop()
            return nil
        }
        let grouped = browser.prefs.usesTabGroups
        let place = ListDrop.resolve(point, items: itemsNow, below: raisedNow.map(\.maxY).max() ?? -.greatestFiniteMagnitude,
                                     frames: grouped ? dropFrames() : [:], groups: grouped ? browser.tabGroups.filter { !$0.live } : [],
                                     excluding: tab.id, band: 0)
        var target: GroupDropTarget?
        var loose: LoosePlace?
        switch place {
        case .folder(let inside)?: target = browser.liveDrop(inside, carrying: tab)
        case .loose(let out)?: loose = out
        case nil: break
        }
        if dropOn != target { dropOn = target }
        if looseOn != loose { looseOn = loose }
        return target.map(ListDrop.folder) ?? loose.map(ListDrop.loose)
    }
}

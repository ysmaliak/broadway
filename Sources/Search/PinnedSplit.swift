import AppKit
import Foundation

enum PinnedSplits {
    static func whole(_ pair: TabSplit, pinned: (Tab.ID) -> Bool) -> Bool {
        pair.tabs.count >= 2 && pair.tabs.allSatisfy(pinned)
    }

    static func mixed(_ pair: TabSplit, pinned: (Tab.ID) -> Bool) -> Bool {
        pair.tabs.contains(where: pinned) && !pair.tabs.allSatisfy(pinned)
    }

    static func leaving(_ pair: TabSplit, page: Tab.ID, pinned: (Tab.ID) -> Bool) -> (unpin: Tab.ID?, keepsPin: [Tab.ID]) {
        guard whole(pair, pinned: pinned), pair.contains(page) else { return (nil, []) }
        return (page, pair.tabs.filter { $0 != page })
    }
}

@MainActor
extension Browser {
    static func wholePinned(_ pair: TabSplit, in row: [Tab]) -> Bool {
        PinnedSplits.whole(pair) { id in row.contains { $0.id == id && $0.pin != nil && !$0.shy } }
    }

    func pinnedSplit(of tab: Tab) -> TabSplit? {
        guard tab.pin != nil, let pair = splits.first(where: { $0.contains(tab.id) }) else { return nil }
        return Browser.wholePinned(pair, in: tabs) ? pair : nil
    }

    func shownPinnedSplit(of tab: Tab) -> TabSplit? {
        guard prefs.splitView else { return nil }
        return pinnedSplit(of: tab)
    }

    func pinSplitDef(for tab: Tab) -> PinSplit? {
        guard let pair = pinnedSplit(of: tab), let at = pair.tabs.firstIndex(of: tab.id) else { return nil }
        return PinSplit(id: pair.id, axis: pair.axis, size: pair.sizes.indices.contains(at) ? pair.sizes[at] : 0.5)
    }

    func canPinSplit(_ pair: TabSplit) -> Bool {
        guard prefs.splitView, !isPrivate else { return false }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        guard members.count == pair.tabs.count, members.count >= 2 else { return false }
        guard !members.allSatisfy({ $0.pin != nil }) else { return false }
        return members.allSatisfy { $0.pin == nil && !$0.shy && !$0.bench && !$0.agent && $0.page == nil && $0.isWeb }
    }

    func pinSplit(_ pair: TabSplit) {
        guard canPinSplit(pair) else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        let focused = activeID
        for tab in members { pin(tab) }
        guard members.allSatisfy({ $0.pin != nil }) else { return }
        replaceSplits(splits.filter { !($0.id == pair.id || $0.tabs.contains(where: pair.contains)) })
        lineUpPins(pair.tabs)
        replaceSplits(splits + [pair])
        if let focused, pair.contains(focused) { activeID = focused }
        revision &+= 1
        writeSession(now: true)
    }

    func unpinSplit(_ pair: TabSplit) {
        guard Browser.wholePinned(pair, in: tabs) else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        let focused = activeID
        replaceSplits(splits.filter { $0.id != pair.id })
        for tab in members.reversed() { unpin(tab) }
        replaceSplits(splits + [pair])
        if let focused, pair.contains(focused) { activeID = focused }
        revision &+= 1
        writeSession(now: true)
    }

    func togglePinFront() {
        guard let tab = active else { return }
        if let pair = pinnedSplit(of: tab), prefs.splitView { return unpinSplit(pair) }
        if let pair = activeSplit {
            if canPinSplit(pair) { pinSplit(pair) }
            return
        }
        if tab.pin == nil { pin(tab) } else { unpin(tab) }
    }

    func leftSplit(_ pair: TabSplit, page: Tab) {
        let pinned: (Tab.ID) -> Bool = { id in self.tabs.contains { $0.id == id && $0.pin != nil } }
        guard let id = PinnedSplits.leaving(pair, page: page.id, pinned: pinned).unpin,
              let tab = tabs.first(where: { $0.id == id }) else { return }
        unpin(tab)
    }

    func unpinningLeaves(_ tab: Tab) {
        guard let pair = pinnedSplit(of: tab) else { return }
        replaceSplits(splits.filter { $0.id != pair.id })
    }

    func putsDownPinnedSplit(_ tab: Tab) -> Bool {
        guard let pair = pinnedSplit(of: tab) else { return false }
        let members = prefs.splitView ? pair.tabs.compactMap { id in tabs.first { $0.id == id } } : [tab]
        for page in members {
            heldDialogs.removeValue(forKey: page.id)?.forEach { $0.dismiss() }
            dropQuestions(for: page.id)
            if floating == page.id { land(covering: false) }
            page.rest(at: prefs.pinsGoHome || prefs.pinsPeek ? page.home : nil)
        }
        if members.contains(where: { $0.id == activeID }) {
            let gone = Set(members.map(\.id))
            let others = tabs.filter { !gone.contains($0.id) && !$0.asleep && !$0.agent && !$0.bench }
            let loose = others.filter { $0.pin == nil }
            if let back = returning(from: tab, without: gone) {
                select(back)
            } else if let back = (loose.isEmpty ? others : loose).max(by: { $0.touched < $1.touched }) {
                select(back)
            } else {
                newTab()
            }
        }
        writeSession(now: true)
        return true
    }

    func shareSplit(_ pair: TabSplit, everywhere: Bool) {
        guard Browser.wholePinned(pair, in: tabs) else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        replaceSplits(splits.filter { $0.id != pair.id })
        if everywhere {
            for tab in members where !tab.everywhere { shareEverywhere(tab) }
        } else {
            for tab in members.reversed() where tab.everywhere { keepHere(tab) }
        }
        if Browser.wholePinned(pair, in: tabs) {
            lineUpPins(pair.tabs)
            replaceSplits(splits + [pair])
        }
        revision &+= 1
        writeSession(now: true)
    }

    func lineUpPins(_ ids: [Tab.ID]) {
        let members = ids.compactMap { id in tabs.first { $0.id == id } }
        guard members.count == ids.count, let first = tabs.firstIndex(where: { ids.contains($0.id) }) else { return }
        var row = tabs.filter { !ids.contains($0.id) }
        row.insert(contentsOf: members, at: min(first, row.count))
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { replaceRow(row) }
    }

    func pinSplits(_ row: [Tab], keeping old: [TabSplit], space: UUID) -> [TabSplit] {
        let showing = prefs.showsSharedPins
        let defs = Pins.row(own: Pins.defs(space), shared: showing ? Pins.shared() : [], showing: showing)
        let pinned: (Tab.ID) -> Bool = { id in row.contains { $0.id == id && $0.pin != nil } }
        var out = old.filter { !$0.tabs.contains(where: pinned) }
        for group in PinSplit.groups(defs) {
            let members = group.ids.compactMap { id in row.first { $0.pinID == id && $0.pin != nil } }
            guard members.count == group.ids.count, members.count >= 2 else { continue }
            let ids = members.map(\.id)
            let before = old.first { $0.id == group.split.id }
            out.removeAll { $0.tabs.contains(where: ids.contains) }
            out.append(TabSplit(id: group.split.id, tabs: ids, axis: group.split.axis, sizes: group.sizes,
                                focused: before?.focused.flatMap { ids.contains($0) ? $0 : nil }))
        }
        return out
    }
}

@MainActor
extension Browser {
    func pinPartner(of tab: Tab) -> (tab: Tab, axis: TabSplit.Axis)? {
        guard let pair = shownPinnedSplit(of: tab), pair.left == tab.id,
              let other = tabs.first(where: { $0.id == pair.tabs[1] }) else { return nil }
        return (other, pair.axis)
    }
}

@MainActor
extension Browser {
    func pinTarget(_ tab: Tab) -> Tab {
        guard let pair = shownPinnedSplit(of: tab) else { return tab }
        let wanted = pair.contains(activeID ?? UUID()) ? activeID : pair.focused
        return wanted.flatMap { id in tabs.first { $0.id == id } } ?? tab
    }
}


@MainActor
extension Browser {
    static func picture(of view: NSView?, to path: String) -> Bool {
        guard let view, let layer = view.layer else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = view.window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.scaleBy(x: scale, y: scale)
        if view.isFlipped == false, layer.isGeometryFlipped == false {
            context.translateBy(x: 0, y: view.bounds.height)
            context.scaleBy(x: 1, y: -1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        view.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

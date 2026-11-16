import AppKit

extension Browser {
    var pickableTabs: [Tab] {
        selectableTabs.filter { $0.pin == nil && !$0.bench }
    }

    var keyTabs: [Tab] {
        let picked = pickedTabs
        if !picked.isEmpty { return picked }
        return active.map { [$0] } ?? []
    }

    func menuTabs(for tab: Tab) -> [Tab] {
        guard selectedTabIDs.contains(tab.id) else { return [tab] }
        let picked = pickedTabs
        return picked.count > 1 ? picked : [tab]
    }

    func links(of chosen: [Tab]) -> [LinkCopy.Link] {
        chosen.compactMap { tab in tab.address.map { LinkCopy.Link(tab.label, $0) } }
    }

    func copyLinks(_ style: LinkCopy.Style, of chosen: [Tab]? = nil) {
        let found = links(of: chosen ?? keyTabs)
        guard LinkCopy.copy(found, as: style, to: LinkCopy.board) else { return }
        announce(LinkCopy.announcement(found.count, as: style))
    }

    func copyPage(_ style: LinkCopy.Style) {
        copyLinks(style, of: active.map { [$0] } ?? [])
    }

    func copyFolderLinks(_ id: UUID, as style: LinkCopy.Style) {
        copyLinks(style, of: folderTabs(id))
    }

    func movable(toSpace tab: Tab) -> Bool {
        tabs.contains { $0.id == tab.id } && !tab.bench && !tab.everywhere
            && tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil
    }

    func sendToSpace(index: Int) {
        guard showsSpaces, spaces.indices.contains(index) else { return }
        let space = spaces[index]
        guard space.id != spaceID else { return announce("Already in \(space.name)") }
        move(keyTabs, toSpace: space.id)
    }

    func move(_ chosen: [Tab], toSpace target: UUID, then: (() -> Void)? = nil) {
        guard showsSpaces, target != spaceID,
              let destination = spaces.first(where: { $0.id == target }) else { return }
        let movers = chosen.filter(movable(toSpace:))
        guard !movers.isEmpty else { return }
        if movers.count == 1 { return move(movers[0], toSpace: target, then: then) }
        let from = spaceID
        let complete: () -> Void = { [weak self] in
            guard let self, self.spaceID == from else { return }
            let still = movers.filter { tab in self.tabs.contains { $0.id == tab.id } }
            self.finishMoves(still, to: destination)
            then?()
        }
        let store = Spaces.store(for: target)
        let asking = movers.filter { !$0.shy && $0.store !== store }
        guard !asking.isEmpty else { return complete() }
        var unsaved = false
        let asked = DispatchGroup()
        for tab in asking {
            asked.enter()
            tab.unsaved { if $0 { unsaved = true }; asked.leave() }
        }
        asked.notify(queue: .main) {
            guard unsaved else { return complete() }
            Ask.sure(
                "Move \(movers.count) tabs?",
                detail: "A page among them has unsaved form entries. They will reopen in “\(destination.name)” with that space's accounts, so the entries may be lost.",
                confirm: "Move",
                then: complete
            )
        }
    }

    private func finishMoves(_ movers: [Tab], to destination: Space) {
        guard !movers.isEmpty else { return }
        let mark = beginStep("Move to Space", carrying: movers.map(\.id), to: destination.id)
        defer { endStep(mark) }
        clearTabSelection()
        let ids = Set(movers.map(\.id))
        if let activeID, ids.contains(activeID) {
            let at = tabs.firstIndex { $0.id == activeID } ?? 0
            let after = tabs[at...].first { !ids.contains($0.id) && standsInRow($0) }
            let before = tabs[..<at].last { !ids.contains($0.id) && standsInRow($0) }
            if let next = after ?? before { select(next, floatPrevious: false) }
        }
        var moved = 0
        var arrived: Tab?
        holdingLoneFolders {
            for tab in movers where finishMove(tab, toSpace: destination.id, quietly: true) {
                moved += 1
                if arrived == nil, LinkArrivals.arrived[tab.id] != nil { arrived = tab }
            }
        }
        guard moved > 0 else { return }
        writeSession(now: true)
        if let row = parked[destination.id] { writeSession(now: true, space: destination.id, row: row) }
        announce(moved == 1 ? "Moved to \(destination.name)" : "Moved \(moved) tabs to \(destination.name)")
        if let arrived { LinkArrivals.moved(arrived, to: destination.id, in: self) }
    }

    func togglePin(_ chosen: [Tab], like tab: Tab) {
        let mark = beginStep(chosen.count > 1 ? (tab.pin == nil ? "Pin \(chosen.count) Tabs" : "Unpin \(chosen.count) Tabs") : (tab.pin == nil ? "Pin Tab" : "Unpin Tab"))
        defer { endStep(mark) }
        if tab.pin == nil {
            for each in chosen where each.pin == nil && each.isWeb && !each.shy { pin(each) }
        } else {
            for each in chosen.reversed() where each.pin != nil { unpin(each) }
        }
    }

    func duplicate(_ chosen: [Tab]) {
        let pages = chosen.filter(\.isWeb)
        if pages.count == 1, let only = pages.first {
            if only.id != activeID { select(only) }
            return duplicate()
        }
        for tab in pages {
            if let url = tab.address { open(url, foreground: false, from: tab) }
        }
        if pages.count > 1 { announce("\(pages.count) tabs duplicated") }
    }

    func move(_ chosen: [Tab], toGroup id: UUID?) {
        let mark = beginStep(id == nil ? "Remove from Folder" : "Move to Folder")
        defer { endStep(mark) }
        for tab in chosen { move(tab, toGroup: id) }
    }

    func moveTab(by step: Int) {
        guard let tab = active, tabs.contains(where: { $0.id == tab.id }), !tab.bench else { return }
        let lead = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.left } } ?? tab
        let shown = displayedTabs
        let peers: [Tab]
        if lead.pin != nil {
            peers = shown.filter { $0.pin != nil && $0.everywhere == lead.everywhere }
        } else if prefs.usesTabGroups {
            let folder = group(of: lead)
            peers = shown.filter { $0.pin == nil && group(of: $0) == folder }
        } else {
            peers = shown.filter { $0.pin == nil }
        }
        guard let from = peers.firstIndex(where: { $0.id == lead.id }) else { return }
        let to = from + step
        guard peers.indices.contains(to),
              let index = shown.firstIndex(where: { $0.id == peers[to].id }) else { return }
        moveDisplayedTab(lead, to: index)
        if lead.pin != nil { writeSession(now: true) }
    }
}

import AppKit
import Foundation

struct PersonTab {
    var tab: Tab
    var browser: Browser
    var space: UUID
    var onScreen: Bool
}

@MainActor
enum PersonTabs {
    static func everyTab(_ call: PersonCall, load: Bool = false) -> [PersonTab] {
        call.box.browsers.flatMap { browser -> [PersonTab] in
            if load, browser.prefs.usesSpaces { browser.preloadSpaces() }
            let shown = browser.tabs.filter(BrowserToolbox.listed).map { PersonTab(tab: $0, browser: browser, space: browser.spaceID, onScreen: true) }
            let parked = browser.parked.flatMap { space, row in
                row.tabs.filter(BrowserToolbox.listed).map { PersonTab(tab: $0, browser: browser, space: space, onScreen: false) }
            }
            return shown + parked
        }
    }

    static func find(_ call: PersonCall, _ named: String, allowInternal: Bool = false) throws -> PersonTab {
        let wanted = named.lowercased()
        let found = wanted.isEmpty ? [] : everyTab(call, load: true).filter { $0.tab.id.uuidString.lowercased().hasPrefix(wanted) }
        if found.count > 1 { throw PersonRefusal("ambiguous_tab", "\(named) matches \(found.count) tabs: give more of its id") }
        guard let only = found.first else { throw PersonRefusal("no_tab", "No such tab: \(named)") }
        if only.tab.page != nil, !allowInternal { throw PersonRefusal("person_only", "Broadway internal pages are person-only. Agents can list their addresses but cannot read or act on them.") }
        if only.tab.driving { throw PersonRefusal("driving", "The person is driving that tab. Nothing was done.") }
        return only
    }

    static func onScreen(_ call: PersonCall, _ named: String) throws -> PersonTab {
        let found = try find(call, named)
        guard found.onScreen else {
            let name = found.browser.spaces.first { $0.id == found.space }?.name ?? "another space"
            throw PersonRefusal("refused", "That tab is in \(name). Switch there first: broadway spaces switch \(name).")
        }
        return found
    }

    static func space(_ call: PersonCall, _ named: String) throws -> Space {
        let lower = named.lowercased()
        let spaces = call.browser.spaces
        if let exact = spaces.first(where: { $0.name.lowercased() == lower }) { return exact }
        let found = spaces.filter { $0.id.uuidString.lowercased().hasPrefix(lower) || $0.name.lowercased().hasPrefix(lower) }
        if found.count > 1 { throw PersonRefusal.ambiguous("name", named, found.count) }
        guard let only = found.first else {
            throw PersonRefusal.missing("space", named)
        }
        return only
    }

    static func spacesOn(_ call: PersonCall) throws {
        guard call.browser.prefs.usesSpaces else {
            throw PersonRefusal("refused", "Spaces are off", hint: "Turn them on with broadway settings set spaces true")
        }
    }

    static func spaceName(_ found: PersonTab) -> String {
        found.browser.spaces.first { $0.id == found.space }?.name ?? ""
    }

    static func row(_ found: PersonTab, call: PersonCall) -> [String: Any] {
        var row = call.box.describe(found.tab, found.browser)
        row["space"] = spaceName(found)
        row["pinned"] = found.tab.pin != nil
        row["asleep"] = found.tab.asleep
        return row
    }

    static func webAddress(_ text: String) throws -> URL {
        guard let url = Address.url(from: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw PersonRefusal("refused", "That isn't a web address")
        }
        return url
    }

    private static func moved(_ tab: Tab, in browser: Browser, to space: Space) async throws {
        if tab.store !== Spaces.store(for: space.id), !tab.shy {
            let typed: Bool = await withCheckedContinuation { done in tab.unsaved { done.resume(returning: $0) } }
            if typed { throw PersonRefusal("refused", "This page has unsaved form entries, and they could be lost. Move it in Broadway.") }
        }
        guard browser.moveToSpace(tab, id: space.id) else {
            throw PersonRefusal("refused", "That tab can't go to \(space.name)")
        }
    }

    private static func shut(_ found: PersonTab) {
        if found.onScreen { found.browser.close(found.tab) } else { found.browser.closeParkedAgentTab(found.tab) }
    }

    private static func slept(_ found: PersonTab) async -> String {
        await withCheckedContinuation { done in found.browser.sleep(found.tab) { done.resume(returning: $0) } }
    }

    static let verbs: [PersonVerb] = [
        PersonVerb("spaces", "list", .look) { call in
            let browser = call.browser
            if browser.prefs.usesSpaces { browser.preloadSpaces() }
            let every = everyTab(call)
            return ["on": browser.prefs.usesSpaces, "spaces": browser.spaces.map { space in
                ["id": PersonCommands.short(space.id), "name": space.name, "tabs": every.filter { $0.space == space.id && $0.browser === browser && !$0.tab.agent }.count,
                 "current": space.id == browser.spaceID, "accounts": space.accounts.rawValue, "icon": space.shownIcon.saved] as [String: Any]
            }]
        },
        PersonVerb("spaces", "switch", .arrange) { call in
            try spacesOn(call)
            let space = try space(call, try call.need("space"))
            call.browser.switchSpace(to: space.id)
            return ["space": space.name, "message": "Now in \(space.name)"]
        },
        PersonVerb("space", "show", .arrange, softer: { $0.string("space") == nil ? .look : nil }) { call in
            guard let named = call.string("space") else {
                return ["space": call.browser.space.name, "id": PersonCommands.short(call.browser.space.id)]
            }
            try spacesOn(call)
            let space = try space(call, named)
            call.browser.switchSpace(to: space.id)
            return ["space": space.name, "message": "Now in \(space.name)"]
        },
        PersonVerb("spaces", "new", .arrange) { call in
            try spacesOn(call)
            let browser = call.browser
            let name = try call.need("name")
            if browser.spaces.contains(where: { $0.name.lowercased() == name.lowercased() }) { throw PersonRefusal("refused", "There's already a space named \(name)") }
            var icon: TabIcon?
            if let wanted = call.string("icon") {
                guard let known = Spaces.icons.contains(wanted) ? TabIcon(symbol: wanted) : IconChoices.typed(wanted) else {
                    throw PersonRefusal.usage("That isn't an icon a space can wear", hint: "Icons: \(Spaces.icons.joined(separator: ", ")), or one emoji")
                }
                icon = known
            }
            var made: Space?
            browser.afterSpaceCreated = { made = $0 }
            browser.addSpace(named: name, icon: icon, sharesSignIns: !call.flag("fresh"))
            guard let made else { throw PersonRefusal("failed", "No space was made") }
            if call.flag("switch") { browser.switchSpace(to: made.id) }
            return ["id": PersonCommands.short(made.id), "space": made.name]
        },
        PersonVerb("spaces", "rename", .arrange) { call in
            let found = try space(call, try call.need("space"))
            let name = try call.need("name")
            call.browser.renameSpace(found.id, to: name)
            return ["space": name, "message": "Renamed"]
        },
        PersonVerb("spaces", "move", .arrange) { call in
            let found = try space(call, try call.need("space"))
            guard let position = Int(try call.need("position")), call.browser.spaces.indices.contains(position - 1) else {
                throw PersonRefusal.usage("Position is 1 to \(call.browser.spaces.count)")
            }
            call.browser.moveSpace(found.id, to: position - 1)
            return ["space": found.name, "position": position, "message": "Moved"]
        },
        PersonVerb("spaces", "icon", .arrange) { call in
            let found = try space(call, try call.need("space"))
            let icon = try call.need("symbol")
            guard let worn = Spaces.icons.contains(icon) ? TabIcon(symbol: icon) : IconChoices.typed(icon) else {
                throw PersonRefusal.usage("That isn't an icon a space can wear", hint: "Icons: \(Spaces.icons.joined(separator: ", ")), or one emoji")
            }
            call.browser.setSpaceIcon(found.id, to: worn)
            return ["space": found.name, "icon": icon, "message": "Changed"]
        },
        PersonVerb("spaces", "delete", .erase, first: { call in
            guard !(try space(call, try call.need("space"))).isFirst else { throw PersonRefusal("refused", "The first space can't be deleted") }
        }) { call in
            let found = try space(call, try call.need("space"))
            call.browser.deleteSpace(found.id)
            return ["space": found.name, "message": "Deleted \(found.name)"]
        },
        PersonVerb("tabs", "list", .tool) { call in
            if let link = call.link, call.flag("mine"), call.string("space") == nil, !call.flag("all"), !call.flag("pinned") {
                return ToolReply.data(AgentWorkTabs.listing(link.id, box: call.box, current: AgentLinks.shared.currentTab(link.id)))
            }
            _ = try await PersonCommands.tool(call, "tabs")
            let onlySpace = try call.string("space").map { try space(call, $0).id }
            let everything = call.flag("all") || onlySpace != nil
            var rows = everyTab(call, load: everything).filter { everything || $0.onScreen || $0.tab.agent }
            if let onlySpace { rows = rows.filter { $0.space == onlySpace } }
            if call.flag("pinned") { rows = rows.filter { $0.tab.pin != nil } }
            return ["tabs": rows.map { row($0, call: call) }]
        },
        PersonVerb("tabs", "show", .look) { call in
            let found = try find(call, try call.need("tab"), allowInternal: true)
            var data = row(found, call: call)
            data["folder"] = found.browser.tabGroups.first { $0.id == found.tab.groupID }?.name ?? ""
            data["name"] = found.tab.name ?? ""
            data["zoom"] = Int((found.tab.zoom * 100).rounded())
            data["muted"] = found.tab.muted
            data["sound"] = found.tab.noisy
            data["player"] = MiniPlayer.told(found.tab, in: found.browser) ?? NSNull()
            data["split"] = found.browser.split(for: found.tab).flatMap { $0.partner(of: found.tab.id) }.map(PersonCommands.short) ?? ""
            return data
        },
        PersonVerb("tabs", "new", .arrange) { call in
            let browser = call.browser
            let space = try call.string("space").map { named -> Space in
                try spacesOn(call)
                return try PersonTabs.space(call, named)
            }
            let folder = try call.string("folder").map { try PersonFolders.find(call, $0) }
            let url = try call.string("url").map(webAddress)
            if space != nil, space?.id != browser.spaceID, folder != nil { throw PersonRefusal.usage("That folder is in the space on screen. Pick --space or --folder.") }
            let tab: Tab
            if let url {
                tab = browser.open(url, foreground: call.flag("front"), atEnd: true)
                browser.openedForAgent(tab, link: call.link)
            } else {
                browser.newTab()
                guard let made = browser.active else { throw PersonRefusal("failed", "No tab was made") }
                tab = made
            }
            if let folder { browser.move(tab, toGroup: folder.id) }
            if let space, space.id != browser.spaceID { try await moved(tab, in: browser, to: space) }
            return ["id": PersonCommands.short(tab.id)]
        },
        PersonVerb("tabs", "open", .tool) { call in
            guard let named = call.string("space") else { return try await PersonCommands.tool(call, "open", ["url": try call.need("url")]) }
            try spacesOn(call)
            let space = try space(call, named)
            let url = try call.need("url")
            var made = await call.box.openTab(["url": url], task: call.link?.id, space: space.id == call.browser.spaceID ? nil : space.id)
            if made.failed {
                let text = made.text ?? "That didn't work"
                throw PersonRefusal(ToolFailure.code(text), text)
            }
            made.plain = nil
            var data = ToolReply.data(made)
            if let link = call.link, let id = data["id"] as? String { AgentLinks.shared.setCurrentTab(link.id, id) }
            data["space"] = space.name
            return data
        },
        PersonVerb("tabs", "select", .arrange) { call in
            let found = try find(call, try call.need("tab"))
            guard !found.tab.agent else { throw PersonRefusal("refused", "An agent's tab stays behind the person's. Run broadway tabs keep to make it theirs.") }
            if !found.onScreen { found.browser.switchSpace(to: found.space) }
            guard found.browser.tabs.contains(where: { $0.id == found.tab.id }) else { throw PersonRefusal("refused", "That tab can't come to the front") }
            found.browser.select(found.tab)
            return ["id": PersonCommands.short(found.tab.id), "message": "In front"]
        },
        PersonVerb("tabs", "close", .erase, softer: { call in
            let found = call.strings("tab").compactMap { try? find(call, $0) }
            return found.count == call.strings("tab").count && found.allSatisfy(\.tab.agent) ? .arrange : nil
        }, first: { call in
            for named in call.strings("tab") { _ = try find(call, named) }
        }) { call in
            let found = try call.strings("tab").map { try find(call, $0) }
            for one in found {
                if one.tab.agent { one.browser.closeAgentTab(one.tab) } else { shut(one) }
                if PersonCommands.short(one.tab.id) == AgentSocket.shared.currentTab { AgentSocket.shared.currentTab = nil }
            }
            return ["closed": found.map { PersonCommands.short($0.tab.id) }, "message": found.count == 1 ? "Closed" : "Closed \(found.count) tabs"]
        },
        PersonVerb("tabs", "reopen", .arrange) { call in
            guard call.browser.recentlyClosed.first != nil else { throw PersonRefusal("refused", "Nothing was closed lately") }
            call.browser.reopen()
            return ["id": call.browser.active.map { PersonCommands.short($0.id) } ?? "", "message": "Reopened"]
        },
        PersonVerb("tabs", "closed", .look) { call in
            ["closed": call.browser.recentlyClosed.map { ghost in
                ["title": call.browser.closedTitle(for: ghost), "url": AgentSecrets.shown(ghost.url), "at": PersonCommands.stamp(ghost.at)]
            }]
        },
        PersonVerb("tabs", "move", .arrange) { call in
            let found = try onScreen(call, try call.need("tab"))
            let browser = found.browser
            guard found.tab.agent || !found.tab.bench else { throw PersonRefusal("refused", "That tab can't be moved") }
            var did = false
            if let index = call.number("to") {
                guard browser.tabs.indices.contains(Int(index) - 1) else { throw PersonRefusal.usage("--to is 1 to \(browser.tabs.count)") }
                browser.move(found.tab, to: Int(index) - 1)
                did = true
            }
            if call.flag("no-folder") {
                browser.move(found.tab, toGroup: nil)
                did = true
            } else if let folder = call.string("folder") {
                browser.move(found.tab, toGroup: try PersonFolders.find(call, folder).id)
                did = true
            }
            if let named = call.string("space") {
                try spacesOn(call)
                try await moved(found.tab, in: browser, to: try space(call, named))
                did = true
            }
            guard did else { throw PersonRefusal.usage("Say where: --space, --folder, --no-folder or --to") }
            return ["id": PersonCommands.short(found.tab.id), "message": "Moved"]
        },
        PersonVerb("tabs", "pin", .arrange) { call in
            let found = try onScreen(call, try call.need("tab"))
            guard !found.tab.agent else { throw PersonRefusal("refused", "An agent's tab can't be a pin. Run broadway tabs keep to make it the person's.") }
            found.browser.pin(found.tab)
            return ["id": PersonCommands.short(found.tab.id), "pinned": found.tab.pin != nil, "message": "Pinned"]
        },
        PersonVerb("tabs", "unpin", .arrange) { call in
            let found = try onScreen(call, try call.need("tab"))
            found.browser.unpin(found.tab)
            return ["id": PersonCommands.short(found.tab.id), "pinned": found.tab.pin != nil, "message": "Unpinned"]
        },
        PersonVerb("tabs", "rename", .arrange) { call in
            let found = try find(call, try call.need("tab"))
            found.tab.name = call.string("name")
            found.browser.writeSession(now: true)
            return ["id": PersonCommands.short(found.tab.id), "message": call.string("name") == nil ? "Name cleared" : "Renamed"]
        },
        PersonVerb("tabs", "sleep", .arrange) { call in
            var rows: [[String: Any]] = []
            for named in call.strings("tab") {
                let found = try find(call, named)
                rows.append(["id": PersonCommands.short(found.tab.id), "state": await slept(found)])
            }
            return ["tabs": rows]
        },
        PersonVerb("tabs", "wake", .arrange) { call in
            var rows: [[String: Any]] = []
            for named in call.strings("tab") {
                let found = try find(call, named)
                if !found.tab.wake() { found.tab.revive() }
                rows.append(["id": PersonCommands.short(found.tab.id), "state": found.tab.asleep ? "asleep" : "awake"])
            }
            return ["tabs": rows]
        },
        PersonVerb("tabs", "mute", .arrange) { call in try sound(call, muted: true) },
        PersonVerb("tabs", "unmute", .arrange) { call in try sound(call, muted: false) },
        PersonVerb("tabs", "keep", .person(.tab), first: { call in
            guard try find(call, try call.need("tab")).tab.agent else { throw PersonRefusal("refused", "That tab is already the person's") }
        }) { call in
            let found = try find(call, try call.need("tab"))
            found.browser.keepAgentTab(found.tab)
            return ["id": PersonCommands.short(found.tab.id), "message": "It is the person's now"]
        },
        PersonVerb("windows", "list", .look) { call in
            ["windows": call.box.browsers.enumerated().map { index, browser in
                ["id": index + 1, "space": browser.space.name, "tabs": browser.tabs.filter(BrowserToolbox.listed).count, "front": browser === Browsers.front] as [String: Any]
            }]
        },
        PersonVerb("windows", "new", .arrange) { _ in
            let made = Browsers.newWindow()
            AgentBoard.note(made)
            return ["windows": Browsers.saved.count, "message": "A new window"]
        },
    ]

    private static func sound(_ call: PersonCall, muted: Bool) throws -> [String: Any] {
        var rows: [[String: Any]] = []
        for named in call.strings("tab") {
            let found = try find(call, named)
            if found.tab.muted != muted { found.tab.toggleMute() }
            rows.append(["id": PersonCommands.short(found.tab.id), "state": found.tab.muted ? "muted" : "sound on"])
        }
        return ["tabs": rows]
    }
}

@MainActor
enum PersonFolders {
    static func find(_ call: PersonCall, _ named: String) throws -> TabGroup {
        let lower = named.lowercased()
        let groups = call.browser.tabGroups
        if let exact = groups.first(where: { $0.name.lowercased() == lower }) { return exact }
        let found = groups.filter { $0.id.uuidString.lowercased().hasPrefix(lower) }
        if found.count > 1 { throw PersonRefusal.ambiguous("id", named, found.count) }
        guard let only = found.first else { throw PersonRefusal.missing("folder", named) }
        return only
    }

    private static func fold(_ call: PersonCall, _ want: Bool) throws -> [String: Any] {
        let folder = try find(call, try call.need("folder"))
        if folder.collapsed != want { call.browser.toggleTabGroup(folder.id) }
        return ["folder": folder.name, "folded": want, "message": want ? "Folded" : "Unfolded"]
    }

    private static func pin(_ call: PersonCall, _ want: Bool) throws -> [String: Any] {
        let folder = try find(call, try call.need("folder"))
        guard !folder.live else { throw PersonRefusal("refused", "A live folder is always pinned") }
        guard folder.parent == nil else { throw PersonRefusal("refused", "A folder inside another follows its parent") }
        call.browser.setFolderPinned(folder.id, want)
        return ["folder": folder.name, "pinned": want, "message": want ? "Pinned" : "Unpinned"]
    }

    private static func pairOf(_ pair: TabSplit, in browser: Browser) -> Bool {
        pair.tabs.allSatisfy { id in browser.tabs.contains { $0.id == id && BrowserToolbox.listed($0) } }
    }

    private static func needsPair(_ call: PersonCall) throws {
        guard let pair = call.browser.activeSplit, pairOf(pair, in: call.browser) else {
            throw PersonRefusal("refused", "There is no pair on screen")
        }
    }

    static let verbs: [PersonVerb] = [
        PersonVerb("folders", "list", .look) { call in
            let groups = FolderTree.ordered(call.browser.tabGroups)
            return ["folders": groups.map { group in
                ["id": PersonCommands.short(group.id), "name": group.name, "folded": group.collapsed,
                 "pinned": FolderTree.raised(group.id, in: groups),
                 "tabs": call.browser.tabs.filter { $0.groupID == group.id && BrowserToolbox.listed($0) }.count,
                 "parent": groups.first { $0.id == group.parent }?.name ?? ""] as [String: Any]
            }]
        },
        PersonVerb("folders", "new", .arrange) { call in
            let browser = call.browser
            let parent = try call.string("in").map { try find(call, $0).id }
            let picked = try (call.string("tabs")?.split(separator: ",").map { try PersonTabs.onScreen(call, String($0)).tab }) ?? []
            let made = picked.isEmpty ? browser.newFolder(inside: parent, named: try call.need("name"), editing: false)
                : browser.newFolder(with: picked, inside: parent, named: try call.need("name"), editing: false)
            guard let made else { throw PersonRefusal("refused", "No folder was made: those tabs can't be in one, or it would be too deep") }
            return ["id": PersonCommands.short(made), "folder": try call.need("name")]
        },
        PersonVerb("folders", "rename", .arrange) { call in
            let folder = try find(call, try call.need("folder"))
            call.browser.renameTabGroup(folder.id, to: try call.need("name"))
            return ["folder": try call.need("name"), "message": "Renamed"]
        },
        PersonVerb("folders", "fold", .arrange) { call in try fold(call, true) },
        PersonVerb("folders", "pin", .arrange) { call in try pin(call, true) },
        PersonVerb("folders", "unpin", .arrange) { call in try pin(call, false) },
        PersonVerb("folders", "unfold", .arrange) { call in try fold(call, false) },
        PersonVerb("folders", "add", .arrange) { call in
            let folder = try find(call, try call.need("folder"))
            guard !folder.live else { throw PersonRefusal("refused", "A live folder fills itself") }
            var moved: [String] = []
            for named in call.strings("tab") {
                let found = try PersonTabs.onScreen(call, named)
                call.browser.move(found.tab, toGroup: folder.id)
                if found.tab.groupID == folder.id { moved.append(PersonCommands.short(found.tab.id)) }
            }
            guard !moved.isEmpty else { throw PersonRefusal("refused", "Those tabs can't be in a folder") }
            return ["folder": folder.name, "moved": moved, "message": "Moved \(moved.count)"]
        },
        PersonVerb("folders", "remove", .arrange) { call in
            for named in call.strings("tab") { call.browser.move(try PersonTabs.onScreen(call, named).tab, toGroup: nil) }
            return ["message": "Out of their folders"]
        },
        PersonVerb("folders", "delete", .arrange) { call in
            let folder = try find(call, try call.need("folder"))
            call.browser.removeTabGroup(folder.id)
            return ["folder": folder.name, "message": "Deleted. Its tabs stayed."]
        },
        PersonVerb("folders", "close", .erase, first: { _ = try find($0, try $0.need("folder")) }) { call in
            let folder = try find(call, try call.need("folder"))
            call.browser.closeTabGroup(folder.id)
            return ["folder": folder.name, "message": "Closed"]
        },
        PersonVerb("split", "list", .look) { call in
            let browser = call.browser
            return ["pairs": browser.splits.filter { pairOf($0, in: browser) }.map { pair in
                ["id": PersonCommands.short(pair.id), "left": PersonCommands.short(pair.left), "right": PersonCommands.short(pair.right),
                 "axis": pair.axis.rawValue, "front": browser.activeSplit?.id == pair.id] as [String: Any]
            }]
        },
        PersonVerb("split", "start", .arrange) { call in
            let left = try PersonTabs.onScreen(call, try call.need("left"))
            let right = try PersonTabs.onScreen(call, try call.need("right"))
            guard left.browser === right.browser, left.browser.canSplit(left.tab, with: right.tab) else {
                throw PersonRefusal("refused", "Those two tabs can't be side by side")
            }
            left.browser.pair(left.tab, with: right.tab, onLeft: true)
            return ["message": "Side by side"]
        },
        PersonVerb("split", "swap", .arrange) { call in
            try needsPair(call)
            call.browser.swapSplit()
            return ["message": "Swapped"]
        },
        PersonVerb("split", "even", .arrange) { call in
            try needsPair(call)
            call.browser.evenSplit()
            return ["message": "Evened out"]
        },
        PersonVerb("split", "detach", .arrange) { call in
            let found = try PersonTabs.onScreen(call, try call.need("tab"))
            guard found.browser.split(for: found.tab) != nil else { throw PersonRefusal("refused", "That tab isn't in a pair") }
            found.browser.detachSplit(found.tab)
            return ["message": "Apart"]
        },
    ]
}

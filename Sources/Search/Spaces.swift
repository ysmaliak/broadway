import AppKit
import WebKit

struct Space: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    /// Which of `Spaces.colours` — from before spaces had icons; kept so an
    /// older list still reads.
    var colour: Int
    var icon: TabIcon?
    var look: SpaceLook?
    /// Signed in wherever the first space is — the same cookies and
    /// sign-ins, only the tabs its own — rather than a store of its own.
    /// Chosen when it is made; nil, for a space from before the choice, is
    /// a store of its own.
    var sharesSignIns: Bool?
    /// Where this space's downloads go; nil for the folder in Settings.
    var downloads: String?
    var languages: [String]?
    /// The first space: the session and the store there were before spaces.
    static let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    var isFirst: Bool { id == Space.firstID }
    static func first() -> Space { Space(id: firstID, name: "Personal", colour: 0) }
    static let privateWindow = Space(id: firstID, name: "Private", colour: 0, icon: TabIcon(symbol: "eye.slash"), look: SpaceLook.onyx)

    var symbol: String { icon?.symbol ?? (isFirst ? "house" : "briefcase") }

    var shownIcon: TabIcon { icon ?? TabIcon(symbol: symbol) }

    init(id: UUID, name: String, colour: Int, icon: TabIcon? = nil, look: SpaceLook? = nil,
         sharesSignIns: Bool? = nil, downloads: String? = nil, languages: [String]? = nil) {
        self.id = id
        self.name = name
        self.colour = colour
        self.icon = icon
        self.look = look
        self.sharesSignIns = sharesSignIns
        self.downloads = downloads
        self.languages = languages
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, colour, icon, emoji, look, sharesSignIns, downloads, languages
    }

    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        id = try saved.decode(UUID.self, forKey: .id)
        name = try saved.decode(String.self, forKey: .name)
        colour = try saved.decode(Int.self, forKey: .colour)
        look = try saved.decodeIfPresent(SpaceLook.self, forKey: .look)
        sharesSignIns = try saved.decodeIfPresent(Bool.self, forKey: .sharesSignIns)
        downloads = try saved.decodeIfPresent(String.self, forKey: .downloads)
        languages = (try? saved.decodeIfPresent([String].self, forKey: .languages)).flatMap { $0.isEmpty ? nil : $0 }
        let emoji = try saved.decodeIfPresent(String.self, forKey: .emoji).flatMap { $0.isEmpty ? nil : $0 }
        let icon = try saved.decodeIfPresent(String.self, forKey: .icon)
        self.icon = (emoji ?? icon).map(TabIcon.init(saved:))
    }

    func encode(to encoder: Encoder) throws {
        var out = encoder.container(keyedBy: CodingKeys.self)
        try out.encode(id, forKey: .id)
        try out.encode(name, forKey: .name)
        try out.encode(colour, forKey: .colour)
        try out.encodeIfPresent(icon?.saved, forKey: .icon)
        try out.encodeIfPresent(look, forKey: .look)
        try out.encodeIfPresent(sharesSignIns, forKey: .sharesSignIns)
        try out.encodeIfPresent(downloads, forKey: .downloads)
        try out.encodeIfPresent(languages, forKey: .languages)
    }
}

enum Spaces {
    static func moved<T>(_ items: [T], from: Int, to index: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(index), from != index else { return items }
        var items = items
        let item = items.remove(at: from)
        items.insert(item, at: index)
        return items
    }

    /// The icons a space can wear: Apple's own symbols, drawn in one weight
    /// and one grey, grouped as work, thinking, leisure and life.
    static let icons = [
        "briefcase", "building.2", "desktopcomputer", "laptopcomputer", "chevron.left.forwardslash.chevron.right", "terminal",
        "sparkles", "brain.head.profile", "lightbulb", "gamecontroller", "beach.umbrella", "cup.and.saucer",
        "music.note", "film", "paintpalette", "camera", "house", "book",
        "graduationcap", "cart", "airplane", "dumbbell", "leaf", "heart",
    ]
    static let iconNames = [
        "Work", "Office", "Desktop", "Laptop", "Code", "Terminal",
        "AI", "Thinking", "Ideas", "Games", "Leisure", "Café",
        "Music", "Film", "Art", "Photos", "Home", "Reading",
        "Studies", "Shopping", "Travel", "Sport", "Nature", "Personal",
    ]

    static func leastWorn(in spaces: [Space]) -> String {
        var worn: [String: Int] = [:]
        for space in spaces where space.icon?.emoji == nil { worn[space.symbol, default: 0] += 1 }
        return icons.min { worn[$0, default: 0] < worn[$1, default: 0] } ?? "briefcase"
    }

    private static var file: URL { Store.file("spaces.json") }

    static func read() -> [Space] {
        let saved = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Space].self, from: $0) } ?? []
        guard !saved.isEmpty else { return [Space.first()] }
        var foundHome = false
        var spaces = saved.compactMap { space -> Space? in
            if space.isFirst {
                // Keep the old reader's repair of a damaged list, without
                // moving the first home entry away from its chosen place.
                guard !foundHome else { return nil }
                foundHome = true
            }
            return space
        }
        if !spaces.contains(where: \.isFirst) { spaces.insert(Space.first(), at: 0) }
        if keepsOrder(in: saved) { return spaces }
        return spaces.filter(\.isFirst) + spaces.filter { !$0.isFirst }
    }

    private static func keepsOrder(in spaces: [Space]) -> Bool {
        Store.settings.bool(forKey: "spaces.orderKept") || spaces.first?.id != Space.firstID
    }

    static func write(_ spaces: [Space]) {
        guard let data = try? JSONEncoder().encode(spaces) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        MainActor.assumeIsolated { known = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        // Every window's list follows (see Browser.init).
        NotificationCenter.default.post(name: changed, object: spaces)
    }

    /// The list of spaces changed, in one window or another.
    static let changed = Notification.Name("SearchSpacesChanged")

    /// The space new tabs are made in: the one on screen.
    @MainActor static var current = Space.firstID

    /// Each space's store, made once: WebKit shares processes between views
    /// that ask for the same store object.
    @MainActor private static var stores: [UUID: WKWebsiteDataStore] = [:]
    @MainActor static var known: [UUID: Space] = Dictionary(read().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

    @MainActor static func store(for id: UUID) -> WKWebsiteDataStore {
        if id == Space.firstID || known[id]?.sharesSignIns == true {
            let shared = Store.websites
            SignInKeeper.shared.watch(shared, as: Space.firstID)
            return shared
        }
        if let made = stores[id] { return made }
        let made = WKWebsiteDataStore(forIdentifier: id)
        if Store.keepsSignIns { Store.followSignIns(made) } else { Store.followCookies(made) }
        stores[id] = made
        SignInKeeper.shared.watch(made, as: id)
        return made
    }

    /// The shared store and every space's own made so far. Not a private
    /// tab's: each has a store of its own, out of this list on purpose, so
    /// tracking prevention stays on there whatever the switch says.
    @MainActor static var everyStore: [WKWebsiteDataStore] {
        [Store.websites] + stores.values
    }

    @MainActor static func spaceStores() -> [WKWebsiteDataStore] {
        var found: [WKWebsiteDataStore] = [Store.websites]
        for space in read() {
            let store = store(for: space.id)
            if !found.contains(where: { $0 === store }) { found.append(store) }
        }
        return found
    }

    /// A space's store and everything in it, gone. What it holds — cookies,
    /// sign-ins, storage, caches — is emptied at once. The store itself
    /// WebKit won't remove while this run still holds on to it, however
    /// closed its tabs, so it is written down and removed at the next
    /// launch if the tries in between don't manage.
    @MainActor static func erase(_ id: UUID) {
        guard id != Space.firstID else { return }
        // And once more a moment later, for what its closing tabs were
        // still writing — the cache of the page on screen, for one.
        let store = store(for: id)
        // The space's downloads would have kept its store, and asked with
        // its cookies again: they go with it.
        stores[id] = nil
        SignInKeeper.shared.forget(id)
        CertificateTrust.forget(space: id)
        eraseStore(store, id: id)
    }

    @MainActor static func eraseStore(_ store: WKWebsiteDataStore?, id: UUID) {
        if let store {
            guard store !== Store.websites else { return }
            Browsers.all.first?.forgetDownloads(of: store)
            let everything = WKWebsiteDataStore.allWebsiteDataTypes()
            store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                store.removeData(ofTypes: everything, modifiedSince: .distantPast) {}
            }
        }
        let pending = Set(Store.settings.stringArray(forKey: "spaces.erasing") ?? []).union([id.uuidString])
        Store.settings.set(pending.sorted(), forKey: "spaces.erasing")
        sweep()
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { sweep() }
        }
    }

    /// Every store of a deleted space that is still there, tried again.
    @MainActor static func sweep() {
        for text in Store.settings.stringArray(forKey: "spaces.erasing") ?? [] {
            guard let id = UUID(uuidString: text) else { continue }
            Task { @MainActor in
                do { try await WKWebsiteDataStore.remove(forIdentifier: id) } catch {
                    // Gone already is as good as removed; anything else is
                    // tried again later.
                    let left = await WKWebsiteDataStore.allDataStoreIdentifiers
                    guard !left.contains(id) else { return }
                }
                let now = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != text }
                Store.settings.set(now, forKey: "spaces.erasing")
            }
        }
    }
}

@MainActor
enum SpaceLoads {
    static var rows = 0
    static var longest: CFTimeInterval = 0
}

/// A space's row of tabs while another space is on screen.
struct Parked {
    var tabs: [Tab]
    var active: Tab.ID?
    var splits: [TabSplit] = []
    /// Its groups, as its file has them: kept here so that writing the row,
    /// or coming back to the space, doesn't read and decode the file again
    /// on the main thread. Nil when unknown, for the file to say.
    var groups: [TabGroup]? = nil

    /// The row as it is drawn while it passes during a swipe between spaces,
    /// the same way it is drawn on screen: each group under its heading,
    /// folded or not as it was left — a folded one shows only the tab in
    /// front, if that is in it — then the loose tabs. Drawn flat, every tab
    /// in a folded group came out for the length of the swipe and went back
    /// in as the space landed. A pair's other half isn't a row of its own.
    @MainActor func drawn(groupsOn: Bool, splitView: Bool) -> (groups: [DrawnGroup], loose: [Tab]) {
        let stands: (Tab) -> Bool = { tab in
            !splitView || !splits.contains { $0.tabs.contains(tab.id) && $0.left != tab.id }
        }
        let kept = groupsOn ? FolderTree.ordered(FolderTree.lasting(groups ?? [], holding: Set(tabs.compactMap(\.groupID)))) : []
        let shown = drawnGroups(kept, splitView: splitView)
        let inGroups = Set(kept.map(\.id))
        let loose = tabs.filter { tab in
            tab.pin == nil && stands(tab) && !(tab.groupID.map(inGroups.contains) ?? false)
        }
        return (shown, loose)
    }

    @MainActor func list(groupsOn: Bool, splitView: Bool) -> (raised: [DrawnGroup], items: [DrawnItem]) {
        let stands: (Tab) -> Bool = { tab in
            !splitView || !splits.contains { $0.tabs.contains(tab.id) && $0.left != tab.id }
        }
        let kept = groupsOn ? FolderTree.ordered(FolderTree.lasting(groups ?? [], holding: Set(tabs.compactMap(\.groupID)))) : []
        let raised = drawnGroups(kept.filter { FolderTree.raised($0.id, in: kept) }, splitView: splitView)
        let inGroups = Set(kept.map(\.id))
        var items: [DrawnItem] = []
        var gathered = Set<UUID>()
        for tab in tabs where tab.pin == nil && stands(tab) {
            guard let id = tab.groupID, inGroups.contains(id) else {
                items.append(.tab(tab))
                continue
            }
            guard !FolderTree.raised(id, in: kept) else { continue }
            let root = FolderTree.root(of: id, in: kept)
            guard gathered.insert(root).inserted else { continue }
            let family = Set([root] + FolderTree.descendants(of: root, in: kept).map(\.id))
            items.append(.folder(root, drawnGroups(kept.filter { family.contains($0.id) }, splitView: splitView)))
        }
        return (raised, items)
    }

    enum DrawnItem: Identifiable {
        case tab(Tab)
        case folder(UUID, [DrawnGroup])

        var id: UUID {
            switch self {
            case .tab(let tab): return tab.id
            case .folder(let id, _): return id
            }
        }
    }

    @MainActor private func drawnGroups(_ kept: [TabGroup], splitView: Bool) -> [DrawnGroup] {
        let stands: (Tab) -> Bool = { tab in
            !splitView || !splits.contains { $0.tabs.contains(tab.id) && $0.left != tab.id }
        }
        let front = splits.first { pair in active.map(pair.tabs.contains) ?? false }?.left ?? active
        var shown: [DrawnGroup] = []
        for row in FolderTree.rows(kept) {
            switch row.kind {
            case .heading:
                shown.append(DrawnGroup(group: row.group, tabs: [], depth: row.depth, heading: true))
            case .tabs:
                let inside = Set([row.group.id] + FolderTree.descendants(of: row.group.id, in: kept).map(\.id))
                let drawn = row.group.collapsed
                    ? tabs.filter { $0.pin == nil && $0.groupID.map(inside.contains) == true && stands($0) && $0.id == front }
                    : tabs.filter { $0.pin == nil && $0.groupID == row.group.id && stands($0) }
                if let last = shown.last, last.group.id == row.group.id {
                    shown[shown.count - 1] = DrawnGroup(group: row.group, tabs: drawn, depth: row.depth, heading: true)
                } else if !drawn.isEmpty {
                    shown.append(DrawnGroup(group: row.group, tabs: drawn, depth: row.depth, heading: false))
                }
            }
        }
        return shown
    }

    /// One group of a row drawn off screen, and the tabs it shows.
    struct DrawnGroup: Identifiable {
        let group: TabGroup
        let tabs: [Tab]
        var depth = 0
        var heading = true
        var id: String { "\(group.id.uuidString)-\(heading)" }
    }
}

extension Browser {
    var space: Space { isPrivate ? .privateWindow : spaces.first { $0.id == spaceID } ?? spaces[0] }
    var showsSpaces: Bool { prefs.usesSpaces && !isPrivate }

    var groundOpaque: Bool {
        !asCards || NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || !spaces.contains { $0.look?.showsThrough == true }
    }

    /// Every tab of the spaces not on screen, for the sleep timer.
    var parkedTabs: [Tab] { parked.values.flatMap(\.tabs) }

    /// Where a download lands: the space's folder, or the one in Settings.
    var downloadsFolder: URL {
        guard prefs.usesSpaces, let path = space.downloads else { return prefs.downloads }
        return URL(fileURLWithPath: path)
    }

    func downloadsFolder(in id: UUID) -> URL {
        guard prefs.usesSpaces, !isPrivate, let path = spaces.first(where: { $0.id == id })?.downloads else { return prefs.downloads }
        return URL(fileURLWithPath: path)
    }

    func switchSpace(to id: UUID) {
        guard showsSpaces else { return }
        enter(id)
    }

    func goToSpace(_ id: UUID) {
        guard showsSpaces, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        if prefs.stacksSpaces { return stackedJump(to: id) }
        let here = makingSpace ? spaces.count : (spaces.firstIndex { $0.id == spaceID } ?? 0)
        let hidden = (folded && !peeking) || (Store.testing && !Store.shownOnScreen)
        guard !hidden else { return switchSpace(to: id) }
        preloadSpaces()
        SpaceSwipe.shared.slide(self, to: to, from: here)
    }

    func enter(_ id: UUID) {
        guard id != spaceID, let to = spaces.firstIndex(where: { $0.id == id }) else { return }
        hoverCards.quiet()
        if spaceAsk.up { cancelSpaceCreation() }
        // Which way the icon at the foot turns over: the way the spaces lie.
        if !makingSpace { spaceStep = to > (spaces.firstIndex { $0.id == spaceID } ?? 0) ? 1 : -1 }
        columnMemory.capture(spaceID)
        spacePictures.capture(spaceID, tabs: tabs.filter { visibleTabIDs.contains($0.id) })
        cancelTabEdit()
        let arriving = shownOnEntering(id)
        if let out = floating, arriving.contains(out) { land() }
        if let out = pictured, arriving.contains(out) { unpicture() }
        leaving()
        writeSession(now: true)
        for tab in tabs where visibleTabIDs.contains(tab.id) { tab.touch() }

        // The row on screen is parked as it is, sound and all: music or a
        // stream keeps playing in the space you left, as it does in a tab
        // you left. ⌘⇧M, or its speaker, stops it.
        parked[spaceID] = Parked(tabs: tabs, active: activeID, splits: splits, groups: tabGroups)
        spacePictures.follow(spaceID, tabs: tabs.filter { visibleTabIDs.contains($0.id) })

        let columnTicket = columnMemory.begin(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.columnMemory.finish(columnTicket)
        }
        spaceID = id
        sitePanelFollowsSpace()
        // A space kept in memory has its groups with it; one that isn't is
        // read whole just below (restoreSession), groups included.
        tabGroups = parked[id]?.groups ?? []
        // The space new pages are made in, when this is the window in front;
        // and the one to come back to, when this is the oldest window.
        if Browsers.front === self || Browsers.front == nil { Spaces.current = id }
        if Browsers.primary === self { Store.settings.set(id.uuidString, forKey: "space.current") }
        if let back = parked.removeValue(forKey: id), !back.tabs.isEmpty {
            // Nothing in front there (a fresh start, see Session.startFresh):
            // an empty tab beside its pins, as at launch, not the first pin.
            // One that has gone from the row falls to its first tab that isn't a pin.
            let front = back.active.map { active in
                back.tabs.contains { $0.id == active } ? active : (back.tabs.first { $0.pin == nil } ?? back.tabs[0]).id
            }
            showRow(back.tabs, active: front, splits: back.splits, blank: true)
            if let shown = floating, visibleTabIDs.contains(shown) { land() }
            if let shown = pictured, visibleTabIDs.contains(shown) { unpicture() }
            for tab in tabs where visibleTabIDs.contains(tab.id) {
                if !tab.wake() { tab.revive() }
            }
        } else {
            showRow([], active: nil)
            restoreSession()
        }
        editing = active?.isBlank ?? true
        typed = ""
        // A row read from its file just now may hold tabs whose time ran out
        // while it wasn't in memory (see Closing.swift).
        closeLeftAlone()
        if Motion.reduced {
            for tab in tabs where visibleTabIDs.contains(tab.id) { spacePictures.coverForLanding(tab, in: id) }
        }
        askFocus()
        spacePictures.keepFollowing(Set(nearSpaces))
        for near in nearSpaces { if let tabs = parked[near]?.tabs { spacePictures.followPictured(near, tabs: tabs) } }
        spacePages.settle()
        // Beside the space's icon when the tabs are on screen (SpaceDot);
        // folded away, at the bottom.
        if folded && !peeking { announce(space.name) }
    }

    func space(holding tab: Tab.ID) -> UUID? {
        parked.first { $0.value.tabs.contains { $0.id == tab } }?.key
    }

    private func shownOnEntering(_ id: UUID) -> Set<Tab.ID> {
        guard let row = parked[id], let front = row.active, row.tabs.contains(where: { $0.id == front }) else { return [] }
        guard let pair = row.splits.first(where: { $0.contains(front) }) else { return [front] }
        return Set(pair.tabs)
    }

    var nearSpaces: [UUID] {
        guard prefs.usesSpaces, !prefs.stacksSpaces, !isPrivate, !makingSpace,
              let here = spaces.firstIndex(where: { $0.id == spaceID }) else { return [] }
        return [here + 1, here - 1].filter(spaces.indices.contains).map { spaces[$0].id }
    }

    /// Every other space's row, made ahead of time, so the column can show
    /// the next space beside this one while two fingers bring it in.
    func preloadSpaces() {
        guard !isPrivate else { return }
        let began = CACurrentMediaTime()
        var loaded = 0
        defer {
            if Store.testing, loaded > 0 {
                SpaceLoads.rows += loaded
                SpaceLoads.longest = max(SpaceLoads.longest, CACurrentMediaTime() - began)
            }
        }
        for space in spaces where space.id != spaceID {
            let kept = parked[space.id]
            guard kept == nil || kept?.active == nil else { continue }
            loaded += 1
            var row = kept ?? loadRow(space.id)
            if row.active == nil {
                let blank = makeTab(space: space.id)
                prepare(blank)
                row.tabs.append(blank)
                row.active = blank.id
            }
            parked[space.id] = row
        }
    }

    func switchSpace(index: Int) {
        guard spaces.indices.contains(index) else { return }
        switchSpace(to: spaces[index].id)
    }

    func goToSpace(index: Int) {
        guard spaces.indices.contains(index) else { return }
        goToSpace(spaces[index].id)
    }

    func stepSpace(_ direction: Int) {
        guard showsSpaces, spaces.count > 1 else { return }
        let here = SpaceSwipe.shared.target(of: self) ?? spaces.firstIndex { $0.id == spaceID } ?? 0
        goToSpace(index: ((here + direction) % spaces.count + spaces.count) % spaces.count)
    }

    /// The icon a new space gets unless told: the first no space wears yet.
    var freeIcon: TabIcon { TabIcon(symbol: Spaces.leastWorn(in: spaces)) }

    func addSpace(named name: String, icon: TabIcon? = nil, look: SpaceLook? = nil, sharesSignIns: Bool = true) {
        let made = Space(id: UUID(), name: name, colour: 0, icon: icon ?? freeIcon, look: look,
                         sharesSignIns: sharesSignIns)
        makingSpace = false
        spaceDraftIcon = nil
        spaceAsk.close(created: true)
        spaces.append(made)
        Spaces.write(spaces)
        if let afterSpaceCreated {
            self.afterSpaceCreated = nil
            afterSpaceCreated(made)
        } else {
            switchSpace(to: made.id)
        }
        Delight.shared.first(.firstSpace, in: self)
    }

    /// Dragged to another place among the dots. ⌃1–⌃9 follow the order.
    func moveSpace(_ id: UUID, to index: Int) {
        guard let from = spaces.firstIndex(where: { $0.id == id }), spaces.indices.contains(index), from != index else { return }
        spaces = Spaces.moved(spaces, from: from, to: index)
        Store.settings.set(true, forKey: "spaces.orderKept")
        Spaces.write(spaces)
    }

    func askForSpace(then onCreated: ((Space) -> Void)? = nil) {
        afterSpaceCreated = onCreated
        guard !spaceAsk.up, !makingSpace else { return }
        columnMemory.capture(spaceID)
        spaceDraftIcon = nil
        spaceDraftName.text = ""
        spaceAsk.open(in: self)
        guard !folded, !prefs.stacksSpaces else { return }
        let here = spaces.firstIndex { $0.id == spaceID } ?? 0
        SpaceSwipe.shared.start(for: self)
        SpaceSwipe.shared.slide(self, to: spaces.count, from: here)
    }

    func cancelSpaceCreation() {
        afterSpaceCreated = nil
        spaceAsk.close()
    }

    func leaveSpaceCreation() {
        cancelSpaceCreation()
        guard makingSpace || spaceNext == spaces.count else {
            spaceDraftIcon = nil
            return
        }
        let back = spaces.firstIndex { $0.id == spaceID } ?? 0
        SpaceSwipe.shared.slide(self, to: back, from: spaces.count)
    }

    func renameSpace(_ id: UUID, to name: String) {
        guard let at = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        spaces[at].name = name
        Spaces.write(spaces)
    }

    func setSpaceIcon(_ id: UUID, to icon: TabIcon?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].icon = icon
        Spaces.write(spaces)
    }

    func setSpaceLook(_ id: UUID, to look: SpaceLook, lasting: Bool = true) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].look = look
        if lasting { Spaces.write(spaces) }
    }

    func useLookEverywhere(_ look: SpaceLook) {
        for index in spaces.indices { spaces[index].look = look }
        Spaces.write(spaces)
    }

    func setSpaceDownloads(_ id: UUID, to folder: URL?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].downloads = folder?.path
        Spaces.write(spaces)
    }

    func setSpaceLanguages(_ id: UUID, to languages: [String]?) {
        guard let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[at].languages = languages.flatMap { $0.isEmpty ? nil : $0 }
        Spaces.write(spaces)
    }

    func deleteSpace(_ id: UUID) {
        guard id != Space.firstID, let at = spaces.firstIndex(where: { $0.id == id }) else { return }
        if spaceID == id { switchSpace(to: Space.firstID) }
        spacePictures.discard(id)
        StackedFolds.shared.forget(id)
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        let shared = spaces[at].sharesSignIns == true
        spaces.remove(at: at)
        Spaces.write(spaces)
        Session.erase(space: id)
        SessionStates.erase(space: id)
        // Gone from the other windows too: their rows there, and the space
        // itself if one was showing it (the list's change moves it).
        for other in Browsers.all where other !== self { other.forget(space: id) }
        Pins.forget(id)
        LiveOffers.shared.forget(space: id)
        LiveFolders.shared.remove(space: id)
        history.forget(space: id)
        // A space signed in with the others has nothing of its own to erase:
        // its cookies are theirs.
        if !shared { Spaces.erase(id) }
    }

    /// Spaces turned off: back to the first one. The others are kept, in
    /// case they are turned on again.
    func leaveSpaces() {
        enter(Space.firstID)
        for (_, row) in parked { for tab in row.tabs { tab.close() } }
        parked = [:]
        spacePictures.clear()
    }
}

/// The dot's menu: the spaces, then what can be done to the one on screen.
@MainActor
enum SpaceMenu {
    static func item(_ title: String, checked: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        KitMenu.item(.action(title, modifiers: [], on: checked, run: run))
    }

    static func show(for browser: Browser) {
        menu(for: browser).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The menu itself, for show() to pop up, and for the bench to read.
    static func menu(for browser: Browser, space id: UUID? = nil, icon: Bool = false) -> NSMenu {
        let menu = NSMenu()
        for (index, space) in browser.spaces.enumerated() {
            let entry = item(space.name, checked: space.id == browser.spaceID) {
                browser.goToSpace(space.id)
            }
            if index < 9, let key = ShortcutStore.shared.key(for: "spaces.\(index + 1)")?.menuKey {
                entry.keyEquivalent = key.key
                entry.keyEquivalentModifierMask = key.mask
            }
            entry.image = space.menuMark
            entry.preferredImageVisibility = .visible
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("New Space…") { browser.askForSpace() }.leadingSymbol(MenuSymbol.newSpace))
        menu.addItem(.separator())
        let here = id.flatMap { id in browser.spaces.first { $0.id == id } } ?? browser.space
        let shown = here.id == browser.spaceID
        menu.addItem(item("Rename “\(here.name)”…") {
            Ask.name("Rename Space", placeholder: here.name, initial: here.name, confirm: "Rename") { browser.renameSpace(here.id, to: $0) }
        }.leadingSymbol(MenuSymbol.rename))
        if icon { menu.addItem(item("Change Icon…") { browser.iconPicker.pick(.space(here.id)) }.leadingSymbol(MenuSymbol.icon)) }
        if shown { menu.addItem(item("Edit Look…") { browser.editingLook = true }.leadingSymbol(MenuSymbol.look)) }
        // The order is the swipe's, and ⌃1–⌃9's.
        if let at = browser.spaces.firstIndex(where: { $0.id == here.id }) {
            let stacked = browser.prefs.stacksSpaces
            if at > 0 {
                menu.addItem(item(stacked ? "Move Up" : "Move Left") { browser.moveSpace(here.id, to: at - 1) }
                    .leadingSymbol(stacked ? MenuSymbol.moveUp : MenuSymbol.moveLeft))
            }
            if at < browser.spaces.count - 1 {
                menu.addItem(item(stacked ? "Move Down" : "Move Right") { browser.moveSpace(here.id, to: at + 1) }
                    .leadingSymbol(stacked ? MenuSymbol.moveDown : MenuSymbol.moveRight))
            }
        }
        // Every group of this space, folded or opened at once, as in Arc.
        if shown, browser.prefs.usesTabGroups, !browser.tabGroups.isEmpty {
            if browser.canFoldAllGroups {
                menu.addItem(item("Shut All Folders") { browser.foldAllGroups(true) }.leadingSymbol(MenuSymbol.shutFolders))
            }
            if browser.canUnfoldAllGroups {
                menu.addItem(item("Open All Folders") { browser.foldAllGroups(false) }.leadingSymbol(MenuSymbol.openFolders))
            }
        }
        menu.addItem(.separator())
        let folder = here.downloads.map { URL(fileURLWithPath: $0).lastPathComponent }
        menu.addItem(item(folder.map { "Downloads to “\($0)”…" } ?? "Downloads Folder…") {
            Ask.folder { browser.setSpaceDownloads(here.id, to: $0) }
        }.leadingSymbol(MenuSymbol.downloadsFolder))
        if folder != nil {
            menu.addItem(item("Downloads to the Folder in Settings") { browser.setSpaceDownloads(here.id, to: nil) }
                .leadingSymbol(MenuSymbol.settingsFolder))
        }
        let languages = here.languages.map(PreferredLanguages.names) ?? "Same as Settings"
        menu.addItem(item("Languages: \(languages)…") { browser.openSpaceLanguages(here.id) }.leadingSymbol(MenuSymbol.languages))
        if !here.isFirst {
            menu.addItem(.separator())
            menu.addItem(item("Delete “\(here.name)”…") {
                Ask.sure("Delete “\(here.name)”?", detail: "Its tabs close, and its cookies and sign-ins are erased from this Mac. History and bookmarks stay.", confirm: "Delete") {
                    browser.deleteSpace(here.id)
                }
            }.leadingSymbol(MenuSymbol.delete))
        }
        return menu
    }
}

/// The few questions a space's menu asks, as sheets on the window. The
/// bookmarks list borrows `name` for Rename….
@MainActor
enum Ask {
    /// A test run's answer to `sure`, in place of a sheet that a probe
    /// started hidden can't show (`ui confirm on|off`). Never set otherwise.
    @MainActor static var testing: Bool?

    static var typed: String?

    static var asked: [String] = []

    /// `empty`: an empty name is an answer too (a bookmark's, see
    /// Bookmarks.askRename); otherwise it is taken as no answer.
    static func name(_ title: String, detail: String? = nil, placeholder: String, initial: String = "", confirm: String, empty: Bool = false, then: @escaping (String) -> Void) {
        if Store.testing, let typed {
            let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if empty || !name.isEmpty { then(name) }
            return
        }
        let alert = plain(title, detail: detail ?? "")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = placeholder
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        show(alert) { ok in
            let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if ok, empty || !name.isEmpty { then(name) }
        }
    }

    /// `returnCancels`: Return is Cancel's, for a yes that can't be undone.
    static func sure(_ title: String, detail: String, confirm: String, cancel: String = "Cancel", returnCancels: Bool = false,
                     over window: NSWindow? = nil, then: @escaping () -> Void) {
        if let yes = rehearsed(title) {
            if yes { then() }
            return
        }
        let alert = question(title, detail: detail, confirm: confirm, cancel: cancel, returnCancels: returnCancels)
        guard returnCancels else {
            show(alert, over: window) { ok in if ok { then() } }
            return
        }
        // A button holds one key, and Cancel gave up Esc for Return: Esc is
        // caught here for it while the question is up.
        let escape = escapeCancels(alert)
        show(alert, over: window) { ok in
            if let escape { NSEvent.removeMonitor(escape) }
            if ok { then() }
        }
    }

    static func rehearsed(_ title: String) -> Bool? {
        guard Store.testing, let yes = testing else { return nil }
        asked.append(title)
        return yes
    }

    static func plain(_ title: String, detail: String = "", buttons: [String] = []) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        for button in buttons { alert.addButton(withTitle: button) }
        return alert
    }

    static func escapeCancels(_ alert: NSAlert) -> Any? {
        let no = alert.buttons[1]
        return NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.keyCode == 53 else { return event }
            no.performClick(nil)
            return nil
        }
    }

    static func question(_ title: String, detail: String, confirm: String, cancel: String = "Cancel", returnCancels: Bool,
                         destructive: Bool = true) -> NSAlert {
        let alert = plain(title, detail: detail)
        let yes = alert.addButton(withTitle: confirm)
        yes.hasDestructiveAction = destructive
        let no = alert.addButton(withTitle: cancel)
        if returnCancels {
            yes.keyEquivalent = ""
            no.keyEquivalent = "\r"
        }
        return alert
    }

    static func folder(then: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for This Space"
        panel.message = "Downloads in this space go here. Cancel keeps the current folder."
        guard let window = Links.window else { return }
        panel.beginSheetModal(for: window) { answer in
            if answer == .OK, let url = panel.url { then(url) }
        }
    }

    private static func show(_ alert: NSAlert, over asked: NSWindow? = nil, _ done: @escaping (Bool) -> Void) {
        guard let window = asked ?? Links.window else {
            done(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }
}

extension Space {
    @MainActor var menuImage: NSImage? {
        if shownIcon.emoji == nil, let name = shownIcon.symbol {
            return KitGlyph.image(name, .init(size: 13, weight: IconLook.weight))
        }
        guard let copy = shownIcon.image?.copy() as? NSImage else { return nil }
        copy.size = NSSize(width: 16, height: 16)
        return copy
    }

    @MainActor var menuMark: NSImage? {
        guard let image = menuImage else { return nil }
        let box = NSSize(width: 20, height: 16)
        let scale = min(1, box.width / image.size.width, box.height / image.size.height)
        let fitted = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let boxed = NSImage(size: box, flipped: false) { bounds in
            image.draw(in: NSRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height))
            return true
        }
        boxed.isTemplate = image.isTemplate
        return boxed
    }
}

extension Browser {
    /// A space deleted in another window: this window's row there goes.
    func forget(space id: UUID) {
        spacePictures.discard(id)
        for tab in parked.removeValue(forKey: id)?.tabs ?? [] { tab.close() }
        record.rows[id.uuidString] = nil
    }
}

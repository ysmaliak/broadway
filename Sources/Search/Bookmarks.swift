import Combine
import Observation
import AppKit
import Combine

struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    /// Nil for a folder.
    var url: String?
    var children: [Bookmark]?

    var isFolder: Bool { url == nil }

    /// A bookmark whose name was emptied, as in Chrome and Safari: on the
    /// bar it is its icon alone. There is no setting; emptying it is the
    /// choice. A folder always has a name.
    var unnamed: Bool {
        !isFolder && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What a list reads it as: its name, or for one without, its address
    /// as the address field shows it, so the list is still readable.
    var label: String {
        guard unnamed else { return title }
        return url.flatMap { URL(string: $0) }.map(Address.pretty) ?? url ?? ""
    }

    var host: String? {
        url.flatMap { URL(string: $0)?.host()?.lowercased() }
    }

    var address: URL? {
        url.flatMap { URL(string: $0) }
    }

    static func site(_ title: String, _ url: URL) -> Bookmark {
        Bookmark(title: title.isEmpty ? Address.pretty(url) : title, url: url.absoluteString, children: nil)
    }

    static func folder(_ title: String, _ children: [Bookmark]) -> Bookmark {
        Bookmark(title: title, url: nil, children: children)
    }
}

@MainActor
@Observable
final class Bookmarks {

    private(set) var roots: [Bookmark] = [] {
        didSet {
            revision &+= 1
            kept = preparedKept ?? Set(Bookmarks.urls(roots).map(\.absoluteString))
            preparedKept = nil
            sites = nil
            listing = nil
        }
    }
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var preparedKept: Set<String>?

    /// Every address kept, for `contains` — asked on every redraw of the
    /// button, which fills in on a page that is kept.
    @ObservationIgnored private var kept: Set<String> = []

    init() { load() }

    var isEmpty: Bool { roots.isEmpty }

    /// How many sites, folders included.
    var count: Int { Bookmarks.count(roots) }

    nonisolated static func count(_ nodes: [Bookmark]) -> Int {
        nodes.reduce(0) { $0 + ($1.isFolder ? count($1.children ?? []) : 1) }
    }

    /// Every site in the list, in order, folders opened.
    nonisolated static func urls(_ nodes: [Bookmark]) -> [URL] {
        nodes.flatMap { node -> [URL] in
            if node.isFolder { return urls(node.children ?? []) }
            return node.url.flatMap(URL.init(string:)).map { [$0] } ?? []
        }
    }

    /// Every folder in the tree, each with how deep it sits — for "move to
    /// folder" lists, where a folder three deep should look like it.
    static func folders(_ nodes: [Bookmark], depth: Int = 0) -> [(node: Bookmark, depth: Int)] {
        nodes.flatMap { node -> [(Bookmark, Int)] in
            guard node.isFolder else { return [] }
            return [(node, depth)] + folders(node.children ?? [], depth: depth + 1)
        }
    }

    /// Every site and folder whose title or address holds all the words,
    /// with the folders it sits in — the same rule chrome.bookmarks.search
    /// keeps (see ExtensionShims.swift).
    func matches(_ text: String) -> [(node: Bookmark, path: [String])] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        func walk(_ nodes: [Bookmark], _ path: [String]) -> [(node: Bookmark, path: [String])] {
            nodes.flatMap { node -> [(node: Bookmark, path: [String])] in
                let hay = (node.title + " " + (node.url ?? "")).lowercased()
                let hit = words.allSatisfy { hay.contains($0) } ? [(node: node, path: path)] : []
                return hit + walk(node.children ?? [], path + [node.title])
            }
        }
        return walk(roots, [])
    }

    // MARK: - in the address field

    /// A site as the address field looks for it: its name and its address,
    /// lowercased once, the address without its scheme or www, as the field
    /// matches history (History.stripped).
    private struct Site {
        /// As it reads in the list.
        let name: String
        let title: String
        let address: String
        let url: URL
    }

    /// Every site, folders opened, made once after each change of the list
    /// and kept: the field asks on every key, and walking a tree of a few
    /// thousand imported bookmarks to lowercase each again was work thrown
    /// away each time.
    @ObservationIgnored private var sites: [Site]?

    /// The sites for what is typed in the address field, the best `limit`
    /// first: every word, in any order, in the name or the address. Kept to
    /// two letters and more: one letter is in nearly every name, and the
    /// field finishes a single letter only towards a site you have been to.
    func places(for typed: String, limit: Int) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        let words = needle.split(whereSeparator: \.isWhitespace).map(String.init)
        guard needle.count >= 2, let first = words.first else { return [] }
        let bare = History.stripped(needle)
        if sites == nil {
            sites = Bookmarks.sites(roots)
        }
        // The address starting with what was typed first, then the name,
        // then a word anywhere; among equals, the shorter address.
        var best: [(site: Site, score: Int)] = []
        for site in sites ?? [] {
            guard words.allSatisfy({ site.title.contains($0) || site.address.contains($0) }) else { continue }
            let score = site.address.hasPrefix(bare) ? 3
                : site.title.hasPrefix(needle) || site.title.split(separator: " ").contains(where: { $0.hasPrefix(first) }) ? 2
                : 1
            let at = best.firstIndex {
                score > $0.score || (score == $0.score && site.address.count < $0.site.address.count)
            } ?? best.endIndex
            guard at < limit else { continue }
            best.insert((site, score), at: at)
            if best.count > limit { best.removeLast() }
        }
        return best.map { found in
            Suggestion(key: Address.editable(found.site.url), title: found.site.name, url: found.site.url, kind: .bookmark)
        }
    }

    struct Listed: Equatable {
        let id: Bookmark.ID
        let title: String
        let url: URL
        let folders: [String]
        fileprivate let hay: String
    }

    @ObservationIgnored private var listing: [Listed]?

    func listed(matching typed: String, limit: Int) -> [Listed] {
        if listing == nil { listing = Bookmarks.listing(roots, []) }
        let words = FieldPlace.words(typed)
        var found: [Listed] = []
        for kept in listing ?? [] where words.allSatisfy({ kept.hay.contains($0) }) {
            found.append(kept)
            if found.count == limit { break }
        }
        return found
    }

    private static func listing(_ nodes: [Bookmark], _ folders: [String]) -> [Listed] {
        nodes.flatMap { node -> [Listed] in
            if node.isFolder { return listing(node.children ?? [], folders + [node.title]) }
            guard let url = node.address, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return [] }
            let title = node.unnamed ? "" : node.title
            let hay = ([title, History.stripped(url.absoluteString)] + folders).joined(separator: " ").lowercased()
            return [Listed(id: node.id, title: title, url: url, folders: folders, hay: hay)]
        }
    }

    private static func sites(_ nodes: [Bookmark]) -> [Site] {
        nodes.flatMap { node -> [Site] in
            if node.isFolder { return sites(node.children ?? []) }
            // Only places to go: a bookmarklet's javascript: is no address.
            guard let url = node.address, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return [] }
            let title = node.unnamed ? "" : node.title
            return [Site(name: title, title: title.lowercased(), address: History.stripped(url.absoluteString), url: url)]
        }
    }

    /// The folders `id` sits in, outermost first; empty at the top level,
    /// nil when it isn't here at all.
    func path(to id: Bookmark.ID) -> [Bookmark]? {
        func walk(_ nodes: [Bookmark], _ above: [Bookmark]) -> [Bookmark]? {
            for node in nodes {
                if node.id == id { return above }
                if let kids = node.children, let found = walk(kids, above + [node]) { return found }
            }
            return nil
        }
        return walk(roots, [])
    }

    /// The folder `id` sits in, nil at the top level.
    func parent(of id: Bookmark.ID) -> Bookmark.ID? {
        path(to: id)?.last?.id
    }

    /// The one kept for this address, wherever it is filed.
    func bookmark(for url: URL) -> Bookmark? {
        first { $0.url == url.absoluteString }
    }

    func bookmark(_ id: Bookmark.ID) -> Bookmark? {
        first { $0.id == id }
    }

    private func first(where test: (Bookmark) -> Bool) -> Bookmark? {
        func walk(_ nodes: [Bookmark]) -> Bookmark? {
            for node in nodes {
                if test(node) { return node }
                if let found = walk(node.children ?? []) { return found }
            }
            return nil
        }
        return walk(roots)
    }

    // MARK: - changing

    /// The page, at the end of the list. Nothing is asked first: the title
    /// is the page's, and the card that opens after (see BookmarkCard) is
    /// where it gets another name or a folder.
    @discardableResult
    func add(_ url: URL, title: String) -> Bookmark? {
        guard !contains(url) else { return nil }
        let made = Bookmark.site(title, url)
        roots.append(made)
        save()
        return made
    }

    func contains(_ url: URL) -> Bool {
        kept.contains(url.absoluteString)
    }

    func remove(_ id: Bookmark.ID) {
        roots = Bookmarks.prune(id, from: roots)
        save()
    }

    private static func prune(_ id: Bookmark.ID, from nodes: [Bookmark]) -> [Bookmark] {
        nodes.compactMap { node in
            if node.id == id { return nil }
            var copy = node
            if let kids = node.children { copy.children = prune(id, from: kids) }
            return copy
        }
    }

    /// Takes a bookmark or a whole folder out of wherever it currently sits
    /// and puts it in another folder — or at the top level when `folderID`
    /// is nil — at `index` among what is there, or at the end. The index is
    /// counted as the list reads before the move, so dropping a row just
    /// below itself leaves it where it was. Moving a folder into its own
    /// children is refused rather than allowed to erase it by looping it
    /// inside itself; moving it onto itself is simply nothing to do.
    func move(_ id: Bookmark.ID, into folderID: Bookmark.ID?, at index: Int? = nil) {
        guard id != folderID else { return }
        var index = index
        if let at = index, let from = siblings(of: folderID).firstIndex(where: { $0.id == id }), from < at {
            // It leaves a gap above the place it goes to.
            index = at - 1
        }
        var working = roots
        guard let node = Bookmarks.detach(id, from: &working) else { return }
        if let folderID, Bookmarks.holds(folderID, node) { return }
        guard Bookmarks.place(node, in: folderID, at: index, nodes: &working) else { return }
        roots = working
        save()
    }

    /// What a folder holds, or the top level for nil.
    private func siblings(of folderID: Bookmark.ID?) -> [Bookmark] {
        guard let folderID else { return roots }
        func walk(_ nodes: [Bookmark]) -> [Bookmark]? {
            for node in nodes {
                if node.id == folderID { return node.children ?? [] }
                if let found = walk(node.children ?? []) { return found }
            }
            return nil
        }
        return walk(roots) ?? []
    }

    private static func detach(_ id: Bookmark.ID, from nodes: inout [Bookmark]) -> Bookmark? {
        for i in nodes.indices {
            if nodes[i].id == id { return nodes.remove(at: i) }
            guard nodes[i].children != nil else { continue }
            var kids = nodes[i].children!
            if let found = detach(id, from: &kids) {
                nodes[i].children = kids
                return found
            }
        }
        return nil
    }

    /// `node` into the folder `id` (the top level for nil) at `index`,
    /// clamped to what is there, or at the end. False when there is no such
    /// folder.
    @discardableResult
    private static func place(_ node: Bookmark, in id: Bookmark.ID?, at index: Int?, nodes: inout [Bookmark]) -> Bool {
        guard let id else {
            nodes.insert(node, at: min(max(index ?? nodes.count, 0), nodes.count))
            return true
        }
        for i in nodes.indices {
            if nodes[i].id == id, nodes[i].isFolder {
                var kids = nodes[i].children ?? []
                kids.insert(node, at: min(max(index ?? kids.count, 0), kids.count))
                nodes[i].children = kids
                return true
            }
            guard var kids = nodes[i].children else { continue }
            if place(node, in: id, at: index, nodes: &kids) {
                nodes[i].children = kids
                return true
            }
        }
        return false
    }

    /// `id` is `node` itself, or somewhere inside it — also used by the
    /// outline to keep a folder out of its own "move to" list.
    static func holds(_ id: Bookmark.ID, _ node: Bookmark) -> Bool {
        node.id == id || (node.children ?? []).contains { holds(id, $0) }
    }

    /// Another browser's, kept apart in a folder of that browser's name
    /// unless there was nothing here yet. Bringing them in again adds only
    /// what is new — a page already in the same place is left as it is, a
    /// folder of the same name is gone into — and never takes away what
    /// you have added or moved since. Returns how many pages came in, and
    /// how many were already here.
    @discardableResult
    func take(_ nodes: [Bookmark], from name: String) -> (added: Int, already: Int) {
        let taken = takeNoting(nodes, from: name)
        return (taken.added, taken.already)
    }

    /// The same, and which bookmarks and folders it added — every one, so
    /// they can be taken back out exactly (see ImportRecord).
    func takeNoting(_ nodes: [Bookmark], from name: String) -> (added: Int, already: Int, ids: [Bookmark.ID]) {
        guard !nodes.isEmpty else { return (0, 0, []) }
        var added = 0, already = 0
        var ids: [Bookmark.ID] = []
        if roots.isEmpty {
            var merged: [Bookmark] = []
            Bookmarks.merge(nodes, into: &merged, added: &added, already: &already, ids: &ids)
            roots = merged
            Store.settings.set(name, forKey: Bookmarks.topKey)
        } else if intoTop(nodes, from: name) {
            Bookmarks.merge(nodes, into: &roots, added: &added, already: &already, ids: &ids)
        } else {
            var kids = roots.first { $0.isFolder && $0.title == name }?.children ?? []
            Bookmarks.merge(nodes, into: &kids, added: &added, already: &already, ids: &ids)
            if let at = roots.firstIndex(where: { $0.isFolder && $0.title == name }) {
                roots[at].children = kids
            } else {
                let folder = Bookmark.folder(name, kids)
                ids.append(folder.id)
                roots.append(folder)
            }
        }
        save()
        return (added, already, ids)
    }

    /// Prepare a potentially large file merge away from the UI thread. A live
    /// edit wins: if bookmarks changed while preparing, merge a fresh snapshot.
    func takeFile(_ incoming: [Bookmark], from name: String, control: ImportFile.Control) async throws -> (added: Int, already: Int) {
        guard !incoming.isEmpty else { return (0, 0) }
        while true {
            try control.checkCancellation()
            let snapshot = roots
            let version = revision
            let top = Store.settings.string(forKey: Bookmarks.topKey)
            let prepared: (roots: [Bookmark], kept: Set<String>, added: Int, already: Int, top: Bool) = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try control.checkCancellation()
                        var output = snapshot
                        var added = 0, already = 0
                        var setTop = false
                        if snapshot.isEmpty {
                            output = incoming
                            added = try Bookmarks.fileCount(incoming, control: control)
                            setTop = true
                        } else {
                            let intoTop: Bool
                            if let top { intoTop = top == name }
                            else {
                                let theirs = try Bookmarks.fileURLs(incoming, control: control)
                                let ours = Set(try Bookmarks.fileURLs(snapshot, control: control))
                                intoTop = !theirs.isEmpty && theirs.filter { ours.contains($0) }.count * 2 >= theirs.count
                                setTop = intoTop
                            }
                            if intoTop {
                                try Bookmarks.mergeFile(incoming, into: &output, added: &added, already: &already, control: control)
                            } else {
                                var kids = output.first { $0.isFolder && $0.title == name }?.children ?? []
                                try Bookmarks.mergeFile(incoming, into: &kids, added: &added, already: &already, control: control)
                                if let at = output.firstIndex(where: { $0.isFolder && $0.title == name }) {
                                    output[at].children = kids
                                } else {
                                    output.append(.folder(name, kids))
                                }
                            }
                        }
                        try control.checkCancellation()
                        continuation.resume(returning: (output, Set(try Bookmarks.fileURLs(output, control: control)), added, already, setTop))
                    } catch { continuation.resume(throwing: error) }
                }
            }
            try control.checkCancellation()
            guard revision == version, Store.settings.string(forKey: Bookmarks.topKey) == top else { continue }
            preparedKept = prepared.kept
            roots = prepared.roots
            if prepared.top { Store.settings.set(name, forKey: Bookmarks.topKey) }
            save()
            return (prepared.added, prepared.already)
        }
    }

    /// Takes back out what an import added: every bookmark among `ids`
    /// wherever it now sits, then every folder among them left empty. A
    /// folder of theirs that you have put something of your own in stays,
    /// with that in it. Returns how many bookmarks went.
    @discardableResult
    func withdraw(_ ids: [Bookmark.ID]) -> Int {
        let ours = Set(ids)
        var gone = 0
        func strip(_ nodes: [Bookmark]) -> [Bookmark] {
            nodes.compactMap { node in
                if !node.isFolder, ours.contains(node.id) {
                    gone += 1
                    return nil
                }
                guard let kids = node.children else { return node }
                var copy = node
                copy.children = strip(kids)
                if ours.contains(node.id), copy.children?.isEmpty == true { return nil }
                return copy
            }
        }
        roots = strip(roots)
        save()
        return gone
    }

    /// Every id in a tree, folders and all.
    nonisolated private static func ids(_ nodes: [Bookmark]) -> [Bookmark.ID] {
        nodes.flatMap { [$0.id] + ids($0.children ?? []) }
    }

    nonisolated private static func fileURLs(_ nodes: [Bookmark], control: ImportFile.Control) throws -> [String] {
        var urls: [String] = []
        var pending = nodes
        var scanned = 0
        while let node = pending.popLast() {
            scanned += 1
            if scanned % 256 == 0 {
                try control.checkCancellation()
            }
            if let url = node.url, let canonical = URL(string: url)?.absoluteString { urls.append(canonical) }
            if let children = node.children { pending.append(contentsOf: children) }
        }
        try control.checkCancellation()
        return urls
    }

    nonisolated private static func fileCount(_ nodes: [Bookmark], control: ImportFile.Control) throws -> Int {
        var count = 0
        var scanned = 0
        var pending = nodes
        while let node = pending.popLast() {
            scanned += 1
            if scanned % 256 == 0 { try control.checkCancellation() }
            if node.isFolder { pending.append(contentsOf: node.children ?? []) }
            else { count += 1 }
        }
        try control.checkCancellation()
        return count
    }

    nonisolated private static func mergeFile(_ incoming: [Bookmark], into nodes: inout [Bookmark], added: inout Int, already: inout Int, control: ImportFile.Control) throws {
        var folders: [String: Int] = [:]
        var pages = Set<String>()
        for (index, node) in nodes.enumerated() {
            if index % 256 == 0 { try control.checkCancellation() }
            if node.isFolder { if folders[node.title] == nil { folders[node.title] = index } }
            else if let url = node.url { pages.insert(url) }
        }
        for (index, node) in incoming.enumerated() {
            if index % 256 == 0 {
                try control.checkCancellation()
            }
            if node.isFolder {
                if let at = folders[node.title] {
                    var kids = nodes[at].children ?? []
                    try mergeFile(node.children ?? [], into: &kids, added: &added, already: &already, control: control)
                    nodes[at].children = kids
                } else {
                    folders[node.title] = nodes.count
                    nodes.append(node)
                    added += try Bookmarks.fileCount([node], control: control)
                }
            } else if pages.contains(node.url ?? "") {
                already += 1
            } else {
                if let url = node.url { pages.insert(url) }
                nodes.append(node)
                added += 1
            }
        }
    }

    /// Which browser filled the empty top level, the first time.
    private static let topKey = "bookmarks.top"

    /// Whether this browser's bookmarks belong at the top level: it filled
    /// it the first time — or, from before that was noted, most of its
    /// pages are already there.
    private func intoTop(_ nodes: [Bookmark], from name: String) -> Bool {
        if let top = Store.settings.string(forKey: Bookmarks.topKey) { return top == name }
        let theirs = Bookmarks.urls(nodes).map(\.absoluteString)
        guard !theirs.isEmpty else { return false }
        let ours = Set(Bookmarks.urls(roots).map(\.absoluteString))
        let shared = theirs.filter { ours.contains($0) }.count
        guard shared * 2 >= theirs.count else { return false }
        Store.settings.set(name, forKey: Bookmarks.topKey)
        return true
    }

    /// `incoming` into `nodes`, level by level: a folder into the folder of
    /// the same name, a page only if the same address isn't already at
    /// that level.
    nonisolated private static func merge(_ incoming: [Bookmark], into nodes: inout [Bookmark], added: inout Int, already: inout Int, ids: inout [Bookmark.ID]) {
        var folders: [String: Int] = [:]
        for (index, node) in nodes.enumerated() where node.isFolder {
            if folders[node.title] == nil { folders[node.title] = index }
        }
        var pages = Set(nodes.compactMap { $0.isFolder ? nil : $0.url })
        for node in incoming {
            if node.isFolder {
                if let at = folders[node.title] {
                    var kids = nodes[at].children ?? []
                    merge(node.children ?? [], into: &kids, added: &added, already: &already, ids: &ids)
                    nodes[at].children = kids
                } else {
                    folders[node.title] = nodes.count
                    nodes.append(node)
                    added += count([node])
                    ids += Bookmarks.ids([node])
                }
            } else if pages.contains(node.url ?? "") {
                already += 1
            } else {
                if let url = node.url { pages.insert(url) }
                nodes.append(node)
                added += 1
                ids.append(node.id)
            }
        }
    }

    // MARK: - the file

    private var file: URL { Store.file("bookmarks.json") }

    // MARK: - for extensions

    /// A page or a folder filed under `parent` at `index`, or at the top
    /// level for nil or a folder that isn't there. What
    /// chrome.bookmarks.create does.
    @discardableResult
    func insert(_ node: Bookmark, into parent: Bookmark.ID?, at index: Int? = nil) -> Bookmark {
        var nodes = roots
        if !Bookmarks.place(node, in: parent, at: index, nodes: &nodes) {
            Bookmarks.place(node, in: nil, at: index, nodes: &nodes)
        }
        roots = nodes
        save()
        return node
    }

    /// A folder of your own, its name asked for as a rename's is: inside
    /// `parent`, or at the top level for nil. An empty name makes none.
    func askNewFolder(in parent: Bookmark.ID?, made: @escaping (Bookmark.ID) -> Void = { _ in }) {
        Ask.name("New Folder", placeholder: "Folder name", confirm: "Create") { name in
            made(self.insert(.folder(name, []), into: parent).id)
        }
    }

    /// A folder with bookmarks in it asks first: they all go with it, and
    /// there is no taking it back. Anything else goes at once.
    func askRemove(_ node: Bookmark) {
        guard node.isFolder, let kids = node.children, !kids.isEmpty else { return remove(node.id) }
        let count = Bookmarks.count(kids)
        let detail = switch count {
        case 0: "The empty folders in it go too"
        case 1: "The bookmark in it goes too"
        default: "The \(count) bookmarks in it go too"
        }
        Ask.sure("Remove \u{201C}\(node.title)\u{201D}?", detail: detail, confirm: "Remove") {
            self.remove(node.id)
        }
    }

    /// A name of your own for a bookmark or a folder, asked for the way a
    /// space's is: the page's title is what a bookmark starts with, and a
    /// folder brought in from another browser is called after it. The name
    /// it has arrives in the field. An empty one changes nothing for a
    /// folder; a bookmark left without one is its icon alone on the bar.
    func askRename(_ node: Bookmark) {
        if node.isFolder {
            Ask.name("Rename Folder", placeholder: node.title, initial: node.title, confirm: "Rename") {
                self.update(node.id, title: $0, url: nil)
            }
        } else {
            Ask.name("Rename Bookmark", detail: "Without a name, the bookmarks bar shows its icon alone",
                     placeholder: node.label, initial: node.title, confirm: "Rename", empty: true) {
                self.update(node.id, title: $0, url: nil)
            }
        }
    }

    /// A bookmark's address, changed by hand and read the way the address
    /// field reads what is typed. What that refuses, a bookmarklet or a
    /// word, isn't saved: the question comes back with it in the field and a
    /// line on why, and Cancel keeps the address the bookmark had.
    func askAddress(_ node: Bookmark, typed: String? = nil) {
        guard let current = node.url else { return }
        let detail = typed.map { "Broadway can't open \u{201C}\($0)\u{201D} as a page. Cancel keeps the address the bookmark has." }
        Ask.name("Edit Address", detail: detail, placeholder: "https://example.com", initial: typed ?? current, confirm: "Save") { typed in
            guard let url = Address.url(from: typed) else {
                DispatchQueue.main.async { self.askAddress(node, typed: typed) }
                return
            }
            self.update(node.id, title: nil, url: url.absoluteString)
        }
    }

    /// A new title or address for one that is kept. chrome.bookmarks.update,
    /// and Rename… in the list's right-click menu.
    func update(_ id: Bookmark.ID, title: String?, url: String?) {
        func walk(_ nodes: inout [Bookmark]) -> Bool {
            for i in nodes.indices {
                if nodes[i].id == id {
                    if let title { nodes[i].title = title }
                    if let url, !nodes[i].isFolder { nodes[i].url = url }
                    return true
                }
                guard var kids = nodes[i].children else { continue }
                if walk(&kids) {
                    nodes[i].children = kids
                    return true
                }
            }
            return false
        }
        var nodes = roots
        if walk(&nodes) {
            roots = nodes
            save()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Bookmark].self, from: data) else {
            Store.quarantine(file)
            return
        }
        roots = list
    }

    private func save() {
        let snapshot = roots
        // One after another, the newest last (see Disk).
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}

final class BookmarkMarkView: NSView {
    let size: CGFloat
    private let tile = KitBox(fill: nil)
    private let plate = KitBox(fill: nil)
    private let letterLabel: KitLabel
    private let art = BookmarkArt()
    private var folder: KitSymbol?

    init(size: CGFloat, folderSymbol: CGFloat? = nil) {
        self.size = size
        letterLabel = KitLabel("", font: .systemFont(ofSize: size * 0.56, weight: .medium), color: KitColor.muted)
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        letterLabel.alignment = .center
        letterLabel.setAccessibilityElement(false)
        tile.corners = .radius(size * 0.22)
        tile.fill = KitColor.ink.withAlphaComponent(0.06)
        plate.corners = .radius(size * 0.32)
        art.wantsLayer = true
        art.layer?.cornerCurve = .continuous
        art.layer?.cornerRadius = size * 0.22
        art.layer?.masksToBounds = true
        for view in [plate, tile, letterLabel, art] as [NSView] { addSubview(view) }
        if let folderSymbol {
            let glyph = KitSymbol("folder.fill", style: .init(size: folderSymbol), tint: KitColor.muted)
            addSubview(glyph)
            folder = glyph
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(icon: NSImage?, letter: String) {
        letterLabel.text = letter
        art.icon = icon
        letterLabel.isHidden = icon != nil
        tile.isHidden = icon != nil
        art.isHidden = icon == nil
        paintPlate()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintPlate()
    }

    private func paintPlate() {
        guard let icon = art.icon, !icon.isTemplate else { plate.fill = nil; return }
        plate.fill = PinTint.of(icon).backing(dark: kitDark)
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: 0, y: 0, width: size, height: size)
        tile.frame = box
        plate.frame = box.insetBy(dx: -size * 0.14, dy: -size * 0.14)
        letterLabel.frame = box
        art.frame = box
        if let folder {
            let natural = folder.intrinsicContentSize
            folder.frame = NSRect(x: ((size - natural.width) / 2).rounded(.toNearestOrAwayFromZero), y: ((size - natural.height) / 2).rounded(.down),
                                  width: natural.width, height: natural.height)
        }
    }
}

private final class BookmarkArt: NSView {
    var icon: NSImage? { didSet { if icon !== oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon, let context = NSGraphicsContext.current else { return }
        context.imageInterpolation = .high
        let natural = icon.size
        let side = bounds.width
        if icon.isTemplate {
            let inset = bounds.insetBy(dx: side * 0.06, dy: side * 0.06)
            let scale = min(inset.width / max(natural.width, 0.01), inset.height / max(natural.height, 0.01))
            let fitted = NSSize(width: natural.width * scale, height: natural.height * scale)
            let rect = NSRect(x: inset.midX - fitted.width / 2, y: inset.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
            context.saveGraphicsState()
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            KitColor.ink.kitResolved(dark: kitDark).withAlphaComponent(0.75).setFill()
            rect.fill(using: .sourceAtop)
            context.restoreGraphicsState()
        } else {
            let scale = max(side / max(natural.width, 0.01), side / max(natural.height, 0.01))
            let filled = NSSize(width: natural.width * scale, height: natural.height * scale)
            icon.draw(in: NSRect(x: bounds.midX - filled.width / 2, y: bounds.midY - filled.height / 2, width: filled.width, height: filled.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }
}

enum BookmarkWords {
    static func fitted(_ text: String, font: NSFont, in width: CGFloat) -> String {
        func measure(_ string: String) -> CGFloat { ceil((string as NSString).size(withAttributes: [.font: font]).width) }
        guard measure(text) > width else { return text }
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        while words.count > 1 {
            words.removeLast()
            let candidate = words.joined(separator: " ").trimmingCharacters(in: .whitespaces) + "\u{2026}"
            if measure(candidate) <= width { return candidate }
        }
        return text
    }
}

final class BookmarkOutlineView: KitFlippedView, NSDraggingSource {
    enum Zone { case before, into, after }

    struct Aim: Equatable {
        let id: Bookmark.ID?
        let zone: Zone
    }

    fileprivate enum Entry {
        case node(Bookmark, depth: Int, parent: Bookmark.ID?, index: Int, open: Bool)
        case hint(folder: Bookmark.ID, depth: Int)

        var key: String {
            switch self {
            case .node(let node, _, _, _, _): return node.id.uuidString
            case .hint(let folder, _): return "hint-" + folder.uuidString
            }
        }
    }

    static let rowHeight: CGFloat = 27
    static let spacing: CGFloat = 1
    static let endHeight: CGFloat = 10
    static let hintHeight: CGFloat = ceil(NSFont.systemFont(ofSize: 12).boundingRectForFont.height) + 10

    let bookmarks: Bookmarks
    var expanded: Set<Bookmark.ID> { didSet { if expanded != oldValue { changed() } } }
    var shown: Bookmark.ID? { didSet { if shown != oldValue { needsLayout = true } } }
    var open: (URL) -> Void
    var openInNewTab: (URL) -> Void
    var onExpand: ((Set<Bookmark.ID>) -> Void)?
    var onResize: (() -> Void)?

    private(set) var dragging: Bookmark.ID? { didSet { if dragging != oldValue { changed() } } }
    private(set) var aimed: Aim? { didSet { if aimed != oldValue { needsLayout = true } } }
    private var spring: DispatchWorkItem?
    private var entries: [Entry] = []
    private var frames: [String: NSRect] = [:]
    private var rows: [String: BookmarkOutlineRow] = [:]
    private var hints: [String: BookmarkOutlineHint] = [:]
    private let line = KitBox(fill: KitColor.ink.withAlphaComponent(0.55), corners: .capsule)
    private var watch: AnyCancellable?
    private var animateNext = false
    private var laidOut = false

    static let pasteboard = NSPasteboard.PasteboardType(InternalDrag.bookmark.identifier)

    init(bookmarks: Bookmarks, expanded: Set<Bookmark.ID> = [], shown: Bookmark.ID? = nil,
         open: @escaping (URL) -> Void, openInNewTab: @escaping (URL) -> Void) {
        self.bookmarks = bookmarks
        self.expanded = expanded
        self.shown = shown
        self.open = open
        self.openInNewTab = openInNewTab
        super.init(frame: .zero)
        wantsLayer = true
        line.isHidden = true
        addSubview(line)
        registerForDraggedTypes([Self.pasteboard])
        watch = kitObserve(initial: false, { [weak bookmarks] in bookmarks?.roots }) { [weak self] _ in self?.changed() }
        entries = flatten()
        setAccessibilityElement(true)
        setAccessibilityRole(.outline)
        setAccessibilityLabel("Bookmarks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height(of: flatten(), dragging: dragging != nil))
    }

    func fittingHeight() -> CGFloat { Self.height(of: flatten(), dragging: dragging != nil) }

    private static func height(of entries: [Entry], dragging: Bool) -> CGFloat {
        var total: CGFloat = 0
        for (i, entry) in entries.enumerated() {
            if i > 0 { total += spacing }
            if case .hint = entry { total += hintHeight } else { total += rowHeight }
        }
        if dragging { total += (entries.isEmpty ? 0 : spacing) + endHeight }
        return total
    }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        onResize?()
    }

    private func flatten() -> [Entry] {
        var out: [Entry] = []
        func walk(_ nodes: [Bookmark], _ depth: Int, _ parent: Bookmark.ID?) {
            for (index, node) in nodes.enumerated() {
                let isOpen = node.isFolder && expanded.contains(node.id)
                out.append(.node(node, depth: depth, parent: parent, index: index, open: isOpen))
                guard isOpen else { continue }
                if let kids = node.children, !kids.isEmpty { walk(kids, depth + 1, node.id) }
                else { out.append(.hint(folder: node.id, depth: depth)) }
            }
        }
        walk(bookmarks.roots, 0, nil)
        return out
    }

    override func layout() {
        super.layout()
        entries = flatten()
        let animate = animateNext && laidOut && !Motion.reduced
        animateNext = false
        let arrows = bookmarks.roots.contains(where: \.isFolder)
        let folders = Bookmarks.folders(bookmarks.roots)
        var seen = Set<String>()
        var y: CGFloat = 0
        frames = [:]
        for (i, entry) in entries.enumerated() {
            if i > 0 { y += Self.spacing }
            let key = entry.key
            seen.insert(key)
            switch entry {
            case let .node(node, depth, _, _, isOpen):
                let frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
                frames[key] = frame
                let made = rows[key] == nil
                let row = rows[key] ?? BookmarkOutlineRow(outline: self)
                if made {
                    rows[key] = row
                    addSubview(row, positioned: .below, relativeTo: line)
                }
                row.show(node: node, depth: depth, arrows: arrows, isOpen: isOpen, animate: animate && !made,
                         dragging: dragging == node.id, washed: aimed == Aim(id: node.id, zone: .into) || shown == node.id,
                         targets: folders.filter { !Bookmarks.holds($0.node.id, node) })
                place(row, frame, made: made, animate: animate)
                y += Self.rowHeight
            case let .hint(folder, depth):
                let frame = NSRect(x: 0, y: y, width: bounds.width, height: Self.hintHeight)
                frames[key] = frame
                let made = hints[key] == nil
                let hint = hints[key] ?? BookmarkOutlineHint()
                if made {
                    hints[key] = hint
                    addSubview(hint, positioned: .below, relativeTo: line)
                }
                hint.folder = folder
                hint.depth = depth
                place(hint, frame, made: made, animate: animate)
                y += Self.hintHeight
            }
        }
        for (key, row) in rows where !seen.contains(key) {
            row.removeFromSuperview()
            rows[key] = nil
        }
        for (key, hint) in hints where !seen.contains(key) {
            hint.removeFromSuperview()
            hints[key] = nil
        }
        if dragging != nil {
            frames["end"] = NSRect(x: 0, y: y + (entries.isEmpty ? 0 : Self.spacing), width: bounds.width, height: Self.endHeight)
        }
        placeLine()
        laidOut = true
    }

    private func place(_ view: NSView, _ frame: NSRect, made: Bool, animate: Bool) {
        let old = view.frame
        view.frame = frame
        guard animate, let layer = view.layer else { return }
        if made {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "arrive")
        } else if old.minY != frame.minY, old.height > 0,
                  let move = Motion.kitSettle.animation("transform.translation.y", from: old.minY - frame.minY, to: 0) as? CAPropertyAnimation {
            move.isAdditive = true
            layer.add(move, forKey: "move")
        }
    }

    func rect(of id: Bookmark.ID) -> NSRect? { frames[id.uuidString] }

    private func placeLine() {
        guard let aimed, aimed.zone != .into else {
            line.isHidden = true
            return
        }
        let depth: Int
        let y: CGFloat
        if let id = aimed.id, let frame = frames[id.uuidString], let entry = entries.first(where: { $0.key == id.uuidString }),
           case let .node(_, nodeDepth, _, _, isOpen) = entry {
            depth = aimed.zone == .after && isOpen ? nodeDepth + 1 : nodeDepth
            y = aimed.zone == .before ? frame.minY - 1.5 : frame.maxY - 0.5
        } else if aimed.id == nil, let end = frames["end"] {
            depth = 0
            y = end.minY
        } else {
            line.isHidden = true
            return
        }
        let x = CGFloat(depth) * 18 + 10
        line.frame = NSRect(x: x, y: y, width: max(0, bounds.width - x - 10), height: 2)
        line.isHidden = false
    }

    func toggle(_ id: Bookmark.ID) {
        animateNext = true
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        onExpand?(expanded)
    }

    fileprivate func activate(_ node: Bookmark) {
        if node.isFolder { toggle(node.id) }
        else if let text = node.url, let url = URL(string: text) { open(url) }
    }

    fileprivate func middle(_ node: Bookmark) {
        guard let url = node.url.flatMap(URL.init(string:)) else { return }
        openInNewTab(url)
    }

    fileprivate func menu(for node: Bookmark, targets: [(node: Bookmark, depth: Int)]) -> NSMenu {
        var items: [KitMenuItem] = []
        if !node.isFolder, let url = node.url.flatMap(URL.init(string:)) {
            items += [.action("Open", run: { [weak self] in self?.open(url) }), .separator]
        }
        items.append(.action("Rename\u{2026}", run: { [bookmarks] in bookmarks.askRename(node) }))
        if node.isFolder {
            items.append(.action("New Folder Inside\u{2026}", run: { [weak self, bookmarks] in
                bookmarks.askNewFolder(in: node.id) { _ in
                    guard let self else { return }
                    self.expanded.insert(node.id)
                    self.onExpand?(self.expanded)
                }
            }))
        }
        var moves: [KitMenuItem] = [.action("Top Level", run: { [bookmarks] in bookmarks.move(node.id, into: nil) })]
        if !targets.isEmpty {
            moves.append(.separator)
            moves += targets.map { target in
                .action(String(repeating: "   ", count: target.depth) + target.node.title, run: { [bookmarks] in
                    bookmarks.move(node.id, into: target.node.id)
                })
            }
        }
        items += [.submenu("Move To", moves), .separator, .action("Remove", run: { [bookmarks] in bookmarks.askRemove(node) })]
        return KitMenu.make(items)
    }

    fileprivate func startDrag(_ node: Bookmark, from row: NSView, event: NSEvent) {
        let item = NSPasteboardItem()
        item.setData(Data(node.id.uuidString.utf8), forType: Self.pasteboard)
        let dragged = NSDraggingItem(pasteboardWriter: item)
        let picture = NSImage(size: row.bounds.size)
        if let rep = row.bitmapImageRepForCachingDisplay(in: row.bounds) {
            row.cacheDisplay(in: row.bounds, to: rep)
            picture.addRepresentation(rep)
        }
        dragged.setDraggingFrame(row.bounds, contents: picture)
        dragging = node.id
        row.beginDraggingSession(with: [dragged], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        settle()
    }

    private func settle() {
        spring?.cancel()
        spring = nil
        aimed = nil
        dragging = nil
    }

    private func allows(_ target: Bookmark.ID) -> Bool {
        guard let dragging else { return true }
        return target != dragging && !(bookmarks.path(to: target) ?? []).contains { $0.id == dragging }
    }

    private struct Landing {
        let aim: Aim
        let allowed: Bool
        let move: (Bookmark.ID) -> Void
    }

    private func landing(at point: NSPoint) -> Landing? {
        for entry in entries {
            guard let frame = frames[entry.key], point.y >= frame.minY - Self.spacing, point.y < frame.maxY else { continue }
            switch entry {
            case let .node(node, _, parent, index, isOpen):
                let part = (point.y - frame.minY) / max(frame.height, 1)
                let zone: Zone = node.isFolder ? (part < 0.25 ? .before : part > 0.75 ? .after : .into) : (part < 0.5 ? .before : .after)
                return Landing(aim: Aim(id: node.id, zone: zone), allowed: allows(node.id)) { [bookmarks] id in
                    switch zone {
                    case .before: bookmarks.move(id, into: parent, at: index)
                    case .after where isOpen: bookmarks.move(id, into: node.id, at: 0)
                    case .after: bookmarks.move(id, into: parent, at: index + 1)
                    case .into: bookmarks.move(id, into: node.id)
                    }
                }
            case let .hint(folder, _):
                return Landing(aim: Aim(id: folder, zone: .after), allowed: allows(folder)) { [bookmarks] id in
                    bookmarks.move(id, into: folder)
                }
            }
        }
        if let end = frames["end"], point.y >= end.minY - Self.spacing, point.y < end.maxY {
            return Landing(aim: Aim(id: nil, zone: .after), allowed: true) { [bookmarks] id in bookmarks.move(id, into: nil) }
        }
        return nil
    }

    private func aim(_ target: Aim?) {
        guard target != aimed else { return }
        aimed = target
        spring?.cancel()
        spring = nil
        guard let target, target.zone == .into, let id = target.id, !expanded.contains(id) else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.animateNext = true
            self.expanded.insert(id)
            self.onExpand?(self.expanded)
        }
        spring = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        guard let landing = landing(at: point) else {
            aim(nil)
            return []
        }
        guard landing.allowed else {
            aim(nil)
            return []
        }
        aim(landing.aim)
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { aim(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        aim(nil)
        guard let landing = landing(at: point), landing.allowed,
              let data = sender.draggingPasteboard.data(forType: Self.pasteboard),
              let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return false }
        animateNext = true
        landing.move(id)
        dragging = nil
        return true
    }
}

final class BookmarkOutlineRow: KitHoverView {
    private weak var outline: BookmarkOutlineView?
    private(set) var node: Bookmark?
    private var targets: [(node: Bookmark, depth: Int)] = []
    private var depth = 0
    private var arrows = false
    private var isOpen = false
    private var washed = false
    private var faded = false

    private let ground = KitBox(fill: nil, corners: .radius(8))
    private let chevron = KitSymbol("chevron.right", style: .init(size: 9, weight: .semibold), tint: KitColor.faint)
    private let siteMark = BookmarkMarkView(size: 15)
    private let folderMark = BookmarkMarkView(size: 15, folderSymbol: 9)
    private let title = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.ink)
    private let count = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.faint)
    private var down: NSPoint?

    init(outline: BookmarkOutlineView) {
        self.outline = outline
        super.init(frame: .zero)
        wantsLayer = true
        for view in [ground, chevron, siteMark, folderMark, title, count] as [NSView] { addSubview(view) }
        chevron.wantsLayer = true
        title.setAccessibilityElement(false)
        count.setAccessibilityElement(false)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(node: Bookmark, depth: Int, arrows: Bool, isOpen: Bool, animate: Bool, dragging: Bool, washed: Bool,
              targets: [(node: Bookmark, depth: Int)]) {
        let turned = self.isOpen != isOpen
        self.node = node
        self.depth = depth
        self.arrows = arrows
        self.isOpen = isOpen
        self.targets = targets
        title.text = node.label
        title.color = node.unnamed ? KitColor.muted : KitColor.ink
        let kids = node.children ?? []
        count.text = node.isFolder && !kids.isEmpty ? "\(Bookmarks.count(kids))" : ""
        count.isHidden = count.text.isEmpty
        chevron.isHidden = !node.isFolder
        folderMark.isHidden = !node.isFolder
        siteMark.isHidden = node.isFolder
        if !node.isFolder {
            siteMark.show(icon: Favicons.shared.cached(for: node.address), letter: String((node.host ?? "\u{2022}").prefix(1)).uppercased())
        }
        if turned || chevron.layer?.animation(forKey: "turn") == nil {
            let angle = isOpen ? CGFloat.pi / 2 : 0
            chevron.layer?.kitAnimate("transform", to: NSValue(caTransform3D: turn(angle)), curve: turned && animate ? Motion.kitSettle : .none, key: "turn")
        }
        if self.washed != washed {
            self.washed = washed
            paint(curve: Motion.kitSettle)
        }
        if faded != dragging {
            faded = dragging
            layer?.kitAnimate("opacity", to: dragging ? 0.35 : 1, curve: Motion.kitQuick, key: "fade")
        }
        kitAccess(label: node.label, role: node.isFolder ? .disclosureTriangle : .button)
        setAccessibilityValue(node.isFolder ? (isOpen ? "open" : "closed") : node.url)
        needsLayout = true
    }

    private func turn(_ angle: CGFloat) -> CATransform3D {
        let size = chevron.bounds.size
        let centre = CATransform3DMakeTranslation(size.width / 2, size.height / 2 + (angle == 0 ? 0 : 0.5), 0)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                       CATransform3DMakeRotation(angle, 0, 0, 1)), centre)
    }

    override func hoverChanged() { paint(curve: Motion.kitQuick) }

    private func paint(curve: KitCurve) {
        let wanted: NSColor? = washed ? Palette.NS.hover : hovering ? Palette.NS.wash : nil
        guard wanted != ground.fill else { return }
        ground.layer?.kitTransition(curve)
        ground.fill = wanted
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        guard let node else { return }
        let h = bounds.height
        var x = CGFloat(depth) * 18 + 10
        func centred(_ height: CGFloat) -> CGFloat { (h - height) / 2 }
        if node.isFolder {
            let natural = chevron.intrinsicContentSize
            chevron.frame = kitSnap(NSRect(x: x + (10 - natural.width) / 2, y: centred(natural.height), width: natural.width, height: natural.height))
            if chevron.layer?.animation(forKey: "turn") == nil {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                chevron.layer?.transform = turn(isOpen ? CGFloat.pi / 2 : 0)
                CATransaction.commit()
            }
            x += 18
            folderMark.frame = kitSnap(NSRect(x: x, y: centred(15), width: 15, height: 15))
        } else {
            if arrows { x += 18 }
            siteMark.frame = kitSnap(NSRect(x: x, y: centred(15), width: 15, height: 15))
        }
        x += 15 + 8
        let right = bounds.width - 10
        var titleRight = right - 16
        if !count.isHidden {
            let size = count.intrinsicContentSize
            count.frame = kitSnap(NSRect(x: right - size.width, y: centred(size.height), width: size.width, height: size.height))
            titleRight = right - size.width - 24
        }
        title.text = BookmarkWords.fitted(node.label, font: title.font, in: max(0, titleRight - x))
        let size = title.intrinsicContentSize
        title.frame = kitSnap(NSRect(x: x, y: centred(size.height), width: max(0, min(size.width, titleRight - x)), height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        down = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down, let node, let outline else { return }
        let here = convert(event.locationInWindow, from: nil)
        guard hypot(here.x - start.x, here.y - start.y) > 3 else { return }
        down = nil
        outline.startDrag(node, from: self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard down != nil, let node else { return }
        down = nil
        outline?.activate(node)
    }

    private var middleDown = false

    override func otherMouseDown(with event: NSEvent) {
        middleDown = event.buttonNumber == 2
    }

    override func otherMouseUp(with event: NSEvent) {
        guard middleDown, event.buttonNumber == 2, let node else { return }
        middleDown = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { outline?.middle(node) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let node, let outline else { return nil }
        return outline.menu(for: node, targets: targets)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let node else { return false }
        outline?.activate(node)
        return true
    }
}

final class BookmarkOutlineHint: KitFlippedView {
    var folder: Bookmark.ID?
    var depth = 0 { didSet { if depth != oldValue { needsLayout = true } } }
    private let label = KitLabel("Nothing in here yet", font: .systemFont(ofSize: 12), color: KitColor.faint)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        let x = CGFloat(depth + 1) * 18 + 26
        label.frame = kitSnap(NSRect(x: x, y: 5, width: max(0, min(size.width, bounds.width - x)), height: size.height))
    }
}

final class BookmarkScroll: NSScrollView {
    let inner: NSView
    let insets: NSEdgeInsets
    private let document = KitFlippedView()

    init(_ inner: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero, indicators: Bool = true) {
        self.inner = inner
        self.insets = insets
        super.init(frame: .zero)
        hasVerticalScroller = indicators
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        scrollerStyle = .overlay
        drawsBackground = false
        contentView.drawsBackground = false
        automaticallyAdjustsContentInsets = false
        documentView = document
        document.addSubview(inner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var contentHeight: CGFloat { inner.intrinsicContentSize.height + insets.top + insets.bottom }

    override func layout() {
        super.layout()
        let width = contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: width, height: max(contentHeight, contentSize.height))
        inner.frame = NSRect(x: insets.left, y: insets.top, width: max(0, width - insets.left - insets.right),
                             height: inner.intrinsicContentSize.height)
    }

    func reveal(_ rect: NSRect, animated: Bool) {
        let inDocument = inner.convert(rect, to: document)
        let visible = contentSize.height
        let top = min(max(0, inDocument.midY - visible / 2), max(0, document.frame.height - visible))
        let target = NSPoint(x: 0, y: top)
        if animated, !Motion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                contentView.animator().setBoundsOrigin(target)
            } completionHandler: { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated { self.reflectScrolledClipView(self.contentView) }
            }
        } else {
            contentView.setBoundsOrigin(target)
            reflectScrolledClipView(contentView)
        }
    }
}

@MainActor
final class BookmarksDropdown: NSObject, NSMenuDelegate {
    let browser: Browser
    let bookmarks: Bookmarks
    let menu = NSMenu(title: "Bookmarks")
    private var folders: [ObjectIdentifier: [Bookmark]] = [:]

    init(browser: Browser, bookmarks: Bookmarks) {
        self.browser = browser
        self.bookmarks = bookmarks
        super.init()
        menu.autoenablesItems = false
        build()
    }

    static func lone(_ roots: [Bookmark]) -> Bookmark? {
        guard roots.count == 1, let only = roots.first, only.isFolder else { return nil }
        return only
    }

    private func build() {
        let roots = bookmarks.roots
        if roots.isEmpty {
            let none = NSMenuItem(title: "No bookmarks yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else if let lone = Self.lone(roots) {
            menu.addItem(.sectionHeader(title: lone.title))
            fill(menu, with: lone.children ?? [])
        } else {
            fill(menu, with: roots)
        }
        menu.addItem(.separator())
        let kept = browser.pageKept
        let browser = browser
        menu.addItem(action(kept ? "Edit This Bookmark\u{2026}" : "Add This Page", symbol: kept ? "bookmark.fill" : "bookmark",
                            key: "bookmarks.add", id: "bookmarks.add") { browser.bookmarkCurrent() })
        menu.addItem(action("Manage Bookmarks", symbol: nil, key: "bookmarks.show", id: "bookmarks.manage") {
            browser.bookmarking = true
        })
    }

    private func action(_ title: String, symbol: String?, key: String, id: String, run: @escaping () -> Void) -> NSMenuItem {
        let item = KitMenuAction(title, key: "") { DispatchQueue.main.async(execute: run) }
        if let made = ShortcutStore.shared.key(for: key)?.menuKey {
            item.keyEquivalent = made.key
            item.keyEquivalentModifierMask = made.mask
        }
        if let symbol { item.image = KitGlyph.plain(symbol) }
        item.setAccessibilityIdentifier(id)
        return item
    }

    private func fill(_ menu: NSMenu, with nodes: [Bookmark]) {
        if nodes.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for node in nodes {
            if node.isFolder {
                let item = NSMenuItem(title: KitMenu.middle(node.title, limit: 60), action: nil, keyEquivalent: "")
                item.image = KitGlyph.plain("folder")
                let sub = NSMenu(title: node.title)
                sub.autoenablesItems = false
                sub.delegate = self
                folders[ObjectIdentifier(sub)] = node.children ?? []
                item.submenu = sub
                menu.addItem(item)
            } else if let url = node.address {
                let title = KitMenu.middle(node.label, limit: 60)
                let image = Self.image(node)
                let browser = browser
                let open = KitMenuAction(title, key: "") { DispatchQueue.main.async { browser.pickBookmark(url) } }
                open.keyEquivalentModifierMask = []
                open.image = image
                open.toolTip = node.url
                menu.addItem(open)
                let tab = KitMenuAction("Open \u{201C}\(KitMenu.middle(node.label, limit: 48))\u{201D} in New Tab", key: "") {
                    DispatchQueue.main.async { browser.pickBookmark(url, inNewTab: true) }
                }
                tab.keyEquivalentModifierMask = .command
                tab.isAlternate = true
                tab.image = image
                menu.addItem(tab)
            }
        }
    }

    static func image(_ node: Bookmark) -> NSImage {
        if let icon = Favicons.shared.cached(for: node.address) {
            let small = icon.copy() as? NSImage ?? icon
            small.size = NSSize(width: 16, height: 16)
            return small
        }
        return BookmarkMenu.letter(String((node.host ?? "\u{2022}").prefix(1)).uppercased())
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kids = folders.removeValue(forKey: ObjectIdentifier(menu)) else { return }
        menu.removeAllItems()
        fill(menu, with: kids)
    }

    func fillAll(_ menu: NSMenu? = nil) {
        for item in (menu ?? self.menu).items {
            guard let sub = item.submenu else { continue }
            menuNeedsUpdate(sub)
            fillAll(sub)
        }
    }
}

enum BookmarkTrack {
    static let rest = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.055)
    }
    static let lit = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.105) : NSColor(white: 0, alpha: 0.085)
    }
    static let group = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.025)
    }
}

final class BookmarkNameField: KitHoverView, NSTextFieldDelegate {
    let field = NSTextField()
    var onChange: ((String) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    private let ground = KitBox(fill: BookmarkTrack.rest, corners: .radius(SurfaceLook.fieldCorner))
    private var focused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = SurfaceLook.fieldFont
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(ground)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: SurfaceLook.field) }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let height = field.intrinsicContentSize.height
        let lead = SurfaceLook.fieldLead
        field.frame = NSRect(x: lead, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - lead * 2), height: height)
        let now = window?.firstResponder === field.currentEditor() && field.currentEditor() != nil
        if now != focused {
            focused = now
            paint()
        }
    }

    override func hoverChanged() { paint() }

    func controlTextDidBeginEditing(_ obj: Notification) {
        focused = true
        paint()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        focused = false
        paint()
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let onSubmit {
            onSubmit()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)), let onCancel {
            onCancel()
            return true
        }
        return false
    }

    private func paint() {
        let wanted = focused || hovering ? BookmarkTrack.lit : BookmarkTrack.rest
        guard wanted !== ground.fill else { return }
        ground.layer?.kitTransition(Motion.kitQuick)
        ground.fill = wanted
    }
}

final class BookmarkFolderPicker: KitHoverView {
    var title = "" { didSet { if title != oldValue { label.text = title; setAccessibilityValue(title); needsLayout = true } } }
    var items: () -> [KitMenuItem] = { [] }
    private let ground = KitBox(fill: BookmarkTrack.rest, corners: .radius(SurfaceLook.fieldCorner))
    private let glyph = KitSymbol("folder", style: .init(size: 11), tint: KitColor.muted)
    private let label = KitLabel("", font: SurfaceLook.fieldFont, color: KitColor.ink)
    private let arrows = KitSymbol("chevron.up.chevron.down", style: .init(size: 9, weight: .semibold), tint: KitColor.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [ground, glyph, label, arrows] as [NSView] { addSubview(view) }
        label.setAccessibilityElement(false)
        kitAccess(label: "Folder", role: .popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: SurfaceLook.field) }

    override func hoverChanged() {
        ground.layer?.kitTransition(Motion.kitQuick)
        ground.fill = hovering ? BookmarkTrack.lit : BookmarkTrack.rest
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let h = bounds.height
        let glyphSize = glyph.intrinsicContentSize
        glyph.frame = kitSnap(NSRect(x: SurfaceLook.fieldLead, y: (h - glyphSize.height) / 2, width: glyphSize.width, height: glyphSize.height))
        let arrowSize = arrows.intrinsicContentSize
        arrows.frame = kitSnap(NSRect(x: bounds.width - SurfaceLook.fieldLead - arrowSize.width, y: (h - arrowSize.height) / 2, width: arrowSize.width, height: arrowSize.height))
        let x = glyph.frame.maxX + 6
        let size = label.intrinsicContentSize
        label.frame = kitSnap(NSRect(x: x, y: (h - size.height) / 2, width: max(0, min(size.width, arrows.frame.minX - 6 - 4 - x)), height: size.height))
    }

    override func mouseDown(with event: NSEvent) {
        KitMenu.pop(items(), below: self)
    }

    override func accessibilityPerformPress() -> Bool {
        KitMenu.pop(items(), below: self)
        return true
    }
}

final class BookmarkCardView: KitFlippedView {
    static let width: CGFloat = 280

    let browser: Browser
    let bookmarks: Bookmarks
    let id: Bookmark.ID
    var close: () -> Void

    private let heading = KitLabel("Bookmarked", font: SurfaceLook.title, color: KitColor.ink)
    private let nameCaption = KitLabel("Name", font: SurfaceLook.captionFont, color: KitColor.muted)
    private let folderCaption = KitLabel("Folder", font: SurfaceLook.captionFont, color: KitColor.muted)
    let name = BookmarkNameField()
    let folder = BookmarkFolderPicker()
    private let remove: KitButton
    private let done: KitButton
    private var watch: AnyCancellable?

    init(browser: Browser, bookmarks: Bookmarks, id: Bookmark.ID, close: (() -> Void)? = nil) {
        self.browser = browser
        self.bookmarks = bookmarks
        self.id = id
        self.close = close ?? { [weak browser] in browser?.bookmarksOpen = false }
        remove = KitButton.pill("Remove", kind: .destructive, font: .systemFont(ofSize: 12), height: 22, padding: 9)
        done = KitButton.pill("Done", kind: .primary, font: .systemFont(ofSize: 12, weight: .semibold), height: 22, padding: 9)
        super.init(frame: .zero)
        remove.action = { [weak self] in
            guard let self else { return }
            self.close()
            self.bookmarks.remove(self.id)
        }
        done.action = { [weak self] in self?.close() }
        for view in [heading, nameCaption, folderCaption, name, folder, remove, done] as [NSView] { addSubview(view) }
        name.field.stringValue = bookmarks.bookmark(id)?.title ?? ""
        name.field.placeholderString = bookmarks.bookmark(id)?.url.flatMap(URL.init(string:)).map(Address.pretty) ?? ""
        name.field.setAccessibilityLabel("Name")
        name.onChange = { [weak self] typed in
            guard let self else { return }
            BookmarkCardView.rename(self.id, typed, in: self.bookmarks)
        }
        name.onSubmit = { [weak self] in self?.close() }
        name.onCancel = { [weak self] in self?.close() }
        folder.items = { [weak self] in self?.folderItems() ?? [] }
        watch = kitTrack { [weak self] in self?.refresh() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Bookmarked")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func rename(_ id: Bookmark.ID, _ typed: String, in bookmarks: Bookmarks) {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != bookmarks.bookmark(id)?.title else { return }
        bookmarks.update(id, title: name, url: nil)
    }

    private func refresh() {
        guard bookmarks.bookmark(id) != nil else { return }
        folder.title = bookmarks.path(to: id)?.last?.title ?? "Top Level"
        name.field.placeholderString = bookmarks.bookmark(id)?.url.flatMap(URL.init(string:)).map(Address.pretty) ?? ""
    }

    private func folderItems() -> [KitMenuItem] {
        var items: [KitMenuItem] = [.action("Top Level", run: { [bookmarks, id] in bookmarks.move(id, into: nil) })]
        let folders = Bookmarks.folders(bookmarks.roots)
        if !folders.isEmpty {
            items.append(.separator)
            items += folders.map { target in
                .action(String(repeating: "   ", count: target.depth) + target.node.title, run: { [bookmarks, id] in
                    bookmarks.move(id, into: target.node.id)
                })
            }
        }
        items += [.separator, .action("New Folder\u{2026}", run: { [bookmarks, id] in
            Ask.name("New Folder", placeholder: "Folder name", confirm: "Create") { name in
                let made = bookmarks.insert(.folder(name, []), into: nil)
                bookmarks.move(id, into: made.id)
            }
        })]
        return items
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.canBecomeKey else { return }
            window.makeFirstResponder(self.name.field)
        }
    }

    private var lineHeights: (name: CGFloat, folder: CGFloat) {
        (max(nameCaption.intrinsicContentSize.height, SurfaceLook.field), max(folderCaption.intrinsicContentSize.height, SurfaceLook.field))
    }

    override var intrinsicContentSize: NSSize {
        let lines = lineHeights
        return NSSize(width: Self.width, height: 14 + heading.intrinsicContentSize.height + 12 + lines.name + 8 + lines.folder + 12 + 22 + 14)
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - 28
        let headingSize = heading.intrinsicContentSize
        heading.frame = kitSnap(NSRect(x: 14, y: 14, width: headingSize.width, height: headingSize.height))
        let lines = lineHeights
        var y = heading.frame.maxY + 12
        func line(_ caption: KitLabel, _ control: NSView, _ height: CGFloat, _ controlHeight: CGFloat) {
            let size = caption.intrinsicContentSize
            caption.frame = kitSnap(NSRect(x: 14, y: y + (height - size.height) / 2, width: size.width, height: size.height))
            control.frame = kitSnap(NSRect(x: 14 + 52, y: y + (height - controlHeight) / 2, width: inner - 52, height: controlHeight))
            y += height
        }
        line(nameCaption, name, lines.name, SurfaceLook.field)
        y += 8
        line(folderCaption, folder, lines.folder, SurfaceLook.field)
        y += 12
        let removeWidth = remove.intrinsicContentSize.width
        let doneWidth = done.intrinsicContentSize.width
        remove.frame = NSRect(x: 14, y: y, width: removeWidth, height: 22)
        done.frame = NSRect(x: bounds.width - 14 - doneWidth, y: y, width: doneWidth, height: 22)
    }
}

final class BookmarkGroup: KitBox {
    let outline: BookmarkOutlineView

    init(_ outline: BookmarkOutlineView) {
        self.outline = outline
        super.init(frame: .zero)
        fill = BookmarkTrack.group
        corners = .radius(8)
        passesClicks = false
        addSubview(outline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: outline.fittingHeight() + 10)
    }

    override func layout() {
        super.layout()
        outline.frame = NSRect(x: 5, y: 5, width: max(0, bounds.width - 10), height: outline.fittingHeight())
    }
}

final class BookmarksPageView: KitFlippedView {
    let browser: Browser
    let bookmarks: Bookmarks
    let asTab: Bool
    let body: BookmarksBody
    private var plate: KitPlatePage!
    var onPress: (() -> Void)?

    init(browser: Browser, bookmarks: Bookmarks, asTab: Bool = true) {
        self.browser = browser
        self.bookmarks = bookmarks
        self.asTab = asTab
        body = BookmarksBody(browser: browser, bookmarks: bookmarks, asTab: asTab)
        super.init(frame: .zero)
        plate = KitPlatePage("Bookmarks", content: body, foot: BookmarksFoot(browser: browser, bookmarks: bookmarks))
        kitPin(plate)
        let press = NSClickGestureRecognizer(target: self, action: #selector(pressed))
        press.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(press)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Bookmarks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }
}

final class BookmarksBody: KitFlippedView {
    let browser: Browser
    let bookmarks: Bookmarks
    let asTab: Bool
    let field = KitSearchField(prompt: "Search bookmarks", takesFocus: true)
    let outline: BookmarkOutlineView
    private let none = KitEmptyView("No bookmarks yet", line: "Keep a page with \u{21E7}\u{2318}B, or bring yours over from another browser below", symbol: "bookmark")
    private let tree: BookmarkScroll
    private let found = BookmarkFoundList()
    private let foundScroll: BookmarkScroll
    private let nothing = KitEmptyView("Nothing matches", line: "No bookmark by that name or address", symbol: "magnifyingglass")
    private(set) var query = ""

    init(browser: Browser, bookmarks: Bookmarks, asTab: Bool) {
        self.browser = browser
        self.bookmarks = bookmarks
        self.asTab = asTab
        outline = BookmarkOutlineView(bookmarks: bookmarks, open: { [browser] in browser.pickBookmark($0) },
                                      openInNewTab: { [browser] in browser.pickBookmark($0, inNewTab: true) })
        tree = BookmarkScroll(BookmarkGroup(outline), insets: NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0))
        foundScroll = BookmarkScroll(found, insets: NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0), indicators: false)
        super.init(frame: .zero)
        wantsLayer = true
        outline.onResize = { [weak tree] in
            tree?.inner.invalidateIntrinsicContentSize()
            tree?.inner.needsLayout = true
            tree?.needsLayout = true
        }
        found.open = { [browser] in browser.pickBookmark($0) }
        found.show = { [weak self] in self?.show($0) }
        for view in [field, none, tree, foundScroll, nothing] as [NSView] { addSubview(view) }
        field.onChange = { [weak self] in self?.search($0) }
        field.onSubmit = { [weak self] in self?.openFirst() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func search(_ text: String) {
        if field.stringValue != text { field.stringValue = text }
        let was = query.isEmpty
        query = text
        if was != text.isEmpty { layer?.kitTransition(Motion.kitSettle) }
        needsLayout = true
    }

    private func openFirst() {
        guard let url = bookmarks.matches(query).lazy.compactMap({ $0.node.url.flatMap(URL.init(string:)) }).first else { return }
        browser.pickBookmark(url)
    }

    func show(_ node: Bookmark) {
        search("")
        var open = outline.expanded
        open.formUnion((bookmarks.path(to: node.id) ?? []).map(\.id))
        if node.isFolder { open.insert(node.id) }
        outline.expanded = open
        outline.shown = node.id
        layoutSubtreeIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self, let rect = self.outline.rect(of: node.id) else { return }
            self.tree.reveal(self.outline.convert(rect, to: self.tree.inner), animated: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, self.outline.shown == node.id else { return }
            self.outline.shown = nil
        }
    }

    override func layout() {
        super.layout()
        let empty = bookmarks.isEmpty
        let hits = empty || query.isEmpty ? [] : bookmarks.matches(query)
        let fieldHeight = field.intrinsicContentSize.height
        field.frame = NSRect(x: 0, y: 0, width: bounds.width, height: fieldHeight)
        let gap = KitPlatePage.fieldGap
        let below = NSRect(x: 0, y: fieldHeight + gap, width: bounds.width, height: max(0, bounds.height - fieldHeight - gap))
        let capped = asTab ? below : NSRect(x: below.minX, y: below.minY, width: below.width, height: min(below.height, 440))
        none.isHidden = !empty
        tree.isHidden = empty || !query.isEmpty
        foundScroll.isHidden = empty || query.isEmpty || hits.isEmpty
        nothing.isHidden = empty || query.isEmpty || !hits.isEmpty
        none.frame = KitPageRow.emptyFrame(for: none, in: self, fieldHeight: fieldHeight)
        tree.frame = capped
        if !foundScroll.isHidden {
            found.hits = hits.map { ($0.node, $0.path) }
            foundScroll.frame = capped
        }
        nothing.frame = KitPageRow.emptyFrame(for: nothing, in: self, fieldHeight: fieldHeight)
    }
}

final class BookmarksFoot: KitFlippedView {
    private let bookmarks: Bookmarks
    private let lead = KitLabel("Bring over from", font: KitPageRow.footFont, color: .secondaryLabelColor)
    private let another: KitButton
    private let file: KitButton
    private let folder: KitButton
    private let count = KitLabel("", font: KitPageRow.footFont, color: .secondaryLabelColor)

    init(browser: Browser, bookmarks: Bookmarks) {
        self.bookmarks = bookmarks
        let font = NSFont.systemFont(ofSize: 13)
        another = KitButton.pill("Another Browser", font: font, height: 28, padding: 12) { browser.lead(to: InternalPage(.importing)) }
        file = KitButton.pill("File\u{2026}", font: font, height: 28, padding: 12) { browser.importFile() }
        folder = KitButton.pill("New Folder\u{2026}", font: font, height: 28, padding: 12) { bookmarks.askNewFolder(in: nil) }
        super.init(frame: .zero)
        lead.setAccessibilityElement(true)
        for view in [lead, another, file, folder, count] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    private static let ellipsis = ceil(("\u{2026}" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)

    override func layout() {
        super.layout()
        let total = bookmarks.count
        count.text = total == 1 ? "1 bookmark" : "\(total) bookmarks"
        count.isHidden = bookmarks.isEmpty
        func text(_ label: KitLabel) -> KitFlex.Item { KitFlex.Item(least: Self.ellipsis, most: label.intrinsicContentSize.width) }
        func button(_ button: KitButton) -> KitFlex.Item { KitFlex.Item(least: 64, most: max(64, button.intrinsicContentSize.width)) }
        var views: [NSView?] = [lead, another, file, nil, folder]
        var items: [KitFlex.Item] = [text(lead), button(another), button(file), .spacer(), button(folder)]
        if !count.isHidden {
            views.append(count)
            items.append(text(count))
        }
        KitFlex.lay(views, items, spacing: 8, in: bounds, snap: kitSnap)
        for view in [another, file, folder] { view.frame.size.height = 28; view.frame.origin.y = 0 }
    }
}

final class BookmarkFoundList: KitFlippedView {
    var hits: [(node: Bookmark, path: [String])] = [] { didSet { rebuild() } }
    var open: ((URL) -> Void)?
    var show: ((Bookmark) -> Void)?
    private var rows: [BookmarkFoundRow] = []
    static let spacing: CGFloat = 8

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rows.isEmpty ? 0 : CGFloat(rows.count) * BookmarkFoundRow.height + CGFloat(rows.count - 1) * Self.spacing)
    }

    private func rebuild() {
        while rows.count > hits.count { rows.removeLast().removeFromSuperview() }
        while rows.count < hits.count {
            let row = BookmarkFoundRow()
            rows.append(row)
            addSubview(row)
        }
        for (row, hit) in zip(rows, hits) {
            let url = hit.node.url.flatMap(URL.init(string:))
            row.set(node: hit.node, path: hit.path, open: url.map { url in { [weak self] in self?.open?(url) } },
                    show: { [weak self] in self?.show?(hit.node) })
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
        (enclosingScrollView as? BookmarkScroll)?.needsLayout = true
    }

    override func layout() {
        super.layout()
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: CGFloat(index) * (BookmarkFoundRow.height + Self.spacing), width: bounds.width, height: BookmarkFoundRow.height)
        }
    }
}

final class BookmarkFoundRow: KitHoverView {
    static let height: CGFloat = 32
    private var node: Bookmark?
    private var path: [String] = []
    private var open: (() -> Void)?
    private var show: (() -> Void)?
    private let siteMark = BookmarkMarkView(size: 16)
    private let folderMark = BookmarkMarkView(size: 16, folderSymbol: 10)
    private let title = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.ink)
    private let whereabouts = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private lazy var showButton: NSButton = {
        let button = KitPushButton("Show in Folder", size: .small) { [weak self] in self?.show?() }
        button.isBordered = false
        return button
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [siteMark, folderMark, title, whereabouts, showButton] as [NSView] { addSubview(view) }
        whereabouts.overflow = .middle
        title.setAccessibilityElement(false)
        whereabouts.setAccessibilityElement(false)
        showButton.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(node: Bookmark, path: [String], open: (() -> Void)?, show: @escaping () -> Void) {
        self.node = node
        self.path = path
        self.open = open
        self.show = show
        folderMark.isHidden = !node.isFolder
        siteMark.isHidden = node.isFolder
        if !node.isFolder {
            siteMark.show(icon: Favicons.shared.cached(for: node.address), letter: String((node.host ?? "\u{2022}").prefix(1)).uppercased())
        }
        title.text = node.label
        title.color = node.unnamed ? KitColor.muted : KitColor.ink
        let folders = path.isEmpty ? "Top Level" : path.joined(separator: " \u{203A} ")
        whereabouts.text = node.host.map { folders + "  \u{00B7}  " + $0 } ?? folders
        setAccessibilityLabel(node.label)
        setAccessibilityValue(whereabouts.text)
        needsLayout = true
    }

    override func hoverChanged() {
        showButton.isHidden = !hovering
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let mark = node?.isFolder == true ? folderMark : siteMark
        mark.frame = kitSnap(NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16))
        var right = bounds.width
        if !showButton.isHidden {
            let size = showButton.intrinsicContentSize
            showButton.frame = NSRect(x: right - size.width, y: ((h - size.height) / 2).rounded(), width: size.width, height: size.height)
            right -= size.width + 8
        }
        let x: CGFloat = 26
        let room = max(0, right - 8 - x)
        if let node { title.text = BookmarkWords.fitted(node.label, font: title.font, in: room) }
        let titleSize = title.intrinsicContentSize
        let lineSize = whereabouts.intrinsicContentSize
        let top = ((h - titleSize.height - 2 - lineSize.height) / 2).rounded()
        title.frame = kitSnap(NSRect(x: x, y: top, width: min(titleSize.width, room), height: titleSize.height))
        whereabouts.frame = kitSnap(NSRect(x: x, y: title.frame.maxY + 2, width: min(lineSize.width, room), height: lineSize.height))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if let open { open() } else { show?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        var items: [KitMenuItem] = []
        if let open { items.append(.action("Open", run: open)) }
        if let show { items.append(.action("Show in Folder", run: show)) }
        return KitMenu.make(items)
    }

    override func accessibilityPerformPress() -> Bool {
        if let open { open() } else { show?() }
        return true
    }
}

/// The bookmarks in the menu bar's Bookmarks menu, made by AppKit rather
/// than SwiftUI. SwiftUI makes a menu bar's items all at once, folders
/// and all, before the app has finished launching: 1,500 bookmarks, as a
/// Chrome import brings, held the window back by 230 ms at every launch.
/// Here the top of the list is made as the menu opens, and a folder's
/// items as that folder opens.
///
/// SwiftUI keeps its own two items, and its own delegate, which lays the
/// menu out afresh each time it opens — anything added beside them was
/// gone by then. So its delegate is wrapped: SwiftUI does its update,
/// then the bookmarks go in after it. SwiftUI puts its delegate back on
/// every update, so the wrapping is put back too (see `start`).
@MainActor
final class BookmarkMenu: NSObject, NSMenuDelegate {
    static let shared = BookmarkMenu()

    private weak var browser: Browser?
    private var watch: [Any] = []
    private let relay = Relay()
    /// What each folder's submenu holds, until it opens.
    private var folders: [ObjectIdentifier: [Bookmark]] = [:]
    /// The items put in here, among SwiftUI's own.
    fileprivate static let mark = 0x5EAC

    func start(for browser: Browser) {
        guard self.browser == nil else { return }
        self.browser = browser
        relay.after = { [weak self] menu in self?.fill(menu) }
        // SwiftUI puts its own delegate back whenever it updates the menu
        // bar, which is whenever anything in the window changes. So: after
        // each event, and as the menu bar starts to be used, before any of
        // its menus opens.
        let centre = NotificationCenter.default
        watch = [
            centre.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.wrap() }
            },
            centre.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.wrap()
                }
            },
            // However the menu bar is let go of, even if SwiftUI's delegate
            // got the menu's own close instead.
            centre.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { [weak self] note in
                MainActor.assumeIsolated {
                    guard (note.object as? NSMenu) === NSApp.mainMenu else { return }
                    self?.closed()
                }
            },
        ]
        wrap()
    }

    private var menu: NSMenu? { NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu }

    private var shown: Browser? { Browsers.front.flatMap { !$0.isPopup ? $0 : nil } ?? browser }

    /// Looks, while the menu is open, after each turn of the run loop.
    private var looking: CFRunLoopObserver?

    /// An open menu is updated by SwiftUI itself, straight through its own
    /// delegate, whenever anything it shows could have changed — a tab's
    /// title, every second on a download page — and that took the bookmarks
    /// out from under the pointer. While it is open, they go back in as soon
    /// as a turn of the run loop finds them gone.
    fileprivate func opened(_ menu: NSMenu) {
        guard looking == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { [weak self, weak menu] _, _ in
            MainActor.assumeIsolated {
                guard let self, let menu, !menu.items.contains(where: { $0.tag == Self.mark }) else { return }
                self.fill(menu)
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        looking = observer
    }

    fileprivate func closed() {
        guard let looking else { return }
        CFRunLoopObserverInvalidate(looking)
        self.looking = nil
    }

    private func wrap() {
        guard let menu, menu.delegate !== relay
        else { return }
        relay.inner = menu.delegate
        menu.delegate = relay
    }

    /// SwiftUI's own update of the menu, without ours after it: what it
    /// does by itself to a menu that is open. For the bench.
    func swiftUIUpdate() {
        guard let menu else { return }
        relay.inner?.menuNeedsUpdate?(menu)
    }

    /// How many items this has put in the menu, for the bench.
    var count: Int {
        menu?.items.filter { $0.tag == Self.mark }.count ?? 0
    }

    /// The top of the list, after SwiftUI's items, in place of any left
    /// from the last time.
    private func fill(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.mark { menu.removeItem(item) }
        folders = [:]
        guard let roots = shown?.bookmarks.roots, !roots.isEmpty else { return }
        let line = NSMenuItem.separator()
        line.tag = Self.mark
        menu.addItem(line)
        for item in items(for: roots) { menu.addItem(item) }
    }

    /// A folder of the bookmarks bar, opened as a menu at the pointer: the
    /// same items as the menu bar's, folders opening as they are reached.
    func popUp(_ folder: Bookmark) {
        let menu = NSMenu(title: folder.title)
        let made = items(for: folder.children ?? [])
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func items(for nodes: [Bookmark]) -> [NSMenuItem] {
        nodes.compactMap { node in
            let item: NSMenuItem
            if node.isFolder {
                item = NSMenuItem(title: node.title, action: nil, keyEquivalent: "")
                item.image = KitGlyph.plain("folder")
                let sub = NSMenu(title: node.title)
                sub.delegate = self
                folders[ObjectIdentifier(sub)] = node.children ?? []
                item.submenu = sub
            } else if let text = node.url, let url = URL(string: text) {
                // One without a name reads as its address here.
                item = NSMenuItem(title: node.label, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                // The site's icon, as the bar wears it: a folder opened from
                // the bar, or the Bookmarks menu, had none (idea 183). A site
                // whose icon isn't kept yet (brought in, never visited) wears
                // the bar's letter in its place, rather than nothing and its
                // title out of line with the others'.
                item.image = BookmarksDropdown.image(node)
            } else {
                return nil
            }
            item.tag = Self.mark
            return item
        }
    }

    /// The bar's Mark with no icon, for a menu: the letter, muted, on a
    /// faint square, drawn as the menu draws so it follows light and dark.
    static func letter(_ letter: String) -> NSImage {
        let size: CGFloat = 16
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            Palette.NS.ink.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            let text = NSAttributedString(string: letter, attributes: [
                .font: NSFont.systemFont(ofSize: size * 0.56, weight: .medium),
                .foregroundColor: Palette.NS.muted,
            ])
            let drawn = text.size()
            text.draw(at: NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2))
            return true
        }
    }

    /// What a folder of the bar holds as its menu: every item, its folders
    /// opened as a click would, deepest last. For the bench.
    func walk(_ folder: Bookmark) -> [(depth: Int, item: NSMenuItem)] {
        func down(_ items: [NSMenuItem], _ depth: Int) -> [(depth: Int, item: NSMenuItem)] {
            items.flatMap { item -> [(depth: Int, item: NSMenuItem)] in
                guard let sub = item.submenu else { return [(depth, item)] }
                menuNeedsUpdate(sub)
                return [(depth, item)] + down(sub.items, depth + 1)
            }
        }
        return down(items(for: folder.children ?? []), 0)
    }

    /// A folder, opening.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let kids = folders[ObjectIdentifier(menu)] else { return }
        menu.removeAllItems()
        let made = items(for: kids)
        if made.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for item in made { menu.addItem(item) }
    }

    @objc private func open(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        shown?.openBookmark(url)
    }

    /// SwiftUI's delegate, with the bookmarks put in after its update.
    /// Everything else it answers goes straight to it.
    private final class Relay: NSObject, NSMenuDelegate {
        weak var inner: NSMenuDelegate?
        var after: ((NSMenu) -> Void)?

        func menuNeedsUpdate(_ menu: NSMenu) {
            inner?.menuNeedsUpdate?(menu)
            MainActor.assumeIsolated { after?(menu) }
        }

        func menuWillOpen(_ menu: NSMenu) {
            inner?.menuWillOpen?(menu)
            MainActor.assumeIsolated { BookmarkMenu.shared.opened(menu) }
        }

        func menuDidClose(_ menu: NSMenu) {
            inner?.menuDidClose?(menu)
            MainActor.assumeIsolated { BookmarkMenu.shared.closed() }
        }

        /// Only for its own items: the bookmarks aren't SwiftUI's to know.
        func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
            guard item?.tag != BookmarkMenu.mark else { return }
            inner?.menu?(menu, willHighlight: item)
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || (inner?.responds(to: selector) ?? false)
        }

        override func forwardingTarget(for selector: Selector!) -> Any? { inner }
    }
}

@MainActor
enum BookmarksSurface {
    static let names = ["bookmarks-page", "bookmark-outline", "bookmark-card"]

    private static let model = Bookmarks()

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    static let fixture: [Bookmark] = [
        Bookmark(id: id(1), title: "Reading", url: nil, children: [
            Bookmark(id: id(2), title: "A very long article title that keeps going well past the edge of the list it sits in",
                     url: "https://longreads.example/a-very-long-article", children: nil),
            Bookmark(id: id(3), title: "Swift Forums", url: "https://forums.swift.org", children: nil),
            Bookmark(id: id(4), title: "Later", url: nil, children: []),
        ]),
        Bookmark(id: id(5), title: "Work", url: nil, children: [
            Bookmark(id: id(6), title: "Linear", url: "https://linear.app", children: nil),
            Bookmark(id: id(7), title: "Figma", url: "https://figma.com", children: nil),
            Bookmark(id: id(8), title: "Notion", url: "https://notion.so", children: nil),
        ]),
        Bookmark(id: id(9), title: "GitHub", url: "https://github.com", children: nil),
        Bookmark(id: id(10), title: "", url: "https://news.ycombinator.com/news", children: nil),
        Bookmark(id: id(11), title: "Apple Developer", url: "https://developer.apple.com", children: nil),
    ]

    static let opened: Set<Bookmark.ID> = [id(1), id(4)]
    static let carded = id(3)

    static func bookmarks(empty: Bool) -> Bookmarks {
        for node in model.roots { model.remove(node.id) }
        if !empty { for node in fixture { model.insert(node, into: nil) } }
        return model
    }

    static func make(_ name: String, _ request: [String: Any]) -> NSView? {
        guard let browser = Browsers.front else { return nil }
        let bookmarks = bookmarks(empty: request["empty"] as? Bool ?? false)
        let width = CGFloat(request["width"] as? Double ?? 760)
        let height = CGFloat(request["height"] as? Double ?? 600)
        switch name {
        case "bookmarks-page":
            return grounded(BookmarksPageView(browser: browser, bookmarks: bookmarks), fill: .windowBackgroundColor, width: width, height: height)
        case "bookmark-outline":
            let outline = BookmarkOutlineView(bookmarks: bookmarks, expanded: opened, open: { _ in }, openInNewTab: { _ in })
            let ground = KitBox(fill: Palette.NS.ground)
            ground.kitPin(outline, insets: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
            ground.kitSize(width: 280, height: outline.fittingHeight() + 12)
            return ground
        case "bookmark-card":
            let view = BookmarkCardView(browser: browser, bookmarks: bookmarks, id: carded, close: {})
            return grounded(view, fill: .windowBackgroundColor, width: view.intrinsicContentSize.width, height: view.intrinsicContentSize.height)
        default:
            return nil
        }
    }

    private static func grounded(_ view: NSView, fill: NSColor, width: CGFloat, height: CGFloat) -> NSView {
        let ground = KitBox(fill: fill)
        ground.kitPin(view)
        ground.kitSize(width: width, height: height)
        return ground
    }
}

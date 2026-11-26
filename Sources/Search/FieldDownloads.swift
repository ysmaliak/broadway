import AppKit
import Combine

struct FieldFetch: Equatable {
    let entry: FetchEntry

    static func == (left: FieldFetch, right: FieldFetch) -> Bool { left.entry === right.entry }
}

extension FieldPlace {
    @MainActor
    static func downloads(_ entries: [FetchEntry], _ kept: [Keep], matching typed: String) -> [DownloadLine] {
        let words = words(typed)
        let running = words.isEmpty ? entries : entries.filter { entry in
            let hay = entry.name + " " + (entry.request?.url?.host() ?? "")
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return running.map(DownloadLine.entry) + downloads(kept, matching: typed, limit: .max).map(DownloadLine.kept)
    }
}

@MainActor
enum FieldDownloadKeys {
    static func returnVerb(_ entry: FetchEntry) -> DownloadVerb? {
        entry.verbs.first { $0 == .resume || $0 == .retry }
    }

    static func keys(_ verb: DownloadVerb) -> String {
        switch verb {
        case .open: "↩"
        case .pause, .resume: "⌘P"
        case .retry, .reveal: "⌘R"
        case .cancel, .remove, .forget: "⌃X"
        }
    }

    static func hints(_ entry: FetchEntry) -> [(keys: String, word: String)] {
        let lead = returnVerb(entry)
        return entry.verbs.filter { $0 != lead }.map { (keys($0), $0.title) }
    }

    static func menuVerbs(_ entry: FetchEntry) -> [(verb: DownloadVerb, keys: String)] {
        let lead = returnVerb(entry)
        return entry.verbs.map { ($0, $0 == lead ? "↩" : keys($0)) }
    }

    static func symbol(_ verb: DownloadVerb) -> String {
        switch verb {
        case .open: "return"
        case .reveal: "folder"
        case .pause: "pause.circle"
        case .resume: "play.circle"
        case .retry: "arrow.clockwise.circle"
        case .cancel, .remove: "xmark.circle"
        case .forget: "minus.circle"
        }
    }
}

extension FieldPlaceItem {
    @MainActor
    func hints(splits: Bool) -> [(keys: String, word: String)] {
        guard place == .downloads else { return place.hints(splits: splits) }
        if let entry = fetch?.entry { return FieldDownloadKeys.hints(entry) }
        return missing ? [("⌃X", place.forgetting)] : place.hints(splits: splits)
    }

    @MainActor
    var returns: Bool {
        guard place == .downloads else { return true }
        if let entry = fetch?.entry { return FieldDownloadKeys.returnVerb(entry) != nil }
        return !missing
    }

    @MainActor
    var returnWord: String {
        fetch.flatMap { FieldDownloadKeys.returnVerb($0.entry)?.title } ?? "Open"
    }
}

extension Browser {
    func downloadItems(matching typed: String) -> [FieldPlaceItem] {
        FieldPlace.downloads(fetches.entries, loot.kept, matching: typed).compactMap { line in
            switch line {
            case .entry(let entry):
                return FieldPlaceItem(place: .downloads, id: "fetch " + entry.id.uuidString, title: entry.name, detail: "", aside: "",
                                      url: entry.destination ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(entry.name),
                                      fetch: FieldFetch(entry: entry))
            case .kept(let keep):
                let there = keptThere[keep.path] ?? {
                    let found = keep.stillThere
                    keptThere[keep.path] = found
                    return found
                }()
                return FieldPlaceItem(place: .downloads, id: keep.path, title: keep.name,
                                      detail: keep.from.isEmpty ? "" : "From " + Address.withoutWWW(keep.from),
                                      aside: there ? When.said(keep.date) : "Moved or deleted",
                                      url: keep.url, missing: !there)
            case .none:
                return nil
            }
        }
    }

    func showDownloads() {
        downloadsOpen = false
        if active == nil, tabs.isEmpty { newTab() }
        let again = fieldPlace == .downloads && fieldShowing
        enterPlace(.downloads)
        if again { retype() }
    }

    func watchDownloads(_ on: Bool) {
        guard on else {
            downloadsWatch = nil
            return
        }
        keptThere = [:]
        downloadsWatch = kitObserve(initial: false, { [weak self] () -> [String] in
            guard let self else { return [] }
            return self.fetches.entries.map { "\($0.id) \($0.state)" } + self.loot.kept.map(\.path)
        }) { [weak self] _ in self?.relistDownloads() }
    }

    func relistDownloads() {
        guard fieldShowing, fieldPlace == .downloads else { return }
        let lit = pickedOffer?.placed?.id
        let at = picked
        let next = placeRows(.downloads, matching: typed)
        if next != offers { offers = next }
        let found = lit.flatMap { id in offers.firstIndex { $0.placed?.id == id } }
        let wanted = offers.isEmpty ? nil : found ?? min(at ?? 0, offers.count - 1)
        if picked != wanted { picked = wanted }
    }

    func runDownload(_ verb: DownloadVerb, on entry: FetchEntry) {
        switch verb {
        case .pause: pauseDownload(entry)
        case .resume: resumeDownload(entry)
        case .retry: retryDownload(entry)
        case .cancel, .remove: cancelDownload(entry)
        case .open, .reveal, .forget: return
        }
    }

    func downloadKey(_ combo: KeyCombo, on entry: FetchEntry) -> Bool {
        let verbs = entry.verbs
        let wanted: DownloadVerb?
        switch combo {
        case KeyCombo("x", command: false, control: true), KeyCombo("delete", command: false, shift: true):
            wanted = verbs.first { $0 == .cancel || $0 == .remove }
        case KeyCombo("p"):
            wanted = verbs.first { $0 == .pause || $0 == .resume }
        case KeyCombo("r"):
            wanted = verbs.first { $0 == .retry }
        case KeyCombo("c", shift: true):
            return true
        default:
            return false
        }
        if let wanted { runDownload(wanted, on: entry) }
        return true
    }

    func downloadMenuItems(_ item: FieldPlaceItem) -> [FieldMenuItem] {
        var items: [FieldMenuItem] = []
        if let entry = item.fetch?.entry {
            for (verb, keys) in FieldDownloadKeys.menuVerbs(entry) {
                items.append(FieldMenuItem(id: verb.rawValue, title: verb.title, symbol: FieldDownloadKeys.symbol(verb), keys: keys) { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    self.runDownload(verb, on: entry)
                })
            }
        } else {
            if !item.missing {
                items.append(FieldMenuItem(id: "open", title: "Open", symbol: "return", keys: "↩") { [weak self] in self?.openPlaced(item) })
                items.append(FieldMenuItem(id: "reveal", title: "Show in Finder", symbol: "folder", keys: "⌘R") { [weak self] in self?.revealPlaced(item) })
                items.append(FieldMenuItem(id: "copy", title: "Copy Path", symbol: "doc.on.doc", keys: "⇧⌘C") { [weak self] in self?.copyPlaced(item) })
            }
            items.append(FieldMenuItem(id: "forget", title: "Remove from List", symbol: "minus.circle", keys: "⌃X") { [weak self] in self?.forgetPlaced(item) })
        }
        if let clear = clearDownloadsItem() { items.append(clear) }
        return items
    }

    func clearDownloadsItem() -> FieldMenuItem? {
        guard !loot.kept.isEmpty else { return nil }
        return FieldMenuItem(id: "clear", title: "Clear List", symbol: "trash") { [weak self] in self?.clearDownloadsList() }
    }

    static let clearedList = "Cleared the list. The files stay where they are."

    func clearDownloadsList() {
        let was = loot.kept
        guard !was.isEmpty else { return }
        loot.forgetAll()
        keptThere = [:]
        if fieldPlace == .downloads { relistDownloads() }
        announce(Self.clearedList, undo: { [weak self] in
            guard let self else { return }
            for keep in was.reversed() { self.loot.restore(keep) }
            if self.fieldPlace == .downloads { self.relistDownloads() }
        })
    }

    func downloadsContextMenu(_ item: FieldPlaceItem, from view: NSView) -> NSMenu? {
        guard item.place == .downloads else { return nil }
        if let entry = item.fetch?.entry {
            let verbs = entry.verbs
            guard !verbs.isEmpty else { return nil }
            return KitMenu.make(verbs.map { verb in
                .action(verb.title, id: "field.downloads.row." + verb.rawValue) { [weak self, weak entry] in
                    guard let self, let entry else { return }
                    self.runDownload(verb, on: entry)
                }
            })
        }
        return DownloadMenu.menu(for: item.url, there: !item.missing, open: { [weak self] in self?.openPlaced(item) },
                                 reveal: { [weak self] in self?.revealPlaced(item) }, forget: { [weak self] in self?.forgetPlaced(item) },
                                 from: view, id: "field.downloads.row")
    }
}

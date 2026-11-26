import AppKit
import Combine
import UniformTypeIdentifiers

enum FieldPlace: String, CaseIterable, Equatable {
    case history, bookmarks, downloads, snippets

    static let most = 30
    static let browsable: [FieldPlace] = [.history, .bookmarks, .downloads]

    var title: String {
        switch self {
        case .history: "History"
        case .bookmarks: "Bookmarks"
        case .downloads: "Downloads"
        case .snippets: "Snippets"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock"
        case .bookmarks: "bookmark"
        case .downloads: "arrow.down.circle"
        case .snippets: "text.insert"
        }
    }

    var names: [String] {
        switch self {
        case .history: ["history", "история"]
        case .bookmarks: ["bookmarks", "закладки"]
        case .downloads: ["downloads", "files", "загрузки", "файлы"]
        case .snippets: []
        }
    }

    var page: InternalPage? {
        switch self {
        case .history: InternalPage(.history)
        case .bookmarks: InternalPage(.bookmarks)
        case .downloads: nil
        case .snippets: InternalPage(.settings, "snippets")
        }
    }

    var forgetting: String { self == .history ? "Forget" : "Remove" }

    func hints(splits: Bool) -> [(keys: String, word: String)] {
        switch self {
        case .history, .bookmarks:
            [("⌘↩", "Background")] + (splits ? [("⌥↩", "Split View")] : []) + [("⇧⌘C", "Copy Link"), (self == .history ? "⇧⌫" : "⌃X", forgetting)]
        case .downloads:
            [("⌘R", "Show in Finder"), ("⇧⌘C", "Copy Path"), ("⌃X", forgetting)]
        case .snippets:
            []
        }
    }

    @MainActor
    func empty(for typed: String) -> String {
        let asked = !typed.trimmingCharacters(in: .whitespaces).isEmpty
        switch self {
        case .history: return asked ? "No history matches" : "No history yet"
        case .bookmarks: return asked ? "No bookmarks match" : "No bookmarks yet"
        case .downloads: return asked ? "No downloads match" : "No downloads yet"
        case .snippets: return asked && !SnippetStore.shared.snippets.isEmpty ? "No snippets match" : "No snippets yet"
        }
    }

    static func offered(for typed: String) -> FieldPlace? {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 4 else { return nil }
        return browsable.first { $0.names.contains { $0.hasPrefix(needle) } }
    }

    static func words(_ typed: String) -> [String] {
        typed.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func downloads(_ kept: [Keep], matching typed: String, limit: Int = most) -> [Keep] {
        let words = words(typed)
        let found = words.isEmpty ? kept : kept.filter { keep in
            let hay = keep.name + " " + keep.from
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return Array(found.enumerated()
            .sorted { $0.element.date != $1.element.date ? $0.element.date > $1.element.date : $0.offset < $1.offset }
            .prefix(limit)
            .map(\.element))
    }

    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor
    static func icon(forFile name: String) -> NSImage {
        let kind = (name as NSString).pathExtension.lowercased()
        if let icon = icons[kind] { return icon }
        let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: kind) ?? .data)
        icons[kind] = icon
        return icon
    }
}

struct FieldPlaceItem: Equatable {
    let place: FieldPlace
    let id: String
    let title: String
    let detail: String
    let aside: String
    let url: URL
    var missing = false
    var fetch: FieldFetch?
}

@MainActor
enum PlaceFiles {
    static var done: [String] = []

    static func open(_ url: URL) {
        if Store.testing { done.append("open " + url.path) } else { NSWorkspace.shared.open(url) }
    }

    static func reveal(_ url: URL) {
        if Store.testing { done.append("reveal " + url.path) } else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

extension Suggestion {
    static func placed(_ item: FieldPlaceItem) -> Suggestion {
        Suggestion(key: item.title, title: item.detail, url: item.url, kind: .placed(item))
    }

    var placed: FieldPlaceItem? {
        if case .placed(let item) = kind { return item }
        return nil
    }
}

extension Browser {
    func placeItems(_ place: FieldPlace, matching typed: String) -> [FieldPlaceItem] {
        switch place {
        case .history:
            return history.newest(matching: typed, limit: FieldPlace.most).map { trace in
                let address = Address.withoutWWW(trace.address)
                return FieldPlaceItem(place: .history, id: trace.key, title: trace.title.isEmpty ? address : trace.title,
                                      detail: trace.title.isEmpty ? "" : address, aside: When.said(trace.last), url: trace.url)
            }
        case .bookmarks:
            return bookmarks.listed(matching: typed, limit: FieldPlace.most).map { kept in
                FieldPlaceItem(place: .bookmarks, id: kept.id.uuidString, title: kept.title.isEmpty ? Address.pretty(kept.url) : kept.title,
                               detail: kept.title.isEmpty ? "" : Address.pretty(kept.url), aside: kept.folders.joined(separator: " › "), url: kept.url)
            }
        case .downloads:
            return downloadItems(matching: typed)
        case .snippets:
            return []
        }
    }

    func placeRows(_ place: FieldPlace, matching typed: String) -> [Suggestion] {
        placeItems(place, matching: typed).map(Suggestion.placed)
    }

    var placeIsEmpty: Bool { fieldPlace != nil && offers.isEmpty }

    var offerRowShown: Bool { siteOffer != nil || placeOffer != nil }

    func escapePlace() -> Bool {
        guard fieldShowing, fieldPlace != nil, !fieldMenu.showing else { return false }
        if !typed.isEmpty {
            typed = ""
            return true
        }
        leavePlace()
        return true
    }

    func openPlaced(_ item: FieldPlaceItem, aside: Bool = false, front: Bool = false) {
        if let entry = item.fetch?.entry {
            if let verb = FieldDownloadKeys.returnVerb(entry) { runDownload(verb, on: entry) }
            return
        }
        if item.place == .downloads {
            guard FileManager.default.fileExists(atPath: item.url.path) else {
                announce("\(item.title) isn't there any more")
                return
            }
            quitField()
            PlaceFiles.open(item.url)
            return
        }
        if aside {
            open(item.url, foreground: front, from: active, mayWait: !front)
        } else if launching {
            open(item.url, foreground: true, from: active)
        } else {
            (active ?? tabs.first)?.go(to: item.url)
        }
        quitField()
    }

    func openPlacedAtEnd(_ item: FieldPlaceItem) {
        guard item.place != .downloads else { return openPlaced(item) }
        open(item.url, foreground: true, atEnd: true, from: active)
        quitField()
    }

    func copyPlaced(_ item: FieldPlaceItem) {
        guard item.fetch == nil, !item.missing else { return }
        if item.place == .downloads {
            AnswerBoard.write(item.url.path)
            announce("Path copied")
        } else {
            AnswerBoard.write(item.url.absoluteString)
            announce("Link copied")
        }
    }

    func revealPlaced(_ item: FieldPlaceItem) {
        guard item.place == .downloads, item.fetch == nil else { return }
        guard FileManager.default.fileExists(atPath: item.url.path) else {
            announce("\(item.title) isn't there any more")
            return
        }
        quitField()
        PlaceFiles.reveal(item.url)
    }

    func forgetPlaced(_ item: FieldPlaceItem) {
        let at = offers.firstIndex { $0.placed == item } ?? picked ?? 0
        let relist: @MainActor () -> Void = { [weak self] in
            guard let self, self.fieldPlace == item.place else { return }
            let lit = self.picked
            self.retype()
            self.picked = self.offers.isEmpty ? nil : min(lit ?? at, self.offers.count - 1)
        }
        let undo: @MainActor () -> Void
        let said: String
        switch item.place {
        case .history:
            guard history.trace(item.id) != nil else { return }
            forgetPage(item.id, after: relist)
            retype()
            picked = offers.isEmpty ? nil : min(at, offers.count - 1)
            return
        case .bookmarks:
            guard let id = UUID(uuidString: item.id), let node = bookmarks.bookmark(id) else { return }
            let parent = bookmarks.parent(of: id)
            let siblings = parent.flatMap { bookmarks.bookmark($0)?.children } ?? bookmarks.roots
            let index = siblings.firstIndex { $0.id == id }
            bookmarks.remove(id)
            said = "Removed \(item.title)"
            undo = { [bookmarks] in _ = bookmarks.insert(node, into: parent, at: index) }
        case .downloads:
            guard item.fetch == nil, let keep = loot.kept.first(where: { $0.path == item.id }) else { return }
            loot.forget(keep)
            said = "Removed \(keep.name) from the list"
            undo = { [loot] in loot.restore(keep) }
        case .snippets:
            return
        }
        retype()
        picked = offers.isEmpty ? nil : min(at, offers.count - 1)
        announce(said, undo: {
            undo()
            relist()
        })
    }

    func placeKey(_ combo: KeyCombo) -> Bool {
        guard fieldPlace != nil else { return false }
        if combo == KeyCombo("z"), announcedUndo != nil {
            undoAnnounced()
            return true
        }
        if combo == KeyCombo("return", command: false, option: true) {
            submit(split: true)
            return true
        }
        guard let row = pickedOffer?.placed else { return false }
        if let entry = row.fetch?.entry { return downloadKey(combo, on: entry) }
        switch combo {
        case KeyCombo("x", command: false, control: true), KeyCombo("delete", command: false, shift: true):
            forgetPlaced(row)
        case KeyCombo("c", shift: true):
            copyPlaced(row)
        case KeyCombo("r"):
            guard row.place == .downloads else { return false }
            revealPlaced(row)
        default:
            return false
        }
        return true
    }

    func placeMenuItems(_ item: FieldPlaceItem) -> [FieldMenuItem] {
        var items: [FieldMenuItem] = []
        func add(_ id: String, _ title: String, _ symbol: String, keys: String = "", run: @escaping @MainActor () -> Void) {
            items.append(FieldMenuItem(id: id, title: title, symbol: symbol, keys: keys, run: run))
        }
        if item.place == .downloads {
            return downloadMenuItems(item)
        } else {
            add("open", "Open", "return", keys: "↩") { [weak self] in self?.openPlaced(item) }
            add("background", "Open in Background", "square.on.square", keys: "⌘↩") { [weak self] in
                self?.openPlaced(item, aside: true)
            }
            add("newTab", "Open in New Tab", "plus.square", keys: "⇧⌘↩") { [weak self] in
                self?.openPlaced(item, aside: true, front: true)
            }
            if splitsFromField(.placed(item)) {
                add("split", "Open in Split View", "rectangle.split.2x1", keys: "⌥↩") { [weak self] in self?.openPlacedInSplit(item) }
            }
            add("copy", "Copy Link", "link", keys: "⇧⌘C") { [weak self] in self?.copyPlaced(item) }
            if item.place == .history {
                add("forget", "Forget from History", "clock.badge.xmark", keys: "⇧⌫") { [weak self] in self?.forgetPlaced(item) }
            } else {
                add("forget", "Remove Bookmark", "bookmark.slash", keys: "⌃X") { [weak self] in self?.forgetPlaced(item) }
            }
        }
        if let page = placePageItem(item.place) { items.append(page) }
        return items
    }

    func placePageItem(_ place: FieldPlace) -> FieldMenuItem? {
        guard let page = place.page else { return nil }
        return FieldMenuItem(id: "page", title: "Open \(place.title) Page", symbol: place.symbol) { [weak self] in
            self?.quitField()
            self?.show(page)
        }
    }

    func restingPlaceItems(_ place: FieldPlace) -> [FieldMenuItem] {
        if place == .downloads { return clearDownloadsItem().map { [$0] } ?? [] }
        return placePageItem(place).map { [$0] } ?? []
    }
}

final class FieldKeyCap: KitBox {
    var keys: String { didSet { if keys != oldValue { label.text = keys; invalidateIntrinsicContentSize(); needsLayout = true } } }
    private let label: KitLabel

    init(_ keys: String) {
        self.keys = keys
        label = KitLabel(keys, font: .systemFont(ofSize: 11, weight: .medium), color: KitColor.muted)
        super.init(frame: .zero)
        stroke = KitColor.hairline
        corners = .radius(5)
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: FieldLine.width(label, scale: kitScale) + 12, height: 18)
    }

    override func layout() {
        super.layout()
        label.frame = kitSnap(NSRect(x: 6, y: 0, width: max(0, bounds.width - 12), height: bounds.height))
    }
}

final class PlaceChipView: KitBox {
    var place: FieldPlace { didSet { if place != oldValue { refresh() } } }
    private let icon = FieldLine.symbol("clock", size: 11, weight: .medium)
    private let title = FieldLine.label("", size: 13, weight: .medium)

    init(place: FieldPlace) {
        self.place = place
        super.init(frame: .zero)
        fill = Palette.NS.wash
        corners = .radius(7)
        title.setAccessibilityElement(false)
        addSubview(icon)
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        icon.name = place.symbol
        title.text = place.title
        setAccessibilityLabel("In \(place.title)")
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 8 + 14 + 6 + FieldLine.width(title, scale: kitScale) + 8, height: 22)
    }

    override func layout() {
        super.layout()
        FieldLine.place([.box(icon, 14, 14), .text(title, fixed: true)], in: self, padding: 8, spacing: 6)
    }
}

final class PlaceOfferRowView: NSView {
    var place: FieldPlace { didSet { if place != oldValue { refresh() } } }
    private let icon = FieldLine.symbol("clock", size: 10, weight: .medium)
    private let title = FieldLine.label("", size: 13)
    private let cap = FieldKeyCap("Tab")

    init(place: FieldPlace) {
        self.place = place
        super.init(frame: .zero)
        title.setAccessibilityElement(false)
        for view in [icon, title, cap] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 38) }

    private func refresh() {
        icon.name = place.symbol
        title.text = "Search \(place.title)"
        setAccessibilityLabel("Search \(place.title), press Tab")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = cap.intrinsicContentSize
        FieldLine.place([.box(icon, 14, 14), .text(title), .spacer(0), .box(cap, size.width, size.height)], in: self, padding: 10, spacing: 10)
    }
}

final class FieldPlaceRowView: NSView {
    var item: FieldPlaceItem { didSet { if item != oldValue { refresh() } } }
    var lit: Bool {
        didSet {
            guard lit != oldValue else { return }
            trailing.layer?.kitTransition(Motion.kitQuick)
            refresh()
        }
    }

    private var icon: NSView?
    private var iconKey = ""
    private let title = FieldLine.label("", size: 14)
    private let detail = FieldLine.label("", size: 14, opacity: 0.68, overflow: .middle)
    private let trailing = NSView()
    private let aside = FieldLine.label("", size: 12, color: KitColor.muted)
    private var hints: [(cap: FieldKeyCap, word: KitLabel)] = []
    private var shownHints: [String] = []
    private var bar: NSProgressIndicator?
    private var progress: KitLabel?
    private var progressWidth: CGFloat = 0
    private var progressState: FetchEntry.State?
    private var watch: AnyCancellable?
    private weak var watched: FetchEntry?

    var splits: Bool { didSet { if splits != oldValue { refresh() } } }

    init(item: FieldPlaceItem, lit: Bool, splits: Bool = false) {
        self.item = item
        self.lit = lit
        self.splits = splits
        super.init(frame: .zero)
        trailing.wantsLayer = true
        for view in [title, detail, trailing] as [NSView] { addSubview(view) }
        trailing.addSubview(aside)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        for label in [title, detail, aside] { label.setAccessibilityElement(false) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var entry: FetchEntry? { item.fetch?.entry }

    private func refresh() {
        let entry = entry
        watchEntry(entry)
        let name = entry?.name ?? item.title
        let key = item.place == .downloads ? "file " + (name as NSString).pathExtension.lowercased() : "mark " + item.url.absoluteString
        if item.place != .downloads || key != iconKey || icon == nil {
            icon?.removeFromSuperview()
            let made: NSView
            if item.place == .downloads {
                let image = NSImageView(image: FieldPlace.icon(forFile: name))
                image.imageScaling = .scaleProportionallyUpOrDown
                made = image
            } else {
                let host = item.url.host().map(Address.withoutWWW) ?? ""
                made = FieldMark(icon: Favicons.shared.cached(for: item.url), letter: host.first.map { String($0).uppercased() } ?? "•", size: 18)
            }
            addSubview(made)
            icon = made
            iconKey = key
        }
        icon?.alphaValue = item.missing ? 0.45 : 1
        title.text = name
        title.color = item.missing ? KitColor.muted : KitColor.ink
        title.overflow = item.place == .downloads ? .middle : .tail
        detail.text = item.detail
        detail.isHidden = entry != nil || item.detail.isEmpty || lit
        if let entry {
            showProgress(entry)
        } else {
            bar?.removeFromSuperview()
            bar = nil
            progress?.removeFromSuperview()
            progress = nil
            progressState = nil
        }
        aside.text = entry.map { $0.state == .failed ? "Failed" : "" } ?? item.aside
        aside.isHidden = lit || aside.text.isEmpty
        let wanted = lit ? item.hints(splits: splits) : []
        let words = wanted.map { $0.keys + " " + $0.word }
        if words != shownHints {
            shownHints = words
            for hint in hints {
                hint.cap.removeFromSuperview()
                hint.word.removeFromSuperview()
            }
            hints = wanted.map { (FieldKeyCap($0.keys), FieldLine.label($0.word, size: 11.5, color: KitColor.muted)) }
            for hint in hints {
                hint.word.setAccessibilityElement(false)
                trailing.addSubview(hint.cap)
                trailing.addSubview(hint.word)
            }
        }
        let said = entry.map { [name, $0.detailText] } ?? [item.title, item.detail, item.aside]
        setAccessibilityLabel(said.filter { !$0.isEmpty }.joined(separator: ", "))
        needsLayout = true
    }

    private func watchEntry(_ entry: FetchEntry?) {
        guard watched !== entry || (entry == nil) != (watch == nil) else { return }
        watched = entry
        guard let entry else {
            watch = nil
            return
        }
        watch = kitObserve(initial: false, { [weak entry] in
            entry.map { ($0.state, $0.name, $0.fraction, $0.completedBytes, $0.totalBytes, $0.errorDescription) }
        }) { [weak self] _ in self?.refresh() }
    }

    private func showProgress(_ entry: FetchEntry) {
        let label = progress ?? {
            let made = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: KitColor.muted)
            made.setAccessibilityElement(false)
            addSubview(made)
            progress = made
            return made
        }()
        let failed = entry.state == .failed
        label.text = entry.detailText
        label.overflow = .tail
        label.toolTip = failed ? entry.detailText : nil
        if progressState != entry.state {
            progressState = entry.state
            progressWidth = 0
        }
        if entry.showsBar {
            let shown = bar ?? {
                let made = NSProgressIndicator()
                made.style = .bar
                made.controlSize = .small
                made.minValue = 0
                made.maxValue = 1
                made.isIndeterminate = false
                made.setAccessibilityElement(false)
                addSubview(made)
                bar = made
                return made
            }()
            if let fraction = entry.fraction {
                if shown.isIndeterminate {
                    shown.stopAnimation(nil)
                    shown.isIndeterminate = false
                }
                shown.doubleValue = min(1, max(0, fraction))
            } else if entry.state == .downloading || entry.state == .resuming {
                if !shown.isIndeterminate {
                    shown.isIndeterminate = true
                    shown.startAnimation(nil)
                }
            } else {
                if shown.isIndeterminate {
                    shown.stopAnimation(nil)
                    shown.isIndeterminate = false
                }
                shown.doubleValue = 0
            }
        } else {
            bar?.removeFromSuperview()
            bar = nil
        }
    }

    private var trailingWidth: CGFloat {
        let scale = kitScale
        if lit {
            let parts = hints.map { $0.cap.intrinsicContentSize.width + 5 + FieldLine.width($0.word, scale: scale) }
            return parts.reduce(0, +) + CGFloat(max(0, parts.count - 1)) * 10
        }
        return aside.isHidden ? 0 : FieldLine.width(aside, scale: scale)
    }

    static let barWidth: CGFloat = 64

    override func layout() {
        super.layout()
        var items: [FieldLine.Item] = []
        if let icon { items.append(.box(icon, 18, 18)) }
        items.append(.text(title, priority: 1))
        if let bar { items.append(.box(bar, Self.barWidth, bar.intrinsicContentSize.height)) }
        if let progress {
            if progressState == .failed {
                items.append(.text(progress, priority: 1))
            } else {
                progressWidth = max(progressWidth, FieldLine.width(progress, scale: kitScale))
                items.append(.box(progress, progressWidth, bounds.height))
            }
        } else if !detail.isHidden {
            let room = bounds.width - 20 - 18 - 12 * 3 - 8 - trailingWidth
            let fits = item.place != .downloads || FieldLine.width(title, scale: kitScale) + 60 < room
            detail.alphaValue = fits ? 1 : 0
            if fits { items.append(.text(detail, least: item.place == .downloads ? 0 : (bounds.width / 4).rounded())) }
        }
        items.append(.spacer(8))
        items.append(.box(trailing, trailingWidth, bounds.height))
        FieldLine.place(items, in: self, padding: 10, spacing: 12)
        aside.frame = trailing.bounds
        var x: CGFloat = 0
        let scale = kitScale
        for hint in hints {
            let cap = hint.cap.intrinsicContentSize
            hint.cap.frame = trailing.kitSnap(NSRect(x: x, y: (trailing.bounds.height - cap.height) / 2, width: cap.width, height: cap.height))
            x += cap.width + 5
            let word = FieldLine.width(hint.word, scale: scale)
            hint.word.frame = trailing.kitSnap(NSRect(x: x, y: 0, width: word, height: trailing.bounds.height))
            x += word + 10
        }
    }

    var bench: [String: Any] {
        ["title": title.text, "progress": progress?.text ?? "", "bar": bar != nil, "indeterminate": bar?.isIndeterminate ?? false,
         "fraction": bar?.doubleValue ?? 0, "hints": shownHints, "aside": aside.isHidden ? "" : aside.text,
         "dimmed": (icon?.alphaValue ?? 1) < 1, "progressWidth": Double(progress?.frame.width ?? 0),
         "titleWidth": Double(title.frame.width), "width": Double(bounds.width)]
    }
}

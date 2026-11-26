import AppKit
import Combine
import Observation

struct PointerWatch {
    private var seen: NSPoint?

    mutating func rest(at point: NSPoint = NSEvent.mouseLocation) { seen = point }

    mutating func moved(to point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard point != seen else { return false }
        seen = point
        return true
    }
}

struct FieldMenuItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    var keys = ""
    var parted = false
    var run: @MainActor () -> Void
}

@MainActor
@Observable
final class FieldMenu {
    private(set) var showing = false
    private(set) var heading = ""
    private(set) var items: [FieldMenuItem] = []
    var query = "" {
        didSet { picked = 0 }
    }
    var picked = 0
    @ObservationIgnored private var pointer = PointerWatch()
    @ObservationIgnored var location: () -> NSPoint = { NSEvent.mouseLocation }

    var shown: [FieldMenuItem] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    func open(heading: String, items: [FieldMenuItem]) {
        self.heading = heading
        self.items = items
        query = ""
        picked = 0
        pointer.rest(at: location())
        showing = true
    }

    func close() {
        guard showing else { return }
        showing = false
        query = ""
        items = []
    }

    func walk(_ step: Int) {
        let count = shown.count
        guard count > 0 else { return }
        picked = (picked + step + count) % count
    }

    func point(at index: Int) {
        guard pointer.moved(to: location()) else { return }
        picked = index
    }

    func runPicked() {
        let list = shown
        guard list.indices.contains(picked) else { return }
        take(list[picked])
    }

    func take(_ item: FieldMenuItem) {
        close()
        item.run()
    }
}

final class FieldMenuListView: NSView {
    let actions: FieldMenu
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    var room: CGFloat? { didSet { if room != oldValue { needsLayout = true } } }

    private let scroll = NSScrollView()
    private let page = KitFlippedView()
    private let header = FieldLine.label("", size: 13, opacity: 0.75)
    private let empty = FieldLine.label("No actions match", size: 14, color: KitColor.muted)
    private let slab = FieldSlabTrack()
    private let line = KitBox(fill: KitColor.ink.withAlphaComponent(0.1))
    private var rows: [FieldMenuRowView] = []
    private var rules: [KitBox] = []
    static let part: CGFloat = 9
    private var shownPicked: Int?
    private var lineOn = false
    private var area: NSTrackingArea?
    var held = false { didSet { if held != oldValue, !held { needsLayout = true } } }

    init(menu: FieldMenu, rowHeight: CGFloat, headerHeight: CGFloat, room: CGFloat? = nil) {
        self.actions = menu
        self.rowHeight = rowHeight
        self.headerHeight = headerHeight
        self.room = room
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.verticalScrollElasticity = .allowed
        scroll.contentView.drawsBackground = false
        scroll.documentView = page
        scroll.contentView.postsBoundsChangedNotifications = true
        page.addSubview(slab)
        page.addSubview(header)
        page.addSubview(empty)
        addSubview(scroll)
        line.alphaValue = 0
        addSubview(line)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        area = made
    }

    private func row(at event: NSEvent) -> Int? {
        let point = page.convert(event.locationInWindow, from: nil)
        return rows.firstIndex { $0.frame.minY <= point.y && point.y < $0.frame.maxY }
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = row(at: event) { actions.point(at: index) }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let index = row(at: event) else { return }
        let list = actions.shown
        guard list.indices.contains(index) else { return }
        actions.take(list[index])
    }

    override func layout() {
        super.layout()
        guard !held else { return }
        let list = actions.shown
        let picked = actions.picked
        header.text = actions.heading
        while rows.count > list.count { rows.removeLast().removeFromSuperview() }
        for (index, item) in list.enumerated() {
            if index < rows.count {
                rows[index].item = item
            } else {
                let made = FieldMenuRowView(item: item)
                page.addSubview(made)
                rows.append(made)
            }
        }
        empty.isHidden = !list.isEmpty
        let width = bounds.width
        let inner = width - 14
        header.frame = page.kitSnap(NSRect(x: 7 + 8, y: 0, width: max(0, inner - 8), height: headerHeight))
        empty.frame = NSRect(x: 7 + 10, y: headerHeight, width: max(0, inner - 20), height: rowHeight)
        var parts: [CGFloat] = []
        var y = headerHeight
        for (index, row) in rows.enumerated() {
            if list[index].parted, index > 0 {
                parts.append(y + Self.part / 2)
                y += Self.part
            }
            row.frame = NSRect(x: 7, y: y, width: inner, height: rowHeight)
            y += rowHeight
        }
        while rules.count > parts.count { rules.removeLast().removeFromSuperview() }
        while rules.count < parts.count {
            let rule = KitBox(fill: KitColor.ink.withAlphaComponent(0.1))
            page.addSubview(rule)
            rules.append(rule)
        }
        let thin = 1 / max(kitScale, 1)
        for (rule, middle) in zip(rules, parts) {
            rule.frame = page.kitSnap(NSRect(x: 7 + 10, y: middle - thin / 2, width: max(0, inner - 20), height: thin))
        }
        let content = list.isEmpty ? headerHeight + rowHeight : y
        scroll.frame = bounds
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: room ?? 0, right: 0)
        page.frame = NSRect(x: 0, y: 0, width: width, height: content)
        slab.frame = page.bounds
        let lit = list.indices.contains(picked) ? picked : nil
        slab.show(lit.map { rows[$0].frame }, at: lit, faint: false)
        line.frame = NSRect(x: 0, y: 0, width: width, height: 1 / max(kitScale, 1))
        if let lit, shownPicked != lit { reveal(rows[lit].frame) }
        shownPicked = lit
        scrolled()
    }

    private func reveal(_ rect: NSRect) {
        let clip = scroll.contentView
        let top = clip.bounds.minY
        let bottom = clip.bounds.maxY - (room ?? 0)
        var y = top
        if rect.minY < top { y = rect.minY } else if rect.maxY > bottom { y = rect.maxY - (bottom - top) }
        guard y != top else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        let clip = scroll.contentView.bounds
        let insets = scroll.contentInsets
        let on = clip.minY + insets.top > 1
        if on != lineOn {
            lineOn = on
            line.layer?.kitAnimate("opacity", to: on ? 1 : 0, curve: Motion.kitQuick)
            line.alphaValue = on ? 1 : 0
        }
        guard Store.testing else { return }
        let size = page.frame.height
        ColumnEdges.seen["field.top"] = on ? 1 : 0
        ColumnEdges.seen["field.bottom"] = clip.maxY - insets.bottom < size - 1 ? 1 : 0
        let numbers: [String: CGFloat] = ["offsetY": clip.minY, "contentH": size, "containerH": clip.height, "insetTop": insets.top,
                                          "insetBottom": insets.bottom, "visibleMinY": clip.minY, "visibleMaxY": clip.maxY]
        for (name, value) in numbers { ColumnEdges.seen["field." + name] = value }
    }
}

final class FieldMenuRowView: NSView {
    var item: FieldMenuItem {
        didSet {
            guard item.id != oldValue.id || item.title != oldValue.title || item.symbol != oldValue.symbol || item.keys != oldValue.keys else { return }
            refresh()
        }
    }

    private let icon = FieldLine.symbol("circle", size: 13)
    private let title = FieldLine.label("", size: 14)
    private let keys = FieldLine.label("", size: 12, weight: .medium, color: KitColor.muted)

    init(item: FieldMenuItem) {
        self.item = item
        super.init(frame: .zero)
        for view in [icon, title, keys] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func refresh() {
        icon.name = item.symbol
        title.text = item.title
        keys.text = item.keys
        keys.isHidden = item.keys.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var items: [FieldLine.Item] = [.box(icon, 18, 18), .text(title), .spacer(0)]
        if !keys.isHidden { items.append(.text(keys)) }
        FieldLine.place(items, in: self, padding: 10, spacing: 12)
    }
}

extension Browser {
    enum RowOpening {
        case background, newTab, atEnd
    }

    static let siteRow = -1

    var fieldRow: Int? { pointed ?? picked }

    var pickedOffer: Suggestion? {
        fieldRow.flatMap { offers.indices.contains($0) ? offers[$0] : nil }
    }

    func point(at index: Int) {
        guard pointer.moved() else { return }
        pointed = index
    }

    func pointerTaken() {
        defer { pointed = nil }
        if let pointed, offers.indices.contains(pointed) { picked = pointed }
    }

    func fieldActions() {
        if fieldMenu.showing {
            fieldMenu.close()
            return
        }
        let offer = pickedOffer
        fieldMenu.open(heading: offer?.primary ?? "This Page", items: fieldMenuItems(for: offer))
    }

    func open(row offer: Suggestion, _ how: RowOpening) {
        if case .answer(let answer) = offer.kind {
            copyAnswer(answer, whole: false)
            return
        }
        if let item = offer.placed {
            switch how {
            case .background: openPlaced(item, aside: true)
            case .newTab: openPlaced(item, aside: true, front: true)
            case .atEnd: openPlacedAtEnd(item)
            }
            return
        }
        if case .snippet(let snippet) = offer.kind {
            chooseSnippet(snippet)
            return
        }
        if case .action(let id) = offer.kind {
            runFieldAction(id)
            return
        }
        switch how {
        case .background:
            open(offer.url, foreground: false, from: active, mayWait: true)
        case .newTab:
            open(offer.url, foreground: true, from: active)
            quitField()
        case .atEnd:
            open(offer.url, foreground: true, atEnd: true, from: active)
            quitField()
        }
    }

    func copyLink(of offer: Suggestion) {
        copyToPasteboard(PageHit.plain(offer.url).absoluteString)
        announce("Link copied")
    }

    func copyMarkdown(of offer: Suggestion) {
        copyToPasteboard(Browser.markdownLink(offer.primary, PageHit.plain(offer.url)))
        announce("Markdown link copied")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func fillsPair(with tab: Tab) -> Bool {
        guard let blank = active, blank.isBlank, split(for: blank) != nil,
              tab.shy == blank.shy, split(for: tab)?.contains(blank.id) != true else { return false }
        fill(blank, with: tab)
        return true
    }

    func forgetRow(_ offer: Suggestion) {
        forgetPage(History.identity(for: offer.url)) { [weak self] in
            guard let self, self.fieldShowing else { return }
            self.retype()
        }
        retype()
    }

    @discardableResult
    func forgetPage(_ key: String, after: @escaping @MainActor () -> Void = {}) -> Bool {
        guard let gone = history.forgetPage(key) else {
            history.forget(key)
            return false
        }
        announce("Forgot \(gone.name)", undo: { [weak self] in
            self?.history.restore(gone)
            after()
        })
        return true
    }

    func forgetSite(of offer: Suggestion) {
        guard let host = offer.url.host() else { return }
        history.forget(site: host)
        forgetVideoTraces(of: host)
        SiteNameBook.forget(site: host)
        announce("Forgot \(Address.withoutWWW(host))")
        retype()
    }

    func forgetSince(_ date: Date, said: String) {
        history.forget(since: date)
        forgetVideoTraces(since: date)
        SiteNameBook.forget(since: date)
        announce(said)
        retype()
    }

    private func isHistoryRow(_ offer: Suggestion) -> Bool {
        (offer.kind == .visited || offer.kind == .passage) && history.knows(History.identity(for: offer.url))
    }

    func fieldMenuItems(for offer: Suggestion?) -> [FieldMenuItem] {
        guard let offer else { return fieldPlace.map(restingPlaceItems) ?? pageMenuItems() }
        if let item = offer.placed { return placeMenuItems(item) }
        var items: [FieldMenuItem] = []
        func add(_ id: String, _ title: String, _ symbol: String, keys: String = "", run: @escaping @MainActor () -> Void) {
            items.append(FieldMenuItem(id: id, title: title, symbol: symbol, keys: keys, run: run))
        }

        if case .snippet(let snippet) = offer.kind {
            add("snippet", snippetField.target?.editor == true ? "Insert Snippet" : "Copy Snippet", "text.insert", keys: "↩") { [weak self] in
                self?.chooseSnippet(snippet)
            }
            return items
        }

        if case .answer(let answer) = offer.kind {
            add("copy", "Copy", "doc.on.doc", keys: "↩") { [weak self] in self?.copyAnswer(answer, whole: false) }
            add("copyWhole", "Copy with Question", "equal", keys: "⌘↩") { [weak self] in self?.copyAnswer(answer, whole: true) }
            return items
        }

        if case .action(let id) = offer.kind {
            add("run", "Run", "return", keys: "↩") { [weak self] in self?.take(offer) }
            if id.hasPrefix("quick:") { addQuickItems(String(id.dropFirst("quick:".count)), offer, into: &items) }
            addNowItems(offer, into: &items)
            addFavoriteItems(offer, into: &items)
            return items
        }

        if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
            add("switch", "Switch to Tab", "arrow.right.square", keys: "↩") { [weak self] in self?.take(offer) }
            add("close", "Close Tab", "xmark.square") { [weak self] in
                self?.closeTab(tab)
                self?.retype()
            }
        } else {
            let opens = offer.kind == .search || offer.kind == .suggested ? "Search" : "Open"
            add("open", opens, "return", keys: "↩") { [weak self] in self?.take(offer) }
            add("background", "\(opens) in Background", "square.on.square", keys: "⌘↩") { [weak self] in
                self?.open(row: offer, .background)
            }
            add("newTab", "\(opens) in New Tab", "plus.square", keys: "⇧⌘↩") { [weak self] in
                self?.open(row: offer, .newTab)
            }
            if splitsFromField(offer.kind) {
                add("split", "Open in Split View", "rectangle.split.2x1", keys: "⌥↩") { [weak self] in self?.openRowInSplit(offer) }
            }
            add("atEnd", "\(opens) in New Tab at the End", "arrow.right.to.line") { [weak self] in
                self?.open(row: offer, .atEnd)
            }
        }
        add("copy", "Copy Link", "link", keys: "⇧⌘C") { [weak self] in self?.copyLink(of: offer) }
        add("markdown", LinkCopy.title(.markdown, count: 1), "text.badge.checkmark") { [weak self] in self?.copyMarkdown(of: offer) }
        addFavoriteItems(offer, into: &items)
        if isHistoryRow(offer) {
            add("forget", "Forget from History", "clock.badge.xmark", keys: "⇧⌫") { [weak self] in self?.forgetRow(offer) }
            if let host = offer.url.host() {
                add("forgetSite", "Forget \(Address.withoutWWW(host))", "globe.badge.chevron.backward") { [weak self] in
                    self?.forgetSite(of: offer)
                }
            }
            add("forgetHour", "Forget the Last Hour", "clock.arrow.circlepath") { [weak self] in
                self?.forgetSince(Date().addingTimeInterval(-3600), said: "Forgot the last hour")
            }
            add("forgetToday", "Forget Today", "calendar.badge.minus") { [weak self] in
                self?.forgetSince(Calendar.current.startOfDay(for: Date()), said: "Forgot today")
            }
            items.append(FieldMenuItem(id: "clearHistory", title: Clearing.history.row, symbol: "trash", parted: true) { [weak self] in
                guard let self else { return }
                let window = self.window
                self.quitField()
                self.askToClear(.history, over: window)
            })
        }
        return items
    }

    private func addQuickItems(_ id: String, _ offer: Suggestion, into items: inout [FieldMenuItem]) {
        let store = QuickActions.shared
        items.append(FieldMenuItem(id: "copy", title: "Copy Link", symbol: "link", keys: "⇧⌘C") { [weak self] in
            self?.copyLink(of: offer)
        })
        if store.isSuggestion(id) {
            items.append(FieldMenuItem(id: "keep", title: "Keep in Quick Actions", symbol: "plus.circle") { [weak self] in
                store.keep(id)
                self?.retype()
            })
            items.append(FieldMenuItem(id: "dismiss", title: "Don't Suggest This", symbol: "minus.circle") { [weak self] in
                store.dismiss(id)
                self?.retype()
            })
        } else if store.isCustom(id) || store.saved.kept.contains(id) {
            items.append(FieldMenuItem(id: "remove", title: "Remove from Quick Actions", symbol: "minus.circle") { [weak self] in
                store.remove(id)
                self?.retype()
            })
        }
    }

    func pageMenuItems() -> [FieldMenuItem] {
        var items: [FieldMenuItem] = []
        if !typed.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(FieldMenuItem(id: "go", title: "Go", symbol: "return", keys: "↩") { [weak self] in self?.submit() })
        }
        guard let tab = active, !tab.isBlank else { return items }
        items.append(FieldMenuItem(id: "copy", title: LinkCopy.title(.address, count: 1), symbol: "link") { [weak self] in
            self?.copyPage(.address)
            self?.quitField()
        })
        items.append(FieldMenuItem(id: "markdown", title: LinkCopy.title(.markdown, count: 1), symbol: "text.badge.checkmark") { [weak self] in
            self?.copyPage(.markdown)
            self?.quitField()
        })
        items.append(FieldMenuItem(id: "rich", title: LinkCopy.title(.rich, count: 1), symbol: "link.badge.plus") { [weak self] in
            self?.copyPage(.rich)
            self?.quitField()
        })
        if tab.isWeb {
            items.append(FieldMenuItem(id: "pageMarkdown", title: "Copy Page as Markdown", symbol: "doc.plaintext",
                                       keys: ShortcutStore.shared.key(for: "edit.copyPageMarkdown")?.display ?? "") { [weak self] in
                self?.quitField()
                self?.copyPageAsMarkdown()
            })
        }
        items.append(FieldMenuItem(id: "duplicate", title: "Duplicate Tab", symbol: "plus.square.on.square",
                                   keys: ShortcutStore.shared.key(for: "tabs.duplicate")?.display ?? "") { [weak self] in
            self?.quitField()
            self?.duplicate()
        })
        return items
    }

    func fieldKey(_ event: NSEvent) -> Bool {
        guard !fieldMenu.showing, let combo = KeyCombo(event: event) else { return false }
        if fieldPlace != nil { return placeKey(combo) }
        let row = pickedOffer
        if handleNowKey(combo) { return true }
        if handleFavoriteKey(combo) { return true }
        if combo == KeyCombo("return", command: false, option: true) {
            submit(split: true)
            return true
        }
        if combo == KeyCombo("delete", command: false, shift: true) || combo == KeyCombo("x", command: false, control: true) {
            guard let row, isHistoryRow(row) else { return false }
            forgetRow(row)
            return true
        }
        if combo == KeyCombo("c", shift: true), let row, row.url != FieldAction.nowhere {
            copyLink(of: row)
            return true
        }
        return false
    }
}

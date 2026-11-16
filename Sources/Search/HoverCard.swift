import AppKit
import Combine
import Observation
import WebKit

@MainActor
enum HoverEntry: @MainActor Identifiable {
    case folder(TabGroup)
    case tab(Tab)

    var id: UUID {
        switch self {
        case .folder(let group): return group.id
        case .tab(let tab): return tab.id
        }
    }

    var words: String {
        switch self {
        case .folder(let group): return group.name
        case .tab(let tab): return tab.label + " " + (tab.address?.absoluteString ?? "")
        }
    }
}

@MainActor
@Observable
final class HoverCards {
    enum Kind: Equatable {
        case tab(Tab.ID)
        case folder(UUID)
    }

    enum Key: Equatable {
        case up, down, left, right, enter, escape, delete
        case text(String)

        init?(_ event: NSEvent) {
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return nil }
            switch event.keyCode {
            case 126: self = .up
            case 125: self = .down
            case 123: self = .left
            case 124: self = .right
            case 36, 76: self = .enter
            case 53: self = .escape
            case 51: self = .delete
            default:
                guard let text = event.characters, !text.isEmpty,
                      text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return nil }
                self = .text(text)
            }
        }
    }

    static var dwell: TimeInterval = 0.6
    static let quick: TimeInterval = 0.08
    static let grace: TimeInterval = 0.25
    static let width: CGFloat = 268
    static let column = "hoverColumn"

    private(set) var kind: Kind?
    private(set) var frame: CGRect = .zero
    private(set) var picture: NSImage?
    private(set) var query = ""
    private(set) var path: [UUID] = []
    private(set) var selection = 0
    var plainGround = false

    @ObservationIgnored private weak var browser: Browser?
    @ObservationIgnored private var aim: Kind?
    @ObservationIgnored private var spent = false
    @ObservationIgnored private var waiting: DispatchWorkItem?
    @ObservationIgnored private var leaving: DispatchWorkItem?
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var warm = Date.distantPast
    @ObservationIgnored private var asked: UUID?
    @ObservationIgnored private var onList = false

    init(browser: Browser) { self.browser = browser }

    var space: UUID? { browser?.spaceID }

    var hasIntegrationLinks: Bool {
        entries.contains { entry in
            guard case .tab(let tab) = entry, !tab.shy, let address = tab.shownURL?.absoluteString else { return false }
            return IntegrationLink(address) != nil
        }
    }

    var selectedTab: Tab? {
        let list = entries
        guard list.indices.contains(selection), case .tab(let tab) = list[selection] else { return nil }
        return tab
    }

    private var sliding: Bool {
        guard let browser else { return false }
        return browser.spaceSliding || browser.spaceMotion.moving || browser.spaceMotion.offset != 0
            || SpaceSwipe.shared.target(of: browser) != nil
    }

    func quiet() {
        guard aim != nil || kind != nil else { return }
        clear()
    }

    func enter(_ next: Kind, frame: CGRect) {
        guard !sliding else { return quiet() }
        leaving?.cancel()
        guard aim != next else {
            if kind == next, self.frame != frame {
                if case .tab = next { dismiss() } else { self.frame = frame }
            } else if kind == nil {
                self.frame = frame
            }
            return
        }
        clear()
        aim = next
        spent = false
        self.frame = frame
        watch()
        let work = DispatchWorkItem { [weak self] in self?.show(next) }
        waiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (Date() < warm ? HoverCards.quick : HoverCards.dwell), execute: work)
    }

    func leave(_ old: Kind) {
        guard aim == old else { return }
        if case .folder = old, kind == old {
            let work = DispatchWorkItem { [weak self] in self?.clear() }
            leaving = work
            DispatchQueue.main.asyncAfter(deadline: .now() + HoverCards.grace, execute: work)
        } else {
            clear()
        }
    }

    func overList(_ over: Bool) {
        guard case .folder(let id)? = kind else { return }
        onList = over
        if over { leaving?.cancel() } else { leave(.folder(id)) }
    }

    func dismiss() {
        let held = aim
        clear()
        aim = held
        spent = true
    }

    func show(_ next: Kind) {
        guard aim == next, !spent, Store.testing || NSEvent.pressedMouseButtons == 0, let browser, browser.prefs.hoverCards else { return }
        guard !sliding else { return quiet() }
        switch next {
        case .tab(let id):
            guard let tab = browser.tabs.first(where: { $0.id == id }), !tab.isBlank else { return }
            kind = next
            load(tab)
        case .folder(let id):
            guard browser.tabGroups.contains(where: { $0.id == id }) else { return }
            path = [id]
            kind = next
        }
    }

    private func load(_ tab: Tab) {
        let request = UUID()
        asked = request
        picture = browser?.tabSwitcher.preview(for: tab.id, address: tab.address)
        tab.preview(width: HoverCards.width * 1.5) { [weak self] image in
            guard let self, self.asked == request, let image else { return }
            self.picture = image
        }
    }

    private func clear() {
        waiting?.cancel()
        leaving?.cancel()
        waiting = nil
        leaving = nil
        if kind != nil { warm = Date().addingTimeInterval(0.4) }
        if kind != nil { kind = nil }
        aim = nil
        spent = false
        asked = nil
        if !query.isEmpty { query = "" }
        if !path.isEmpty { path = [] }
        if selection != 0 { selection = 0 }
        onList = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self else { return event }
            return self.heard(event)
        }
    }

    private func heard(_ event: NSEvent) -> NSEvent? {
        guard case .folder? = kind else {
            dismiss()
            return event
        }
        if event.type == .keyDown {
            if browser?.window?.firstResponder is NSText {
                dismiss()
                return event
            }
            if !takesKeys(from: browser?.window?.firstResponder) { return event }
            guard let key = Key(event) else { return event }
            press(key)
            return nil
        }
        if event.type == .rightMouseDown { dismiss() }
        return event
    }

    func takesKeys(from responder: NSResponder?) -> Bool {
        onList || !(responder is WKWebView)
    }

    var entries: [HoverEntry] {
        guard let browser, let id = path.last else { return [] }
        let folders = browser.tabGroups.filter { $0.parent == id }.map(HoverEntry.folder)
        let tabs = browser.tabs(in: id).map(HoverEntry.tab)
        let words = SearchFolders.words(of: query)
        return (folders + tabs).filter { SearchFolders.matchesAll($0.words, words: words) }
    }

    var title: String {
        browser?.tabGroups.first { $0.id == path.last }?.name ?? ""
    }

    func press(_ key: Key) {
        let list = entries
        switch key {
        case .up:
            selection = max(0, selection - 1)
        case .down:
            selection = min(max(0, list.count - 1), selection + 1)
        case .right:
            if list.indices.contains(selection), case .folder(let group) = list[selection] { step(into: group.id) }
        case .left:
            guard path.count > 1 else { return }
            path.removeLast()
            query = ""
            selection = 0
        case .enter:
            guard list.indices.contains(selection) else { return }
            open(list[selection])
        case .escape:
            dismiss()
        case .delete:
            guard !query.isEmpty else { return }
            query.removeLast()
            selection = 0
        case .text(let text):
            query += text
            selection = 0
        }
    }

    private func step(into id: UUID) {
        path.append(id)
        query = ""
        selection = 0
    }

    func open(_ entry: HoverEntry) {
        switch entry {
        case .folder(let group):
            step(into: group.id)
        case .tab(let tab):
            browser?.clearTabSelection()
            browser?.select(tab)
            dismiss()
        }
    }

    func point(at index: Int) {
        if selection != index { selection = index }
    }

    static func doing(_ tab: Tab) -> String? {
        var marks: [String] = []
        if tab.shy { marks.append("Private") }
        if tab.recording { marks.append("Recording") }
        if tab.loading {
            marks.append("Loading")
        } else if tab.muted {
            marks.append("Muted")
        } else if tab.noisy {
            marks.append("Playing sound")
        }
        return marks.isEmpty ? nil : marks.joined(separator: " · ")
    }
}

final class CardGroundView: NSView {
    var plain: Bool
    let content: NSView

    private let holder = KitFlippedView()

    init(_ content: NSView, plain: Bool) {
        self.content = content
        self.plain = plain
        super.init(frame: .zero)
        holder.addSubview(content)
        addSubview(holder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        holder.frame = bounds
        content.frame = holder.bounds
    }
}

final class HoverLayerView: NSView {
    let cards: HoverCards
    weak var browser: Browser?

    private var shown: HoverCards.Kind?
    private var card: NSView?
    private var tabCard: TabCardView?
    private var popup: KitPopup?
    private var placed: NSRect?

    init(cards: HoverCards, browser: Browser) {
        self.cards = cards
        self.browser = browser
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let _ = Bodies.tick("HoverLayer")
        let kind = cards.kind
        if kind != shown || card == nil {
            swap(to: kind)
        }
        guard let card, let window, let content = window.contentView else { return }
        card.layoutSubtreeIfNeeded()
        let size = NSSize(width: HoverCards.width, height: card.fittingSize.height)
        let frame = cards.frame
        let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
        let row = NSRect(x: frame.minX - Metrics.sideInset, y: top, width: frame.width + 2 * Metrics.sideInset, height: frame.height)
        let passive = card is TabCardView
        if let popup, popup.isShown {
            if popup.content !== card { popup.hold(card, size: size) } else { popup.resize(to: size) }
            popup.passive = passive
            if row != placed {
                placed = row
                popup.move(to: row, of: content)
            }
            return
        }
        if let other = KitPopup.current(in: window), other !== popup {
            cards.dismiss()
            return
        }
        if browser?.downloadsOpen == true {
            cards.dismiss()
            return
        }
        placed = row
        popup = KitPopup.show(card, size: size, from: row, of: content, edge: .page, follows: true, bleeds: true, passive: passive) { [weak self] in
            guard let self, self.popup != nil else { return }
            self.popup = nil
            self.cards.dismiss()
        }
    }

    private func swap(to kind: HoverCards.Kind?) {
        guard let kind else {
            shown = nil
            card = nil
            tabCard = nil
            let going = popup
            popup = nil
            going?.close()
            return
        }
        shown = kind
        switch kind {
        case .tab(let id):
            guard let browser, let tab = browser.tabs.first(where: { $0.id == id }) else {
                card = nil
                tabCard = nil
                let going = popup
                popup = nil
                going?.close()
                return
            }
            if let tabCard, tabCard.tab === tab { return }
            let made = TabCardView(cards: cards, tab: tab)
            tabCard = made
            card = made
        case .folder:
            tabCard = nil
            card = FolderListView(cards: cards)
        }
    }
}

final class TabCardView: NSView {
    let cards: HoverCards
    let tab: Tab
    private let space: UUID?

    private let ground: CardGroundView
    private let body = KitFlippedView()
    private let well = KitBox(fill: Palette.NS.wash)
    private let picture = NSImageView()
    private let mark = MarkView(size: 24)
    private let title = KitLabel("", font: .systemFont(ofSize: 13, weight: .semibold))
    private let host = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let doing = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private var preview: NSView?
    private var previewAddress: String?

    init(cards: HoverCards, tab: Tab) {
        self.cards = cards
        self.tab = tab
        space = cards.space
        ground = CardGroundView(body, plain: cards.plainGround)
        super.init(frame: NSRect(x: 0, y: 0, width: HoverCards.width, height: 60))
        wantsLayer = true
        addSubview(ground)
        well.corners = .radius(9)
        well.layer?.masksToBounds = true
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        well.addSubview(mark)
        well.addSubview(picture)
        body.addSubview(well)
        title.lines = 2
        for label in [title, host, doing] { body.addSubview(label) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var integration: String? {
        guard let address = tab.shownURL?.absoluteString, !tab.shy, IntegrationLink(address) != nil else { return nil }
        return address
    }

    private func refresh() {
        ground.plain = cards.plainGround
        title.text = tab.label
        host.text = tab.shownURL?.host().map(Address.withoutWWW) ?? ""
        doing.text = HoverCards.doing(tab) ?? ""
        let integration = integration
        if integration != previewAddress {
            preview?.removeFromSuperview()
            preview = integration.map { IntegrationHoverPreviewView(address: $0, space: space) }
            if let preview { body.addSubview(preview) }
            previewAddress = integration
        }
        let image = cards.picture
        picture.image = image
        picture.isHidden = image == nil
        mark.isHidden = image != nil
        mark.icon = tab.icon
        mark.letter = tab.monogram
    }

    private func arrange(width: CGFloat) -> CGFloat {
        let inner = width - 16
        var y: CGFloat = 8
        well.isHidden = true
        if let preview {
            preview.frame = NSRect(x: 8, y: y, width: inner, height: 148)
            y += 148 + 8
        } else if tab.isWeb {
            well.isHidden = false
            well.frame = NSRect(x: 8, y: y, width: inner, height: 148)
            mark.frame = NSRect(x: (inner - 24) / 2, y: (148 - 24) / 2, width: 24, height: 24)
            if let image = picture.image, image.size.width > 0, image.size.height > 0 {
                let scale = max(inner / image.size.width, 148 / image.size.height)
                let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
                picture.frame = NSRect(x: (inner - size.width) / 2, y: (148 - size.height) / 2, width: size.width, height: size.height)
            }
            y += 148 + 8
        }
        let text = inner - 8
        let lineHeight = NSLayoutManager().defaultLineHeight(for: title.font)
        let titleHeight = min(ceil(title.measure(width: text).height), ceil(lineHeight * 2))
        title.frame = kitSnap(NSRect(x: 12, y: y, width: text, height: titleHeight))
        y += titleHeight
        for label in [host, doing] {
            label.isHidden = label.text.isEmpty
            guard !label.isHidden else { continue }
            y += 3
            let height = label.intrinsicContentSize.height
            label.frame = kitSnap(NSRect(x: 12, y: y, width: text, height: height))
            y += height
        }
        return y + 2 + 8
    }

    override var fittingSize: NSSize {
        refresh()
        return NSSize(width: HoverCards.width, height: arrange(width: HoverCards.width))
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        refresh()
        _ = arrange(width: bounds.width)
        ground.frame = bounds
    }
}

final class FolderListView: KitHoverView {
    let cards: HoverCards

    private let ground: CardGroundView
    private let body = KitFlippedView()
    private let back = KitButton(.plain(press: 0.94), label: "Back")
    private let heading = KitLabel("", font: .systemFont(ofSize: 12, weight: .semibold), color: KitColor.muted)
    private let note = KitLabel("Point at an issue to see its state", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let empty = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let scroll = NSScrollView()
    private let rowsView = KitFlippedView()
    private var rows: [FolderListRowView] = []
    private var preview: NSView?
    private var previewAddress: String?

    init(cards: HoverCards) {
        self.cards = cards
        ground = CardGroundView(body, plain: cards.plainGround)
        super.init(frame: NSRect(x: 0, y: 0, width: HoverCards.width, height: 60))
        wantsLayer = true
        addSubview(ground)
        back.content = KitSymbol("chevron.left", style: KitSymbol.Style(size: 9, weight: .semibold), tint: KitColor.muted)
        back.action = { [weak cards] in cards?.press(.left) }
        body.addSubview(back)
        body.addSubview(heading)
        body.addSubview(note)
        body.addSubview(empty)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = rowsView
        body.addSubview(scroll)
        onHover = { [weak cards] in cards?.overList($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() -> [HoverEntry] {
        ground.plain = cards.plainGround
        let entries = cards.entries
        back.isHidden = cards.path.count <= 1
        let typed = !cards.query.isEmpty
        heading.text = typed ? cards.query : cards.title
        heading.color = typed ? KitColor.ink : KitColor.muted
        (back.content as? KitSymbol)?.tint = typed ? KitColor.ink : KitColor.muted
        var address: String?
        if cards.hasIntegrationLinks, let tab = cards.selectedTab, !tab.shy, let link = tab.shownURL?.absoluteString, IntegrationLink(link) != nil {
            address = link
        }
        if address != previewAddress || (cards.hasIntegrationLinks && address == nil && preview != nil) {
            preview?.removeFromSuperview()
            preview = address.map { IntegrationHoverPreviewView(address: $0, space: cards.space) }
            if let preview { body.addSubview(preview) }
            previewAddress = address
        }
        if !cards.hasIntegrationLinks, preview != nil {
            preview?.removeFromSuperview()
            preview = nil
            previewAddress = nil
        }
        note.isHidden = !(cards.hasIntegrationLinks && preview == nil)
        empty.text = typed ? "No tabs match" : "Nothing here yet"
        empty.isHidden = !entries.isEmpty
        scroll.isHidden = entries.isEmpty
        if rows.map(\.entry.id) != entries.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = entries.enumerated().map { FolderListRowView(cards: cards, entry: $1, index: $0) }
            rows.forEach { rowsView.addSubview($0) }
        }
        for row in rows { row.chosen = cards.selection == row.index }
        return entries
    }

    private func arrange(width: CGFloat, entries count: Int) -> CGFloat {
        let inner = width - 12
        var y: CGFloat = 6
        let headX: CGFloat = 6 + 8
        var x = headX
        if !back.isHidden {
            back.frame = NSRect(x: x, y: y + 4, width: 14, height: 14)
            x += 14 + 6
        }
        heading.frame = kitSnap(NSRect(x: x, y: y, width: max(0, 6 + inner - 8 - x), height: 22))
        y += 22 + 4
        if cards.hasIntegrationLinks {
            let box = NSRect(x: 6 + 8, y: y, width: inner - 16, height: 148)
            preview?.frame = box
            note.frame = kitSnap(NSRect(x: box.minX + 8, y: box.minY + 8, width: box.width - 16, height: note.intrinsicContentSize.height))
            y += 148 + 4
        }
        if count == 0 {
            empty.frame = kitSnap(NSRect(x: 6 + 8, y: y, width: inner - 16, height: 28))
            y += 28
        } else {
            let height = min(CGFloat(count) * PopupLook.row, PopupLook.row * (cards.hasIntegrationLinks ? 6 : 12))
            scroll.frame = NSRect(x: 6, y: y, width: inner, height: height)
            rowsView.frame = NSRect(x: 0, y: 0, width: inner, height: CGFloat(count) * PopupLook.row)
            for (index, row) in rows.enumerated() {
                row.frame = NSRect(x: 0, y: CGFloat(index) * PopupLook.row, width: inner, height: PopupLook.row)
            }
            y += height
        }
        return y + 6
    }

    override var fittingSize: NSSize {
        let entries = refresh()
        return NSSize(width: HoverCards.width, height: arrange(width: HoverCards.width, entries: entries.count))
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        let entries = refresh()
        _ = arrange(width: bounds.width, entries: entries.count)
        ground.frame = bounds
        if let chosen = rows.first(where: \.chosen) { rowsView.scrollToVisible(chosen.frame) }
    }
}

private final class FolderListRowView: KitHoverView {
    let cards: HoverCards
    let entry: HoverEntry
    let index: Int
    var chosen = false { didSet { if chosen != oldValue { ground.layer?.kitTransition(Motion.kitQuick); ground.fill = chosen ? Palette.NS.wash : nil } } }

    private let ground = KitBox(fill: nil, corners: .radius(PopupLook.rowCorner))
    private let label = KitLabel("", font: .systemFont(ofSize: 13))
    private var leading: NSView?
    private let chevron = KitSymbol("chevron.right", style: KitSymbol.Style(size: 9, weight: .semibold), tint: KitColor.muted)

    init(cards: HoverCards, entry: HoverEntry, index: Int) {
        self.cards = cards
        self.entry = entry
        self.index = index
        super.init(frame: .zero)
        addSubview(ground)
        switch entry {
        case .folder(let group):
            let mark = FolderMarkView()
            mark.icon = group.icon?.image
            mark.open = group.collapsed ? 0 : 1
            leading = mark
            label.text = group.name
            addSubview(chevron)
        case .tab(let tab):
            let mark = MarkView(icon: tab.icon, letter: tab.monogram, size: 15)
            mark.dim = tab.asleep
            leading = mark
            label.text = tab.label
        }
        if let leading { addSubview(leading) }
        addSubview(label)
        onHover = { [weak self] over in
            guard let self, over else { return }
            self.cards.point(at: self.index)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label.text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        cards.open(entry)
    }

    override func mouseDown(with event: NSEvent) {}

    override func accessibilityPerformPress() -> Bool {
        cards.open(entry)
        return true
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        var x: CGFloat = 8
        switch entry {
        case .folder:
            leading?.frame = kitSnap(NSRect(x: x, y: (bounds.height - 15) / 2, width: 19, height: 15))
            x += 19 + 8
            let chevronSize = chevron.intrinsicContentSize
            chevron.frame = kitSnap(NSRect(x: bounds.width - 8 - chevronSize.width, y: (bounds.height - chevronSize.height) / 2,
                                           width: chevronSize.width, height: chevronSize.height))
            label.frame = kitSnap(NSRect(x: x, y: 0, width: max(0, chevron.frame.minX - 8 - x), height: bounds.height))
        case .tab:
            leading?.frame = kitSnap(NSRect(x: x, y: (bounds.height - 15) / 2, width: 15, height: 15))
            x += 15 + 8
            label.frame = kitSnap(NSRect(x: x, y: 0, width: max(0, bounds.width - 8 - x), height: bounds.height))
        }
    }
}

extension HoverCards {
    static func surface(plain: Bool) -> NSView? {
        guard let browser = Browsers.front else { return nil }
        let cards = HoverCards(browser: browser)
        cards.plainGround = plain
        let tab = BenchArt.tab("Broadway, a calmer browser for the whole web, with a long title", address: "https://www.example.com/a/page")
        let card = TabCardView(cards: cards, tab: tab)
        card.frame = NSRect(origin: .zero, size: card.fittingSize)
        return BenchPadded(card, pad: 8)
    }

    static func folderSurface(plain: Bool) -> NSView? {
        guard let cards = folderFixture(plain: plain) else { return nil }
        let list = FolderListView(cards: cards)
        list.frame = NSRect(origin: .zero, size: list.fittingSize)
        return BenchPadded(list, pad: 8)
    }

    static func folderFixture(plain: Bool) -> HoverCards? {
        guard let browser = Browsers.front else { return nil }
        let name = "Bench folder"
        if !browser.tabGroups.contains(where: { $0.name == name }) {
            _ = browser.newFolder(inside: nil, named: name, editing: false)
            if let made = browser.tabGroups.first(where: { $0.name == name }) {
                _ = browser.newFolder(inside: made.id, named: "Plans for the spring", editing: false)
                _ = browser.newFolder(inside: made.id, named: "Reading", editing: false)
            }
        }
        guard let group = browser.tabGroups.first(where: { $0.name == name }) else { return nil }
        let cards = HoverCards(browser: browser)
        cards.plainGround = plain
        cards.enter(.folder(group.id), frame: CGRect(x: 10, y: 120, width: 220, height: 34))
        cards.show(.folder(group.id))
        cards.press(.down)
        return cards
    }
}

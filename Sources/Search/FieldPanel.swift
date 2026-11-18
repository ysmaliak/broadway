import AppKit
import Combine

struct FieldSection: Identifiable, Equatable {
    let title: String
    let range: Range<Int>
    var id: String { title }
}

extension Suggestion {
    var primary: String {
        switch kind {
        case .search, .suggested, .open, .command, .action, .snippet: return key
        case .answer(let answer): return answer.answer
        case .placed(let item): return item.title
        default: return title.isEmpty ? Address.withoutWWW(key) : title
        }
    }

    var secondary: String {
        switch kind {
        case .open, .command, .action, .snippet: return title
        case .search: return title
        case .suggested: return ""
        case .passage: return note
        case .answer(let answer): return answer.detail.isEmpty ? answer.expression : answer.detail
        case .placed(let item): return item.detail
        default: return title.isEmpty ? "" : Address.withoutWWW(key)
        }
    }

    var pickIsSwitch: Bool { tab != nil }
}

@MainActor
enum FieldLine {
    enum Item {
        case box(NSView, CGFloat, CGFloat)
        case text(KitLabel, priority: Int = 0, fixed: Bool = false)
        case spacer(CGFloat)
    }

    static func width(_ label: KitLabel, scale: CGFloat) -> CGFloat {
        ceil(KitLabelFit.width(label) * scale) / scale
    }

    static func place(_ items: [Item], in view: NSView, padding: CGFloat, trailing: CGFloat? = nil, spacing: CGFloat) {
        let scale = view.kitScale
        let height = view.bounds.height
        var left = view.bounds.width - padding - (trailing ?? padding) - spacing * CGFloat(max(0, items.count - 1))
        var widths = [CGFloat](repeating: 0, count: items.count)
        var flexible: [(index: Int, priority: Int, ideal: CGFloat)] = []
        var spacer: Int?
        for (index, item) in items.enumerated() {
            switch item {
            case .box(_, let width, _):
                widths[index] = width
                left -= width
            case .text(let label, let priority, let fixed):
                let ideal = width(label, scale: scale)
                if fixed {
                    widths[index] = ideal
                    left -= ideal
                } else {
                    flexible.append((index, priority, ideal))
                }
            case .spacer(let least):
                widths[index] = least
                left -= least
                if spacer == nil { spacer = index }
            }
        }
        for priority in Set(flexible.map(\.priority)).sorted(by: >) {
            let group = flexible.filter { $0.priority == priority }.sorted { $0.ideal < $1.ideal }
            var count = CGFloat(group.count)
            for entry in group {
                let take = min(entry.ideal, max(0, left / count))
                widths[entry.index] = take
                left -= take
                count -= 1
            }
        }
        if let spacer, left > 0 { widths[spacer] += left }
        var x = padding
        for (index, item) in items.enumerated() {
            let width = widths[index]
            switch item {
            case .box(let box, _, let tall):
                let rect = NSRect(x: x, y: (height - tall) / 2, width: width, height: tall)
                if let symbol = box as? KitSymbol { symbol.centre(in: rect) } else { box.frame = view.kitSnap(rect) }
            case .text(let label, _, let fixed):
                if !fixed, label.runs.count == 1, label.overflow == .tail { KitLabelFit.tail(label, width: width) }
                label.frame = view.kitSnap(NSRect(x: x, y: 0, width: width, height: height))
            case .spacer:
                break
            }
            x += width + spacing
        }
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = KitColor.ink,
                      opacity: Double = 1, overflow: KitLabel.Overflow = .tail) -> KitLabel {
        let label = KitLabel(text, font: .systemFont(ofSize: size, weight: weight), color: color)
        label.opacity = opacity
        label.overflow = overflow
        return label
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, tint: NSColor = KitColor.muted) -> KitSymbol {
        KitSymbol(name, style: KitSymbol.Style(size: size, weight: weight), tint: tint)
    }
}

final class FieldMark: NSView {
    var icon: NSImage? { didSet { if icon !== oldValue { iconChanged(from: oldValue) } } }
    var letter: String { didSet { if letter != oldValue { label.text = letter } } }
    let size: CGFloat

    private let tile: KitBox
    private let label: KitLabel
    private let plate: KitBox
    private let picture = NSView()
    private let glyph = NSImageView()

    init(icon: NSImage?, letter: String, size: CGFloat) {
        self.icon = icon
        self.letter = letter
        self.size = size
        tile = KitBox(fill: KitColor.ink.withAlphaComponent(0.06), corners: .radius(size * 0.22))
        label = KitLabel(letter, font: .systemFont(ofSize: size * 0.56, weight: .medium), color: KitColor.muted)
        plate = KitBox(fill: nil, corners: .radius(size * 0.32))
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        label.alignment = .center
        label.setAccessibilityElement(false)
        picture.wantsLayer = true
        picture.layer?.cornerCurve = .continuous
        picture.layer?.cornerRadius = size * 0.22
        picture.layer?.masksToBounds = true
        picture.layer?.contentsGravity = .resizeAspectFill
        glyph.imageScaling = .scaleProportionallyUpOrDown
        for view in [tile, label, plate, picture, glyph] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
        iconChanged(from: icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var template: Bool { icon?.isTemplate == true }

    private func iconChanged(from old: NSImage?) {
        if (old == nil) != (icon == nil), window != nil { layer?.kitTransition(Motion.kitQuick) }
        let blank = icon == nil
        tile.isHidden = !blank
        label.isHidden = !blank
        picture.isHidden = blank || template
        glyph.isHidden = blank || !template
        glyph.image = template ? icon : nil
        picture.layer?.contents = template ? nil : icon
        needsLayout = true
        paint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        picture.layer?.contentsScale = kitScale
    }

    private func paint() {
        let dark = kitDark
        glyph.contentTintColor = KitColor.ink.kitResolved(dark: dark).withAlphaComponent(0.75)
        guard let icon, !template else {
            plate.isHidden = true
            return
        }
        plate.fill = PinTint.of(icon).backing(dark: dark)
        plate.isHidden = plate.fill == nil
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: 0, y: 0, width: size, height: size)
        tile.frame = box
        label.frame = box
        picture.frame = box
        glyph.frame = box.insetBy(dx: size * 0.06, dy: size * 0.06)
        plate.frame = box.insetBy(dx: -size * 0.14, dy: -size * 0.14)
    }
}

final class FieldRowView: NSView {
    var offer: Suggestion { didSet { if offer != oldValue { refresh(rebuild: kind(offer) != kind(oldValue)) } } }
    var height: CGFloat { didSet { if height != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }
    var lit = false { didSet { if lit != oldValue { (content as? FieldPlaceRowView)?.lit = lit } } }
    var splits = false { didSet { if splits != oldValue { (content as? FieldPlaceRowView)?.splits = splits } } }
    var copyAnswer: ((FieldAnswer) -> Void)? { didSet { (content as? FieldAnswerRowView)?.copyWhole = copyAnswer } }

    private var content: NSView?

    init(offer: Suggestion, height: CGFloat, lit: Bool = false) {
        self.offer = offer
        self.height = height
        self.lit = lit
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: height))
        refresh(rebuild: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: height) }

    private enum Kind { case plain, answer, placed }

    private func kind(_ offer: Suggestion) -> Kind {
        if case .answer = offer.kind { return .answer }
        return offer.placed == nil ? .plain : .placed
    }

    private func refresh(rebuild: Bool) {
        if rebuild {
            content?.removeFromSuperview()
            let made: NSView
            switch offer.kind {
            case .answer(let answer):
                let row = FieldAnswerRowView(answer: answer)
                row.copyWhole = copyAnswer
                made = row
            default:
                if let item = offer.placed {
                    made = FieldPlaceRowView(item: item, lit: lit, splits: splits)
                } else {
                    made = FieldPlainRowView(offer: offer)
                }
            }
            addSubview(made)
            content = made
            needsLayout = true
            return
        }
        switch content {
        case let row as FieldAnswerRowView:
            if case .answer(let answer) = offer.kind { row.answer = answer }
        case let row as FieldPlaceRowView:
            if let item = offer.placed { row.item = item }
        case let row as FieldPlainRowView:
            row.offer = offer
        default:
            break
        }
    }

    override func layout() {
        super.layout()
        content?.frame = bounds
    }
}

final class FieldPlainRowView: NSView {
    var offer: Suggestion { didSet { if offer != oldValue { refresh() } } }

    private var icon: NSView?
    private var symbolIcon: KitSymbol?
    private var markIcon: FieldMark?
    private let primary = FieldLine.label("", size: 14)
    private let secondary = FieldLine.label("", size: 14, opacity: 0.68)
    private var bookmark: KitSymbol?
    private let keys = FieldLine.label("", size: 12, weight: .medium, color: KitColor.muted)

    init(offer: Suggestion) {
        self.offer = offer
        super.init(frame: .zero)
        for view in [primary, secondary, keys] as [NSView] { addSubview(view) }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        primary.text = offer.primary
        secondary.text = shortened
        secondary.isHidden = offer.secondary.isEmpty
        if offer.kind == .bookmark, bookmark == nil {
            let made = FieldLine.symbol("bookmark", size: 11)
            addSubview(made, positioned: .below, relativeTo: keys)
            bookmark = made
        }
        bookmark?.isHidden = offer.kind != .bookmark
        keys.text = offer.keys
        keys.isHidden = offer.keys.isEmpty
        switch wantedIcon {
        case .symbol(let name):
            if let symbolIcon {
                symbolIcon.name = name
            } else {
                let made = FieldLine.symbol(name, size: 13)
                addSubview(made)
                symbolIcon = made
            }
            icon = symbolIcon
        case .mark(let image, let letter):
            if let markIcon, (image == nil) == (markIcon.icon == nil) {
                markIcon.icon = image
                markIcon.letter = letter
            } else {
                markIcon?.removeFromSuperview()
                let made = FieldMark(icon: image, letter: letter, size: 18)
                addSubview(made)
                markIcon = made
            }
            icon = markIcon
        }
        symbolIcon?.isHidden = icon !== symbolIcon
        markIcon?.isHidden = icon !== markIcon
        needsLayout = true
    }

    private enum Icon {
        case symbol(String)
        case mark(NSImage?, String)
    }

    private var wantedIcon: Icon {
        switch offer.kind {
        case .search, .suggested:
            if offer.kind == .search, let found = Favicons.shared.cached(for: offer.url) { return .mark(found, "") }
            return .symbol("magnifyingglass")
        case .command:
            return .symbol("command")
        case .snippet:
            return .symbol("text.insert")
        case .action where !offer.symbol.isEmpty:
            return .symbol(offer.symbol)
        default:
            return .mark(Favicons.shared.cached(for: offer.url), letter)
        }
    }

    private var shortened: String {
        let text = offer.secondary
        let room = offer.kind == .passage ? 64 : 44
        return text.count > room ? String(text.prefix(room - 1)) + "…" : text
    }

    private var letter: String {
        let host = offer.url.host().map(Address.withoutWWW) ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    override func layout() {
        super.layout()
        var items: [FieldLine.Item] = []
        if let icon { items.append(.box(icon, 18, 18)) }
        items.append(.text(primary))
        if !secondary.isHidden { items.append(.text(secondary, fixed: true)) }
        items.append(.spacer(0))
        if let bookmark, !bookmark.isHidden { items.append(.box(bookmark, bookmark.intrinsicContentSize.width, bounds.height)) }
        if !keys.isHidden { items.append(.text(keys, fixed: true)) }
        FieldLine.place(items, in: self, padding: 10, spacing: 12)
    }
}

final class FieldHint: NSView, KitOnGlass {
    var word: String { didSet { if word != oldValue { label.text = word; invalidateIntrinsicContentSize(); needsLayout = true } } }
    var faded = false {
        didSet {
            guard faded != oldValue else { return }
            layer?.kitAnimate("opacity", to: faded ? 0.4 : 1, curve: Motion.kitQuick)
        }
    }

    private let label: KitLabel
    private let keys: KitLabel
    private static let gap: CGFloat = 7

    init(_ word: String, keys: String, size: CGFloat = 13) {
        self.word = word
        label = KitLabel(word, font: .systemFont(ofSize: size), color: KitColor.ink)
        self.keys = KitLabel(keys, font: .systemFont(ofSize: 13, weight: .medium), color: KitColor.muted)
        super.init(frame: .zero)
        wantsLayer = true
        label.setAccessibilityElement(false)
        self.keys.setAccessibilityElement(false)
        addSubview(label)
        addSubview(self.keys)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let scale = kitScale
        let height = max(label.intrinsicContentSize.height, keys.intrinsicContentSize.height)
        return NSSize(width: FieldLine.width(label, scale: scale) + Self.gap + FieldLine.width(keys, scale: scale), height: height)
    }

    override func layout() {
        super.layout()
        FieldLine.place([.text(label, fixed: true), .text(keys, fixed: true)], in: self, padding: 0, spacing: Self.gap)
    }
}

final class FieldBarView: NSView {
    static let height: CGFloat = 30

    let browser: Browser
    let fieldMenu: FieldMenu
    private let places: KitGlassKey
    private let go: KitGlassKey
    private let actions: KitGlassKey
    private let goHint = FieldHint("Open", keys: "↩")
    var held = false { didSet { if held != oldValue, !held { needsLayout = true } } }

    init(browser: Browser, menu: FieldMenu) {
        self.browser = browser
        self.fieldMenu = menu
        places = KitGlassKey(symbol: "line.3.horizontal.decrease", circle: Self.height, symbolSize: 14, weight: .medium, label: "Places") {
            FieldPlaces.show(for: browser)
        }
        go = KitGlassKey(title: "Open", size: .regular, tall: Self.height) { browser.submit() }
        actions = KitGlassKey(title: "Actions", size: .regular, tall: Self.height) { browser.fieldActions() }
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: Self.height))
        places.kitAccess(help: "Places")
        go.content = goHint
        actions.content = FieldHint("Actions", keys: "⌘K")
        actions.setAccessibilityLabel("Actions ⌘K")
        for key in [places, go, actions] {
            key.grounded = true
            addSubview(key)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Self.height) }

    var benchWord: String { goHint.word }

    var returnWord: String {
        if fieldMenu.showing { return "Run" }
        if browser.pointed == Browser.siteRow { return browser.placeOffer.map { "Search \($0.title)" } ?? "Search Site" }
        if browser.fieldPlace == .snippets, browser.leadingSnippet != nil {
            return browser.snippetField.target?.editor == true || browser.snippetField.waiting ? "Insert" : "Copy"
        }
        if browser.fieldPlace != nil { return "Open" }
        if browser.leadingAnswer != nil { return "Copy" }
        if browser.leadingSnippet != nil { return browser.snippetField.target?.editor == true ? "Insert" : "Copy" }
        guard let picked = browser.fieldRow, browser.offers.indices.contains(picked) else {
            if browser.offers.first?.leads == true { return "Open" }
            return browser.typed.isEmpty ? "Open" : "Go"
        }
        let offer = browser.offers[picked]
        if offer.pickIsSwitch { return "Switch to Tab" }
        switch offer.kind {
        case .search, .suggested: return "Search"
        case .command, .action: return "Run"
        default: return "Open"
        }
    }

    override func layout() {
        super.layout()
        guard !held else { return }
        let word = returnWord
        let idle = browser.returnIsIdle
        if goHint.word != word {
            goHint.word = word
            go.setAccessibilityLabel("\(word) ↩")
            go.invalidateIntrinsicContentSize()
        }
        goHint.faded = idle
        go.isEnabled = !idle
        go.alphaValue = 1
        let height = Self.height
        places.frame = kitSnap(NSRect(x: 0, y: (bounds.height - height) / 2, width: height, height: height))
        let actionsWidth = actions.intrinsicContentSize.width
        actions.frame = kitSnap(NSRect(x: bounds.width - actionsWidth, y: (bounds.height - height) / 2, width: actionsWidth, height: height))
        let goWidth = go.intrinsicContentSize.width
        go.frame = kitSnap(NSRect(x: actions.frame.minX - 10 - goWidth, y: (bounds.height - height) / 2, width: goWidth, height: height))
    }
}

final class FieldSlabArt: CALayer {
    var dark = false { didSet { if dark != oldValue { paint() } } }
    var faint = false { didSet { if faint != oldValue { paint() } } }

    private let fill = CAGradientLayer()
    private let edge = CAGradientLayer()
    private let edgeShape = CAShapeLayer()

    override init() {
        super.init()
        addSublayer(fill)
        addSublayer(edge)
        edge.mask = edgeShape
        edgeShape.fillColor = nil
        edgeShape.strokeColor = NSColor.black.cgColor
        edgeShape.lineWidth = 0.75
        fill.cornerRadius = 12
        fill.cornerCurve = .continuous
        shadowOffset = CGSize(width: 0, height: 1)
        shadowRadius = 3
        shadowColor = NSColor.black.cgColor
        paint()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func paint() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.colors = (dark ? [NSColor(white: 1, alpha: 0.19), NSColor(white: 1, alpha: 0.13)]
                            : [NSColor(white: 1, alpha: 0.92), NSColor(white: 1, alpha: 0.7)]).map(\.cgColor)
        edge.colors = (dark ? [NSColor(white: 1, alpha: 0.22), NSColor(white: 1, alpha: 0.06)]
                            : [NSColor(white: 0, alpha: 0.05), NSColor(white: 0, alpha: 0.13)]).map(\.cgColor)
        shadowOpacity = faint ? 0 : dark ? 0.24 : 0.11
        opacity = faint ? 0.5 : 1
        CATransaction.commit()
    }

    override func layoutSublayers() {
        super.layoutSublayers()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let slab = bounds.insetBy(dx: 0, dy: 1)
        fill.frame = slab
        edge.frame = slab
        let path = CGPath(roundedRect: CGRect(origin: .zero, size: slab.size).insetBy(dx: 0.375, dy: 0.375),
                          cornerWidth: 11.625, cornerHeight: 11.625, transform: nil)
        edgeShape.frame = edge.bounds
        edgeShape.path = path
        shadowPath = CGPath(roundedRect: slab, cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
    }
}

final class FieldSlabView: NSView {
    var faint: Bool {
        get { art.faint }
        set {
            guard newValue != art.faint else { return }
            if window != nil { art.kitTransition(Motion.kitQuick) }
            art.faint = newValue
        }
    }

    private let art = FieldSlabArt()

    init(faint: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(art)
        art.faint = faint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame = bounds
        art.dark = kitDark
        CATransaction.commit()
    }
}

final class FieldSlabTrack: NSView {
    private let art = FieldSlabArt()
    private var place: Int?
    private var shown = false
    private var rect: CGRect?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(art)
        art.opacity = 0
        art.anchorPoint = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        art.dark = kitDark
    }

    func show(_ rect: CGRect?, at lit: Int?, faint: Bool) {
        art.dark = kitDark
        if art.faint != faint {
            art.kitTransition(Motion.kitQuick)
            art.faint = faint
        }
        guard let lit else {
            place = nil
            if shown {
                shown = false
                fade(to: 0)
            }
            return
        }
        let moving = place != nil && place != lit && shown
        let showing = place == nil || !shown
        place = lit
        guard let rect else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            art.isHidden = true
            CATransaction.commit()
            self.rect = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.isHidden = false
        CATransaction.commit()
        if showing {
            set(rect, curve: .none)
            shown = true
            fade(to: 1)
        } else if moving {
            set(rect, curve: Motion.kitGlide)
        } else if rect != self.rect {
            set(rect, curve: .none)
        }
    }

    private func fade(to value: Swift.Float) {
        art.kitAnimate("opacity", to: value, curve: Motion.kitQuick)
    }

    private func set(_ rect: CGRect, curve: KitCurve) {
        self.rect = rect
        art.kitAnimate("position", to: NSValue(point: rect.origin), curve: curve)
        art.kitAnimate("bounds", to: NSValue(rect: CGRect(origin: .zero, size: rect.size)), curve: curve)
    }
}

@MainActor
enum FieldPlaces {
    private final class Action: NSObject {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        @objc func fire() { run() }
    }

    private static var kept: [Action] = []

    static func entry(_ title: String, _ run: @escaping () -> Void) -> NSMenuItem {
        let action = Action(run)
        kept.append(action)
        let item = NSMenuItem(title: title, action: #selector(Action.fire), keyEquivalent: "")
        item.target = action
        return item
    }

    static func show(for browser: Browser) {
        kept = []
        let menu = NSMenu()
        for place in FieldPlace.browsable {
            menu.addItem(entry(place.title) { browser.enterPlace(place) })
        }
        for page: InternalPage.Kind in [.files, .passwords, .settings] {
            menu.addItem(entry(page.rawValue.capitalized) {
                browser.editing = false
                browser.show(InternalPage(page))
            })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

extension Browser {
    func fieldRested() {
        guard !fieldShowing else { return }
        noticeClipboard()
        if !typed.isEmpty || picked != nil || fieldPlace != nil { typed = "" }
    }

    func fieldRose() {
        pointer.rest()
        noticeClipboard()
        if typed.isEmpty, !summoning, CACurrentMediaTime() - guessedAt > 0.05 { retype() }
    }

    func homeOffers() -> ([Suggestion], [FieldSection]) {
        guard active?.shy != true, !newTabPageShown else { return ([], []) }
        var list: [Suggestion] = []
        var sections: [FieldSection] = []

        func section(_ title: String, _ rows: [Suggestion]) {
            guard !rows.isEmpty else { return }
            sections.append(FieldSection(title: title, range: list.count..<(list.count + rows.count)))
            list += rows
        }

        section("Now", nowRows())
        section("Favorites", favoriteRows())

        let recent = tabs
            .filter { $0.id != activeID && !$0.isBlank && !$0.shy && !$0.bench && $0.pin == nil }
            .sorted { $0.touched > $1.touched }
            .prefix(3)
            .compactMap { tab -> Suggestion? in
                guard let url = tab.address else { return nil }
                return Suggestion(key: tab.label, title: Address.pretty(url), url: url, kind: .open, tab: tab.id)
            }
        section("Recent Tabs", recent)

        let open = Set(recent.map { History.identity(for: $0.url) })
        let frequent = history.frequent(limit: 2, skipping: open).map {
            Suggestion(key: $0.address, title: $0.title, url: $0.url, kind: .visited)
        }
        section("Frequent", frequent)

        section("Quick Actions", quickHomeRows())
        return (list, sections)
    }
}

final class FieldRowSlot: NSView {
    var take: (() -> Void)?
    private(set) var row: FieldRowView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(offer: Suggestion, height: CGFloat, lit: Bool, splits: Bool = false, copy: @escaping (FieldAnswer) -> Void) {
        if let row {
            row.splits = splits
            row.offer = offer
            row.height = height
            row.lit = lit
            row.copyAnswer = copy
            return
        }
        let made = FieldRowView(offer: offer, height: height, lit: lit)
        made.splits = splits
        made.copyAnswer = copy
        made.frame = bounds
        addSubview(made)
        row = made
    }

    override func layout() {
        super.layout()
        row?.frame = bounds
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        take?()
    }
}

final class FieldBarSlot: NSView {
    private(set) var bar: FieldBarView?
    var held = false { didSet { bar?.held = held } }

    override var isFlipped: Bool { true }

    func set(browser: Browser) {
        guard bar == nil else { return }
        let made = FieldBarView(browser: browser, menu: browser.fieldMenu)
        made.frame = bounds
        addSubview(made)
        bar = made
    }

    override func layout() {
        super.layout()
        bar?.frame = bounds
    }
}

@MainActor
enum FieldHosts {
    static func placeOffer(_ place: FieldPlace, take: @escaping () -> Void) -> NSView {
        FieldPlaceOfferSlot(place: place, take: take)
    }

    static func placeChip(_ place: FieldPlace) -> NSView { PlaceChipView(place: place) }

    static func menuList(_ menu: FieldMenu, rowHeight: CGFloat, headerHeight: CGFloat, room: CGFloat?) -> NSView {
        FieldMenuListView(menu: menu, rowHeight: rowHeight, headerHeight: headerHeight, room: room)
    }

    static func row() -> FieldRowSlot { FieldRowSlot() }

    static func setRow(_ slot: FieldRowSlot, offer: Suggestion, height: CGFloat, lit: Bool, splits: Bool = false,
                       take: @escaping () -> Void, copy: @escaping (FieldAnswer) -> Void) {
        slot.take = take
        slot.set(offer: offer, height: height, lit: lit, splits: splits, copy: copy)
    }

    static func bar() -> FieldBarSlot { FieldBarSlot() }

    static func setBar(_ slot: FieldBarSlot, browser: Browser, live: Bool) {
        slot.set(browser: browser)
    }
}

final class FieldPlaceOfferSlot: NSView {
    let row: PlaceOfferRowView
    private let take: () -> Void

    init(place: FieldPlace, take: @escaping () -> Void) {
        row = PlaceOfferRowView(place: place)
        self.take = take
        super.init(frame: .zero)
        addSubview(row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { row.intrinsicContentSize }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        take()
    }

    override func layout() {
        super.layout()
        row.frame = bounds
    }

    override func accessibilityChildren() -> [Any]? { [row] }
}

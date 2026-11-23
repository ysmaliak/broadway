import AppKit

enum LinkChooserLook {
    static let tight: CGFloat = 420
    static let head = OmniboxView.inputHeight
    static let heading = OmniboxView.headerHeight
    static let row = OmniboxView.rowHeight
    static let bar = OmniboxView.barRoom
    static let room: CGFloat = 40
    static let size = NSSize(width: OmniboxView.widest, height: OmniboxView.restingHeight)

    static func words(for url: URL) -> (site: String, rest: String) {
        guard let host = url.host(), !host.isEmpty else { return (url.absoluteString, "") }
        let path = url.path()
        var rest = path == "/" ? "" : path
        if let query = url.query(), !query.isEmpty { rest += "?" + query }
        return (Address.withoutWWW(host), rest)
    }

    static func tint(for look: SpaceLook) -> NSColor {
        look.pageTint.withAlphaComponent(look.pageTint.alphaComponent * 0.65)
    }
}

final class LinkChooserView: NSView {
    struct Mark: Equatable {
        var icon: TabIcon
        var look: SpaceLook
    }

    var lit: Int? {
        didSet {
            guard lit != oldValue else { return }
            for (index, row) in rows.enumerated() { row.lit = lit == index }
            needsLayout = true
        }
    }
    var faint = false { didSet { if faint != oldValue { needsLayout = true } } }
    var always = false { didSet { remember.isOn = always } }
    var look: SpaceLook? { didSet { if look != oldValue { needsLayout = true } } }
    var choose: ((Int) -> Void)?
    var point: ((Int) -> Void)?
    var flip: (() -> Void)?
    var here: (() -> Void)?
    var open: (() -> Void)?

    var count: Int { rows.count }

    private let glass = KitGlass(radius: OmniboxView.radius)
    private let inside = KitFlippedView()
    private let mark: FieldMark
    private let address = KitLabel()
    private let heading = FieldLine.label("Open Link In", size: 13, opacity: 0.75)
    private let scroll = NSScrollView()
    private let page = KitFlippedView()
    private let slab = FieldSlabTrack()
    private let above = KitBox(fill: KitColor.ink.withAlphaComponent(0.1))
    private let below = KitBox(fill: KitColor.ink.withAlphaComponent(0.1))
    private var rows: [LinkChooserRow] = []
    private let remember: LinkChooserAlways
    private let hereKey: KitGlassKey
    private let openKey: KitGlassKey
    private var shownLit: Int??
    private var tint: NSColor?

    init(rows choices: [LinkChooser.Row], url: URL, site: String?, marks: [UUID: Mark]) {
        let words = LinkChooserLook.words(for: url)
        mark = FieldMark(icon: Favicons.shared.cached(for: url), letter: words.site.first.map { String($0).uppercased() } ?? "•", size: 20)
        remember = LinkChooserAlways(site.map { "Always for \($0)" } ?? "")
        (hereKey, openKey) = Self.keys()
        super.init(frame: NSRect(origin: .zero, size: LinkChooserLook.size))
        wantsLayer = true
        layer?.allowsGroupOpacity = true
        glass.wantsLayer = true
        inside.wantsLayer = true
        inside.layer?.cornerRadius = OmniboxView.radius
        inside.layer?.cornerCurve = .continuous
        inside.layer?.masksToBounds = true
        identifier = NSUserInterfaceItemIdentifier("link.chooser")
        let font = NSFont.systemFont(ofSize: 20)
        address.runs = [KitLabel.Run(text: words.site, font: font, color: KitColor.ink)]
            + (words.rest.isEmpty ? [] : [KitLabel.Run(text: words.rest, font: font, color: KitColor.muted)])
        address.overflow = .tail
        address.kitAccess(label: url.absoluteString)
        heading.setAccessibilityElement(false)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.contentView.drawsBackground = false
        scroll.documentView = page
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        page.addSubview(slab)
        rows = choices.enumerated().map { index, choice in
            var art: Mark?
            if case .space(let id, _) = choice { art = marks[id] ?? Mark(icon: TabIcon(symbol: "square.stack"), look: SpaceLook()) }
            let row = LinkChooserRow(choice, number: index < 9 ? index + 1 : nil, mark: art)
            row.action = { [weak self] in self?.choose?(index) }
            row.moved = { [weak self] in self?.point?(index) }
            page.addSubview(row)
            return row
        }
        above.alphaValue = 0
        below.alphaValue = 0
        remember.isHidden = site == nil
        remember.toggled = { [weak self] on in
            guard let self, on != self.always else { return }
            self.flip?()
        }
        hereKey.action = { [weak self] in self?.here?() }
        openKey.action = { [weak self] in self?.open?() }
        for view in [mark, address, heading, scroll, above, below, remember, hereKey, openKey] as [NSView] { inside.addSubview(view) }
        addSubview(glass)
        addSubview(inside)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Open Link In")
        setAccessibilityModal(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func keys() -> (here: KitGlassKey, open: KitGlassKey) {
        let here = KitGlassKey(title: "Open Here", size: .regular, tall: FieldBarView.height)
        let open = KitGlassKey(title: "Open", size: .regular, tall: FieldBarView.height)
        here.content = FieldHint("Open Here", keys: "esc")
        here.setAccessibilityLabel("Open Here")
        here.setAccessibilityHelp("Escape opens the link where you are")
        here.setAccessibilityIdentifier("link.chooser.here")
        open.content = FieldHint("Open", keys: "↩")
        open.setAccessibilityLabel("Open ↩")
        open.setAccessibilityIdentifier("link.chooser.open")
        for key in [here, open] { key.grounded = true }
        return (here, open)
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint = nil
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        LinkChooserLook.size
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    func reveal(_ index: Int?) {
        guard let index, rows.indices.contains(index) else { return }
        layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let seen = clip.bounds
        let rect = rows[index].frame
        var y = seen.minY
        if rect.minY < seen.minY { y = rect.minY } else if rect.maxY > seen.maxY { y = rect.maxY - seen.height }
        y = min(max(0, y), max(0, page.frame.height - seen.height))
        guard y != seen.minY else { return }
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    var litShown: Bool {
        guard let lit, rows.indices.contains(lit) else { return true }
        return rows[lit].visibleRect.height >= rows[lit].bounds.height - 0.5
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        inside.frame = bounds
        let wanted = look.map(LinkChooserLook.tint)
        if tint != wanted {
            tint = wanted
            glass.tintColor = wanted
        }
        let width = bounds.width
        let height = bounds.height
        let head = LinkChooserLook.head
        mark.frame = kitSnap(NSRect(x: 18, y: (head - mark.size) / 2, width: mark.size, height: mark.size))
        let x = 18 + mark.size + 12
        address.frame = kitSnap(NSRect(x: x, y: 0, width: max(0, width - x - 18), height: head))
        heading.frame = kitSnap(NSRect(x: 15, y: head, width: max(0, width - 30), height: LinkChooserLook.heading))
        let top = head + LinkChooserLook.heading
        let list = NSRect(x: 0, y: top, width: width, height: max(0, height - top - LinkChooserLook.bar))
        if scroll.frame != list { scroll.frame = list }
        let inner = max(0, width - 14)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 7, y: CGFloat(index) * LinkChooserLook.row, width: inner, height: LinkChooserLook.row)
        }
        let along = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * LinkChooserLook.row)
        if page.frame != along { page.frame = along }
        scroll.verticalScrollElasticity = along.height > list.height ? .allowed : .none
        slab.frame = page.bounds
        let shown = lit.flatMap { rows.indices.contains($0) ? $0 : nil }
        slab.show(shown.map { rows[$0].frame }, at: shown, faint: faint)
        let hair = 1 / max(kitScale, 1)
        above.frame = NSRect(x: 0, y: list.minY, width: width, height: hair)
        below.frame = NSRect(x: 0, y: list.maxY - hair, width: width, height: hair)

        let tall = FieldBarView.height
        let y = height - 11 - tall
        let openWidth = openKey.intrinsicContentSize.width
        openKey.isHidden = width < LinkChooserLook.tight
        openKey.frame = kitSnap(NSRect(x: width - 12 - openWidth, y: y, width: openWidth, height: tall))
        let hereWidth = hereKey.intrinsicContentSize.width
        let edge = openKey.isHidden ? width - 12 : openKey.frame.minX - 10
        hereKey.frame = kitSnap(NSRect(x: edge - hereWidth, y: y, width: hereWidth, height: tall))
        let room = max(0, hereKey.frame.minX - 12 - 18)
        remember.frame = kitSnap(NSRect(x: 18, y: y, width: min(room, remember.intrinsicContentSize.width), height: tall))
        if shownLit.map({ $0 != lit }) ?? true {
            shownLit = .some(lit)
            reveal(lit)
        }
        scrolled()
    }

    @objc private func scrolled() {
        let clip = scroll.contentView.bounds
        show(above, clip.minY > 1)
        show(below, clip.maxY < page.frame.height - 1)
    }

    private func show(_ line: NSView, _ on: Bool) {
        guard (line.alphaValue > 0.5) != on else { return }
        line.wantsLayer = true
        line.layer?.kitAnimate("opacity", to: on ? 1 : 0, curve: window == nil ? KitCurve.none : Motion.kitQuick)
        line.alphaValue = on ? 1 : 0
    }
}

final class LinkChooserRow: KitButton {
    var lit = false
    var moved: (() -> Void)?

    private let art: NSView
    private let title: KitLabel
    private let cap: FieldKeyCap?
    private var motion: NSTrackingArea?

    init(_ choice: LinkChooser.Row, number: Int?, mark: LinkChooserView.Mark?) {
        title = FieldLine.label(choice.title, size: 14)
        cap = number.map { FieldKeyCap("\($0)") }
        let help: String
        switch choice {
        case .space:
            art = mark.map { LinkSpaceTile($0) as NSView } ?? FieldLine.symbol("square.stack", size: 13)
            help = "Opens the link in this space"
        case .window:
            art = FieldLine.symbol("macwindow.badge.plus", size: 13)
            help = "Opens the link in a new window"
        case .peek:
            art = FieldLine.symbol("eye", size: 13)
            help = "Opens the link over this page"
        }
        super.init(.plain(press: 0.98), label: choice.title)
        identifier = NSUserInterfaceItemIdentifier("link.chooser.row." + choice.title)
        setAccessibilityHelp(number.map { "\(help). Press \($0) to choose it." } ?? help)
        addSubview(art)
        addSubview(title)
        title.setAccessibilityElement(false)
        art.setAccessibilityElement(false)
        if let cap {
            cap.setAccessibilityElement(false)
            addSubview(cap)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let motion { removeTrackingArea(motion) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        motion = made
    }

    override func mouseMoved(with event: NSEvent) { moved?() }

    override func isAccessibilitySelected() -> Bool { lit }

    override func layout() {
        super.layout()
        var items: [FieldLine.Item] = [.box(art, 20, 20), .text(title), .spacer(0)]
        if let cap { items.append(.box(cap, cap.intrinsicContentSize.width, 18)) }
        FieldLine.place(items, in: self, padding: 10, spacing: 12)
    }
}

final class LinkSpaceTile: NSView {
    private let look: SpaceLook
    private let ground: KitBox
    private let mark: SpaceMarkView

    init(_ made: LinkChooserView.Mark) {
        look = made.look
        ground = KitBox(fill: made.look.tint, stroke: KitColor.hairline, corners: .radius(6))
        mark = SpaceMarkView(icon: made.icon, size: 13)
        super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        addSubview(ground)
        addSubview(mark)
        setAccessibilityElement(false)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 20) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        mark.tint = look.inkLight(dark: kitDark) ? NSColor(white: 1, alpha: 0.95) : NSColor(white: 0, alpha: 0.82)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        mark.frame = bounds
    }
}

final class LinkChooserAlways: KitButton {
    var toggled: ((Bool) -> Void)?
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            show()
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    private let box = FieldLine.symbol("square", size: 15)
    private let words: KitLabel
    private let cap = FieldKeyCap("Space")

    init(_ text: String) {
        words = FieldLine.label(text, size: 13)
        super.init(.plain(press: 1))
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(text)
        setAccessibilityHelp("Space turns this on or off")
        setAccessibilityIdentifier("link.chooser.always")
        toolTip = "Keep this choice for every link to the site"
        words.setAccessibilityElement(false)
        cap.setAccessibilityElement(false)
        for view in [box, words, cap] as [NSView] { addSubview(view) }
        action = { [weak self] in
            guard let self else { return }
            self.toggled?(!self.isOn)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func show() {
        box.name = isOn ? "checkmark.square.fill" : "square"
        box.tint = isOn ? KitColor.ink : KitColor.muted
    }

    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override var intrinsicContentSize: NSSize {
        let scale = kitScale
        return NSSize(width: Self.side + 7 + FieldLine.width(words, scale: scale) + 10 + cap.intrinsicContentSize.width,
                      height: FieldBarView.height)
    }

    private static let side: CGFloat = 18

    override func layout() {
        super.layout()
        box.frame = kitSnap(NSRect(x: 0, y: (bounds.height - Self.side) / 2, width: Self.side, height: Self.side))
        let capSize = cap.intrinsicContentSize
        let x = Self.side + 7
        let natural = FieldLine.width(words, scale: kitScale)
        let roomy = bounds.width - x - 10 - capSize.width >= natural
        cap.isHidden = !roomy
        let width = roomy ? natural : max(0, bounds.width - x)
        words.frame = kitSnap(NSRect(x: x, y: 0, width: width, height: bounds.height))
        cap.frame = kitSnap(NSRect(x: x + width + 10, y: (bounds.height - capSize.height) / 2, width: capSize.width, height: capSize.height))
    }
}

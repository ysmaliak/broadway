import AppKit
import Combine

@MainActor
enum TabOffersPanel {
    private static var popup: KitPopup?
    private static var list: TabOffersListView?
    private static weak var anchor: NSView?
    private static var watching: [ObjectIdentifier: AnyCancellable] = [:]

    static func follow(_ browser: Browser, anchor field: NSView) {
        anchor = field
        let key = ObjectIdentifier(browser)
        guard watching[key] == nil else { return }
        watching[key] = kitObserve(distinct: true, { [weak browser] in browser?.tabOffers.isEmpty ?? true }) { [weak browser] empty in
            guard let browser else { return }
            if empty || browser.editingTab == nil { hide() } else { show(browser, tries: 0) }
        }
    }

    static var isShown: Bool { popup?.isShown == true }

    static func picture(to path: String) -> Bool {
        guard let view = popup?.stage.surface, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    private static func show(_ browser: Browser, tries: Int) {
        guard !browser.tabOffers.isEmpty, browser.editingTab != nil else { return }
        guard popup == nil else { return }
        let focused = (browser.window?.firstResponder as? NSTextView)?.delegate as? NSTextField
        guard let field = focused ?? anchor, field.window != nil else {
            if tries < 15 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { show(browser, tries: tries + 1) }
            }
            return
        }
        let width = min(max(field.bounds.width + 24, 320), 460)
        let made = TabOffersListView(browser: browser, width: width)
        let shown = KitPopup.show(made, size: made.fittingSize, from: field.bounds, of: field, edge: .auto, follows: true,
                                  bleeds: true) { [weak made] in
            if TabOffersPanel.list === made {
                TabOffersPanel.list = nil
                TabOffersPanel.popup = nil
            }
        }
        made.onResize = { [weak shown] fitted in shown?.resize(to: fitted) }
        popup = shown
        list = made
        browser.tabPointer.rest()
    }

    static func hide() {
        popup?.close()
    }
}

final class TabOffersListView: NSView {
    let browser: Browser
    let width: CGFloat
    var onResize: ((NSSize) -> Void)?

    private let column = KitFlippedView()
    private var rows: [TabOfferRowView] = []
    private var watch: Set<AnyCancellable> = []

    init(browser: Browser, width: CGFloat, offers: [Suggestion]? = nil, picked: Int? = nil) {
        self.browser = browser
        self.width = width
        super.init(frame: .zero)
        addSubview(column)
        if let offers {
            show(offers, picked: picked)
        } else {
            kitObserve({ [weak browser] in (browser?.tabOffers ?? [], browser?.tabPicked) }) { [weak self] in
                self?.show($0.0, picked: $0.1)
            }.store(in: &watch)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func show(_ offers: [Suggestion], picked: Int?) {
        if rows.map(\.offer.id) != offers.map(\.id) {
            rows.forEach { $0.removeFromSuperview() }
            rows = offers.enumerated().map { index, offer in
                let row = TabOfferRowView(offer: offer)
                row.take = { [weak self] in self?.browser.takeTabOffer(offer) }
                row.point = { [weak self] in self?.browser.pointTab(at: index) }
                return row
            }
            rows.forEach { column.addSubview($0) }
        }
        for (index, row) in rows.enumerated() { row.picked = picked == index }
        let size = fittingSize
        if frame.size != size {
            DispatchQueue.main.async { [weak self] in self?.onResize?(size) }
        }
        needsLayout = true
    }

    override var fittingSize: NSSize {
        let height = rows.reduce(0) { $0 + $1.height(width - 16 - 12) }
        return NSSize(width: ceil(width - 16), height: ceil(height + 12))
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        let card = bounds
        column.frame = card
        var y: CGFloat = 6
        for row in rows {
            let height = row.height(card.width - 12)
            row.frame = NSRect(x: 6, y: y, width: card.width - 12, height: height)
            y += height
        }
    }
}

private final class TabOfferRowView: KitHoverView {
    let offer: Suggestion
    var picked = false { didSet { if picked != oldValue { host.show(offer: offer, picked: picked) } } }
    var take: (() -> Void)?
    var point: (() -> Void)?

    private let host: OmniboxRowView
    private var motion: NSTrackingArea?

    init(offer: Suggestion) {
        self.offer = offer
        host = OmniboxRowView(offer: offer, picked: false)
        super.init(frame: .zero)
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func height(_ width: CGFloat) -> CGFloat { host.height(width) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let motion { removeTrackingArea(motion) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        motion = made
    }

    override func mouseMoved(with event: NSEvent) { point?() }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        point?()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        take?()
    }

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

extension TabOffersListView {
    static func surface(picked: Int?) -> NSView? {
        guard let browser = Browsers.front else { return nil }
        let offers = [
            Suggestion(key: "example.com", title: "Example Domain", url: URL(string: "https://example.com")!, kind: .visited),
            Suggestion(key: "example.org", title: "Example Org, a much longer title that runs on", url: URL(string: "https://example.org/a/b")!, kind: .bookmark),
            Suggestion(key: "broadway", title: "Broadway", url: URL(string: "https://broadway.example/")!, kind: .known),
        ]
        return TabOffersListView(browser: browser, width: 360, offers: offers, picked: picked)
    }
}

final class OmniboxRowView: NSView {
    private var offer: Suggestion
    private var picked: Bool
    private let wash = KitBox(fill: Palette.NS.wash, corners: .radius(9))
    private var icon: NSView = NSView()
    private let key = FieldLine.label("", size: 13)
    private let title = FieldLine.label("", size: 12, color: KitColor.muted)
    private let bookmark = FieldLine.symbol("bookmark", size: 10, weight: .medium)

    init(offer: Suggestion, picked: Bool) {
        self.offer = offer
        self.picked = picked
        super.init(frame: .zero)
        for view in [wash, icon, key, title, bookmark] { addSubview(view) }
        show(offer: offer, picked: picked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(offer: Suggestion, picked: Bool) {
        self.offer = offer
        self.picked = picked
        wash.isHidden = !picked
        icon.removeFromSuperview()
        icon = makeIcon()
        addSubview(icon)
        key.text = offer.kind == .suggested ? offer.key : Address.withoutWWW(offer.key)
        title.text = offer.title
        title.isHidden = offer.title.isEmpty
        bookmark.isHidden = offer.kind != .bookmark
        needsLayout = true
    }

    private func makeIcon() -> NSView {
        switch offer.kind {
        case .search:
            if let favicon = Favicons.shared.cached(for: offer.url) { return MarkView(icon: favicon, letter: "", size: 14) }
            return FieldLine.symbol("magnifyingglass", size: 10, weight: .medium)
        case .suggested:
            return FieldLine.symbol("magnifyingglass", size: 10, weight: .medium)
        default:
            return MarkView(icon: Favicons.shared.cached(for: offer.url), letter: letter, size: 14)
        }
    }

    private var letter: String {
        let host = offer.url.host().map(Address.withoutWWW) ?? ""
        return host.first.map { String($0).uppercased() } ?? "\u{2022}"
    }

    func height(_ width: CGFloat) -> CGFloat {
        let line = { (font: NSFont) in ceil(font.ascender - font.descender) }
        let text = max(line(key.font), title.isHidden ? 0 : line(title.font))
        return max(14, text) + 18
    }

    override func layout() {
        super.layout()
        wash.frame = bounds
        var items: [FieldLine.Item] = [.box(icon, 14, 14), .text(key)]
        if !title.isHidden { items.append(.text(title)) }
        items.append(.spacer(0))
        if !bookmark.isHidden {
            let size = bookmark.intrinsicContentSize
            items.append(.box(bookmark, size.width, size.height))
        }
        FieldLine.place(items, in: self, padding: 12, spacing: 10)
    }
}

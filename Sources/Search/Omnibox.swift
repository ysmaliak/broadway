import AppKit
import Combine

@MainActor
final class OmniboxView: NSView {
    static let topShare: CGFloat = 0.177
    static let inputHeight: CGFloat = 60
    static let rowHeight: CGFloat = 38
    static let headerHeight: CGFloat = 28
    static let barRoom: CGFloat = FieldBarView.height + 22
    static let restingHeight: CGFloat = inputHeight + 3 * headerHeight + 7 * rowHeight + barRoom
    static let widest: CGFloat = 640
    static let radius: CGFloat = 27
    static var holdsWhileLeaving = true

    let browser: Browser

    private let glass = KitGlass(radius: OmniboxView.radius)
    private let panel = OmniboxPanel()
    private let edge = KitBox(fill: nil, stroke: NSColor.systemRed.withAlphaComponent(0.35), corners: .radius(OmniboxView.radius))
    private let magnifier = KitSymbol("magnifyingglass", style: KitSymbol.Style(size: 16, weight: IconLook.weight), tint: KitColor.ink)
    private let field: AddressTextField
    private let list: FieldListView
    private let bar = FieldHosts.bar()
    private var menuList: NSView?
    private var siteChip: SiteChipView?
    private var placeChip: (view: NSView, place: FieldPlace)?
    private var seen: Seen?
    private var barLive: Bool?
    private var tint: NSColor?
    private var glassTicket = 0
    private var showing = false
    private var held = false
    private let still = NSImageView()
    private var stillSelection: [Int] = []
    private var over = false

    private struct Seen: Equatable {
        var showing: Bool
        var refusals: Int
        var typed: String
        var activeID: Tab.ID?
    }

    init(browser: Browser) {
        self.browser = browser
        field = AddressTextField(keys: AddressFieldKeys(browser: browser))
        list = FieldListView(browser: browser, rowHeight: Self.rowHeight, headerHeight: Self.headerHeight,
                             measure: "field", room: Self.barRoom)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        wantsLayer = true
        glass.wantsLayer = true
        edge.alphaValue = 0
        panel.addSubview(list)
        panel.addSubview(magnifier)
        panel.addSubview(field)
        panel.addSubview(bar)
        still.imageScaling = .scaleAxesIndependently
        still.isHidden = true
        panel.addSubview(still)
        magnifier.opacity = 0.8
        for view in [glass, panel, edge] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let menu = browser.fieldMenu
        let now = Seen(showing: browser.fieldShowing && !browser.newTabPageShown, refusals: browser.refusals,
                       typed: browser.typed, activeID: browser.activeID)
        let was = seen
        seen = now
        showing = now.showing
        over = !(browser.active?.isBlank ?? true)
        let opening = now.showing && was?.showing != true
        let animated = !opening && was != nil
        if now.showing {
            if held { release() }
        } else if was?.showing == true, Self.holdsWhileLeaving {
            hold()
        }
        list.held = held
        bar.held = held

        let size = bounds.size
        let width = min(Self.widest, max(320, size.width - 40))
        let height = min(Self.restingHeight, max(160, size.height * (1 - Self.topShare) - 20))
        let box = kitSnap(NSRect(x: (size.width - width) / 2, y: size.height * Self.topShare, width: width, height: height))
        for view in [glass, panel, edge] as [NSView] where view.frame != box { view.frame = box }
        let look = browser.makingSpace ? browser.draftLook : browser.space.look ?? SpaceLook()
        let wanted = look.pageTint.withAlphaComponent(look.pageTint.alphaComponent * 0.65)
        if tint != wanted {
            tint = wanted
            glass.tintColor = wanted
        }

        let area = NSRect(x: 0, y: Self.inputHeight, width: width, height: max(0, height - Self.inputHeight))
        if held {
            field.keys.live = false
        } else {
            placeInput(width: width, animated: animated)
            field.update(browser: browser, tab: nil, search: menu.showing ? menu.query : nil, prompt: AddressTextField.prompt, live: now.showing)
        }
        list.settles = !opening
        if held {
            (menuList as? FieldMenuListView)?.held = true
        } else if menu.showing {
            let made = menuList ?? FieldHosts.menuList(menu, rowHeight: Self.rowHeight, headerHeight: Self.headerHeight, room: Self.barRoom)
            if menuList == nil {
                menuList = made
                panel.addSubview(made, positioned: .below, relativeTo: bar)
            }
            if made.frame != area { made.frame = area }
            (made as? FieldMenuListView)?.held = false
            list.isHidden = true
        } else {
            menuList?.removeFromSuperview()
            menuList = nil
            list.isHidden = false
        }
        if list.frame != area { list.frame = area }
        let barBox = NSRect(x: 12, y: height - 11 - FieldBarView.height, width: max(0, width - 24), height: FieldBarView.height)
        if bar.frame != barBox { bar.frame = barBox }
        if barLive != now.showing {
            barLive = now.showing
            FieldHosts.setBar(bar, browser: browser, live: now.showing)
        }

        if Store.testing {
            note("field.panel", panel.bounds, in: panel)
            note("field.list", area, in: panel)
            note("field.bar", barBox, in: panel)
        }
        react(was, now)
    }

    private func hold() {
        held = true
        let editor = field.currentEditor() as? NSTextView
        stillSelection = editor.map { [$0.selectedRange().location, $0.selectedRange().length] } ?? []
        guard !field.bounds.isEmpty, let picture = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return }
        field.cacheDisplay(in: field.bounds, to: picture)
        let image = NSImage(size: field.bounds.size)
        image.addRepresentation(picture)
        still.image = image
        still.frame = field.frame
        still.isHidden = false
        field.alphaValue = 0
    }

    private func release() {
        held = false
        still.isHidden = true
        still.image = nil
        stillSelection = []
        field.alphaValue = 1
    }

    private func note(_ id: String, _ rect: NSRect, in view: NSView) {
        if let global = view.fieldGlobal(rect) { FieldLayout.note(id, global) }
    }

    private func placeInput(width: CGFloat, animated: Bool) {
        let fieldWas = field.frame
        let mark = magnifier.intrinsicContentSize
        magnifier.frame = kitSnap(NSRect(x: 18, y: (Self.inputHeight - mark.height) / 2, width: mark.width, height: mark.height))
        var x = 18 + mark.width + 12

        let site = browser.siteChip
        if site != siteChip?.site {
            if let leaving = siteChip { leave(leaving, animated: animated) }
            siteChip = site.map { site in
                let chip = SiteChipView(site: site)
                panel.addSubview(chip)
                return chip
            }
        }
        if let chip = siteChip {
            let fits = chip.intrinsicContentSize
            let isNew = chip.frame.isEmpty
            chip.frame = kitSnap(NSRect(x: x, y: (Self.inputHeight - fits.height) / 2, width: fits.width, height: fits.height))
            if isNew, animated { arrive(chip) }
            x += fits.width + 12
        }

        let place = browser.fieldPlace
        if place != placeChip?.place {
            if let leaving = placeChip?.view { leave(leaving, animated: animated) }
            placeChip = place.map { place in
                let chip = FieldHosts.placeChip(place)
                panel.addSubview(chip)
                return (chip, place)
            }
        }
        if let chip = placeChip?.view {
            let fits = chip.fittingSize
            let isNew = chip.frame.isEmpty
            chip.frame = kitSnap(NSRect(x: x, y: (Self.inputHeight - fits.height) / 2, width: fits.width, height: fits.height))
            if isNew, animated { arrive(chip) }
            x += fits.width + 12
        }

        let target = kitSnap(field.lineFrame(x: x, width: max(0, width - 18 - x), in: Self.inputHeight))
        guard field.frame != target else { return }
        field.frame = target
        let shift = fieldWas.minX - target.minX
        guard animated, !fieldWas.isEmpty, shift != 0, let layer = field.layer,
              let move = Motion.kitQuick.animation("position.x", from: shift, to: 0) as? CAPropertyAnimation else { return }
        move.isAdditive = true
        layer.add(move, forKey: "chipShift")
    }

    private func chipTransform(_ view: NSView) -> CATransform3D {
        guard let layer = view.layer else { return CATransform3DIdentity }
        let bounds = layer.bounds
        let pivot = CGPoint(x: bounds.minX - layer.anchorPoint.x * bounds.width,
                            y: bounds.midY - (bounds.minY + layer.anchorPoint.y * bounds.height))
        var transform = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        transform = CATransform3DScale(transform, 0.9, 0.9, 1)
        return CATransform3DTranslate(transform, -pivot.x, -pivot.y, 0)
    }

    private func arrive(_ view: NSView) {
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer else { return }
        let curve = Motion.kitQuick
        if let scale = curve.animation("transform", from: NSValue(caTransform3D: chipTransform(view)),
                                       to: NSValue(caTransform3D: CATransform3DIdentity)) {
            layer.add(scale, forKey: "chipScale")
        }
        if let fade = curve.animation("opacity", from: Swift.Float(0), to: Swift.Float(1)) {
            layer.add(fade, forKey: "chipFade")
        }
    }

    private func leave(_ view: NSView, animated: Bool) {
        let curve = Motion.kitQuick
        guard animated, curve.animates, let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { view.removeFromSuperview() }
        if let scale = curve.animation("transform", from: NSValue(caTransform3D: CATransform3DIdentity),
                                       to: NSValue(caTransform3D: chipTransform(view))) {
            scale.fillMode = .forwards
            scale.isRemovedOnCompletion = false
            layer.add(scale, forKey: "chipScale")
        }
        view.alphaValue = 0
        if let fade = curve.animation("opacity", from: Swift.Float(1), to: Swift.Float(0)) { layer.add(fade, forKey: "chipFade") }
        CATransaction.commit()
    }

    private func react(_ was: Seen?, _ now: Seen) {
        guard let was else {
            if now.showing { later { $0.rose() } }
            return
        }
        if was.showing != now.showing {
            if now.showing {
                later { $0.rose() }
            } else {
                rested()
            }
        }
        if was.activeID != now.activeID, now.showing { later { $0.browser.fieldRose() } }
        if was.refusals != now.refusals {
            fade(edge, to: 1, curve: Motion.kitSettle)
            shake()
        }
        if was.typed != now.typed, edge.alphaValue != 0, !held { fade(edge, to: 0, curve: Motion.kitQuick) }
    }

    private func later(_ work: @escaping (OmniboxView) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            work(self)
        }
    }

    private func rose() {
        for view in [glass, panel, edge] as [NSView] { view.layer?.removeAnimation(forKey: "shake") }
        edge.layer?.removeAnimation(forKey: "opacity")
        edge.alphaValue = 0
        browser.fieldRose()
        guard Store.testing else { return }
        FieldLayout.afterCommit { [browser] in
            if browser.fieldTimes.drawn == nil { browser.fieldTimes.drawn = CACurrentMediaTime() }
        }
    }

    private func rested() {
        glassTicket += 1
        guard let wait = Motion.fieldOutSeconds else {
            later { $0.browser.fieldRested() }
            return
        }
        let ticket = glassTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, ticket == glassTicket, !showing else { return }
            browser.fieldRested()
        }
    }

    private func fade(_ view: NSView, to alpha: CGFloat, curve: KitCurve) {
        let from = view.layer?.presentation()?.opacity ?? Swift.Float(view.alphaValue)
        view.alphaValue = alpha
        guard let animation = curve.animation("opacity", from: from, to: Swift.Float(alpha)) else {
            view.layer?.removeAnimation(forKey: "opacity")
            return
        }
        view.layer?.add(animation, forKey: "opacity")
    }

    private func shake() {
        guard !Motion.reduced else { return }
        let steps = 90
        let travel = (0...steps).map { step -> CGFloat in
            let t = CGFloat(step) / CGFloat(steps)
            return sin(t * .pi * 6) * 7 * (1 - t)
        }
        for view in [glass, panel, edge] as [NSView] {
            let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
            shake.values = travel
            shake.duration = 0.5
            shake.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shake.isAdditive = true
            view.layer?.add(shake, forKey: "shake")
        }
    }

    var benchLine: NSImage? {
        if !still.isHidden { return still.image }
        guard !field.bounds.isEmpty, let picture = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return nil }
        field.cacheDisplay(in: field.bounds, to: picture)
        let image = NSImage(size: field.bounds.size)
        image.addRepresentation(picture)
        return image
    }

    var benchDrawn: [String: Any] {
        var up: NSView? = superview
        while let view = up, !(view is FieldHost.Layer) { up = view.superview }
        let host = up as? FieldHost.Layer
        let editor = field.currentEditor() as? NSTextView
        let selection = editor.map { [$0.selectedRange().location, $0.selectedRange().length] } ?? []
        var out: [String: Any] = [
            "visible": window != nil && host.map { !$0.isHidden } ?? false,
            "leaving": host.map { !$0.shown } ?? false,
            "fading": host?.layer?.animation(forKey: "fade") != nil,
            "held": held,
            "still": !still.isHidden,
            "text": field.stringValue,
            "placeholder": field.placeholderAttributedString?.string ?? "",
            "selection": still.isHidden ? selection : stillSelection,
            "menu": menuList.map { !$0.isHidden } ?? false,
            "chips": [siteChip?.site.name, placeChip?.place.rawValue].compactMap { $0 },
            "bar": bar.bar?.benchWord ?? "",
        ]
        out.merge(list.benchDrawn) { _, new in new }
        return out
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard showing, !isHidden else { return nil }
        let local = convert(point, from: superview)
        if let hit = panel.hitTest(local) { return hit }
        return over && bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard showing, over, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        browser.dismiss()
    }
}

private final class OmniboxPanel: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = OmniboxView.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let shape = CGPath(roundedRect: bounds, cornerWidth: OmniboxView.radius, cornerHeight: OmniboxView.radius, transform: nil)
        guard bounds.contains(local), shape.contains(local) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
}

extension NSView {
    func fieldGlobal(_ rect: NSRect) -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let box = convert(rect, to: nil)
        return CGRect(x: box.minX, y: content.bounds.height - box.maxY, width: box.width, height: box.height)
    }
}

final class SiteIconView: NSView {
    var site: SearchSite { didSet { if site != oldValue { refresh() } } }

    private let picture = NSImageView()
    private let glassMark = KitSymbol("magnifyingglass", style: KitSymbol.Style(size: 10, weight: .medium), tint: KitColor.muted)

    init(site: SearchSite) {
        self.site = site
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        wantsLayer = true
        picture.imageScaling = .scaleAxesIndependently
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 3
        picture.layer?.cornerCurve = .continuous
        picture.layer?.masksToBounds = true
        picture.setAccessibilityElement(false)
        addSubview(picture)
        addSubview(glassMark)
        setAccessibilityElement(false)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    private func refresh() {
        let host = site.host.split(separator: "/").first.map(String.init) ?? site.host
        let icon = Favicons.shared.cached(host) ?? Favicons.shared.cached("www." + host)
        picture.image = icon
        picture.isHidden = icon == nil
        glassMark.isHidden = icon != nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        picture.frame = bounds
        let mark = glassMark.intrinsicContentSize
        glassMark.frame = kitSnap(NSRect(x: (bounds.width - mark.width) / 2, y: (bounds.height - mark.height) / 2,
                                         width: mark.width, height: mark.height))
    }
}

final class SiteChipView: NSView {
    var site: SearchSite {
        didSet {
            guard site != oldValue else { return }
            icon.site = site
            name.text = site.name
            setAccessibilityLabel("Searching \(site.name)")
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private let ground = KitBox(fill: Palette.NS.wash, corners: .radius(7))
    private let icon: SiteIconView
    private let name = KitLabel("", font: .systemFont(ofSize: 13, weight: .medium), color: KitColor.ink)

    init(site: SearchSite) {
        self.site = site
        icon = SiteIconView(site: site)
        super.init(frame: .zero)
        wantsLayer = true
        name.text = site.name
        name.setAccessibilityElement(false)
        for view in [ground, icon, name] as [NSView] { addSubview(view) }
        kitAccess(label: "Searching \(site.name)", role: .group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var nameWidth: CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return ceil(name.measure(width: .greatestFiniteMagnitude).width * scale) / scale
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 8 + 14 + 6 + nameWidth + 8, height: 22) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        icon.frame = kitSnap(NSRect(x: 8, y: (bounds.height - 14) / 2, width: 14, height: 14))
        name.frame = kitSnap(NSRect(x: 28, y: 0, width: nameWidth, height: bounds.height))
    }
}

final class SiteOfferRowView: NSView {
    var site: SearchSite {
        didSet {
            guard site != oldValue else { return }
            icon.site = site
            words.text = "Search \(site.name)"
            setAccessibilityLabel("Search \(site.name), press Tab")
            needsLayout = true
        }
    }
    var take: () -> Void = {}

    private let icon: SiteIconView
    private let words = KitLabel("", font: .systemFont(ofSize: 13), color: KitColor.ink)
    private let cap = KitBox(fill: nil, stroke: KitColor.hairline, corners: .radius(5))
    private let capWord = KitLabel("Tab", font: .systemFont(ofSize: 11, weight: .medium), color: KitColor.muted)

    init(site: SearchSite) {
        self.site = site
        icon = SiteIconView(site: site)
        super.init(frame: .zero)
        words.text = "Search \(site.name)"
        words.setAccessibilityElement(false)
        capWord.setAccessibilityElement(false)
        cap.addSubview(capWord)
        for view in [icon, words, cap] as [NSView] { addSubview(view) }
        kitAccess(label: "Search \(site.name), press Tab", role: .group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let capText = ceil(capWord.measure(width: .greatestFiniteMagnitude).width * scale) / scale
        let capWidth = capText + 12
        cap.frame = kitSnap(NSRect(x: bounds.width - 10 - capWidth, y: (bounds.height - 18) / 2, width: capWidth, height: 18))
        capWord.frame = NSRect(x: 6, y: 0, width: capText, height: 18)
        icon.frame = kitSnap(NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14))
        let natural = ceil(words.measure(width: .greatestFiniteMagnitude).width * scale) / scale
        let room = max(0, cap.frame.minX - 20 - 34)
        words.frame = kitSnap(NSRect(x: 34, y: 0, width: min(natural, room), height: bounds.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        take()
    }
}

@MainActor
final class FieldListView: NSView {
    let browser: Browser
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let measure: String?
    let room: CGFloat?
    var settles = true
    var held = false { didSet { if held != oldValue, !held { needsLayout = true } } }
    var headerMuted = false { didSet { if headerMuted != oldValue { needsLayout = true } } }

    @MainActor
    private final class Row {
        let host = FieldHosts.row()
        var offer: Suggestion?
        var lit = false
        var key = ""
        var leaving = false
    }

    private let scroll = NSScrollView()
    private let content = FieldListContent()
    private let slab = FieldListSlab()
    private let topLine = KitBox(fill: KitColor.ink.withAlphaComponent(0.1))
    private let empty = KitLabel("", font: .systemFont(ofSize: 15), color: KitColor.muted)
    private var siteRow: SiteOfferRowView?
    private var placeRow: (host: NSView, place: FieldPlace)?
    private var heads: [String: KitLabel] = [:]
    private var rows: [Int: Row] = [:]
    private var frames: [Int: NSRect] = [:]
    private var headFrames: [String: NSRect] = [:]
    private var slabAt: Int?
    private var slabLit: Int?
    private var slabShown = false
    private var picked: Int??
    private var under = false
    private var built = false
    private var area: NSTrackingArea?

    init(browser: Browser, rowHeight: CGFloat, headerHeight: CGFloat, measure: String? = nil, room: CGFloat? = nil) {
        self.browser = browser
        self.rowHeight = rowHeight
        self.headerHeight = headerHeight
        self.measure = measure
        self.room = room
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 300))
        wantsLayer = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: room ?? 0, right: 0)
        scroll.documentView = content
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        content.addSubview(slab)
        content.addSubview(empty)
        empty.isHidden = true
        slab.alphaValue = 0
        topLine.alphaValue = 0
        topLine.isHidden = room == nil
        addSubview(scroll)
        addSubview(topLine)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        if scroll.frame != bounds { scroll.frame = bounds }
        let scale = window?.backingScaleFactor ?? 2
        topLine.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1 / max(scale, 1))
        guard !held else { return }
        let width = max(0, bounds.width - 14)
        let offers = browser.offers
        let sections = browser.fieldSections
        let animated = built && settles
        var y: CGFloat = 0
        frames = [:]
        headFrames = [:]

        placeOffer(width: width, y: &y)

        if let place = browser.fieldPlace, offers.isEmpty {
            empty.text = place.empty(for: browser.typed)
            empty.isHidden = false
            empty.frame = kitSnap(NSRect(x: 17, y: y, width: max(0, width - 20), height: rowHeight))
            y += rowHeight
        } else {
            empty.isHidden = true
        }

        var used = Set<Int>()
        var usedHeads = Set<String>()
        func lay(_ range: Range<Int>, section: String) {
            for index in range where offers.indices.contains(index) {
                let rect = NSRect(x: 7, y: y, width: width, height: rowHeight)
                frames[index] = rect
                y += rowHeight
                used.insert(index)
                let key = "\(section)|\(index)"
                let row = rows[index] ?? {
                    let made = Row()
                    content.addSubview(made.host)
                    rows[index] = made
                    return made
                }()
                let fresh = row.key != key || row.leaving
                if row.leaving {
                    row.leaving = false
                    row.host.layer?.removeAllAnimations()
                    row.host.alphaValue = 1
                }
                row.key = key
                let lit = browser.fieldRow == index
                if row.offer != offers[index] || row.lit != lit {
                    row.offer = offers[index]
                    row.lit = lit
                    let offer = offers[index]
                    FieldHosts.setRow(row.host, offer: offer, height: rowHeight, lit: lit,
                                      take: { [weak browser] in browser?.take(offer) },
                                      copy: { [weak browser] in browser?.copyAnswer($0, whole: true) })
                }
                if row.host.frame != rect { row.host.frame = rect }
                if fresh, animated { settle(row.host, order: index - range.lowerBound) }
            }
        }
        if sections.isEmpty {
            lay(0..<offers.count, section: "")
        } else {
            for section in sections {
                let label = heads[section.title] ?? {
                    let made = KitLabel(section.title, font: .systemFont(ofSize: 13))
                    content.addSubview(made)
                    heads[section.title] = made
                    return made
                }()
                label.color = headerMuted ? KitColor.muted : KitColor.ink
                label.opacity = headerMuted ? 1 : 0.75
                let words = ceil(label.measure(width: .greatestFiniteMagnitude).width * scale) / scale
                label.frame = kitSnap(NSRect(x: 15, y: y, width: words, height: headerHeight))
                headFrames[section.title] = NSRect(x: 7, y: y, width: words + 8, height: headerHeight)
                usedHeads.insert(section.title)
                y += headerHeight
                lay(section.range, section: section.title)
            }
        }
        for (title, label) in heads where !usedHeads.contains(title) {
            label.removeFromSuperview()
            heads[title] = nil
        }
        for (index, row) in rows where !used.contains(index) && !row.leaving {
            leave(index, row, animated: animated)
        }

        let along = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: y)
        if content.frame != along { content.frame = along }

        placeSlab(lit: browser.fieldRow, faint: browser.pointed != nil && browser.pointed != browser.picked)
        let now = browser.picked
        if picked.map({ $0 != now }) ?? false, let now, let rect = frames[now] { reveal(rect) }
        picked = .some(now)
        built = true
        scrolled()
    }

    var benchDrawn: [String: Any] {
        let shownRows = rows.values.filter { !$0.leaving && !$0.host.isHidden && $0.host.superview != nil }
            .sorted { $0.host.frame.minY < $1.host.frame.minY }
        let shownHeads = heads.filter { $0.value.superview != nil && !$0.value.isHidden }.sorted { $0.value.frame.minY < $1.value.frame.minY }
        return [
            "rows": shownRows.map { $0.offer?.primary ?? "" },
            "lit": shownRows.first { $0.lit }?.offer?.primary ?? "",
            "heads": shownHeads.map(\.key),
        ]
    }

    private func placeOffer(width: CGFloat, y: inout CGFloat) {
        let rect = NSRect(x: 7, y: y, width: width, height: 38)
        if let site = browser.siteOffer {
            let row = siteRow ?? {
                let made = SiteOfferRowView(site: site)
                made.take = { [weak browser] in _ = browser?.lockSiteOffer() }
                content.addSubview(made)
                siteRow = made
                return made
            }()
            row.site = site
            if row.frame != rect { row.frame = rect }
            frames[Browser.siteRow] = rect
            y += 38
        } else {
            siteRow?.removeFromSuperview()
            siteRow = nil
        }
        if browser.siteOffer == nil, let place = browser.placeOffer {
            if placeRow?.place != place {
                placeRow?.host.removeFromSuperview()
                let made = FieldHosts.placeOffer(place) { [weak browser] in _ = browser?.lockSiteOffer() }
                content.addSubview(made)
                placeRow = (made, place)
            }
            if let host = placeRow?.host, host.frame != rect { host.frame = rect }
            frames[Browser.siteRow] = rect
            y += 38
        } else {
            placeRow?.host.removeFromSuperview()
            placeRow = nil
        }
    }

    private func settle(_ view: NSView, order: Int) {
        guard let layer = view.layer else { return }
        layer.removeAllAnimations()
        if Motion.calm {
            if let fade = KitCurve.easeOut(0.14).animation("opacity", from: Swift.Float(0), to: Swift.Float(1)) {
                layer.add(fade, forKey: "settle")
            }
            return
        }
        let start = layer.convertTime(CACurrentMediaTime(), from: nil) + Double(min(max(order, 0), 8)) * 0.018
        let spring = KitSpring(response: 0.26, damping: 1)
        let down = (layer.superlayer?.contentsAreFlipped() ?? true) ? 6.0 : -6.0
        let rise = spring.animation("position.y", from: down, to: 0)
        rise.isAdditive = true
        let fade = spring.animation("opacity", from: Swift.Float(0), to: Swift.Float(1))
        for animation in [rise, fade] {
            animation.beginTime = start
            animation.fillMode = .backwards
        }
        layer.add(rise, forKey: "settleRise")
        layer.add(fade, forKey: "settle")
    }

    private func leave(_ index: Int, _ row: Row, animated: Bool) {
        let duration = Motion.calm ? 0.14 : 0.08
        guard animated, let layer = row.host.layer else {
            row.host.removeFromSuperview()
            rows[index] = nil
            return
        }
        row.leaving = true
        layer.removeAllAnimations()
        row.host.alphaValue = 0
        if let fade = KitCurve.easeOut(duration).animation("opacity", from: Swift.Float(1), to: Swift.Float(0)) {
            layer.add(fade, forKey: "settle")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self, weak row] in
            guard let self, let row, row.leaving, self.rows[index] === row else { return }
            row.host.removeFromSuperview()
            self.rows[index] = nil
        }
    }

    private func placeSlab(lit: Int?, faint: Bool) {
        func target(_ index: Int?) -> NSRect? { index.flatMap { frames[$0] }?.insetBy(dx: 0, dy: 1) }
        slab.faint = faint
        if !built {
            slabLit = lit
            slabAt = lit
            slabShown = lit != nil
            if let rect = target(lit) { slab.frame = rect }
            slab.alphaValue = slabShown && target(lit) != nil ? (faint ? 0.5 : 1) : 0
            return
        }
        if lit != slabLit {
            let old = slabLit
            slabLit = lit
            if let lit {
                let fresh = old == nil || !slabShown
                slabAt = lit
                slabShown = true
                if let rect = target(lit) {
                    if fresh { slab.frame = rect } else { glide(slab, to: rect) }
                }
            } else {
                slabShown = false
            }
        } else if let rect = target(slabAt), slab.frame != rect, slab.layer?.animation(forKey: "position") == nil {
            slab.frame = rect
        }
        let wanted: CGFloat = slabShown && target(slabAt) != nil ? (faint ? 0.5 : 1) : 0
        guard slab.alphaValue != wanted else { return }
        let from = slab.layer?.presentation()?.opacity ?? Swift.Float(slab.alphaValue)
        slab.alphaValue = wanted
        if let fade = Motion.kitQuick.animation("opacity", from: from, to: Swift.Float(wanted)) {
            slab.layer?.add(fade, forKey: "opacity")
        }
    }

    private func glide(_ view: NSView, to frame: NSRect) {
        guard let layer = view.layer else {
            view.frame = frame
            return
        }
        let shown = layer.presentation() ?? layer
        let from = (position: shown.position, bounds: shown.bounds)
        view.frame = frame
        let curve = Motion.kitGlide
        if let move = curve.animation("position", from: NSValue(point: from.position), to: NSValue(point: layer.position)) {
            layer.add(move, forKey: "position")
        }
        if let size = curve.animation("bounds", from: NSValue(rect: from.bounds), to: NSValue(rect: layer.bounds)) {
            layer.add(size, forKey: "bounds")
        }
    }

    private func reveal(_ rect: NSRect) {
        let clip = scroll.contentView
        let seen = clip.bounds
        let insets = scroll.contentInsets
        let top = seen.minY + insets.top
        let bottom = seen.maxY - insets.bottom
        var y = seen.minY
        if rect.minY < top {
            y = rect.minY - insets.top
        } else if rect.maxY > bottom {
            y = rect.maxY - seen.height + insets.bottom
        } else {
            return
        }
        let lowest = max(-insets.top, content.frame.height + insets.bottom - seen.height)
        y = min(max(y, -insets.top), lowest)
        clip.scroll(to: NSPoint(x: seen.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        let clip = scroll.contentView.bounds
        let insets = scroll.contentInsets
        if room != nil {
            let height = content.frame.height
            let top = clip.minY + insets.top > 1
            let bottom = clip.maxY - insets.bottom < height - 1
            if top != under {
                under = top
                let from = topLine.layer?.presentation()?.opacity ?? Swift.Float(topLine.alphaValue)
                topLine.alphaValue = top ? 1 : 0
                if built, let fade = Motion.kitQuick.animation("opacity", from: from, to: Swift.Float(top ? 1 : 0)) {
                    topLine.layer?.add(fade, forKey: "opacity")
                }
            }
            if Store.testing {
                ColumnEdges.seen["field.top"] = top ? 1 : 0
                ColumnEdges.seen["field.bottom"] = bottom ? 1 : 0
                let names = ["offsetY", "contentH", "containerH", "insetTop", "insetBottom", "visibleMinY", "visibleMaxY"]
                let numbers = [clip.minY, height, scroll.frame.height, insets.top, insets.bottom, clip.minY, clip.maxY]
                for (name, value) in zip(names, numbers) { ColumnEdges.seen["field." + name] = value }
            }
        }
        guard Store.testing, let measure else { return }
        for (index, rect) in frames where index >= 0 {
            if let global = content.fieldGlobal(rect) { FieldLayout.note("\(measure).row.\(index)", global) }
        }
        for (title, rect) in headFrames {
            if let global = content.fieldGlobal(rect) { FieldLayout.note("\(measure).head.\(title)", global) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(made)
        area = made
    }

    override func mouseEntered(with event: NSEvent) { pointed(event) }
    override func mouseMoved(with event: NSEvent) { pointed(event) }

    override func mouseExited(with event: NSEvent) {
        browser.pointed = nil
    }

    private func pointed(_ event: NSEvent) {
        if let holder = superview {
            let spot = holder.convert(event.locationInWindow, from: nil)
            let asked = holder.superview.map { $0.convert(spot, from: holder) } ?? spot
            if let hit = holder.hitTest(asked), !hit.isDescendant(of: self) {
                if browser.pointed != nil { browser.pointed = nil }
                return
            }
        }
        let point = content.convert(event.locationInWindow, from: nil)
        guard let index = frames.first(where: { $0.value.contains(point) })?.key else { return }
        browser.point(at: index)
    }
}

private final class FieldListContent: NSView {
    override var isFlipped: Bool { true }
}

private final class FieldListSlab: NSView {
    var faint = false { didSet { if faint != oldValue { needsDisplay = true } } }

    private static func pair(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }

    private let fill = KitBox(fill: nil, corners: .radius(12))
    private let rim = CAGradientLayer()
    private let rimShape = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        fill.gradient = [Self.pair(NSColor(white: 1, alpha: 0.92), NSColor(white: 1, alpha: 0.19)),
                         Self.pair(NSColor(white: 1, alpha: 0.7), NSColor(white: 1, alpha: 0.13))]
        rimShape.fillColor = nil
        rimShape.strokeColor = NSColor.black.cgColor
        rimShape.lineWidth = 0.75
        rim.mask = rimShape
        rim.zPosition = 1
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 3
        addSubview(fill)
        layer?.addSublayer(rim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        fill.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = min(12, min(bounds.width, bounds.height) / 2)
        let path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layer?.shadowPath = path
        rim.frame = bounds
        rimShape.frame = bounds
        let inner = bounds.insetBy(dx: 0.375, dy: 0.375)
        let innerRadius = max(0, radius - 0.375)
        rimShape.path = CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
        CATransaction.commit()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        let dark = kitDark
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rim.colors = dark ? [NSColor(white: 1, alpha: 0.22).cgColor, NSColor(white: 1, alpha: 0.06).cgColor]
                          : [NSColor(white: 0, alpha: 0.05).cgColor, NSColor(white: 0, alpha: 0.13).cgColor]
        rim.startPoint = CGPoint(x: 0.5, y: 0)
        rim.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.shadowOpacity = faint ? 0 : dark ? 0.24 : 0.11
        layer?.shadowOffset = CGSize(width: 0, height: layer?.contentsAreFlipped() == true ? 1 : -1)
        CATransaction.commit()
    }
}

final class AddressTextField: NSTextField {
    static let prompt = "Enter a web address"
    static let shown = NSMapTable<Browser, AddressTextField>.weakToWeakObjects()

    let keys: AddressFieldKeys
    var arrived: (() -> Void)?
    private let size: CGFloat

    init(keys: AddressFieldKeys, size: CGFloat = 20, prompt: String = AddressTextField.prompt) {
        self.keys = keys
        self.size = size
        super.init(frame: .zero)
        Self.shown.setObject(self, forKey: keys.browser)
        delegate = keys
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: size)
        textColor = Palette.NS.ink
        lineBreakMode = .byClipping
        cell?.usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        placeholderAttributedString = placeholder(prompt)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func placeholder(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: Palette.NS.ink.withAlphaComponent(0.35),
        ])
    }

    func update(browser: Browser, tab: Tab.ID?, search: String?, prompt: String, live: Bool) {
        keys.browser = browser
        keys.tab = tab
        keys.live = live
        if live, Self.shown.object(forKey: browser) !== self { Self.shown.setObject(self, forKey: browser) }

        let want = search ?? browser.completed
        if want != keys.synced {
            keys.synced = want
            stringValue = want
            keys.select(from: search == nil ? browser.typed.count : want.count, in: self)
        }
        let shownPrompt = search != nil ? "Search actions" : browser.fieldPlace.map { "Search \($0.title)" } ?? prompt
        if keys.placeholder != shownPrompt {
            keys.placeholder = shownPrompt
            placeholderAttributedString = placeholder(shownPrompt)
        }

        if keys.answered != browser.focusRequest {
            keys.answered = browser.focusRequest
            if live { DispatchQueue.main.async { [keys] in keys.focus(self) } }
        }
    }

    func lineFrame(x: CGFloat, width: CGFloat, in height: CGFloat) -> NSRect {
        let font = font ?? .systemFont(ofSize: size)
        return NSRect(x: x, y: font.capCentredTop(in: height, baseline: firstBaselineOffsetFromTop), width: width, height: 28)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let arrived else { return }
        self.arrived = nil
        arrived()
    }
}

final class AddressFieldKeys: NSObject, NSTextFieldDelegate {
    var browser: Browser
    var tab: Tab.ID?
    var live = true
    var answered = -1
    var synced = ""
    var placeholder: String?

    private var deleting = false
    private var capturingSnippet = false

    init(browser: Browser) {
        self.browser = browser
    }

    @MainActor func focus(_ field: AddressTextField, captured: Bool = false) {
        guard tab == nil || tab == browser.activeID else { return }
        guard live else { return }
        guard AddressTextField.shown.object(forKey: browser) === field else { return }
        guard let window = field.window else {
            field.arrived = { [weak self, weak field] in
                DispatchQueue.main.async {
                    guard let self, let field, self.browser.fieldShowing else { return }
                    self.focus(field)
                }
            }
            return
        }
        field.arrived = nil
        if !captured, field.currentEditor() == nil {
            guard !capturingSnippet else { return }
            capturingSnippet = true
            browser.rememberSnippetSelection { [weak self, weak field] in
                guard let self else { return }
                self.capturingSnippet = false
                guard let field, self.browser.fieldShowing else { return }
                self.focus(field, captured: true)
            }
            return
        }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() as? NSTextView else { return }
        defer { browser.fieldFocused(in: window) }
        editor.selectedTextAttributes = [
            .backgroundColor: Palette.NS.ink.withAlphaComponent(0.12),
            .foregroundColor: Palette.NS.ink,
        ]
        if browser.active?.isBlank == true, !browser.typed.isEmpty {
            select(from: browser.typed.count, in: field)
        } else {
            editor.selectAll(nil)
        }
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        let text = field.stringValue

        if browser.fieldMenu.showing {
            browser.fieldMenu.query = text
            synced = text
            deleting = false
            return
        }

        browser.typed = text
        guard !deleting, let ending = browser.ending else {
            if deleting { browser.stopCompleting() }
            deleting = false
            synced = browser.completed
            return
        }
        deleting = false

        field.stringValue = text + ending
        synced = field.stringValue
        select(from: text.count, in: field)
    }

    func select(from start: Int, in field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        editor.selectedTextAttributes = [
            .backgroundColor: Palette.NS.ink.withAlphaComponent(0.12),
            .foregroundColor: Palette.NS.ink,
        ]
        let length = field.stringValue.count
        guard start <= length else { return }
        editor.selectedRange = NSRange(location: start, length: length - start)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.insertNewline(_:)):
            browser.submit()
            return true
        case #selector(NSResponder.moveDown(_:)):
            browser.walk(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            browser.walk(-1)
            return true
        case #selector(NSResponder.deleteWordBackward(_:)):
            deleting = true
            let selected = textView.selectedRange()
            guard browser.ending != nil, selected.length > 0,
                  NSMaxRange(selected) == (textView.string as NSString).length
            else { return false }
            textView.delete(nil)
            deleting = true
            textView.deleteWordBackward(nil)
            return true
        case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty && browser.fieldPlace != nil:
            browser.leavePlace()
            return true
        case #selector(NSResponder.deleteBackward(_:)) where textView.string.isEmpty && browser.siteChip != nil:
            browser.siteChip = nil
            return true
        case #selector(NSResponder.deleteBackward(_:)),
             #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordForward(_:)):
            deleting = true
            return false
        default:
            return false
        }
    }
}

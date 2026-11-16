import AppKit
import Combine
import WebKit

enum NewTabStyle: String, CaseIterable, Identifiable {
    case page, floating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .page: return "New Tab Page"
        case .floating: return "Floating Field"
        }
    }
}

extension Preferences {
    var newTabStyle: NewTabStyle {
        get { floatingNewTab ? .floating : .page }
        set { floatingNewTab = newValue == .floating }
    }
}

extension Browser {
    var newTabPageShown: Bool {
        !prefs.floatingNewTab && active?.isBlank == true
    }

    func escapeNewTab() -> Bool {
        guard let blank = active, blank.isBlank, editingTab == nil else { return false }
        if !typed.isEmpty || siteChip != nil {
            siteChip = nil
            picked = nil
            typed = ""
            blank.draft = ""
            return true
        }
        guard let back = tabs.filter({ $0.id != blank.id && !$0.agent }).max(by: { $0.touched < $1.touched }) else {
            return false
        }
        select(back)
        close(blank)
        return true
    }

    func escapeEmptyNewTabPage() -> Bool {
        guard newTabPageShown, typed.isEmpty, siteChip == nil, !fieldMenu.showing else { return false }
        return escapeNewTab()
    }

    func switchFromNewTab(to tab: Tab) -> Bool {
        guard !prefs.floatingNewTab, let blank = active, blank.isBlank, blank.id != tab.id,
              split(for: blank) == nil, !launching
        else { return false }
        typed = ""
        picked = nil
        editing = false
        blank.draft = ""
        select(tab)
        close(blank)
        return true
    }

    func leavesWhenLeft(_ tab: Tab) -> Bool {
        tab.isBlank && tab.draft.isEmpty && tab.pin == nil && tab.groupID == nil && !tab.agent && !tab.bench
            && split(for: tab) == nil
    }

    func noteLeft(_ old: Tab.ID, words: String) {
        guard let left = tabs.first(where: { $0.id == old }), left.isBlank,
              let id = activeID, id != old, tabs.contains(where: { $0.id == id }),
              !visibleTabIDs.contains(old)
        else { return }
        if !words.isEmpty { left.draft = words }
        guard siteChip == nil, leavesWhenLeft(left) else { return }
        leftNewTabs.insert(old)
        DispatchQueue.main.async { [weak self] in self?.closeLeftNewTabs() }
    }

    func closeLeftNewTabs() {
        let left = leftNewTabs
        leftNewTabs = []
        for id in left {
            guard tabs.count > 1, let tab = tabs.first(where: { $0.id == id }),
                  !visibleTabIDs.contains(id), leavesWhenLeft(tab)
            else { continue }
            close(tab)
        }
    }
}

final class NewTabPageView: KitFlippedView {
    static let prompt = "Search"
    static let fieldHeight: CGFloat = 60
    static let rowHeight: CGFloat = 38
    static let headerHeight: CGFloat = 28
    private static let widest = KitPlatePage.columnWidth
    private static let gap: CGFloat = 12

    struct Layout: Equatable {
        var fieldWidth: CGFloat
        var fieldTop: CGFloat
        var room: CGFloat
    }

    static func layout(in size: CGSize) -> Layout {
        let width = min(widest, max(260, size.width - KitPlatePage.side * 2))
        let fieldTop = max(24, (size.height * 0.42 - fieldHeight / 2).rounded())
        return Layout(fieldWidth: width, fieldTop: fieldTop,
                      room: max(0, size.height - fieldTop - fieldHeight - gap - 24))
    }

    let browser: Browser
    var tab: Tab { didSet { if tab !== oldValue { watch(); needsLayout = true } } }
    var corner: CGFloat { didSet { if corner != oldValue { ground.corner = corner } } }
    var look: SpaceLook? { didSet { if look != oldValue { needsLayout = true } } }
    var resting: Bool { didSet { if resting != oldValue { needsLayout = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { inked() } } }

    private let ground = PageGroundView()
    private let front = KitFlippedView()
    private let glass = KitGlass(radius: 22, tint: Palette.NS.glassTint)
    private let row = KitFlippedView()
    private let lens = KitSymbol("magnifyingglass", style: .init(size: 17, weight: IconLook.weight), tint: KitColor.ink)
    private let hint = KitLabel(NewTabPageView.prompt, font: .systemFont(ofSize: 22), color: KitColor.ink)
    private var address: NSView?
    private var siteChip: NSView?
    private var placeChip: NSView?
    private var fresh: [NSView] = []
    private let list = KitFlippedView()
    private var listHost: NSView?

    private var watching: AnyCancellable?
    private var seenActive: Tab.ID?
    private var seenRefusals: Int
    private var shownSite: SearchSite?
    private var shownPlace: FieldPlace?
    private var listKind: String?
    private var addressInput: String?

    init(browser: Browser, tab: Tab, corner: CGFloat, look: SpaceLook? = nil, resting: Bool = false) {
        self.browser = browser
        self.tab = tab
        self.corner = corner
        self.look = look
        self.resting = resting
        seenActive = browser.activeID
        seenRefusals = browser.refusals
        super.init(frame: .zero)
        wantsLayer = true
        ground.corner = corner
        hint.opacity = 0.35
        lens.opacity = 0.75
        for view in [ground, front] as [NSView] { addSubview(view) }
        front.wantsLayer = true
        front.addSubview(glass)
        front.addSubview(list)
        glass.contentView = row
        row.addSubview(lens)
        row.addSubview(hint)
        list.wantsLayer = true
        kitAccess(label: "New Tab", role: .group)
        watch()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var here: Bool { !resting && browser.activeID == tab.id }

    private var listHeight: CGFloat {
        let menu = browser.fieldMenu
        if menu.showing { return Self.headerHeight + CGFloat(max(menu.items.count, 1)) * Self.rowHeight }
        let rows = CGFloat(browser.offers.count + (browser.offerRowShown || browser.placeIsEmpty ? 1 : 0)) * Self.rowHeight
        return rows + CGFloat(browser.fieldSections.count) * Self.headerHeight
    }

    private func watch() {
        let browser = browser
        watching = kitObserve(initial: false, { [weak browser] in (browser?.activeID, browser?.refusals) }) { [weak self] _ in
            self?.noticeChanges()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        seenActive = browser.activeID
        if here {
            addressField()
            browser.fieldRose()
        }
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard !resting, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if here { browser.askFocus() } else { browser.focusPane(tab) }
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        let layout = Self.layout(in: size)
        let here = here
        ground.frame = bounds
        let page = (look ?? browser.space.look ?? SpaceLook()).page(dark: kitDark)
        ground.show(page)
        if front.appearance?.name != page.appearance?.name { front.appearance = page.appearance }
        front.frame = bounds
        glass.frame = kitSnap(NSRect(x: (size.width - layout.fieldWidth) / 2, y: layout.fieldTop,
                                     width: layout.fieldWidth, height: Self.fieldHeight))
        row.frame = glass.bounds
        placeRow(here: here)
        placeList(here: here, layout: layout)
    }

    private func placeRow(here: Bool) {
        let site = here ? browser.siteChip : nil
        let place = here ? browser.fieldPlace : nil
        let chipsMoved = site != shownSite || place != shownPlace
        siteChip = chip(siteChip, showing: site != shownSite ? site.map { value in { NewTabHosts.site($0, site: value, lift: self.ink.lift) } } : nil,
                        keep: site != nil)
        placeChip = chip(placeChip, showing: place != shownPlace ? place.map { value in { NewTabHosts.place($0, place: value, lift: self.ink.lift) } } : nil,
                         keep: place != nil)
        shownSite = site
        shownPlace = place
        if here {
            addressField()
        } else if let field = address {
            field.removeFromSuperview()
            address = nil
            addressInput = nil
        }
        hint.isHidden = here
        let height = row.bounds.height
        var x: CGFloat = 20
        func centred(width: CGFloat, height natural: CGFloat) -> NSRect {
            kitSnap(NSRect(x: x, y: (height - natural) / 2, width: width, height: natural))
        }
        let symbol = lens.intrinsicContentSize
        lens.frame = centred(width: symbol.width, height: symbol.height)
        x += symbol.width + 12
        let moves: KitCurve = chipsMoved ? Motion.kitQuick : .none
        for chip in [siteChip, placeChip].compactMap({ $0 }) {
            let fit = chip.fittingSize
            move(chip, to: centred(width: fit.width, height: fit.height), curve: moves)
            if fresh.contains(where: { $0 === chip }) { arrive(chip) }
            x += fit.width + 12
        }
        fresh.removeAll()
        let rest = max(0, row.bounds.width - 20 - x)
        if let field = address {
            let text = (field as? NewTabSlot)?.content as? AddressTextField
            move(field, to: text.map { kitSnap($0.lineFrame(x: x, width: rest, in: height)) } ?? centred(width: rest, height: 28), curve: moves)
        }
        let natural = hint.measure(width: .greatestFiniteMagnitude)
        hint.frame = kitSnap(NSRect(x: x, y: hint.font.capCentredTop(in: height, baseline: hint.font.ascender),
                                    width: min(ceil(natural.width), rest), height: natural.height))
    }

    private func addressField() {
        let menu = browser.fieldMenu
        let input = "\(tab.id)|\(menu.showing ? menu.query : "\u{0}")|\(ink.lift)"
        let field = address ?? NewTabHosts.make()
        if address == nil {
            address = field
            row.addSubview(field)
        }
        if input != addressInput {
            addressInput = input
            NewTabHosts.address(field, browser: browser, tab: tab.id, search: menu.showing ? menu.query : nil,
                                prompt: Self.prompt, lift: ink.lift)
            if field.frame.isEmpty { field.frame = NSRect(x: 0, y: 0, width: max(row.bounds.width - 60, 200), height: 28) }
            if field.window != nil { field.layoutSubtreeIfNeeded() }
        }
    }

    private func move(_ view: NSView, to frame: NSRect, curve: KitCurve) {
        guard view.frame != frame else { return }
        guard case .easeOut(let duration) = curve, view.frame != .zero else {
            view.frame = frame
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            view.frame = frame
        }
    }

    private func chip(_ current: NSView?, showing make: ((NSView) -> Void)?, keep: Bool) -> NSView? {
        if let make {
            current.map(leave)
            let made = NewTabHosts.make()
            make(made)
            made.wantsLayer = true
            row.addSubview(made)
            fresh.append(made)
            return made
        }
        if !keep, let current {
            leave(current)
            return nil
        }
        return current
    }

    private func chipScale(_ view: NSView, _ amount: CGFloat) -> CATransform3D {
        let mid = view.bounds.midY
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(0, -mid, 0), CATransform3DMakeScale(amount, amount, 1)),
                                   CATransform3DMakeTranslation(0, mid, 0))
    }

    private func arrive(_ view: NSView) {
        let curve = Motion.kitQuick
        guard curve.animates, let layer = view.layer else { return }
        layer.opacity = 0
        layer.transform = chipScale(view, 0.9)
        layer.kitAnimate("opacity", to: 1, curve: curve, key: "chip")
        layer.kitAnimate("transform", to: NSValue(caTransform3D: CATransform3DIdentity), curve: curve)
    }

    private func leave(_ view: NSView) {
        let curve = Motion.kitQuick
        guard case .easeOut(let duration) = curve, let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        layer.kitAnimate("opacity", to: 0, curve: curve, key: "chip")
        layer.kitAnimate("transform", to: NSValue(caTransform3D: chipScale(view, 0.9)), curve: curve)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { view.removeFromSuperview() }
    }

    private func placeList(here: Bool, layout: Layout) {
        guard here else {
            listHost?.removeFromSuperview()
            listHost = nil
            listKind = nil
            list.isHidden = true
            return
        }
        list.isHidden = false
        let menu = browser.fieldMenu
        let width = layout.fieldWidth + 14
        list.frame = kitSnap(NSRect(x: (bounds.width - width) / 2, y: layout.fieldTop + Self.fieldHeight + Self.gap,
                                    width: width, height: max(0, min(listHeight, layout.room))))
        let kind = menu.showing ? "menu" : "list.\(browser.typed.isEmpty && browser.siteChip == nil && browser.fieldPlace == nil)"
        if kind != listKind {
            if listKind != nil { list.layer?.kitTransition(Motion.kitQuick) }
            listKind = kind
            listHost?.removeFromSuperview()
            let host = NewTabHosts.make()
            if menu.showing {
                NewTabHosts.menu(host, menu: menu, rowHeight: Self.rowHeight, headerHeight: Self.headerHeight, lift: ink.lift)
            } else {
                NewTabHosts.list(host, browser: browser, rowHeight: Self.rowHeight, headerHeight: Self.headerHeight, lift: ink.lift)
            }
            list.addSubview(host)
            listHost = host
        }
        listHost?.frame = NSRect(x: 0, y: 0, width: list.bounds.width, height: max(list.bounds.height, 1))
    }

    private func noticeChanges() {
        guard window != nil else { return }
        let active = browser.activeID
        if active != seenActive {
            seenActive = active
            if here {
                addressField()
                browser.fieldRose()
            }
        }
        let refusals = browser.refusals
        if refusals != seenRefusals {
            seenRefusals = refusals
            if here { shake() }
        }
    }

    private func shake() {
        guard !Motion.reduced, let layer = glass.layer else { return }
        let steps = 60
        let travel = (0...steps).map { Double($0) / Double(steps) }
        let wobble = CAKeyframeAnimation(keyPath: "transform.translation.x")
        wobble.values = travel.map { sin($0 * .pi * 6) * 7 * (1 - $0) }
        wobble.keyTimes = travel.map { NSNumber(value: $0) }
        wobble.duration = 0.5
        wobble.timingFunction = CAMediaTimingFunction(name: .easeOut)
        wobble.isAdditive = true
        layer.add(wobble, forKey: "shake")
    }

    private func inked() {
        lens.ink = ink
        hint.ink = ink
        addressInput = nil
        listKind = nil
        shownSite = nil
        shownPlace = nil
        needsLayout = true
    }
}

@MainActor
enum NewTabSurface {
    static let tab = Tab(configuration: WKWebViewConfiguration())

    static func make(_ request: [String: Any]) -> NSView {
        let width = CGFloat(request["width"] as? Double ?? 1000), height = CGFloat(request["height"] as? Double ?? 680)
        let look = (request["space"] as? String).flatMap { SpaceLook.named($0) } ?? SpaceLook()
        let browser = Browsers.primary ?? Browsers.acting
        let view = NewTabPageView(browser: browser, tab: tab, corner: 10, look: look, resting: true)
        view.kitSize(width: width, height: height)
        return view
    }
}

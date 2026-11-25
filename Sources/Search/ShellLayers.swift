import AppKit

@MainActor
class ShellLayer: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
final class ShellGroundLayer: ShellLayer {
    let browser: Browser
    private var live: LiveGroundView?
    private var plain: KitBox?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if browser.asCards {
            plain?.removeFromSuperview()
            plain = nil
            let view = live ?? {
                let made = LiveGroundView(browser: browser, motion: browser.spaceMotion, opaque: browser.fullScreen)
                addSubview(made)
                live = made
                return made
            }()
            view.solid = browser.fullScreen
            view.groundDark = kitDark
            view.frame = bounds
        } else {
            live?.removeFromSuperview()
            live = nil
            let view = plain ?? {
                let made = KitBox(fill: Palette.NS.ground)
                addSubview(made)
                plain = made
                return made
            }()
            view.frame = bounds
        }
    }
}

@MainActor
final class ShellPanelLayer: ShellLayer {
    struct Panel: Equatable {
        var up = false
        var top: CGFloat = 0
        var gap: CGFloat = 0
        var width: CGFloat = 0
    }

    let browser: Browser
    var panel = Panel() { didSet { if panel != oldValue { changed(from: oldValue) } } }
    private var beside: SidePanelBesideView?
    private var placed = false

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var right: Bool { browser.prefs.sidePosition == .right }

    private func target(_ view: SidePanelBesideView) -> CGRect {
        let width = panel.width + (browser.asCards ? Metrics.cardGap : 1)
        let x = right ? panel.gap : bounds.width - panel.gap - width
        return CGRect(x: x, y: panel.top, width: width, height: max(0, bounds.height - panel.top - panel.gap))
    }

    private func away(_ frame: CGRect) -> CGFloat {
        right ? -frame.maxX : bounds.width - frame.minX
    }

    private func changed(from was: Panel) {
        needsLayout = true
        guard was.up != panel.up, placed, window != nil else { return }
        layoutSubtreeIfNeeded()
        guard let view = beside, let layer = view.layer else { return }
        let off = away(view.frame)
        let curve = Motion.kitGlide
        if panel.up {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setValue(off, forKeyPath: "transform.translation.x")
            layer.opacity = 0
            CATransaction.commit()
            layer.kitAnimate("transform.translation.x", to: 0, curve: curve)
            layer.kitAnimate("opacity", to: Swift.Float(1), curve: curve)
        } else {
            layer.kitAnimate("transform.translation.x", to: off, curve: curve)
            layer.kitAnimate("opacity", to: Swift.Float(0), curve: curve)
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.calm ? 0.2 : 0.45)) { [weak self, weak view] in
                guard let self, let view, !panel.up, beside === view else { return }
                view.removeFromSuperview()
                beside = nil
            }
        }
    }

    override func layout() {
        super.layout()
        placed = true
        let cards = browser.asCards
        if panel.up {
            let view = beside ?? {
                let made = SidePanelBesideView(browser: browser)
                made.wantsLayer = true
                addSubview(made)
                beside = made
                return made
            }()
            view.onLeft = right
            view.card = cards
            view.width = panel.width
            let frame = target(view)
            if view.frame != frame { view.frame = frame }
        } else if let view = beside, view.layer?.animationKeys()?.isEmpty ?? true {
            view.removeFromSuperview()
            beside = nil
        }
    }
}

@MainActor
final class BarStack: KitFlippedView {
    struct Bar {
        let view: NSView
        let kind: NoticeKind
        var clock: NoticeClock?
        var pane: CGRect?

        init(view: NSView, kind: NoticeKind, clock: NoticeClock? = nil, pane: CGRect? = nil) {
            self.view = view
            self.kind = kind
            self.clock = clock
            self.pane = pane
        }
    }

    var bottom: CGFloat = 30
    var spacing: CGFloat = 8
    var page: CGRect?
    private var bars: [Bar] = []
    private var leaving: [ObjectIdentifier: NSView] = [:]
    private var sizes: [ObjectIdentifier: CGSize] = [:]
    private var placed = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    static var arrival: KitArrival { NoticeMotion.arrival }
    static var leaveTime: TimeInterval { NoticeMotion.leaveTime }

    var shown: [Bar] { bars }

    func show(_ next: [Bar]) {
        let wanted = Set(next.map { ObjectIdentifier($0.view) })
        let going = bars.filter { !wanted.contains(ObjectIdentifier($0.view)) }
        for bar in going { leave(bar) }
        var arriving: [NSView] = []
        for bar in next where bar.view.superview !== self || leaving[ObjectIdentifier(bar.view)] != nil {
            if leaving.removeValue(forKey: ObjectIdentifier(bar.view)) == nil { addSubview(bar.view) }
            if placed, window != nil { arriving.append(bar.view) }
        }
        for bar in next { bar.clock?.view = bar.view }
        bars = next
        place(animated: placed && window != nil)
        placed = true
        let waits = !going.isEmpty && going.contains { old in
            arriving.contains { $0.frame.intersects(old.view.frame) }
        }
        for view in arriving {
            NoticeMotion.show(view, false, animated: false)
            guard waits else {
                NoticeMotion.show(view, true)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + NoticeMotion.waitTime) { [weak self, weak view] in
                guard let self, let view, view.superview === self, leaving[ObjectIdentifier(view)] == nil else { return }
                NoticeMotion.show(view, true)
            }
        }
    }

    private func leave(_ bar: Bar) {
        let view = bar.view
        sizes[ObjectIdentifier(view)] = nil
        guard window != nil else {
            view.removeFromSuperview()
            return
        }
        let key = ObjectIdentifier(view)
        leaving[key] = view
        NoticeMotion.show(view, false)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaveTime) { [weak self, weak view] in
            guard let self, let view, leaving[key] === view else { return }
            leaving[key] = nil
            view.removeFromSuperview()
        }
    }

    static func size(_ view: NSView, width: CGFloat) -> CGSize {
        if let question = view as? QuestionView { return question.fit(width) }
        let natural = view.intrinsicContentSize
        return CGSize(width: natural.width == NSView.noIntrinsicMetric ? width : natural.width,
                      height: natural.height == NSView.noIntrinsicMetric ? view.fittingSize.height : natural.height)
    }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    static func centre(_ width: CGFloat, pane: CGRect?, across: CGFloat) -> CGFloat {
        guard let pane, width <= pane.width else { return across / 2 }
        return pane.midX
    }

    static func fitted(_ size: CGSize, view: NSView, pane: CGRect?) -> CGSize {
        guard let pane, let shrinks = view as? BarShrinks else { return size }
        let room = pane.width - 2 * Metrics.cardGap
        guard size.width > room else { return size }
        return CGSize(width: max(shrinks.leastWidth, room), height: size.height)
    }

    private func place(animated: Bool) {
        var y = bounds.height - bottom
        for bar in bars.reversed() {
            let size = Self.fitted(Self.size(bar.view, width: bounds.width), view: bar.view, pane: bar.pane)
            y -= size.height
            let x = Self.centre(size.width, pane: bar.pane ?? page, across: bounds.width) - size.width / 2
            let frame = kitSnap(CGRect(x: x, y: y, width: size.width, height: size.height))
            let was = bar.view.frame
            let key = ObjectIdentifier(bar.view)
            if animated, let old = sizes[key], old != frame.size, bar.view.layer?.animation(forKey: "arrive") == nil {
                NoticeMotion.change(bar.view)
            }
            sizes[key] = frame.size
            if was != frame {
                bar.view.frame = frame
                if animated, was.width > 0, was.size == frame.size, let layer = bar.view.layer, layer.animation(forKey: "arrive") == nil {
                    let dy = was.minY - frame.minY
                    let dx = was.minX - frame.minX
                    layer.removeAnimation(forKey: "stack")
                    if let move = Motion.kitSettle.animation("transform.translation", from: NSValue(size: CGSize(width: dx, height: dy)),
                                                              to: NSValue(size: .zero)) as? CAPropertyAnimation {
                        move.isAdditive = true
                        layer.add(move, forKey: "stack")
                    }
                }
            }
            y -= spacing
        }
    }
}

@MainActor
final class CapsuleNote: KitFlippedView {
    private let glass = KitGlass.floating(capsule: true)
    private let inside = KitFlippedView()
    let label: KitLabel
    let trailing: KitLabel?
    var onPress: (() -> Void)?

    init(_ text: String, size: CGFloat, trailing: String? = nil) {
        label = KitLabel(text, font: .systemFont(ofSize: size), color: KitColor.ink)
        self.trailing = trailing.map { KitLabel($0, font: .systemFont(ofSize: size), color: KitColor.muted) }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(glass)
        glass.hold(inside)
        inside.addSubview(label)
        if let trailing = self.trailing { inside.addSubview(trailing) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var shownTrailing: Bool { !(trailing?.text.isEmpty ?? true) }

    override var intrinsicContentSize: NSSize {
        let text = label.measure(width: .greatestFiniteMagnitude)
        var width = ceil(text.width)
        if shownTrailing, let trailing { width += 8 + ceil(trailing.measure(width: .greatestFiniteMagnitude).width) }
        return NSSize(width: width + 30, height: ceil(text.height) + 18)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        inside.frame = glass.bounds
        let text = label.measure(width: .greatestFiniteMagnitude)
        label.frame = kitSnap(CGRect(x: 15, y: 9, width: ceil(text.width), height: ceil(text.height)))
        if let trailing {
            trailing.isHidden = !shownTrailing
            let size = trailing.measure(width: .greatestFiniteMagnitude)
            trailing.frame = kitSnap(CGRect(x: label.frame.maxX + 8, y: 9, width: ceil(size.width), height: ceil(size.height)))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard onPress != nil else { return nil }
        let inside = convert(point, from: superview)
        return NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).contains(inside) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }
}

@MainActor
final class AnnouncementView {
    let note = CapsuleNote("", size: 12, trailing: "")
    private weak var browser: Browser?
    private var file: URL?
    private var undoes = false

    init(browser: Browser) {
        self.browser = browser
        note.onPress = { [weak browser] in
            guard let browser else { return }
            if browser.announcedUndo != nil {
                browser.undoAnnounced()
            } else if let file = browser.announcedFile {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else {
                browser.hints.pressed()
            }
        }
        _ = browser.hints
        note.setAccessibilityElement(true)
        note.setAccessibilityRole(.button)
    }

    var shown: Bool { browser?.announcement != nil }

    func sync() {
        guard let browser else { return }
        if let text = browser.announcement {
            if note.label.text != text, !note.label.text.isEmpty, note.superview != nil, note.layer?.animation(forKey: "arrive") == nil {
                NoticeMotion.change(note)
            }
            note.label.text = text
            file = browser.announcedFile
            undoes = browser.announcedUndo != nil
        }
        note.trailing?.text = undoes ? "Undo" : file != nil ? "Show in Finder" : ""
        note.setAccessibilityLabel(note.label.text)
        note.invalidateIntrinsicContentSize()
        note.needsLayout = true
    }
}

@MainActor
protocol BarShrinks: NSView {
    var leastWidth: CGFloat { get }
}

@MainActor
final class ShellLowerLayer: ShellLayer {
    let browser: Browser
    var immersed = false { didSet { if immersed != oldValue { needsLayout = true } } }
    var paneSpot: (() -> CGRect?)?
    var agentCard: (() -> CGRect?)?
    var barsBottom: CGFloat { stack.bottom }

    func barPane(paned: Bool) -> CGRect? {
        paned ? paneSpot?() : nil
    }

    private let stack = BarStack()
    private let book = NoticeBook()
    private let announcement: AnnouncementView
    private let newTabs: NewTabsNoticeView
    private var capture: CaptureQuestionView?
    private var screen: ScreenQuestionView?
    private var offer: PasswordOfferView?
    private var siteFile: SiteFileQuestionView?
    private var store: (id: String, view: StoreOfferView)?
    private var fillCard: FormFillCard?
    private var fillDone: FormFillBar?
    private var fillOffer: FormFillBar?
    private var shield: ShieldOfferView?
    private var developer: (key: String, view: OfferBarView)?
    private var linkBar: (id: UUID, view: OfferBarView)?
    private var veil: CapsuleNote?
    private var acting: AgentActingBadgeView?
    private var driving: AgentDrivingBarView?
    private var link: LinkBubbleView?

    init(browser: Browser) {
        self.browser = browser
        announcement = AnnouncementView(browser: browser)
        newTabs = NewTabsNoticeView(browser: browser)
        super.init(frame: .zero)
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func kept<View: NSView>(_ view: inout View?, _ on: Bool, _ make: () -> View) -> View? {
        guard on else {
            view = nil
            return nil
        }
        let made = view ?? make()
        view = made
        return made
    }

    override func layout() {
        super.layout()
        stack.frame = bounds
        stack.bottom = agentCard?().map { max(30, bounds.height - $0.minY + stack.spacing) } ?? 30
        stack.page = paneSpot?()
        var bars: [BarStack.Bar] = []
        book.begin()
        announcement.sync()
        if !browser.fieldShowing, announcement.shown {
            bars.append(.init(view: announcement.note, kind: browser.announcedKind ?? .note, clock: browser.hush))
        }
        newTabs.sync()
        if !browser.fieldShowing, newTabs.shown != nil {
            bars.append(.init(view: newTabs.note, kind: .note, clock: browser.newTabsHush))
        }
        if let notice = browser.linkNotice, !browser.fieldShowing {
            if linkBar?.id != notice.id {
                let made = OfferBarView(notice.text, choices: notice.choices)
                made.identifier = NSUserInterfaceItemIdentifier("link.notice")
                linkBar = (notice.id, made)
            }
            if let view = linkBar?.view { bars.append(.init(view: view, kind: notice.kind, clock: browser.linkNoticeHush)) }
        } else {
            linkBar = nil
        }
        let ask = browser.asking
        if let ask, ask.screen {
            let view = kept(&screen, true) { ScreenQuestionView(browser: browser, ask: ask) }
            view?.ask = ask
            capture = nil
            if let view { bars.append(.init(view: view, kind: .question)) }
        } else if let ask {
            let view = kept(&capture, true) { CaptureQuestionView(browser: browser, ask: ask) }
            view?.ask = ask
            screen = nil
            if let view { bars.append(.init(view: view, kind: .question)) }
        } else {
            capture = nil
            screen = nil
        }
        if let card = SiteFileAsk.shared.card(for: browser.active?.id) {
            let view = kept(&siteFile, true) { SiteFileQuestionView(browser: browser, card: card) }
            view?.card = card
            if let view { bars.append(.init(view: view, kind: .question)) }
        } else {
            siteFile = nil
        }
        if let asked = browser.offering {
            let view = kept(&offer, true) { PasswordOfferView(browser: browser, offer: asked) }
            view?.offer = asked
            if let view { bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.password(book, browser, asked, view))) }
        } else {
            offer = nil
        }
        let extensions = Extensions.shared
        if let id = StoreOfferRules.offered(browser.active, extensions) {
            if store?.id != id {
                store = (id, StoreOfferView(busy: extensions.busy == id))
            }
            if let view = store?.view {
                view.busy = extensions.busy == id
                view.onAdd = { extensions.install(from: id) }
                bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.store(book, browser, id, view)))
            }
        } else {
            store = nil
        }
        let forms = browser.forms
        let tab = browser.active?.id
        if let up = forms.preview, up.tab == tab {
            let book = AutofillBook.shared
            let view = kept(&fillCard, true) { FormFillCard(forms: forms) }
            view?.show(up, addresses: book.addresses.map { ($0.id, $0.note) }, cards: book.cards.map { ($0.id, $0.title) })
            if let view { bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.fill(self.book, browser, up, view))) }
        } else {
            fillCard = nil
        }
        if let up = forms.done, up.tab == tab {
            let view = kept(&fillDone, true) { FormFillBar(forms: forms) }
            view?.kind = .done(up)
            if let view { bars.append(.init(view: view, kind: .action, clock: NoticeOffers.filled(book, browser, up, view))) }
        } else {
            fillDone = nil
        }
        if let up = forms.offer, up.tab == tab {
            let view = kept(&fillOffer, true) { FormFillBar(forms: forms) }
            view?.kind = .offer(up)
            if let view { bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.save(book, browser, up, view))) }
        } else {
            fillOffer = nil
        }
        if let host = Shield.shared.offer, host == browser.hereHost {
            let view = kept(&shield, true) { ShieldOfferView(browser: browser, shield: .shared, host: host) }
            view?.host = host
            if let view { bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.shield(book, browser, host, view))) }
        } else {
            shield = nil
        }
        let developing = Developer.shared
        if let key = developing.offer, key == LocalServer.key(browser.active?.pageAddress), browser.active?.agent != true {
            let notNow = {
                developing.offer = nil
                developing.set(key, false)
            }
            if developer?.key != key {
                let browser = browser
                developer = (key, DeveloperOfferView.make(key: key, turnOn: { browser.setDeveloperMode(true, key: key) }, notNow: notNow))
            }
            if let view = developer?.view {
                bars.append(.init(view: view, kind: .offer, clock: NoticeOffers.developer(book, browser, key, view, notNow: notNow),
                                  pane: barPane(paned: browser.prefs.splitView && browser.activeSplit != nil)))
            }
        } else {
            developer = nil
        }
        if browser.veiling {
            if let view = kept(&veil, true, { CapsuleNote("Click anything to hide it   ⌘Z undo   esc done", size: 11.5) }) {
                bars.append(.init(view: view, kind: .question))
            }
        } else {
            veil = nil
        }
        let agentPane = barPane(paned: browser.prefs.splitView && browser.activeSplit != nil)
        if let tab = browser.active, let doing = tab.agentActing, !tab.driving {
            let view = kept(&acting, true) { AgentActingBadgeView(doing: doing) }
            view?.doing = doing
            if let view { bars.append(.init(view: view, kind: .progress, pane: agentPane)) }
        } else {
            acting = nil
        }
        if browser.active?.driving == true {
            let view = kept(&driving, true) { AgentDrivingBarView { [weak browser] in _ = browser?.handBack() } }
            if let view { bars.append(.init(view: view, kind: .question, pane: agentPane)) }
        } else {
            driving = nil
        }
        book.end()
        stack.show(bars)
        if browser.prefs.showsLinks, !immersed {
            let view = link ?? {
                let made = LinkBubbleView(status: browser.linkStatus)
                addSubview(made)
                link = made
                return made
            }()
            view.frame = bounds
        } else if let link {
            link.removeFromSuperview()
            self.link = nil
        }
    }
}

@MainActor
final class ShellUpperLayer: ShellLayer {
    let browser: Browser
    private let stack = BarStack()
    private let announcement: AnnouncementView
    private let newTabs: NewTabsNoticeView
    private let downloads: DownloadsLayerView
    private let plus: PlusLayerView
    private var catcher: ClickAway?
    private var veils: HiddenPanelView?

    init(browser: Browser) {
        self.browser = browser
        announcement = AnnouncementView(browser: browser)
        newTabs = NewTabsNoticeView(browser: browser)
        downloads = DownloadsLayerView(browser: browser)
        plus = PlusLayerView(browser: browser)
        super.init(frame: .zero)
        addSubview(stack)
        addSubview(downloads)
        addSubview(plus)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let point = convert(point, from: superview)
        if let hit = veils?.hitTest(point) { return hit }
        if let hit = catcher?.hitTest(point) { return hit }
        if browser.plusOpen, let hit = plus.hitTest(point) { return hit }
        if let hit = downloads.hitTest(point) { return hit }
        return stack.hitTest(point)
    }

    override func layout() {
        super.layout()
        stack.frame = bounds
        announcement.sync()
        newTabs.sync()
        var bars: [BarStack.Bar] = []
        if browser.fieldShowing, announcement.shown {
            bars.append(.init(view: announcement.note, kind: browser.announcedKind ?? .note, clock: browser.hush))
        }
        if browser.fieldShowing, newTabs.shown != nil {
            bars.append(.init(view: newTabs.note, kind: .note, clock: browser.newTabsHush))
        }
        stack.show(bars)
        downloads.frame = bounds
        downloads.sync()
        plus.frame = bounds
        if browser.reviewing {
            let click = catcher ?? {
                let made = ClickAway { [weak browser] in browser?.reviewing = false }
                addSubview(made)
                catcher = made
                made.kitFade(false, curve: .none)
                made.kitFade(true, curve: Motion.kitSettle)
                return made
            }()
            click.frame = bounds
            let fresh = veils == nil
            let panel = veils ?? {
                let made = HiddenPanelView(browser: browser)
                made.wantsLayer = true
                addSubview(made)
                veils = made
                return made
            }()
            let size = CGSize(width: HiddenPanelView.width, height: HiddenPanelView.height(for: browser))
            panel.frame = CGRect(x: bounds.width - 14 - size.width, y: Metrics.strip + 8, width: size.width, height: size.height)
            if fresh {
                panel.kitArrive(false, Self.unfold, animated: false)
                panel.kitArrive(true, Self.unfold)
            }
        } else {
            if let going = catcher {
                catcher = nil
                going.kitFade(false, curve: Motion.kitSettle) { going.removeFromSuperview() }
            }
            if let going = veils {
                veils = nil
                going.kitArrive(false, Self.unfold)
                DispatchQueue.main.asyncAfter(deadline: .now() + BarStack.leaveTime) { going.removeFromSuperview() }
            }
        }
    }

    static let unfold = KitArrival.unfold(from: KitArrival.topTrailing)
}

@MainActor
final class ClickAway: NSView {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
}

@MainActor
final class ShellTopLayer: ShellLayer {
    let browser: Browser
    private let hover: HoverLayerView
    private var picker: IconPickerView?
    private var progress: ImportProgressView?
    private var newSpace: NewSpaceLayerView?
    private let delight: DelightView

    init(browser: Browser) {
        self.browser = browser
        hover = HoverLayerView(cards: browser.hoverCards, browser: browser)
        delight = DelightView(browser: browser)
        super.init(frame: .zero)
        addSubview(hover)
        addSubview(delight)
        delight.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let point = convert(point, from: superview)
        if let hit = progress?.hitTest(point) { return hit }
        if let hit = picker?.hitTest(point) { return hit }
        if case .folder = browser.hoverCards.kind, let hit = hover.hitTest(point) { return hit }
        return newSpace?.hitTest(point)
    }

    override func layout() {
        super.layout()
        let room = safeAreaRect
        hover.frame = room
        if let draft = browser.spaceAsk.draft {
            if newSpace?.draft !== draft {
                newSpace?.removeFromSuperview()
                let made = NewSpaceLayerView(browser: browser, draft: draft)
                addSubview(made, positioned: .below, relativeTo: hover)
                newSpace = made
            }
            newSpace?.frame = bounds
        } else if let going = newSpace {
            newSpace = nil
            going.leave(created: browser.spaceAsk.created) { going.removeFromSuperview() }
        }
        if browser.iconPicker.target != nil {
            let view = picker ?? {
                let made = IconPickerView(browser: browser)
                addSubview(made, positioned: .above, relativeTo: hover)
                picker = made
                return made
            }()
            view.frame = room
        } else if let picker {
            picker.removeFromSuperview()
            self.picker = nil
        }
        if let job = browser.fileImport {
            let view = progress ?? {
                let made = ImportProgressView(browser: browser)
                addSubview(made, positioned: .below, relativeTo: delight)
                progress = made
                return made
            }()
            view.job = job
            let size = view.intrinsicContentSize
            view.frame = CGRect(x: room.maxX - 20 - size.width, y: room.minY + 20, width: size.width, height: size.height)
        } else if let progress {
            progress.removeFromSuperview()
            self.progress = nil
        }
        delight.frame = room
    }
}

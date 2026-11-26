import AppKit
import Combine

@MainActor
final class SplitStageView: NSView {
    struct Spot: Equatable {
        let tab: Tab
        let rect: CGRect
        let onPage: Bool

        static func == (a: Spot, b: Spot) -> Bool { a.tab === b.tab && a.rect == b.rect && a.onPage == b.onPage }
    }

    let browser: Browser
    var onLoadSpot: ((Spot?) -> Void)?
    var onApart: ((Bool) -> Void)?
    private(set) var corner: CGFloat = 0
    private var sliding = false
    private(set) var immersed: Tab.ID?
    private var find: FindState
    private var hold: CGSize?
    private var card: CardClip?

    private let stage = PaneStage()
    private let grips = SplitPassLayer()
    private let panes = SplitPassLayer()
    private let drops = SplitPassLayer()
    private var frames: [Tab.ID: CGRect] = [:]
    private var hovered: Tab.ID?
    private var shuffle: PaneShuffle?
    private var shown: [Tab] = []
    private var placed: [Tab.ID: Pane] = [:]
    private var dropPane: DropPaneView?
    private var carriedCard: CarriedCardView?
    private var spot: Spot?
    private var watch: AnyCancellable?
    private var dragWatch: AnyCancellable?
    private var rideWatch: AnyCancellable?
    private var queued = false
    private var plan: Plan?
    private var provisional: (preview: TabDrag.Preview, split: TabSplit)?
    private var rest: [Tab.ID: CGRect] = [:]

    struct Plan {
        let tabs: [Tab]
        let split: TabSplit?
        let focused: Tab.ID
        let standIn: Tab?
        let source: Tab
        let target: Tab
        let side: TabDrag.Side
    }

    @MainActor
    private final class Pane {
        let tab: Tab
        let group = SplitPaneGroup()
        let layers: PaneLayersView
        let grip = PaneGrip.Grip()
        var bar: PaneBarView?
        var transform = CATransform3DIdentity
        var dim: (layers: Swift.Float, bar: Swift.Float) = (1, 1)

        init(tab: Tab, browser: Browser) {
            self.tab = tab
            layers = PaneLayersView(browser: browser, tab: tab)
            group.addSubview(layers)
            group.wantsLayer = true
        }
    }

    init(browser: Browser) {
        self.browser = browser
        find = browser.findState
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(stage)
        addSubview(grips)
        addSubview(panes)
        addSubview(stage.rims)
        addSubview(drops)
        stage.onCommit = { [weak self] id, sizes in self?.browser.setSplitFraction(id, fraction: sizes[0]) }
        stage.onFocus = { [weak self] tab in self?.browser.focusPane(tab) }
        stage.onFrames = { [weak self] frames in
            guard let self else { return }
            self.frames = frames
            if plan == nil, Set(frames.keys) == Set(shown.map(\.id)) { rest = frames }
            place(animated: true)
        }
        stage.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .swap: browser.swapSplit()
            case .even: browser.evenSplit()
            case .separate: if let tab = browser.active { browser.detachSplit(tab) }
            case .closeBoth: browser.closeSplit()
            }
        }
        stage.onHover = { [weak self] id in
            guard let self, hovered != id else { return }
            hovered = id
            place(animated: true)
        }
        dragWatch = kitObserve(initial: false, { (TabDrag.shared.preview, TabDrag.shared.cancelledID, TabDrag.shared.carried) }) { [weak self] _ in
            self?.later()
        }
        rideWatch = kitObserve(initial: true, { [weak browser] in browser?.spaceNeighbour.revision }) { [weak self] _ in
            self?.slide()
        }
        stage.onApart = { [weak self] apart in self?.onApart?(apart) }
        rewatchFind()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func update(find: FindState, corner: CGFloat, immersed: Tab.ID?, hold: CGSize?, card: CardClip?) {
        if find !== self.find {
            self.find = find
            rewatchFind()
        }
        self.corner = corner
        self.immersed = immersed
        self.hold = hold
        self.card = card
        refresh()
    }

    func slide() {
        let next = browser.stageSliding
        guard next != sliding else { return }
        sliding = next
        stage.sliding = next
        place(animated: false)
    }

    func returnBorrowedPages() {
        stage.returnBorrowedPages()
        for pane in placed.values {
            pane.layers.returnBorrowedPages()
            pane.layers.discard()
        }
    }

    private func rewatchFind() {
        watch = kitObserve(initial: false, { [weak self] in self?.heard() }) { [weak self] _ in self?.refresh() }
    }

    private func heard() {
        _ = (browser.activeSplit, browser.tabs.map(\.id), browser.activeID, browser.stageVeiled, browser.spaceID, browser.space.look,
             find.on, browser.suggesting != nil, browser.applePairing != nil, browser.paneQuestions.map(\.id), browser.folded)
    }

    private func later() {
        guard !queued else { return }
        queued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            queued = false
            refresh()
        }
    }

    override func layout() {
        super.layout()
        for view in [stage, grips, panes, stage.rims, drops] as [NSView] where view.frame != bounds { view.frame = bounds }
    }

    private func refresh() {
        let split = browser.activeSplit
        let now: [Tab] = split.map { pair in pair.tabs.compactMap { id in browser.tabs.first { $0.id == id } } }
            ?? browser.active.map { [$0] } ?? []
        let ids = now.map(\.id)
        if ids != shown.map(\.id), let shuffle, shuffle.order != ids, shuffle.result != ids { self.shuffle = nil }
        shown = now
        plan = makePlan(now, split: split)
        let veiled = browser.stageVeiled
        stage.spaceID = browser.spaceID
        stage.groundDark = (browser.space.look ?? SpaceLook()).inkLight(dark: false)
        stage.look = browser.pageLook(in: nil)
        stage.borrowing = false
        stage.corner = corner
        stage.immersedID = immersed
        stage.veiled = veiled
        stage.lift(lift)
        if let plan {
            stage.show(plan.tabs, split: plan.split, focused: plan.focused, standIn: plan.standIn?.id)
        } else {
            stage.show(now, split: split, focused: browser.activeID)
        }
        stage.hold(growing: hold)
        stage.card = card
        stage.showFind(find.on && !veiled ? browser : nil)
        stage.showAccounts(veiled ? nil : browser.suggesting.map { (browser, $0) })
        stage.showPairing(veiled ? nil : browser.applePairing.map { (browser, $0) })
        place(animated: true)
    }

    private var lift: PaneLift? {
        shuffle.map { shuffle in
            PaneLift(carried: shuffle.carried,
                     shifts: Dictionary(uniqueKeysWithValues: shuffle.order.map { ($0, shuffle.shift(of: $0)) }),
                     lifted: !shuffle.settled)
        }
    }

    var shownFrames: [Tab.ID: CGRect] { frames }
    var landingPane: DropPaneView? { dropPane }
    func zoneFrame(of id: Tab.ID) -> CGRect? { placed[id]?.layers.zoneFrame }
    func paneCorners(of id: Tab.ID) -> PaneLayersView.Corners? { placed[id]?.layers.shownCorners }

    private var members: [Tab.ID] { plan?.tabs.map(\.id) ?? shown.map(\.id) }

    private var bars: Bool {
        let members = members
        return members.count == 2 && immersed == nil && members.allSatisfy { frames[$0] != nil }
    }

    private var preview: TabDrag.Preview? {
        guard let preview = TabDrag.shared.preview, preview.browserID == ObjectIdentifier(browser) else { return nil }
        return preview
    }

    private func makePlan(_ real: [Tab], split: TabSplit?) -> Plan? {
        guard let preview, let source = browser.tabs.first(where: { $0.id == preview.sourceID }),
              let target = real.first(where: { $0.id == preview.targetID }), source !== target else {
            provisional = nil
            return nil
        }
        switch preview.side {
        case .centre:
            provisional = nil
            return Plan(tabs: real, split: split, focused: source.id, standIn: nil, source: source, target: target, side: .centre)
        case .left, .right:
            let within = real.count == 2 && real.contains { $0 === source }
            guard real.count == 1 || within else {
                provisional = nil
                return nil
            }
            let onLeft = preview.side == .left
            let made = provisional.flatMap { $0.preview == preview ? $0.split : nil }
                ?? Browser.pairing(source.id, with: target.id, onLeft: onLeft)
            provisional = (preview, made)
            return Plan(tabs: onLeft ? [source, target] : [target, source], split: made, focused: source.id,
                        standIn: within ? nil : source, source: source, target: target, side: preview.side)
        }
    }

    private func place(animated: Bool) {
        let bars = self.bars
        let bar = bars ? Metrics.paneBar : 0
        let paired = members.count > 1
        let focused = plan?.focused ?? browser.activeID
        let all = Array(frames.values)
        for (id, pane) in placed where frames[id] == nil || !shown.contains(where: { $0 === pane.tab }) {
            pane.group.removeFromSuperview()
            pane.grip.removeFromSuperview()
            pane.layers.discard()
            placed[id] = nil
        }
        for tab in shown {
            guard let frame = frames[tab.id] else { continue }
            let pane = placed[tab.id] ?? made(tab)
            let carried = shuffle?.carried == tab.id
            let lifted = carried && shuffle?.settled == false
            let dimmed = shuffle.map { !$0.settled && !carried } ?? false
            let shift = shuffle?.shift(of: tab.id) ?? 0
            if bars {
                let made = pane.bar ?? {
                    let view = PaneBarView(browser: browser, tab: tab)
                    pane.group.addSubview(view)
                    pane.bar = view
                    return view
                }()
                made.show(tab: tab, focused: focused == tab.id, carrying: carried, corner: corner, look: browser.pageLook(in: nil))
                made.frame = NSRect(x: 0, y: 0, width: frame.width, height: bar)
                if pane.grip.superview == nil { grips.addSubview(pane.grip) }
                pane.grip.frame = NSRect(x: frame.minX, y: frame.minY - bar, width: frame.width, height: bar)
            } else {
                pane.bar?.removeFromSuperview()
                pane.bar = nil
                pane.grip.removeFromSuperview()
            }
            pane.group.frame = NSRect(x: frame.minX, y: frame.minY - bar, width: frame.width, height: frame.height + bar)
            pane.layers.frame = NSRect(x: 0, y: bar, width: frame.width, height: frame.height)
            pane.layers.show(paired: paired, hovered: hovered == tab.id, corners: corners(of: frame, among: all), width: frame.width)
            pane.layers.hold(zone: plan == nil ? nil : rest[tab.id].map { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) })
            pane.group.layer?.zPosition = carried ? 2 : 0
            let curve: KitCurve = animated && !lifted ? Motion.kitGlide : .none
            let transform = liftTransform(pane.group, scale: lifted ? PaneShuffle.lift : 1, shift: shift)
            if !CATransform3DEqualToTransform(transform, pane.transform) {
                pane.transform = transform
                pane.group.layer?.kitAnimate("transform", to: NSValue(caTransform3D: transform), curve: curve, key: "lift")
            }
            let dim: (layers: Swift.Float, bar: Swift.Float) = dimmed ? (0.78, 0.55) : (1, 1)
            if dim != pane.dim {
                pane.dim = dim
                pane.layers.layer?.kitAnimate("opacity", to: dim.layers, curve: curve, key: "dim")
                pane.bar?.layer?.kitAnimate("opacity", to: dim.bar, curve: curve, key: "dim")
            }
        }
        placeDrops(animated: animated)
        tellSpot(bar: bar)
    }

    private func made(_ tab: Tab) -> Pane {
        let pane = Pane(tab: tab, browser: browser)
        panes.addSubview(pane.group)
        pane.grip.focus = { [weak self, weak tab] in
            guard let self, let tab else { return }
            browser.focusPane(tab)
        }
        pane.grip.step = { [weak self, weak tab] step in
            guard let self, let tab else { return }
            carry(tab, step)
        }
        placed[tab.id] = pane
        return pane
    }

    private func liftTransform(_ view: NSView, scale: CGFloat, shift: CGFloat) -> CATransform3D {
        guard let layer = view.layer else { return CATransform3DIdentity }
        let bounds = layer.bounds
        let anchor = CGPoint(x: layer.anchorPoint.x * bounds.width, y: layer.anchorPoint.y * bounds.height)
        let fix = CGPoint(x: (bounds.midX - anchor.x) * (1 - scale), y: (bounds.midY - anchor.y) * (1 - scale))
        if scale == 1 && shift == 0 { return CATransform3DIdentity }
        return CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(fix.x + shift, fix.y, 0))
    }

    private func corners(of frame: CGRect, among frames: [CGRect]) -> PaneLayersView.Corners {
        guard frames.count > 1, bars else { return .init(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0) }
        let outer = sliding ? PaneStage.outer(frame, in: bounds) : (left: false, right: false)
        return .init(topLeft: 0, topRight: 0, bottomLeft: outer.left ? 0 : corner, bottomRight: outer.right ? 0 : corner)
    }

    private func placeDrops(animated: Bool) {
        placeLanding(animated: animated)
        if let carried = TabDrag.shared.carried, let tab = browser.tabs.first(where: { $0.id == carried.id }), let window {
            let card = carriedCard ?? {
                let made = CarriedCardView()
                drops.addSubview(made)
                carriedCard = made
                return made
            }()
            card.show(tab)
            let point = convert(NSPoint(x: carried.point.x, y: window.frame.height - carried.point.y), from: nil)
            card.setFrameOrigin(NSPoint(x: point.x + 12, y: point.y + 10))
        } else if let carriedCard {
            carriedCard.removeFromSuperview()
            self.carriedCard = nil
        }
    }

    private func landingMode(_ plan: Plan) -> DropPaneView.Mode {
        switch plan.side {
        case .centre: .fade
        case .left, .right: plan.standIn == nil ? .ring : .slide(plan.side)
        }
    }

    private func column(_ frame: CGRect, bar: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY - bar, width: frame.width, height: frame.height + bar)
    }

    private func offset(for view: DropPaneView) -> CGFloat {
        guard case .slide(let side) = view.mode else { return 0 }
        return side == .left ? -PaneStage.gutter - view.frame.maxX : bounds.maxX + PaneStage.gutter - view.frame.minX
    }

    private func placeLanding(animated: Bool) {
        let bar = bars ? Metrics.paneBar : 0
        if let plan {
            let mode = landingMode(plan)
            let landing = plan.side == .centre ? plan.target.id : plan.source.id
            if let dropPane, dropPane.tab !== plan.source || dropPane.mode != mode { dismiss(dropPane, landed: false) }
            guard Set(frames.keys).isSubset(of: plan.tabs.map(\.id)), let frame = frames[landing] else { return }
            let fresh = dropPane == nil
            let view = dropPane ?? {
                let made = DropPaneView(browser: browser, tab: plan.source, mode: mode)
                drops.addSubview(made, positioned: .below, relativeTo: carriedCard)
                dropPane = made
                return made
            }()
            view.frame = column(frame, bar: bar)
            view.show(bar: bar, corner: corner, corners: corners(of: frame, among: Array(frames.values)))
            if fresh { view.arrive(from: animated ? offset(for: view) : 0) }
        } else if let dropPane {
            dismiss(dropPane, landed: shown.contains { $0 === dropPane.tab })
        }
    }

    private func dismiss(_ view: DropPaneView, landed: Bool) {
        if dropPane === view { dropPane = nil }
        let done: () -> Void = { [weak view] in view?.removeFromSuperview() }
        if landed { view.land(done: done) } else { view.leave(to: offset(for: view), done: done) }
    }

    private func tellSpot(bar: CGFloat) {
        var next: Spot?
        if let tab = browser.active, let frame = frames[tab.id] {
            next = Spot(tab: tab, rect: CGRect(x: frame.minX, y: frame.minY - bar, width: frame.width, height: frame.height + bar),
                        onPage: bar == 0)
        }
        guard next != spot else { return }
        spot = next
        DispatchQueue.main.async { [weak self] in self?.onLoadSpot?(next) }
    }

    private func carry(_ tab: Tab, _ step: PaneGrip.Step) {
        switch step {
        case .began:
            guard shuffle == nil, bars else { return }
            shuffle = PaneShuffle(carried: tab.id, order: shown.map(\.id), frames: frames, gap: PaneStage.gutter)
        case .moved(let dx):
            guard var next = shuffle, next.carried == tab.id, !next.settled else { return }
            next.move(by: dx)
            guard next != shuffle else { return }
            shuffle = next
        case .ended, .cancelled:
            guard var next = shuffle, next.carried == tab.id, !next.settled else { return }
            if step == .cancelled { next.cancel() } else { next.drop() }
            shuffle = next
            land(next)
        }
        stage.lift(lift)
        place(animated: true)
    }

    private func land(_ done: PaneShuffle) {
        let wait: TimeInterval = Motion.reduced ? 0 : Motion.light ? 0.17 : 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, shuffle == done else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if done.moved, let split = browser.activeSplit, split.tabs == done.order {
                frames.merge(done.targets) { $1 }
                browser.reorderSplit(split.id, moving: done.carried, to: done.landing)
            }
            shuffle = nil
            stage.lift(nil)
            place(animated: false)
            CATransaction.commit()
        }
    }
}

private final class SplitPassLayer: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class SplitPaneGroup: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor
final class PaneLayersView: NSView {
    struct Corners: Equatable {
        var topLeft: CGFloat
        var topRight: CGFloat
        var bottomLeft: CGFloat
        var bottomRight: CGFloat
    }

    let browser: Browser
    let tab: Tab
    private let page: TabPageView
    private let zone = SplitDropMarker()
    private let whose = PaneWhose()
    private let clip = CAShapeLayer()
    private var question: PaneQuestionCardView?
    private var committed: URL?
    private var paired = false
    private var hovered = false
    private var corners = Corners(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0)
    private var width: CGFloat = 0
    private var watch: AnyCancellable?
    private var heldZone: CGRect?

    init(browser: Browser, tab: Tab) {
        self.browser = browser
        self.tab = tab
        page = TabPageView(tab: tab, browser: browser)
        committed = tab.committed
        super.init(frame: .zero)
        wantsLayer = true
        clip.fillColor = NSColor.black.cgColor
        clip.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.mask = clip
        zone.browser = browser
        zone.tab = tab
        zone.kind = .stage
        TabDrag.shared.register(zone)
        addSubview(zone)
        addSubview(page)
        addSubview(whose)
        page.update(.init(holdsPage: false), tab: tab, browser: browser)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "Focus Page") { [weak self] in
            guard let self else { return false }
            if paired { browser.focusPane(tab) }
            return true
        }])
        watch = kitObserve(initial: false, { [weak tab] in tab.map { ($0.committed, $0.address, $0.label, $0.isBlank) } }) { [weak self] _ in
            guard let self else { return }
            if tab.committed != committed {
                committed = tab.committed
                browser.dropQuestions(for: tab.id)
            }
            refresh(animated: true)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func discard() {
        TabDrag.shared.unregister(zone)
        watch = nil
    }

    func returnBorrowedPages() {
        page.returnBorrowedPages()
    }

    func hold(zone rect: CGRect?) {
        guard rect != heldZone else { return }
        heldZone = rect
        needsLayout = true
    }

    var zoneFrame: CGRect { zone.frame }
    var shownCorners: Corners { corners }

    func show(paired: Bool, hovered: Bool, corners: Corners, width: CGFloat) {
        self.paired = paired
        self.hovered = hovered
        self.width = width
        if corners != self.corners {
            self.corners = corners
            needsLayout = true
        }
        refresh(animated: true)
    }

    private var focused: Bool { browser.activeID == tab.id }

    private func refresh(animated: Bool) {
        let asked = browser.paneQuestions.first { $0.tab == tab.id }
        if asked?.id != question?.question.id {
            question?.removeFromSuperview()
            question = asked.map { asked in
                let card = PaneQuestionCardView(browser: browser, tab: tab, question: asked)
                addSubview(card, positioned: .below, relativeTo: whose)
                card.frame = bounds
                return card
            }
        }
        question?.width = width
        var host: String?
        if paired, !focused, hovered || browser.folded, let name = tab.address?.host(), !tab.isBlank {
            host = name.hasPrefix("www.") ? String(name.dropFirst(4)) : name
        }
        whose.show(host, animated: animated)
        setAccessibilityLabel(tab.label.isEmpty ? "New Tab" : tab.label)
        setAccessibilityHelp(paired && !focused ? "Click to focus this page" : "")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        zone.frame = heldZone ?? bounds
        page.frame = bounds
        question?.frame = bounds
        let size = whose.fitting
        whose.frame = kitSnap(NSRect(x: bounds.width - 10 - size.width, y: 10, width: size.width, height: size.height))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        clip.path = KitPath.continuous(bounds, topLeft: corners.topLeft, topRight: corners.topRight,
                                       bottomLeft: corners.bottomLeft, bottomRight: corners.bottomRight)
        CATransaction.commit()
    }
}

private final class PaneWhose: NSView {
    private let capsule = KitBox(fill: KitColor.ground, stroke: KitColor.hairline, corners: .capsule)
    private let label = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private var shown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        addSubview(capsule)
        addSubview(label)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var fitting: NSSize { NSSize(width: ceil(label.intrinsicContentSize.width) + 20, height: 22) }

    func show(_ host: String?, animated: Bool) {
        if let host, label.text != host {
            label.text = host
            needsLayout = true
            superview?.needsLayout = true
        }
        let now = host != nil
        guard now != shown else { return }
        shown = now
        layer?.kitAnimate("opacity", to: Swift.Float(now ? 1 : 0), curve: animated ? Motion.kitQuick : .none, key: "shown")
    }

    override func layout() {
        super.layout()
        capsule.frame = bounds
        let height = label.intrinsicContentSize.height
        label.frame = kitSnap(NSRect(x: 10, y: (bounds.height - height) / 2, width: max(0, bounds.width - 20), height: height))
    }
}

@MainActor
private final class PaneQuestionCardView: NSView {
    let browser: Browser
    let tab: Tab
    let question: PaneQuestion
    var width: CGFloat = 0 { didSet { if width != oldValue { needsLayout = true } } }

    private let dim = KitBox(fill: Palette.NS.ground.withAlphaComponent(0.62))
    private let card = PaneQuestionCard()
    private let glass = KitGlass(radius: 14, tint: Palette.NS.glassTint)
    private let heading: KitLabel
    private let scroll = NSScrollView()
    private let words = NSTextView()
    private let field: PaneQuestionField?
    private let cancel: KitButton?
    private let ok: KitButton
    private var ready = false

    private var prompting: Bool { if case .prompt = question.kind { return true } else { return false } }

    init(browser: Browser, tab: Tab, question: PaneQuestion) {
        self.browser = browser
        self.tab = tab
        self.question = question
        heading = KitLabel(question.host.isEmpty ? "This page says" : question.host,
                           font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ink)
        heading.overflow = .middle
        if case .prompt(let given) = question.kind { field = PaneQuestionField(text: given) } else { field = nil }
        cancel = question.kind == .alert ? nil : Self.choice("Cancel", strong: false)
        ok = Self.choice("OK", strong: true)
        super.init(frame: .zero)
        wantsLayer = true
        dim.passesClicks = false
        addSubview(dim)
        addSubview(card)
        card.addSubview(glass)
        card.addSubview(heading)
        words.string = question.message
        words.font = .systemFont(ofSize: 13)
        words.textColor = Palette.NS.ink
        words.isEditable = false
        words.isSelectable = true
        words.drawsBackground = false
        words.textContainerInset = .zero
        words.textContainer?.lineFragmentPadding = 0
        words.isVerticallyResizable = true
        words.isHorizontallyResizable = false
        words.textContainer?.widthTracksTextView = true
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = words
        card.addSubview(scroll)
        if let field {
            field.touched = { [weak self] in
                guard let self else { return }
                browser.focusPane(tab)
            }
            field.submit = { [weak self] in
                guard let self, ready else { return }
                answer(true)
            }
            card.addSubview(field)
        }
        if let cancel {
            cancel.action = { [weak self] in self?.answer(false) }
            card.addSubview(cancel)
        }
        ok.action = { [weak self] in self?.answer(true) }
        card.addSubview(ok)
        card.touched = { [weak self] in
            guard let self else { return }
            browser.focusPane(tab)
        }
        setEnabled(false)
        let wait = max(0, 0.5 - Date().timeIntervalSince(question.asked))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self else { return }
            ready = true
            setEnabled(true)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(question.host.isEmpty ? "This page" : question.host) asks")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        browser.focusPane(tab)
    }

    private static func choice(_ title: String, strong: Bool) -> KitButton {
        let button = KitButton(title: title, font: .systemFont(ofSize: 13, weight: strong ? .semibold : .regular),
                               look: .keycap(strong ? .primary : .secondary))
        button.padding = 12
        button.height = 28
        button.kitAccess(label: title, role: .button)
        return button
    }

    private func setEnabled(_ on: Bool) {
        cancel?.isEnabled = on
        ok.isEnabled = on
    }

    private func answer(_ yes: Bool) {
        browser.focusPane(tab)
        browser.answer(question, ok: yes, text: prompting ? field?.text : nil)
    }

    private static func buttonWidth(_ button: KitButton) -> CGFloat {
        max(64, ceil(button.intrinsicContentSize.width))
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
        let cardWidth = min(380, max(0, width - 32))
        let inner = max(0, cardWidth - 28)
        var y: CGFloat = 14
        let headingHeight = heading.intrinsicContentSize.height
        heading.frame = NSRect(x: 14, y: y, width: inner, height: headingHeight)
        y += headingHeight + 10
        let text = NSAttributedString(string: question.message, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let natural = ceil(text.boundingRect(with: NSSize(width: inner, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let wordsHeight = min(200, natural)
        scroll.frame = NSRect(x: 14, y: y, width: inner, height: wordsHeight)
        words.frame = NSRect(x: 0, y: 0, width: inner, height: max(natural, wordsHeight))
        y += wordsHeight + 10
        if let field {
            field.frame = NSRect(x: 14, y: y, width: inner, height: PaneQuestionField.height)
            y += PaneQuestionField.height + 10
        }
        y += 2
        let okWidth = Self.buttonWidth(ok)
        ok.frame = NSRect(x: 14 + inner - okWidth, y: y, width: okWidth, height: 28)
        if let cancel {
            let cancelWidth = Self.buttonWidth(cancel)
            cancel.frame = NSRect(x: ok.frame.minX - 8 - cancelWidth, y: y, width: cancelWidth, height: 28)
        }
        y += 28 + 14
        card.frame = kitSnap(NSRect(x: (bounds.width - cardWidth) / 2, y: 56, width: cardWidth, height: y))
        glass.frame = card.bounds
    }
}

private final class PaneQuestionCard: NSView {
    var touched: (() -> Void)?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        touched?()
    }

}

private final class PaneQuestionField: KitHoverView, NSTextFieldDelegate {
    static let height: CGFloat = 30
    var submit: (() -> Void)?
    var touched: (() -> Void)?
    private let ground = KitBox(fill: nil, corners: .radius(9))
    private let input = NSTextField()
    private var focused = false

    var text: String { input.stringValue }

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        input.stringValue = text
        input.isBordered = false
        input.drawsBackground = false
        input.focusRingType = .none
        input.font = .systemFont(ofSize: 13)
        input.textColor = Palette.NS.ink
        input.cell?.usesSingleLineMode = true
        input.cell?.isScrollable = true
        input.lineBreakMode = .byClipping
        input.delegate = self
        input.target = self
        input.action = #selector(enter)
        addSubview(ground)
        addSubview(input)
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func enter() {
        submit?()
    }

    override func hoverChanged() { paint(animated: true) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint(animated: false)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        focused = true
        paint(animated: true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        focused = false
        paint(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        touched?()
        window?.makeFirstResponder(input)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === input, input.currentEditor() == nil { return self }
        return hit
    }

    private func paint(animated: Bool) {
        let dark = kitDark
        let lit = hovering || focused
        let fill = KitWash.track.color(dark: dark, plus: lit ? 0.03 : 0)
        if animated { ground.layer?.kitTransition(Motion.kitQuick) }
        ground.fill = fill
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let height = ceil(input.intrinsicContentSize.height)
        input.frame = NSRect(x: 10, y: (bounds.height - height) / 2, width: max(0, bounds.width - 20), height: height)
    }
}

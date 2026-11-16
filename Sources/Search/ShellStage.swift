import AppKit

@MainActor
final class ShellStageLayer: ShellLayer {
    let browser: Browser
    var hold: CGSize? { didSet { if hold != oldValue { needsLayout = true } } }

    private let shade = KitFlippedView()
    private let card = KitFlippedView()
    private let mask = CAShapeLayer()
    private let pages: ShellPagesView
    private let space: SpaceStageView
    private let draft: SpaceDraftStageView
    private let ai: AIOverlayView
    private let agentRim = AgentRimView()
    private var band: DeveloperBandView?
    private var panel: DeveloperPanelView?
    private var deviceBar: DeviceBarView?
    private var handles: DeviceHandlesView?

    var paneSpot: CGRect? { pages.spot.map { pages.convert($0, to: self) } }
    var onSpot: (() -> Void)? {
        get { pages.onSpot }
        set { pages.onSpot = newValue; ai.onCard = newValue }
    }
    var agentCard: CGRect? { ai.cardFrame.map { ai.convert($0, to: self) } }

    init(browser: Browser) {
        self.browser = browser
        let corner = browser.asCards ? Metrics.pageRadius : 0
        pages = ShellPagesView(browser: browser)
        space = SpaceStageView(browser: browser, motion: browser.spaceMotion, corner: corner, content: pages)
        draft = SpaceDraftStageView(browser: browser, corner: corner)
        ai = AIOverlayView(browser: browser)
        super.init(frame: .zero)
        wantsLayer = true
        shade.wantsLayer = true
        card.wantsLayer = true
        card.layer?.mask = mask
        addSubview(shade)
        addSubview(card)
        card.addSubview(space)
        card.addSubview(draft)
        card.addSubview(agentRim)
        card.addSubview(ai)
        space.pageReady = { [weak self] in self?.pages.liveReady ?? true }
        pages.onApart = { [weak self] apart in self?.space.paired = apart }
        browser.spaceNeighbour.onTurn = { [weak self] in self?.turned() }
        space.onDress = { [weak self] in self?.pages.slide() }
        space.makePreview = { [weak self] row, id in
            SpaceStagePreviewView(browser: browser, row: row, space: id, corner: self?.space.corner ?? 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func turned() {
        Still.set { space.dress() }
    }

    override func layout() {
        super.layout()
        let cards = browser.asCards
        let corner = cards ? Metrics.pageRadius : 0
        let edged = cards && !browser.prefs.splitView
        dress(edged)
        shade.frame = bounds
        card.frame = bounds
        space.corner = corner
        draft.corner = corner
        pages.corner = corner
        pages.cards = cards
        pages.hold = hold
        var top: CGFloat = 0
        var bottom = bounds.height
        let tab = browser.active
        let developing = tab.map { $0.isWeb && Developer.shared.isOn($0.pageAddress) } ?? false
        if let tab, developing {
            if band?.tab !== tab {
                band?.removeFromSuperview()
                let made = DeveloperBandView(browser: browser, tab: tab, log: tab.devLog)
                made.wantsLayer = true
                card.addSubview(made, positioned: .below, relativeTo: draft)
                band = made
            }
            band?.frame = CGRect(x: 0, y: 0, width: bounds.width, height: DeveloperBandView.height)
            band?.layer?.cornerRadius = corner
            band?.layer?.cornerCurve = .continuous
            band?.layer?.maskedCorners = band?.layer?.contentsAreFlipped() == false
                ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            top = DeveloperBandView.height
        } else if let band {
            band.removeFromSuperview()
            self.band = nil
        }
        if let tab, tab.device != nil {
            if deviceBar?.tab !== tab {
                deviceBar?.removeFromSuperview()
                let made = DeviceBarView(tab: tab)
                card.addSubview(made, positioned: .below, relativeTo: draft)
                deviceBar = made
            }
            deviceBar?.frame = CGRect(x: 0, y: top, width: bounds.width, height: 28)
            top += 28
        } else if let deviceBar {
            deviceBar.removeFromSuperview()
            self.deviceBar = nil
        }
        if let tab, developing, tab.developerPanel {
            if panel?.tab !== tab {
                panel?.removeFromSuperview()
                let made = DeveloperPanelView(tab: tab, log: tab.devLog)
                card.addSubview(made, positioned: .below, relativeTo: draft)
                panel = made
            }
            bottom -= DeveloperPanelView.height
            panel?.frame = CGRect(x: 0, y: bottom, width: bounds.width, height: DeveloperPanelView.height)
        } else if let panel {
            panel.removeFromSuperview()
            self.panel = nil
        }
        let content = CGRect(x: 0, y: top, width: bounds.width, height: max(0, bottom - top))
        if space.frame != content { space.frame = content }
        if let tab, tab.device != nil {
            if handles?.tab !== tab {
                handles?.removeFromSuperview()
                let made = DeviceHandlesView(tab: tab)
                card.addSubview(made, positioned: .above, relativeTo: space)
                handles = made
            }
            handles?.frame = content
        } else if let handles {
            handles.removeFromSuperview()
            self.handles = nil
        }
        draft.frame = bounds
        draft.needsLayout = true
        agentRim.frame = bounds
        agentRim.corner = cards ? corner : 0
        let alone = !browser.prefs.splitView || browser.activeSplit == nil
        agentRim.wear(alone ? browser.active?.agentColour : nil, animated: true)
        ai.frame = bounds
        ai.needsLayout = true
        pages.needsLayout = true
    }

    private func dress(_ edged: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let radius = edged ? Metrics.pageRadius : 0
        let outline = KitPath.continuous(bounds, radius: radius)
        let open = CGMutablePath()
        open.addPath(edged ? outline : CGPath(rect: bounds.insetBy(dx: -10_000, dy: -10_000), transform: nil))
        if edged { open.addRect(CGRect(x: 0, y: -Metrics.cardGap, width: bounds.width, height: Metrics.cardGap)) }
        mask.frame = card.bounds
        mask.path = card.layer?.contentsAreFlipped() == false ? flippedPath(open) : open
        mask.fillColor = NSColor.black.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let layer = card.layer, let shaded = shade.layer else { return }
            layer.backgroundColor = edged ? Palette.NS.ground.cgColor : nil
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
            layer.borderWidth = edged ? PaneEdge.width : 0
            layer.borderColor = PaneEdge.ink(browser.pageLook(in: nil), dark: kitDark).cgColor
            shaded.backgroundColor = edged ? Palette.NS.ground.cgColor : nil
            shaded.cornerRadius = radius
            shaded.cornerCurve = .continuous
            shaded.shadowColor = NSColor.black.cgColor
            shaded.shadowOpacity = edged ? Swift.Float(CardEdge.shadow) : 0
            shaded.shadowRadius = 3
            shaded.shadowOffset = CGSize(width: 0, height: shaded.contentsAreFlipped() ? 1 : -1)
            shaded.shadowPath = edged ? outline : nil
        }
    }

    private func flippedPath(_ path: CGPath) -> CGPath {
        var flip = CGAffineTransform(translationX: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        return path.copy(using: &flip) ?? path
    }
}

@MainActor
final class ShellPagesView: KitFlippedView {
    let browser: Browser
    var corner: CGFloat = 0 { didSet { if corner != oldValue { needsLayout = true } } }
    var cards = false { didSet { if cards != oldValue { needsLayout = true } } }
    var hold: CGSize? { didSet { if hold != oldValue { needsLayout = true } } }
    private(set) var spot: CGRect?
    var onSpot: (() -> Void)?
    var onApart: ((Bool) -> Void)?

    private var split: SplitStageView?
    private var page: TabPageView?
    private var ground: PageGroundView?
    private var find: FindHost?
    private var accounts: AccountHost?
    private var pairing: PairingHost?
    private var splitSpot: SplitStageView.Spot?
    private let pill = LoadPillView()

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        addSubview(pill)
        pill.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === pill ? nil : hit
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func put<View: NSView>(_ view: View) -> View {
        addSubview(view, positioned: .below, relativeTo: pill)
        view.frame = bounds
        return view
    }

    var liveReady: Bool {
        guard let tab = browser.active else { return true }
        if tab.isWeb { return tab.failure != nil || (tab.built != nil && tab.painted) }
        return true
    }

    override func layout() {
        super.layout()
        var shown: (tab: Tab, rect: CGRect, onPage: Bool)?
        if browser.prefs.splitView {
            dropPage()
            dropGround()
            let view = split ?? {
                let made = put(SplitStageView(browser: browser))
                made.onLoadSpot = { [weak self] next in
                    guard let self, splitSpot != next else { return }
                    splitSpot = next
                    needsLayout = true
                }
                made.onApart = { [weak self] apart in self?.onApart?(apart) }
                split = made
                return made
            }()
            if view.frame != bounds { view.frame = bounds }
            view.update(find: browser.findState, corner: corner, immersed: nil, hold: hold, card: nil)
            shown = splitSpot.map { ($0.tab, $0.rect, $0.onPage) }
            placeCards(for: nil)
        } else if let tab = browser.active {
            dropSplit()
            dropGround()
            let view = page ?? {
                let made = put(TabPageView(tab: tab, browser: browser))
                page = made
                return made
            }()
            if view.frame != bounds { view.frame = bounds }
            view.update(.init(holdsPage: true, corner: 0, veiled: browser.stageVeiled, space: nil, borrowing: false,
                              hold: hold, card: nil), tab: tab, browser: browser)
            shown = (tab, bounds, true)
            placeCards(for: tab)
        } else {
            dropSplit()
            dropPage()
            placeCards(for: nil)
            let view = ground ?? {
                let made = put(PageGroundView())
                ground = made
                return made
            }()
            view.show(browser.pageLook(in: nil).page(dark: kitDark))
            view.frame = bounds
        }
        if spot != shown?.rect {
            spot = shown?.rect
            onSpot?()
        }
        placePill(shown)
    }

    func slide() {
        guard let split else { return }
        split.slide()
        split.layoutSubtreeIfNeeded()
    }

    private func dropSplit() {
        guard let split else { return }
        split.returnBorrowedPages()
        split.removeFromSuperview()
        self.split = nil
        splitSpot = nil
        onApart?(false)
    }

    private func dropPage() {
        guard let page else { return }
        page.returnBorrowedPages()
        page.removeFromSuperview()
        self.page = nil
    }

    private func dropGround() {
        ground?.removeFromSuperview()
        ground = nil
    }

    private func placeCards(for tab: Tab?) {
        if let tab, browser.findState.on {
            let host = find ?? {
                let made = put(FindHost(browser: browser))
                made.arrives = false
                find = made
                return made
            }()
            host.frame = bounds
            host.needsLayout = true
        } else if let find {
            find.removeFromSuperview()
            self.find = nil
        }
        if let tab, let asked = browser.suggesting, asked.tab == tab.id {
            let fresh = accounts == nil
            let host = accounts ?? put(AccountHost(browser: browser))
            accounts = host
            host.show(browser, asked)
            host.frame = bounds
            if fresh { host.kitFade(false, curve: .none); host.kitFade(true, curve: Motion.kitQuick) }
        } else if let going = accounts {
            accounts = nil
            going.kitFade(false, curve: Motion.kitQuick) { going.removeFromSuperview() }
        }
        if let tab, let asked = browser.applePairing, asked.tab == tab.id {
            let fresh = pairing == nil
            let host = pairing ?? put(PairingHost(browser: browser, pairing: asked))
            pairing = host
            host.show(browser, asked)
            host.frame = bounds
            if fresh { host.kitFade(false, curve: .none); host.kitFade(true, curve: Motion.kitQuick) }
        } else if let going = pairing {
            pairing = nil
            going.kitFade(false, curve: Motion.kitQuick) { going.removeFromSuperview() }
        }
    }

    private func placePill(_ shown: (tab: Tab, rect: CGRect, onPage: Bool)?) {
        guard let shown, !browser.makingSpace else {
            pill.isHidden = true
            pill.loading = false
            return
        }
        pill.isHidden = false
        let at = LoadPillView.origin(in: shown.rect, cards: cards)
        let frame = CGRect(x: at.x, y: at.y, width: LoadPillView.width, height: LoadPillView.height)
        if pill.frame != frame { pill.frame = frame }
        browser.spaceNeighbour.watch()
        let base = superview?.kitDark ?? kitDark
        var dark = base
        if cards {
            let next = browser.spaceNext.flatMap { browser.spaces.indices.contains($0) ? browser.spaces[$0].look ?? SpaceLook() : SpaceLook() }
            let blend = LookBlend(from: browser.seenLook, to: next, share: next != nil && browser.spaceMotion.crossing.past ? 1 : 0)
            dark = blend.inkLight(dark: base)
        }
        pill.paint(LoadPillView.tone(cards: cards, onPage: shown.onPage), dark: dark)
        pill.loading = shown.tab.loading
    }
}

@MainActor
final class SpaceStagePreviewView: KitFlippedView {
    let browser: Browser
    let row: Parked
    let space: UUID
    let corner: CGFloat
    var sliding = true { didSet { if sliding != oldValue { needsLayout = true } } }
    var apart: Bool { frames.count > 1 && corner > 0 }
    private var stage: PaneStage?
    private var single: TabPageView?
    private var ground: PageGroundView?
    private var panes: [Tab.ID: (page: TabPageView, picture: StagePicture?, bar: PaneBarView?, clip: KitFlippedView, cue: FocusCue?, edge: PaneEdge)] = [:]
    private var frames: [Tab.ID: CGRect] = [:]

    init(browser: Browser, row: Parked, space: UUID, corner: CGFloat) {
        self.browser = browser
        self.row = row
        self.space = space
        self.corner = corner
        super.init(frame: .zero)
        if browser.prefs.splitView {
            let made = PaneStage()
            made.onFrames = { [weak self] frames in
                guard let self, self.frames != frames else { return }
                self.frames = frames
                needsLayout = true
            }
            addSubview(made)
            stage = made
        } else if let tab = tabs.first {
            let made = TabPageView(tab: tab, browser: browser)
            addSubview(made)
            single = made
        }
        if tabs.isEmpty {
            let made = PageGroundView()
            addSubview(made, positioned: .below, relativeTo: nil)
            ground = made
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var split: TabSplit? {
        guard browser.prefs.splitView, let active = row.active else { return nil }
        return row.splits.first { $0.contains(active) }
    }

    var tabs: [Tab] {
        if let split { return split.tabs.compactMap { id in row.tabs.first { $0.id == id } } }
        return row.tabs.filter { $0.id == row.active }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            stage?.returnBorrowedPages()
            single?.returnBorrowedPages()
            return
        }
        for tab in tabs where !tab.wake() { tab.revive() }
    }

    override func layout() {
        super.layout()
        if let ground {
            ground.frame = bounds
            ground.show(browser.pageLook(in: space).page(dark: kitDark))
        }
        if let single, let tab = tabs.first {
            single.frame = bounds
            single.update(.init(holdsPage: true, corner: 0, veiled: false, space: space, borrowing: true, hold: nil, card: nil),
                          tab: tab, browser: browser)
            return
        }
        guard let stage else { return }
        let tabs = tabs
        stage.frame = bounds
        stage.sliding = sliding
        stage.spaceID = space
        stage.borrowing = true
        stage.groundDark = (browser.spaces.first { $0.id == space }?.look ?? SpaceLook()).inkLight(dark: false)
        stage.look = browser.pageLook(in: space)
        stage.corner = corner
        stage.show(tabs, split: split, focused: row.active)
        let paired = tabs.count == 2
        var kept: Set<Tab.ID> = []
        for tab in tabs {
            guard let frame = frames[tab.id] else { continue }
            kept.insert(tab.id)
            let pane = panes[tab.id] ?? {
                let clip = KitFlippedView()
                clip.wantsLayer = true
                clip.layer?.masksToBounds = true
                clip.layer?.cornerCurve = .continuous
                let page = TabPageView(tab: tab, browser: browser)
                clip.addSubview(page)
                let picture = paired ? StagePicture() : nil
                if let picture { clip.addSubview(picture) }
                let bar = paired ? PaneBarView(browser: browser, tab: tab) : nil
                let cue = paired ? FocusCue() : nil
                let edge = PaneEdge()
                addSubview(clip)
                if let cue { addSubview(cue) }
                if let bar { addSubview(bar) }
                addSubview(edge)
                let made = (page: page, picture: picture, bar: bar, clip: clip, cue: cue, edge: edge)
                panes[tab.id] = made
                return made
            }()
            pane.clip.frame = frame
            pane.page.frame = pane.clip.bounds
            pane.page.update(.init(holdsPage: false, space: space), tab: tab, browser: browser)
            pane.picture?.frame = pane.clip.bounds
            pane.picture?.show(browser.spacePictures.image(for: tab, in: space), corner: 0)
            let alone = frames.count < 2
            let column = pane.bar == nil ? frame : frame.union(frame.offsetBy(dx: 0, dy: -Metrics.paneBar))
            let outer = sliding || alone ? PaneStage.outer(column, in: bounds) : (left: false, right: false)
            pane.clip.layer?.cornerRadius = alone ? 0 : corner
            pane.clip.layer?.maskedCorners = PaneStage.bottoms(flipped: pane.clip.isFlipped).subtracting(PaneStage.sides(outer))
            if let bar = pane.bar {
                bar.frame = CGRect(x: frame.minX, y: frame.minY - Metrics.paneBar, width: frame.width, height: Metrics.paneBar)
                bar.show(tab: tab, focused: row.active == tab.id, carrying: false, corner: corner, look: browser.pageLook(in: space))
            }
            let lit = paired && row.active == tab.id
            let ring = PaneStage.ring(column, outer: outer, corner: corner)
            let cut = sliding || alone ? nil : bounds
            if let cue = pane.cue {
                cue.corner = corner
                cue.wrap(ring, in: self, cut: cut, within: column)
                cue.alphaValue = lit ? 1 : 0
            }
            pane.edge.corner = corner
            pane.edge.wrap(ring, in: self, cut: cut, within: column)
            pane.edge.ink = PaneEdge.ink(browser.pageLook(in: space), dark: kitDark)
            pane.edge.alphaValue = corner > 0 && !alone && !lit ? 1 : 0
        }
        for (id, pane) in panes where !kept.contains(id) {
            pane.clip.removeFromSuperview()
            pane.bar?.removeFromSuperview()
            pane.cue?.removeFromSuperview()
            pane.edge.removeFromSuperview()
            panes[id] = nil
        }
    }
}

extension SpaceStagePreviewView {
    static func edges(in root: NSView) -> [[String: Any]] {
        guard let window = root.window else { return [] }
        return root.kitSubviews(of: SpaceStagePreviewView.self).filter { !$0.isHiddenOrHasHiddenAncestor }.flatMap { preview in
            preview.panes.values.map { pane -> [String: Any] in
                let frame = pane.clip.convert(pane.clip.bounds, to: nil)
                let top = window.contentLayoutRect.maxY
                return ["box": [frame.minX, top - frame.maxY, frame.maxX, top - frame.minY].map { Double($0) },
                        "edge": Double(pane.edge.alphaValue > 0 || (pane.cue?.alphaValue ?? 0) > 0 ? pane.edge.line : 0),
                        "rounds": PaneStage.rounds(pane.clip)]
            }
        }
    }
}

@MainActor
final class AIOverlayView: KitFlippedView {
    let browser: Browser
    private let pointer = AgentPointerView()
    private let selection: SelectionOverlayView
    private var card: AgentCardView?
    private(set) var cardFrame: CGRect? { didSet { if cardFrame != oldValue { onCard?() } } }
    var onCard: (() -> Void)?

    init(browser: Browser) {
        self.browser = browser
        selection = SelectionOverlayView(browser: browser)
        super.init(frame: .zero)
        pointer.setAccessibilityElement(false)
        addSubview(pointer)
        addSubview(selection)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        let tab = browser.active
        pointer.isHidden = tab == nil || browser.activeSplit != nil
        pointer.frame = bounds
        pointer.tab = tab?.id
        pointer.driving = tab?.driving ?? false
        selection.frame = bounds
        selection.sync()
        if AgentDesk.shared.front != nil {
            let view = card ?? {
                let made = AgentCardView(browser: browser, desk: .shared)
                addSubview(made)
                card = made
                return made
            }()
            view.sync()
            view.invalidateIntrinsicContentSize()
            let size = view.intrinsicContentSize
            let room = max(0, bounds.width - 40)
            let width = size.width == NSView.noIntrinsicMetric ? min(AgentCardView.widest, room) : min(size.width, AgentCardView.widest, room)
            view.frame = kitSnap(CGRect(x: (bounds.width - width) / 2, y: bounds.height - 14 - size.height, width: width, height: size.height))
            cardFrame = view.frame
        } else if let card {
            card.removeFromSuperview()
            self.card = nil
            cardFrame = nil
        } else {
            cardFrame = nil
        }
    }
}

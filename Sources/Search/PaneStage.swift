import AppKit
import Combine
import WebKit

// Split View's stage, while the switch is on: one AppKit view that holds
// every page on screen, one or two, and is never rebuilt — not from one tab
// to the next, not from one page to two. Each page keeps a StageView of its
// own (see Stage.swift), so everything that stage learned about taking a
// page back holds here too. With the switch off none of this exists, and the
// window's stage is the one it always was.
//
// The divider is this view's own: it follows the pointer, lays the pages out
// as it goes, and tells the pair once, when the button comes up. Nothing is
// published while it moves — not to the window, the row or the menus.

final class PaneStage: NSView {
    var spaceID: UUID?
    var borrowing = false {
        didSet { for slot in slots { slot.borrowing = borrowing } }
    }

    func returnBorrowedPages() {
        for slot in slots { slot.returnBorrowedPages() }
    }
    var corner: CGFloat = 0 {
        didSet {
            guard corner != oldValue else { return }
            for cue in cues { cue.corner = corner }
            for edge in edges { edge.corner = corner }
            paint()
            needsLayout = true
        }
    }
    var groundDark = false {
        didSet {
            guard groundDark != oldValue else { return }
            paint()
            needsLayout = true
        }
    }
    var look: SpaceLook? {
        didSet {
            guard look != oldValue else { return }
            paint()
        }
    }
    var sliding = false {
        didSet {
            guard sliding != oldValue else { return }
            paint()
            needsLayout = true
        }
    }
    var framed: Bool { sliding || !separate }
    var onApart: ((Bool) -> Void)?
    private var saidApart: Bool?
    private(set) var edgeWidth: CGFloat = 0
    private var cutFor: (size: CGSize, corner: CGFloat)?
    private var painted: (apart: Bool, framed: Bool)?
    fileprivate var shadows: [CALayer] = []
    var onCommit: ((UUID, [Double]) -> Void)?
    var onFocus: ((Tab) -> Void)?
    /// Where each page is, from the top left, each time that changes — never
    /// while the divider is being dragged.
    var onFrames: (([Tab.ID: CGRect]) -> Void)?
    /// The divider's menu.
    var onAction: ((Action) -> Void)?
    /// The page under the pointer, as it changes; nil off the stage.
    var onHover: ((Tab.ID?) -> Void)?
    private var hovered: Tab.ID?

    enum Action { case swap, even, separate, closeBoth }

    /// Between the pages: room for the divider, and to keep it off the left
    /// page's scroll bar.
    static let gutter: CGFloat = 7
    /// Narrower than this, a page is no use: the pair shows the focused page
    /// alone until there is room again, and stays a pair.
    static let narrowest: CGFloat = 250
    /// How close to even the divider has to come to settle there.
    static let snap: CGFloat = 15
    /// And how far past it the pointer goes before it lets go.
    static let unsnap: CGFloat = 20

    fileprivate var tabs: [Tab] = []
    var veiled = false {
        didSet { if veiled != oldValue { needsLayout = true } }
    }
    fileprivate var split: TabSplit?
    private var focused: Tab.ID?
    private var findBar: FindHost?
    private var findWidth: CGFloat?

    /// The controls belong to the stage so they stay above WebKit, below
    /// window panels, and follow every layout of the focused page.
    func showFind(_ browser: Browser?) {
        findTicket += 1
        guard let browser else {
            guard findBar != nil else { return }
            let ticket = findTicket
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.calm ? 0.16 : 0.26)) { [weak self] in
                guard let self, self.findTicket == ticket else { return }
                self.findBar?.removeFromSuperview()
                self.findBar = nil
                self.findWidth = nil
            }
            return
        }
        if findBar == nil {
            let bar = FindHost.make(browser)
            findBar = bar
            addSubview(bar, positioned: .above, relativeTo: nil)
        }
        needsLayout = true
    }

    private var findTicket = 0

    private var accountList: AccountHost?
    private var accountsFor: Tab.ID?
    private var pairingCard: PairingHost?
    private var pairingFor: Tab.ID?

    /// Apple Passwords' code card under a sign-in box (ApplePairingCard),
    /// above the pages for the reason the accounts are.
    func showPairing(_ pairing: (browser: Browser, pairing: Browser.ApplePairing)?) {
        guard let pairing else {
            pairingCard?.removeFromSuperview()
            pairingCard = nil
            pairingFor = nil
            return
        }
        if pairingCard == nil {
            let host = PairingHost.make(pairing.browser, pairing.pairing)
            pairingCard = host
            addSubview(host, positioned: .above, relativeTo: nil)
        }
        guard let host = pairingCard else { return }
        host.show(pairing.browser, pairing.pairing)
        pairingFor = pairing.pairing.tab
        needsLayout = true
    }

    /// The accounts under a sign-in box, for the same reason: drawn by
    /// SwiftUI over the stage, they were under WebKit's pages and never
    /// seen, though the list was up and a click on the box did nothing.
    func showAccounts(_ accounts: (browser: Browser, asked: Browser.Suggesting)?) {
        guard let accounts else {
            accountList?.removeFromSuperview()
            accountList = nil
            accountsFor = nil
            return
        }
        if accountList == nil {
            let host = AccountHost.make(accounts.browser, accounts.asked)
            accountList = host
            addSubview(host, positioned: .above, relativeTo: nil)
        }
        guard let host = accountList else { return }
        host.show(accounts.browser, accounts.asked)
        accountsFor = accounts.asked.tab
        needsLayout = true
    }
    fileprivate var slots: [StageView] = []
    fileprivate let pageFrame = PageFrame()
    private let frameShadow = CALayer()
    private var cues: [FocusCue] = []
    private var edges: [PaneEdge] = []
    private var agentRims: [AgentRimView] = []
    let rims = PaneRims()
    private var cuesFor: (space: UUID?, paired: Bool, sliding: Bool)?
    fileprivate let divider = PaneDivider()
    private var holding: AnyCancellable?
    private var held: [ObjectIdentifier] = []
    private var monitor: Any?
    private var told: [Tab.ID: CGRect] = [:]

    /// The first page's share while the divider is held; nil otherwise.
    private var live: Double?
    private var snapped = false
    /// Just let go of: the pair then told of it is no move to show.
    fileprivate var dragged = false
    /// Which change is the latest: a picture that arrives for an older one
    /// is let go.
    fileprivate var generation = 0
    /// The pictures standing in for pages while they move.
    fileprivate var pictures: [NSImageView] = [] {
        didSet { if pictures.isEmpty != oldValue.isEmpty { needsLayout = true } }
    }
    fileprivate var motionLog: [(NSImageView, CGRect, CGRect)] = []
    private var lifting: PaneLift?
    private var landing: PaneLift?
    private var arriving: (tabs: [Tab], split: TabSplit?, focused: Tab.ID?, standIn: Tab.ID?)?
    private(set) var standIn: Tab.ID?
    private var raised = false
    private var liftShadow: CALayer?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        frameShadow.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "shadowPath": NSNull()]
        layer?.insertSublayer(frameShadow, at: 0)
        addSubview(pageFrame)
        addSubview(rims)
        divider.stage = self
        addSubview(divider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func updateLayer() {
        paint()
    }

    // MARK: - what is shown

    func show(_ tabs: [Tab], split: TabSplit?, focused: Tab.ID?, standIn: Tab.ID? = nil) {
        if let landed = landing {
            landing = nil
            if tabs.map(\.id) != self.tabs.map(\.id), window != nil { return land(landed, tabs, split: split, focused: focused) }
            lower()
        }
        if let pending = arriving {
            if tabs.map(\.id) == pending.tabs.map(\.id) {
                arriving = (tabs, split, focused, standIn)
                return
            }
            arriving = nil
        }
        // A change the eye should follow — a page arriving beside another,
        // one leaving, the two swapping, the divider moving by itself — is
        // shown moving (see `animate`). Anything else, a tab switch among
        // them, is a cut, as it always was.
        guard let move = motion(to: tabs, split: split), window != nil else {
            // The same pages again — SwiftUI asking once more — leave a move
            // under way alone; different ones cut it short.
            if tabs.map(\.id) != self.tabs.map(\.id) || split?.sizes != self.split?.sizes {
                generation += 1
                clearPictures()
            }
            if standIn == nil { resting = nil }
            return apply(tabs, split: split, focused: focused, standIn: standIn)
        }
        let before = placed()
        let was = self.tabs.map(\.id)
        let entering = standIn != nil && self.standIn == nil
        let kept = standIn == nil && self.standIn != nil ? resting.flatMap { $0.ids == tabs.map(\.id) ? $0.pictures : nil } : nil
        if standIn == nil { resting = nil }
        let leaving = kept == nil ? self.tabs.filter { before[$0.id] != nil && $0.id != self.standIn } : []
        generation += 1
        let ticket = generation
        capture(leaving) { [weak self] pictures in
            guard let self, ticket == self.generation else { return }
            if entering { self.resting = (was, pictures) }
            self.clearPictures()
            self.apply(tabs, split: split, focused: focused, standIn: standIn)
            self.layoutSubtreeIfNeeded()
            self.animate(move, from: before, pictures: kept ?? pictures)
        }
    }

    private var resting: (ids: [Tab.ID], pictures: [Tab.ID: NSImage])?

    private func apply(_ tabs: [Tab], split: TabSplit?, focused: Tab.ID?, standIn: Tab.ID? = nil) {
        if lifting == nil { lower() }
        self.tabs = tabs
        self.standIn = standIn
        let ids = tabs.map(ObjectIdentifier.init)
        if ids != held {
            held = ids
            holding = kitObserve(initial: false, { [weak self] in self?.tabs.map { ($0.isWeb, $0.asleep, $0.floating) } }) { [weak self] _ in
                self?.refill()
            }
        }
        self.split = split
        self.focused = focused
        if live != nil, split == nil { live = nil }
        refill()
    }

    /// The page a tab puts on the stage: none while it is blank, one of
    /// Search's own pages, asleep or floating, as Page decides it (see
    /// Stage.swift).
    private func page(_ tab: Tab) -> NSView? {
        !tab.isWeb || tab.asleep || tab.floating || tab.id == standIn ? nil : tab.web
    }

    private func refill() {
        while slots.count < tabs.count {
            let slot = StageView()
            slot.wantsLayer = true
            slot.borrowing = borrowing
            pageFrame.addSubview(slot, positioned: .below, relativeTo: nil)
            slots.append(slot)
            let shadow = CALayer()
            shadow.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "shadowPath": NSNull()]
            shadow.cornerCurve = .continuous
            pageFrame.layer?.insertSublayer(shadow, at: 0)
            shadows.append(shadow)
            let edge = PaneEdge()
            edge.corner = corner
            edge.alphaValue = 0
            rims.addSubview(edge)
            edges.append(edge)
            let cue = FocusCue()
            cue.corner = corner
            cue.alphaValue = 0
            rims.addSubview(cue)
            cues.append(cue)
            let agent = AgentRimView()
            rims.addSubview(agent)
            agentRims.append(agent)
        }
        // Which page each slot holds is put right with where the slots are,
        // in layout(), not here: told from SwiftUI's update, a page filling
        // the screen took the other one off a frame before the stage grew
        // to give it the room.
        paint()
        needsLayout = true
        watchClicks()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        paint()
    }

    static func edge(card: Bool) -> CGFloat {
        card ? PaneEdge.width : 0
    }

    /// The cards' edges and shadows, in this appearance's colours; nothing
    /// without corners, where the pages fill the stage as they always did.
    private func paint() {
        let card = corner > 0
        let apart = separate
        let framed = framed
        painted = (apart, framed)
        divider.card = card
        let line = Self.edge(card: card)
        if edgeWidth != line {
            edgeWidth = line
            needsLayout = true
        }
        let page = look?.page(dark: kitDark)
        for slot in slots { slot.ground = page }
        let ink = PaneEdge.ink(look ?? SpaceLook(), dark: kitDark)
        for edge in edges { edge.ink = ink }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let ground = page?.flat.cgColor ?? Palette.NS.ground.cgColor
            layer?.backgroundColor = NSColor.clear.cgColor
            if let frame = pageFrame.layer {
                frame.backgroundColor = apart ? nil : ground
                frame.cornerRadius = framed ? 0 : corner
                frame.cornerCurve = .continuous
                frame.masksToBounds = !apart
            }
            frameShadow.backgroundColor = ground
            for shadow in [frameShadow] + shadows {
                if shadow !== frameShadow { shadow.backgroundColor = ground }
                shadow.shadowColor = NSColor.black.cgColor
                shadow.shadowOpacity = Swift.Float(CardEdge.shadow)
                shadow.shadowRadius = 6
                shadow.shadowOffset = CGSize(width: 0, height: 1)
                shadow.cornerRadius = corner
            }
            frameShadow.cornerCurve = .continuous
            frameShadow.isHidden = !card || apart
        }
    }

    private var separate: Bool { paired && corner > 0 }

    static func bottoms(flipped: Bool) -> CACornerMask {
        flipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }

    static let allCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]

    static func outer(_ card: CGRect, in bounds: CGRect) -> (left: Bool, right: Bool) {
        (abs(card.minX - bounds.minX) < 0.5, abs(card.maxX - bounds.maxX) < 0.5)
    }

    static func sides(_ outer: (left: Bool, right: Bool)) -> CACornerMask {
        var corners: CACornerMask = []
        if outer.left { corners.formUnion([.layerMinXMinYCorner, .layerMinXMaxYCorner]) }
        if outer.right { corners.formUnion([.layerMaxXMinYCorner, .layerMaxXMaxYCorner]) }
        return corners
    }

    static func ring(_ card: CGRect, outer: (left: Bool, right: Bool), corner: CGFloat) -> CGRect {
        let past = corner * 2 + PaneEdge.width + 2
        let left = outer.left ? past : 0, right = outer.right ? past : 0
        return CGRect(x: card.minX - left, y: card.minY, width: card.width + left + right, height: card.height)
    }

    /// What each slot was last told to show.
    private var fed: [Fed] = []

    private struct Fed {
        weak var page: NSView?
        var empty = true
    }

    /// Each slot its page, told only when that changes: which pages are on
    /// screen depends on the tabs and on the room, and both can change.
    private func feed() {
        while fed.count < slots.count { fed.append(Fed()) }
        for (index, slot) in slots.enumerated() {
            let wanted = !veiled && index < tabs.count && shown(index) ? page(tabs[index]) : nil
            let was = fed[index]
            guard was.page !== wanted || (wanted == nil) != was.empty else { continue }
            fed[index] = Fed(page: wanted, empty: wanted == nil)
            slot.show(wanted, space: spaceID)
        }
    }

    // MARK: - where things go

    /// The first page's share, as it is drawn now.
    private var share: Double { live ?? split?.fraction ?? 0.5 }

    /// Two pages side by side, with room enough for both.
    private var paired: Bool {
        tabs.count == 2 && immersed == nil && bounds.width - Self.gutter >= 2 * Self.narrowest
    }

    /// A page lent to WebKit's full screen window: its slot has the stage.
    /// As the window says it, with its chrome, not from the tab: read from
    /// the tab, the other page went (or came back) a turn before the column
    /// and the card did, one more jump.
    var immersedID: Tab.ID? = nil {
        didSet { if immersedID != oldValue { needsLayout = true } }
    }
    fileprivate var immersed: Int? { immersedID.flatMap { id in tabs.firstIndex { $0.id == id } } }

    /// Whether the page in this slot is on screen.
    private func shown(_ index: Int) -> Bool {
        if tabs.count < 2 { return true }
        if let immersed { return index == immersed }
        if bounds.width - Self.gutter >= 2 * Self.narrowest || bounds.width == 0 { return true }
        return tabs[index].id == (focused ?? tabs[0].id)
    }

    private func pageFrames(in area: CGRect) -> [CGRect] {
        var frames: [CGRect] = Array(repeating: .zero, count: tabs.count)
        if paired {
            let room = area.width - Self.gutter
            let scale = window?.backingScaleFactor ?? 2
            let left = (clampLeft(room * CGFloat(share), room: room) * scale).rounded() / scale
            let bar = Metrics.paneBar
            frames[0] = CGRect(x: 0, y: bar, width: left, height: area.height - bar)
            frames[1] = CGRect(x: left + Self.gutter, y: bar, width: room - left, height: area.height - bar)
        } else {
            for index in tabs.indices where shown(index) { frames[index] = area }
        }
        return frames
    }

    func hold(growing delta: CGSize?) {
        guard let delta else {
            for slot in slots { slot.held = nil }
            return
        }
        let wide = CGRect(x: 0, y: 0, width: bounds.width + max(0, delta.width), height: bounds.height + max(0, delta.height))
        let ends = pageFrames(in: wide)
        for (index, slot) in slots.enumerated() {
            let end = index < ends.count ? ends[index].size : .zero
            slot.held = NSSize(width: max(slot.bounds.width, end.width, slot.held?.width ?? 0),
                               height: max(slot.bounds.height, end.height, slot.held?.height ?? 0))
        }
    }

    var card: CardClip? {
        didSet {
            guard card != oldValue else { return }
            clip(to: card)
            if rims.superview !== self { rims.clip(to: card) }
        }
    }

    override func layout() {
        super.layout()
        clip(to: card)
        if rims.superview !== self { rims.clip(to: card) }
        let area = bounds
        let frames = pageFrames(in: area)
        if pageFrame.frame != area { pageFrame.frame = area }
        if rims.superview === self, rims.frame != area { rims.frame = area }
        let resized = frameShadow.bounds.size != area.size
        if resized {
            frameShadow.bounds = CGRect(origin: .zero, size: area.size)
            frameShadow.position = CGPoint(x: area.midX, y: area.midY)
        }
        if paired {
            divider.frame = CGRect(x: frames[0].maxX, y: 0, width: Self.gutter, height: area.height)
            divider.isHidden = false
        } else {
            divider.isHidden = true
        }
        if painted?.apart != separate || painted?.framed != framed { paint() }
        let stale = cutFor.map { $0.size != area.size || $0.corner != corner } ?? true
        if resized || stale {
            cutFor = (area.size, corner)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            frameShadow.shadowPath = KitPath.continuous(frameShadow.bounds, radius: corner)
            CATransaction.commit()
        }
        let apart = separate
        let framed = framed
        let cut = apart && !sliding ? bounds : nil
        if saidApart != apart {
            saidApart = apart
            onApart?(apart)
        }
        let arriving = cuesFor.map { $0.space != spaceID || $0.paired != paired || $0.sliding != sliding } ?? true
        cuesFor = (spaceID, paired, sliding)
        for (index, slot) in slots.enumerated() {
            let frame = index < frames.count ? frames[index] : .zero
            let visible = index < tabs.count && shown(index) && frame.width > 0
            slot.isHidden = !visible
            if slot.frame != frame { slot.frame = frame }
            slot.corner = apart ? corner : 0
            let column = paired ? frame.union(frame.offsetBy(dx: 0, dy: -Metrics.paneBar)) : frame
            let outer = framed ? Self.outer(column, in: bounds) : (left: false, right: false)
            let rounded = (apart ? Self.bottoms(flipped: slot.layer?.contentsAreFlipped() ?? true) : Self.allCorners)
                .subtracting(Self.sides(outer))
            if slot.layer?.maskedCorners != rounded { slot.layer?.maskedCorners = rounded }
            if index < shadows.count {
                // Pages run the stage's full height, so its flip is no matter.
                let shadow = shadows[index]
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                shadow.bounds = CGRect(origin: .zero, size: column.size)
                shadow.position = CGPoint(x: column.midX, y: column.midY)
                shadow.shadowPath = KitPath.continuous(shadow.bounds, radius: corner)
                shadow.maskedCorners = Self.allCorners.subtracting(Self.sides(outer))
                shadow.isHidden = !apart || !visible
                CATransaction.commit()
            }
            // Only with two pages on screen does it matter which one keys go to.
            let cue = cues[index]
            let ring = Self.ring(column, outer: outer, corner: corner)
            cue.wrap(ring, in: self, cut: cut, within: column)
            let lit = paired && index < tabs.count && tabs[index].id == focused
            let edge = edges[index]
            edge.wrap(ring, in: self, cut: cut, within: column)
            let quiet = apart && visible && !lit
            let agent = agentRims[index]
            let worn = CardRim.snapped(column, in: self)
            if agent.frame != worn { agent.frame = worn }
            agent.corner = corner
            agent.wear(paired && visible && !sliding ? tabs[index].agentColour : nil, animated: !arriving)
            if arriving {
                cue.alphaValue = lit ? 1 : 0
                edge.alphaValue = quiet ? 1 : 0
            } else {
                for (view, on) in [(cue as NSView, lit), (edge, quiet)] where (view.alphaValue == 1) != on {
                    NSAnimationContext.kit(Motion.kitQuick) {
                        view.animator().alphaValue = on ? 1 : 0
                    }
                }
            }
        }
        // A window made too narrow for two takes the other page off, and
        // gives it back once there is room.
        feed()
        if let bar = findBar {
            let page = focused.flatMap { id in tabs.firstIndex { $0.id == id } }
                .flatMap { frames.indices.contains($0) ? frames[$0] : nil }
            bar.isHidden = page == nil || page?.width == 0
            if let page, page.width > 0 {
                if findWidth != page.width {
                    findWidth = page.width
                    bar.fit(page.width)
                }
                let width = min(FindBarView.widest, page.width)
                bar.frame = CGRect(x: page.maxX - width, y: page.minY,
                                   width: width, height: min(60, page.height))
            }
        }
        if let host = pairingCard {
            // As the accounts below: over the page the box is on.
            let page = pairingFor.flatMap { id in tabs.firstIndex { $0.id == id } }
                .flatMap { frames.indices.contains($0) ? frames[$0] : nil }
            host.isHidden = page == nil || page?.width == 0
            if let page, host.frame != page { host.frame = page }
        }
        if let host = accountList {
            // Over the page the box is on, as large as it: the list places
            // itself under the box from that page's top-left.
            let page = accountsFor.flatMap { id in tabs.firstIndex { $0.id == id } }
                .flatMap { frames.indices.contains($0) ? frames[$0] : nil }
            host.isHidden = page == nil || page?.width == 0
            if let page, host.frame != page { host.frame = page }
        }
        guard live == nil else { return }
        var now: [Tab.ID: CGRect] = [:]
        for (index, tab) in tabs.enumerated() where shown(index) { now[tab.id] = frames[index] }
        if now != told {
            told = now
            let frames = now
            DispatchQueue.main.async { [weak self] in self?.onFrames?(frames) }
        }
    }

    /// Neither page narrower than `narrowest` while both are on screen.
    private func clampLeft(_ left: CGFloat, room: CGFloat) -> CGFloat {
        min(max(left, Self.narrowest), room - Self.narrowest)
    }

    // MARK: - the divider, held

    fileprivate func dividerBegan() {
        live = split?.fraction ?? 0.5
        snapped = abs(live! - 0.5) < 0.0001
    }

    fileprivate func dividerMoved(to x: CGFloat) {
        guard live != nil else { return }
        let room = bounds.width - Self.gutter
        guard room > 0 else { return }
        var left = clampLeft(x - Self.gutter / 2, room: room)
        let even = room / 2
        if snapped {
            if abs(left - even) > Self.unsnap { snapped = false } else { left = even }
        } else if abs(left - even) <= Self.snap {
            snapped = true
            left = even
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let fraction = Double(left / room)
        guard fraction != live else { return }
        live = fraction
        // Laid out now, not on the next pass: the pages are to keep up with
        // the hand.
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    fileprivate func dividerEnded() {
        guard let fraction = live else { return }
        let id = split?.id
        live = nil
        // Already where the hand left it: the pair being told is no move.
        dragged = true
        needsLayout = true
        if let id { onCommit?(id, [fraction, 1 - fraction]) }
    }

    /// Double-clicked, or asked by VoiceOver: even, or a step either way.
    fileprivate func setShare(_ fraction: Double) {
        guard let id = split?.id else { return }
        onCommit?(id, TabSplit.clamp([fraction, 1 - fraction]))
    }

    fileprivate var currentShare: Double { share }

    fileprivate func act(_ action: Action) { onAction?(action) }

    // MARK: - a click on a page focuses it

    /// With two pages up, a click in the one without the keys gives them to
    /// it, and is still the page's click. Watched rather than taken: the
    /// click belongs to WebKit.
    private func watchClicks() {
        let wanted = tabs.count == 2 && window != nil
        if wanted, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                self?.clicked(event)
                return event
            }
        } else if !wanted, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func clicked(_ event: NSEvent) {
        guard let window, event.window === window, paired else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        // What is over the stage — the field, the find bar, a panel — is not
        // the page: a click there moves nothing.
        if let hit = window.contentView?.hitTest(event.locationInWindow), hit !== self,
           !hit.isDescendant(of: self) { return }
        for (index, slot) in slots.enumerated() where index < tabs.count && slot.frame.contains(point) {
            let tab = tabs[index]
            guard tab.id != focused else { return }
            DispatchQueue.main.async { [weak self] in self?.onFocus?(tab) }
            return
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        watchClicks()
    }

    // MARK: - the page under the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited,
                                                              .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let under = paired ? slots.indices.first { $0 < tabs.count && slots[$0].frame.contains(point) }.map { tabs[$0].id } : nil
        hover(under)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hover(nil)
    }

    private func hover(_ id: Tab.ID?) {
        guard hovered != id else { return }
        hovered = id
        onHover?(id)
    }
}

class CardRim: NSView {
    var corner: CGFloat = 0 { didSet { if corner != oldValue { needsDisplay = true } } }
    var card: CGRect? { didSet { if card != oldValue { needsDisplay = true } } }
    var cut: CGRect? { didSet { if cut != oldValue { needsDisplay = true } } }
    var line: CGFloat { 0 }
    var colour: NSColor { .clear }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func snapped(_ card: CGRect, in view: NSView) -> CGRect {
        guard card.width > 1, card.height > 1 else { return card }
        return view.backingAlignedRect(card.insetBy(dx: 0.01, dy: 0.01), options: .alignAllEdgesOutward)
    }

    static func shape(_ card: CGRect, in bounds: CGRect, cut: CGRect?, corner: CGFloat, line: CGFloat) -> (outer: CGPath, inner: CGPath) {
        func met(_ side: CGFloat, _ other: CGFloat?) -> Bool { other.map { abs(side - $0) < 0.01 } ?? false }
        let left = met(card.minX, cut?.minX), right = met(card.maxX, cut?.maxX)
        let top = met(card.minY, cut?.minY), bottom = met(card.maxY, cut?.maxY)
        let x = left ? min(bounds.minX, card.minX) : card.minX, y = top ? min(bounds.minY, card.minY) : card.minY
        let far = right ? max(bounds.maxX, card.maxX) : card.maxX, low = bottom ? max(bounds.maxY, card.maxY) : card.maxY
        let outer = KitPath.continuous(CGRect(x: x, y: y, width: far - x, height: low - y),
                                       topLeft: left && top ? 0 : corner, topRight: right && top ? 0 : corner,
                                       bottomLeft: left && bottom ? 0 : corner, bottomRight: right && bottom ? 0 : corner)
        return (KitPath.fine(outer), KitPath.fine(KitPath.continuous(card.insetBy(dx: line, dy: line), radius: max(0, corner - line))))
    }

    func wrap(_ card: CGRect, in view: NSView, cut: CGRect? = nil, within: CGRect? = nil) {
        let ring = Self.snapped(within ?? card, in: view)
        if clipsToBounds != (within != nil) { clipsToBounds = within != nil }
        if frame != ring { frame = ring }
        self.card = card.offsetBy(dx: -ring.minX, dy: -ring.minY)
        self.cut = cut?.offsetBy(dx: -ring.minX, dy: -ring.minY)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    static func fill(_ card: CGRect, in bounds: CGRect, cut: CGRect?, corner: CGFloat, line: CGFloat, colour: NSColor, on context: CGContext) {
        guard line > 0, card.width > 2 * line, card.height > 2 * line else { return }
        let shape = shape(card, in: bounds, cut: cut, corner: corner, line: line)
        context.addPath(shape.outer)
        context.addPath(shape.inner)
        context.setFillColor(colour.cgColor)
        context.fillPath(using: .evenOdd)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Self.fill(card ?? bounds, in: bounds, cut: cut, corner: corner, line: line, colour: colour, on: context)
    }
}

final class FocusCue: CardRim {
    static let width: CGFloat = 1
    static let ink = NSColor(white: 0.45, alpha: 0.7)
    override var line: CGFloat { Self.width }
    override var colour: NSColor { Self.ink }

    static func path(in bounds: CGRect, corner: CGFloat, line: CGFloat) -> CGPath {
        let inset = line / 2
        return KitPath.continuous(bounds.insetBy(dx: inset, dy: inset), radius: max(0, corner - inset))
    }
}

final class PaneRims: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class PaneEdge: CardRim {
    static let width: CGFloat = 1
    static let lift: (light: CGFloat, dark: CGFloat) = (0.025, 0.05)
    static let behind: (light: CGFloat, dark: CGFloat) = (0.88, 0.27)

    static func side(_ look: SpaceLook, dark: Bool, blurred: Bool = !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) -> NSColor {
        let ground = look.ground(dark: dark)
        let paint = ground.average.color
        let vivid = look.vivid(dark: dark)
        let shown = SpaceGroundView.shown(transparency: look.transparency, glass: look.glass ? 1 : 0, vivid: vivid, blurred: blurred)
        guard shown < 1 else { return paint }
        let under = vivid > 0 ? ground.lightInk : look.shade(dark: dark)
        return LookBlend.mix(NSColor(white: under ? behind.dark : behind.light, alpha: 1), paint, shown)
    }

    static func ink(_ look: SpaceLook, dark: Bool) -> NSColor {
        let ground = look.ground(dark: dark)
        return PaneBarLook.line(on: side(look, dark: dark), stops: ground.stops, lightInk: ground.lightInk,
                                share: ground.lightInk ? lift.dark : lift.light)
    }

    static func ring(in bounds: CGRect, corner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addPath(KitPath.fine(KitPath.continuous(bounds.insetBy(dx: width, dy: width), radius: max(0, corner - width))))
        return path
    }

    var ink = NSColor.clear { didSet { if ink != oldValue { needsDisplay = true } } }
    override var line: CGFloat { Self.width }
    override var colour: NSColor { ink }
}

final class PageFrame: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Between two pages: a narrow gutter that takes the pointer, with a small
/// pill in its middle (see Grip) — hidden at rest, faded in under the pointer
/// and while held, as the column's edge grip is. As cards, the gap is what
/// parts the pages; edge to edge, a hairline down the gutter does. Dragged, the pages follow it;
/// double-clicked, they are made even. It never takes the keys: the page
/// keeps them.
final class PaneDivider: NSView {
    weak var stage: PaneStage?
    /// The pages are cards (see PaneStage.paint): no hairline then.
    var card = false {
        didSet { if card != oldValue { needsDisplay = true } }
    }

    private let pill = CALayer()
    private let seam = CALayer()
    private var hovering = false
    private var dragging = false
    private var lit: Bool { hovering || dragging }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(seam)
        layer?.addSublayer(pill)
        pill.opacity = 0
        for part in [pill, seam] {
            part.actions = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = (lit ? Palette.NS.muted : Palette.NS.faint).cgColor
            seam.backgroundColor = Palette.NS.hairline.cgColor
        }
        seam.isHidden = card
    }

    override func layout() {
        super.layout()
        place()
    }

    private func place() {
        let length = min(bounds.height, lit ? Grip.lit : Grip.rest)
        pill.frame = CGRect(x: (bounds.width - Grip.width) / 2, y: (bounds.height - length) / 2,
                            width: Grip.width, height: length)
        pill.cornerRadius = Grip.width / 2
        pill.opacity = lit ? 1 : 0
        seam.frame = CGRect(x: (bounds.width - 1) / 2, y: 0, width: 1, height: bounds.height)
    }

    private func light(_ on: Bool) {
        guard hovering != on else { return }
        hovering = on
        // Only this change moves; the pill keeps still while the window or
        // the pages are being resized.
        let still = pill.actions
        pill.actions = nil
        CATransaction.begin()
        CATransaction.setDisableActions(Motion.reduced)
        CATransaction.setAnimationDuration(Grip.fade)
        place()
        paint()
        CATransaction.commit()
        pill.actions = still
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { light(true) }

    override func mouseExited(with event: NSEvent) {
        if !dragging { light(false) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let stage else { return }
        if event.clickCount == 2 {
            stage.setShare(0.5)
            return
        }
        dragging = true
        light(true)
        stage.dividerBegan()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let stage else { return }
        NSCursor.resizeLeftRight.set()
        stage.dividerMoved(to: stage.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        stage?.dividerEnded()
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        hovering = !inside
        light(inside)
    }

    func benchHover(_ on: Bool) {
        guard Store.testing else { return }
        if on || !dragging { light(on) }
    }

    func benchHold(_ on: Bool) {
        guard Store.testing, let stage else { return }
        if on {
            dragging = true
            light(true)
            stage.dividerBegan()
        } else {
            dragging = false
            stage.dividerEnded()
            light(false)
        }
    }

    var benchPill: [String: Double] {
        let shown = pill.presentation() ?? pill
        return ["opacity": Double(shown.opacity), "height": Double(shown.bounds.height), "model": Double(pill.opacity)]
    }

    // MARK: - its menu

    /// What can be done with the pair, from the page area itself: the tabs
    /// may be folded away.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        for (title, action) in [("Swap Pages", PaneStage.Action.swap), ("Even Out", .even),
                                ("Separate", .separate), ("Close Both", .closeBoth)] {
            let item = NSMenuItem(title: title, action: #selector(chose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
            if action == .even { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc private func chose(_ item: NSMenuItem) {
        guard let action = item.representedObject as? PaneStage.Action else { return }
        stage?.act(action)
    }

    // MARK: - VoiceOver

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
    override func accessibilityLabel() -> String? { "Divider between the pages" }
    override func accessibilityValue() -> Any? { Int(((stage?.currentShare ?? 0.5) * 100).rounded()) }
    override func accessibilityPerformIncrement() -> Bool {
        stage.map { $0.setShare($0.currentShare + 0.05) } != nil
    }
    override func accessibilityPerformDecrement() -> Bool {
        stage.map { $0.setShare($0.currentShare - 0.05) } != nil
    }
}

// MARK: - a page carried by its bar

struct PaneLift: Equatable {
    var carried: Tab.ID
    var shifts: [Tab.ID: CGFloat]
    var lifted: Bool
}

extension PaneStage {
    func lift(_ next: PaneLift?) {
        guard next != lifting else { return }
        let was = lifting
        lifting = next
        guard let next else {
            landing = was
            return
        }
        raised = true
        let starting = was == nil
        for (index, tab) in tabs.enumerated() where index < slots.count {
            let carried = tab.id == next.carried
            let scale = carried && next.lifted ? PaneShuffle.lift : 1
            let shift = next.shifts[tab.id] ?? 0
            let follows = carried && next.lifted
            let layers = liftLayers(index, carried: carried)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in layers { layer.zPosition = carried ? 3 : 0 }
            liftShadow?.zPosition = 2.9
            if carried, let page = shadows.indices.contains(index) && !shadows[index].isHidden ? shadows[index] : slots[index].layer,
               let shade = liftShadow {
                shade.bounds = page.bounds
                shade.position = CGPoint(x: page.position.x + (0.5 - page.anchorPoint.x) * page.bounds.width,
                                         y: page.position.y + (0.5 - page.anchorPoint.y) * page.bounds.height)
                shade.shadowPath = KitPath.continuous(shade.bounds, radius: max(corner, 6))
                shade.isHidden = false
            }
            CATransaction.commit()
            place(layers, pivot: pivot(index), shift: shift, scale: scale, animated: !follows || starting)
            if carried {
                ease(liftShadow, key: "shadowOpacity", to: next.lifted ? 0.34 : 0)
            }
            let dim: CGFloat = next.lifted && !carried ? 0.78 : 1
            if slots[index].alphaValue != dim {
                NSAnimationContext.kit(Motion.kitSlide) {
                    slots[index].animator().alphaValue = dim
                }
            }
        }
        let rule: CGFloat = next.lifted ? 0 : 1
        if divider.alphaValue != rule {
            NSAnimationContext.kit(Motion.kitQuick) {
                divider.animator().alphaValue = rule
            }
        }
    }

    private func liftLayers(_ index: Int, carried: Bool) -> [CALayer] {
        if carried, liftShadow == nil, let layer = pageFrame.layer {
            let shade = CALayer()
            shade.actions = ["bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "shadowPath": NSNull()]
            shade.shadowColor = NSColor.black.cgColor
            shade.shadowOpacity = 0
            shade.shadowRadius = 18
            shade.shadowOffset = CGSize(width: 0, height: 0)
            layer.addSublayer(shade)
            liftShadow = shade
        }
        var out: [CALayer] = [slots[index].layer, shadows.indices.contains(index) ? shadows[index] : nil,
                              cues.indices.contains(index) ? cues[index].layer : nil,
                              edges.indices.contains(index) ? edges[index].layer : nil].compactMap { $0 }
        if carried, let liftShadow { out.append(liftShadow) }
        return out
    }

    private func pivot(_ index: Int) -> CGPoint {
        guard let page = slots[index].layer else { return .zero }
        return CGPoint(x: page.position.x + (0.5 - page.anchorPoint.x) * page.bounds.width,
                       y: page.position.y + (0.5 - page.anchorPoint.y) * page.bounds.height)
    }

    private func place(_ layers: [CALayer], pivot: CGPoint, shift: CGFloat, scale: CGFloat, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            let anchor = layer.position
            let moved = CATransform3DScale(
                CATransform3DMakeTranslation(shift + (1 - scale) * (pivot.x - anchor.x), (1 - scale) * (pivot.y - anchor.y), 0),
                scale, scale, 1)
            let from = layer.presentation()?.transform ?? layer.transform
            layer.transform = moved
            guard animated, !Motion.reduced, !CATransform3DEqualToTransform(from, moved) else {
                layer.removeAnimation(forKey: "lift")
                continue
            }
            layer.add(PaneStage.slide("transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: moved)), forKey: "lift")
        }
        CATransaction.commit()
    }

    private func ease(_ layer: CALayer?, key: String, to value: Swift.Float) {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let from: Swift.Float = (layer.presentation() ?? layer).value(forKey: key) as? Swift.Float ?? 0
        layer.setValue(value, forKey: key)
        if !Motion.reduced, from != value {
            layer.add(PaneStage.slide(key, from: from, to: value), forKey: key)
        }
        CATransaction.commit()
    }

    private static func slide(_ key: String, from: Any, to: Any) -> CAAnimation {
        if Motion.light {
            let ease = CABasicAnimation(keyPath: key)
            ease.fromValue = from
            ease.toValue = to
            ease.duration = 0.16
            ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
            return ease
        }
        let spring = CASpringAnimation(keyPath: key)
        spring.mass = 1
        spring.stiffness = 1218
        spring.damping = 69.8
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    fileprivate func lower() {
        guard raised else { return }
        raised = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for index in slots.indices {
            for layer in liftLayers(index, carried: false) {
                layer.removeAnimation(forKey: "lift")
                layer.transform = CATransform3DIdentity
                layer.zPosition = 0
            }
            slots[index].alphaValue = 1
        }
        liftShadow?.removeAllAnimations()
        liftShadow?.shadowOpacity = 0
        liftShadow?.isHidden = true
        divider.alphaValue = 1
        CATransaction.commit()
    }

    fileprivate func land(_ lift: PaneLift, _ next: [Tab], split: TabSplit?, focused: Tab.ID?) {
        var before = placed()
        for (id, frame) in before { before[id] = frame.offsetBy(dx: lift.shifts[id] ?? 0, dy: 0) }
        let leaving = tabs.filter { before[$0.id] != nil }
        generation += 1
        let ticket = generation
        arriving = (next, split, focused, nil)
        capture(leaving) { [weak self] pictures in
            guard let self, ticket == self.generation else { return }
            let latest = self.arriving ?? (next, split, focused, nil)
            self.arriving = nil
            self.clearPictures()
            self.apply(latest.tabs, split: latest.split, focused: latest.focused, standIn: latest.standIn)
            self.layoutSubtreeIfNeeded()
            self.animate(.swap, from: before, pictures: pictures, travel: false, settle: 0.2)
        }
    }
}

// MARK: - moving, not jumping

extension PaneStage {
    enum Move: Equatable {
        /// A page coming in beside the one on screen.
        case enter(Tab.ID)
        /// One of two going, the other taking the room.
        case leave(Tab.ID)
        case swap
        /// The divider moved by itself: evened out, or from VoiceOver.
        case resize
    }

    /// What the change from what is shown to `tabs` is, to the eye; nil for
    /// a cut.
    fileprivate func motion(to next: [Tab], split next2: TabSplit?) -> Move? {
        let old = tabs.map(\.id), new = next.map(\.id)
        defer { dragged = false }
        guard bounds.width - PaneStage.gutter >= 2 * PaneStage.narrowest, immersedID == nil else { return nil }
        if old.count == 1, new.count == 2, new.contains(old[0]), let other = new.first(where: { $0 != old[0] }) {
            return .enter(other)
        }
        if old.count == 2, new.count == 1, old.contains(new[0]), let other = old.first(where: { $0 != new[0] }) {
            return .leave(other)
        }
        if old.count == 2, old == Array(new.reversed()) { return .swap }
        if old.count == 2, old == new, !dragged, let was = split, let now = next2, was.id == now.id,
           abs(was.fraction - now.fraction) > 0.001 {
            return .resize
        }
        return nil
    }

    /// Where each page on screen is now.
    fileprivate func placed() -> [Tab.ID: CGRect] {
        var out: [Tab.ID: CGRect] = [:]
        for (index, tab) in tabs.enumerated() where index < slots.count && !slots[index].isHidden {
            out[tab.id] = slots[index].frame
        }
        return out
    }

    /// Pictures of the pages on screen, as they are. WebKit takes them in a
    /// frame or so; one slower than a twentieth of a second, and the change
    /// is a cut instead of a wait. Under Reduce Motion they are still
    /// taken, for the dissolve. A test run makes the move anyway, with
    /// stand-ins for the pictures still to come: a page just arrived in a
    /// window on no screen can keep WebKit waiting for seconds, and so can
    /// a busy machine.
    fileprivate func capture(_ pages: [Tab], _ done: @escaping ([Tab.ID: NSImage]) -> Void) {
        var pictures: [Tab.ID: NSImage] = [:]
        var sizes: [Tab.ID: NSSize] = [:]
        var waiting = pages.count
        var finished = false
        func finish() {
            guard !finished else { return }
            finished = true
            done(pictures)
        }
        guard waiting > 0 else { return finish() }
        for tab in pages {
            guard let web = tab.built, web.window === window, !web.isHidden else {
                waiting -= 1
                if waiting == 0 { finish() }
                continue
            }
            let size = web.bounds.size
            sizes[tab.id] = size
            web.takeSnapshot(with: nil) { image, _ in
                MainActor.assumeIsolated {
                    // A test run's window is on no screen, and WebKit pictures
                    // nothing there: a plain stand-in, so what moves can
                    // still be followed (see Bench, split motion).
                    if let image { pictures[tab.id] = image }
                    else if Store.testing { pictures[tab.id] = PaneStage.standIn(size) }
                    waiting -= 1
                    if waiting == 0 { finish() }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if !finished {
                if Store.testing {
                    for (id, size) in sizes where pictures[id] == nil { pictures[id] = PaneStage.standIn(size) }
                } else {
                    pictures = [:]
                }
            }
            finish()
        }
    }

    private static func standIn(_ size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        Palette.NS.hairline.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// The pictures moved from where the pages were to where they are now,
    /// over pages already laid out at their new size — laid out once, never
    /// frame by frame — then faded to the live pages. Cropped, never
    /// squashed: a picture keeps its size and shows what fits.
    fileprivate func animate(_ move: Move, from before: [Tab.ID: CGRect], pictures: [Tab.ID: NSImage], travel: Bool = true, settle: TimeInterval = 0) {
        let after = placed()
        let reduced = Motion.reduced
        var moving: [(NSImageView, CGRect?)] = []
        for (id, image) in pictures {
            guard let start = before[id] else { continue }
            let view = NSImageView(frame: start)
            view.image = image
            view.imageScaling = .scaleNone
            view.imageAlignment = .alignTopLeft
            view.wantsLayer = true
            view.layer?.backgroundColor = look?.page(dark: kitDark).flat.cgColor ?? Palette.NS.ground.cgColor
            view.layer?.cornerRadius = separate ? corner : 0
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            pageFrame.addSubview(view)
            view.layer?.maskedCorners = start.minY < Metrics.paneBar ? Self.allCorners
                : Self.bottoms(flipped: view.layer?.contentsAreFlipped() ?? true)
            self.pictures.append(view)
            moving.append((view, after[id]))
        }
        motionLog = moving.map { view, end in (view, view.frame, end ?? view.frame) }
        // The page arriving comes up under the one making room for it.
        if case .enter(let id) = move, let index = tabs.firstIndex(where: { $0.id == id }), index < slots.count {
            let slot = slots[index]
            slot.alphaValue = 0
            NSAnimationContext.kit(reduced ? Motion.kitFade : Motion.kitSlide) {
                slot.animator().alphaValue = 1
            }
        }
        if case .enter = move, !divider.isHidden {
            divider.alphaValue = 0
            NSAnimationContext.kit(Motion.kitQuick) {
                divider.animator().alphaValue = 1
            }
        }
        let fade = { [weak self] in
            NSAnimationContext.kit(Motion.kitFade, {
                for (view, _) in moving { view.animator().alphaValue = 0 }
            }, done: { [weak self] in
                MainActor.assumeIsolated {
                    for (view, _) in moving { view.removeFromSuperview() }
                    self?.pictures.removeAll { view in moving.contains { $0.0 === view } }
                }
            })
        }
        // Under Reduce Motion nothing travels: the old pictures dissolve
        // into the new layout.
        guard !reduced, travel else {
            guard settle > 0 else { return fade() }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { fade() }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.pane
            context.timingFunction = Motion.paneTiming
            context.allowsImplicitAnimation = true
            for (view, end) in moving {
                if let end {
                    view.animator().frame = end
                } else {
                    // Leaving: a little smaller as it fades.
                    view.animator().frame = view.frame.insetBy(dx: view.frame.width * 0.01, dy: view.frame.height * 0.01)
                    view.animator().alphaValue = 0
                }
            }
        }, completionHandler: { MainActor.assumeIsolated { fade() } })
    }

    fileprivate func clearPictures() {
        for view in pictures { view.removeFromSuperview() }
        pictures.removeAll()
    }

    /// The pictures moving now, where each started and where it is going,
    /// and where it is this moment: for the bench.
    var motionNow: [[String: [Double]]] {
        motionLog.compactMap { view, start, end in
            guard view.superview != nil else { return nil }
            let now = view.layer?.presentation()?.frame ?? view.frame
            func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
            return ["from": box(start), "to": box(end), "now": box(now),
                    "radius": [Double(view.layer?.cornerRadius ?? 0)], "framed": [view.superview is PageFrame ? 1 : 0]]
        }
    }
}

/// The find bar's box over the page's corner is wider and taller than its
/// pill; a press where the pill isn't goes to the page under it, rather than
/// to the box, which would have kept the click or carried the window off.
extension PaneStage {
    static func rounds(_ view: NSView) -> String {
        guard let layer = view.layer, layer.cornerRadius > 0, let root = view.window?.contentView?.superview?.layer else { return "none" }
        let low = layer.convert(CGPoint(x: 0, y: layer.bounds.minY), to: root).y
        let high = layer.convert(CGPoint(x: 0, y: layer.bounds.maxY), to: root).y
        let up = (low > high) != root.contentsAreFlipped()
        let corners = layer.maskedCorners
        if corners == allCorners { return "all" }
        if corners == bottoms(flipped: up) { return "bottoms" }
        if corners == bottoms(flipped: !up) { return "tops" }
        return "other"
    }

    static func cards(in root: NSView) -> [String: Any] {
        func stage(in view: NSView) -> PaneStage? {
            if let found = view as? PaneStage { return found }
            for child in view.subviews { if let found = stage(in: child) { return found } }
            return nil
        }
        guard let stage = stage(in: root), let window = stage.window else { return [:] }
        func box(_ view: NSView) -> [Double] {
            let frame = view.convert(view.bounds, to: nil)
            return [frame.minX, window.contentLayoutRect.maxY - frame.maxY, frame.maxX, window.contentLayoutRect.maxY - frame.minY].map { Double($0) }
        }
        let shown = stage.slots.filter { !$0.isHidden && $0.bounds.width > 0 }
        return ["window": [Double(root.bounds.width), Double(root.bounds.height)],
                "apart": stage.separate, "masked": stage.pageFrame.layer?.masksToBounds == true, "pictures": stage.pictures.count,
                "radii": shown.map { Double($0.layer?.cornerRadius ?? 0) },
                "rounds": shown.map(rounds),
                "edge": Double(stage.edgeWidth), "groundDark": stage.groundDark, "corner": Double(stage.corner),
                "cards": shown.map(box),
                "pages": shown.compactMap { $0.subviews.first(where: { $0.alphaValue > 0 }) }.map(box)]
    }

    /// The account list's card and its host, in the window, from its
    /// top-left: for the bench, which asks whether the card hangs under the
    /// box it was drawn for.
    static func accountCard() -> (card: CGRect, host: CGRect)? {
        guard let host = AccountHost.shown, let window = host.window, !host.isHidden else { return nil }
        func top(_ r: CGRect) -> CGRect {
            let w = host.convert(r, to: nil)
            return CGRect(x: w.minX, y: window.frame.height - w.maxY, width: w.width, height: w.height)
        }
        return (top(host.card), top(host.bounds))
    }
}

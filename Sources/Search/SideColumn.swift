import AppKit
import Combine
import QuartzCore

final class SideColumnView: NSView {
    static var measured: [String: CGFloat] = [:]
    let browser: Browser
    var onFrame = false { didSet { if onFrame != oldValue { changed() } } }
    var floating = false { didSet { if floating != oldValue { changed() } } }
    var ground = RowGround() { didSet { if ground != oldValue { needsLayout = true } } }
    var baseDark = false { didSet { if baseDark != oldValue { needsLayout = true } } }
    var inksItself = false { didSet { if inksItself != oldValue { followInk() } } }
    var facesShown = true { didSet { agents.facesShown = facesShown } }

    private let back = KitPlate()
    private let hairline = KitPlate()
    private let wholeStrip = ColumnDragStrip()
    private let topStrip = ColumnDragStrip()
    private let footStrip = ColumnDragStrip()
    private let grip = ColumnEdgeGrip()
    private let pages: SidePagesView
    private let ride: RideView
    private let titles: SpaceTitlesView
    private let spaceFoot: SpaceFootView
    private let agents: AgentsAreaView
    private let address: SideAddressView
    private let mini: MiniPlayerView
    private let update: UpdateCardView
    private var updateWatch: AnyCancellable?
    private let helm: HelmView
    private let fetch: FetchDoorView
    private var stackedView: StackedColumnView?
    private var watch: AnyCancellable?
    private var started = false
    private var outerLook: NSKeyValueObservation?

    init(browser: Browser) {
        self.browser = browser
        pages = SidePagesView(browser: browser)
        ride = RideView(content: pages, motion: browser.spaceMotion)
        titles = SpaceTitlesView(browser: browser)
        spaceFoot = SpaceFootView(browser: browser)
        agents = AgentsAreaView(browser: browser)
        address = SideAddressView(browser: browser)
        mini = MiniPlayerView(mini: browser.mini)
        update = UpdateCardView(wait: Updates.shared.wait)
        helm = HelmView(browser: browser)
        fetch = FetchDoorView(browser: browser, fetches: browser.fetches)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        addSubview(back)
        addSubview(wholeStrip)
        addSubview(topStrip)
        addSubview(ride)
        addSubview(titles)
        addSubview(helm)
        addSubview(address)
        addSubview(footStrip)
        addSubview(agents)
        addSubview(mini)
        addSubview(update)
        addSubview(spaceFoot)
        addSubview(hairline)
        addSubview(grip)
        hairline.fill = .hairline
        wholeStrip.onDoubleClick = { [weak browser] in browser?.newTab() }
        wholeStrip.menuMaker = { [weak browser] in browser.map { PlusMenu.column(for: $0) } ?? NSMenu() }
        footStrip.onDoubleClick = wholeStrip.onDoubleClick
        footStrip.menuMaker = wholeStrip.menuMaker
        grip.prefs = browser.prefs
        grip.canClose = { [weak browser] in browser.map { !$0.folded } ?? false }
        grip.onClose = { [weak browser] width in browser?.closeColumnFromEdge(restoring: width) }
        pages.column = self
        address.ground = { [weak self] index in self?.ground(for: index) ?? RowGround() }
        spaceFoot.fetch = fetch
        update.onRestart = { [weak self] in Updates.shared.restart(over: self?.window) }
        followMini()
        registerForDraggedTypes(SidePageView.dropped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var livePage: SidePageView { pages.live }

    private var prefs: Preferences { browser.prefs }
    private var inset: CGFloat { Metrics.sideInset }
    private var strip: CGFloat { Metrics.strip }
    private var showsPill: Bool { prefs.addressBar }
    private var addressRoom: CGFloat { showsPill ? Metrics.sidePill - 3 + 8 : 0 }
    var columnHeight: CGFloat { max(40, (bounds.height / 40).rounded() * 40) }

    var footHeight: CGFloat {
        SpaceFootView.height + miniHeight + updateHeight + agentsHeight
    }

    private var miniHeight: CGFloat { mini.room }

    private var updateHeight: CGFloat {
        browser.isPrivate || browser.folded || !Updates.shared.wait.card ? 0 : UpdateCardView.foot
    }

    private func followMini() {
        mini.onRoom = { [weak self] in self?.changed() }
        agents.onRoom = { [weak self] in self?.changed() }
        updateWatch = kitObserve(initial: false, distinct: true, { [weak self] in self?.updateHeight ?? 0 }) { [weak self] _ in
            self?.changed()
        }
    }

    private var agentsHeight: CGFloat { agents.room }

    private func changed() {
        needsLayout = true
        pages.needsLayout = true
    }

    private func followInk() {
        guard inksItself else { return }
        let browser = browser
        watch = kitObserve(initial: false, { [weak browser] in (browser?.spaceNeighbour.revision, browser?.spaceMotion.crossing.past) }) {
            [weak self] _ in self?.needsLayout = true
        }
        lookOutside()
        needsLayout = true
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        lookOutside()
    }

    private func lookOutside() {
        outerLook = nil
        guard inksItself, let superview else { return }
        outerLook = superview.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.needsLayout = true } }
        }
    }

    private func reink() {
        guard inksItself else { return }
        let dark = superview?.kitDark ?? false
        let cards = browser.asCards
        let inkDark: Bool
        let made: RowGround
        if cards {
            let next = browser.spaceNext.flatMap { browser.spaces.indices.contains($0) ? browser.spaces[$0].look ?? SpaceLook() : SpaceLook() }
            let blend = LookBlend(from: browser.seenLook, to: next, share: next != nil && browser.spaceMotion.crossing.past ? 1 : 0)
            let rest = LookBlend(from: browser.makingSpace ? browser.draftLook : browser.space.look ?? SpaceLook())
            inkDark = blend.inkLight(dark: dark)
            let stops = rest.groundStops(dark: dark)
            made = RowGround(greys: KitGreys.frame.lit(by: stops), ink: KitInk(lift: blend.inkLift(dark: dark)), dark: inkDark, stops: stops)
        } else {
            inkDark = dark
            made = RowGround(greys: cards ? .frame : .white, ink: .flat, dark: dark, stops: nil)
        }
        onFrame = cards
        baseDark = dark
        let named: NSAppearance.Name = inkDark ? .darkAqua : .aqua
        if appearance?.name != named { appearance = NSAppearance(named: named) }
        if ground != made { ground = made }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if Store.testing { livePage.driveProbe() }
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        SpaceSwipe.shared.start(for: browser)
        browser.spacePages.browser = browser
        browser.spacePages.settle(after: 1)
    }

    override func layout() {
        let clock = CACurrentMediaTime()
        defer { FrameGaps.shared.note("column", from: clock) }
        super.layout()
        reink()
        let width = bounds.width
        let height = bounds.height
        let stacked = browser.stacked
        let clear = onFrame || floating
        back.fill = clear ? nil : .ground
        back.kitSetFrame(bounds)
        hairline.isHidden = clear
        let onRight = prefs.sidePosition == .right
        hairline.kitSetFrame(NSRect(x: onRight ? 0 : width - 1, y: 0, width: 1, height: height))
        grip.onRight = onRight
        grip.onFrame = onFrame
        grip.kitSetFrame(NSRect(x: onRight ? 0 : width - ColumnEdgeGrip.width, y: 0, width: ColumnEdgeGrip.width, height: height))

        titles.isHidden = stacked
        placeStacked(stacked)

        agents.column = columnHeight
        agents.aim(AgentsAreaView.height(of: browser, column: columnHeight))
        let foot = footHeight
        wholeStrip.isHidden = browser.makingSpace
        wholeStrip.kitSetFrame(bounds)
        let helmWidth = width - inset - Metrics.helmLights >= Metrics.helm ? Metrics.helm : Metrics.helmNarrow
        topStrip.kitSetFrame(NSRect(x: 0, y: 0, width: max(0, width - helmWidth), height: strip))
        footStrip.kitSetFrame(NSRect(x: 0, y: height - foot, width: width, height: browser.makingSpace ? 0 : foot))
        footStrip.isHidden = browser.makingSpace

        helm.greys = onFrame ? .frame : .white
        helm.ink = ground.ink
        helm.frame = NSRect(x: width - inset - helmWidth, y: 0, width: helmWidth, height: strip)
        fetch.ink = ground.ink
        var y = strip
        if !stacked {
            titles.ink = ground.ink
            titles.frame = NSRect(x: inset, y: y - SpaceTitleSize.lift, width: width - 2 * inset, height: SpaceTitleSize.height)
            y += SpaceTitleSize.room
        }
        address.isHidden = !showsPill
        let addressFrame = NSRect(x: inset, y: y - 3, width: width - 2 * inset, height: Metrics.sidePill)
        if address.frame != addressFrame { address.frame = addressFrame }
        y += addressRoom
        let pagesFrame = NSRect(x: 0, y: y, width: width, height: max(0, height - foot - y))
        if let stackedView {
            stackedView.onFrame = onFrame
            stackedView.floating = floating
            stackedView.ground = ground
            if stackedView.frame != pagesFrame { stackedView.frame = pagesFrame }
        } else {
            if ride.frame != pagesFrame { ride.frame = pagesFrame }
            pages.lay(width: prefs.columnWidth)
            ride.set(RideLook(here: pages.at))
        }
        let spotsHeight = SpaceFootView.height
        agents.column = columnHeight
        agents.ground = ground
        let agentsFrame = NSRect(x: 0, y: height - foot, width: width, height: agentsHeight)
        if agents.frame != agentsFrame { agents.frame = agentsFrame }
        mini.isHidden = miniHeight == 0
        mini.ink = ground.ink
        mini.greys = onFrame ? .frame : .white
        let miniFrame = NSRect(x: 0, y: agentsFrame.maxY, width: width, height: miniHeight)
        if mini.frame != miniFrame { mini.frame = miniFrame }
        mini.listBottom = pagesFrame.maxY
        update.ink = ground.ink
        update.greys = onFrame ? .frame : .white
        let updateFrame = NSRect(x: 0, y: miniFrame.maxY - UpdateCardView.closeOut, width: width, height: UpdateCardView.room)
        if updateHeight != 0, update.frame != updateFrame { update.frame = updateFrame }
        update.shown(updateHeight != 0)
        spaceFoot.ground = ground
        spaceFoot.frame = NSRect(x: 0, y: height - spotsHeight, width: width, height: spotsHeight)
    }

    func ground(for index: Int) -> RowGround {
        guard onFrame, browser.spaces.indices.contains(index) else { return ground }
        let look = browser.spaces[index].look ?? SpaceLook()
        let stops = look.ground(dark: baseDark).stops
        return RowGround(greys: KitGreys.frame.lit(by: stops), ink: KitInk(lift: look.inkLift(dark: baseDark)), dark: look.inkLight(dark: baseDark),
                         stops: stops)
    }

    private func placeStacked(_ stacked: Bool) {
        if stacked, stackedView == nil {
            ride.removeFromSuperview()
            let made = StackedColumnView(browser: browser)
            addSubview(made, positioned: .above, relativeTo: topStrip)
            stackedView = made
        } else if !stacked, let view = stackedView {
            view.removeFromSuperview()
            stackedView = nil
            addSubview(ride, positioned: .above, relativeTo: topStrip)
            if Store.testing { livePage.driveProbe() }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { livePage.draggingEntered(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { livePage.draggingUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { livePage.draggingExited(sender) }
    override func draggingEnded(_ sender: NSDraggingInfo) { livePage.draggingEnded(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { livePage.performDragOperation(sender) }
}

final class SidePagesView: NSView {
    let browser: Browser
    let live: SidePageView
    weak var column: SideColumnView?
    private var previews: [UUID: SidePageView] = [:]
    private(set) var at = 0
    private var lastLive: UUID?
    private var holdBack: CFTimeInterval = 0
    private var sparePages: [SidePageView] = []
    private static let newSpace = UUID()

    init(browser: Browser) {
        self.browser = browser
        live = SidePageView(browser: browser)
        super.init(frame: .zero)
        addSubview(live)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard browser.spaceNext == nil else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        let clock = CACurrentMediaTime()
        defer { FrameGaps.shared.note("pages", from: clock) }
        super.layout()
        lay(width: browser.prefs.columnWidth)
    }

    private struct Shown {
        let id: UUID
        let index: Int
    }

    private func shown(at: Int, seen: Int, next: Int?) -> [Shown] {
        let warm = browser.spacePages.warm
        var indices = [at - 1, at, at + 1]
        for index in [seen - 1, seen, seen + 1] + [next].compactMap({ $0 }) where !indices.contains(index) {
            indices.append(index)
        }
        return indices.compactMap { index in
            let wanted = index == at || index == next || index == seen
            if index == browser.spaces.count {
                return wanted ? Shown(id: Self.newSpace, index: index) : nil
            }
            guard browser.spaces.indices.contains(index) else { return nil }
            let id = browser.spaces[index].id
            return wanted || warm.contains(id) ? Shown(id: id, index: index) : nil
        }
    }

    private func ground(for index: Int) -> RowGround {
        column?.ground(for: index) ?? RowGround()
    }

    func lay(width: CGFloat) {
        at = browser.makingSpace ? browser.spaces.count : (browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0)
        let next = browser.spaceNext
        let seen = browser.spaceSeen
        let height = bounds.height
        var kept = Set<UUID>()
        var liveShown = false
        let now = CACurrentMediaTime()
        if let lastLive, lastLive != browser.spaceID {
            holdBack = now + 0.35
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.needsLayout = true }
        }
        lastLive = browser.spaceID
        let still = browser.spaceNext == nil && !SpaceSwipe.shared.touching && !browser.spaceMotion.moving
        for page in shown(at: at, seen: seen, next: next) {
            let x = SpaceLane.place(page.index, real: at, seen: seen, next: next) * width
            let covered = SpaceLane.covered(page.index, real: at, seen: seen, next: next)
            if page.id == Self.newSpace { continue }
            let isLive = page.id == browser.spaceID && browser.spacePages.adopted != page.id
            let frame = NSRect(x: x, y: 0, width: width, height: height)
            let pageGround = ground(for: page.index)
            if isLive {
                liveShown = true
                live.isHidden = covered
                live.onFrame = column?.onFrame ?? false
                live.floating = column?.floating ?? false
                live.ground = pageGround
                live.appearance = NSAppearance(named: pageGround.dark ? .darkAqua : .aqua)
                live.setLane(frame, shift: 0)
                continue
            }
            guard let row = browser.parked[page.id] ?? browser.spacePages.held[page.id] else { continue }
            let rest = browser.columnMemory.saved[page.id] ?? ColumnRest()
            let wanted = SidePreview(space: page.id, row: row, rest: rest)
            if previews[page.id] == nil, still, now < holdBack { continue }
            let view = previews[page.id] ?? {
                if let spare = sparePages.popLast() {
                    spare.preview = wanted
                    previews[page.id] = spare
                    return spare
                }
                let made = SidePageView(browser: browser, preview: wanted)
                previews[page.id] = made
                addSubview(made, positioned: .below, relativeTo: live)
                return made
            }()
            view.preview = wanted
            view.isHidden = covered
            view.onFrame = column?.onFrame ?? false
            view.floating = column?.floating ?? false
            view.ground = pageGround
            view.appearance = NSAppearance(named: pageGround.dark ? .darkAqua : .aqua)
            view.setLane(NSRect(x: 0, y: 0, width: width, height: height), shift: x)
            kept.insert(page.id)
        }
        live.isHidden = live.isHidden || !liveShown
        let warm = browser.spacePages.warm.union([browser.spaceID])
        for (id, view) in previews where !kept.contains(id) {
            if warm.contains(id) {
                view.isHidden = true
                continue
            }
            previews[id] = nil
            view.isHidden = true
            if sparePages.count < 3 {
                sparePages.append(view)
            } else {
                view.removeFromSuperview()
                view.giveRowsBack()
            }
        }
        if Store.testing, let window, let content = window.contentView {
            let frame = convert(bounds, to: content)
            ColumnEdges.seen["pagesMinX"] = frame.minX
            ColumnEdges.seen["pagesMaxX"] = frame.maxX
        }
    }
}

final class ColumnEdgeGrip: NSView {
    static let width: CGFloat = 9
    weak var prefs: Preferences?
    var onRight = false { didSet { needsLayout = true } }
    var onFrame = false { didSet { needsLayout = true } }
    private let pill = CALayer()
    private var over = false { didSet { if over != oldValue { shine() } } }
    private var grabbed: CGFloat?
    private var start: NSPoint = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        pill.cornerCurve = .continuous
        pill.cornerRadius = Grip.width / 2
        pill.opacity = 0
        layer?.addSublayer(pill)
        layer?.masksToBounds = false
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    private func place(animated: Bool) {
        let lit = over || grabbed != nil
        let length = lit ? Grip.lit : Grip.rest
        let shift: CGFloat = onFrame ? 0 : onRight ? -4 : 4
        CATransaction.begin()
        CATransaction.setDisableActions(!animated || Motion.reduced)
        CATransaction.setAnimationDuration(Grip.fade)
        pill.bounds = CGRect(x: 0, y: 0, width: Grip.width, height: length)
        pill.position = CGPoint(x: bounds.midX + shift, y: bounds.midY)
        pill.opacity = lit ? 1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = (lit ? Palette.NS.muted : Palette.NS.faint).cgColor
        }
        CATransaction.commit()
    }

    private func shine() { place(animated: true) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        place(animated: false)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { over = true }
    override func mouseExited(with event: NSEvent) { over = false }

    static let closeZone: CGFloat = 60
    static let closeFloor: CGFloat = Metrics.sideMin - closeZone

    var canClose: () -> Bool = { false }
    var onClose: ((CGFloat) -> Void)?
    private(set) var closing = false

    static func step(from grabbed: CGFloat, pulled: CGFloat, canClose: Bool) -> (width: CGFloat, closes: Bool) {
        let wanted = grabbed + pulled
        let line = Metrics.sideMin - closeZone
        guard canClose, wanted < line else { return (min(Metrics.sideMax, max(Metrics.sideMin, wanted)), false) }
        return (max(closeFloor, Metrics.sideMin - (line - wanted) / 2), true)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            KitChange.eased { prefs?.sideWidth = Metrics.side }
            return
        }
        begin(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        pull(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        letGo()
    }

    func begin(at point: NSPoint) {
        grabbed = prefs?.sideWidth
        start = point
        closing = false
        shine()
    }

    func pull(to point: NSPoint) {
        guard let prefs, let grabbed else { return }
        let dx = point.x - start.x
        let step = ColumnEdgeGrip.step(from: grabbed, pulled: onRight ? -dx : dx, canClose: canClose())
        closing = step.closes
        prefs.sideWidth = step.width
    }

    func letGo() {
        let before = grabbed
        grabbed = nil
        if closing, let before {
            closing = false
            onClose?(before)
        }
        shine()
    }
}

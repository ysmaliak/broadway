import AppKit
import QuartzCore

final class ColumnDragStrip: NSView {
    var below: CGFloat = 0
    var onDoubleClick: (() -> Void)?
    var menuMaker: (() -> NSMenu)?

    private var pressed: NSEvent?
    private var moved = false
    private var over = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? { menuMaker?() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        guard inside.y >= below else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hover(convert(event.locationInWindow, from: nil).y >= below) }
    override func mouseMoved(with event: NSEvent) { hover(convert(event.locationInWindow, from: nil).y >= below) }
    override func mouseExited(with event: NSEvent) { hover(false) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        hover(false)
        super.viewWillMove(toWindow: newWindow)
    }

    private func hover(_ on: Bool) {
        guard let window, on != over else { return }
        over = on
        WindowHold.hover(window, on)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let pressed, !moved else { return }
        let dx = event.locationInWindow.x - pressed.locationInWindow.x
        let dy = event.locationInWindow.y - pressed.locationInWindow.y
        if abs(dx) < 3 && abs(dy) < 3 { return }
        moved = true
        window.isMovable = true
        window.performDrag(with: pressed)
        window.isMovable = !WindowHold.held(window)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window, !moved, event.clickCount == 2 else { return }
        if let onDoubleClick {
            onDoubleClick()
            return
        }
        WindowHold.doubleClick(window)
    }
}

final class SideClipView: NSClipView {
    var pinned = false { didSet { if pinned, bounds.origin != .zero { super.setBoundsOrigin(.zero) } } }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var made = super.constrainBoundsRect(proposedBounds)
        made.origin.x = 0
        if pinned { made.origin.y = 0 }
        return made
    }

    override func scroll(to newOrigin: NSPoint) {
        super.scroll(to: NSPoint(x: 0, y: pinned ? 0 : newOrigin.y))
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        super.setBoundsOrigin(NSPoint(x: 0, y: pinned ? 0 : newOrigin.y))
    }
}

final class SideScrollView: NSScrollView {
    var scrolls = true

    var nested = false {
        didSet {
            guard nested != oldValue else { return }
            hasVerticalScroller = !nested
            verticalScrollElasticity = nested ? .none : .allowed
            (contentView as? SideClipView)?.pinned = nested
        }
    }

    override var scrollerStyle: NSScroller.Style {
        get { .overlay }
        set { super.scrollerStyle = .overlay }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        contentView = SideClipView()
        scrollerStyle = .overlay
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        verticalScrollElasticity = .allowed
        horizontalScrollElasticity = .none
        contentView.drawsBackground = false
        contentView.wantsLayer = true
        automaticallyAdjustsContentInsets = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func scrollWheel(with event: NSEvent) {
        guard scrolls, !nested, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) || event.phase != [] else {
            nextResponder?.scrollWheel(with: event)
            return
        }
        if scrolls && !nested { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }

    override func tile() {
        super.tile()
        if let scroller = verticalScroller {
            var frame = scroller.frame
            let knob = scroller.rect(for: .knob)
            let lead = knob.width > 0 ? knob.minX : frame.width - 7
            frame.origin.x = bounds.width - Metrics.sideInset - lead
            if knob.width > 0 { frame.origin.x = min(frame.origin.x, bounds.width - knob.maxX) }
            scroller.frame = frame
        }
    }
}

final class SideDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

enum SideKey: Hashable {
    case row(UUID)
    case heading(UUID)
    case card(UUID)
    case task(UUID)
    case taskCard(UUID)
    case note(UUID)
    case divider(Int)
    case newTab
}

final class SidePageView: NSView, HoverColumnSpace, TabRowHost {
    let browser: Browser
    var onFrame = false { didSet { if onFrame != oldValue { needsLayout = true } } }
    var floating = false { didSet { if floating != oldValue { needsLayout = true } } }
    var ground = RowGround() { didSet { if ground != oldValue { needsLayout = true } } }

    private let strip = ColumnDragStrip()
    private let pinsView = SideDocumentView()
    private let raisedDivider = KitPlate(fill: KitTone(base: Palette.NS.sideRule, kind: .stronger(0.8)))
    private let listScroll = SideScrollView()
    private let listClip = SideListClipView()
    private let listMask = CALayer()
    private let listDocument = SideDocumentView()
    private let listReader = ColumnScrollReaderView()
    private let held: QuietRowView
    private let heldGround = KitPlate()
    private let topLine = KitPlate(fill: KitTone(base: Palette.NS.sideEdge, kind: .stronger(0.8)))
    private let bottomLine = KitPlate(fill: KitTone(base: Palette.NS.sideRule, kind: .stronger(0.8)))
    private var newTabTop: QuietRowView

    private var rows: [UUID: TabRowView] = [:]
    private var pins: [UUID: PinSquareView] = [:]
    private var headings: [UUID: GroupHeadingView] = [:]
    private var tasks: [UUID: TaskFolderHeadingView] = [:]
    private var cards: [SideKey: KitPlate] = [:]
    private var notes: [UUID: NSView] = [:]
    private var mores: [UUID: NSView] = [:]
    private var seenMores = Set<UUID>()
    private var ghost: LiveGhostView?
    fileprivate var fillingFrom: (id: UUID, frame: NSRect)?
    private var splitRows: [UUID: (view: NSView, right: UUID)] = [:]
    private var seenSplits = Set<UUID>()
    private var dividers: [Int: KitPlate] = [:]
    private lazy var reads = KitReads(now: true) { [weak self] in self?.changed() }
    private var arranging = false
    private var arrangingScene: SideScene?
    var preview: SidePreview? {
        didSet {
            if preview?.signature != oldValue?.signature || preview?.rest.list != oldValue?.rest.list { needsLayout = true }
        }
    }
    var embedded = false {
        didSet {
            guard embedded != oldValue else { return }
            listScroll.nested = embedded
            listReader.memory = embedded ? nil : (preview == nil ? browser.columnMemory : nil)
            needsLayout = true
        }
    }
    var onHeight: ((CGFloat) -> Void)?
    var onReveal: ((NSRect) -> Void)?
    var outside: ((Tab, CGPoint?, Bool) -> Bool)?
    private(set) var naturalHeight: CGFloat = 0
    private var animateNext = false
    private var lastWidth: CGFloat = 0
    private var animating = false
    private var lastSpace: UUID?
    private var lastShut: Set<UUID>?
    private var openedNow: Set<UUID> = []
    fileprivate var closedNow: Set<UUID> = []
    fileprivate var cardsBefore: [UUID: NSRect] = [:]
    fileprivate var lights: [UUID: FolderLightView] = [:]
    fileprivate var reclaimedLift: [UUID: CGFloat] = [:]
    private var cardsShown: [UUID: (frame: NSRect, speed: Double)] = [:]
    private var settle: KitCurve = Motion.kitSettle
    private var lastActive: UUID?
    fileprivate var givenBack = 0
    fileprivate var carry: SideCarry?
    fileprivate var pending: (view: NSView, at: NSPoint)?
    fileprivate var laid: [UUID: SideLaid] = [:]
    fileprivate var laidBefore: [UUID: SideLaid] = [:]
    fileprivate var hoveredCard: UUID?
    fileprivate var headingFrames: [UUID: NSRect] = [:]
    fileprivate var cardFrames: [UUID: NSRect] = [:]
    fileprivate var leaving: [UUID: TabRowView] = [:]
    fileprivate var reclaimed: [UUID: Swift.Float] = [:]
    fileprivate var leaves = 0
    fileprivate var raisedPlaces: [(id: UUID, rect: CGRect)] = []
    fileprivate var itemPlaces: [(item: Browser.ListItem, rect: CGRect)] = []
    fileprivate var itemDocs: [(item: Browser.ListItem, rect: CGRect)] = []
    fileprivate var headingDocs: [UUID: (parent: NSView?, rect: NSRect)] = [:]
    fileprivate var cardDocs: [UUID: (parent: NSView?, rect: NSRect)] = [:]
    fileprivate var raisedDocs: [CGRect] = []
    fileprivate var listTopNow: CGFloat = 0
    fileprivate let landingGround = KitPlate()
    fileprivate let folderLine = KitPlate(radius: 1)
    fileprivate var looseOrder: [UUID] = []
    var dropOn: GroupDropTarget? { didSet { if dropOn != oldValue { showDrop(); relightCards(animated: false) } } }
    var looseOn: LoosePlace? { didSet { if looseOn != oldValue { showDrop() } } }
    fileprivate var joining: UUID? { didSet { if joining != oldValue { showJoin(); showDrop() } } }
    fileprivate let spring = FolderSpring()
    fileprivate let hold = FolderHold()
    fileprivate let dropOutline = KitPlate(radius: Metrics.folderRadius)
    fileprivate let dropLine = KitPlate(radius: 1)
    fileprivate let joinOutline = KitPlate(radius: Metrics.sideRadius)
    fileprivate var pinStart: NSRect?
    var crossing: PinDrop.Crossing? { didSet { if crossing != oldValue { animateNext = true; needsLayout = true; showDrop() } } }
    var morphView: PinMorphView?
    var morphCarried: UUID?
    var swallowRelease = false
    var morphArrived: UUID?
    var hand = SideHand()
    var gridRect: NSRect?
    var gapRect: NSRect?
    var looseTop: CGFloat?
    var rowsRect: NSRect = .zero
    var flights = 0
    var frozen: (row: CGRect, tile: CGRect)?
    private var fits = true
    private var listViewport: CGFloat = 0
    private var listContent: CGFloat = 0

    init(browser: Browser, preview: SidePreview? = nil) {
        self.browser = browser
        self.preview = preview
        held = QuietRowView(icon: "plus", title: "New Tab", act: {})
        newTabTop = QuietRowView(icon: "plus", title: "New Tab", act: {})
        super.init(frame: .zero)
        wantsLayer = true
        held.act = { [weak browser] in browser?.launch() }
        newTabTop.act = { [weak browser] in browser?.launch() }
        held.setAccessibilityIdentifier("column-new-tab")
        landingGround.isHidden = true
        addSubview(landingGround)
        addSubview(strip)
        strip.onDoubleClick = { [weak browser] in browser?.newTab() }
        strip.menuMaker = { [weak browser] in browser.map { PlusMenu.column(for: $0) } ?? NSMenu() }
        addSubview(pinsView)
        listScroll.documentView = listDocument
        listDocument.addSubview(listReader)
        raisedDivider.isHidden = true
        listDocument.addSubview(raisedDivider)
        listScroll.clipsToBounds = false
        listScroll.contentView.clipsToBounds = false
        listClip.wantsLayer = true
        listMask.backgroundColor = NSColor.black.cgColor
        listClip.layer?.mask = listMask
        listClip.addSubview(listScroll)
        addSubview(listClip)
        addSubview(heldGround)
        addSubview(held)
        topLine.isHidden = true
        bottomLine.isHidden = true
        addSubview(topLine)
        addSubview(bottomLine)
        listDocument.addSubview(newTabTop)
        folderLine.isHidden = true
        for plate in [dropOutline, dropLine, joinOutline, folderLine] {
            plate.isHidden = true
            addSubview(plate)
        }
        dropOutline.strokeWidth = SideLook.dropRingWidth
        joinOutline.strokeWidth = 1.5
        listReader.part = .list
        listReader.memory = preview == nil ? browser.columnMemory : nil
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: listScroll.contentView)
        listScroll.contentView.postsBoundsChangedNotifications = true
        guard preview == nil else {
            strip.isHidden = true
            return
        }
        registerForDraggedTypes(Self.dropped)
        if Store.testing && !embedded { driveProbe() }
    }

    func driveProbe() {
        PinDragProbe.shared.drive = { [weak self] id, point, ended in self?.probe(id, point, ended: ended) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard preview == nil else { return }
        if window == nil {
            guard browser.pinFlightOwner === self else { return }
            browser.pinFlight = nil
            browser.pinFlightOwner = nil
            return
        }
        browser.pinFlight = { [weak self] tab, change in
            guard let self, self.morphCarried == nil else { return false }
            if Motion.reduced, self.crossing == nil, self.browser.tabs.contains(where: { $0.id == tab.id }) {
                change()
                return true
            }
            return self.flyPin(tab, change)
        }
        browser.pinFlightOwner = self
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    var drawnTabs: [Tab.ID] { scene.tabs.filter { rows[$0.id] != nil && $0.pin == nil }.map(\.id) }

    var listOffset: CGFloat { listScroll.contentView.bounds.minY }

    var veiled: Tab.ID? {
        didSet {
            guard veiled != oldValue else { return }
            for id in [oldValue, veiled].compactMap({ $0 }) {
                let shown: CGFloat = id == veiled || id == morphCarried ? 0 : 1
                rows[id]?.alphaValue = shown
                pins[id]?.alphaValue = shown
            }
        }
    }

    var heldShade: CGFloat = 1 {
        didSet {
            guard heldShade != oldValue else { return }
            held.alphaValue = heldShade
            heldGround.alphaValue = heldShade
        }
    }

    func frame(of id: Tab.ID) -> NSRect? {
        if let pin = pins[id], pin.superview != nil { return pin.convert(pin.bounds, to: self) }
        if let row = rows[id], let parent = row.superview { return parent.convert(row.frame, to: self) }
        return nil
    }

    func pickTargets() -> [(tab: Tab, frame: NSRect, radius: CGFloat)] {
        var out: [(tab: Tab, frame: NSRect, radius: CGFloat)] = []
        for tab in scene.tabs {
            if let pin = pins[tab.id], !pin.isHidden, pin.superview != nil {
                out.append((tab, pin.convert(pin.bounds, to: self), Metrics.pinRadius))
            } else if let row = rows[tab.id], !row.isHidden, row.alphaValue > 0, let parent = row.superview {
                out.append((tab, parent.convert(row.frame, to: self), row.state.radius))
            }
        }
        return out
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        preview == nil ? super.hitTest(point) : nil
    }

    override func accessibilityChildren() -> [Any]? {
        preview == nil ? super.accessibilityChildren() : []
    }

    private func showPreviewRest() {
        guard let preview else { return }
        let clip = listScroll.contentView
        let target = NSRect(origin: NSPoint(x: clip.bounds.minX, y: preview.rest.list), size: clip.bounds.size)
        let origin = clip.constrainBoundsRect(target).origin
        guard abs(origin.y - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(to: origin)
        listScroll.reflectScrolledClipView(clip)
    }

    private func changed() {
        animateNext = true
        needsLayout = true
    }

    private var rested = false

    private func restIn(viewport: CGFloat) {
        guard !rested, window != nil, viewport > 0 else { return }
        rested = true
        guard !browser.columnMemory.restoring, browser.spaceNext == nil, !browser.makingSpace,
              let rest = browser.columnMemory.saved[browser.spaceID], rest.list > 0.5 else { return }
        let clip = listScroll.contentView
        let target = NSRect(origin: NSPoint(x: clip.bounds.minX, y: rest.list), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        listScroll.reflectScrolledClipView(clip)
    }

    @objc private func scrolled() {
        guard preview == nil else { return edges() }
        guard rested, browser.spaceNext == nil, !browser.makingSpace else { clipList(); return edges() }
        browser.columnMemory.note(.list, value: listScroll.contentView.bounds.minY, in: browser.spaceID)
        placeHeld()
        edges()
        settleHover()
        noteBench()
    }

    func giveRowsBack() {
        let given = rows.values
        rows = [:]
        for view in given {
            view.recycle()
            view.removeFromSuperview()
        }
    }

    func noteBench() {
        guard Store.testing, preview == nil else { return }
        for view in rows.values { view.noteBench() }
        for view in pins.values { view.noteBench() }
    }

    private var prefs: Preferences { browser.prefs }
    private var rowHeight: CGFloat { prefs.sideRow }
    private static let gap = Metrics.sideGap
    private static let inset = Metrics.sideInset
    private static let indent: CGFloat = 16
    static let cardLead = SideLook.cardRowInset - Metrics.folderPad

    private var scene: SideScene {
        if let arrangingScene { return arrangingScene }
        if let preview { return SideScene.parked(preview.row, prefs: prefs) }
        return SideScene.live(browser)
    }

    private var topFolders: [TabGroup] { scene.tops }
    private var listFolders: [TabGroup] { scene.listFolders }
    private var looseTabs: [Tab] { scene.loose }
    private var listItems: [Browser.ListItem] { scene.items }

    private func noteHeight(_ group: TabGroup) -> CGFloat {
        let note = group.live && !group.collapsed && LiveFolders.shared.folder(group.id)?.note != nil ? rowHeight + Self.gap : 0
        return note + moreHeight(group)
    }

    private func showsMore(_ group: TabGroup) -> Bool {
        preview == nil && group.live && !group.collapsed && LiveFolders.shared.folder(group.id)?.more != nil
    }

    private func moreHeight(_ group: TabGroup) -> CGFloat {
        showsMore(group) ? rowHeight + Self.gap : 0
    }

    private func folderHeight(_ group: TabGroup, depth: Int) -> CGFloat {
        let scene = scene
        let children = group.collapsed ? [] : scene.groups.filter { $0.parent == group.id }
        var total = GroupHeadingView.height + (depth == 0 ? 2 * Metrics.folderPad : 0) + noteHeight(group)
        total += children.reduce(0) { $0 + folderHeight($1, depth: depth + 1) + Self.gap }
        total += CGFloat(scene.visible(group).filter { !leaving($0) }.count) * (rowHeight + Self.gap)
        return total
    }

    private func taskHeight(_ folder: TaskFolder) -> CGFloat {
        GroupHeadingView.height + 2 * Metrics.folderPad + (folder.folded ? 0 : CGFloat(folder.tabs.count) * (rowHeight + Self.gap))
    }

    private var ghostOffer: LiveOffer? {
        guard prefs.usesTabGroups, !(embedded && preview != nil), let offer = LiveOffers.shared.offer(for: browser),
              offer.space == preview?.space ?? browser.spaceID else { return nil }
        return offer
    }

    private var ghostHeight: CGFloat? {
        ghostOffer.map { LiveGhostView.height($0, width: bounds.width - 2 * Self.inset) }
    }

    private var pinnedHeight: CGFloat {
        let tops = topFolders
        var blocks: [(air: SideAir, height: CGFloat)] = tops.map { (.folder, folderHeight($0, depth: 0)) }
        if let ghostHeight { blocks.append((.folder, ghostHeight)) }
        guard !blocks.isEmpty else { return 0 }
        return SideAir.span(blocks)
    }

    private var listHeight: CGFloat {
        let scene = scene
        let tops = topFolders
        var blocks: [(air: SideAir, height: CGFloat)] = tops.map { (.folder, folderHeight($0, depth: 0)) }
        if let ghostHeight { blocks.append((.folder, ghostHeight)) }
        if !blocks.isEmpty { blocks.append((.divider, 1)) }
        blocks += scene.tasks.map { (.folder, taskHeight($0)) }
        if !scene.tasks.isEmpty { blocks.append((.divider, 1)) }
        for item in listItems {
            switch item {
            case .folder(let id): if let group = scene.group(id) { blocks.append((.folder, folderHeight(group, depth: 0))) }
            case .tab: blocks.append((.row, rowHeight))
            }
        }
        return rowHeight + Self.gap + 8 + SideAir.span(blocks)
    }

    private var blankLeads: Bool { looseTabs.contains(where: \.isBlank) }
    private var newTabBelow: Bool { prefs.newTabsAtBottom && !blankLeads }
    private var heldLead = Metrics.sideGap
    private var heldRoom: CGFloat { newTabBelow ? rowHeight + heldLead : 0 }
    var heldRoomNow: CGFloat { heldRoom }

    private func runOrder(_ tabs: [Tab]) -> [UUID] {
        let splits = scene.splits
        return tabs.map { tab in prefs.splitView && splits.contains(where: { $0.contains(tab.id) }) ? RowRun.apart : tab.id }
    }

    private func rowState(_ tab: Tab, order: [UUID], lit: Set<UUID>, numbers: [UUID: Int], carded: Bool = false) -> RowState {
        let real = preview == nil
        let live = tab.id == scene.active
        let editing = real && browser.editingTab == tab.id
        let peek = real && !editing && tab.pin != nil && browser.peekFrom == tab.id ? browser.peekTab : nil
        var state = RowState()
        state.live = live
        state.editing = editing
        state.peek = peek.map(ObjectIdentifier.init)
        state.interactive = real
        state.picked = lit.contains(tab.id)
        state.join = RowRun.join(tab.id, in: order, lit: lit)
        state.before = live && real ? browser.pageBefore : nil
        state.refusals = real ? browser.refusals : 0
        state.number = numbers[tab.id]
        state.height = rowHeight
        state.radius = carded ? SideLook.cardRowRadius : Metrics.sideRadius
        state.carded = carded
        state.titleSize = prefs.sideTitle
        state.ground = ground
        state.hoverCards = prefs.hoverCards
        state.splitView = prefs.splitView
        state.icons = prefs.glyph == .icons
        state.showsAddress = prefs.showsAddress
        state.floatingNewTab = prefs.floatingNewTab
        state.addressBar = prefs.addressBar
        state.tabsGive = prefs.tabsGive
        state.nextMeeting = prefs.nextMeeting
        return state
    }

    private func pinState(_ tab: Tab, lit: Set<UUID>, numbers: [UUID: Int]) -> RowState {
        var state = RowState()
        let real = preview == nil
        state.live = tab.id == scene.active || (prefs.splitView && tab.pin != nil
            && scene.splits.contains { $0.left == tab.id && scene.active.map($0.contains) == true })
        state.interactive = real
        state.editing = real && browser.editingPin == tab.id
        state.peek = real && browser.peekFrom == tab.id ? browser.peekTab.map(ObjectIdentifier.init) : nil
        state.picked = lit.contains(tab.id)
        state.before = state.live && real ? browser.pageBefore : nil
        state.number = numbers[tab.id]
        state.height = rowHeight
        state.ground = ground
        state.hoverCards = prefs.hoverCards
        state.icons = prefs.glyph == .icons
        state.tabsGive = prefs.tabsGive
        state.nextMeeting = prefs.nextMeeting
        return state
    }

    private func pinCells(_ count: Int) -> [CGRect] {
        PinPlaces.cells(count, room: bounds.width - 2 * Self.inset)
    }

    override func layout() {
        reads.track { layoutNow() }
        settleHover()
    }

    private func layoutNow() {
        let clock = CACurrentMediaTime()
        defer { FrameGaps.shared.note(preview == nil ? (embedded ? "page.embedded" : "page.live") : "page.preview", from: clock) }
        super.layout()
        if isHidden, preview == nil, !embedded, window != nil {
            waitingToShow = true
            return
        }
        arrange()
    }

    private func settleHover() {
        guard preview == nil, carry == nil, !isHidden else { return }
        for view in rows.values { view.settleHover() }
        for view in pins.values { view.settleHover() }
    }

    private var waitingToShow = false

    override func viewDidUnhide() {
        super.viewDidUnhide()
        guard waitingToShow else { return }
        waitingToShow = false
        needsLayout = true
    }

    private func arrange() {
        guard !arranging, bounds.width > 0 else { return }
        arranging = true
        defer { arranging = false }
        let width = bounds.width
        let inner = width - 2 * Self.inset
        animating = animateNext && width == lastWidth && !browser.columnMemory.restoring && window != nil && Motion.kitSettle.animates
            && browser.spaceID == lastSpace && preview == nil
        animateNext = false
        lastWidth = width
        lastSpace = browser.spaceID
        let shut = Set(browser.tabGroups.filter(\.collapsed).map(\.id)).union(browser.taskFolders.filter(\.folded).map(\.id))
        settle = animating && lastShut != nil && shut != lastShut ? Motion.kitCover : Motion.kitSettle
        openedNow = (lastShut ?? []).subtracting(shut)
        closedNow = lastShut.map { shut.subtracting($0) } ?? []
        lastShut = shut
        let before = laid
        laidBefore = before
        laid = [:]
        seenSplits = []
        headingFrames = [:]
        headingDocs = [:]
        cardDocs = [:]
        var cardsBefore = cardFrames
        self.cardsBefore = cardsBefore
        cardsShown = [:]
        if animating {
            for (id, model) in cardsBefore { cardsShown[id] = shownCard(id, model: model) }
        }
        cardFrames = [:]
        raisedPlaces = []
        itemPlaces = []
        raisedDocs = []
        itemDocs = []
        let made = preview.map { SideScene.parked($0.row, prefs: prefs) } ?? SideScene.live(browser)
        arrangingScene = made
        if !animating {
            let present = Set(made.tabs.map(\.id))
            for (id, view) in rows where !present.contains(id) && id != morphCarried && carry?.tab.id != id {
                rows[id] = nil
                view.recycle()
            }
        }
        defer { arrangingScene = nil }
        let lit = made.lit
        let numbers = made.numbers
        gapRect = nil
        var seenRows = Set<UUID>()
        var seenHeadings = Set<UUID>()
        var seenTasks = Set<UUID>()
        var seenCards = Set<SideKey>()
        var seenNotes = Set<UUID>()
        seenMores = []
        var seenDividers = Set<Int>()

        let squares = made.pins
        var y: CGFloat = 0
        var seenPins = Set<UUID>()
        var ghostSquare: Int?
        if case .squares(let at)? = crossing?.target { ghostSquare = at }
        gridRect = nil
        if !squares.isEmpty || ghostSquare != nil {
            let all = pinCells(squares.count + (ghostSquare == nil ? 0 : 1))
            let cells = ghostSquare.map { open in all.indices.filter { $0 != open }.map { all[$0] } } ?? all
            if let ghostSquare, all.indices.contains(ghostSquare) {
                gapRect = all[ghostSquare].offsetBy(dx: Self.inset, dy: 0)
            }
            let block = (all.map(\.maxY).max() ?? 0)
            gridRect = NSRect(x: Self.inset, y: 0, width: inner, height: block)
            pinsView.isHidden = false
            pinsView.kitSetFrame(NSRect(x: Self.inset, y: 0, width: inner, height: block))
            for (index, tab) in squares.enumerated() {
                let view = pins[tab.id] ?? {
                    let made = PinSquareView()
                    made.host = self
                    pins[tab.id] = made
                    pinsView.addSubview(made)
                    return made
                }()
                view.alphaValue = morphCarried == tab.id || veiled == tab.id ? 0 : 1
                if carry?.tab.id != tab.id { put(view, cells[index]) }
                laid[tab.id] = SideLaid(frame: cells[index], parent: pinsView, block: .pins, index: index, count: squares.count)
                view.show(tab, in: browser, state: pinState(tab, lit: lit, numbers: numbers))
                view.close = { [weak browser, weak tab] in if let browser, let tab { browser.closeAsking(tab) } }
                seenPins.insert(tab.id)
            }
            y = block + SideLook.pinsFoot
        } else {
            pinsView.isHidden = true
        }
        for (id, view) in pins where !seenPins.contains(id) {
            view.forget()
            if id == morphCarried { view.removeFromSuperview() } else { retire(view) }
            pins[id] = nil
        }

        let whole = bounds.height - y
        let tops = topFolders
        let pinned = pinnedHeight
        let list = listHeight

        let listTop = y
        listTopNow = y
        let floor = bounds.height - ColumnEdges.clear
        var viewport = max(0, floor - listTop)
        var at: CGFloat = 0
        var flow = SideFlow()
        var blocks: [(kind: String, rect: CGRect)] = []
        func lead(_ air: SideAir) {
            at += flow.take(air)
        }
        var dividerIndex = 0
        func divider() {
            lead(.divider)
            let plate = dividers[dividerIndex] ?? {
                let made = KitPlate(fill: KitTone(base: Palette.NS.sideRule, kind: .stronger(0.8)))
                dividers[dividerIndex] = made
                listDocument.addSubview(made)
                return made
            }()
            plate.ink = ground.ink
            put(plate, NSRect(x: Self.inset + SideLook.ruleInset, y: at, width: inner - 2 * SideLook.ruleInset, height: 1))
            blocks.append(("divider", NSRect(x: Self.inset, y: at, width: inner, height: 1)))
            seenDividers.insert(dividerIndex)
            dividerIndex += 1
            at += 1
        }
        let offered = ghostOffer
        fillingFrom = nil
        if offered == nil, let view = ghost {
            ghost = nil
            if animating, !view.filling, let id = LiveOffers.shared.filled(in: browser), tops.contains(where: { $0.id == id }) {
                fillingFrom = (id, view.frame)
                cardsBefore[id] = convert(view.frame, from: listDocument)
                self.cardsBefore[id] = cardsBefore[id]
                view.fill()
            } else if view.filling {
                view.removeFromSuperview()
            } else {
                retire(view)
            }
        }
        for group in tops {
            lead(.folder)
            let height = card(group, depth: 0, x: Self.inset, y: at, width: inner, into: listDocument, lit: lit, numbers: numbers,
                              rows: &seenRows, headings: &seenHeadings, cards: &seenCards, notes: &seenNotes)
            let rect = NSRect(x: Self.inset, y: at, width: inner, height: height)
            raisedPlaces.append((group.id, listDocument.convert(rect, to: self)))
            raisedDocs.append(rect)
            blocks.append(("folder", rect))
            at += height
        }
        fillingFrom = nil
        if let offered {
            lead(.folder)
            let view = ghost ?? {
                let made = LiveGhostView(browser: browser)
                ghost = made
                return made
            }()
            if view.superview !== listDocument { listDocument.addSubview(view) }
            view.interactive = preview == nil
            SideSigns.update(view, colour: .ink, ground: ground)
            view.show(offered)
            let height = LiveGhostView.height(offered, width: inner)
            let rect = NSRect(x: Self.inset, y: at, width: inner, height: height)
            put(view, rect)
            blocks.append(("ghost", rect))
            at += height
        }
        raisedDivider.isHidden = tops.isEmpty && offered == nil
        if !tops.isEmpty || offered != nil {
            lead(.divider)
            raisedDivider.ink = ground.ink
            put(raisedDivider, NSRect(x: Self.inset + SideLook.ruleInset, y: at, width: inner - 2 * SideLook.ruleInset, height: 1))
            blocks.append(("divider", NSRect(x: Self.inset, y: at, width: inner, height: 1)))
            at += 1
        }
        let folders = made.tasks
        for folder in folders {
            lead(.folder)
            let height = taskCard(folder, x: Self.inset, y: at, width: inner, lit: lit, numbers: numbers,
                                  rows: &seenRows, tasks: &seenTasks, cards: &seenCards)
            blocks.append(("folder", NSRect(x: Self.inset, y: at, width: inner, height: height)))
            at += height
        }
        if !folders.isEmpty { divider() }
        let topNew = !blankLeads && !prefs.newTabsAtBottom
        newTabTop.isHidden = !topNew
        if topNew {
            lead(.row)
            styleNew(newTabTop)
            put(newTabTop, NSRect(x: Self.inset, y: at, width: inner, height: rowHeight))
            blocks.append(("row", NSRect(x: Self.inset, y: at, width: inner, height: rowHeight)))
            at += rowHeight
        }
        let loose = looseTabs
        let items = listItems
        let places = Dictionary(uniqueKeysWithValues: loose.enumerated().map { ($1.id, $0) })
        let runs = Dictionary(uniqueKeysWithValues: zip(loose.map(\.id), runOrder(loose)))
        let order = items.map { item -> UUID in
            if case .tab(let id) = item { runs[id] ?? RowRun.apart } else { RowRun.apart }
        }
        let ghostRow: Int? = nil
        looseTop = items.isEmpty && ghostRow == nil ? nil : listDocument.convert(NSPoint(x: 0, y: at + flow.lead(.row)), to: self).y
        func gap() {
            lead(.row)
            gapRect = listDocument.convert(NSRect(x: Self.inset, y: at, width: inner, height: rowHeight), to: self)
            at += rowHeight
        }
        for item in items {
            switch item {
            case .folder(let id):
                guard let group = made.group(id) else { continue }
                lead(.folder)
                let height = card(group, depth: 0, x: Self.inset, y: at, width: inner, into: listDocument, lit: lit, numbers: numbers,
                                  rows: &seenRows, headings: &seenHeadings, cards: &seenCards, notes: &seenNotes)
                let rect = NSRect(x: Self.inset, y: at, width: inner, height: height)
                itemPlaces.append((item, listDocument.convert(rect, to: self)))
                itemDocs.append((item, rect))
                blocks.append(("folder", rect))
                at += height
            case .tab(let id):
                guard let index = places[id] else { continue }
                if ghostRow == index { gap() }
                let tab = loose[index]
                let frame = NSRect(x: Self.inset, y: at + flow.lead(.row), width: inner, height: rowHeight)
                row(tab, frame: frame, into: listDocument,
                    state: rowState(tab, order: order, lit: lit, numbers: numbers), close: { [weak browser] in browser?.closeTab(tab) })
                laid[tab.id] = SideLaid(frame: frame, parent: listDocument, block: .loose, index: index, count: loose.count)
                if !leaving(tab) {
                    itemPlaces.append((item, listDocument.convert(frame, to: self)))
                    itemDocs.append((item, frame))
                }
                seenRows.insert(tab.id)
                if leaving(tab) {
                    rows[tab.id]?.alphaValue = 0
                } else {
                    lead(.row)
                    blocks.append(("row", frame))
                    at += rowHeight
                }
            }
        }
        if let ghostRow, ghostRow >= loose.count { gap() }
        looseOrder = loose.map(\.id)
        let rowsEnd = at
        heldLead = flow.last == nil ? Self.gap : flow.lead(.row)
        noteBlocks(blocks)
        let content = rowsEnd + heldRoom
        if embedded { viewport = content }
        rowsRect = listDocument.convert(NSRect(x: Self.inset, y: 0, width: inner, height: max(rowsEnd, rowHeight)), to: self)

        for (id, held) in splitRows where !seenSplits.contains(id) {
            retire(held.view)
            splitRows[id] = nil
        }
        if animating { dropOpened(before: before, cards: cardsBefore) }
        var foldClips: [UUID: (view: SideFoldClip, velocity: Double)] = [:]
        for (id, view) in rows where !seenRows.contains(id) {
            view.forget()
            if id == morphCarried {
                view.removeFromSuperview()
            } else if let clip = foldClip(before[id], view: view, cards: cardsBefore, clips: &foldClips) {
                leaving[id] = view
                retire(view, covered: true, drift: clip.drift, velocity: clip.velocity, shift: clip.shift, leaving: id)
            } else {
                let rise = stackFolded(id) ? Self.foldRise : foldRise(before[id])
                retire(view, rise: rise, fade: rise > 0 ? 0.08 : 0.14)
            }
            rows[id] = nil
        }
        if animating { capKeptRows() }
        for (id, view) in headings where !seenHeadings.contains(id) {
            browser.hoverCards.leave(.folder(id))
            retire(view)
            headings[id] = nil
        }
        for (id, view) in tasks where !seenTasks.contains(id) {
            retire(view)
            tasks[id] = nil
        }
        for (key, view) in cards where !seenCards.contains(key) {
            dissolve(view, onto: key, before: before)
            cards[key] = nil
            if case .card(let id) = key, let light = lights.removeValue(forKey: id) { retire(light) }
        }
        for (id, view) in notes where !seenNotes.contains(id) {
            retire(view)
            notes[id] = nil
        }
        for (id, view) in mores where !seenMores.contains(id) {
            retire(view)
            mores[id] = nil
        }
        for (index, view) in dividers where !seenDividers.contains(index) {
            retire(view)
            dividers[index] = nil
        }

        let now = max(list, content) <= viewport
        fits = now
        listViewport = viewport
        listContent = content
        listScroll.scrolls = !embedded && (!now || preview == nil)
        put(listScroll, NSRect(x: 0, y: listTop, width: width, height: viewport))
        let keptRoom = carry.flatMap { lifted($0.tab) ? $0.room : nil } ?? 0
        let documentHeight = preview == nil && !embedded ? max(content, viewport, keptRoom) : content
        let clip = listScroll.contentView
        let offset = clip.bounds.minY
        let target = max(0, documentHeight - viewport)
        if listDocument.frame.size != CGSize(width: width, height: documentHeight) {
            listDocument.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        }
        if animating, offset > target + 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            listScroll.reflectScrolledClipView(clip)
            giveBack(offset - clip.bounds.minY)
        }
        listReader.frame = listDocument.bounds
        listReader.viewport = viewport
        if embedded {
            let natural = listTop + viewport
            if abs(natural - naturalHeight) > 0.5 {
                naturalHeight = natural
                let report = onHeight
                DispatchQueue.main.async { report?(natural) }
            }
        }
        if preview != nil || embedded {
            rowsBottom = listTop + rowsEnd
            held.isHidden = !newTabBelow
            heldGround.isHidden = !newTabBelow
            if newTabBelow { styleNew(held) }
            if preview != nil { showPreviewRest() }
            placeHeld(moving: animating)
            edges()
            strip.below = bounds.height
            if preview == nil {
                let active = browser.activeSplit?.left ?? browser.activeID
                if active != lastActive {
                    let had = lastActive != nil
                    lastActive = active
                    if had, let active { DispatchQueue.main.async { [weak self] in self?.reveal(active) } }
                }
            }
            return
        }
        listReader.memory = browser.columnMemory
        let rest = browser.columnMemory.restoring ? browser.columnMemory.landing : browser.columnMemory.saved[browser.spaceID] ?? ColumnRest()
        if listReader.destination?.0 != browser.columnMemory.generation {
            listReader.destination = browser.columnMemory.generation.map { ($0, rest.list) }
        }
        listReader.connect()
        rowsBottom = listTop + rowsEnd
        held.isHidden = !newTabBelow
        heldGround.isHidden = !newTabBelow
        if newTabBelow { styleNew(held) }
        placeHeld(moving: animating)
        edges()
        restIn(viewport: viewport)

        let active = browser.activeSplit?.left ?? browser.activeID
        if active != lastActive {
            let had = lastActive != nil
            lastActive = active
            if had, let active, !now, !browser.columnMemory.restoring {
                DispatchQueue.main.async { [weak self] in self?.reveal(active) }
            }
        }
        strip.kitSetFrame(bounds)
        landingGround.kitSetFrame(bounds)
        landingGround.fill = ground.greys.hover
        folderLine.fill = ground.greys.dot
        folderLine.ink = ground.ink
        strip.below = fits ? listTop + rowsEnd + heldRoom : bounds.height
        if Store.testing {
            DispatchQueue.main.async { [weak self] in self?.noteBench() }
            SideColumnView.measured = ["room": viewport, "needed": list, "drawn": content, "fits": now ? 1 : 0,
                                "whole": whole, "pinned": pinned]
        }
    }

    private var rowsBottom: CGFloat = 0

    private(set) var blocksNow: [(kind: String, rect: CGRect)] = []

    private func noteBlocks(_ blocks: [(kind: String, rect: CGRect)]) {
        blocksNow = blocks
        guard Store.testing, preview == nil, !embedded, let content = window?.contentView else { return }
        SidePageView.benchBlocks = blocks.map { block in
            let rect = listDocument.convert(block.rect, to: content)
            let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
            return ["kind": block.kind, "x": Double(rect.minX), "y": Double(top), "w": Double(rect.width), "h": Double(rect.height)]
        }
    }

    static var benchBlocks: [[String: Any]] = []
    static var benchLine: [String: Double]?
    static var benchDrop: [String: Any] = [:]

    private func put(_ view: NSView, _ frame: NSRect, rise: CGFloat = 0) {
        let snapped = view.kitSnapped(frame)
        guard view.frame != snapped else { return }
        if animating, view.frame == .zero {
            enter(view, snapped, rise: rise)
            return
        }
        guard animating, let layer = view.layer else {
            view.frame = snapped
            return
        }
        let from = layer.presentation()?.position ?? layer.position
        let fromSize = layer.presentation()?.bounds.size ?? layer.bounds.size
        view.frame = snapped
        let to = layer.position
        let (start, end) = (NSValue(point: from), NSValue(point: to))
        if from != to, let animation = settle.animation("position", from: start, to: end,
                                                                   velocity: layer.kitCarry("position", from: start, to: end)) {
            animation.fillMode = .backwards
            layer.add(animation, forKey: "position")
            if abs(to.y - from.y) > rowHeight * 1.5 { ride(layer, for: animation.duration) }
        }
        let (small, large) = (NSValue(size: fromSize), NSValue(size: layer.bounds.size))
        if fromSize != layer.bounds.size,
           let animation = settle.animation("bounds.size", from: small, to: large,
                                                      velocity: layer.kitCarry("bounds.size", from: small, to: large)) {
            animation.fillMode = .backwards
            layer.add(animation, forKey: "bounds.size")
        }
    }

    private func ride(_ layer: CALayer, for duration: CFTimeInterval) {
        layer.zPosition = 1
        let landing = CACurrentMediaTime() + duration
        layer.setValue(landing, forKey: "rideLands")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak layer] in
            guard let layer, let lands = layer.value(forKey: "rideLands") as? CFTimeInterval, lands <= landing else { return }
            layer.zPosition = 0
        }
    }

    private(set) var heldFloored = false
    private var clipTurn = 0
    private var crossed: (top: Bool, bottom: Bool) = (false, false)
    var heldFloor: CGFloat? { didSet { if heldFloor != oldValue { placeHeld() } } }
    var heldFrame: NSRect? { newTabBelow && !held.isHidden ? held.frame : nil }

    func reclip() {
        listClip.layer?.mask = SelectedLook.unclipped ? nil : listMask
        clipList()
    }

    private func clipList(moving: Bool = false) {
        if listClip.frame != bounds { listClip.frame = bounds }
        let list = listScroll.frame
        let offset = listScroll.contentView.bounds.minY
        let floored = newTabBelow && (heldFloored || moving)
        let resting = offset <= 0.5
        let ended = !floored && offset + listViewport >= listContent - 0.5
        let hair = 1 / max(1, window?.backingScaleFactor ?? 2)
        let cuts = Self.cuts(offset: offset, viewport: listViewport, content: listContent)
        let crossing = crossingNow()
        crossed = crossing
        let cutTop = cuts.top || crossing.top
        let cutBottom = cuts.bottom || crossing.bottom
        let top = list.minY - (resting && !cutTop ? SelectedLook.room : 0) + (cutTop ? hair : 0)
        let bottom = (floored ? held.frame.minY - Self.gap : list.maxY) + (ended && !cutBottom ? SelectedLook.room : 0) - (cutBottom ? hair : 0)
        let shown = listMask.presentation() ?? listMask
        let from = (shown.position, shown.bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        listMask.frame = CGRect(x: -4000, y: top, width: bounds.width + 8000, height: max(0, bottom - top))
        if moving, from.1 != listMask.bounds || from.0 != listMask.position {
            for (key, was, now) in [("position", NSValue(point: from.0), NSValue(point: listMask.position)),
                                    ("bounds", NSValue(rect: from.1), NSValue(rect: listMask.bounds))] {
                guard let animation = settle.animation(key, from: was, to: now,
                                                                 velocity: listMask.kitCarry(key, from: was, to: now)) else { continue }
                animation.fillMode = .backwards
                listMask.add(animation, forKey: key)
            }
        }
        CATransaction.commit()
        clipTurn += 1
        guard moving, floored, !heldFloored else { return }
        let turn = clipTurn
        let lands = settle.animation("opacity", from: 0, to: 1)?.duration ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + lands + 0.02) { [weak self] in
            guard let self, self.clipTurn == turn else { return }
            self.clipList()
        }
    }

    private func placeHeld(moving: Bool = false) {
        defer { clipList(moving: moving) }
        guard newTabBelow else { heldFloored = false; return }
        let width = bounds.width
        let offset = listScroll.contentView.bounds.minY
        let natural = listScroll.frame.minY + (rowsBottom - listScroll.frame.minY) - offset + heldLead
        let floor: CGFloat
        if embedded {
            floor = heldFloor.map { $0 - rowHeight } ?? .infinity
        } else {
            floor = listScroll.frame.maxY - rowHeight
        }
        let top = embedded && floor < listTopNow ? natural : min(natural, floor)
        heldFloored = natural > top + 0.5
        let frame = NSRect(x: Self.inset, y: top, width: width - 2 * Self.inset, height: rowHeight)
        let groundFrame = NSRect(x: 0, y: top - Self.gap, width: width, height: rowHeight + Self.gap)
        if moving {
            put(held, frame)
            put(heldGround, groundFrame)
        } else {
            held.kitSetFrame(frame)
            heldGround.kitSetFrame(groundFrame)
        }
        heldGround.fill = seeThrough || onFrame || floating ? nil : .ground
        if Store.testing, preview == nil, !embedded, let window, let content = window.contentView {
            let frame = held.convert(held.bounds, to: content)
            let y = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
            ColumnEdges.seen["newTabX"] = frame.minX
            ColumnEdges.seen["newTabY"] = y
            ColumnEdges.seen["newTabW"] = frame.width
            ColumnEdges.seen["newTabH"] = frame.height
        }
    }

    private var seeThrough: Bool {
        let id = preview?.space ?? browser.spaceID
        let look = browser.spaces.first { $0.id == id }?.look
        return (onFrame || floating) && (look?.showsThrough ?? false) && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    static func cuts(offset: CGFloat, viewport: CGFloat, content: CGFloat) -> (top: Bool, bottom: Bool) {
        (offset > 1, offset + viewport < content - 1)
    }

    private func edges() {
        let offset = listScroll.contentView.bounds.minY
        let scale = window?.backingScaleFactor ?? 2
        let hair = 1 / max(1, scale)
        let cuts = Self.cuts(offset: offset, viewport: listViewport, content: listContent)
        let crossing = crossingNow()
        crossed = crossing
        let top = cuts.top || crossing.top
        let bottomEdge = cuts.bottom || crossing.bottom
        topLine.kitEdge(top)
        bottomLine.kitEdge(bottomEdge)
        topLine.ink = ground.ink
        bottomLine.ink = ground.ink
        topLine.kitSetFrame(NSRect(x: 0, y: listScroll.frame.minY, width: bounds.width, height: hair))
        let floored = newTabBelow && (heldFloored || !crossing.bottom || cuts.bottom)
        let lineY = floored ? held.frame.minY - Self.gap - hair : listScroll.frame.maxY - hair
        bottomLine.kitSetFrame(NSRect(x: 0, y: lineY, width: bounds.width, height: hair))
        reportEdges(top: top, bottom: bottomEdge)
    }

    static func crossing(_ rects: [CGRect], top: CGFloat, bottom: CGFloat) -> (top: Bool, bottom: Bool) {
        (rects.contains { $0.minY < top - 1 }, rects.contains { $0.maxY > bottom + 1 })
    }

    fileprivate func crossingNow() -> (top: Bool, bottom: Bool) {
        guard preview == nil, !embedded else { return (false, false) }
        var rects: [CGRect] = []
        if let carry, lifted(carry.tab), crossing == nil, let morphView, morphView.alphaValue > 0.05 {
            rects.append(morphView.frame)
        } else if let carry, let view = carry.view, view.superview === listDocument, view.alphaValue > 0.05 {
            rects.append(listDocument.convert(view.frame, to: self))
        }
        if !dropOutline.isHidden { rects.append(dropOutline.frame) }
        let bottom = newTabBelow && heldFloored ? held.frame.minY - Self.gap : listScroll.frame.maxY
        return Self.crossing(rects, top: listScroll.frame.minY, bottom: bottom)
    }

    fileprivate func recheckEdges() {
        let now = crossingNow()
        guard now != crossed else { return }
        clipList()
        edges()
    }

    private func reportEdges(top: Bool, bottom: Bool) {
        guard Store.testing, preview == nil, !embedded, !isHiddenOrHasHiddenAncestor, let content = window?.contentView else { return }
        let line = bottomLine.convert(bottomLine.bounds, to: content)
        let offset = listScroll.contentView.bounds.minY
        var seen = ColumnEdges.seen
        seen["top"] = top ? 1 : 0
        seen["bottom"] = bottom ? 1 : 0
        seen["newTabHeld"] = newTabBelow && heldFloored ? 1 : 0
        seen["lineY"] = content.isFlipped ? line.maxY : content.bounds.height - line.minY
        let names = ["offsetY", "contentH", "containerH", "insetTop", "insetBottom", "visibleMinY", "visibleMaxY"]
        let numbers = [offset, listContent, listScroll.frame.height, 0, listScroll.contentInsets.bottom, offset, offset + listViewport]
        for (name, value) in zip(names, numbers) { seen[name] = value }
        ColumnEdges.seen = seen
    }

    private func styleNew(_ view: QuietRowView) {
        view.height = rowHeight
        view.size = prefs.sideTitle
        view.greys = ground.greys
        view.ink = ground.ink
    }

    private func row(_ tab: Tab, frame: NSRect, into parent: NSView, state: RowState, rise: CGFloat = 0,
                     stack: StackFoldButton.Dress? = nil, close: @escaping () -> Void) {
        let fades = animating && laidBefore[tab.id] != nil
        if prefs.splitView, let pair = scene.splits.first(where: { $0.left == tab.id }),
           let right = scene.tabs.first(where: { $0.id == pair.right }) {
            if let old = rows.removeValue(forKey: tab.id) {
                old.forget()
                old.removeFromSuperview()
            }
            var held = splitRows[tab.id]
            if held?.right != right.id {
                held?.view.removeFromSuperview()
                held = (SideSigns.split(browser: browser, left: tab, right: right, height: rowHeight), right.id)
                splitRows[tab.id] = held
            }
            guard let view = held?.view else { return }
            if view.superview !== parent { parent.addSubview(view) }
            SideSigns.update(view, colour: .ink, ground: ground)
            (view as? SplitSignView)?.item.radius = state.radius
            put(view, frame, rise: rise)
            StackFoldButton.dress(view, stack, lit: false, fades: fades)
            seenSplits.insert(tab.id)
            return
        }
        let view = rows[tab.id] ?? reclaim(tab.id, into: parent) ?? {
            let made = TabRowView.take(in: parent)
            made.host = self
            rows[tab.id] = made
            return made
        }()
        if view.superview !== parent { parent.addSubview(view) }
        view.alphaValue = morphCarried == tab.id || veiled == tab.id ? 0 : 1
        if carry?.tab.id != tab.id { put(view, frame, rise: rise) }
        view.close = close
        view.show(tab, in: browser, state: state)
        view.settleFromPool()
        StackFoldButton.dress(view, stack, lit: view.isHovering, fades: fades)
    }

    private func card(_ group: TabGroup, depth: Int, x: CGFloat, y: CGFloat, width: CGFloat, into parent: NSView,
                      lit: Set<UUID>, numbers: [UUID: Int], rows seenRows: inout Set<UUID>, headings seenHeadings: inout Set<UUID>,
                      cards seenCards: inout Set<SideKey>, notes seenNotes: inout Set<UUID>) -> CGFloat {
        let filled = depth == 0
        let pad = filled ? Metrics.folderPad : 0
        let indent = CGFloat(depth) * Self.indent + Self.cardLead
        let height = folderHeight(group, depth: depth)
        let rise = headings[group.id] == nil ? 0 : Self.foldRise
        var seeded = false
        if filled {
            let key = SideKey.card(group.id)
            let plate = cards[key] ?? {
                let made = KitPlate(radius: Metrics.folderRadius)
                made.hairline = true
                cards[key] = made
                return made
            }()
            if plate.superview !== parent { parent.addSubview(plate, positioned: .below, relativeTo: nil) }
            paintCard(plate, group.id, animated: false)
            plate.ink = ground.ink
            if let from = fillingFrom, from.id == group.id, plate.frame == .zero {
                plate.frame = plate.kitSnapped(from.frame)
                if let layer = plate.layer,
                   let fade = KitCurve.easeOut(SideLook.growFade).animation("opacity", from: Swift.Float(0), to: layer.opacity) {
                    fade.fillMode = .backwards
                    layer.add(fade, forKey: "enter.opacity")
                }
            }
            seeded = seed(plate, for: group, x: x, width: width)
            put(plate, NSRect(x: x, y: y, width: width, height: height))
            seenCards.insert(key)
            let light = lights[group.id] ?? {
                let made = FolderLightView()
                lights[group.id] = made
                return made
            }()
            let order = parent.subviews
            if light.superview !== parent || order.firstIndex(of: light) != order.firstIndex(of: plate).map({ $0 + 1 }) {
                parent.addSubview(light, positioned: .above, relativeTo: plate)
            }
            if Store.testing, preview == nil { FoldTrace.track(card: plate, for: group.id) }
        }
        cardFrames[group.id] = parent.convert(NSRect(x: x, y: y, width: width, height: height), to: self)
        cardDocs[group.id] = (parent, NSRect(x: x, y: y, width: width, height: height))
        let inner = width - 2 * pad
        var at = y + pad
        let heading = headings[group.id] ?? {
            let made = GroupHeadingView()
            headings[group.id] = made
            return made
        }()
        if heading.superview !== parent { parent.addSubview(heading) }
        heading.depth = depth
        heading.flat = filled
        heading.onHover = filled ? { [weak self] on in self?.hoverCard(group.id, on) } : nil
        heading.greys = ground.greys
        heading.ink = ground.ink
        heading.hoverCards = prefs.hoverCards
        heading.number = numbers[group.id]
        heading.count = tally(group.id)
        heading.curve = animating ? settle : .none
        heading.progress = group.collapsed ? 0 : 1
        heading.show(group, in: browser)
        let headingLead = depth == 0 ? 0 : Self.cardLead
        let headingFrame = NSRect(x: x + pad + headingLead, y: at, width: inner - headingLead, height: GroupHeadingView.height)
        if fillingFrom?.id == group.id, heading.frame == .zero { heading.frame = heading.kitSnapped(headingFrame) }
        put(heading, headingFrame)
        if filled, let light = lights[group.id] {
            placeLight(light, group, card: NSRect(x: x, y: y, width: width, height: height), heading: headingFrame)
        }
        if seeded, let layer = heading.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = layer.opacity
            fade.beginTime = CACurrentMediaTime() + SideLook.growLag
            fade.duration = SideLook.headingFade
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.fillMode = .backwards
            layer.add(fade, forKey: "enter.opacity")
        }
        if Store.testing, preview == nil { FoldTrace.track(heading: heading, for: group.id) }
        headingFrames[group.id] = parent.convert(headingFrame, to: self)
        headingDocs[group.id] = (parent, headingFrame)
        seenHeadings.insert(group.id)
        at += GroupHeadingView.height
        if !group.collapsed {
            for child in scene.groups where child.parent == group.id {
                at += Self.gap
                let childHeight = card(child, depth: depth + 1, x: x + pad, y: at, width: inner, into: parent, lit: lit, numbers: numbers,
                                       rows: &seenRows, headings: &seenHeadings, cards: &seenCards, notes: &seenNotes)
                at += childHeight
            }
            if group.live, LiveFolders.shared.folder(group.id)?.note != nil {
                at += Self.gap
                let note = notes[group.id] ?? SideSigns.liveNote(browser: browser, id: group.id, height: rowHeight, interactive: true)
                if notes[group.id] == nil { notes[group.id] = note }
                if note.superview !== parent { parent.addSubview(note) }
                SideSigns.update(note, colour: .ink, ground: ground)
                put(note, NSRect(x: x + pad + indent, y: at, width: inner - indent, height: rowHeight))
                seenNotes.insert(group.id)
                at += rowHeight
            }
        }
        let members = scene.visible(group)
        let order = runOrder(members)
        let stackTops = !group.live ? [:] : preview == nil ? browser.stackTops(in: group)
            : Browser.stackTops(scene.tabs.filter { $0.pin == nil && $0.groupID == group.id }, in: group)
        for (index, tab) in members.enumerated() {
            at += Self.gap
            let frame = NSRect(x: x + pad + indent, y: at, width: inner - indent, height: rowHeight)
            let state = rowState(tab, order: order, lit: lit, numbers: numbers, carded: true)
            let id = tab.id, folder = group.id
            let stack = leaving(tab) ? nil : stackTops[tab.id].map { folded in
                StackFoldButton.Dress(folded: folded) { [weak browser] in browser?.toggleStack(id, in: folder) }
            }
            row(tab, frame: frame, into: parent, state: state, rise: rise, stack: stack, close: { [weak browser] in browser?.closeAsking(tab) })
            laid[tab.id] = SideLaid(frame: frame, parent: parent, block: .folder(group.id), index: index, count: members.count)
            seenRows.insert(tab.id)
            if leaving(tab) { rows[tab.id]?.alphaValue = 0; at -= rowHeight + Self.gap }
            at += rowHeight
        }
        if showsMore(group) {
            at += Self.gap
            let more = mores[group.id] ?? SideSigns.liveMore(browser: browser, id: group.id)
            if mores[group.id] == nil { mores[group.id] = more }
            if more.superview !== parent { parent.addSubview(more) }
            SideSigns.update(more, colour: .ink, ground: ground)
            put(more, NSRect(x: x + pad + indent, y: at, width: inner - indent, height: rowHeight))
            seenMores.insert(group.id)
            at += rowHeight
        }
        return height
    }

    private func taskCard(_ folder: TaskFolder, x: CGFloat, y: CGFloat, width: CGFloat, lit: Set<UUID>, numbers: [UUID: Int],
                          rows seenRows: inout Set<UUID>, tasks seenTasks: inout Set<UUID>, cards seenCards: inout Set<SideKey>) -> CGFloat {
        let height = taskHeight(folder)
        let rise = tasks[folder.id] == nil ? 0 : Self.foldRise
        let key = SideKey.taskCard(folder.id)
        let plate = cards[key] ?? {
            let made = KitPlate(radius: Metrics.folderRadius)
            made.hairline = true
            cards[key] = made
            listDocument.addSubview(made, positioned: .below, relativeTo: nil)
            return made
        }()
        ground.greys.card(plate)
        plate.ink = ground.ink
        put(plate, NSRect(x: x, y: y, width: width, height: height))
        seenCards.insert(key)
        let pad = Metrics.folderPad
        let heading = tasks[folder.id] ?? {
            let made = TaskFolderHeadingView()
            tasks[folder.id] = made
            listDocument.addSubview(made)
            return made
        }()
        heading.ink = ground.ink
        heading.curve = animating ? settle : .none
        heading.progress = folder.folded ? 0 : 1
        heading.show(folder, in: browser)
        put(heading, NSRect(x: x + pad, y: y + pad, width: width - 2 * pad, height: GroupHeadingView.height))
        seenTasks.insert(folder.id)
        var at = y + pad + GroupHeadingView.height
        if !folder.folded {
            let order = runOrder(folder.tabs)
            for (index, tab) in folder.tabs.enumerated() {
                at += Self.gap
                let frame = NSRect(x: x + pad + Self.cardLead, y: at, width: width - 2 * pad - Self.cardLead, height: rowHeight)
                row(tab, frame: frame, into: listDocument, state: rowState(tab, order: order, lit: lit, numbers: numbers, carded: true), rise: rise,
                    close: { [weak browser] in browser?.closeTab(tab) })
                laid[tab.id] = SideLaid(frame: frame, parent: listDocument, block: .task(folder.id), index: index,
                                        count: folder.tabs.count)
                seenRows.insert(tab.id)
                at += rowHeight
            }
        }
        return height
    }

    func rowHovered(_ row: NSView, _ over: Bool) {
        StackFoldButton.on(row)?.lit = over
    }

    func rowMenu(_ row: NSView, event: NSEvent) -> NSMenu? {
        if let row = row as? TabRowView, let tab = row.tab {
            return TabMenuItems.menu(browser: browser, tab: tab, close: { [weak browser] in browser?.closeTab(tab) })
        }
        if let pin = row as? PinSquareView, let lead = pin.tab {
            let tab = browser.pinTarget(lead)
            return TabMenuItems.menu(browser: browser, tab: tab, close: { [weak browser] in browser?.closeAsking(tab) })
        }
        return nil
    }
}

enum SideBlock: Equatable {
    case loose
    case folder(UUID)
    case task(UUID)
    case pins
}

struct SideLaid {
    let frame: NSRect
    weak var parent: NSView?
    let block: SideBlock
    let index: Int
    let count: Int
}

struct SideCarry {
    let tab: Tab
    weak var view: NSView?
    var block: SideBlock
    var from: Int
    let count: Int
    let down: NSPoint
    var startY: CGFloat?
    var travel: CGSize = .zero
    var onPage = false
    var away = false
    var home: NSRect?
    var leftHome = false
    var room: CGFloat?
}

extension SidePageView {
    private var stepHeight: CGFloat { browser.prefs.sideRow + Metrics.sideGap }

    func rowPressed(_ row: NSView, event: NSEvent) -> Bool {
        pending = (row, convert(event.locationInWindow, from: nil))
        swallowRelease = false
        return false
    }

    func rowDragged(_ row: NSView, event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if carry == nil {
            guard let pending, pending.view === row, hypot(point.x - pending.at.x, point.y - pending.at.y) >= 5,
                  let tab = (row as? TabRowView)?.tab ?? (row as? PinSquareView)?.tab, let laid = laid[tab.id] else { return }
            carry = SideCarry(tab: tab, view: row, block: laid.block, from: laid.index, count: laid.count, down: pending.at,
                              startY: laidY(tab.id))
            browser.beginGesture()
            switch laid.block {
            case .loose, .folder: pickUp(tab, row: row, at: pending.at)
            case .pins, .task: lift(row, on: true)
            }
        }
        guard var carry else { return }
        carry.travel = CGSize(width: point.x - carry.down.x, height: point.y - carry.down.y)
        self.carry = carry
        let tab = carry.tab
        if carry.block != .pins, let window,
           TearOff.shared.drag(self, tab: tab, at: window.convertPoint(toScreen: event.locationInWindow), moved: Self.moved(event)) {
            if browser.prefs.splitView, TabDrag.shared.update(browser: browser, tab: tab, translation: carry.travel, event: event),
               TabDrag.shared.cancelledID == tab.id, lifted(tab) {
                setAway(false)
                _ = land(tab, nil)
                finishCarry()
                pending = nil
                swallowRelease = true
                return
            }
            clearListDrop()
            if crossing != nil { crossing = nil }
            _ = outside?(tab, nil, false)
            setAway(true)
            return
        }
        setAway(false)
        follow()
        let tasked: Bool = if case .task = carry.block { true } else { false }
        let crossed = tasked ? false : cross(tab, point, fromPin: carry.block == .pins)
        if carry.block != .pins, browser.prefs.splitView, TabDrag.shared.update(browser: browser, tab: tab, translation: carry.travel, event: event) {
            clearListDrop()
            if TabDrag.shared.cancelledID == tab.id, lifted(tab) {
                _ = land(tab, nil)
                finishCarry()
                pending = nil
                swallowRelease = true
                return
            }
            setFaded(true)
            return
        }
        setFaded(false)
        if crossed {
            clearListDrop()
            return
        }
        switch carry.block {
        case .pins: dragPin(point)
        case .task: break
        case .loose, .folder: dragRow(point)
        }
    }

    func rowReleased(_ row: NSView, event: NSEvent) -> Bool {
        pending = nil
        if swallowRelease {
            swallowRelease = false
            if let tab = (row as? TabRowView)?.tab { _ = TabDrag.shared.finish(browser: browser, tab: tab, event: event) }
            return true
        }
        guard let carry else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let tab = carry.tab
        defer { finishCarry() }
        if browser.prefs.splitView, carry.block != .pins {
            let finished = TabDrag.shared.finish(browser: browser, tab: tab, event: event)
            let source = finished.source
            let cancelled: Bool = if case .cancelled = finished.drop { true } else { false }
            if !cancelled, carry.away, TearOff.shared.letGo(self, source) { return true }
            if !taken(cancelled ? nil : point, carry) {
                switch finished.drop {
                case .stage(let target, let onLeft): browser.pair(source, with: target, onLeft: onLeft)
                case .replace(let target): browser.replacePage(target, with: source)
                case .strip(let target):
                    if let destination = destination(source, at: point) {
                        browser.move(source, toGroup: destination, detaching: true)
                    } else {
                        browser.dropTabIntoStrip(source, before: target)
                    }
                case .outside:
                    drop(source, at: point)
                case .cancelled:
                    break
                }
            }
            return true
        }
        switch carry.block {
        case .pins:
            _ = land(tab, point)
            return true
        case .task(let folder):
            let reach = CGFloat(browser.taskFolders.first { $0.id == folder }?.tabs.count ?? 0) * stepHeight
            if DragOutToKeep.leftFolder(carry.travel, reach: reach) { browser.keepAgentTab(tab) }
            return true
        case .loose, .folder:
            if carry.away, TearOff.shared.letGo(self, tab) { return true }
            if !taken(point, carry) { drop(tab, at: point) }
            return true
        }
    }

    private func laidY(_ id: UUID) -> CGFloat? {
        guard let laid = laid[id], let parent = laid.parent else { return nil }
        return parent.convert(laid.frame, to: self).minY
    }

    private var gained: CGFloat {
        guard let carry else { return 0 }
        if let start = carry.startY, let now = laidY(carry.tab.id) { return now - start }
        return 0
    }

    fileprivate func follow() {
        if let carry, lifted(carry.tab) { return recheckEdges() }
        guard let carry, let view = carry.view, let laid = laid[carry.tab.id] else { return }
        var frame = laid.frame
        if carry.block == .pins {
            let start = laidStart ?? frame
            frame.origin = NSPoint(x: start.minX + carry.travel.width, y: start.minY + carry.travel.height)
            frame.origin.x += 0
        } else {
            frame.origin.y += carry.travel.height - gained
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.removeAnimation(forKey: "position")
        view.frame = frame
        CATransaction.commit()
        recheckEdges()
    }

    private var laidStart: NSRect? { pinStart }

    private func lift(_ view: NSView, on: Bool) {
        guard let layer = view.layer else { return }
        layer.zPosition = on ? 10 : 0
        layer.shadowColor = NSColor.black.cgColor
        let pin = view is PinSquareView
        layer.shadowRadius = pin ? 10 : 14
        layer.shadowOffset = CGSize(width: 0, height: pin ? -3 : -6)
        layer.kitAnimate("shadowOpacity", to: Swift.Float(on ? (pin ? 0.16 : 0.3) : 0), curve: on ? Motion.kitQuick : Motion.kitSettle)
        if !pin { view.kitScale(on ? 1.03 : 1, curve: on ? Motion.kitQuick : Motion.kitSettle) }
        if on { pinStart = laid[(view as? PinSquareView)?.tab?.id ?? UUID()]?.frame }
        (view as? TabRowView)?.releasePress()
        (view as? PinSquareView)?.releasePress()
    }

    private func setFaded(_ on: Bool) {
        guard var carry, carry.onPage != on else { return }
        carry.onPage = on
        self.carry = carry
        if morphCarried == carry.tab.id {
            morphView?.alphaValue = on ? 0.4 : 1
        } else {
            carry.view?.alphaValue = on ? 0.4 : 1
        }
    }

    private func setAway(_ on: Bool) {
        guard var carry, carry.away != on else { return }
        carry.away = on
        self.carry = carry
        let view = morphCarried == carry.tab.id ? morphView : carry.view
        view?.alphaValue = on ? 0 : carry.onPage ? 0.4 : 1
    }

    private static func moved(_ event: NSEvent) -> CGVector? {
        guard event.type == .leftMouseDragged, event.deltaX != 0 || event.deltaY != 0 else { return nil }
        return CGVector(dx: event.deltaX, dy: -event.deltaY)
    }

    private func lifted(_ tab: Tab) -> Bool {
        guard let carry, carry.tab.id == tab.id, morphCarried == tab.id else { return false }
        return carry.block != .pins
    }

    func clearListDrop() {
        if dropOn != nil { dropOn = nil }
        if looseOn != nil { looseOn = nil }
        spring.over(nil) { _ in }
        hold.over(nil) { [weak self] in self?.joining = $0 }
    }

    private func pickUp(_ tab: Tab, row: NSView, at point: NSPoint) {
        guard let laid = laid[tab.id], let parent = laid.parent else { return lift(row, on: true) }
        let source = parent.convert(laid.frame, to: self)
        carry?.home = parent.convert(laid.frame, to: listDocument)
        carry?.room = listDocument.frame.height
        (row as? TabRowView)?.releasePress()
        flights += 1
        hand = SideHand(point: point, tile: false, fromPin: false,
                        grab: CGSize(width: point.x - source.minX, height: point.y - source.minY), started: source)
        morphCarried = tab.id
        startMorph(tab, washed: false)
        morphView?.apply(frame: source, form: 0, lift: 0, curve: .none)
        drawHand(tab, curve: Motion.calm ? .none : Self.morphChange)
        for view in listDocument.kitSubviews(of: TabRowView.self) where view.tab?.id == tab.id { view.alphaValue = 0 }
        rows[tab.id]?.alphaValue = 0
        relightCards()
        animateNext = true
        needsLayout = true
    }

    private func finishCarry() {
        TearOff.shared.end(self)
        guard let carry else { return }
        dropOn = nil
        looseOn = nil
        joining = nil
        spring.over(nil) { _ in }
        if let view = carry.view, !lifted(carry.tab) {
            view.alphaValue = 1
            lift(view, on: false)
        }
        morphView?.alphaValue = 1
        self.carry = nil
        browser.endGesture()
        pinStart = nil
        animateNext = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        recheckEdges()
    }

    private func move(_ tab: Tab, _ block: SideBlock, to index: Int) {
        animateNext = true
        switch block {
        case .loose:
            if browser.prefs.usesTabGroups { browser.move(tab, within: nil, to: index) } else { browser.moveDisplayedTab(tab, to: index + browser.squarePins.count) }
        case .folder(let group): browser.move(tab, within: group, to: index)
        case .pins: browser.moveDisplayedTab(tab, to: index)
        case .task: break
        }
    }

    private func dragRow(_ point: NSPoint) {
        guard let carry else { return }
        let tab = carry.tab
        _ = destination(tab, at: point)
        guard carry.block == .loose, browser.prefs.usesTabGroups, dropOn == nil else {
            hold.over(nil) { [weak self] in self?.joining = $0 }
            return
        }
        hold.over(neighbour(of: tab, at: point)) { [weak self] in self?.joining = $0 }
    }

    private func neighbour(of tab: Tab, at point: NSPoint) -> UUID? {
        for entry in itemsNow {
            guard case .tab(let id) = entry.item, id != tab.id else { continue }
            let band = entry.rect.insetBy(dx: 0, dy: entry.rect.height * 0.3)
            if point.y >= band.minY, point.y <= band.maxY, point.x >= entry.rect.minX, point.x <= entry.rect.maxX { return id }
        }
        return nil
    }

    private func dragPin(_ point: NSPoint) {
        guard let carry, let start = pinStart else { return }
        let cells = laid.values.filter { $0.block == .pins }.sorted { $0.index < $1.index }.map(\.frame)
        let target = PinCarried.target(travel: carry.travel, from: carry.from, cells: cells.isEmpty ? [start] : cells)
        if let index = laid[carry.tab.id]?.index, target != index {
            move(carry.tab, .pins, to: target)
            layoutSubtreeIfNeeded()
            follow()
        }
    }

    func dropFrames() -> [UUID: GroupDropFrame] {
        var frames: [UUID: GroupDropFrame] = [:]
        for (id, rect) in headingFrames {
            let now = headingDocs[id].flatMap { held in held.parent.map { $0.convert(held.rect, to: self) } } ?? rect
            frames[id] = GroupDropFrame(group: id, rect: now)
        }
        for (id, laid) in laid {
            guard case .folder(let group) = laid.block, let parent = laid.parent else { continue }
            frames[id] = GroupDropFrame(group: group, tab: id, rect: parent.convert(laid.frame, to: self))
        }
        return frames
    }

    var itemsNow: [(item: Browser.ListItem, rect: CGRect)] {
        let carried = carry.flatMap { lifted($0.tab) ? $0.tab.id : nil }
        return itemDocs.filter { $0.item != .tab(carried ?? UUID()) }.map { ($0.item, listDocument.convert($0.rect, to: self)) }
    }

    var raisedNow: [CGRect] {
        raisedDocs.map { listDocument.convert($0, to: self) }
    }

    fileprivate func destination(_ tab: Tab, at point: NSPoint) -> GroupDropTarget? {
        guard tab.pin == nil else { return nil }
        let grouped = browser.prefs.usesTabGroups
        let carried = lifted(tab)
        if carried, var carry = carry, !carry.leftHome {
            if let home = carry.home.map({ listDocument.convert($0, to: self) }), home.contains(point) {
                clearListDrop()
                return nil
            }
            carry.leftHome = true
            self.carry = carry
        }
        guard grouped || carried else { return nil }
        var frames = grouped ? dropFrames() : [:]
        if carried { frames[tab.id] = nil }
        let groups = grouped ? browser.tabGroups.filter { !$0.live || $0.id == tab.groupID && tab.liveKey != nil } : []
        let place = carried || browser.group(of: tab) != nil
            ? ListDrop.resolve(point, items: itemsNow, below: raisedNow.map(\.maxY).max() ?? -.greatestFiniteMagnitude,
                               frames: frames, groups: groups, excluding: tab.id,
                               band: browser.group(of: tab) == nil ? 0 : ListDrop.edge)
            : GroupDropFrames.resolve(point, frames: frames, groups: groups, excluding: tab.id, vertical: true).map(ListDrop.folder)
        var target: GroupDropTarget?
        var loose: LoosePlace?
        switch place {
        case .folder(let inside)?: target = browser.liveDrop(inside, carrying: tab)
        case .loose(let out)?: loose = carried || browser.group(of: tab) != nil ? out : nil
        case nil: break
        }
        let shut = target.flatMap { target in
            target.member == nil && browser.tabGroups.first { $0.id == target.group }?.collapsed == true ? target.group : nil
        }
        spring.over(shut) { [weak self] id in
            self?.animateNext = true
            self?.browser.unfoldFolder(id)
        }
        if dropOn != target { dropOn = target }
        if looseOn != loose { looseOn = loose }
        return target
    }

    private func drop(_ tab: Tab, at point: NSPoint) {
        spring.over(nil) { _ in }
        if let target = destination(tab, at: point) {
            animateNext = true
            browser.move(tab, toGroup: target)
        } else if let looseOn {
            animateNext = true
            if browser.prefs.usesTabGroups, browser.group(of: tab) != nil {
                browser.moveOut(tab, before: looseOn.before)
            } else {
                browser.moveLoose(tab, before: looseOn.before)
            }
        }
        spring.over(nil) { _ in }
    }

    private func taken(_ point: NSPoint?, _ carry: SideCarry) -> Bool {
        if land(carry.tab, point) { return true }
        if let neighbour = hold.take() {
            joining = nil
            if point != nil, let other = browser.tabs.first(where: { $0.id == neighbour }) {
                animateNext = true
                _ = browser.newFolder(with: [other, carry.tab])
                return true
            }
        }
        guard point != nil, abs(carry.travel.height) < stepHeight / 2, abs(carry.travel.width) >= 24 else { return false }
        return shifted(carry.tab, carry.travel.width)
    }

    private func shifted(_ tab: Tab, _ width: CGFloat) -> Bool {
        guard browser.prefs.usesTabGroups else { return false }
        let steps = Int((width / (16 * 1.5)).rounded(.towardZero))
        animateNext = true
        return browser.shiftLevel(tab, by: steps)
    }

    fileprivate func showDrop() {
        defer {
            recheckEdges()
            noteDrop()
        }
        let greys = ground.greys
        dropOutline.isHidden = true
        dropLine.isHidden = true
        let items = itemsNow
        guard joining == nil else { return }
        if let crossing, carry?.tab.id == crossing.tab {
            switch crossing.target {
            case .loose(let at):
                let order = looseOrder.filter { $0 != crossing.tab }
                let before: Browser.ListItem? = order.indices.contains(at) ? .tab(order[at])
                    : order.last.flatMap { last in
                        items.firstIndex { $0.item == .tab(last) }.flatMap { items.indices.contains($0 + 1) ? items[$0 + 1].item : nil }
                    } ?? (order.isEmpty ? items.first?.item : nil)
                showLine(before: before, items: items)
            case .group(let id): showOutline(id)
            case .squares: break
            }
            return
        }
        if let looseOn {
            showLine(before: looseOn.before, items: items)
            return
        }
        guard let dropOn else { return }
        if let member = dropOn.member, let laid = laid[member], let parent = laid.parent {
            let rect = parent.convert(laid.frame, to: self)
            let y = dropOn.after ? rect.maxY + 3 - 1 : rect.minY - 3 - 1
            dropLine.fill = greys.dot
            dropLine.ink = ground.ink
            dropLine.kitSetFrame(NSRect(x: rect.minX + 6, y: y, width: rect.width - 12, height: 2))
            dropLine.isHidden = false
        } else if dropOn.member == nil {
            showOutline(dropOn.group)
        }
    }

    private func showLine(before: Browser.ListItem?, items: [(item: Browser.ListItem, rect: CGRect)]) {
        let greys = ground.greys
        if let first = items.first,
           let y = FolderDrop.line(for: FolderDrop.Place(pinned: false, before: before), raised: [], items: items, gap: Self.gap) {
            dropLine.fill = greys.dot
            dropLine.ink = ground.ink
            dropLine.kitSetFrame(NSRect(x: first.rect.minX + 6, y: max(0, y - 1), width: first.rect.width - 12, height: 2))
            dropLine.isHidden = false
        }
    }

    private func showOutline(_ group: UUID) {
        guard let card = cardDocs[group].flatMap({ held in held.parent.map { $0.convert(held.rect, to: self) } }) ?? cardFrames[group] else { return }
        dropOutline.stroke = ground.greys.dot.opacity(SideLook.dropRing)
        dropOutline.fill = nil
        dropOutline.ink = ground.ink
        dropOutline.kitSetFrame(card)
        dropOutline.isHidden = false
    }

    private func noteDrop() {
        guard Store.testing, preview == nil, !embedded, let content = window?.contentView else { return }
        func placed(_ view: NSView) -> [Double]? {
            guard !view.isHidden else { return nil }
            let rect = convert(view.frame, to: content)
            let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
            return [rect.minX, top, rect.width, rect.height].map { Double($0) }
        }
        var out: [String: Any] = [:]
        if let looseOn {
            out["loose"] = switch looseOn.before {
            case .tab(let id)?: browser.tabs.first { $0.id == id }.map(Bench.short) ?? ""
            case .folder(let id)?: "folder:" + (browser.tabGroups.first { $0.id == id }?.name ?? "")
            case nil: ""
            }
        }
        if let dropOn {
            out["group"] = browser.tabGroups.first { $0.id == dropOn.group }?.name ?? ""
            out["member"] = dropOn.member.flatMap { id in browser.tabs.first { $0.id == id } }.map(Bench.short) ?? ""
            out["after"] = dropOn.after
        }
        if let line = placed(dropLine) { out["line"] = line }
        if let outline = placed(dropOutline) { out["outline"] = outline }
        SidePageView.benchDrop = out
    }

    func benchFolder(_ id: UUID, look: String) {
        guard Store.testing else { return }
        let heading = headings[id]
        heading?.benchPillHover(look == "hover")
        heading?.dropping = look == "dropheading"
        dropOn = look == "drop" ? GroupDropTarget(group: id) : nil
        SidePageView.benchLine = nil
        guard look == "line" || look == "lineunder" else { return showFolderLine(nil) }
        let pinned = raisedPlaces.contains { $0.id == id }
        var before: Browser.ListItem? = .folder(id)
        if look == "lineunder" {
            let order: [Browser.ListItem] = pinned ? raisedPlaces.map { .folder($0.id) } : itemPlaces.map(\.item)
            before = order.firstIndex(of: .folder(id)).flatMap { order.indices.contains($0 + 1) ? order[$0 + 1] : nil }
        }
        showFolderLine(FolderDrop.line(for: FolderDrop.Place(pinned: pinned, before: before), raised: raisedPlaces, items: itemPlaces, gap: Self.gap))
        guard let content = window?.contentView else { return }
        let rect = convert(folderLine.frame, to: content)
        SidePageView.benchLine = ["y": Double(content.isFlipped ? rect.minY : content.bounds.height - rect.maxY), "h": Double(rect.height)]
    }

    fileprivate func showJoin() {
        joinOutline.isHidden = true
        guard let joining, let laid = laid[joining], let parent = laid.parent else { return }
        joinOutline.stroke = KitTone.ink.opacity(0.5)
        joinOutline.fill = nil
        joinOutline.ink = ground.ink
        joinOutline.kitSetFrame(parent.convert(laid.frame, to: self))
        joinOutline.isHidden = false
    }
}

struct SideHand {
    var point: CGPoint = .zero
    var tile = false
    var fromPin = false
    var grab: CGSize = .zero
    var started: CGRect?
    var scripted = false
}

extension SidePageView {
    fileprivate var tileSize: CGSize {
        let others = browser.squarePins.filter { $0.id != morphCarried }.count
        let cells = pinCells(others + 1)
        if case .squares(let ghost)? = crossing?.target, cells.indices.contains(ghost) { return cells[ghost].size }
        return cells.last?.size ?? CGSize(width: PinPlaces.narrowest, height: PinPlaces.height)
    }

    fileprivate func leaving(_ tab: Tab) -> Bool {
        guard morphCarried == tab.id, tab.pin == nil else { return false }
        if case .squares? = crossing?.target { return true }
        return carry?.tab.id == tab.id
    }

    private func itemFrame(_ id: UUID) -> NSRect? {
        guard let laid = laid[id], let parent = laid.parent else { return nil }
        return parent.convert(laid.frame, to: self)
    }

    private func target(for tab: Tab, at point: CGPoint) -> PinDrop.Target? {
        let squares = browser.squarePins.filter { $0.id != tab.id }
        let ghosted: Bool = if case .squares? = crossing?.target { true } else { false }
        let gridShown = !squares.isEmpty || ghosted
        let inner = bounds.width - 2 * Metrics.sideInset
        let local = CGPoint(x: point.x - Metrics.sideInset, y: point.y)
        switch PinDrop.zone(local, width: inner, gridBottom: gridShown ? gridRect?.maxY : nil) {
        case .none:
            return nil
        case .squares:
            guard tab.pin == nil, browser.pinsByDrag(tab) else { return nil }
            let origin = gridShown ? gridRect?.origin ?? NSPoint(x: Metrics.sideInset, y: 0) : NSPoint(x: Metrics.sideInset, y: 0)
            let slot = PinDrop.gridSlot(CGPoint(x: point.x - origin.x, y: point.y - origin.y), cells: pinCells(squares.count + 1))
            return .squares(browser.pinSlot(tab, proposed: slot))
        case .loose:
            guard tab.pin != nil else { return nil }
            if browser.prefs.usesTabGroups {
                for (id, rect) in cardFrames where rect.contains(point) {
                    guard let group = browser.tabGroups.first(where: { $0.id == id }), !group.live else { continue }
                    return .group(id)
                }
            }
            let loose = looseOrder
            guard !loose.isEmpty, let top = looseTop else { return .loose(0) }
            let measured = loose.compactMap(itemFrame)
            if measured.count == loose.count {
                let held: (Int, CGRect)? = if case .loose(let at)? = crossing?.target, let gapRect { (at, gapRect) } else { nil }
                return .loose(PinDrop.slot(y: point.y, rows: measured, ghost: held))
            }
            let ghost: (Int, CGFloat)? = nil
            let heights = loose.map { _ in browser.prefs.sideRow }
            return .loose(PinDrop.rowSlot(y: point.y - top, heights: heights, gap: Metrics.sideGap, ghost: ghost))
        }
    }

    func cross(_ tab: Tab, _ point: CGPoint, fromPin: Bool) -> Bool {
        if let outside, tab.pin == nil, outside(tab, convert(point, to: nil), false) {
            if crossing != nil { crossing = nil }
            return true
        }
        let now = target(for: tab, at: point).map { PinDrop.Crossing(tab: tab.id, target: $0) }
        if now != crossing {
            if crossing == nil, now != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            crossing = now
            layoutSubtreeIfNeeded()
        }
        moved(tab, to: point, crossing: now != nil, fromPin: fromPin, source: itemFrame(tab.id))
        return now != nil
    }

    private func moved(_ tab: Tab, to point: CGPoint, crossing: Bool, fromPin: Bool, source: CGRect?) {
        let tile = fromPin != crossing
        if morphCarried != tab.id {
            guard crossing else { return }
            flights += 1
            hand = SideHand(point: point, tile: fromPin, fromPin: fromPin,
                            grab: source.map { CGSize(width: point.x - $0.minX, height: point.y - $0.minY) } ?? .zero,
                            started: source, scripted: hand.scripted)
            morphCarried = tab.id
            startMorph(tab)
            if let view = carry?.view, let parent = view.superview {
                let shown = view.layer?.presentation().map { parent.convert($0.frame, to: self) } ?? parent.convert(view.frame, to: self)
                morphView?.apply(frame: shown, form: fromPin ? 1 : 0, lift: 1, curve: .none)
            }
            carry?.view?.alphaValue = 0
            hand.tile = tile
            drawHand(tab, curve: Self.morphChange)
            needsLayout = true
            return
        }
        hand.point = point
        let changed = hand.tile != tile
        hand.tile = tile
        drawHand(tab, curve: changed ? Self.morphChange : .none)
    }

    private func startMorph(_ tab: Tab, washed: Bool = true) {
        morphView?.removeFromSuperview()
        let view = PinMorphView()
        view.washed = washed
        view.solid = ground.stops.map { Paint.Ground(stops: $0, lightInk: ground.dark).average.color } ?? Palette.NS.ground
        view.configure(tab: tab, live: tab.id == browser.activeID, landing: false, titleSize: browser.prefs.sideTitle, ground: ground)
        addSubview(view, positioned: .above, relativeTo: nil)
        morphView = view
    }

    private func shapes(_ tab: Tab) -> (row: CGRect, tile: CGRect) {
        let height = browser.prefs.sideRow
        let source = hand.scripted ? nil : hand.started
        let row = PinShape.row(hand: hand.point, fromPin: hand.fromPin, source: hand.fromPin ? nil : source,
                               grab: hand.grab, rows: rowsRect, height: height)
        let tile = PinShape.tile(hand: hand.point, fromPin: hand.fromPin, source: hand.fromPin ? source : nil, size: tileSize)
        return (row, tile)
    }

    private func drawHand(_ tab: Tab, curve: KitCurve) {
        guard let morphView else { return }
        let (row, tile) = frozen ?? shapes(tab)
        let form: CGFloat = hand.tile ? 1 : 0
        morphView.apply(frame: PinShape.mix(row, tile, form), form: form, lift: 1, curve: curve)
    }

    func land(_ tab: Tab, _ point: CGPoint?) -> Bool {
        if let outside, tab.pin == nil, outside(tab, point.map { convert($0, to: nil) }, true) {
            if crossing != nil { crossing = nil }
            return true
        }
        let carried = morphCarried == tab.id
        if carried { frozen = shapes(tab) }
        if let neighbour = hold.take() {
            joining = nil
            if point != nil, let other = browser.tabs.first(where: { $0.id == neighbour }) {
                animateNext = true
                _ = browser.newFolder(with: [other, tab])
                if carried { flyHome(tab) }
                return true
            }
        }
        let shown = crossing?.tab == tab.id ? crossing?.target : nil
        guard point != nil, let shown else {
            if crossing != nil { crossing = nil }
            if carried { flyHome(tab) }
            return false
        }
        let commit = { [weak self, browser] in
            self?.animateNext = true
            self?.crossing = nil
            switch shown {
            case .squares(let at): browser.pinDropped(tab, at: at)
            case .loose(let at): browser.unpinDropped(tab, at: at)
            case .group(let id): browser.unpinDropped(tab, at: 0, group: id)
            }
        }
        guard carried else {
            commit()
            return true
        }
        guard case .squares = shown else {
            commit()
            flyHome(tab)
            return true
        }
        settle(gapRect, tile: true, done: commit)
        return true
    }

    private func flyHome(_ tab: Tab) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSubtreeIfNeeded()
            self.settle(self.home(of: tab), tile: tab.pin != nil) {}
        }
    }

    private func home(of tab: Tab) -> CGRect? {
        if tab.pin != nil { return itemFrame(tab.id) }
        let folded = browser.group(of: tab).flatMap { id in headings[id].map { ($0, id) } }
        guard var target = itemFrame(tab.id) ?? folded.map({ heading, _ in convert(heading.bounds, from: heading) }) else { return nil }
        let list = listScroll.frame
        if list.height > target.height {
            target.origin.y = min(max(target.minY, list.minY), list.maxY - target.height)
        }
        return target
    }

    private func settle(_ rect: CGRect?, tile: Bool, done: @escaping () -> Void) {
        guard morphCarried != nil else { done(); return }
        flights += 1
        let mine = flights
        let curve = Self.morphLanding
        guard let rect, curve.animates, let morphView else {
            done()
            finishMorph(mine)
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            done()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * PinMorph.slow) { self?.finishMorph(mine) }
        }
        morphView.apply(frame: rect, form: tile ? 1 : 0, lift: 0, curve: curve)
        CATransaction.commit()
    }

    private func finishMorph(_ mine: Int) {
        guard mine == flights else { return }
        PinFlightTrace.event("finish \(mine)")
        if morphCarried != nil, let morph = morphView, let layer = morph.layer {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.toValue = 0
            fade.duration = 0.12
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { morph.removeFromSuperview() }
            layer.add(fade, forKey: "landed.opacity")
            CATransaction.commit()
        } else {
            morphView?.removeFromSuperview()
        }
        morphView = nil
        morphCarried = nil
        morphArrived = nil
        frozen = nil
        hand = SideHand()
        animateNext = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        for view in rows.values { view.alphaValue = 1 }
        for view in pins.values { view.alphaValue = 1 }
    }

    func flyPin(_ tab: Tab, _ change: () -> Void) -> Bool {
        PinFlightTrace.event("ask animates \(Self.morphFlight.animates) crossing \(crossing != nil) carried \(morphCarried != nil) window \(window != nil) source \(itemFrame(tab.id).map { "\($0)" } ?? "none")")
        guard Self.morphFlight.animates, crossing == nil, !browser.stacked, browser.spaceNext == nil, !browser.makingSpace,
              !(Store.testing && !Store.shownOnScreen), window != nil, morphCarried == nil,
              browser.tabs.contains(where: { $0.id == tab.id }), let source = itemFrame(tab.id), seen(tab, at: source) else { return false }
        let unpinning = tab.pin != nil
        flights += 1
        let mine = flights
        morphCarried = tab.id
        change()
        animateNext = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard var target = itemFrame(tab.id) else {
            finishMorph(mine)
            return true
        }
        if unpinning {
            let list = listScroll.frame
            if list.height > target.height {
                target.origin.y = min(max(target.minY, list.minY), list.maxY - target.height)
            }
        }
        rows[tab.id]?.alphaValue = 0
        pins[tab.id]?.alphaValue = 0
        PinFlightTrace.event("fly \(source) to \(target)")
        let view = PinMorphView()
        view.washed = false
        view.rowRadius = rows[tab.id]?.state.radius ?? Metrics.sideRadius
        view.configure(tab: tab, live: tab.id == browser.activeID, landing: true, titleSize: browser.prefs.sideTitle, ground: ground)
        addSubview(view, positioned: .above, relativeTo: nil)
        morphView?.removeFromSuperview()
        morphView = view
        view.apply(frame: source, form: unpinning ? 1 : 0, lift: 0, curve: .none)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finishMorph(mine) }
        view.apply(frame: target, form: unpinning ? 0 : 1, lift: 0, curve: Self.morphFlight)
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.finishMorph(mine) }
        if unpinning, !fits { DispatchQueue.main.async { [weak self] in self?.reveal(tab.id) } }
        return true
    }

    private func seen(_ tab: Tab, at frame: CGRect) -> Bool {
        if tab.pin != nil {
            guard let grid = gridRect else { return false }
            return grid.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        if let id = browser.group(of: tab), let group = browser.tabGroups.first(where: { $0.id == id }) {
            guard browser.visibleTabs(in: group).contains(where: { $0.id == tab.id }) else { return false }
        }
        let list = listScroll.frame
        return frame.midY > list.minY && frame.midY < list.maxY
    }

    private func giveBack(_ shift: CGFloat) {
        guard shift > 0.5, let layer = listDocument.layer else { return }
        let lift = (listDocument.superview?.layer?.contentsAreFlipped() ?? true) ? -shift : shift
        guard let animation = Motion.kitSettle.animation("position", from: NSValue(point: NSPoint(x: 0, y: lift)),
                                                         to: NSValue(point: .zero)) as? CAPropertyAnimation else { return }
        animation.isAdditive = true
        animation.fillMode = .backwards
        givenBack += 1
        layer.add(animation, forKey: "giveBack.\(givenBack)")
    }

    func reveal(_ id: UUID) {
        if embedded {
            if let frame = frame(of: id) { onReveal?(frame) }
            return
        }
        guard !fits, let laid = laid[id], laid.parent === listDocument else { return }
        let clip = listScroll.contentView
        let fade = ColumnEdges.fade
        let floor = clip.bounds.height - heldRoomNow
        let row = laid.frame
        var y = clip.bounds.minY
        if row.minY < y + fade { y = row.minY - fade } else if row.maxY > y + floor - fade { y = row.maxY - floor + fade } else { return }
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin
        if Store.testing || !Motion.kitSettle.animates {
            clip.scroll(to: target)
        } else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
        }
        listScroll.reflectScrolledClipView(clip)
    }

    func probe(_ id: UUID, _ point: CGPoint?, ended: Bool) -> Bool {
        guard let tab = browser.tabs.first(where: { $0.id == id }) else { return false }
        hand.scripted = true
        let page = point.map { CGPoint(x: $0.x + Metrics.sideInset, y: $0.y) }
        guard !ended, let page else { return land(tab, page) }
        return cross(tab, page, fromPin: tab.pin != nil)
    }
}

extension InternalDrag {
    static var folderPasteboard: NSPasteboard.PasteboardType { NSPasteboard.PasteboardType(folder.identifier) }

    static func folderID(_ pasteboard: NSPasteboard) -> UUID? {
        guard let text = pasteboard.string(forType: folderPasteboard) else { return nil }
        return UUID(uuidString: text)
    }
}

extension SidePageView {
    static let dropped: [NSPasteboard.PasteboardType] = [.URL, .fileURL, .string, InternalDrag.folderPasteboard]

    private func carriesFolder(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.availableType(from: [InternalDrag.folderPasteboard]) != nil
    }

    private func folderPlace(y: CGFloat, moving: UUID?) -> FolderDrop.Place {
        FolderDrop.place(y: y, rowsTop: listTopNow, raised: raisedPlaces, items: itemPlaces, moving: moving)
    }

    private func aimDrop(_ info: NSDraggingInfo) -> NSDragOperation {
        let point = convert(info.draggingLocation, from: nil)
        if carriesFolder(info) {
            landingGround.isHidden = true
            let place = folderPlace(y: point.y, moving: InternalDrag.folderID(info.draggingPasteboard))
            let line = FolderDrop.line(for: place, raised: raisedPlaces, items: itemPlaces, gap: Self.gap)
            showFolderLine(line)
            return .move
        }
        showFolderLine(nil)
        landingGround.isHidden = false
        return .copy
    }

    private func showFolderLine(_ y: CGFloat?) {
        guard let y else {
            folderLine.isHidden = true
            return
        }
        let frame = NSRect(x: Self.inset + 6, y: y - 1, width: bounds.width - 2 * (Self.inset + 6), height: 2)
        if folderLine.isHidden {
            folderLine.frame = frame
            folderLine.isHidden = false
        } else if folderLine.frame != frame, let layer = folderLine.layer {
            let from = layer.presentation()?.position ?? layer.position
            folderLine.kitSetFrame(frame)
            let curve: KitCurve = Motion.reduced ? .none : .easeOut(0.15)
            if let animation = curve.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position)) {
                animation.fillMode = .backwards
                layer.add(animation, forKey: "position")
            }
        }
    }

    private func endDrop() {
        landingGround.isHidden = true
        showFolderLine(nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { aimDrop(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { aimDrop(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { endDrop() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endDrop() }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        endDrop()
        let pasteboard = sender.draggingPasteboard
        if let id = InternalDrag.folderID(pasteboard) {
            guard browser.tabGroups.contains(where: { $0.id == id }) else { return false }
            let place = folderPlace(y: convert(sender.draggingLocation, from: nil).y, moving: id)
            animateNext = true
            browser.placeFolder(id, pinned: place.pinned, before: place.before)
            return true
        }
        if carriesFolder(sender) { return false }
        var providers: [NSItemProvider] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            providers = urls.map { NSItemProvider(object: $0 as NSURL) }
        } else if let text = pasteboard.string(forType: .string) {
            providers = [NSItemProvider(object: text as NSString)]
        }
        return browser.take(providers)
    }
}

extension SidePageView {
    static let foldRise: CGFloat = 14

    fileprivate func stackFolded(_ id: UUID) -> Bool {
        guard let tab = browser.tabs.first(where: { $0.id == id }), let key = tab.liveItem?.key, let group = tab.groupID else { return false }
        return browser.tabGroups.first { $0.id == group }?.foldedStacks.contains(key) == true
    }

    fileprivate func foldRise(_ was: SideLaid?) -> CGFloat {
        guard folded(was) else { return 0 }
        guard let was, case .folder(let id) = was.block, let parent = was.parent, let heading = headingFrames[id] else { return Self.foldRise }
        let row = parent.convert(was.frame, to: self)
        let up = isFlipped ? row.minY - heading.maxY : heading.minY - row.maxY
        return max(Self.foldRise, up)
    }

    fileprivate func folded(_ was: SideLaid?) -> Bool {
        switch was?.block {
        case .folder(let id)?: browser.tabGroups.first { $0.id == id }?.collapsed == true
        case .task(let id)?: browser.taskFolders.first { $0.id == id }?.folded == true
        default: false
        }
    }

    func tally(_ id: UUID) -> Int {
        scene.tabs.filter { tab in
            guard tab.pin == nil, let own = tab.groupID else { return false }
            return own == id || FolderTree.ancestors(of: own, in: scene.groups).contains { $0.id == id }
        }.count
    }

    fileprivate func paintCard(_ plate: KitPlate, _ id: UUID, animated: Bool) {
        let lit = dropOn.map { $0.group == id && $0.member == nil } == true
        let fill: KitTone? = lit ? ground.greys.card.opacity(SideLook.cardLift(dark: plate.kitDark)) : ground.greys.onFrame ? nil : ground.greys.card
        if animated, plate.fill != fill, Motion.kitQuick.animates { plate.layer?.kitTransition(Motion.kitQuick) }
        ground.greys.card(plate)
        plate.fill = fill
    }

    fileprivate func hoverCard(_ id: UUID, _ on: Bool) {
        let now = on ? id : hoveredCard == id ? nil : hoveredCard
        guard now != hoveredCard else { return }
        hoveredCard = now
        relightCards()
    }

    fileprivate func relightCards(animated: Bool = true) {
        for (key, plate) in cards { if case .card(let id) = key { paintCard(plate, id, animated: animated) } }
        for (id, light) in lights { light.light(lightsUp(id), curve: Motion.kitQuick) }
    }

    fileprivate func lightsUp(_ id: UUID) -> Bool {
        guard carry == nil, hoveredCard == id, let heading = headings[id] else { return false }
        return heading.interactive && !heading.dropping && browser.editingGroupID != id
    }

    fileprivate func placeLight(_ light: FolderLightView, _ group: TabGroup, card: NSRect, heading: NSRect) {
        let shut = group.collapsed
        let hair: CGFloat = ground.greys.onFrame ? 0 : 1 / max(1, window?.backingScaleFactor ?? 2)
        let box = shut ? card.insetBy(dx: hair, dy: hair) : heading
        let radius = shut ? Metrics.folderRadius - hair : SideLook.cardRowRadius
        let tone = lightTone(shut: shut, dark: light.kitDark)
        if light.frame == .zero || !animating {
            light.frame = light.kitSnapped(box)
            light.shape(radius: radius, tone: tone, curve: .none)
        } else {
            put(light, box)
            light.shape(radius: radius, tone: tone, curve: settle)
        }
        light.light(lightsUp(group.id), curve: Motion.kitQuick)
    }

    fileprivate func lightTone(shut: Bool, dark: Bool) -> CGColor {
        let greys = ground.greys, ink = ground.ink
        let hover = greys.hover.resolved(ink, dark: dark)
        guard shut else { return hover.cgColor }
        let lit = greys.card.opacity(SideLook.cardLift(dark: dark)).resolved(ink, dark: dark)
        if greys.onFrame { return dark ? lit.cgColor : hover.cgColor }
        let card = greys.card.resolved(ink, dark: dark)
        let under = card.alphaComponent, over = lit.alphaComponent
        let share = under < 1 ? max(0, (over - under) / (1 - under)) : 0
        return lit.withAlphaComponent(share).cgColor
    }

    fileprivate func keptShift(_ id: UUID) -> CGFloat { keptRow(id)?.shift ?? 0 }

    fileprivate func keptRow(_ id: UUID) -> (tab: UUID, shift: CGFloat)? {
        guard animating, closedNow.contains(id) || openedNow.contains(id), let card = cardFrames[id], let old = cardsBefore[id] else { return nil }
        for (tab, now) in laid where now.block == .folder(id) {
            guard let was = laidBefore[tab], was.block == .folder(id), let parent = now.parent, was.parent === parent else { continue }
            let top = parent.convert(card, from: self).minY, topBefore = parent.convert(old, from: self).minY
            return (tab, (now.frame.minY - top) - (was.frame.minY - topBefore))
        }
        return nil
    }

    static let blockCap = 6

    fileprivate func capped(_ shift: CGFloat) -> CGFloat {
        let most = CGFloat(Self.blockCap) * (rowHeight + Self.gap)
        return shift < 0 ? max(shift, -most) : min(shift, most)
    }

    fileprivate func capKeptRows() {
        for id in closedNow.union(openedNow) {
            guard let kept = keptRow(id), capped(kept.shift) != kept.shift, let layer = rows[kept.tab]?.layer,
                  let slide = layer.animation(forKey: "position") as? CASpringAnimation,
                  let from = (slide.fromValue as? NSValue)?.pointValue, let to = (slide.toValue as? NSValue)?.pointValue,
                  abs(from.y - to.y) > 0.5 else { continue }
            let share = abs(capped(kept.shift)) / abs(from.y - to.y)
            let start = CGPoint(x: to.x + (from.x - to.x) * share, y: to.y + (from.y - to.y) * share)
            guard let made = slide.copy() as? CASpringAnimation else { continue }
            made.fromValue = NSValue(point: start)
            layer.add(made, forKey: "position")
        }
    }

    @discardableResult
    fileprivate func seed(_ plate: KitPlate, for group: TabGroup, x: CGFloat, width: CGFloat) -> Bool {
        guard animating, plate.frame == .zero, let parent = plate.superview else { return false }
        let founders = scene.visible(group).compactMap { tab -> NSRect? in
            guard let was = laidBefore[tab.id], was.block != .folder(group.id), let from = was.parent, from.window != nil else { return nil }
            return parent.convert(was.frame, from: from)
        }
        guard let first = founders.min(by: { $0.minY < $1.minY }) else { return false }
        let last = founders.max { $0.maxY < $1.maxY } ?? first
        plate.frame = plate.kitSnapped(NSRect(x: x, y: first.minY, width: width, height: last.maxY - first.minY))
        guard let layer = plate.layer,
              let fade = KitCurve.easeOut(SideLook.growFade).animation("opacity", from: Swift.Float(0), to: layer.opacity) else { return true }
        fade.fillMode = .backwards
        layer.add(fade, forKey: "enter.opacity")
        return true
    }

    fileprivate func dissolve(_ view: NSView, onto key: SideKey, before: [UUID: SideLaid]) {
        guard animating, let parent = view.superview, let layer = view.layer else {
            retire(view)
            return
        }
        var onto: NSRect?
        if case .card(let id) = key {
            for (tab, was) in before where was.block == .folder(id) {
                guard let now = laid[tab], let from = now.parent, from.window != nil else { continue }
                let rect = parent.convert(now.frame, from: from)
                onto = onto.map { $0.union(rect) } ?? rect
            }
        }
        let model = view.frame
        let radius = (view as? KitPlate)?.radius ?? 0
        let shut = GroupHeadingView.height + 2 * Metrics.folderPad
        let end = onto.map { NSRect(x: model.minX, y: $0.minY, width: model.width, height: $0.height) }
            ?? NSRect(x: model.minX, y: model.minY, width: model.width, height: max(min(model.height, shut), 2 * radius))
        let shown = layer.presentation() ?? layer
        let from = (position: shown.position, size: shown.bounds.size, opacity: shown.opacity)
        leaves += 1
        let mine = leaves
        layer.setValue(mine, forKey: "leaving")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.frame = view.kitSnapped(end)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            guard layer.value(forKey: "leaving") as? Int == mine else { return }
            layer.setValue(nil, forKey: "leaving")
            view.removeFromSuperview()
        }
        for (key, was, now) in [("position", NSValue(point: from.position), NSValue(point: layer.position)),
                                ("bounds.size", NSValue(size: from.size), NSValue(size: layer.bounds.size))] {
            guard let animation = settle.animation(key, from: was, to: now, velocity: layer.kitCarry(key, from: was, to: now))
            else { continue }
            animation.fillMode = .backwards
            layer.add(animation, forKey: key)
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from.opacity
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + (onto == nil ? SideLook.foldLag : SideLook.shrinkLag)
        fade.duration = onto == nil ? 0.18 : 0.24
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        fade.fillMode = .both
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "retire.opacity")
        CATransaction.commit()
    }

    fileprivate func enter(_ view: NSView, _ frame: NSRect, rise: CGFloat) {
        guard let layer = view.layer else {
            view.frame = frame
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rise != 0 { view.frame = frame.offsetBy(dx: 0, dy: -rise) }
        let from = layer.position
        view.frame = frame
        CATransaction.commit()
        guard view.alphaValue > 0 else { return }
        if rise != 0, let slide = settle.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position)) {
            slide.fillMode = .backwards
            layer.add(slide, forKey: "position")
        }
        if let fade = KitCurve.easeOut(0.2).animation("opacity", from: Swift.Float(0), to: layer.opacity) {
            fade.fillMode = .backwards
            layer.add(fade, forKey: "enter.opacity")
        }
    }

    fileprivate func dropOpened(before: [UUID: SideLaid], cards: [UUID: NSRect]) {
        var shut = Set<UUID>()
        for (_, was) in before { if case .folder(let id) = was.block { shut.insert(id) } }
        for (id, now) in laid where before[id] == nil {
            guard case .folder(let group) = now.block, !shut.contains(group) || openedNow.contains(group), let parent = now.parent,
                  parent.isFlipped,
                  let view = rows[id], view.superview === parent, let old = cards[group], let card = cardFrames[group],
                  let heading = headingFrames[group] else { continue }
            let shown = cardsShown[group] ?? (old, 0)
            let top = parent.convert(heading, from: self).maxY
            let from = max(top, parent.convert(shown.frame, from: self).maxY)
            let to = parent.convert(card, from: self).maxY
            let back = reclaimed.removeValue(forKey: id)
            let lift = reclaimedLift.removeValue(forKey: id) ?? -capped(keptShift(group))
            reveal(view, frame: now.frame, from: from, to: to, top: top, lift: lift,
                   velocity: to - from > 0.01 ? shown.speed / Double(to - from) : 0, opacity: back ?? 0)
        }
        reclaimed = [:]
        reclaimedLift = [:]
    }

    fileprivate func shownCard(_ id: UUID, model: NSRect) -> (frame: NSRect, speed: Double) {
        guard let plate = cards[.card(id)], let layer = plate.layer, let parent = plate.superview else { return (model, 0) }
        let growing = layer.kitSpeed(forKey: "bounds.size").map { $0[1] } ?? 0
        guard layer.animation(forKey: "bounds.size") != nil || layer.animation(forKey: "position") != nil,
              let shown = layer.presentation() else { return (model, growing) }
        return (parent.convert(shown.frame, to: self), growing)
    }

    fileprivate func reclaim(_ id: UUID, into parent: NSView) -> TabRowView? {
        guard animating, let view = leaving.removeValue(forKey: id), let layer = view.layer,
              let holder = view.superview as? SideFoldClip else { return nil }
        let shown = layer.presentation() ?? layer
        let back = shown.opacity
        let lift = holder.isFlipped ? shown.transform.m42 : -shown.transform.m42
        layer.setValue(nil, forKey: "leaving")
        for key in ["retire.opacity", "retire.transform", "position", "enter.opacity"] { layer.removeAnimation(forKey: key) }
        layer.mask = nil
        let frame = holder.convert(view.frame, to: parent)
        view.removeFromSuperview()
        parent.addSubview(view)
        view.frame = frame
        if holder.subviews.isEmpty { holder.removeFromSuperview() }
        view.setAccessibilityElement(true)
        rows[id] = view
        reclaimed[id] = back
        reclaimedLift[id] = lift
        return view
    }

    fileprivate func reveal(_ view: NSView, frame: NSRect, from: CGFloat, to: CGFloat, top: CGFloat, lift: CGFloat, velocity: Double,
                            opacity: Swift.Float) {
        guard let layer = view.layer, view.alphaValue > 0 else { return }
        layer.removeAnimation(forKey: "position")
        if opacity < layer.opacity - 0.01, let fade = settle.animation("opacity", from: opacity, to: layer.opacity) {
            fade.fillMode = .backwards
            layer.add(fade, forKey: "enter.opacity")
        }
        let lifts = abs(lift) > 0.01
        if lifts {
            let model = view.frame
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.frame = model.offsetBy(dx: 0, dy: lift)
            let start = layer.position
            view.frame = model
            CATransaction.commit()
            if let slide = settle.animation("position", from: NSValue(point: start), to: NSValue(point: layer.position), velocity: velocity) {
                slide.fillMode = .backwards
                layer.add(slide, forKey: "position")
            }
            guard frame.maxY + lift > from || frame.minY + lift < top else { return }
        } else {
            guard to - from > 0.01, frame.maxY > from else { return }
        }
        let width = view.bounds.width
        func shown(_ upper: CGFloat, _ lower: CGFloat) -> NSRect {
            let tall = max(0, lower - upper)
            let rect = view.isFlipped ? NSRect(x: -width, y: upper, width: 3 * width, height: tall)
                : NSRect(x: -width, y: frame.height - lower, width: 3 * width, height: tall)
            return view.convertToLayer(rect)
        }
        let first = lifts ? shown(top - frame.minY - lift, from - frame.minY - lift) : shown(from - frame.minY - 4000, from - frame.minY)
        let last = lifts ? shown(top - frame.minY, to - frame.minY) : shown(to - frame.minY - 4000, to - frame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let mask = CALayer()
        mask.backgroundColor = NSColor.black.cgColor
        mask.frame = last
        layer.mask = mask
        CATransaction.commit()
        guard let edge = settle.animation("position", from: NSValue(point: CGPoint(x: first.midX, y: first.midY)),
                                          to: NSValue(point: CGPoint(x: last.midX, y: last.midY)), velocity: velocity) else {
            layer.mask = nil
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in if layer?.mask === mask { layer?.mask = nil } }
        edge.fillMode = .backwards
        mask.add(edge, forKey: "position")
        if first.size != last.size,
           let grow = settle.animation("bounds.size", from: NSValue(size: first.size), to: NSValue(size: last.size), velocity: velocity) {
            grow.fillMode = .backwards
            mask.add(grow, forKey: "bounds.size")
        }
        CATransaction.commit()
    }

    fileprivate func foldClip(_ was: SideLaid?, view: NSView, cards: [UUID: NSRect],
                              clips: inout [UUID: (view: SideFoldClip, velocity: Double)])
        -> (drift: CGFloat, velocity: Double, shift: CGFloat)? {
        guard animating, folded(was), let was, case .folder(let id) = was.block, let parent = was.parent, parent.isFlipped,
              view.superview === parent, let old = cards[id], let now = cardFrames[id], let heading = headingFrames[id] else { return nil }
        let shift = keptShift(id)
        let clip: (view: SideFoldClip, velocity: Double)
        if let made = clips[id] {
            clip = made
        } else {
            let shown = cardsShown[id] ?? (old, 0)
            let from = parent.convert(shown.frame, from: self)
            let to = parent.convert(now, from: self)
            let top = parent.convert(heading, from: self).maxY
            guard from.maxY > top else { return nil }
            let holder = SideFoldClip()
            holder.wantsLayer = true
            holder.clipsToBounds = !SelectedLook.unclipped
            let room = SelectedLook.room
            let lid = shift == 0 ? room : 0
            let start = NSRect(x: from.minX - room, y: top - lid, width: from.width + 2 * room, height: from.maxY - top + lid)
            let travel = Double(to.maxY - from.maxY)
            let carried = abs(travel) > 0.01 ? shown.speed / travel : 0
            parent.addSubview(holder, positioned: .above, relativeTo: view)
            holder.frame = holder.kitSnapped(NSRect(x: to.minX - room, y: top - lid, width: to.width + 2 * room,
                                                    height: max(0, to.maxY - top + lid)))
            if let layer = holder.layer {
                let end = (position: layer.position, size: layer.bounds.size)
                holder.frame = holder.kitSnapped(start)
                for (key, was, now) in [("position", NSValue(point: layer.position), NSValue(point: end.position)),
                                        ("bounds.size", NSValue(size: layer.bounds.size), NSValue(size: end.size))] {
                    guard let animation = settle.animation(key, from: was, to: now, velocity: carried) else { continue }
                    animation.fillMode = .forwards
                    animation.isRemovedOnCompletion = false
                    layer.add(animation, forKey: "fold.\(key)")
                }
            }
            clip = (holder, carried)
            clips[id] = clip
        }
        var drift: CGFloat = 0
        if let layer = view.layer {
            drift = (layer.presentation()?.position.y ?? layer.position.y) - layer.position.y + shift - capped(shift)
            layer.removeAnimation(forKey: "position")
            layer.mask = nil
        }
        let frame = parent.convert(view.frame, to: clip.view)
        view.removeFromSuperview()
        clip.view.addSubview(view)
        view.frame = frame
        return (drift, clip.velocity, shift)
    }

    fileprivate func retire(_ view: NSView, rise: CGFloat = 0, fade duration: CFTimeInterval = 0.14, covered: Bool = false,
                            drift: CGFloat = 0, velocity: Double = 0, shift: CGFloat = 0, leaving id: UUID? = nil) {
        guard animating, view.superview != nil, let layer = view.layer else {
            view.removeFromSuperview()
            return
        }
        let shown = layer.presentation() ?? layer
        let holder = view.superview as? SideFoldClip
        leaves += 1
        let mine = leaves
        layer.setValue(mine, forKey: "leaving")
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard layer.value(forKey: "leaving") as? Int == mine else { return }
            layer.setValue(nil, forKey: "leaving")
            if let id, self?.leaving[id] === view { self?.leaving[id] = nil }
            view.removeFromSuperview()
            if let holder, holder.subviews.isEmpty { holder.removeFromSuperview() }
        }
        let lifted = drift == 0 ? shown.transform : CATransform3DConcat(shown.transform, CATransform3DMakeTranslation(0, drift, 0))
        let fade: CAAnimation
        let move: CAAnimation
        let landing = shift == 0 ? CATransform3DIdentity
            : CATransform3DMakeTranslation(0, view.superview?.isFlipped == true ? shift : -shift, 0)
        if covered, let dim = settle.animation("opacity", from: shown.opacity, to: Swift.Float(0)),
           let rest = settle.animation("transform", from: NSValue(caTransform3D: lifted), to: NSValue(caTransform3D: landing),
                                       velocity: velocity) {
            fade = dim
            move = rest
        } else {
            let plain = CABasicAnimation(keyPath: "opacity")
            plain.fromValue = shown.opacity
            plain.toValue = 0
            plain.duration = duration
            plain.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade = plain
            let squash = CABasicAnimation(keyPath: "transform")
            let middle = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            var matrix = CATransform3DMakeTranslation(middle.x, middle.y, 0)
            matrix = CATransform3DScale(matrix, 1, 0.6, 1)
            matrix = CATransform3DTranslate(matrix, -middle.x, -middle.y, 0)
            if rise != 0 { matrix = CATransform3DConcat(matrix, CATransform3DMakeTranslation(0, view.superview?.isFlipped == true ? -rise : rise, 0)) }
            squash.fromValue = NSValue(caTransform3D: lifted)
            squash.toValue = NSValue(caTransform3D: matrix)
            squash.duration = 0.18
            squash.timingFunction = CAMediaTimingFunction(name: .easeOut)
            move = squash
        }
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: "retire.opacity")
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false
        layer.add(move, forKey: "retire.transform")
        CATransaction.commit()
        (view as? NSView & NSAccessibilityElementProtocol)?.setAccessibilityElement(false)
    }
}

final class SideFoldClip: KitFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class FolderLightView: NSView {
    private(set) var radius: CGFloat = SideLook.cardRowRadius
    private(set) var tone: CGColor = NSColor.clear.cgColor
    private(set) var lit = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = radius
        layer?.backgroundColor = tone
    }

    func shape(radius: CGFloat, tone: CGColor, curve: KitCurve) {
        guard radius != self.radius || tone != self.tone, let layer else { return }
        let shown = layer.presentation() ?? layer
        let fromRadius = shown.cornerRadius
        let fromTone = shown.backgroundColor ?? self.tone
        let carry = layer.kitCarry("cornerRadius", from: NSNumber(value: Double(fromRadius)), to: NSNumber(value: Double(radius)))
        self.radius = radius
        self.tone = tone
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        layer.backgroundColor = tone
        CATransaction.commit()
        layer.removeAnimation(forKey: "cornerRadius")
        layer.removeAnimation(forKey: "backgroundColor")
        guard window != nil else { return }
        if fromRadius != radius, let bend = curve.animation("cornerRadius", from: fromRadius, to: radius, velocity: carry) {
            bend.fillMode = .backwards
            layer.add(bend, forKey: "cornerRadius")
        }
        if fromTone != tone, let shade = curve.animation("backgroundColor", from: fromTone, to: tone, velocity: carry) {
            shade.fillMode = .backwards
            layer.add(shade, forKey: "backgroundColor")
        }
    }

    func light(_ on: Bool, curve: KitCurve) {
        guard on != lit, let layer else { return }
        lit = on
        let target: Swift.Float = on ? 1 : 0
        let from = (layer.presentation() ?? layer).opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "light.opacity")
        guard window != nil, let fade = curve.animation("opacity", from: from, to: target) else { return }
        fade.fillMode = .backwards
        layer.add(fade, forKey: "light.opacity")
    }
}

final class SideListClipView: KitFlippedView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

extension SidePageView {
    func benchCarry() -> [String: Any] {
        guard Store.testing, preview == nil, !embedded, let content = window?.contentView else { return [:] }
        func shown(_ view: NSView) -> [Double]? {
            guard !view.isHiddenOrHasHiddenAncestor, let superview = view.superview else { return nil }
            let moving = !(view.layer?.animationKeys() ?? []).isEmpty
            let layer = moving ? view.layer?.presentation() ?? view.layer : view.layer
            let opacity = Double(layer?.opacity ?? 1) * Double(view.alphaValue)
            let frame = moving ? layer.map { superview.convert($0.frame, to: content) } ?? superview.convert(view.frame, to: content)
                : superview.convert(view.frame, to: content)
            let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
            return [frame.minX, top, frame.width, frame.height, opacity].map { (Double($0) * 10).rounded() / 10 }
        }
        func placed(_ rect: NSRect?) -> [Double]? {
            guard let rect else { return nil }
            let frame = convert(rect, to: content)
            let top = content.isFlipped ? frame.minY : content.bounds.height - frame.maxY
            return [frame.minX, top, frame.width, frame.height].map { (Double($0) * 10).rounded() / 10 }
        }
        var out: [String: Any] = [:]
        var drawn: [String: [Double]] = [:]
        for (id, view) in rows {
            guard let tab = browser.tabs.first(where: { $0.id == id }), let frame = shown(view) else { continue }
            drawn[Bench.short(tab)] = frame
        }
        out["rows"] = drawn
        var squares: [String: [Double]] = [:]
        for (id, view) in pins {
            guard let tab = browser.tabs.first(where: { $0.id == id }), let frame = shown(view) else { continue }
            squares[Bench.short(tab)] = frame
        }
        out["pins"] = squares
        if let carry {
            out["carried"] = Bench.short(carry.tab)
            if let view = carry.view, let frame = shown(view) { out["carry"] = frame }
        }
        if let morphView, let frame = shown(morphView) { out["morph"] = frame }
        if let frame = shown(dropLine) { out["line"] = frame }
        if let frame = shown(dropOutline) { out["outline"] = frame }
        if let frame = shown(folderLine) { out["folderLine"] = frame }
        if let gap = placed(gapRect) { out["gap"] = gap }
        if let grid = placed(gridRect) { out["grid"] = grid }
        var lit: [String] = []
        for (id, light) in lights where (light.layer?.presentation()?.opacity ?? light.layer?.opacity ?? 0) > 0.05 && !light.isHidden {
            lit.append(browser.tabGroups.first { $0.id == id }?.name ?? "")
        }
        out["lit"] = lit
        out["top"] = topLine.kitEdgeShown
        if let id = carry?.tab.id ?? morphCarried {
            var copies: [[Double]] = []
            for view in listDocument.kitSubviews(of: TabRowView.self) where view.tab?.id == id {
                if let frame = shown(view), frame[4] > 0.05 { copies.append(frame) }
            }
            if let pin = pins[id], let frame = shown(pin), frame[4] > 0.05 { copies.append(frame) }
            if let morphView, let frame = shown(morphView), frame[4] > 0.05 { copies.append(frame) }
            out["copies"] = copies
            out["tile"] = hand.tile
            let point = convert(hand.point, to: content)
            out["hand"] = [Double(point.x), Double(content.isFlipped ? point.y : content.bounds.height - point.y)]
        }
        return out
    }
}

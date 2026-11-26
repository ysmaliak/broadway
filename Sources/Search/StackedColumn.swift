import AppKit
import Combine

final class StackedColumnView: NSView {
    let browser: Browser
    var onFrame = false { didSet { if onFrame != oldValue { restyle() } } }
    var floating = false { didSet { if floating != oldValue { restyle() } } }
    var ground = RowGround() { didSet { if ground != oldValue { restyle() } } }

    let lift = StackedLift()
    let cuts = StackedCuts()
    private let folds = StackedFolds.shared
    private let scroll = SideScrollView()
    private let document = KitFlippedView()
    private var sections: [UUID: StackedSectionView] = [:]
    private let newSpace: QuietRowView
    private var scrollWatch: AnyCancellable?
    private var lastScroll = StackedScroll()
    private var lit: UUID? { didSet { if lit != oldValue { litChanged() } } }
    private var laidOnce = false
    private var heads: [UUID: CGRect] = [:]
    private var bodies: [UUID: CGRect] = [:]
    private let bottomLine = KitPlate(fill: KitTone.ink.opacity(0.1))
    let motion = StackedFoldMotion()
    private var foldSeen: [UUID: Bool] = [:]
    private var insets: [UUID: CGFloat] = [:]
    var documentView: NSView { document }
    var outerScroll: NSScrollView { scroll }
    func section(_ id: UUID) -> StackedSectionView? { sections[id] }

    init(browser: Browser) {
        self.browser = browser
        newSpace = QuietRowView(icon: "plus.rectangle.on.rectangle", title: "New Space", act: {})
        super.init(frame: .zero)
        wantsLayer = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        bottomLine.isHidden = true
        addSubview(bottomLine)
        document.addSubview(newSpace)
        newSpace.act = { [weak browser] in browser?.askForSpace() }
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        lift.scroll = { [weak self] y in self?.scrollTo(y, animated: false) }
        lift.commit = { [weak browser] id, index in browser?.moveSpace(id, to: index) }
        scrollWatch = kitObserve({ [weak browser] in browser?.stackedScroll }) { [weak self] _ in self?.changed() }
        motion.view = self
        motion.tick = { [weak self] _ in
            guard let self else { return }
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        follow()
        browser.loadStackedRows()
        folds.reload()
        if Store.testing {
            StackedProbe.lift = lift
            StackedProbe.begin = { [weak self] id in
                guard let self, let head = heads[id] else { return }
                begin(id, at: head.midY - lift.scrolled)
            }
            StackedProbe.inner = { [weak self] in self?.sections.mapValues(\.listOffset) ?? [:] }
            StackedProbe.scroll = { [weak self] y in self?.scrollTo(y, animated: false) }
            StackedProbe.run = { [weak self] from, to, step in self?.probeRun(from: from, to: to, step: step) }
            StackedProbe.wheel = { [weak self] dy, steps, ms, glide, y in self?.probeWheel(dy: dy, steps: steps, ms: ms, glide: glide, y: y) }
        }
    }

    private var probeTimer: Timer?

    private func probeRun(from: CGFloat, to: CGFloat, step: CGFloat) {
        probeTimer?.invalidate()
        scrollTo(from, animated: false)
        StackedProbe.trace = []
        StackedProbe.tracing = true
        var y = from
        let sign: CGFloat = to >= from ? 1 : -1
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                y += sign * abs(step)
                if (y - to) * sign >= 0 {
                    y = to
                    timer.invalidate()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { StackedProbe.tracing = false }
                }
                let clip = self.scroll.contentView
                clip.setBoundsOrigin(NSPoint(x: 0, y: y))
                self.scroll.reflectScrolledClipView(clip)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    func takeWheel(_ event: NSEvent) { scroll.scrollWheel(with: event) }

    private func probeWheel(dy: Double, steps: Int, ms: Double, glide: Int, y: CGFloat) {
        guard let window, let root = window.contentView else { return }
        let inWindow = convert(NSPoint(x: bounds.midX, y: y), to: nil)
        let hit = root.hitTest(inWindow) ?? scroll
        StackedProbe.hit = String(describing: type(of: hit))
        let route = StackedProbe.route
        let phased = route != "legacy"
        func send(_ phase: Int64, _ momentum: Int64, _ delta: Double) {
            guard phased || phase == 2 || momentum == 2 else { return }
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta), wheel2: 0, wheel3: 0) else { return }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            if phased {
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
            }
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
            cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(delta))
            guard let event = NSEvent(cgEvent: cg) else { return }
            if route == "app" { window.sendEvent(event) } else { hit.scrollWheel(with: event) }
        }
        send(128, 0, 0)
        send(1, 0, 0)
        let each = ms / 1000 / Double(steps)
        for n in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + each * Double(n)) {
                send(2, 0, dy / Double(steps))
                if n == steps { send(4, 0, 0) }
            }
        }
        for n in 0..<glide {
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 + 0.016 * Double(n + 1)) {
                let k = pow(0.88, Double(n + 1))
                send(0, n == 0 ? 1 : (n == glide - 1 ? 3 : 2), dy / Double(steps) * k)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isFlipped: Bool { true }

    private func follow() {
        withObservationTracking {
            _ = lift.carrying
            _ = lift.order
            _ = lift.shift
            _ = lift.lead
            _ = lift.tail
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.liftChanged()
                    self?.follow()
                }
            }
        }
    }

    private var pendingChange = false

    private func changed() {
        guard !pendingChange else { return }
        pendingChange = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingChange = false
            needsLayout = true
            if browser.stackedScroll != lastScroll {
                lastScroll = browser.stackedScroll
                if let id = lastScroll.space {
                    layoutSubtreeIfNeeded()
                    if let head = heads[id] { scrollTo(sectionTop(id) ?? head.minY, animated: !Store.testing) }
                }
            }
        }
    }

    private func liftChanged() {
        needsLayout = true
    }

    private func restyle() {
        for section in sections.values {
            section.style(onFrame: onFrame, floating: floating, ground: ground)
        }
        newSpace.greys = ground.greys
        newSpace.ink = ground.ink
        needsLayout = true
    }

    private var order: [Space] {
        guard let order = lift.order else { return browser.spaces }
        let byID = Dictionary(browser.spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let drawn = order.compactMap { byID[$0] }
        return drawn.count == browser.spaces.count ? drawn : browser.spaces
    }

    private func count(_ id: UUID) -> Int {
        let row = id == browser.spaceID ? browser.tabs : browser.parked[id]?.tabs ?? []
        return row.filter { $0.pin == nil && !$0.isBlank }.count
    }

    private var sectionTops: [UUID: CGFloat] = [:]
    private func sectionTop(_ id: UUID) -> CGFloat? { sectionTops[id] }

    private var readingLine: CGFloat {
        let top = scroll.contentView.bounds.minY
        return top > 0.5 ? top + StackedHeaderView.height : 0
    }

    private func setFrame(_ view: NSView, _ frame: NSRect, animated: Bool) {
        if animated, !view.frame.isEmpty {
            view.kitMove(to: frame, animated: true)
            return
        }
        if let layer = view.layer, layer.animation(forKey: "position") != nil || layer.animation(forKey: "bounds.size") != nil {
            layer.removeAnimation(forKey: "position")
            layer.removeAnimation(forKey: "bounds.size")
        }
        if view.frame != frame { view.frame = frame }
    }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(x: 0, y: 0, width: bounds.width, height: viewport)
        let width = bounds.width
        let gathered = lift.carrying != nil
        let spaces = order
        let canMove = laidOnce && !Motion.reduced && window != nil
        var shift: CGFloat = 0
        var turned: [UUID: Bool] = [:]
        for space in spaces {
            let folded = folds.isFolded(space.id)
            if let was = foldSeen[space.id], was != folded { turned[space.id] = folded }
            foldSeen[space.id] = folded
        }
        for (id, folding) in turned where canMove && !gathered {
            if !folding, !motion.moving(id), let body = bodies[id], body.minY < readingLine {
                continue
            }
            motion.start(id, folding: folding)
        }
        let animated = laidOnce && !Motion.reduced && !motion.moving
        var kept = Set<UUID>()
        var y = lift.lead
        sectionTops = [:]
        var naturalHeads: [(UUID, CGFloat, CGFloat)] = []
        for (index, space) in spaces.enumerated() {
            let section = sections[space.id] ?? {
                let made = StackedSectionView(browser: browser, space: space, column: self)
                made.style(onFrame: onFrame, floating: floating, ground: ground)
                sections[space.id] = made
                document.addSubview(made.body)
                document.addSubview(made.header)
                return made
            }()
            let id = space.id
            kept.insert(id)
            let wasHeight = bodies[id]?.height
            let wasMoving = section.moving
            section.header.space = space
            section.header.count = count(id)
            section.header.gathered = gathered
            section.header.lifted = lift.carrying == id
            section.header.lit = lit == id
            section.header.onFrame = onFrame
            section.header.ink = ground.ink
            section.header.cuts = cuts
            section.gathered = gathered
            section.moving = motion.moving(id) && !gathered
            section.refresh(width: width)
            let folded = folds.isFolded(id)
            if section.moving, !wasMoving, let folding = turned[id], folding, let body = bodies[id] {
                let line = readingLine
                let removed = max(0, min(line - body.minY, section.openHeight - section.foldedHeight))
                insets[id] = removed
                shift -= removed
            }
            if !section.moving, wasMoving {
                if !folded, let inset = insets[id], inset > 0 { shift += inset }
                insets[id] = nil
            }
            if !section.moving, !wasMoving, let folding = turned[id], !folding, let wasHeight {
                let grown = section.bodyHeight - wasHeight
                if let body = bodies[id], body.minY < readingLine, grown > 0 { shift += grown }
            }
            if !section.moving, !wasMoving, let folding = turned[id], folding, let wasHeight, let body = bodies[id],
               body.minY < readingLine {
                shift -= max(0, wasHeight - section.bodyHeight)
            }
            let open = motion.openness(id, folded: folded)
            section.header.openness = gathered ? (folded ? 0 : 1) : open
            let inset = insets[id] ?? 0
            let tail: CGFloat = index == spaces.count - 1 ? 8 : StackedSpaces.gap
            sectionTops[id] = y
            let headTop = y
            y += StackedHeaderView.height
            let bodyTop = y + StackedSpaces.bodyTop
            let bodyHeight = section.height(open: open, inset: inset)
            let bodyFrame = NSRect(x: 0, y: bodyTop, width: width, height: bodyHeight)
            setFrame(section.body, bodyFrame, animated: animated && !section.body.frame.isEmpty)
            section.place(open: open, inset: inset)
            bodies[id] = bodyFrame
            if Store.testing {
                StackedProbe.open[id] = open
                StackedProbe.bodies[id] = bodyFrame
            }
            y = bodyTop + bodyHeight + tail
            naturalHeads.append((id, headTop, bodyTop + bodyHeight))
        }
        for (id, section) in sections where !kept.contains(id) {
            section.header.removeFromSuperview()
            section.body.removeFromSuperview()
            sections[id] = nil
            motion.stop(id)
            insets[id] = nil
            foldSeen[id] = nil
            cuts.note(head: id, bottom: nil)
            cuts.note(body: id, top: nil)
        }
        newSpace.greys = ground.greys
        newSpace.ink = ground.ink
        newSpace.height = browser.prefs.sideRow
        newSpace.size = browser.prefs.sideTitle
        let rowFrame = NSRect(x: Metrics.sideInset, y: y, width: width - 2 * Metrics.sideInset, height: browser.prefs.sideRow)
        setFrame(newSpace, rowFrame, animated: animated)
        y += browser.prefs.sideRow + 8 + lift.tail
        let documentHeight = max(y, viewport)
        let top = scroll.contentView.bounds.minY
        if document.frame.size != NSSize(width: width, height: documentHeight) {
            document.frame = NSRect(x: 0, y: 0, width: width, height: documentHeight)
        }
        if abs(shift) > 0.01 {
            let clip = scroll.contentView
            let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: top + shift), size: clip.bounds.size)).origin
            clip.setBoundsOrigin(target)
            scroll.reflectScrolledClipView(clip)
        }
        scroll.scrolls = y > viewport + 0.5
        lift.content = y
        lift.viewport = viewport
        placeHeads(naturalHeads, animated: animated)
        laidOnce = true
        if Store.testing { driveProbe() }
    }

    func reveal(_ rect: NSRect) {
        let clip = scroll.contentView.bounds
        let above = clip.minY + StackedHeaderView.height + 4
        let below = clip.minY + viewport - 4
        var y = clip.minY
        if rect.minY < above { y = rect.minY - StackedHeaderView.height - 4 } else if rect.maxY > below { y = rect.maxY - viewport + 4 } else { return }
        scrollTo(max(0, y), animated: !Store.testing)
    }

    private var livePage: SidePageView? { sections[browser.spaceID]?.livePage }
    private var viewport: CGFloat { max(0, bounds.height - ColumnEdges.clear) }

    private func placeHeld() {
        let clip = scroll.contentView.bounds
        let hair = 1 / max(1, window?.backingScaleFactor ?? 2)
        let page = livePage
        if let page {
            page.heldFloor = page.convert(NSPoint(x: 0, y: clip.maxY), from: document).y
        }
        let heldNow = page?.heldFloored ?? false
        let heldFrame = page.flatMap { page in page.heldFrame.map { convert($0, from: page) } }
        let runsUnder = document.frame.height > clip.maxY + 0.5
        let lineBottom = heldNow ? (heldFrame?.minY ?? viewport) - Metrics.sideGap : viewport
        bottomLine.ink = ground.ink
        bottomLine.kitEdge(runsUnder || heldNow)
        bottomLine.kitSetFrame(NSRect(x: 0, y: lineBottom - hair, width: bounds.width, height: hair))
        guard Store.testing, let content = window?.contentView else { return }
        func top(_ rect: NSRect) -> CGFloat { content.isFlipped ? rect.minY : content.bounds.height - rect.maxY }
        var seen = ColumnEdges.seen
        if let page, let frame = page.heldFrame {
            let shown = page.convert(frame, to: content)
            seen["newTabX"] = shown.minX
            seen["newTabY"] = top(shown)
            seen["newTabW"] = shown.width
            seen["newTabH"] = shown.height
        }
        seen["newTabHeld"] = heldNow ? 1 : 0
        let line = convert(NSRect(x: 0, y: lineBottom - hair, width: bounds.width, height: hair), to: content)
        seen["lineY"] = top(line) + line.height
        seen["top"] = clip.minY > 1 ? 1 : 0
        seen["bottom"] = runsUnder ? 1 : 0
        ColumnEdges.seen = seen
    }

    private func driveProbe() {
        PinDragProbe.shared.drive = { [weak self] id, point, ended in
            guard let self, let page = livePage else { return false }
            let document = self.document
            let local = point.map { page.convert(document.convert(CGPoint(x: $0.x - Metrics.sideInset, y: $0.y), to: nil), from: nil) }
            return page.probe(id, local, ended: ended)
        }
    }

    private var naturalHeads: [(UUID, CGFloat, CGFloat)] = []
    private var lastNaturals: [UUID: CGFloat] = [:]

    private func placeHeads(_ heads: [(UUID, CGFloat, CGFloat)], animated: Bool) {
        naturalHeads = heads
        placeHeads(animated: animated)
    }

    private func placeHeads(animated: Bool) {
        let top = scroll.contentView.bounds.minY
        let gathered = lift.carrying != nil
        let width = bounds.width
        let height = StackedHeaderView.height
        for (index, (id, natural, end)) in naturalHeads.enumerated() {
            guard let section = sections[id] else { continue }
            let limit = index + 1 < naturalHeads.count ? naturalHeads[index + 1].1 : end + 8
            var y = natural
            if !gathered { y = max(natural, min(top, limit - height)) }
            if lift.carrying == id { y = natural + lift.shift }
            let frame = NSRect(x: Metrics.sideInset, y: y, width: width - 2 * Metrics.sideInset, height: height)
            let settled = lastNaturals[id].map { abs($0 - natural) > 0.5 } ?? false
            if section.header.frame != frame {
                if animated, settled, lift.carrying != id, !section.header.frame.isEmpty, abs(section.header.frame.minY - y) > 1, top == lastTop {
                    section.header.kitMove(to: frame, animated: true)
                } else {
                    setFrame(section.header, frame, animated: false)
                }
            }
            lastNaturals[id] = natural
            let cut = max(0, frame.maxY - (bodies[id]?.minY ?? 0))
            section.header.held = lift.carrying == id || gathered ? 0 : min(1, cut / StackedSpaces.heldRamp)
            heads[id] = frame
            cuts.note(head: id, bottom: frame.maxY)
            cuts.note(body: id, top: bodies[id]?.minY)
            section.cut(top: cut)
            if Store.testing { StackedProbe.headers[id] = lift.carrying == id ? frame.offsetBy(dx: 0, dy: -lift.shift) : frame }
        }
        lastTop = top
        lift.scrolled = top
        placeHeld()
        if Store.testing {
            StackedProbe.scrolled = top
            StackedProbe.content = document.frame.height
            if StackedProbe.tracing { traceFrame(top) }
            StackedProbe.viewport = viewport

            StackedProbe.gathered = gathered ? Set(naturalHeads.map(\.0)) : []
            if let window, let content = window.contentView {
                let frame = document.convert(document.bounds, to: content)
                PinDragProbe.shared.page = CGRect(x: frame.minX, y: content.isFlipped ? frame.minY : content.bounds.height - frame.maxY,
                                                  width: frame.width, height: frame.height)
            }
        }
    }

    private var lastTop: CGFloat = 0

    private func traceFrame(_ top: CGFloat) {
        var row: [String: Any] = ["t": CACurrentMediaTime(), "top": top]
        var heads: [[String: Any]] = []
        for (id, natural, end) in naturalHeads {
            guard let section = sections[id] else { continue }
            let shown = section.header.layer?.presentation() ?? section.header.layer
            heads.append(["y": section.header.frame.minY - top, "natural": natural - top, "end": end - top,
                          "cut": section.body.cutTop, "held": section.header.held,
                          "scale": shown.map { Double($0.transform.m22) } ?? 1,
                          "moving": section.header.layer?.animation(forKey: "position") != nil])
        }
        row["heads"] = heads
        StackedProbe.trace.append(row)
    }

    @objc private func scrolled() {
        placeHeads(animated: false)
        livePage?.noteBench()
    }

    private func scrollTo(_ y: CGFloat, animated: Bool) {
        let clip = scroll.contentView
        let target = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin
        if animated, !Motion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.columnScroll
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.scroll(to: target)
        }
        scroll.reflectScrolledClipView(clip)
    }

    func begin(_ id: UUID, at y: CGFloat) {
        guard let head = heads[id] else { return }
        lift.begin(id, ids: browser.spaces.map(\.id), at: y, top: sectionTops[id] ?? head.minY,
                   step: StackedHeaderView.height + StackedSpaces.bodyTop + StackedSpaces.gap)
    }

    func carried(_ id: UUID, _ carry: StackedHeaderView.Carry) {
        switch carry {
        case .begin(let y): begin(id, at: y)
        case .move(let y): lift.move(to: y)
        case .end: lift.end()
        }
    }

    func outside(_ tab: Tab, _ point: CGPoint?, ended: Bool) -> Bool {
        guard browser.stacked else { return false }
        var over: UUID?
        if let point {
            let local = document.convert(point, from: nil)
            over = StackedSpaces.section(at: local, heads: heads, bodies: bodies, except: browser.spaceID)
        }
        if ended {
            let target = lit
            lit = nil
            guard point != nil, let target else { return false }
            browser.stackedDrop(tab, onto: target)
            return true
        }
        if over != lit {
            if lit == nil, over != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            lit = over
        }
        return over != nil
    }

    private func litChanged() {
        if Store.testing { StackedProbe.lit = lit }
        for (id, section) in sections { section.header.lit = lit == id }
    }
}

@MainActor
final class StackedSectionView {
    enum Kind { case live, parked, front }

    let header: StackedHeaderView
    let body = StackedBodyView()
    let browser: Browser
    private(set) var space: Space
    private weak var column: StackedColumnView?
    var gathered = false
    var moving = false
    private var page: SidePageView?
    private var kind: Kind?
    private var traveler: SidePageView?
    var livePage: SidePageView? { kind == .live ? page : nil }
    var listOffset: CGFloat { page?.listOffset ?? 0 }
    var pages: [SidePageView] { [page, traveler].compactMap { $0 } }
    var openPage: SidePageView? { kind == .front ? nil : page }
    private var picks: [Tab.ID: StackedPickView] = [:]
    private let quiet: QuietRowView
    private var onFrame = false
    private var floating = false
    private var ground = RowGround()
    private var width: CGFloat = 0
    private var front: Tab.ID?

    init(browser: Browser, space: Space, column: StackedColumnView) {
        self.browser = browser
        self.space = space
        self.column = column
        header = StackedHeaderView(browser: browser, space: space, count: 0)
        quiet = QuietRowView(icon: "plus", title: "New Tab", act: {})
        header.column = column
        let id = space.id
        header.carry = { [weak column] carry in column?.carried(id, carry) }
        quiet.act = { [weak browser] in browser?.stackedNewTab(in: id) }
        quiet.isHidden = true
        body.addSubview(quiet)
    }

    func style(onFrame: Bool, floating: Bool, ground: RowGround) {
        self.onFrame = onFrame || floating
        self.floating = floating
        self.ground = ground
        for made in [page, traveler].compactMap({ $0 }) {
            made.onFrame = onFrame
            made.floating = floating
            made.ground = ground
        }
        quiet.greys = ground.greys
        quiet.ink = ground.ink
        for pick in picks.values {
            pick.onFrame = self.onFrame
            pick.ink = ground.ink
        }
        header.ground = groundView()
    }

    private func groundView() -> NSView {
        if onFrame {
            return LiveGroundView(browser: browser, motion: browser.spaceMotion, opaque: true)
        }
        return KitBox(fill: Palette.NS.ground)
    }

    private var live: Bool { space.id == browser.spaceID }
    private var folded: Bool { StackedFolds.shared.isFolded(space.id) }
    private var quietShown: Bool { !quiet.isHidden }

    var openHeight: CGFloat {
        if gathered { return 0 }
        guard kind != .front else { return foldedHeight }
        return (page?.naturalHeight ?? 0) + (quietShown ? browser.prefs.sideRow : 0)
    }

    var foldedHeight: CGFloat {
        if gathered { return 0 }
        if let traveler { return traveler.naturalHeight }
        return kind == .front ? page?.naturalHeight ?? 0 : 0
    }

    var bodyHeight: CGFloat { folded && !moving ? foldedHeight : openHeight }

    func height(open: CGFloat, inset: CGFloat) -> CGFloat {
        if gathered { return 0 }
        guard moving else { return bodyHeight }
        let low = foldedHeight
        let high = max(low, openHeight - inset)
        return low + (high - low) * open
    }

    func cut(top: CGFloat) {
        body.cutTop = top
    }

    private func frontPreview() -> SidePreview {
        let id = space.id
        let front = browser.activeSplit?.left ?? browser.activeID
        let tabs = browser.tabs.filter { $0.id == front && !$0.isBlank }
        return SidePreview(space: id, row: Parked(tabs: tabs, active: front), rest: ColumnRest())
    }

    private func parkedPreview() -> SidePreview {
        let id = space.id
        let shared = Set(browser.prefs.showsSharedPins ? Pins.shared().map(\.id) : [])
        let row = browser.parked[id] ?? Parked(tabs: [], active: nil)
        let pins = StackedSpaces.own(row.tabs.filter { $0.pin != nil }, id: \.pinID, shared: shared)
        var kept = row
        kept.tabs = row.tabs.filter { $0.pin == nil } + pins
        kept.active = nil
        return SidePreview(space: id, row: kept, rest: ColumnRest())
    }

    private func make(_ kind: Kind) -> SidePageView {
        let preview: SidePreview? = switch kind {
        case .live: nil
        case .parked: parkedPreview()
        case .front: frontPreview()
        }
        let made = SidePageView(browser: browser, preview: preview)
        made.embedded = true
        made.onFrame = onFrame
        made.floating = floating
        made.ground = ground
        made.onHeight = { [weak column] _ in column?.needsLayout = true }
        if kind == .live {
            made.outside = { [weak column] tab, point, ended in column?.outside(tab, point, ended: ended) ?? false }
            made.onReveal = { [weak column, weak made] rect in
                guard let column, let made else { return }
                column.reveal(made.convert(rect, to: column.documentView))
            }
        }
        body.addSubview(made, positioned: .below, relativeTo: nil)
        return made
    }

    private func settle(_ made: SidePageView, width: CGFloat) {
        let frame = NSRect(x: made.frame.minX, y: made.frame.minY, width: width, height: max(made.naturalHeight, 1))
        if made.frame.size != frame.size { made.frame = frame }
        made.layoutSubtreeIfNeeded()
        if abs(made.frame.height - max(made.naturalHeight, 1)) > 0.5 {
            made.frame.size.height = max(made.naturalHeight, 1)
            made.layoutSubtreeIfNeeded()
        }
    }

    private func setPage(_ wanted: Kind?) {
        if wanted == kind {
            switch kind {
            case .parked?: page?.preview = parkedPreview()
            case .front?: page?.preview = frontPreview()
            default: break
            }
            return
        }
        if wanted == .front, let traveler {
            page?.removeFromSuperview()
            page = traveler
            self.traveler = nil
            page?.frame.origin = .zero
            page?.heldShade = 1
            kind = .front
            return
        }
        page?.removeFromSuperview()
        page = wanted.map(make)
        kind = wanted
    }

    func refresh(width: CGFloat) {
        self.width = width
        let id = space.id
        let live = self.live
        let folded = self.folded
        let open = !folded || moving
        if live {
            if moving {
                if traveler == nil {
                    if kind == .front, let page {
                        traveler = page
                        self.page = nil
                        kind = nil
                    } else {
                        traveler = make(.front)
                    }
                }
                setPage(.live)
                if let traveler { body.addSubview(traveler, positioned: .above, relativeTo: page) }
                traveler?.preview = frontPreview()
            } else {
                setPage(folded ? .front : .live)
                traveler?.removeFromSuperview()
                traveler = nil
            }
        } else {
            traveler?.removeFromSuperview()
            traveler = nil
            setPage(open ? .parked : nil)
        }
        front = live ? (browser.activeSplit?.left ?? browser.activeID) : nil
        page?.veiled = traveler != nil ? front : nil
        if !moving { page?.alphaValue = 1 }
        let emptyParked = !live && open && (browser.parked[id]?.tabs.filter { $0.pin == nil }.isEmpty ?? true)
        quiet.isHidden = !emptyParked
        if let page { settle(page, width: width) }
        if let traveler { settle(traveler, width: width) }
        if !quiet.isHidden {
            quiet.height = browser.prefs.sideRow
            quiet.size = browser.prefs.sideTitle
            quiet.frame = NSRect(x: Metrics.sideInset, y: (page?.frame.minY ?? 0) + (page?.naturalHeight ?? 0),
                                 width: width - 2 * Metrics.sideInset, height: browser.prefs.sideRow)
        }
        placePicks(interactive: kind == .live || moving)
        if Store.testing {
            if folded && !live {
                StackedProbe.rows[id] = []
            } else if live && !folded {
                StackedProbe.rows[id] = browser.displayedTabs.map(\.id)
            } else if live {
                StackedProbe.rows[id] = (browser.activeSplit?.left ?? browser.activeID).map { [$0] } ?? []
            } else if let row = browser.parked[id] {
                StackedProbe.rows[id] = SideScene.parked(row, prefs: browser.prefs).items.compactMap { item in
                    if case .tab(let tab) = item { tab } else { nil }
                }
            }
        }
    }

    func place(open: CGFloat, inset: CGFloat) {
        body.clipsBottom = moving
        guard moving else {
            if let page, page.frame.minY != 0 { page.frame.origin.y = 0 }
            page?.alphaValue = 1
            quiet.alphaValue = 1
            return
        }
        let fade = StackedFold.fade(open)
        page?.frame.origin.y = -inset
        page?.alphaValue = fade
        quiet.alphaValue = fade
        quiet.frame.origin.y = -inset + (page?.naturalHeight ?? 0)
        guard let traveler else { return }
        traveler.heldShade = StackedFold.arrive(open)
        if let front, let page, let from = page.frame(of: front), let to = traveler.frame(of: front) {
            let dx = from.minX + page.frame.minX - to.minX
            let dy = from.minY + page.frame.minY - to.minY
            traveler.frame.origin = NSPoint(x: dx * open, y: dy * open)
            traveler.alphaValue = 1
        } else {
            traveler.frame.origin = .zero
            traveler.alphaValue = 1 - fade
        }
        if Store.testing, let front {
            StackedProbe.travel[space.id] = traveler.frame(of: front).map { traveler.convert($0, to: body) }
        }
    }

    private func placePicks(interactive: Bool) {
        guard !interactive, let page else {
            for pick in picks.values { pick.removeFromSuperview() }
            picks = [:]
            return
        }
        let id = space.id
        var kept = Set<Tab.ID>()
        for target in page.pickTargets() {
            let tab = target.tab
            let pick = picks[tab.id] ?? {
                let made = StackedPickView(label: tab.title, radius: target.radius) { [weak browser] in
                    browser?.stackedSelect(tab, in: id)
                }
                made.onFrame = onFrame
                made.ink = ground.ink
                picks[tab.id] = made
                body.addSubview(made)
                return made
            }()
            pick.radius = target.radius
            pick.frame = page.convert(target.frame, to: body)
            kept.insert(tab.id)
        }
        for (tabID, pick) in picks where !kept.contains(tabID) {
            pick.removeFromSuperview()
            picks[tabID] = nil
        }
    }
}

final class StackedBodyView: NSView {
    var cutTop: CGFloat = 0 { didSet { if cutTop != oldValue { recut() } } }
    var clipsBottom = false { didSet { if clipsBottom != oldValue { recut() } } }
    private let mask = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        mask.backgroundColor = NSColor.black.cgColor
        layer?.mask = mask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        recut()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recut()
    }

    private func recut() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let top = min(bounds.height, max(0, cutTop))
        let below: CGFloat = clipsBottom ? 0 : 4000
        mask.frame = CGRect(x: -4000, y: top, width: bounds.width + 8000, height: max(0, bounds.height - top) + below)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.y >= cutTop, !clipsBottom || local.y <= bounds.height else { return nil }
        return super.hitTest(point)
    }
}

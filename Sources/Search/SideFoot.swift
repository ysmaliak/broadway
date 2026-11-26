import AppKit
import Combine

final class SpaceFootView: NSView, SpaceFollowing {
    let browser: Browser
    var fetch: FetchDoorView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let fetch else { return }
            fetch.side = Self.side
            fetch.glyph = Self.glyph
            addSubview(fetch)
        }
    }
    var ground = RowGround() { didSet { if ground != oldValue { needsLayout = true } } }
    private let plus: DoorView
    private let strip = FootStripView()
    private var spots: [FootSpot.Kind: SpaceSpotView] = [:]
    private var laid: [FootSpot.Kind] = []
    private(set) var row = FootRow.none
    private var focus: CGFloat?
    private var focusGoal: CGFloat = 0
    private var pan: CGFloat = 0
    private var panGoal: CGFloat = 0
    private var link: CADisplayLink?
    private var timer: Timer?
    private var ticked: CFTimeInterval = 0
    private var area: NSTrackingArea?
    private var back: DispatchWorkItem?
    private var named: Set<String> = []

    static let side: CGFloat = 28
    static let below: CGFloat = 8
    static let height: CGFloat = side + below
    static let iconMiddle: CGFloat = Metrics.sideInset + TabRowView.iconLead + SideLook.rowMark / 2
    static let lead: CGFloat = iconMiddle - side / 2
    static let glyph: CGFloat = 16
    static let gap: CGFloat = 2
    static let patience: TimeInterval = 0.7
    @MainActor static var trace: [[String: Double]]?
    @MainActor static var fades = 0

    init(browser: Browser) {
        self.browser = browser
        plus = DoorView(icon: "plus", help: "New…", act: {})
        super.init(frame: .zero)
        plus.act = { [weak browser] in browser?.showPlusMenu() }
        plus.box = Self.side
        plus.size = Self.glyph
        plus.weight = IconLook.weight
        addSubview(strip)
        addSubview(plus)
        browser.spaceMotion.followers.add(self)
        browser.spaceFeet.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            browser.plusDoor = .zero
            rest()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        area = made
    }

    override func mouseEntered(with event: NSEvent) {
        back?.cancel()
        back = nil
    }

    override func mouseExited(with event: NSEvent) {
        comeBack(after: Self.patience)
    }

    override func scrollWheel(with event: NSEvent) {
        guard wheel(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas) else {
            return super.scrollWheel(with: event)
        }
    }

    override func layout() {
        super.layout()
        let side = Self.side
        let lead = Self.lead
        let y = bounds.height - Self.below - side
        fetch?.frame = NSRect(x: lead, y: y, width: side, height: side)
        plus.greys = ground.greys
        plus.ink = ground.ink
        plus.on = browser.plusOpen
        plus.frame = NSRect(x: bounds.width - lead - side, y: y, width: side, height: side)
        notePlus()

        let edge = lead + side + Self.gap
        let room = NSRect(x: edge - Self.gap / 2, y: 0, width: max(0, bounds.width - 2 * edge + Self.gap), height: bounds.height)
        strip.frame = room
        strip.bounds = room

        browser.spaceNeighbour.watch()
        let shown = shownSpots
        let going = browser.spaceNext != nil
        var kept = Set<FootSpot.Kind>()
        for spot in shown {
            let view = spots[spot.kind] ?? {
                let made = SpaceSpotView(browser: browser, kind: spot.kind, icon: spot.icon, here: spot.here, next: spot.next)
                made.foot = self
                spots[spot.kind] = made
                strip.addSubview(made)
                return made
            }()
            view.update(spot, going: going, ink: ground.ink)
            kept.insert(spot.kind)
        }
        for (kind, view) in spots where !kept.contains(kind) {
            view.removeFromSuperview()
            spots[kind] = nil
        }
        laid = shown.map(\.kind)
        place()
    }

    private var shownSpots: [FootSpot] {
        browser.prefs.usesSpaces && !browser.isPrivate ? browser.footSpots : []
    }

    var pans: Bool { row.many && !isHiddenOrHasHiddenAncestor }

    func follow(_ motion: SpaceMotion) {
        guard window != nil else { return }
        place()
    }

    private func place() {
        let fresh = shownSpots
        guard fresh.map(\.kind) == laid else {
            needsLayout = true
            return
        }
        let going = browser.spaceNext != nil
        let progress = browser.spaceMotion.progress
        let lights = fresh.map { FootLight(here: $0.here, next: $0.next, going: going, progress: progress).lit }
        let wanted = FootRow.focus(lights) ?? focus ?? 0
        let driven = going || browser.spaceMotion.moving || SpaceSwipe.shared.touching
        if abs(wanted - focusGoal) > 0.01 { panGoal = 0 }
        focusGoal = wanted
        let still = Motion.reduced || window == nil
        var jumped = false
        if focus == nil || driven || still {
            jumped = still && abs(wanted - (focus ?? wanted)) > 0.01
            focus = wanted
        }
        if still, pan != panGoal {
            pan = panGoal
            jumped = true
        }
        apply(lights: lights, fresh: fresh, fading: jumped && Motion.reduced && window != nil)
        chase()
    }

    private var arrived: Bool {
        abs((focus ?? focusGoal) - focusGoal) <= 0.001 && abs(pan - panGoal) <= 0.1
    }

    private func chase() {
        if arrived { settle() } else { run() }
    }

    private func apply(lights: [CGFloat], fresh: [FootSpot], fading: Bool) {
        let drafted = fresh.last?.kind == .draft
        let count = fresh.count - (drafted ? 1 : 0)
        let before = row
        let made = FootRow.lay(count: count, draft: drafted ? lights.last : nil, room: strip.bounds.width, focus: focus ?? 0, pan: pan)
        row = made
        pan = made.pan
        panGoal = min(made.range - made.rest, max(-made.rest, panGoal))
        if fading, abs(made.scroll - before.scroll) > 0.5, let layer = strip.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = SpaceLitView.crossfade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(fade, forKey: "row")
            Self.fades += 1
        }
        let y = bounds.height - Self.below - Self.side
        let origin = strip.bounds.minX
        var seen = Set<String>()
        for (index, spot) in fresh.enumerated() where made.marks.indices.contains(index) {
            guard let view = spots[spot.kind] else { continue }
            let mark = made.marks[index]
            let share = spot.kind == .draft ? lights[index] : 1
            view.place(mark, at: origin, y: y, share: share)
            guard Store.testing, case .space = spot.kind, let window, let content = window.contentView else { continue }
            let side = Self.side * mark.size
            let box = NSRect(x: origin + mark.middle - side / 2, y: y + (Self.side - side) / 2, width: side, height: side)
            let drawn = mark.alpha > 0.01 ? strip.convert(box.intersection(strip.bounds), to: content) : .null
            guard !drawn.isNull, drawn.width > 0.5 else { continue }
            let top = content.isFlipped ? drawn.minY : content.bounds.height - drawn.maxY
            ColumnEdges.marks[view.name] = [drawn.minX, top, drawn.width, drawn.height]
            seen.insert(view.name)
        }
        if Store.testing, window != nil {
            for name in named.subtracting(seen) { ColumnEdges.marks[name] = nil }
            named = seen
            if Self.trace != nil {
                let wanted = FootRow.lay(count: count, draft: drafted ? lights.last : nil, room: strip.bounds.width, focus: focusGoal).scroll
                Self.trace?.append(["t": CACurrentMediaTime(), "focus": Double(focus ?? 0), "goal": Double(focusGoal),
                                    "scroll": Double(made.scroll), "wanted": Double(wanted),
                                    "progress": Double(browser.spaceMotion.progress)])
            }
        }
    }

    @discardableResult
    func wheel(dx: CGFloat, dy: CGFloat, precise: Bool) -> Bool {
        guard pans else { return false }
        let delta = abs(dx) >= abs(dy) ? dx : dy
        pan -= precise ? delta : delta * row.pitch
        panGoal = pan
        replace(fading: false)
        return true
    }

    func page(_ direction: CGFloat) {
        guard pans else { return }
        panGoal = min(row.range - row.rest, max(-row.rest, pan + direction * row.page))
        replace(fading: true)
    }

    func comeBack(after delay: TimeInterval) {
        back?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.panGoal != 0 else { return }
            self.panGoal = 0
            self.replace(fading: true)
        }
        back = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func replace(fading: Bool) {
        let fresh = shownSpots
        guard fresh.map(\.kind) == laid else {
            needsLayout = true
            return
        }
        let going = browser.spaceNext != nil
        let lights = fresh.map { FootLight(here: $0.here, next: $0.next, going: going, progress: browser.spaceMotion.progress).lit }
        let still = Motion.reduced || window == nil
        if still { pan = panGoal }
        apply(lights: lights, fresh: fresh, fading: fading && still && window != nil)
        chase()
        spots.values.forEach { $0.settleHover() }
    }

    private func run() {
        guard link == nil, timer == nil, window != nil else { return }
        ticked = CACurrentMediaTime()
        if window?.isVisible == true, !Store.testing || Store.shownOnScreen {
            let made = displayLink(target: self, selector: #selector(tick))
            made.add(to: .main, forMode: .common)
            link = made
        } else {
            let made = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(made, forMode: .common)
            timer = made
        }
    }

    private func settle() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    private func rest() {
        settle()
        back?.cancel()
        back = nil
        focus = nil
        pan = 0
        panGoal = 0
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        let near = 1 - exp(-CGFloat(min(0.1, max(0, now - ticked))) * Self.pull)
        ticked = now
        let fresh = shownSpots
        guard window != nil, fresh.map(\.kind) == laid else {
            settle()
            needsLayout = true
            return
        }
        let going = browser.spaceNext != nil
        let driven = going || browser.spaceMotion.moving || SpaceSwipe.shared.touching
        let lights = fresh.map { FootLight(here: $0.here, next: $0.next, going: going, progress: browser.spaceMotion.progress).lit }
        if !driven, let at = focus {
            focus = abs(focusGoal - at) < 0.002 ? focusGoal : at + (focusGoal - at) * near
        }
        pan = abs(panGoal - pan) < 0.2 ? panGoal : pan + (panGoal - pan) * near
        apply(lights: lights, fresh: fresh, fading: false)
        if driven ? abs(pan - panGoal) <= 0.1 : arrived {
            settle()
            spots.values.forEach { $0.settleHover() }
        }
    }

    static let pull: CGFloat = 16

    var benchState: [String: Any] {
        let fresh = shownSpots
        return ["room": Double(row.room), "pitch": Double(row.pitch), "scroll": Double(row.scroll), "rest": Double(row.rest),
                "range": Double(row.range), "before": Double(row.before), "after": Double(row.after), "many": row.many,
                "focus": Double(focus ?? 0), "pan": Double(pan),
                "marks": zip(fresh, row.marks).map { spot, mark -> [String: Any] in
                    ["name": spots[spot.kind]?.name ?? "", "from": Double(mark.from), "to": Double(mark.to), "share": Double(mark.share),
                     "size": Double(mark.size), "dot": Double(mark.dot), "alpha": Double(mark.alpha), "here": spot.here, "small": mark.small,
                     "asking": spots[spot.kind]?.asking ?? false]
                }]
    }

    private func notePlus() {
        guard let window, let content = window.contentView, window.contentView != nil else { return }
        let rect = plus.convert(plus.bounds, to: content)
        let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        browser.plusDoor = CGRect(x: rect.minX, y: top, width: rect.width, height: rect.height)
        browser.plusAnchor = plus
    }
}

final class SpaceSpotView: KitHoverView {
    let browser: Browser
    let kind: FootSpot.Kind
    private let mark: SpaceMarkView
    private let lit: SpaceLitView
    private let wash = KitPlate(radius: 7)
    private var light: CGFloat = 0
    private var ink: KitInk = .flat
    private let bead = KitPlate(fill: .ink, radius: 7)
    private let ask = UnseenDotView()
    private var askWatch: AnyCancellable?
    private(set) var asking = false
    private(set) var name = ""
    private(set) var small = false
    private var share: CGFloat = 1
    private var beaded: CGFloat = 0
    weak var foot: SpaceFootView?

    init(browser: Browser, kind: FootSpot.Kind, icon: TabIcon, here: Bool, next: Bool) {
        self.browser = browser
        self.kind = kind
        mark = SpaceMarkView(icon: icon, size: 15)
        mark.byInk = true
        lit = SpaceLitView(motion: browser.spaceMotion, content: mark, here: here, next: next)
        super.init(frame: .zero)
        wash.fill = .ink
        wash.alphaValue = 0
        addSubview(wash)
        addSubview(lit)
        ask.tone = .unsafe
        ask.toolTip = nil
        ask.setAccessibilityElement(false)
        ask.isHidden = true
        addSubview(ask)
        lit.bead = bead
        lit.tint = { [weak self] amount in self?.tinted(amount) }
        setAccessibilityElement(true)
        if case .space(let id) = kind {
            setAccessibilityRole(.button)
            setAccessibilityIdentifier("space-" + id.uuidString)
            askWatch = kitTrack { [weak self] in self?.reask(id) }
        } else {
            setAccessibilityRole(.image)
            setAccessibilityLabel("New Space")
            toolTip = "New Space"
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func reask(_ id: UUID) {
        let now = browser.agentAsks(in: id)
        guard now != asking else { return }
        asking = now
        ask.isHidden = !now
        setAccessibilityValue(now ? "An agent needs you" : nil)
        needsLayout = true
    }

    private func tinted(_ amount: CGFloat) {
        light = amount
        paint()
    }

    private func paint() {
        mark.tint = Self.tint(lit: light, ink: ink, dark: kitDark)
    }

    static func tint(lit: CGFloat, ink: KitInk, dark: Bool) -> NSColor {
        if lit >= 1 { return KitColor.ink }
        if lit <= 0 { return KitColor.muted }
        let quiet = ink.color(KitColor.muted, .quiet, dark: dark)
        let full = ink.color(KitColor.ink, .ink, dark: dark)
        return quiet.blended(withFraction: lit, of: full) ?? full
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    func update(_ spot: FootSpot, going: Bool, ink: KitInk) {
        if mark.icon != spot.icon { mark.icon = spot.icon }
        mark.ink = ink
        wash.ink = ink
        bead.ink = ink
        if ink != self.ink {
            self.ink = ink
            paint()
        }
        lit.here = spot.here
        lit.next = spot.next
        lit.going = going
        if case .space(let id) = kind, let space = browser.spaces.first(where: { $0.id == id }) {
            name = space.name
            toolTip = space.name
            setAccessibilityLabel(space.name)
        }
        needsLayout = true
    }

    func place(_ mark: FootRow.Mark, at origin: CGFloat, y: CGFloat, share: CGFloat) {
        let side = SpaceFootView.side
        let width = side * mark.size * share
        lit.size = mark.size
        lit.dot = mark.dot
        small = mark.small
        beaded = mark.dot
        self.share = mark.size
        let alpha = mark.alpha * share
        if alphaValue != alpha { alphaValue = alpha }
        let wanted = NSRect(x: origin + mark.middle - width / 2, y: y, width: width, height: side)
        if frame != wanted {
            frame = wanted
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let side = SpaceFootView.side
        let box = side * share
        wash.radius = 7 * share
        wash.frame = NSRect(x: (bounds.width - box) / 2, y: (bounds.height - box) / 2, width: box, height: box)
        lit.frame = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        let dot = Self.askSide * share
        let reach = Self.askReach * share * (1 - beaded)
        ask.kitSetFrame(NSRect(x: bounds.midX + reach - dot / 2, y: bounds.midY - reach - dot / 2, width: dot, height: dot))
    }

    static let askSide: CGFloat = 7
    static let askReach: CGFloat = 6.5

    override func hoverChanged() {
        let over = hovering
        guard case .space = kind else { return }
        lit.hovering = over
        NSAnimationContext.kit(Motion.kitSlide, implicit: true) {
            wash.animator().alphaValue = over ? 0.08 : 0
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard case .space = kind, !isHidden, alphaValue > 0.05, frame.contains(point) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard case .space = kind else { return }
        press(true)
    }

    override func mouseUp(with event: NSEvent) {
        press(false)
        guard case .space(let id) = kind, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if small, let foot, foot.pans {
            foot.page(frame.midX < foot.bounds.midX ? -1 : 1)
            return
        }
        browser.goToSpace(id)
    }

    private func press(_ down: Bool) {
        lit.kitScale(down && !Motion.reduced ? 0.86 : 1, curve: down ? Motion.kitQuick : Motion.kitSettle)
    }

    override func accessibilityPerformPress() -> Bool {
        guard case .space(let id) = kind else { return false }
        browser.goToSpace(id)
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard case .space(let id) = kind else { return nil }
        return SpaceMenu.menu(for: browser, space: id, icon: true)
    }
}

final class FootStripView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

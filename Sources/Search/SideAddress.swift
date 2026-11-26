import AppKit
import Combine

enum PillLook {
    static let edgeWidth: CGFloat = 1.5
    static let edgeTone = 0.6
    static let lightHover = 0.44
    static let lightPress = 0.6

    static func fill(_ greys: KitGreys, state: PinLook.State, dark: Bool) -> KitTone {
        guard !dark else { return greys.card.opacity(PinLook.gain(dark: dark, part: .fill, state: state)) }
        return switch state {
        case .hovered: greys.card.opacity(lightHover)
        case .picked, .live: greys.hover.opacity(lightPress)
        case .resting: greys.card
        }
    }

    static func edge(_ greys: KitGreys, state: PinLook.State, dark: Bool) -> KitTone? {
        greys.onFrame ? nil : greys.cardEdge.opacity(PinLook.gain(dark: dark, part: .edge, state: state) * PillLook.edgeTone)
    }

    static func rim(_ greys: KitGreys, state: PinLook.State, dark: Bool) -> KitTone? { nil }

    static var textX: CGFloat { SideLook.pillLead }
}

final class SideAddressView: KitHoverView {
    let browser: Browser
    var ground: (Int) -> RowGround = { _ in RowGround() } { didSet { needsLayout = true } }

    let lane: AddressLaneView
    private let ride: RideView
    private var doors: AddressDoorsView { lane.here.doors }
    private let anchors = NSView()
    private var watch: AnyCancellable?
    private var copyWatch: AnyCancellable?
    private weak var watchedTab: Tab?
    private var copies = 0
    private var copiedAt = 0
    private var pressed = false
    private var doorsSpace: UUID?

    init(browser: Browser) {
        self.browser = browser
        lane = AddressLaneView(browser: browser)
        ride = RideView(content: lane, motion: browser.spaceMotion)
        super.init(frame: .zero)
        wantsLayer = true
        anchors.addSubview(SiteControlsAnchorView(browser: browser))
        anchors.addSubview(BookmarksAnchorView(browser: browser))
        addSubview(anchors)
        addSubview(ride)
        lane.ground = { [weak self] index in self?.ground(index) ?? RowGround() }
        doors.copy.act = { [weak browser] in
            browser?.hints.copied(browser?.active?.address)
            browser?.copyAddress()
        }
        doors.site.act = { [weak browser] in if let browser { SiteCardPanel.toggle(browser) } }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        toolTip = "Edit Address   ⌘L"
        watch = kitTrack { [weak self] in self?.changed() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var sliding: Bool { browser.spaceNext != nil && !browser.stacked }
    private var addressed: Bool { browser.shownTab.flatMap { AddressLaneView.line($0, prefs: browser.prefs) } != nil }

    private func changed() {
        let tab = browser.shownTab
        if tab !== watchedTab {
            watchedTab = tab
            copies = tab?.kicks.copy ?? 0
            copiedAt += 1
            doors.copy.icon = "link"
            doors.copy.confirmed = false
            copyWatch = tab.map { tab in
                kitObserve(initial: false, { [weak tab] in tab?.kicks.copy ?? 0 }) { [weak self] _ in self?.tabChanged() }
            }
        }
        browser.spaceNeighbour.watch()
        _ = browser.spaceNext
        _ = AddressLaneView.signed(tab, browser: browser)?.blockedPopups.last?.id
        setAccessibilityLabel(tab.flatMap { AddressLaneView.line($0, prefs: browser.prefs) } ?? NewTabPageView.prompt)
        needsLayout = true
        lane.needsLayout = true
    }

    private func tabChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let tab = watchedTab else { return }
            if tab.kicks.copy != copies {
                copies = tab.kicks.copy
                copiedAt += 1
                let mark = copiedAt
                doors.copy.icon = "checkmark"
                doors.copy.confirmed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    guard let self, copiedAt == mark else { return }
                    doors.copy.icon = "link"
                    doors.copy.confirmed = false
                }
            }
            changed()
        }
    }

    private func paint() {
        let here = lane.here
        here.state = sliding ? .resting : pressed ? .picked : hovering ? .hovered : .resting
        let doorViews: [KitHoverView] = [doors.copy, doors.site] + (doors.sign.map { [$0] } ?? [])
        for door in doorViews where door.inert != sliding { door.inert = sliding }
        let space = browser.spaceID
        here.show(addressed, animated: !sliding && doorsSpace == space && window != nil)
        doorsSpace = space
    }

    override func layout() {
        let clock = CACurrentMediaTime()
        defer { FrameGaps.shared.note("address", from: clock) }
        super.layout()
        let inset = Metrics.sideInset
        anchors.frame = bounds
        for anchor in anchors.subviews { anchor.frame = anchors.bounds }
        let frame = NSRect(x: -inset, y: 0, width: bounds.width + 2 * inset, height: bounds.height)
        if ride.frame != frame { ride.frame = frame }
        lane.frame = ride.bounds
        lane.lay(width: frame.width)
        ride.set(RideLook(here: browser.spaceAt, span: browser.stacked ? 0 : nil, hits: false))
        paint()
    }

    override func hoverChanged() {
        if !hovering, pressed { give(false) }
        paint()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !sliding, frame.contains(point) else { return nil }
        let here = lane.here
        if here.lit, let hit = doors.hitTest(here.face.convert(point, from: superview)), hit !== doors { return hit }
        return self
    }

    private func give(_ down: Bool) {
        pressed = down
        paint()
        lane.here.face.kitScale(down && !Motion.reduced ? SideLook.pillPress : 1, curve: down ? Motion.kitQuick : Motion.kitSettle)
    }

    override func mouseDown(with event: NSEvent) { give(true) }

    func benchPress(_ down: Bool) {
        guard Store.testing else { return }
        give(down)
    }

    override func mouseUp(with event: NSEvent) {
        let was = pressed
        give(false)
        if was, bounds.contains(convert(event.locationInWindow, from: nil)) { browser.edit() }
    }

    override func accessibilityPerformPress() -> Bool {
        browser.edit()
        return true
    }
}

final class PopupDoorView: PopupSignView {
    let live: Bool
    var greys = KitGreys.white { didSet { if greys != oldValue { paint(animated: false) } } }
    private let plate = KitPlate(radius: 8)

    init(browser: Browser, tab: Tab, live: Bool) {
        self.live = live
        super.init(browser: browser, tab: tab)
        ground.isHidden = true
        addSubview(plate, positioned: .below, relativeTo: symbol)
        symbol.style = KitSymbol.Style(size: SideLook.doorSize, weight: SideLook.doorWeight)
        frame.size = intrinsicContentSize
        if !live {
            inert = true
            setAccessibilityElement(false)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: AddressDoorsView.side, height: AddressDoorsView.side) }
    override var mouseDownCanMoveWindow: Bool { false }

    override func refresh() {
        super.refresh()
        if !live { toolTip = nil }
    }

    override func layout() {
        super.layout()
        plate.kitSetFrame(bounds)
    }

    override func paint(animated: Bool) {
        if animated {
            plate.layer?.kitTransition(Motion.kitQuick)
            symbol.layer?.kitTransition(Motion.kitQuick)
        }
        let open = popup != nil || shown
        symbol.ink = ink
        symbol.tint = open || hovering ? Palette.NS.ink : Palette.NS.muted
        symbol.opacity = 1
        plate.ink = ink
        plate.fill = open ? greys.wash : hovering ? greys.hover : nil
    }

    override func mouseDown(with event: NSEvent) {
        kitScale(Motion.reduced ? 1 : 0.9, curve: Motion.kitQuick)
    }

    override func mouseUp(with event: NSEvent) {
        kitScale(1, curve: Motion.kitSettle)
        super.mouseUp(with: event)
    }
}

final class AddressDoorsView: NSView {
    let live: Bool
    let slot: ExtensionSlotView
    let copy = DoorView(icon: "link", help: "Copy Address   ⇧⌘C", act: {})
    let site = DoorView(icon: SideLook.siteIcon, help: "Site Controls   ⌘E", act: {})
    private(set) var sign: PopupDoorView?
    private var ground = RowGround()
    static let side: CGFloat = 26

    init(live: Bool) {
        self.live = live
        slot = ExtensionSlotView(extensions: .shared, edge: .maxX, room: 2, still: !live)
        super.init(frame: .zero)
        wantsLayer = true
        for view in [slot, copy, site] { addSubview(view) }
        for door in [copy, site] {
            door.size = SideLook.doorSize
            door.weight = SideLook.doorWeight
            guard !live else { continue }
            door.inert = true
            door.toolTip = nil
            door.setAccessibilityElement(false)
        }
        if !live { setAccessibilityElement(false) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { live ? super.hitTest(point) : nil }

    private var slotWidth: CGFloat { Extensions.shared.installed.isEmpty ? 0 : max(0, slot.intrinsicContentSize.width) }
    var width: CGFloat { slotWidth + 2 + (sign == nil ? 0 : Self.side + 2) + Self.side + 2 + Self.side }

    func follow(_ tab: Tab?, browser: Browser) {
        guard let tab else {
            guard let sign else { return }
            sign.removeFromSuperview()
            self.sign = nil
            needsLayout = true
            return
        }
        if let sign, sign.tab === tab {
            sign.refresh()
            return
        }
        sign?.removeFromSuperview()
        let made = PopupDoorView(browser: browser, tab: tab, live: live)
        addSubview(made, positioned: .below, relativeTo: copy)
        sign = made
        paint(ground)
        needsLayout = true
    }

    func paint(_ ground: RowGround) {
        self.ground = ground
        for door in [copy, site] {
            door.greys = ground.greys
            door.ink = ground.ink
        }
        sign?.greys = ground.greys
        sign?.ink = ground.ink
        slot.ink = ground.ink
        slot.onFrame = ground.greys.onFrame
    }

    override func layout() {
        super.layout()
        let side = Self.side
        let slotWidth = slotWidth
        let y = (bounds.height - side) / 2
        slot.frame = NSRect(x: 0, y: 0, width: slotWidth, height: bounds.height)
        var x = slotWidth + 2
        if let sign {
            sign.frame = NSRect(x: x, y: y, width: side, height: side)
            x += side + 2
        }
        copy.frame = NSRect(x: x, y: y, width: side, height: side)
        site.frame = NSRect(x: copy.frame.maxX + 2, y: y, width: side, height: side)
    }
}

final class AddressPillView: NSView {
    let face = NSView()
    let plate = KitPlate(radius: SideLook.pillRadius)
    let words = AddressWordsView()
    let doors: AddressDoorsView
    private(set) var lit = false
    var ground = RowGround() { didSet { if ground != oldValue { paint(animated: fades && window != nil) } } }
    var fades = false
    var state: PinLook.State = .resting { didSet { if state != oldValue { paint(animated: true) } } }

    init(live: Bool = false) {
        doors = AddressDoorsView(live: live)
        super.init(frame: .zero)
        wantsLayer = true
        face.wantsLayer = true
        face.layer?.cornerRadius = SideLook.pillRadius
        face.layer?.cornerCurve = .continuous
        face.layer?.masksToBounds = true
        face.addSubview(plate)
        face.addSubview(words)
        doors.alphaValue = 0
        face.addSubview(doors)
        addSubview(face)
        setAccessibilityElement(false)
        paint(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var host: String?? {
        get { words.host }
        set { words.host = newValue }
    }

    var doorsLead: CGFloat { bounds.width - 4 - doors.width }

    func layDoors() {
        let frame = NSRect(x: doorsLead, y: 0, width: doors.width, height: bounds.height)
        if doors.frame != frame { doors.frame = frame }
        let fade = lit ? frame.minX : nil
        for case let view as AddressWordsView in face.subviews { view.fadeAt = fade }
    }

    func show(_ shown: Bool, animated: Bool) {
        let changed = shown != lit
        lit = shown
        layDoors()
        guard changed else { return }
        let opacity = Swift.Float(shown ? 1 : 0)
        if animated {
            doors.layer?.kitAnimate("opacity", to: opacity, curve: Motion.kitQuick)
        } else {
            doors.layer?.removeAnimation(forKey: "opacity")
        }
        doors.alphaValue = shown ? 1 : 0
    }

    override func layout() {
        super.layout()
        if face.frame != bounds { face.frame = bounds }
        plate.frame = face.bounds
        for view in face.subviews where view is AddressWordsView && view.frame.size != bounds.size {
            view.frame = face.bounds
        }
        layDoors()
    }

    private func paint(animated: Bool) {
        let named: NSAppearance.Name = ground.dark ? .darkAqua : .aqua
        if appearance?.name != named { appearance = NSAppearance(named: named) }
        if animated { plate.layer?.kitTransition(Motion.kitQuick) }
        let greys = ground.greys
        let dark = ground.dark
        plate.ink = ground.ink
        plate.fill = PillLook.fill(greys, state: state, dark: dark)
        plate.foot = nil
        plate.stroke = PillLook.edge(greys, state: state, dark: dark)
        plate.strokeWidth = PillLook.edgeWidth
        plate.rim = PillLook.rim(greys, state: state, dark: dark)
        plate.ramp = nil
        for case let view as AddressWordsView in face.subviews { view.ink = ground.ink }
        doors.paint(ground)
    }
}

final class AddressWordsView: NSView {
    let label = KitLabel("", font: SideLook.pillFont)
    private let fade = CAGradientLayer()
    var ink: KitInk = .flat { didSet { if ink != oldValue { label.ink = ink } } }
    var fadeAt: CGFloat? { didSet { if fadeAt != oldValue { needsLayout = true; shade() } } }
    var whole = false { didSet { if whole != oldValue { refill() } } }
    var host: String?? = nil { didSet { if host != oldValue { refill() } } }
    private(set) var split: (lead: String, name: String)?

    static func lead(_ split: (lead: String, name: String), room: CGFloat) -> String {
        func width(_ text: String) -> CGFloat {
            ceil(NSAttributedString(string: text, attributes: [.font: SideLook.pillFont]).size().width)
        }
        let name = width(split.name)
        guard width(split.lead) + name > room else { return split.lead }
        let labels = split.lead.split(separator: ".").map(String.init)
        for kept in stride(from: labels.count - 1, through: 1, by: -1) {
            let shorter = "…" + labels.suffix(kept).joined(separator: ".") + "."
            if width(shorter) + name <= room { return shorter }
        }
        return "…"
    }

    private func refill() {
        let words = host ?? nil
        split = words.map { whole ? ("", $0) : Hosts.split($0) }.flatMap { $0.lead.isEmpty ? nil : $0 }
        if let split {
            label.runs = [KitLabel.Run(text: split.lead, font: SideLook.pillFont, color: KitColor.muted),
                          KitLabel.Run(text: split.name, font: SideLook.pillFont)]
        } else {
            label.text = words ?? NewTabPageView.prompt
        }
        label.color = words == nil ? KitColor.muted : KitColor.title
        needsLayout = true
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.overflow = .middle
        label.color = KitColor.muted
        addSubview(label)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
        fade.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull(), "frame": NSNull()]
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func shade() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let fadeAt, bounds.width > 0, label.frame.maxX > fadeAt - SideLook.pillFade else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let end = min(1, max(0, fadeAt / bounds.width))
        let start = min(end, max(0, (fadeAt - SideLook.pillFade) / bounds.width))
        fade.frame = bounds
        fade.locations = [0, NSNumber(value: Double(start)), NSNumber(value: Double(end)), 1]
        if layer.mask !== fade { layer.mask = fade }
    }

    override func layout() {
        super.layout()
        let x = PillLook.textX
        var room = max(0, bounds.width - 10 - x)
        if let split, let words = host ?? nil {
            if let fadeAt { room = min(room, max(0, fadeAt - SideLook.pillFade - x)) }
            label.runs = [KitLabel.Run(text: Self.lead(split, room: room), font: SideLook.pillFont, color: KitColor.muted),
                          KitLabel.Run(text: split.name, font: SideLook.pillFont)]
            label.setAccessibilityValue(words)
        }
        let size = label.measure(width: room)
        label.frame = kitSnap(NSRect(x: x, y: (bounds.height - size.height) / 2, width: min(room, size.width), height: size.height))
        shade()
    }
}

final class AddressLaneView: NSView {
    let browser: Browser
    let here = AddressPillView(live: true)
    var ground: (Int) -> RowGround = { _ in RowGround() }
    private var leaving: AddressWordsView?
    private(set) var others: [Int: AddressPillView] = [:]
    private var mark: AddressMove.Mark?
    private var shown: String??

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(here)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func signed(_ tab: Tab?, browser: Browser) -> Tab? {
        guard let tab, !tab.blockedPopups.isEmpty, !browser.editing, browser.editingTab != tab.id else { return nil }
        return tab
    }

    static func line(_ tab: Tab, prefs: Preferences) -> String? {
        guard !tab.isBlank, let url = tab.page?.url ?? tab.saidAddress else { return nil }
        return text(url, full: prefs.fullAddress)
    }

    static func text(_ url: URL, full: Bool) -> String {
        if full { return Address.editable(url) }
        return url.host().map(Address.withoutWWW) ?? Address.editable(url)
    }

    func lay(width: CGFloat) {
        let prefs = browser.prefs
        let tab = browser.shownTab
        let host = tab.flatMap { Self.line($0, prefs: prefs) }
        let next = AddressMove.Mark(tab: tab?.id, space: browser.spaceID, text: host, full: prefs.fullAddress)
        let inset = Metrics.sideInset
        let frame = NSRect(x: inset, y: 0, width: max(0, width - 2 * inset), height: Metrics.sidePill)
        if here.frame != frame {
            here.frame = frame
            here.layoutSubtreeIfNeeded()
        }
        here.fades = browser.stacked
        here.ground = ground(browser.spaceAt)
        here.doors.follow(Self.signed(tab, browser: browser), browser: browser)
        here.layDoors()
        let words = NSRect(origin: .zero, size: frame.size)
        if let old = mark, old != next {
            turn(from: old, to: next, frame: words)
        } else if mark == nil {
            here.words.whole = prefs.fullAddress
            here.host = .some(host)
            shown = .some(host)
        }
        mark = next
        layOthers(frame: frame)
    }

    private func turn(from old: AddressMove.Mark, to new: AddressMove.Mark, frame: NSRect) {
        var cause = AddressMove.cause(from: old, to: new, step: browser.tabStep, back: browser.shownTab?.goingBack ?? false)
        if cause == .space, browser.stacked {
            let order = browser.spaces.map(\.id)
            cause = .tab(from: order.firstIndex(of: old.space), to: order.firstIndex(of: new.space))
        }
        let before = shown ?? old.text
        let move = AddressMove.between(before, new.text, cause: cause, reduced: Motion.reduced, light: Motion.light)
        shown = .some(new.text)
        let shift: CGSize
        let curve: KitCurve
        switch move {
        case .still:
            leaving?.removeFromSuperview()
            leaving = nil
            here.words.layer?.removeAllAnimations()
            here.words.whole = new.full
            here.host = .some(new.text)
            return
        case let .roll(down):
            shift = CGSize(width: 0, height: down ? 14 : -14)
            curve = Motion.kitRoll
        case let .slide(back):
            shift = CGSize(width: back ? -28 : 28, height: 0)
            curve = Motion.kitRoll
        case .fade:
            shift = .zero
            curve = .easeOut(0.16)
        }
        leaving?.removeFromSuperview()
        let out = AddressWordsView(frame: frame)
        out.ink = here.ground.ink
        out.whole = old.full
        out.host = .some(before)
        out.fadeAt = here.words.fadeAt
        here.face.addSubview(out, positioned: .below, relativeTo: here.words)
        leaving = out
        here.words.whole = new.full
        here.host = .some(new.text)
        glide(out, shift: CGSize(width: -shift.width, height: -shift.height), leaving: true, curve: curve)
        glide(here.words, shift: shift, leaving: false, curve: curve)
    }

    private func glide(_ view: AddressWordsView, shift: CGSize, leaving: Bool, curve: KitCurve) {
        guard let layer = view.layer else { return }
        let duration: CFTimeInterval = if case .easeOut(let seconds) = curve { seconds } else { 0.34 }
        let base = layer.position
        let away = CGPoint(x: base.x + shift.width, y: base.y + shift.height)
        if shift != .zero, let move = curve.animation("position", from: NSValue(point: leaving ? base : away), to: NSValue(point: leaving ? away : base)) {
            move.fillMode = .both
            move.isRemovedOnCompletion = !leaving
            layer.add(move, forKey: "glide.position")
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = leaving ? [1, 0, 0] : [0, 0, 1, 1]
        fade.keyTimes = leaving ? [0, 0.45, 1] : [0, 0.2, 0.75, 1]
        fade.duration = duration
        fade.fillMode = .both
        fade.isRemovedOnCompletion = !leaving
        layer.add(fade, forKey: "glide.opacity")
        if leaving {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(duration, 0.4)) { [weak self, weak view] in
                guard let view, self?.leaving === view else { return }
                view.removeFromSuperview()
                self?.leaving = nil
            }
        }
    }

    private func layOthers(frame: NSRect) {
        if browser.stacked {
            for view in others.values { view.removeFromSuperview() }
            others = [:]
            return
        }
        let at = browser.spaceAt
        let seen = browser.spaceSeen
        let next = browser.spaceNext
        let prefs = browser.prefs
        var kept = Set<Int>()
        for index in [seen, next, at - 1, at + 1, seen - 1, seen + 1].compactMap({ $0 })
        where index != at && index >= 0 && (index < browser.spaces.count || index == next) && !kept.contains(index) {
            if SpaceLane.covered(index, real: at, seen: seen, next: next) { continue }
            let side = SpaceLane.place(index, real: at, seen: seen, next: next)
            let active = browser.row(at: index)?.active
            let words: String? = active.flatMap { Self.line($0, prefs: prefs) }
            let view = others[index] ?? {
                let made = AddressPillView()
                others[index] = made
                addSubview(made, positioned: .below, relativeTo: here)
                return made
            }()
            view.ground = ground(index)
            view.doors.follow(active?.blockedPopups.isEmpty == false ? active : nil, browser: browser)
            view.words.whole = prefs.fullAddress
            view.host = .some(words)
            view.show(words != nil, animated: false)
            view.setLane(frame, shift: side * prefs.columnWidth)
            kept.insert(index)
        }
        for (index, view) in others where !kept.contains(index) {
            view.removeFromSuperview()
            others[index] = nil
        }
    }
}

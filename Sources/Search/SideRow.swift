import AppKit
import QuartzCore

struct RowGround: Equatable {
    var greys = KitGreys.white
    var ink = KitInk.flat
    var dark = false
    var stops: [Oklch]? = nil

    static func == (a: RowGround, b: RowGround) -> Bool {
        a.greys == b.greys && a.ink == b.ink && a.dark == b.dark && a.stops?.map(\.l) == b.stops?.map(\.l)
            && a.stops?.map(\.c) == b.stops?.map(\.c) && a.stops?.map(\.h) == b.stops?.map(\.h)
    }
}

struct RowState: Equatable {
    var live = false
    var interactive = true
    var editing = false
    var peek: ObjectIdentifier?
    var picked = false
    var join = RowJoin.none
    var before: Tab.ID?
    var refusals = 0
    var number: Int?
    var height: CGFloat = Metrics.sideRowHeight
    var radius: CGFloat = Metrics.sideRadius
    var carded = false
    var titleSize: CGFloat = 13
    var ground = RowGround()
    var hoverCards = true
    var splitView = false
    var icons = true
    var showsAddress = false
    var floatingNewTab = false
    var addressBar = true
    var tabsGive = true
    var nextMeeting = false
}

final class RowTitleView: NSView {
    var label = "" { didSet { if label != oldValue { title.text = label; needsLayout = true } } }
    var rest: AtRest? { didSet { if rest != oldValue { restChanged() } } }
    var shown = false { didSet { if shown != oldValue { swap(animated: true) } } }
    var hovering = false { didSet { if hovering != oldValue { swap(animated: false) } } }
    var size: CGFloat = 13 { didSet { if size != oldValue { restyle() } } }
    var tone = KitTone.title { didSet { if tone != oldValue { title.color = tone.base; title.opacity = tone.opacity } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { title.ink = ink; restLine.ink = ink } } }
    private(set) var reserve: CGFloat = 0

    private let title = KitLabel()
    private let restLine = KitLabel()
    private let mask = CAGradientLayer()
    private var fadeAnimated = false
    private var fadeSettles = false
    private var fadeWait: CFTimeInterval = 0
    private var fades = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        title.overflow = .tail
        title.lines = 1
        restLine.overflow = .middle
        addSubview(title)
        addSubview(restLine)
        restLine.isHidden = true
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
        layer?.mask = mask
        title.color = tone.base
        title.opacity = tone.opacity
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var natural: CGFloat { ceil(title.measure(width: .greatestFiniteMagnitude).width) }

    func keep(_ room: CGFloat, sweeps: Bool, after wait: CFTimeInterval = 0) {
        guard room != reserve else { return }
        reserve = room
        fadeAnimated = sweeps
        fadeSettles = !sweeps
        fadeWait = sweeps ? wait : 0
        needsLayout = true
    }

    func settleFade() {
        fadeAnimated = false
        fadeSettles = true
        updateMask()
    }

    func sweepFade() {
        guard fadeAnimated else { return }
        updateMask()
    }

    private func restyle() {
        title.font = .systemFont(ofSize: size)
        restChanged()
    }

    private var on: Bool { shown && rest != nil }

    private func restChanged() {
        guard let rest else {
            restLine.runs = []
            swap(animated: false)
            return
        }
        let plain = NSFont.systemFont(ofSize: size)
        let named = NSFont.systemFont(ofSize: size, weight: rest.kind == .file || rest.kind == .other ? .regular : .medium)
        var runs: [KitLabel.Run] = []
        if rest.kind == .notSecure { runs.append(KitLabel.Run(text: "Not secure  ", font: plain, color: Palette.NS.muted)) }
        if !rest.lead.isEmpty { runs.append(KitLabel.Run(text: rest.lead, font: plain, color: Palette.NS.muted)) }
        runs.append(KitLabel.Run(text: rest.name, font: named, color: Palette.NS.ink))
        if !rest.tail.isEmpty { runs.append(KitLabel.Run(text: rest.tail, font: plain, color: Palette.NS.muted)) }
        restLine.runs = runs
        restLine.setAccessibilityValue(rest.text)
        swap(animated: false)
    }

    private func swap(animated: Bool) {
        let restShown = on && !hovering
        if animated, let curve = Optional(Motion.kitSlide), curve.animates {
            title.layer?.kitAnimate("opacity", to: restShown ? 0 : 1, curve: curve)
            restLine.isHidden = !on
            restLine.layer?.kitAnimate("opacity", to: restShown ? 1 : 0, curve: curve)
        } else {
            title.layer?.removeAnimation(forKey: "opacity")
            restLine.layer?.removeAnimation(forKey: "opacity")
            title.alphaValue = restShown ? 0 : 1
            restLine.isHidden = !on
            restLine.alphaValue = restShown ? 1 : 0
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        title.kitSetFrame(NSRect(x: 0, y: 0, width: max(bounds.width, natural), height: height))
        restLine.kitSetFrame(NSRect(x: 0, y: 0, width: bounds.width, height: height))
        updateMask()
    }

    var benchDrawn: NSColor? { title.benchDrawn }

    var benchFade: (shown: [Double], model: [Double], held: Double) {
        let model = (mask.locations ?? []).map(\.doubleValue)
        let held = (mask.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
        return ((mask.presentation()?.locations ?? mask.locations ?? []).map(\.doubleValue), model, held)
    }

    func hold(against slide: CAPropertyAnimation) {
        guard let counter = RowTitleFade.counter(slide) else { return }
        mask.add(counter, forKey: "hold")
    }

    private func updateMask() {
        let room = bounds.width
        let wanted = natural > room - reserve + 0.5
        let fadeWidth: CGFloat = wanted ? TitleFadeWidth.width : 0
        let solid = max(0, room - reserve - fadeWidth)
        let clearFrom = max(solid, room - reserve)
        func at(_ x: CGFloat) -> NSNumber { NSNumber(value: Double(room > 0 ? min(1, max(0, x / room)) : 1)) }
        let locations = [NSNumber(value: 0), at(solid), at(clearFrom), NSNumber(value: 1)]
        let animate = fadeAnimated && Motion.kitQuick.animates && (wanted != fades || (mask.locations ?? []) != locations)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = bounds
        CATransaction.commit()
        if animate {
            if fadeWait > 0 {
                RowSweep.run(mask, "locations", to: locations, after: fadeWait)
            } else {
                mask.kitAnimate("locations", to: locations, curve: Motion.kitQuick)
            }
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if fadeSettles { mask.removeAnimation(forKey: "locations") }
            mask.locations = locations
            CATransaction.commit()
        }
        fades = wanted
        fadeAnimated = false
        fadeSettles = false
        fadeWait = 0
    }
}

enum TitleFadeWidth {
    static let width: CGFloat = 28
}

final class BylineView: NSView {
    var item: LiveItem? { didSet { if item != oldValue { rebuild() } } }
    var stateTint: NSColor? { didSet { if stateTint != oldValue { tinted() } } }
    var reserve: CGFloat = 0 { didSet { if reserve != oldValue { needsLayout = true } } }
    private var sweepWait: CFTimeInterval?
    private var was: (text: String, color: NSColor, opacity: Double)?
    private var wasDot = ""
    private(set) var arrivals = 0
    static let turn: TimeInterval = 0.32
    var ink: KitInk = .flat { didSet { if ink != oldValue { for label in [who, stack, dot, state] { label.ink = ink }; glyph.ink = ink } } }

    private let who = KitLabel()
    private let glyph = KitSymbol("square.stack.3d.up.fill", style: KitSymbol.Style(size: Metrics.liveLine - 1.5), tint: Palette.NS.muted)
    private let stack = KitLabel()
    private let dot = KitLabel()
    private let state = KitLabel()
    private let fade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fade.actions = ["bounds": NSNull(), "position": NSNull(), "locations": NSNull(), "frame": NSNull()]
        layer?.mask = fade
        for label in [who, stack, dot, state] {
            label.font = .systemFont(ofSize: Metrics.liveLine)
            label.color = Palette.NS.muted
            label.opacity = SideLook.bylineTone
            label.setAccessibilityElement(false)
            addSubview(label)
        }
        dot.wantsLayer = true
        state.wantsLayer = true
        addSubview(glyph)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func tinted() {
        state.color = stateTint ?? Palette.NS.muted
        state.opacity = stateTint == nil ? SideLook.bylineTone : 1
    }

    func arrive() {
        guard let was, was.text != state.text, let layer = state.layer else { return }
        layoutSubtreeIfNeeded()
        arrivals += 1
        let lift = Metrics.liveLine * 0.45
        let start = layer.convertTime(CACurrentMediaTime(), from: nil) + (was.text.isEmpty ? 0 : BylineView.turn * 0.25)
        CATransaction.begin()
        if wasDot.isEmpty, !dot.text.isEmpty, let separator = dot.layer {
            let appear = CABasicAnimation(keyPath: "opacity")
            appear.fromValue = 0
            appear.toValue = 1
            appear.beginTime = start
            appear.duration = BylineView.turn * 0.75
            appear.timingFunction = CAMediaTimingFunction(name: .easeOut)
            appear.fillMode = .backwards
            separator.add(appear, forKey: "arrive.fade")
        }
        if !was.text.isEmpty { leave(was) }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = start
        fade.duration = BylineView.turn * 0.75
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        layer.add(fade, forKey: "arrive.fade")
        let rise = KitSpring.roll.animation("transform.translation.y", from: lift, to: 0)
        rise.isAdditive = true
        rise.beginTime = start
        rise.fillMode = .backwards
        layer.add(rise, forKey: "arrive.rise")
        CATransaction.commit()
    }

    private func leave(_ was: (text: String, color: NSColor, opacity: Double)) {
        let old = KitLabel()
        old.wantsLayer = true
        old.font = state.font
        old.text = was.text
        old.color = was.color
        old.opacity = was.opacity
        old.ink = ink
        old.setAccessibilityElement(false)
        old.frame = NSRect(x: state.frame.minX, y: state.frame.minY, width: ceil(old.intrinsicContentSize.width), height: state.frame.height)
        addSubview(old)
        old.layoutSubtreeIfNeeded()
        old.displayIfNeeded()
        let lift = Metrics.liveLine * 0.45
        if let leaving = old.layer {
            leaving.opacity = 0
            let out = CABasicAnimation(keyPath: "opacity")
            out.fromValue = 1
            out.toValue = 0
            out.duration = BylineView.turn * 0.55
            out.timingFunction = CAMediaTimingFunction(name: .easeIn)
            leaving.add(out, forKey: "leave.fade")
            let up = CABasicAnimation(keyPath: "transform.translation.y")
            up.fromValue = 0
            up.toValue = -lift
            up.duration = BylineView.turn * 0.55
            up.timingFunction = CAMediaTimingFunction(name: .easeIn)
            up.fillMode = .forwards
            up.isRemovedOnCompletion = false
            leaving.add(up, forKey: "leave.rise")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + BylineView.turn) { old.removeFromSuperview() }
    }

    private func rebuild() {
        guard let item else { return }
        was = (state.text, state.color, state.opacity)
        wasDot = dot.text
        let author = item.author?.isEmpty == false ? item.author : nil
        let label = item.label?.isEmpty == false ? item.label : nil
        who.text = (author ?? "") + (author != nil && item.stack != nil ? " " : "")
        glyph.isHidden = item.stack == nil
        stack.text = item.stack.map { " " + $0.said } ?? ""
        dot.text = label != nil && item.who != nil ? " • " : ""
        state.text = LiveDocuments.byline(item) ?? label ?? ""
        setAccessibilityLabel(item.spokenByline ?? "")
        needsLayout = true
    }

    var drawn: String { who.text + stack.text + dot.text + state.text }

    func renew() {
        guard let item, let said = LiveDocuments.byline(item), said != state.text else { return }
        state.text = said
        setAccessibilityLabel(item.spokenByline ?? "")
        needsLayout = true
    }

    var natural: CGFloat {
        var width = who.intrinsicContentSize.width + stack.intrinsicContentSize.width + dot.intrinsicContentSize.width + state.intrinsicContentSize.width
        if !glyph.isHidden { width += glyphWidth }
        return width
    }

    private var glyphWidth: CGFloat { ceil(glyph.intrinsicContentSize.width) }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        let height = bounds.height
        func place(_ view: NSView, _ width: CGFloat, dy: CGFloat = 0) {
            view.kitSetFrame(NSRect(x: x, y: dy, width: width, height: height))
            x += width
        }
        place(who, who.intrinsicContentSize.width)
        if !glyph.isHidden { place(glyph, glyphWidth, dy: -1) }
        place(stack, stack.intrinsicContentSize.width)
        place(dot, dot.intrinsicContentSize.width)
        place(state, state.intrinsicContentSize.width)
        let room = bounds.width
        let end = max(0, room - reserve)
        let fades = natural > end + 0.5 && room > 0
        let start = fades ? max(0, (end - TitleFadeWidth.width) / room) : 1
        fade.frame = bounds
        let locations: [NSNumber] = [0, NSNumber(value: Double(start)), NSNumber(value: Double(fades ? end / max(1, room) : 1))]
        if let wait = sweepWait, Motion.kitQuick.animates, fade.locations != locations {
            RowSweep.run(fade, "locations", to: locations, after: wait)
        } else if sweepWait != nil || fade.locations != locations {
            fade.removeAnimation(forKey: "locations")
            fade.locations = locations
        }
        sweepWait = nil
    }

    func keep(_ room: CGFloat, sweeps: Bool, after wait: CFTimeInterval) {
        guard room != reserve else { return }
        sweepWait = sweeps ? wait : nil
        reserve = room
    }

    func hold(against slide: CAPropertyAnimation) {
        guard let counter = RowTitleFade.counter(slide) else { return }
        fade.add(counter, forKey: "hold")
    }
}

final class RowCloseZone: NSView {
    var armed = false
    var takes = false
    var act: () -> Void = {}
    var ready: () -> Bool = { true }
    private var down = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var handed = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard takes else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? self : hit
    }

    private func modified(_ event: NSEvent) -> Bool {
        !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }

    override func mouseDown(with event: NSEvent) {
        handed = modified(event)
        if handed { superview?.mouseDown(with: event) } else { down = ready() }
    }

    override func mouseDragged(with event: NSEvent) {
        if handed { superview?.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if handed {
            handed = false
            superview?.mouseUp(with: event)
            return
        }
        guard down else { return }
        down = false
        if armed, bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
    }
}

protocol TabRowHost: AnyObject {
    func rowPressed(_ row: NSView, event: NSEvent) -> Bool
    func rowDragged(_ row: NSView, event: NSEvent)
    func rowReleased(_ row: NSView, event: NSEvent) -> Bool
    func rowMenu(_ row: NSView, event: NSEvent) -> NSMenu?
    func rowHovered(_ row: NSView, _ over: Bool)
}

final class RowFaceView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

final class TabRowView: KitHoverView {
    static let iconLead: CGFloat = SideLook.rowLead

    private(set) weak var browser: Browser?
    private(set) weak var tab: Tab?
    var state = RowState() { didSet { if state != oldValue { stateChanged(from: oldValue) } } }
    var close: () -> Void = {}
    weak var host: TabRowHost?
    var faded = false { didSet { if faded != oldValue { alphaValue = faded ? 0.4 : 1 } } }

    private let pickedGround = KitPlate(radius: Metrics.sideRadius)
    private let hoverGround = KitPlate(radius: Metrics.sideRadius)
    let liveGround = KitPlate(radius: Metrics.sideRadius)
    private let face = RowFaceView()
    private let content = SideDocumentView()
    private let mark = RowMarkView()
    private let blank = KitSymbol("plus", style: KitSymbol.Style(size: 12, weight: IconLook.control))
    private let flask = KitSymbol("flask", style: KitSymbol.Style(size: 9))
    private let record = KitSymbol("record.circle", style: KitSymbol.Style(size: 10))
    private let title = RowTitleView()
    private let byline = BylineView()
    private let checks = ChecksMarkView(frame: NSRect(x: 0, y: 0, width: ChecksMarkView.side, height: ChecksMarkView.side))
    private let unseenDot = UnseenDotView()
    private let closeZone = RowCloseZone()
    private let closeSpot = CloseSpotView()
    private let speakerSpot = CloseSpotView(swaps: true)
    private let ring = RingView()
    private var ringTab: ObjectIdentifier?
    private var shownTab: ObjectIdentifier?
    private var laidSpeaker: (tab: ObjectIdentifier, sounding: Bool)?
    private var speakerTurn = 0
    private var speakerLeaving = false
    private var shortcut: ShortcutNumberView?
    private var talk: TalkMarkView?
    private var agentFace: NSView?
    private var popupSign: NSView?
    private var translateSign: NSView?
    private var callLeft: NSView?
    private var peekBadge: NSView?
    private var field: NSView?
    private var pressedDown = false
    private var selectedOnPress = false
    private var pressedAt: CFTimeInterval = 0
    private var hoverLeaving = false
    private var benchShown = false
    private var talkSlide: CFTimeInterval?
    private var closeReadyAt: CFTimeInterval = 0
    static var clock: () -> CFTimeInterval = CACurrentMediaTime
    private var wash: MergedWash?
    private var washed: ObjectIdentifier?
    private var waning: MergedWash?
    private(set) var mergedForm: MergedForm?
    private(set) var plays = 0
    private(set) var wornAt: CFTimeInterval?
    var mergedLayers: Int { wash?.layers.count ?? 0 }
    var mergedBegan: CFTimeInterval? { wash?.began }
    var mergedLasts: CFTimeInterval { wash?.lasts ?? 0 }
    var washFrame: NSRect? { wash.map { face.convert($0.frame, to: self) } }
    var washes: Bool { wash != nil || waning != nil }
    var benchLive: Bool? {
        didSet {
            guard let benchLive, state.live != benchLive else { return }
            var made = state
            made.live = benchLive
            state = made
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        followsPointer = true
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        face.wantsLayer = true
        face.clipsToBounds = false
        face.layer?.masksToBounds = false
        pickedGround.isHidden = true
        addSubview(pickedGround)
        addSubview(face)
        for plate in [hoverGround, liveGround] {
            plate.isHidden = true
            face.addSubview(plate)
        }
        content.wantsLayer = true
        face.addSubview(content)
        for view in [mark, blank, flask, record, title, byline] as [NSView] { content.addSubview(view) }
        content.addSubview(checks)
        checks.isHidden = true
        face.addSubview(speakerSpot)
        face.addSubview(ring)
        face.addSubview(unseenDot)
        face.addSubview(closeZone)
        closeZone.addSubview(closeSpot)
        closeSpot.isHidden = true
        speakerSpot.isHidden = true
        ring.isHidden = true
        unseenDot.isHidden = true
        closeZone.act = { [weak self] in self?.closeTapped() }
        closeZone.ready = { [weak self] in self?.closeReady ?? false }
        closeSpot.act = { [weak self] in self?.pointerClose() }
        closeSpot.ready = { [weak self] in self?.closeReady ?? false }
        speakerSpot.act = { [weak self] in self?.tab?.toggleMute() }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        tab == nil ? nil : super.hitTest(point)
    }

    func show(_ tab: Tab, in browser: Browser, state: RowState) {
        let changed = self.tab !== tab
        if changed {
            if let old = self.tab { Bench.rowDisappeared(old.id) ; benchShown = false }
            self.tab = tab
            self.browser = browser
        }
        self.state = benchLive.map { lit in
            var made = state
            made.live = lit
            return made
        } ?? state
        if changed { refresh() }
        registerBench()
    }

    private static var spare: [TabRowView] = []
    private(set) var pooled = false

    static func take(in parent: NSView) -> TabRowView {
        let near = spare.lastIndex { $0.superview === parent }
        let row = near.map { spare.remove(at: $0) } ?? spare.popLast() ?? TabRowView()
        row.isHidden = false
        return row
    }

    func recycle() {
        forget()
        unwash(fading: false)
        StackFoldButton.on(self)?.removeFromSuperview()
        ringTab = nil
        shownTab = nil
        laidSpeaker = nil
        restSpeaker(shown: false)
        host = nil
        close = {}
        faded = false
        alphaValue = 1
        frame = .zero
        guard Self.spare.count < 96 else {
            removeFromSuperview()
            return
        }
        isHidden = true
        pooled = true
        Self.spare.append(self)
    }

    func settleFromPool() {
        guard pooled else { return }
        pooled = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let spinning = ring.layer
        func still(_ layer: CALayer) {
            guard layer !== spinning else { return }
            layer.removeAllAnimations()
            layer.sublayers?.forEach(still)
        }
        if let layer { still(layer) }
        layer?.transform = CATransform3DIdentity
        face.layer?.transform = CATransform3DIdentity
        liveGround.layer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func forget() {
        if let tab {
            if benchShown { Bench.rowDisappeared(tab.id) }
            Bench.rowFrames[tab.id] = nil
            if let browser { browser.hoverCards.leave(.tab(tab.id)) }
        }
        benchShown = false
        benchLive = nil
        waning?.hold()
        tab = nil
        end = nil
        hoverEnded()
        endHover()
    }

    var arrivals: Int { byline.arrivals }

    private func unwash(fading: Bool) {
        if !fading, let waning {
            waning.end()
            self.waning = nil
        }
        guard let wash else { return }
        self.wash = nil
        washed = nil
        mergedForm = nil
        wornAt = nil
        guard fading else {
            wash.end()
            return
        }
        waning?.end()
        waning = wash
        wash.wane { [weak self, weak wash] in
            if let self, self.waning === wash { self.waning = nil }
        }
    }

    var mergedTraces: Int {
        kitSubviews(of: MergedCanvas.self).count
    }

    var mergedMoving: Int {
        var seen = Set<ObjectIdentifier>()
        func count(_ layer: CALayer) -> Int {
            guard seen.insert(ObjectIdentifier(layer)).inserted else { return 0 }
            return (layer.animationKeys() ?? []).filter { $0.hasPrefix(MergedMotion.key + ".") }.count + (layer.sublayers ?? []).map(count).reduce(0, +)
        }
        return ([layer] + kitSubviews(of: MergedCanvas.self).map(\.layer)).compactMap { $0 }.map(count).reduce(0, +)
    }

    private func registerBench() {
        guard Store.testing, let tab, state.interactive, window != nil else { return }
        Bench.rowPress(tab.id) { [weak self] down in self?.benchPress(down) }
        Bench.rowLayers(tab.id) { [weak self] in
            guard let self else { return [:] }
            let named: [String: CALayer?] = ["face": face.layer, "content": content.layer, "live": liveGround.layer, "hover": hoverGround.layer]
            return named.compactMapValues { $0 }
        }
        guard !benchShown else { return }
        benchShown = true
        Bench.rowAppeared(tab.id) { [weak self] over in self?.benchHover(over) }
    }

    private var benchHovering: Bool?

    private func benchHover(_ over: Bool) {
        benchHovering = over
        hoverChanged()
    }

    var isHovering: Bool { benchHovering ?? hovering }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if benchShown, let tab { Bench.rowDisappeared(tab.id) }
            benchShown = false
        } else {
            registerBench()
        }
    }

    private func round(from old: CGFloat) {
        let moving = window != nil && !pooled && Motion.kitSettle.animates
        for plate in [pickedGround, hoverGround, liveGround] {
            plate.radius = state.radius
            guard moving, let layer = plate.layer, let shown = (layer.presentation() ?? layer).cornerRadius as CGFloat?,
                  let turn = Motion.kitSettle.animation("cornerRadius", from: NSNumber(value: Double(shown > 0 ? shown : old)),
                                                        to: NSNumber(value: Double(state.radius))) else { continue }
            turn.fillMode = .backwards
            layer.add(turn, forKey: "cornerRadius")
        }
    }

    private func stateChanged(from old: RowState) {
        if old.ground != state.ground { applyGround() }
        if old.radius != state.radius { round(from: old.radius) }
        if old.refusals != state.refusals, state.editing { shake() }
        if old.live != state.live { liveChanged(from: old) }
        refresh()
    }

    override func hoverChanged() {
        if !isHovering { benchHovering = nil }
        refresh()
        host?.rowHovered(self, isHovering)
        guard let tab, let browser else { return }
        if isHovering, state.interactive, state.hoverCards, !state.editing {
            browser.hoverCards.enter(.tab(tab.id), frame: cardSpot())
        } else {
            browser.hoverCards.leave(.tab(tab.id))
        }
    }

    private func hoverEnded() {
        benchHovering = nil
    }

    func cardSpot() -> CGRect {
        guard let window, let column = ColumnSpace.column(of: self) else { return .zero }
        let row = convert(bounds, to: nil)
        let top = window.contentView.map { $0.bounds.height } ?? window.frame.height
        let side = column.convert(column.bounds, to: nil)
        return CGRect(x: side.minX, y: top - row.maxY, width: side.width, height: row.height)
    }

    func benchFrame() -> CGRect? {
        guard let window, let content = window.contentView else { return nil }
        let row = convert(bounds, to: content)
        return CGRect(x: row.minX, y: content.isFlipped ? row.minY : content.bounds.height - row.maxY, width: row.width, height: row.height)
    }

    private func applyGround() {
        let ground = state.ground
        for plate in [pickedGround, hoverGround, liveGround] { plate.ink = ground.ink }
        pickedGround.fill = ground.greys.picked
        hoverGround.fill = ground.greys.hover
        unseenDot.tone = ground.greys.dot
        unseenDot.ink = ground.ink
        for spot in [closeSpot, speakerSpot] { spot.ink = ground.ink }
        title.ink = ground.ink
        byline.ink = ground.ink
        mark.ink = ground.ink
        for symbol in [blank, flask, record] { symbol.ink = ground.ink }
        ring.ink = ground.ink
        ring.needsLayout = true
        shortcut?.ink = ground.ink
    }

    private func liveChanged(from old: RowState) {
        guard let browser, let tab else { return }
        if state.live {
            let switching = SwitchFade.within(from: state.before, to: [tab.id], among: browser.tabs.map(\.id))
            liveGround.isHidden = false
            let pressed = pressedDown || CACurrentMediaTime() - pressedAt < RowPress.window
            if switching, !Motion.reduced, !hoverGround.isHidden { handHoverToSlab() }
            if switching, !Motion.calm {
                liveGround.alphaValue = 1
                if let fade = Motion.kitQuick.animation("opacity", from: 0, to: 1) { liveGround.layer?.add(fade, forKey: "arrive") }
                guard !pressed else { return }
                let middle = CGPoint(x: liveGround.bounds.midX, y: liveGround.bounds.midY)
                var small = CATransform3DMakeTranslation(middle.x, middle.y, 0)
                small = CATransform3DScale(small, SwitchFade.scale, SwitchFade.scale, 1)
                small = CATransform3DTranslate(small, -middle.x, -middle.y, 0)
                if let grow = Motion.kitQuick.animation("transform", from: NSValue(caTransform3D: small), to: NSValue(caTransform3D: CATransform3DIdentity)) {
                    liveGround.layer?.add(grow, forKey: "grow")
                }
            } else if switching {
                liveGround.layer?.kitAnimate("opacity", to: 1, curve: .easeOut(0.14))
            }
        } else if old.live {
            if isHovering, !(state.interactive && state.picked), !Motion.reduced {
                hoverGround.isHidden = false
                hoverGround.layer?.removeAnimation(forKey: "handover")
                hoverGround.layer?.opacity = 1
                hoverGround.layer?.add(RowPress.fade(from: 0, to: 1, duration: 0.08), forKey: "handback")
            }
            let leaving = liveGround
            if Motion.reduced {
                leaving.isHidden = true
            } else {
                CATransaction.begin()
                CATransaction.setCompletionBlock { [weak self] in
                    guard let self, !self.state.live else { return }
                    self.liveGround.isHidden = true
                    self.liveGround.alphaValue = 1
                    self.liveGround.layer?.opacity = 1
                }
                leaving.layer?.kitAnimate("opacity", to: 0, curve: .easeOut(0.08))
                CATransaction.commit()
            }
        }
    }

    private func handHoverToSlab() {
        hoverLeaving = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.hoverLeaving else { return }
            self.hoverLeaving = false
            self.hoverGround.layer?.opacity = 1
            self.refresh()
        }
        hoverGround.layer?.kitAnimate("opacity", to: Swift.Float(0), curve: .easeOut(0.12), key: "handover")
        CATransaction.commit()
    }

    private var speaker: Bool { guard let tab else { return false }; return !state.editing && (tab.speaks || tab.muted) }
    private var status: Bool { guard let tab else { return false }; return !state.editing && tab.loading }
    private var peeking: Bool { state.peek != nil }
    private var unseen: Bool {
        guard let tab else { return false }
        return (tab.liveItem?.fresh == true || tab.unread) && !status && !peeking && state.number == nil
    }
    private var talking: Int {
        guard let tab, let count = tab.liveItem?.unanswered, count > 0 else { return 0 }
        return !state.editing && !status && !peeking && state.number == nil ? count : 0
    }
    private var talkWidth: CGFloat { talk.map { ceil($0.intrinsicContentSize.width) } ?? 0 }
    private var talkRoom: CGFloat { talk == nil ? 0 : talkWidth + TalkPlace.gap }
    private var talkAside: Bool { unseen || (isHovering && !state.editing) }
    private var closeFromEnd: CGFloat? {
        let close = Metrics.closeSquare(state.height) + Metrics.closeInset(state.height)
        if talk != nil, !talkAside { return TalkPlace.fromEnd(height: state.height, talk: talkWidth, aside: false) }
        if ((isHovering && state.interactive) || unseen) && !state.editing { return close + talkRoom }
        return talk == nil ? nil : close + talkRoom
    }

    private var closeReady: Bool { !closeSpot.isHidden && Self.clock() >= closeReadyAt }

    private var talkWaits: Bool {
        guard let tab, talk != nil, let end, end.tab == ObjectIdentifier(tab), end.talk, !end.aside else { return false }
        return window != nil && !pooled && Motion.kitQuick.animates
    }

    private static let sliding = "slide"
    private static let revealing = "reveal"

    private struct RowEnd: Equatable {
        var tab: ObjectIdentifier
        var dot: Bool
        var talk: Bool
        var call: Bool
        var aside: Bool
        var hovering: Bool
        var title: NSRect
    }

    private var end: RowEnd?
    private static let arriving = "arrive"

    private func settleEnd(for tab: Tab, room: CGFloat?) {
        let dot = room != nil && !isHovering && unseen
        let before = end
        talkSlide = nil
        guard let room else {
            end = nil
            leave(unseenDot)
            return
        }
        let call = (callLeft?.frame.width ?? 0) > 0
        let now = RowEnd(tab: ObjectIdentifier(tab), dot: dot, talk: talk != nil, call: call, aside: talkAside, hovering: isHovering, title: title.frame)
        end = now
        let same = before?.tab == now.tab && window != nil && !pooled
        if !same { talk?.layer?.removeAnimation(forKey: Self.sliding) }
        let still = same && before?.title == now.title
        var comers: [NSView] = []
        if dot, before?.dot != true { comers.append(unseenDot) }
        if let talk, before?.talk != true { comers.append(talk) }
        if call, let callLeft, before?.call != true { comers.append(callLeft) }
        if !dot { leave(unseenDot) }
        if same, before?.talk == true, now.talk, before?.aside != now.aside {
            let sweeps = Motion.kitQuick.animates
            let wait = !now.aside && before?.hovering == true ? RowSweep.back : 0
            if sweeps { talkSlide = wait }
            title.keep(room, sweeps: sweeps, after: wait)
            if sweeps { title.sweepFade() } else { title.settleFade() }
            for view in comers { arrive(view, after: view === callLeft ? wait + RowTitleFade.lead : RowSweep.wait, fading: true) }
            return
        }
        let marked = dot || now.talk || call
        let stays = marked && comers.count < (dot ? 1 : 0) + (now.talk ? 1 : 0) + (call ? 1 : 0)
        let swapped = comers == [unseenDot] && before?.hovering == true && room == title.reserve
        let leads = still && !comers.isEmpty && !stays && room != title.reserve && Motion.kitQuick.animates
            && RowTitleFade.fades(natural: title.natural, room: title.frame.width, reserve: room)
        let settles = !same || (marked && !leads && (room != title.reserve || !comers.isEmpty))
        title.keep(room, sweeps: marked ? leads : same)
        if settles { title.settleFade() } else if leads { title.sweepFade() }
        for view in comers { arrive(view, after: leads ? RowTitleFade.lead : 0, fading: same && !swapped) }
    }

    private func arrive(_ view: NSView, after wait: CFTimeInterval, fading: Bool) {
        view.isHidden = false
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: Self.arriving)
        guard fading, let fade = Motion.kitQuick.animation("opacity", from: 0, to: 1) else { return }
        guard wait > 0 else {
            layer.add(fade, forKey: Self.arriving)
            return
        }
        fade.beginTime = wait
        fade.fillMode = .backwards
        let held = CAAnimationGroup()
        held.animations = [fade]
        held.duration = wait + fade.duration
        layer.add(held, forKey: Self.arriving)
    }

    private func leave(_ view: NSView) {
        view.layer?.removeAnimation(forKey: Self.arriving)
        view.isHidden = true
    }

    private var colour: KitTone {
        state.live ? .strong : isHovering ? .ink : .title
    }

    override func layout() {
        super.layout()
        refresh()
    }

    func refresh() {
        guard let tab, let browser else { return }
        let height = state.height
        let hovering = isHovering
        let draft = tab.liveItem?.draft == true
        let editing = state.editing
        let repointed = shownTab != ObjectIdentifier(tab)
        shownTab = ObjectIdentifier(tab)
        if repointed { mark.settle() }

        let picked = state.interactive && state.picked
        pickedGround.isHidden = !picked
        pickedGround.corners = RowJoin.corners(state.join)
        if !hoverLeaving || picked || !state.live { hoverGround.isHidden = picked || !(hovering && !state.live) }
        if hoverLeaving, hoverGround.isHidden || !state.live {
            hoverLeaving = false
            hoverGround.layer?.removeAnimation(forKey: "handover")
            hoverGround.layer?.opacity = 1
        }
        liveGround.isHidden = liveGround.isHidden && !state.live
        if state.live { liveGround.isHidden = false }
        SelectedLook.dress(liveGround, greys: state.ground.greys, ink: state.ground.ink, picked: picked)

        let tone = draft ? colour.opacity(0.62) : colour
        blank.tint = colour.base
        blank.opacity = colour.opacity
        flask.tint = colour.base
        flask.opacity = colour.opacity * 0.7
        record.tint = colour.base
        record.opacity = colour.opacity * 0.8

        let showsMark = !editing && !tab.isBlank && (state.icons || tab.customIcon != nil)
        blank.isHidden = editing || !tab.isBlank
        mark.isHidden = !showsMark
        if showsMark {
            mark.icon = tab.icon
            mark.letter = tab.monogram
            mark.size = SideLook.rowMark
            mark.draft = draft
        }
        let merged = tab.liveItem?.label == PullState.merged
        let turning = merged && !editing && (tab.liveItem.map { LiveFolders.shared.turning($0.key) } ?? false)
        if let waning, !waning.fading {
            waning.end()
            self.waning = nil
        }
        if wash != nil, !turning || washed != ObjectIdentifier(tab) { unwash(fading: washed == ObjectIdentifier(tab) && window != nil) }
        if turning, wash == nil {
            wash = MergedWash()
            washed = ObjectIdentifier(tab)
        }
        var leading = false
        var arrived = false
        var scene: MergedScene?
        var mergedTint: NSColor?
        let dark = state.ground.dark
        let onFrame = state.ground.greys.onFrame
        let stops = onFrame ? state.ground.stops : nil
        let lift = state.ground.ink.lift
        let pill = underMark(hovering: hovering)
        let average = stops.map { Paint.Ground(stops: $0, lightInk: dark).average }
        let halo = ChecksTint.ground(average, pill: pill, frame: onFrame, dark: dark, lift: lift)
        if wash != nil {
            let ink = ChecksTint.made(.passing, merged: true, dark: dark, stops: stops, frame: onFrame, lift: lift)
            let side = ChecksTint.ground(average, pill: .none, frame: onFrame, dark: dark, lift: lift)
            scene = MergedScene(bounds: bounds, radius: state.radius, ink: ink, under: halo, side: side, pill: pill, dark: dark)
        }
        if turning, tab.leads, window != nil, !Motion.reduced {
            tab.leads = false
            leading = true
        }
        if showsMark, let item = tab.liveItem, let made = merged ? .passing : item.checks {
            checks.isHidden = false
            checks.tab = Store.testing ? tab.id : nil
            let tint = ChecksTint.made(made, merged: merged, dark: dark, stops: stops, frame: onFrame, lift: lift)
            let glyph = scene?.glyph.color ?? tint.color
            checks.show(made, merged: merged, glyph: glyph, halo: .checks(scene?.ground ?? halo))
            if merged { mergedTint = glyph }
        } else {
            checks.isHidden = true
            if let scene { mergedTint = scene.glyph.color }
        }

        let agent = !editing && (tab.agent || tab.agentActing != nil)
        if agent {
            let face = agentFace ?? SideSigns.agentFace(tab: tab)
            if agentFace == nil { content.addSubview(face); agentFace = face }
            SideSigns.update(face, colour: colour, ground: state.ground)
        } else if let face = agentFace {
            face.removeFromSuperview()
            agentFace = nil
        }
        flask.isHidden = editing || agent || !tab.bench
        record.isHidden = editing || !tab.recording
        record.toolTip = tab.recording ? "Recording" : nil

        if !editing, !state.addressBar, !tab.blockedPopups.isEmpty {
            let sign = popupSign ?? SideSigns.popupSign(browser: browser, tab: tab)
            if popupSign == nil { content.addSubview(sign); popupSign = sign }
            SideSigns.update(sign, colour: colour, ground: state.ground)
        } else if let sign = popupSign {
            sign.removeFromSuperview()
            popupSign = nil
        }
        if !editing, tab.translation != nil {
            let sign = translateSign ?? SideSigns.translateSign(tab: tab)
            if translateSign == nil { content.addSubview(sign); translateSign = sign }
            SideSigns.update(sign, colour: colour, ground: state.ground)
        } else if let sign = translateSign {
            sign.removeFromSuperview()
            translateSign = nil
        }

        title.isHidden = editing
        title.label = tab.label
        title.rest = state.live && !editing ? AtRest.said(tab.saidAddress, always: state.showsAddress) : nil
        title.shown = title.rest != nil
        title.hovering = hovering
        title.size = state.titleSize
        let merging = tab.liveItem.map { $0.label == PullState.merged && LiveFolders.shared.turning($0.key) } ?? false
        let arriving = tab.arrives && merging && window != nil && !Motion.reduced
        if arriving, let layer = title.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = BylineView.turn * 0.75
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "merging")
        }
        title.tone = merging ? .strong : tone
        byline.isHidden = editing || tab.liveItem?.byline == nil
        if !byline.isHidden {
            byline.item = tab.liveItem
            byline.renew()
            byline.stateTint = mergedTint
        }
        if tab.arrives, merged {
            tab.arrives = false
            if arriving, !byline.isHidden { byline.arrive() }
            arrived = arriving
        }

        if editing {
            let made = field ?? SideSigns.tabAddressField(browser: browser)
            if field == nil { content.addSubview(made); field = made }
        } else if let made = field {
            made.removeFromSuperview()
            field = nil
        }

        if speaker {
            speakerSpot.side = Metrics.closeSquare(height)
            if repointed {
                speakerSpot.swaps = false
                speakerSpot.symbol = tab.speakerSymbol
                speakerSpot.swaps = true
            } else {
                speakerSpot.symbol = tab.speakerSymbol
            }
            speakerSpot.label = tab.muted ? "Unmute Tab" : "Mute Tab"
            speakerSpot.toolTip = speakerSpot.label
        }

        if let peek = state.peek, let page = browser.peekTab, ObjectIdentifier(page) == peek {
            let badge = peekBadge ?? SideSigns.peekBadge(page: page, size: 16)
            if peekBadge == nil { face.addSubview(badge); peekBadge = badge }
            badge.alphaValue = hovering && !status ? 0 : 1
        } else if let badge = peekBadge {
            badge.removeFromSuperview()
            peekBadge = nil
        }

        if state.interactive, !editing, let number = state.number {
            let made = shortcut ?? ShortcutNumberView(number: number)
            if shortcut == nil { face.addSubview(made); shortcut = made; made.ink = state.ground.ink }
            made.number = number
        } else if let made = shortcut {
            made.removeFromSuperview()
            shortcut = nil
        }

        let sameTab = ringTab == ObjectIdentifier(tab)
        ringTab = ObjectIdentifier(tab)
        ring.show(status, animated: sameTab)
        ring.alphaValue = hovering ? 0 : 1

        if !editing, !hovering, state.nextMeeting, let address = tab.address, MeetingLink.service(of: address) != nil {
            let left = callLeft ?? SideSigns.callTimeLeft(browser: browser, tab: tab) { [weak self] in self?.needsLayout = true }
            if callLeft == nil { face.addSubview(left, positioned: .below, relativeTo: closeZone); callLeft = left }
            SideSigns.update(left, colour: colour, ground: state.ground)
        } else if let left = callLeft {
            left.removeFromSuperview()
            callLeft = nil
        }

        let talking = self.talking
        if talking > 0 {
            let made = talk ?? TalkMarkView()
            if talk == nil {
                made.wantsLayer = true
                face.addSubview(made, positioned: .below, relativeTo: closeZone)
                talk = made
            }
            made.thing = tab.id
            made.count = talking
            made.ink = state.ground.ink
        } else if let made = talk {
            made.removeFromSuperview()
            talk = nil
        }

        closeZone.isHidden = editing
        closeZone.armed = hovering && state.interactive
        closeZone.takes = state.interactive
        let closes = hovering && !editing
        if closeSpot.isHidden == closes {
            let waits = closes && talkWaits
            closeReadyAt = Self.clock() + (waits ? RowSweep.wait : 0)
            closeSpot.layer?.removeAnimation(forKey: Self.revealing)
            if waits, let fade = Motion.kitQuick.animation("opacity", from: 0, to: 1) {
                closeSpot.layer?.add(RowSweep.held(fade, after: RowSweep.wait), forKey: Self.revealing)
            } else {
                closeSpot.layer?.kitTransition(Motion.kitQuick)
            }
            closeSpot.isHidden = !closes
            if closes { closeSpot.settle() }
        }
        if closes {
            closeSpot.symbol = "xmark"
            closeSpot.side = Metrics.closeSquare(height)
            closeSpot.label = "Close Tab"
            closeSpot.toolTip = "Close Tab"
            closeSpot.armed = state.interactive
        }

        setAccessibilityLabel(tab.label)
        setAccessibilityIdentifier(nil)
        toolTip = state.hoverCards ? nil : tab.label
        place()
        if let wash, let scene {
            if mergedForm == nil {
                let form: MergedForm = Motion.reduced || window == nil ? .still
                    : leading && MergedCrowd.first() ? .full : leading ? .quiet : arrived ? .follow : .still
                mergedForm = form
                wornAt = CACurrentMediaTime()
                if form == .full { plays += 1 }
                let since = form == .follow ? tab.liveKey.flatMap(LiveFolders.shared.followed) : nil
                let lasts = since.map { MergedWash.lasts(elapsed: CACurrentMediaTime() - $0, hold: LiveFolders.shared.mergedHold) } ?? MergedWash.sweep
                wash.wear(scene, in: face, below: content, form: form, lasts: lasts)
            } else {
                wash.fit(scene)
            }
        }
        if Store.testing, state.interactive, let frame = benchFrame() { Bench.rowFrames[tab.id] = frame }
    }

    private var titleToEnd: CGFloat = .infinity

    private var benchSeen: Bool {
        guard let layer, !visibleRect.isEmpty else { return false }
        var at = layer.presentation() ?? layer
        var rect = at.bounds
        while let up = at.superlayer {
            rect = at.convert(rect, to: up)
            if up.masksToBounds { rect = rect.intersection(up.bounds) }
            if rect.isNull || rect.width < 1 || rect.height < 1 { return false }
            at = up
        }
        return rect.intersects(at.bounds)
    }

    var benchTitle: [String: Any]? {
        guard let tab, let window, let content = window.contentView, let drawn = title.benchDrawn?.usingColorSpace(.sRGB),
              let meant = title.tone.resolved(state.ground.ink, dark: title.kitDark).usingColorSpace(.sRGB) else { return nil }
        var shown = 1.0
        var layer: CALayer? = title.layer
        while let at = layer {
            shown *= Double((at.presentation() ?? at).opacity)
            layer = at.superlayer
        }
        let rect = title.convert(title.bounds, to: content)
        let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        return ["id": Bench.short(tab), "label": tab.label, "live": state.live, "hover": isHovering,
                "rgba": [drawn.redComponent, drawn.greenComponent, drawn.blueComponent, drawn.alphaComponent].map { Double($0) },
                "meant": [meant.redComponent, meant.greenComponent, meant.blueComponent, meant.alphaComponent].map { Double($0) },
                "shown": shown, "lift": state.ground.ink.lift, "dark": state.ground.dark,
                "frame": [rect.minX, top, min(rect.width, title.natural), rect.height].map { Double($0) }]
    }

    var benchIcon: [String: Any]? {
        guard let tab else { return nil }
        var shown = 1.0
        var hidden = false
        var keys: [String] = []
        var layer: CALayer? = mark.layer
        while let at = layer {
            let seen = at.presentation() ?? at
            shown *= Double(seen.opacity)
            if seen.isHidden { hidden = true }
            keys += at.animationKeys() ?? []
            layer = at.superlayer
        }
        var made = mark.benchPicture
        made["id"] = Bench.short(tab)
        made["label"] = tab.label
        made["known"] = tab.icon != nil
        made["markHidden"] = mark.isHiddenOrHasHiddenAncestor
        made["shown"] = shown
        made["chainHidden"] = hidden
        made["keys"] = keys
        made["pooled"] = pooled
        made["seen"] = benchSeen
        return made
    }

    static func iconDrawn(_ read: [String: Any]) -> Bool {
        guard read["known"] as? Bool == true else { return true }
        return read["markHidden"] as? Bool == false && read["contents"] as? Bool == true && read["pictureHidden"] as? Bool == false
            && read["placed"] as? Bool == true && read["fresh"] as? Bool == true && (read["fading"] as? [String])?.isEmpty != false
            && read["shownContents"] as? Bool == true && read["shownHidden"] as? Bool == false
            && read["chainHidden"] as? Bool == false && (read["shown"] as? Double ?? 0) > 0.9
    }

    var benchEnd: [String: Any]? {
        guard let tab, let window else { return nil }
        func seen(_ view: NSView?) -> Double {
            guard let view, var layer = view.layer else { return 0 }
            var value = 1.0
            while true {
                let shown = layer.presentation() ?? layer
                if shown.isHidden { return 0 }
                value *= Double(shown.opacity)
                guard let up = layer.superlayer else { break }
                layer = up
            }
            return value
        }
        func turning(_ view: NSView?) -> Bool { view?.layer?.animation(forKey: kCATransition) != nil }
        let fade = title.benchFade
        let x = Double(title.frame.minX), room = Double(title.frame.width)
        func places(_ locations: [Double], by shift: Double = 0) -> [Double] {
            locations.count == 4 ? [x + shift + locations[1] * room, x + shift + locations[2] * room] : []
        }
        let slid = (content.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? NSNumber)?.doubleValue ?? 0
        let place = convert(bounds, to: nil)
        return ["id": Bench.short(tab), "label": tab.label, "interactive": state.interactive, "hover": isHovering,
                "at": [Double(place.minX), Double(window.frame.height - place.maxY)], "width": Double(bounds.width),
                "seen": benchSeen,
                "x": x, "room": room, "natural": Double(title.natural), "titled": !title.isHidden,
                "shown": places(fade.shown, by: slid + fade.held), "model": places(fade.model), "slid": slid,
                "call": callLeft?.layer?.presentation() == nil ? 0 : seen(callLeft), "callX": Double(callLeft?.frame.minX ?? 0), "callWidth": Double(callLeft?.frame.width ?? 0),
                "callShownX": Double(callLeft.map { ($0.layer?.presentation() ?? $0.layer)?.frame.minX ?? $0.frame.minX } ?? 0),
                "dot": seen(unseenDot), "dotTurning": turning(unseenDot), "dotX": Double(unseenDot.frame.minX),
                "talk": seen(talk), "talkX": Double(talk?.frame.minX ?? 0), "talkRight": Double(talk?.frame.maxX ?? 0),
                "talkShownX": Double(talk.map { ($0.layer?.presentation() ?? $0.layer)?.frame.minX ?? $0.frame.minX } ?? 0),
                "talkAside": talkAside, "talkSliding": talk?.layer?.animation(forKey: Self.sliding) != nil,
                "crossRight": Double(TalkPlace.crossRight(width: bounds.width, height: state.height)),
                "crossLeft": Double(TalkPlace.crossRight(width: bounds.width, height: state.height) - CloseMarkView.ink(side: Metrics.closeSquare(state.height))),
                "cross": seen(closeSpot), "crossTurning": turning(closeSpot) || closeSpot.layer?.animation(forKey: Self.revealing) != nil]
    }

    func noteBench() {
        guard Store.testing, state.interactive, let tab, let frame = benchFrame() else { return }
        Bench.rowFrames[tab.id] = frame
    }

    private func underMark(hovering: Bool) -> ChecksTint.Pill {
        let picked = state.interactive && state.picked
        switch (picked, state.live) {
        case (true, true): return .pickedLive
        case (true, false): return .picked
        case (false, true): return .live
        case (false, false): return hovering ? .hover : .none
        }
    }

    private func place() {
        guard let tab else { return }
        let height = state.height
        let width = bounds.width
        let editing = state.editing
        let square = Metrics.closeSquare(height)
        let inset = Metrics.closeInset(height)

        var grounds = bounds
        pickedGround.kitSetFrame(state.join.above ? NSRect(x: 0, y: -Metrics.sideGap, width: width, height: height + Metrics.sideGap) : bounds)
        grounds = bounds
        face.kitSetFrame(bounds)
        hoverGround.kitSetFrame(grounds)
        liveGround.kitSetFrame(grounds)
        content.kitSetFrame(bounds)

        let x: CGFloat = 0
        let endInset = inset + square / 2 - 15 / 2
        var trailing = width - (status || peeking ? endInset : 0)
        var ends: [(NSView, CGFloat)] = []
        if status { ends.append((ring, 15)) }
        if let shortcut { ends.append((shortcut, ShortcutNumberView.side + (status ? 0 : 28))) }
        if let peekBadge { ends.append((peekBadge, 16)) }
        for (index, end) in ends.enumerated() {
            let (view, room) = end
            let slot: CGFloat = view === ring ? 15 : view === peekBadge ? 16 : ShortcutNumberView.side
            let size: CGFloat = view === ring ? 11 : slot
            let left = trailing - room
            view.kitSetFrame(NSRect(x: left + (slot - size) / 2, y: (height - size) / 2, width: size, height: size))
            trailing = left - (index < ends.count - 1 || true ? 8 : 0)
        }
        let innerEnd = ends.isEmpty ? trailing + 8 - 8 : trailing
        let lead: CGFloat = Self.iconLead
        let tail: CGFloat = status || peeking ? 0 : 10
        var cursor = x + lead
        if speaker {
            speakerSpot.kitSetFrame(NSRect(x: cursor + (SideLook.rowMark - square) / 2, y: inset, width: square, height: square))
            cursor += SideLook.speakerRoom
        }
        settleSpeaker(for: tab)
        let innerRight = (ends.isEmpty ? width - (status || peeking ? endInset : 0) : innerEnd) - tail
        var callFromEnd: CGFloat?
        if let callLeft {
            let size = callLeft.fittingSize
            let sign = ceil(size.width)
            let place = RowTitleFade.call(width: width, sign: sign, endsLeft: ends.isEmpty ? nil : innerEnd, markFromEnd: closeFromEnd)
            callLeft.kitSetFrame(NSRect(x: place.x, y: (height - size.height) / 2, width: sign, height: size.height))
            callFromEnd = place.fromEnd
        }

        func put(_ view: NSView, width: CGFloat, height viewHeight: CGFloat? = nil, dy: CGFloat = 0) {
            let h = viewHeight ?? height
            view.kitSetFrame(NSRect(x: cursor, y: (height - h) / 2 + dy, width: width, height: h))
            cursor += width + SideLook.markGap
        }
        if editing {
            field?.kitSetFrame(NSRect(x: cursor, y: (height - 16) / 2, width: max(0, innerRight - cursor), height: 16))
            settleEnd(for: tab, room: nil)
        } else {
            if !blank.isHidden { put(blank, width: SideLook.rowMark) }
            if !mark.isHidden {
                put(mark, width: SideLook.rowMark, height: SideLook.rowMark)
                checks.kitSetFrame(ChecksMarkView.frame(on: mark.frame))
            }
            if let agentFace { put(agentFace, width: 14, height: 14) }
            if !flask.isHidden { put(flask, width: flask.intrinsicContentSize.width) }
            if !record.isHidden { put(record, width: record.intrinsicContentSize.width) }
            if let popupSign { put(popupSign, width: popupSign.fittingSize.width, height: popupSign.fittingSize.height) }
            if let translateSign { put(translateSign, width: translateSign.fittingSize.width, height: translateSign.fittingSize.height) }
            let titleWidth = max(0, innerRight - cursor)
            let lineHeight = SideLook.titleLine
            let bylineHeight = SideLook.bylineLine
            let stack = lineHeight + (byline.isHidden ? 0 : bylineHeight)
            let top = ((height - stack) / 2)
            title.kitSetFrame(NSRect(x: cursor, y: top, width: titleWidth, height: lineHeight))
            titleToEnd = width - (cursor + titleWidth)
            settleEnd(for: tab, room: RowTitleFade.reserve(closeFromEnd: [closeFromEnd, callFromEnd].compactMap { $0 }.max(), toEnd: titleToEnd))
            if !byline.isHidden {
                byline.kitSetFrame(NSRect(x: cursor, y: top + lineHeight, width: titleWidth, height: bylineHeight))
                byline.keep(title.reserve, sweeps: talkSlide != nil, after: talkSlide ?? 0)
            }
        }

        let zone = square + 2 * inset
        closeZone.kitSetFrame(NSRect(x: width - zone, y: 0, width: zone, height: height))
        closeSpot.kitSetFrame(NSRect(x: inset, y: inset, width: square, height: square))
        unseenDot.kitSetFrame(NSRect(x: width - inset - square + (square - 7) / 2, y: (height - 7) / 2, width: 7, height: 7))
        if let talk {
            let size = talk.intrinsicContentSize
            let wide = ceil(size.width)
            slide(talk, to: NSRect(x: TalkPlace.x(width: width, height: height, talk: wide, aside: talkAside),
                                   y: ((height - size.height) / 2).rounded(), width: wide, height: size.height))
        }
        talkSlide = nil
        _ = tab
    }

    private func slide(_ talk: TalkMarkView, to next: NSRect) {
        let old = talk.frame.minX
        guard let layer = talk.layer else {
            talk.kitSetFrame(next)
            return
        }
        let shown = layer.animation(forKey: Self.sliding) == nil ? 0 : (layer.presentation().map { $0.frame.minX - layer.frame.minX } ?? 0)
        talk.kitSetFrame(next)
        let moved = talk.frame.minX - old
        guard moved != 0 else { return }
        guard let wait = talkSlide, let move = Motion.kitQuick.animation("transform.translation.x", from: shown - moved, to: 0) as? CAPropertyAnimation else {
            layer.removeAnimation(forKey: Self.sliding)
            return
        }
        move.isAdditive = true
        layer.add(RowSweep.held(move, after: wait), forKey: Self.sliding)
    }

    private func settleSpeaker(for tab: Tab) {
        let id = ObjectIdentifier(tab)
        let sounding = tab.speaks || tab.muted
        let shown = speaker
        let turned = laidSpeaker.map { $0.tab == id && $0.sounding != sounding } ?? false
        laidSpeaker = (id, sounding)
        guard turned, shown == sounding, window != nil, Motion.kitSettle.animates else {
            if speakerLeaving, !shown, !turned { return }
            guard turned || speakerSpot.isHidden == shown else { return }
            restSpeaker(shown: shown)
            return
        }
        speakerTurn += 1
        speakerLeaving = !shown
        let turn = speakerTurn
        if let slide = Motion.kitSettle.animation("transform.translation.x", from: shown ? -SideLook.speakerRoom : SideLook.speakerRoom, to: 0) as? CAPropertyAnimation {
            slide.isAdditive = true
            content.layer?.add(slide, forKey: "speaker")
            if !shown {
                title.hold(against: slide)
                byline.hold(against: slide)
            }
        }
        if shown {
            speakerSpot.isHidden = false
            speakerSpot.alphaValue = 0
            speakerSpot.kitScale(SideLook.speakerFrom, curve: .none)
            speakerSpot.layer?.kitAnimate("opacity", to: Swift.Float(1), curve: Motion.kitQuick)
            speakerSpot.alphaValue = 1
            speakerSpot.kitScale(1, curve: Motion.kitSettle)
        } else {
            speakerSpot.layer?.kitAnimate("opacity", to: Swift.Float(0), curve: Motion.kitQuick)
            speakerSpot.alphaValue = 0
            speakerSpot.kitScale(SideLook.speakerFrom, curve: Motion.kitQuick)
            DispatchQueue.main.asyncAfter(deadline: .now() + SideLook.speakerLeave) { [weak self] in
                guard let self, speakerTurn == turn else { return }
                restSpeaker(shown: false)
            }
        }
    }

    private func restSpeaker(shown: Bool) {
        speakerTurn += 1
        speakerLeaving = false
        speakerSpot.layer?.removeAnimation(forKey: "opacity")
        speakerSpot.kitScale(1, curve: .none)
        speakerSpot.alphaValue = 1
        speakerSpot.isHidden = !shown
    }

    private func closeTapped() {
        if isHovering { pointerClose() }
    }

    func pointerClose() {
        browser?.hints.closedByPointer()
        close()
    }

    private func shake() {
        layer?.kitShake()
    }

    private func give(_ down: Bool) {
        let sink = RowRun.sink(pressed: down, gives: state.tabsGive, calm: Motion.calm)
        let curve = sink < 1 ? Motion.kitQuick : Motion.kitSettle
        face.kitScale(sink, curve: curve)
    }

    var pressLayers: (face: CALayer?, live: CALayer?, content: CALayer?) { (face.layer, liveGround.layer, content.layer) }

    override func mouseDown(with event: NSEvent) {
        guard state.interactive, let tab, let browser else { return }
        if host?.rowPressed(self, event: event) == true { return }
        pressedDown = true
        give(true)
        selectedOnPress = false
        let mods = event.modifierFlags
        guard !state.editing, mods.intersection([.command, .control, .shift]).isEmpty else { return }
        if mods.contains(.option), browser.opensBesideOnOptionClick(tab) { return }
        selectedOnPress = !state.live && browser.menuTabs(for: tab).count < 2
        TabPress.brought = selectedOnPress
        if selectedOnPress {
            pressedAt = CACurrentMediaTime()
            browser.clearTabSelection()
            browser.select(tab)
        }
    }

    func releasePress() {
        guard pressedDown else { return }
        give(false)
    }

    private func benchPress(_ down: Bool) {
        give(down)
    }

    override func mouseDragged(with event: NSEvent) {
        guard state.interactive else { return }
        host?.rowDragged(self, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard state.interactive, let tab, let browser else { return }
        give(false)
        let wasDown = pressedDown
        pressedDown = false
        if host?.rowReleased(self, event: event) == true {
            selectedOnPress = false
            return
        }
        guard wasDown, !state.editing else { return }
        let mods = event.modifierFlags
        if !mods.intersection([.command, .shift]).isEmpty {
            browser.extendTabSelection(to: tab, modifiers: mods)
            selectedOnPress = false
            return
        }
        defer { selectedOnPress = false }
        guard !selectedOnPress else { return }
        browser.clearTabSelection()
        if mods.contains(.option), !mods.contains(.control), browser.opensBesideOnOptionClick(tab) {
            browser.openInSplit(tab)
            return
        }
        if state.live {
            if !state.addressBar { browser.beginTabEdit(tab) }
        } else {
            browser.select(tab)
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, state.interactive, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.otherMouseUp(with: event)
        }
        pointerClose()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard state.interactive else { return nil }
        return host?.rowMenu(self, event: event)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let tab, let browser else { return false }
        browser.select(tab)
        return true
    }
}

@MainActor
enum RowSweep {
    static let wait: CFTimeInterval = 0.06
    static let back: CFTimeInterval = 0.09

    static func run(_ layer: CALayer, _ keyPath: String, to value: Any, after wait: CFTimeInterval) {
        let from = layer.animation(forKey: keyPath) == nil ? layer.value(forKeyPath: keyPath)
            : (layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(value, forKeyPath: keyPath)
        if let move = Motion.kitQuick.animation(keyPath, from: from, to: value) {
            layer.add(held(move, after: wait), forKey: keyPath)
        } else {
            layer.removeAnimation(forKey: keyPath)
        }
        CATransaction.commit()
    }

    static func held(_ animation: CAAnimation, after wait: CFTimeInterval) -> CAAnimation {
        guard wait > 0 else { return animation }
        animation.beginTime = wait
        animation.fillMode = .backwards
        let group = CAAnimationGroup()
        group.animations = [animation]
        group.duration = wait + animation.duration
        return group
    }
}

@MainActor
enum TalkPlace {
    static let gap: CGFloat = 3

    static func x(width: CGFloat, height: CGFloat, talk: CGFloat, aside: Bool) -> CGFloat {
        let square = Metrics.closeSquare(height)
        let inset = Metrics.closeInset(height)
        return aside ? width - inset - square - gap - talk : crossRight(width: width, height: height) - talk
    }

    static func fromEnd(height: CGFloat, talk: CGFloat, aside: Bool) -> CGFloat {
        -x(width: 0, height: height, talk: talk, aside: aside)
    }

    static func crossRight(width: CGFloat, height: CGFloat) -> CGFloat {
        let square = Metrics.closeSquare(height)
        let inset = Metrics.closeInset(height)
        return width - inset - square / 2 + CloseMarkView.ink(side: square) / 2
    }
}

enum RowTitleFade {
    static let width: CGFloat = 28
    static let lead: CFTimeInterval = 0.12

    static func reserve(closeFromEnd: CGFloat?, toEnd: CGFloat) -> CGFloat {
        guard let closeFromEnd, toEnd.isFinite else { return 0 }
        return max(0, closeFromEnd + 2 - toEnd)
    }

    static func fades(natural: CGFloat, room: CGFloat, reserve: CGFloat) -> Bool {
        natural > room - reserve + 0.5
    }

    static let callGap: CGFloat = 6

    static func call(width: CGFloat, sign: CGFloat, endsLeft: CGFloat?, markFromEnd: CGFloat?) -> (x: CGFloat, fromEnd: CGFloat?) {
        let right = min(endsLeft ?? width - 7, markFromEnd.map { width - $0 - 2 } ?? width)
        let x = right - sign
        return (x, sign > 0 ? width - x + callGap : nil)
    }

    static func counter(_ slide: CAPropertyAnimation) -> CAAnimation? {
        guard let counter = slide.copy() as? CABasicAnimation, let from = (counter.fromValue as? NSNumber)?.doubleValue else { return nil }
        counter.fromValue = -from
        counter.toValue = 0
        counter.isAdditive = true
        return counter
    }
}

extension RowJoin {
    static func corners(_ join: RowJoin) -> CACornerMask {
        var mask: CACornerMask = []
        if !join.above { mask.insert([.layerMinXMinYCorner, .layerMaxXMinYCorner]) }
        if !join.below { mask.insert([.layerMinXMaxYCorner, .layerMaxXMaxYCorner]) }
        return mask
    }
}

enum ColumnSpace {
    static func column(of view: NSView) -> NSView? {
        var at: NSView? = view
        while let current = at {
            if current is HoverColumnSpace { return current }
            at = current.superview
        }
        return nil
    }
}

extension SwitchFade {
    static let scale: CGFloat = 0.98
}

enum RowPress {
    static let window: CFTimeInterval = 0.12

    static func fade(from: Swift.Float, to: Swift.Float, duration: CFTimeInterval) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = to
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return fade
    }
}

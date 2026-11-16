import AppKit
import Combine

final class LiveGhostButton: KitButton {
    static let height: CGFloat = 22
    static let pad: CGFloat = 8
    static let crossPad: CGFloat = 4
    static let steps = 8

    private final class Well: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let strong: Bool
    let timed: Bool
    var ink: KitInk = .flat { didSet { if ink != oldValue { paintPill() } } }
    var folded = false {
        didSet {
            guard folded != oldValue else { return }
            padding = folded ? Self.crossPad : Self.pad
            content = folded ? cross : word
        }
    }
    private let word: KitLabel
    private let cross = KitSymbol("xmark", style: KitSymbol.Style(size: 9, weight: .semibold), tint: KitColor.muted)
    private let capsule = KitBox(fill: nil, corners: .capsule)
    private let well = Well()
    private let meter = CALayer()

    init(_ title: String, strong: Bool, timed: Bool = false, action: @escaping () -> Void) {
        self.strong = strong
        self.timed = timed
        word = KitLabel(title, font: .systemFont(ofSize: 11, weight: .medium))
        super.init(.plain(press: 0.96), label: title, action: action)
        addSubview(capsule, positioned: .below, relativeTo: nil)
        well.wantsLayer = true
        well.layer?.masksToBounds = true
        well.isHidden = !timed
        meter.anchorPoint = CGPoint(x: 0, y: 0.5)
        meter.transform = CATransform3DMakeScale(0.0001, 1, 1)
        well.layer?.addSublayer(meter)
        addSubview(well, positioned: .above, relativeTo: capsule)
        word.setAccessibilityElement(false)
        cross.setAccessibilityElement(false)
        content = word
        padding = Self.pad
        paintPill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var title: String { word.text }
    var shownFrame: NSRect { (folded ? cross : word).frame }

    func size(folded: Bool) -> NSSize {
        if folded { return NSSize(width: Self.height, height: Self.height) }
        return NSSize(width: (word.measure(width: .greatestFiniteMagnitude).width * 2).rounded(.up) / 2 + 2 * Self.pad, height: Self.height)
    }

    override var intrinsicContentSize: NSSize { size(folded: folded) }

    override var fittingSize: NSSize { intrinsicContentSize }

    var filled: Double {
        let shown = meter.presentation() ?? meter
        return ((shown.value(forKeyPath: "transform.scale.x") as? NSNumber)?.doubleValue ?? 0)
    }

    static func level(_ fill: Double) -> Double {
        (min(1, max(0, fill)) * Double(steps)).rounded(.down) / Double(steps)
    }

    func clock(fill: Double, left: TimeInterval?, stepped: Bool) {
        let from = min(1, max(0.0001, stepped ? Self.level(fill) : fill))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meter.removeAnimation(forKey: "clock")
        meter.transform = CATransform3DMakeScale(CGFloat(from), 1, 1)
        CATransaction.commit()
        guard let left, left > 0, fill < 1 else { return }
        if stepped {
            let first = Int((min(1, max(0, fill)) * Double(Self.steps)).rounded(.down))
            let levels = (first..<Self.steps).map { Double($0) / Double(Self.steps) }
            guard !levels.isEmpty else { return }
            let run = CAKeyframeAnimation(keyPath: "transform.scale.x")
            run.values = levels.map { max(0.0001, $0) }
            run.keyTimes = ([0] + levels.dropFirst().map { ($0 - fill) / (1 - fill) } + [1]).map { NSNumber(value: min(1, max(0, $0))) }
            run.calculationMode = .discrete
            run.duration = left
            run.fillMode = .forwards
            run.isRemovedOnCompletion = false
            meter.add(run, forKey: "clock")
            return
        }
        let run = CABasicAnimation(keyPath: "transform.scale.x")
        run.fromValue = from
        run.toValue = 1
        run.duration = left
        run.timingFunction = CAMediaTimingFunction(name: .linear)
        run.fillMode = .forwards
        run.isRemovedOnCompletion = false
        meter.add(run, forKey: "clock")
    }

    func stopClock() {
        let now = filled
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        meter.removeAnimation(forKey: "clock")
        meter.transform = CATransform3DMakeScale(CGFloat(max(0.0001, now)), 1, 1)
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        capsule.frame = bounds
        well.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        well.layer?.cornerRadius = bounds.height / 2
        meter.bounds = CGRect(origin: .zero, size: bounds.size)
        meter.position = CGPoint(x: 0, y: bounds.height / 2)
        CATransaction.commit()
    }

    override func hoverChanged() {
        super.hoverChanged()
        paintPill()
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        paintPill()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        paintPill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintPill()
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    private func paintPill() {
        let lit = hovering && isEnabled
        let dark = kitDark
        capsule.layer?.kitTransition(LiveSignInPill.curve)
        word.ink = ink
        cross.ink = ink
        word.color = strong || lit ? KitColor.ink : KitColor.muted
        cross.tint = lit ? KitColor.ink : KitColor.muted
        let rest: Double = strong ? 0.10 : 0
        let fill = pressed ? 0.20 : lit ? (strong ? 0.16 : 0.08) : rest
        capsule.fill = fill > 0 ? ink.color(KitColor.ink, .ink, opacity: fill, dark: dark) : nil
        guard timed else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        well.layer?.backgroundColor = ink.color(KitColor.ink, .ink, opacity: dark ? 0.05 : 0.04, dark: dark).cgColor
        meter.backgroundColor = ink.color(KitColor.ink, .ink, opacity: dark ? 0.16 : 0.12, dark: dark).cgColor
        CATransaction.commit()
    }
}

final class LiveGhostView: KitHoverView, SideGrounded {
    static let tall: CGFloat = 2 * Metrics.folderPad + GroupHeadingView.height
    static let trail: CGFloat = 6
    static let between: CGFloat = 2
    static let nameGap: CGFloat = 8
    static let line: CGFloat = 1.5
    static let dash: (on: CGFloat, off: CGFloat) = (6.5, 6.5)
    static let fade: CFTimeInterval = 0.2

    static func height(_ offer: LiveOffer, width: CGFloat) -> CGFloat { tall }

    static func dashes(along length: CGFloat) -> (on: CGFloat, off: CGFloat) {
        let period = dash.on + dash.off
        guard length > period else { return dash }
        let scale = length / ((length / period).rounded() * period)
        return (dash.on * scale, dash.off * scale)
    }

    static func nameRoom(width: CGFloat, from x: CGFloat, add: CGFloat, decline: CGFloat) -> CGFloat {
        width - trail - decline - between - add - nameGap - x
    }

    weak var browser: Browser?
    var ground = RowGround() { didSet { if ground != oldValue { paint() } } }
    var interactive = true { didSet { if interactive != oldValue { tune() } } }
    private(set) var offer: LiveOffer?
    private(set) var filling = false

    private let mark = FolderMarkView()
    private let name = KitLabel()
    private(set) lazy var add = LiveGhostButton(LiveOfferWords.addShort, strong: true) { [weak self] in self?.pressAdd() }
    private(set) lazy var decline = LiveGhostButton(LiveOfferWords.decline, strong: false, timed: true) { [weak self] in self?.pressDecline() }
    private let dashes = CAShapeLayer()
    private var watch: AnyCancellable?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        dashes.fillColor = nil
        dashes.lineWidth = Self.line
        dashes.lineCap = .round
        layer?.addSublayer(dashes)
        addSubview(mark)
        addSubview(name)
        addSubview(add)
        addSubview(decline)
        mark.open = 0
        mark.tone = KitTone.muted.opacity(SideLook.headingMarkTone)
        name.font = .systemFont(ofSize: 13, weight: SideLook.headingWeight)
        name.color = Palette.NS.inkStrong
        name.opacity = SideLook.headingName
        name.overflow = .tail
        name.lines = 1
        name.setAccessibilityElement(false)
        add.setAccessibilityIdentifier("live-ghost-add")
        decline.setAccessibilityIdentifier("live-ghost-decline")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("live-ghost")
        paint()
        watch = kitTrack { [weak self] in self?.sync() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let browser else { return }
        if window == nil { LiveOffers.shared.unwatch(self, in: browser) } else { LiveOffers.shared.watch(self, in: browser) }
    }

    func show(_ offer: LiveOffer) {
        guard offer != self.offer else { return }
        self.offer = offer
        name.text = offer.name
        toolTip = offer.gives
        setAccessibilityLabel("Suggested folder: \(offer.name)")
        setAccessibilityHelp(offer.gives)
        add.setAccessibilityLabel("\(LiveOfferWords.add): \(offer.name)")
        decline.setAccessibilityLabel("\(LiveOfferWords.decline): \(offer.name)")
        add.toolTip = "Adds \(offer.name) to this space's sidebar"
        decline.toolTip = "Broadway won't suggest it here again"
        add.setAccessibilityHelp(add.toolTip)
        decline.setAccessibilityHelp(decline.toolTip)
        needsLayout = true
        sync()
    }

    var inSight: Bool {
        guard interactive, !filling, window != nil, !isHiddenOrHasHiddenAncestor, alphaValue > 0, bounds.height > 0 else { return false }
        return visibleRect.height >= bounds.height / 2
    }

    var held: Bool {
        guard interactive, !filling else { return false }
        if hovering { return true }
        guard let first = window?.firstResponder as? NSView else { return false }
        return first === add || first === decline
    }

    var timeShare: Double { 1 - decline.filled }

    var nameFrame: NSRect { name.frame }

    private func pressAdd() {
        guard interactive, !filling, let browser, !browser.liveOfferMoving else { return }
        LiveOffers.shared.accept(browser)
    }

    private func pressDecline() {
        guard interactive, !filling, let browser, !browser.liveOfferMoving else { return }
        LiveOffers.shared.turnDown(browser)
    }

    override func hoverChanged() {
        guard interactive, let browser else { return }
        LiveOffers.shared.hold(browser)
    }

    private func tune() {
        inert = !interactive
        add.isEnabled = interactive
        decline.isEnabled = interactive
        add.alphaValue = 1
        decline.alphaValue = 1
        add.inert = !interactive
        decline.inert = !interactive
        setAccessibilityElement(interactive)
    }

    private func paint() {
        let dark = ground.dark
        let ink = ground.ink
        mark.ink = ink
        name.ink = ink
        add.ink = ink
        decline.ink = ink
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dashes.strokeColor = ink.color(KitColor.ink, .ink, opacity: dark ? 0.4 : 0.36, dark: dark).cgColor
        CATransaction.commit()
    }

    private func sync() {
        guard !filling, let browser, let shown = LiveOffers.shared.clock(for: browser) else { return }
        let now = LiveOffers.shared.now()
        let share = shown.share(at: now)
        let left = shown.remaining(at: now)
        let runs = interactive && shown.running && left > 0 && window != nil
        decline.clock(fill: 1 - share, left: runs ? left : nil, stepped: Motion.reduced)
    }

    func fill() {
        guard !filling else { return }
        filling = true
        inert = true
        add.isEnabled = false
        decline.isEnabled = false
        setAccessibilityElement(false)
        mark.isHidden = true
        name.isHidden = true
        decline.stopClock()
        guard let layer, window != nil, !Motion.reduced else {
            removeFromSuperview()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = 0
        fade.duration = Self.fade
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        layer.add(fade, forKey: "fill.opacity")
        CATransaction.commit()
    }

    private func outline(_ box: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r = min(radius, min(box.width, box.height) / 2)
        path.move(to: CGPoint(x: box.midX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX - r, y: box.minY))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX, y: box.minY + r), radius: r)
        path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - r))
        path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX - r, y: box.maxY), radius: r)
        path.addLine(to: CGPoint(x: box.minX + r, y: box.maxY))
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX, y: box.maxY - r), radius: r)
        path.addLine(to: CGPoint(x: box.minX, y: box.minY + r))
        path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX + r, y: box.minY), radius: r)
        path.closeSubpath()
        return path
    }

    override func layout() {
        super.layout()
        let pad = Metrics.folderPad
        let height = GroupHeadingView.height
        let lead = SideLook.rowLead - pad
        mark.kitSetFrame(NSRect(x: pad + lead + (SideLook.rowMark - 19) / 2, y: pad + (height - 15) / 2, width: 19, height: 15))
        let x = pad + lead + SideLook.rowMark + SideLook.markGap
        let wanted = ceil(name.intrinsicContentSize.width)
        let first = add.intrinsicContentSize
        let words = decline.size(folded: false)
        let fold = wanted > Self.nameRoom(width: bounds.width, from: x, add: first.width, decline: words.width)
        decline.folded = fold
        let second = decline.size(folded: fold)
        let room = max(0, Self.nameRoom(width: bounds.width, from: x, add: first.width, decline: second.width))
        let top = (bounds.height - LiveGhostButton.height) / 2
        decline.kitSetFrame(NSRect(x: bounds.width - Self.trail - second.width, y: top, width: second.width, height: second.height))
        add.kitSetFrame(NSRect(x: decline.frame.minX - Self.between - first.width, y: top, width: first.width, height: first.height))
        name.kitSetFrame(NSRect(x: x, y: pad + (height - 16) / 2, width: min(room, wanted), height: 16))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = bounds.insetBy(dx: Self.line / 2, dy: Self.line / 2)
        let radius = min(Metrics.sideRadius, min(box.width, box.height) / 2)
        let length = 2 * (box.width - 2 * radius) + 2 * (box.height - 2 * radius) + 2 * .pi * radius
        let fitted = Self.dashes(along: length)
        dashes.frame = bounds
        dashes.path = outline(box, radius: radius)
        dashes.lineDashPattern = [NSNumber(value: Double(fitted.on)), NSNumber(value: Double(fitted.off))]
        dashes.lineDashPhase = fitted.on / 2
        CATransaction.commit()
    }
}

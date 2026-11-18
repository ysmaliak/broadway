import AppKit
import QuartzCore

final class FolderGlyphView: NSView {
    static let size = CGSize(width: 19, height: 15)

    var open: CGFloat = 1 { didSet { if open != oldValue { reshape(from: oldValue) } } }
    var tone = KitTone.ink { didSet { if tone != oldValue { needsDisplay = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsDisplay = true } } }
    var curve: KitCurve = .none

    private let shape = CAShapeLayer()
    private let flap = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for (layer, width) in [(shape, Self.stroke), (flap, Self.flapWidth(open: open))] {
            layer.fillColor = nil
            layer.lineWidth = width
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.actions = ["path": NSNull(), "strokeColor": NSNull(), "bounds": NSNull(), "position": NSNull(), "lineWidth": NSNull()]
            self.layer?.addSublayer(layer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        let color = tone.resolved(ink, dark: kitDark).cgColor
        shape.strokeColor = color
        flap.strokeColor = color
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        flap.frame = bounds
        shape.path = Self.ring(open: open, in: bounds)
        flap.path = Self.flap(open: open, in: bounds)
        flap.lineWidth = Self.flapWidth(open: open, in: bounds)
        CATransaction.commit()
    }

    private struct Morph {
        let from: CGFloat
        let to: CGFloat
        let start: CFTimeInterval
        let curve: KitCurve
        let velocity: Double
    }

    private var morph: Morph?

    private func reshape(from old: CGFloat) {
        let now = CACurrentMediaTime()
        var shown = old
        var speed = 0.0
        if let morph {
            let elapsed = now - morph.start
            shown = morph.from + (morph.to - morph.from) * Self.progress(elapsed, curve: morph.curve, velocity: morph.velocity)
            speed = Double(morph.to - morph.from) * Self.rate(elapsed, curve: morph.curve, velocity: morph.velocity)
        }
        let velocity = abs(open - shown) > 0.0001 ? speed / Double(open - shown) : 0
        morph = nil
        shape.removeAnimation(forKey: "path")
        flap.removeAnimation(forKey: "path")
        flap.removeAnimation(forKey: "lineWidth")
        let duration = Self.duration(of: curve, velocity: velocity)
        if curve.animates, duration > 0, window != nil, bounds.width > 0, bounds.height > 0 {
            let steps = max(2, Int((duration * 120).rounded(.up)))
            let amounts = (0...steps).map { step in
                shown + (open - shown) * Self.progress(duration * Double(step) / Double(steps), curve: curve, velocity: velocity)
            }
            let box = bounds
            let tracks: [(CAShapeLayer, String, [Any])] = [
                (shape, "path", amounts.map { Self.ring(open: $0, in: box) }),
                (flap, "path", amounts.map { Self.flap(open: $0, in: box) }),
                (flap, "lineWidth", amounts.map { Self.flapWidth(open: $0, in: box) }),
            ]
            for (layer, key, values) in tracks {
                let keyframe = CAKeyframeAnimation(keyPath: key)
                keyframe.values = values
                keyframe.duration = duration
                keyframe.calculationMode = .linear
                keyframe.beginTime = layer.convertTime(now, from: nil)
                keyframe.fillMode = .backwards
                layer.add(keyframe, forKey: key)
            }
            morph = Morph(from: shown, to: open, start: now, curve: curve, velocity: velocity)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = Self.ring(open: open, in: bounds)
        flap.path = Self.flap(open: open, in: bounds)
        flap.lineWidth = Self.flapWidth(open: open, in: bounds)
        CATransaction.commit()
    }

    static func duration(of curve: KitCurve, velocity: Double = 0) -> CFTimeInterval {
        switch curve {
        case .none: return 0
        case .spring(let spring): return spring.animation("path", from: nil, to: nil, velocity: velocity).settlingDuration
        case .easeOut(let duration), .easeInOut(let duration): return duration
        }
    }

    static func progress(_ time: CFTimeInterval, curve: KitCurve, velocity: Double = 0) -> CGFloat {
        let duration = duration(of: curve, velocity: velocity)
        guard duration > 0, time < duration else { return 1 }
        guard time > 0 else { return 0 }
        switch curve {
        case .none:
            return 1
        case .spring(let spring):
            return CGFloat(spring.progress(time, velocity: velocity))
        case .easeOut:
            return bezier(time / duration, 0, 0, 0.58, 1)
        case .easeInOut:
            return bezier(time / duration, 0.42, 0, 0.58, 1)
        }
    }

    static func rate(_ time: CFTimeInterval, curve: KitCurve, velocity: Double = 0) -> Double {
        guard case .spring(let spring) = curve, time < duration(of: curve, velocity: velocity) else { return 0 }
        return spring.rate(time, velocity: velocity)
    }

    private static func bezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> CGFloat {
        func curve(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * a * t * (1 - t) * (1 - t) + 3 * b * t * t * (1 - t) + t * t * t }
        func slope(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * a * (1 - t) * (1 - t) + 6 * (b - a) * t * (1 - t) + 3 * (1 - b) * t * t }
        var t = x
        for _ in 0..<8 {
            let d = slope(t, x1, x2)
            guard abs(d) > 1e-6 else { break }
            t = min(1, max(0, t - (curve(t, x1, x2) - x) / d))
        }
        return CGFloat(curve(t, y1, y2))
    }

    struct Outline: Equatable {
        var backBottomLeft: CGPoint
        var backTopLeft: CGPoint
        var tabEnd: CGPoint
        var slopeEnd: CGPoint
        var backTopRight: CGPoint
        var wallEnd: CGPoint
        var lipRight: CGPoint
        var toe: CGPoint
        var flapEnd: CGPoint
        var lipLeft: CGPoint
        var flapFoot: CGPoint
    }

    static let stroke: CGFloat = 1.43
    static let barWidth: CGFloat = 1.08
    static let left: CGFloat = 2.41
    static let right: CGFloat = 15.91
    static let tabTop: CGFloat = 2.43
    static let bodyTop: CGFloat = 3.63
    static let bottom: CGFloat = 13.09
    static let tabEndX: CGFloat = 6.22
    static let slopeEndX: CGFloat = 7.47
    static let radius: CGFloat = 1.2
    static let tabRadius: CGFloat = 1.2
    static let slopeRadius: CGFloat = 1.36
    static let notchRadius: CGFloat = 0.5
    static let lipRadius: CGFloat = 1
    static let barY: CGFloat = 5.84
    static let barLeft: CGFloat = 3.89
    static let barRight: CGFloat = 14.44
    static let openLip: CGFloat = 7.59
    static let openInset: CGFloat = 4
    static let footOut: CGFloat = 2.5
    static let footDrop: CGFloat = 3
    static let reach: CGFloat = 1
    static let toeIn: CGFloat = 1.75

    static func outline(open: CGFloat, in rect: CGRect) -> Outline {
        let t = min(1, max(0, open))
        let sx = rect.width / size.width
        let sy = rect.height / size.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        let lip = mix(barY, openLip)
        let cap = barWidth / 2
        let lipLeft = mix(barLeft + cap, left + openInset)
        return Outline(
            backBottomLeft: p(left, bottom),
            backTopLeft: p(left, tabTop),
            tabEnd: p(tabEndX, tabTop),
            slopeEnd: p(slopeEndX, bodyTop),
            backTopRight: p(right, bodyTop),
            wallEnd: p(right, lip),
            lipRight: p(right + reach * t, lip),
            toe: p(right - toeIn * t, bottom),
            flapEnd: p(mix(barRight - cap, right), lip),
            lipLeft: p(lipLeft, lip),
            flapFoot: p(lipLeft - (openInset - footOut) * t, lip + footDrop * t))
    }

    static func flapWidth(open: CGFloat, in rect: CGRect = CGRect(origin: .zero, size: size)) -> CGFloat {
        let t = min(1, max(0, open))
        return (barWidth + (stroke - barWidth) * t) * min(rect.width / size.width, rect.height / size.height)
    }

    static func ring(open: CGFloat, in rect: CGRect) -> CGPath {
        let o = outline(open: open, in: rect)
        let scale = min(rect.width / size.width, rect.height / size.height)
        let path = CGMutablePath()
        func corner(_ from: CGPoint, _ at: CGPoint, _ to: CGPoint, radius: CGFloat) {
            let a = CGPoint(x: from.x - at.x, y: from.y - at.y)
            let b = CGPoint(x: to.x - at.x, y: to.y - at.y)
            let la = max(hypot(a.x, a.y), 0.0001)
            let lb = max(hypot(b.x, b.y), 0.0001)
            let ua = CGPoint(x: a.x / la, y: a.y / la)
            let ub = CGPoint(x: b.x / lb, y: b.y / lb)
            let sweep = CGFloat.pi - acos(min(1, max(-1, ua.x * ub.x + ua.y * ub.y)))
            let reach = sweep < 0.0001 ? 0 : min(radius * tan(sweep / 2), la / 2, lb / 2)
            let handle = sweep < 0.0001 ? 0 : reach * 4 / 3 * tan(sweep / 4) / tan(sweep / 2)
            let start = CGPoint(x: at.x + ua.x * reach, y: at.y + ua.y * reach)
            let end = CGPoint(x: at.x + ub.x * reach, y: at.y + ub.y * reach)
            path.addLine(to: start)
            path.addCurve(to: end, control1: CGPoint(x: start.x - ua.x * handle, y: start.y - ua.y * handle),
                          control2: CGPoint(x: end.x - ub.x * handle, y: end.y - ub.y * handle))
        }
        let ring: [(CGPoint, CGFloat)] = [
            (o.backBottomLeft, radius), (o.backTopLeft, radius), (o.tabEnd, tabRadius), (o.slopeEnd, slopeRadius),
            (o.backTopRight, radius), (o.wallEnd, notchRadius), (o.lipRight, lipRadius), (o.toe, radius)]
        let bottomMiddle = CGPoint(x: (o.backBottomLeft.x + o.toe.x) / 2, y: o.backBottomLeft.y)
        path.move(to: bottomMiddle)
        for (index, (at, round)) in ring.enumerated() {
            corner(ring[(index + ring.count - 1) % ring.count].0, at, ring[(index + 1) % ring.count].0, radius: round * scale)
        }
        path.addLine(to: bottomMiddle)
        path.closeSubpath()
        return path
    }

    static func flap(open: CGFloat, in rect: CGRect) -> CGPath {
        let o = outline(open: open, in: rect)
        let path = CGMutablePath()
        path.move(to: o.flapEnd)
        path.addLine(to: o.lipLeft)
        path.addLine(to: o.flapFoot)
        return path
    }

    static func path(open: CGFloat, in rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addPath(ring(open: open, in: rect))
        path.addPath(flap(open: open, in: rect))
        return path
    }
}

final class FolderMarkView: NSView {
    var icon: NSImage? { didSet { if icon !== oldValue { swapKind() } } }
    var open: CGFloat {
        get { glyph.open }
        set { glyph.open = newValue }
    }
    var curve: KitCurve {
        get { glyph.curve }
        set { glyph.curve = newValue }
    }
    var tone: KitTone {
        get { glyph.tone }
        set { glyph.tone = newValue }
    }
    var ink: KitInk = .flat { didSet { glyph.ink = ink; mark.ink = ink } }

    private let glyph = FolderGlyphView()
    private let mark = RowMarkView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(glyph)
        addSubview(mark)
        mark.size = 15
        swapKind()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { FolderGlyphView.size }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func swapKind() {
        mark.isHidden = icon == nil
        glyph.isHidden = icon != nil
        mark.icon = icon
        mark.letter = ""
    }

    override func layout() {
        super.layout()
        glyph.kitSetFrame(bounds)
        mark.kitSetFrame(NSRect(x: (bounds.width - 15) / 2, y: 0, width: 15, height: 15))
    }
}

final class StackFoldButton: KitButton {
    static let width: CGFloat = 14
    static let chip: CGFloat = 12
    static let turn = KitSpring(response: 0.3, damping: 0.72)

    static func frame(row: NSRect) -> NSRect {
        let side = SideLook.rowMark
        let corner = CGPoint(x: row.minX + TabRowView.iconLead + 1, y: row.midY - side / 2 + 1)
        return NSRect(x: corner.x - width / 2, y: corner.y - width / 2, width: width, height: width)
    }

    struct Dress {
        var folded: Bool
        var action: () -> Void
    }

    static func on(_ row: NSView) -> StackFoldButton? {
        row.subviews.lazy.compactMap { $0 as? StackFoldButton }.first
    }

    static func dress(_ row: NSView, _ dress: Dress?, lit: Bool, fades: Bool) {
        guard let dress else {
            on(row)?.leave(fades: fades)
            return
        }
        let found = on(row)
        let chip = found ?? StackFoldButton()
        if chip.superview !== row || row.subviews.last !== chip { row.addSubview(chip) }
        chip.stay(arriving: found == nil && fades && row.window != nil)
        chip.frame = frame(row: row.bounds)
        chip.folded = dress.folded
        chip.lit = lit
        chip.action = dress.action
    }

    private var leaving = false

    private func stay(arriving: Bool) {
        guard let layer else { return }
        if leaving {
            leaving = false
            let shown = (layer.presentation() ?? layer).opacity
            layer.removeAnimation(forKey: "chip.opacity")
            fade(from: shown, to: 1)
            setAccessibilityElement(true)
        } else if arriving {
            fade(from: 0, to: 1)
        }
    }

    private func leave(fades: Bool) {
        guard !leaving else { return }
        guard fades, window != nil, let layer else {
            removeFromSuperview()
            return
        }
        leaving = true
        setAccessibilityElement(false)
        let shown = (layer.presentation() ?? layer).opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.leaving else { return }
            self.leaving = false
            self.removeFromSuperview()
            self.layer?.removeAnimation(forKey: "chip.opacity")
        }
        fade(from: shown, to: 0)
        CATransaction.commit()
    }

    private func fade(from: Swift.Float, to: Swift.Float) {
        guard let layer, from != to, let fade = Motion.kitQuick.animation("opacity", from: from, to: to) else { return }
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = to == 1
        layer.add(fade, forKey: "chip.opacity")
    }

    var folded = false { didSet { if folded != oldValue { turn(animated: true); speak() } } }

    private let plate = CALayer()
    private let arrow = CAShapeLayer()
    private(set) var tint = Palette.NS.muted

    init() {
        super.init(.plain(press: 0.85))
        wantsLayer = true
        plate.cornerRadius = StackFoldButton.chip / 2
        plate.shadowOpacity = 0.25
        plate.shadowRadius = 1.5
        plate.shadowOffset = CGSize(width: 0, height: 0.5)
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "backgroundColor": NSNull(), "borderColor": NSNull(),
                                          "strokeColor": NSNull(), "transform": NSNull(), "path": NSNull()]
        plate.actions = still
        arrow.actions = still
        arrow.fillColor = nil
        arrow.lineWidth = 1.3
        arrow.lineCap = .round
        arrow.lineJoin = .round
        let side = StackFoldButton.chip
        let path = CGMutablePath()
        path.move(to: CGPoint(x: side / 2 - 1.2, y: side / 2 - 2.6))
        path.addLine(to: CGPoint(x: side / 2 + 1.4, y: side / 2))
        path.addLine(to: CGPoint(x: side / 2 - 1.2, y: side / 2 + 2.6))
        arrow.path = path
        arrow.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        layer?.addSublayer(plate)
        layer?.addSublayer(arrow)
        turn(animated: false)
        speak()
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }

    var angle: CGFloat { folded ? 0 : .pi / 2 }

    override func layout() {
        super.layout()
        let side = StackFoldButton.chip
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        arrow.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func drawFocusRingMask() {
        let side = min(bounds.width, bounds.height)
        let square = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        NSBezierPath(roundedRect: square, xRadius: side / 2, yRadius: side / 2).fill()
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { action?() } else { super.keyDown(with: event) }
    }

    var lit = false { didSet { if lit != oldValue { paint() } } }

    override func hoverChanged() {
        super.hoverChanged()
        paint()
    }

    private func paint() {
        let dark = kitDark
        tint = hovering || lit ? Palette.NS.ink : Palette.NS.muted
        var stroke = tint.cgColor
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? effectiveAppearance).performAsCurrentDrawingAppearance { stroke = tint.cgColor }
        arrow.strokeColor = stroke
        plate.backgroundColor = NSColor(white: dark ? (hovering ? 0.34 : 0.26) : (hovering ? 0.94 : 1), alpha: 1).cgColor
        plate.borderWidth = 0.5
        plate.borderColor = NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.12).cgColor
        plate.shadowColor = NSColor.black.cgColor
    }

    private func speak() {
        setAccessibilityLabel(folded ? "Unfold Stack" : "Fold Stack")
    }

    private func turn(animated: Bool) {
        let path = "transform.rotation.z"
        let shown = (arrow.presentation()?.value(forKeyPath: path) as? CGFloat) ?? (arrow.value(forKeyPath: path) as? CGFloat) ?? 0
        arrow.setValue(angle, forKeyPath: path)
        guard animated, !Motion.reduced, window != nil else {
            arrow.removeAnimation(forKey: "turn")
            return
        }
        arrow.add(StackFoldButton.turn.animation(path, from: shown, to: angle), forKey: "turn")
    }
}

final class FolderEditField: NSTextField, NSTextFieldDelegate {
    static let textInset: CGFloat = 2
    static let line: CGFloat = 17

    var commit: (String) -> Void = { _ in }
    var cancel: () -> Void = {}
    private var done = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = .systemFont(ofSize: 13, weight: SideLook.headingWeight)
        textColor = Palette.NS.inkStrong
        placeholderString = "Folder name"
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        lineBreakMode = .byClipping
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func begin(_ name: String) {
        done = false
        stringValue = name
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finish(commit: true)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finish(commit: false)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        finish(commit: true)
    }

    private func finish(commit: Bool) {
        guard !done else { return }
        done = true
        if commit { self.commit(stringValue) } else { cancel() }
    }
}

final class GroupHeadingView: KitHoverView {
    static let height: CGFloat = SideLook.headingHeight
    static let indent: CGFloat = 16
    static var closeInset: CGFloat { (height - Metrics.closeSquare(height)) / 2 }
    static let nameLine: CGFloat = 16

    static func inset(depth: Int) -> CGFloat { FolderHeadingMetrics.inset(depth: depth) }

    static func markLead(depth: Int) -> CGFloat {
        inset(depth: depth) + SideLook.rowLead - (depth == 0 ? Metrics.folderPad : 0)
    }

    static func nameLead(depth: Int) -> CGFloat { markLead(depth: depth) + SideLook.rowMark + SideLook.markGap }

    static func fieldFrame(nameLead: CGFloat, right: CGFloat) -> NSRect {
        let x = nameLead - FolderEditField.textInset
        return NSRect(x: x, y: (height - nameLine) / 2, width: max(0, right - x), height: FolderEditField.line)
    }

    private(set) weak var browser: Browser?
    private(set) var group: TabGroup?
    var depth = 0 { didSet { if depth != oldValue { needsLayout = true } } }
    var progress: CGFloat = 1 { didSet { if progress != oldValue { progressChanged() } } }
    var number: Int? { didSet { if number != oldValue { needsLayout = true } } }
    var count = 0 { didSet { if count != oldValue { tally.text = "\(count)"; needsLayout = true } } }
    var greys = KitGreys.white { didSet { if greys != oldValue { paint() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { applyInk() } } }
    var dropping = false { didSet { if dropping != oldValue { paint() } } }
    var interactive = true
    var hoverCards = true
    var curve: KitCurve = .none
    weak var host: GroupHeadingHost?

    private let ground = KitPlate(radius: SideLook.cardRowRadius)
    private let well = KitPlate(radius: SideLook.fieldRadius)
    private var chevronUnderClose = false
    var flat = false { didSet { if flat != oldValue { paint() } } }
    private let mark = FolderMarkView()
    private let name = KitLabel()
    private let chevron = KitSymbol("chevron.right", style: KitSymbol.Style(size: SideLook.chevron, weight: .semibold), tint: Palette.NS.muted)
    private lazy var chevronTurn = KitTurnView(chevron)
    private let close = CloseSpotView()
    let chipFold = KitFlippedView()
    private var chipShown: Swift.Float = 0
    private let chip = KitBox(fill: KitColor.ink.withAlphaComponent(0.07), corners: .capsule)
    private let tally = KitLabel("", font: .monospacedDigitSystemFont(ofSize: 11, weight: .medium), color: KitColor.muted)
    var showsCount: Bool { count > 0 && group?.collapsed == true && !editing && !asksSignIn }
    private var asksSignIn: Bool { (status as? LiveStatusView)?.asks == true }
    private var askedBefore = false
    private var field: FolderEditField?
    private(set) var status: NSView?
    private var shortcut: ShortcutNumberView?
    private var down: NSPoint?
    private let veil = GroupNameVeil()
    let nameHost = GroupNameHost()
    private(set) var veiled = false
    private var revealing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(ground)
        addSubview(well)
        well.hairline = true
        well.isHidden = true
        addSubview(mark)
        addSubview(nameHost)
        nameHost.addSubview(name)
        addSubview(veil)
        veil.isHidden = true
        addSubview(chevronTurn)
        addSubview(chipFold)
        chipFold.wantsLayer = true
        chipFold.layer?.opacity = 0
        chipFold.isHidden = true
        chipFold.addSubview(chip)
        chip.addSubview(tally)
        tally.setAccessibilityElement(false)
        addSubview(close)
        name.font = .systemFont(ofSize: 13, weight: SideLook.headingWeight)
        name.color = Palette.NS.inkStrong
        name.opacity = SideLook.headingName
        chevron.opacity = SideLook.chevronTone
        mark.tone = KitTone.muted.opacity(SideLook.headingMarkTone)
        name.overflow = .tail
        name.lines = 1
        name.setAccessibilityElement(false)
        chevron.setAccessibilityElement(false)
        chevronTurn.turn(to: CGFloat.pi / 2 * progress, curve: .none)
        close.label = "Close Folder"
        close.isHidden = true
        close.act = { [weak self] in
            guard let self, let browser = self.browser, let group = self.group else { return }
            browser.closeTabGroupAsking(group.id)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        registerForDraggedTypes([InternalDrag.folderPasteboard])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ group: TabGroup, in browser: Browser) {
        let was = self.group?.id == group.id && veiled
        self.browser = browser
        self.group = group
        let veils = AIGroups.shared.veils(group, in: browser)
        veiled = veils
        mark.icon = veils ? nil : group.icon?.image
        name.text = group.name
        setAccessibilityLabel(veils ? GroupNameReveal.spoken : group.name)
        setAccessibilityValue(group.collapsed ? "Shut" : "Open")
        if group.live {
            let made = status ?? SideSigns.liveStatus(browser: browser, id: group.id, collapsed: group.collapsed)
            if status == nil { addSubview(made); status = made }
            SideSigns.update(liveStatus: made, collapsed: group.collapsed)
            groundStatus()
        } else if let made = status {
            made.removeFromSuperview()
            status = nil
        }
        let editing = browser.editingGroupID == group.id
        if editing, field == nil {
            let made = FolderEditField()
            let opened = group.name
            made.commit = { [weak self] text in
                guard let self, let browser = self.browser, let group = self.group else { return }
                browser.commitFolderName(group.id, typed: text, opened: opened)
            }
            made.cancel = { [weak self] in self?.browser?.editingGroupID = nil }
            addSubview(made)
            field = made
            made.begin(group.name)
        } else if !editing, let made = field {
            made.removeFromSuperview()
            field = nil
        }
        if veils {
            dropReveal()
            revealing = false
            mark.alphaValue = GroupNameReveal.markRest
            nameHost.alphaValue = 0
            veil.isHidden = false
        } else if was, !editing, window != nil, Motion.kitSettle.animates {
            reveal(emoji: group.icon?.emoji != nil)
        } else if was || (!revealing && !veil.isHidden) {
            dropReveal()
            revealing = false
            mark.alphaValue = 1
            nameHost.alphaValue = 1
            veil.isHidden = true
        }
        paint()
        needsLayout = true
    }

    private func dropReveal() {
        veil.layer?.removeAnimation(forKey: "reveal.fade")
        nameHost.layer?.removeAnimation(forKey: "reveal.opacity")
        nameHost.layer?.removeAnimation(forKey: "reveal.rise")
        nameHost.layer?.mask = nil
        mark.layer?.removeAnimation(forKey: "reveal.mark")
    }

    private func reveal(emoji: Bool) {
        dropReveal()
        revealing = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        let now = CACurrentMediaTime()
        veil.alphaValue = 1
        veil.isHidden = false
        if let layer = veil.layer, let fade = KitCurve.easeOut(GroupNameReveal.barFade).animation("opacity", from: 1, to: 0) {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.revealing else { return }
                self.revealing = false
                self.veil.isHidden = true
                self.veil.alphaValue = 1
            }
            veil.alphaValue = 0
            layer.add(fade, forKey: "reveal.fade")
            CATransaction.commit()
        }
        nameHost.alphaValue = 1
        if let layer = nameHost.layer {
            let curve = Motion.kitSettle
            if let fade = curve.animation("opacity", from: 0, to: 1) { layer.add(fade, forKey: "reveal.opacity") }
            let low = NSValue(caTransform3D: CATransform3DMakeTranslation(0, GroupNameReveal.rise, 0))
            if let rise = curve.animation("transform", from: low, to: NSValue(caTransform3D: CATransform3DIdentity)) {
                layer.add(rise, forKey: "reveal.rise")
            }
            let mask = CAGradientLayer()
            mask.frame = layer.bounds.insetBy(dx: 0, dy: -GroupNameReveal.rise)
            mask.startPoint = CGPoint(x: 0, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 0.5)
            mask.colors = [NSColor.black.cgColor, NSColor.clear.cgColor]
            let edge = GroupNameReveal.wipeEdge
            mask.locations = [1, NSNumber(value: 1 + edge)]
            let wipe = CABasicAnimation(keyPath: "locations")
            wipe.fromValue = [NSNumber(value: -edge), 0]
            wipe.toValue = [1, NSNumber(value: 1 + edge)]
            wipe.duration = GroupNameReveal.wipe
            wipe.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak layer, weak mask] in
                guard let layer, let mask, layer.mask === mask else { return }
                layer.mask = nil
            }
            layer.mask = mask
            mask.add(wipe, forKey: "reveal.wipe")
            CATransaction.commit()
        }
        mark.alphaValue = 1
        guard let layer = mark.layer else { return }
        if emoji {
            let middle = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            var small = CATransform3DMakeTranslation(middle.x, middle.y, 0)
            small = CATransform3DScale(small, KitSwap.small, KitSwap.small, 1)
            small = CATransform3DTranslate(small, -middle.x, -middle.y, 0)
            let pop = CAAnimationGroup()
            let spring = KitSwap.spring.animation("transform", from: NSValue(caTransform3D: small), to: NSValue(caTransform3D: CATransform3DIdentity))
            pop.animations = [spring, KitCurve.easeOut(KitSwap.fade).animation("opacity", from: 0, to: 1)].compactMap { $0 }
            pop.duration = spring.duration
            pop.beginTime = now + GroupNameReveal.emojiLag
            pop.fillMode = .backwards
            layer.add(pop, forKey: "reveal.mark")
        } else if let lift = Motion.kitQuick.animation("opacity", from: GroupNameReveal.markRest, to: 1) {
            layer.add(lift, forKey: "reveal.mark")
        }
    }

    private var editing: Bool { field != nil }

    var benchParts: [String: NSView] {
        var parts: [String: NSView] = ["mark": mark, "nameHost": nameHost, "chevron": chevronTurn, "chip": chipFold, "ground": ground,
                                       "well": well, "close": close]
        if let field { parts["field"] = field }
        if let status { parts["status"] = status }
        return parts
    }

    var benchNameWidth: CGFloat { ceil(name.intrinsicContentSize.width) }

    private var closes: Bool {
        guard let browser, let group else { return false }
        return !editing && hovering && interactive && !group.live && !FolderTree.raised(group.id, in: browser.tabGroups)
    }

    override func hoverChanged() {
        paint()
        needsLayout = true
        guard let browser, let group else { return }
        if hovering, group.collapsed, !editing, hoverCards, interactive {
            browser.hoverCards.enter(.folder(group.id), frame: cardSpot())
        } else {
            browser.hoverCards.leave(.folder(group.id))
        }
    }

    func cardSpot() -> CGRect {
        guard let window, let content = window.contentView else { return .zero }
        let row = convert(bounds, to: nil)
        let top = content.bounds.height
        let column = ColumnSpace.column(of: self).map { $0.convert($0.bounds, to: nil) } ?? row
        return CGRect(x: column.minX, y: top - row.maxY, width: column.width, height: row.height)
    }

    private func groundStatus() {
        (status as? SideGrounded)?.ground = RowGround(greys: greys, ink: ink, dark: kitDark)
    }

    private func applyInk() {
        groundStatus()
        ground.ink = ink
        mark.ink = ink
        name.ink = ink
        veil.ink = ink
        chevron.ink = ink
        close.ink = ink
        shortcut?.ink = ink
        tally.ink = ink
        chip.fill = ink.color(KitColor.ink, .ink, opacity: 0.07, dark: kitDark)
    }

    private func paint() {
        groundStatus()
        ground.fill = dropping ? greys.wash : flat || editing ? nil : hovering && interactive ? greys.hover : nil
        well.isHidden = !editing
        if editing {
            well.fill = kitDark ? greys.well.opacity(SideLook.fieldWell) : greys.well
            well.stroke = greys.cardEdge
            well.ink = ink
        }
        let closes = self.closes
        if close.isHidden == closes {
            if Motion.kitQuick.animates { close.layer?.kitTransition(Motion.kitQuick) }
            close.isHidden = !closes
        }
        close.armed = closes
        chevronTurn.alphaValue = closes && chevronUnderClose ? 0 : 1
        shortcut?.alphaValue = closes ? 0 : 1
        chip.alphaValue = closes ? 0 : 1
    }

    private func foldChip(_ shows: Bool, curve: KitCurve) {
        let target: Swift.Float = shows ? 1 : 0
        guard target != chipShown, let layer = chipFold.layer else { return }
        chipShown = target
        let wasHidden = chipFold.isHidden
        chipFold.isHidden = false
        let from = wasHidden ? Swift.Float(0) : (layer.presentation()?.opacity ?? layer.opacity)
        let carry = layer.kitCarry("fold.opacity", from: NSNumber(value: from), to: NSNumber(value: target))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "fold.opacity")
        guard window != nil, let fade = curve.animation("opacity", from: from, to: target, velocity: carry) else { return }
        fade.fillMode = .backwards
        layer.add(fade, forKey: "fold.opacity")
    }

    private func progressChanged() {
        mark.curve = curve
        mark.open = progress
        chevronTurn.turn(to: CGFloat.pi / 2 * progress, curve: curve)
    }

    override func layout() {
        super.layout()
        guard let group else { return }
        let indent = Self.inset(depth: depth)
        let height = Self.height
        let box = NSRect(x: indent, y: 0, width: max(0, bounds.width - indent), height: height)
        ground.kitSetFrame(box)
        let glyph = FolderGlyphView.size
        mark.kitSetFrame(NSRect(x: Self.markLead(depth: depth) + (SideLook.rowMark - glyph.width) / 2, y: (height - glyph.height) / 2,
                                width: glyph.width, height: glyph.height))
        var x = Self.nameLead(depth: depth)
        var right = box.maxX - 10
        let showsChevron = !editing
        chevronTurn.isHidden = !showsChevron
        let chevronSize = chevron.intrinsicContentSize
        if showsChevron, !SideLook.chevronInline {
            chevronTurn.kitSetFrame(NSRect(x: right - chevronSize.width, y: (height - chevronSize.height) / 2,
                                           width: chevronSize.width, height: chevronSize.height))
            right -= chevronSize.width + 9
        }
        if !editing, group.collapsed, let number {
            let made = shortcut ?? ShortcutNumberView(number: number)
            if shortcut == nil { addSubview(made); shortcut = made; made.ink = ink }
            made.number = number
            let side = ShortcutNumberView.side
            made.kitSetFrame(NSRect(x: right - side, y: (height - side) / 2, width: side, height: side))
            right -= side + 9
        } else if let made = shortcut {
            made.removeFromSuperview()
            shortcut = nil
        }
        if showsCount {
            let words = tally.intrinsicContentSize
            let width = words.width + 12
            chipFold.kitSetFrame(NSRect(x: right - width, y: (height - 17) / 2, width: width, height: 17))
            chip.kitSetFrame(chipFold.bounds)
            tally.kitSetFrame(NSRect(x: 6, y: (17 - words.height) / 2, width: words.width, height: words.height))
            right -= width + 9
        }
        let asks = asksSignIn
        foldChip(showsCount, curve: asks != askedBefore && !curve.animates ? Motion.kitQuick : curve)
        askedBefore = asks
        if let status, !editing {
            let inline = showsChevron && SideLook.chevronInline ? chevronSize.width + SideLook.chevronGap : 0
            if asks, let live = status as? LiveStatusView, let asked = live.asked {
                let want = min(ceil(name.intrinsicContentSize.width), SideLook.headingNameRoom)
                live.short = right - LiveSignInPill.size(asked).width - 9 - x - inline < want
            }
            let size = status.fittingSize
            let nameRoom = right - size.width - 9 - x - inline
            status.isHidden = !asks && size.width > 0 && nameRoom < SideLook.headingNameRoom
            if size.width > 0, !status.isHidden {
                status.kitSetFrame(NSRect(x: right - size.width, y: (height - size.height) / 2, width: size.width, height: size.height))
                right -= size.width + 9
            }
        } else {
            status?.isHidden = true
        }
        nameHost.isHidden = editing
        if editing { veil.isHidden = true }
        let barHeight = GroupNameReveal.barHeight
        if showsChevron, SideLook.chevronInline {
            let room = max(0, right - x - chevronSize.width - SideLook.chevronGap)
            let width = min(room, ceil(name.intrinsicContentSize.width))
            let bar = GroupNameReveal.width(for: group.id, room: room)
            nameHost.kitSetFrame(NSRect(x: x, y: (height - Self.nameLine) / 2, width: width, height: Self.nameLine))
            name.kitSetFrame(nameHost.bounds)
            veil.kitSetFrame(NSRect(x: x, y: (height - barHeight) / 2, width: bar, height: barHeight))
            chevronTurn.kitSetFrame(NSRect(x: x + (veiled ? bar : width) + SideLook.chevronGap, y: (height - chevronSize.height) / 2,
                                           width: chevronSize.width, height: chevronSize.height))
        } else {
            let room = max(0, right - x)
            nameHost.kitSetFrame(NSRect(x: x, y: (height - Self.nameLine) / 2, width: room, height: Self.nameLine))
            name.kitSetFrame(nameHost.bounds)
            veil.kitSetFrame(NSRect(x: x, y: (height - barHeight) / 2, width: GroupNameReveal.width(for: group.id, room: room),
                                    height: barHeight))
        }
        field?.kitSetFrame(Self.fieldFrame(nameLead: x, right: box.maxX - 10))
        let inset = SideLook.fieldInset
        well.kitSetFrame(NSRect(x: x - SideLook.fieldLead, y: inset, width: max(0, box.maxX - inset - x + SideLook.fieldLead),
                                height: height - 2 * inset))
        let square = Metrics.closeSquare(height)
        close.side = square
        close.kitSetFrame(NSRect(x: box.maxX - Self.closeInset - square, y: (height - square) / 2, width: square, height: square))
        chevronUnderClose = chevronTurn.frame.maxX > close.frame.minX - 2
        paint()
    }

    override func mouseDown(with event: NSEvent) {
        guard interactive, !editing else { return }
        down = event.locationInWindow
        host?.headingPressed(self, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactive, !editing else { return }
        if let host {
            host.headingDragged(self, event: event)
            return
        }
        guard let start = down, let group, hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        down = nil
        let item = NSPasteboardItem()
        item.setString(group.id.uuidString, forType: InternalDrag.folderPasteboard)
        let drag = NSDraggingItem(pasteboardWriter: item)
        drag.setDraggingFrame(bounds, contents: snapshot())
        beginDraggingSession(with: [drag], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    private let spring = FolderSpring()

    private func aim(_ info: NSDraggingInfo) -> NSDragOperation {
        guard let group, let id = InternalDrag.folderID(info.draggingPasteboard), id != group.id else {
            dropping = false
            return []
        }
        dropping = true
        spring.over(group.collapsed ? group.id : nil) { [weak browser] in browser?.unfoldFolder($0) }
        return .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { aim(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { aim(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropping = false
        spring.over(nil) { _ in }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        spring.over(nil) { _ in }
        guard let browser, let group, let id = InternalDrag.folderID(sender.draggingPasteboard), id != group.id else { return false }
        let inside = FolderHeadingMetrics.inside(x: convert(sender.draggingLocation, from: nil).x, depth: depth)
        browser.dropFolder(id, on: group.id, inside: inside)
        return true
    }

    override func mouseUp(with event: NSEvent) {
        guard interactive, !editing, let browser, let group, down != nil else { return }
        down = nil
        if host?.headingReleased(self, event: event) == true { return }
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        if event.modifierFlags.contains(.option) {
            browser.toggleFolderWhole(group.id)
        } else if event.clickCount == 2, onName(convert(event.locationInWindow, from: nil)) {
            browser.toggleTabGroup(group.id)
            browser.editingGroupID = group.id
        } else {
            browser.toggleTabGroup(group.id)
        }
    }

    func onName(_ point: NSPoint) -> Bool {
        let shown = veiled ? veil.frame : nameHost.frame
        let width = veiled ? shown.width : min(shown.width, ceil(name.intrinsicContentSize.width))
        return point.x >= shown.minX - 2 && point.x <= shown.minX + width + 2
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard interactive, let browser, let group else { return nil }
        return FolderMenus.menu(browser: browser, group: group)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let browser, let group else { return false }
        browser.toggleTabGroup(group.id)
        return true
    }
}

@MainActor protocol GroupHeadingHost: AnyObject {
    func headingPressed(_ heading: NSView, event: NSEvent)
    func headingDragged(_ heading: NSView, event: NSEvent)
    func headingReleased(_ heading: NSView, event: NSEvent) -> Bool
}

final class TaskFolderHeadingView: KitHoverView {
    private(set) weak var browser: Browser?
    private(set) var folder: TaskFolder?
    var progress: CGFloat = 1 { didSet { mark.open = progress } }
    var curve: KitCurve {
        get { mark.curve }
        set { mark.curve = newValue }
    }
    var ink: KitInk = .flat { didSet { mark.ink = ink; name.ink = ink; needs.ink = ink } }

    private let mark = FolderGlyphView()
    private let name = KitLabel()
    private let needs = KitLabel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(mark)
        addSubview(name)
        addSubview(needs)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.overflow = .tail
        name.lines = 1
        needs.font = .systemFont(ofSize: 11, weight: .medium)
        needs.color = Palette.NS.unsafe
        needs.text = "Needs you"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func show(_ folder: TaskFolder, in browser: Browser) {
        self.folder = folder
        self.browser = browser
        name.text = folder.name
        needs.isHidden = !folder.needsYou
        toolTip = folder.name
        setAccessibilityLabel(folder.name)
        paint()
        needsLayout = true
    }

    override func hoverChanged() { paint() }

    private func paint() {
        let tone: KitTone = hovering ? .ink : .title
        name.color = tone.base
        name.opacity = tone.opacity
        mark.tone = tone
    }

    override func layout() {
        super.layout()
        let height = GroupHeadingView.height
        mark.kitSetFrame(NSRect(x: 10, y: (height - 15) / 2, width: 19, height: 15))
        var right = bounds.width - 10
        if !needs.isHidden {
            let width = ceil(needs.intrinsicContentSize.width)
            needs.kitSetFrame(NSRect(x: right - width, y: (height - 14) / 2, width: width, height: 14))
            right -= width + 9
        }
        name.kitSetFrame(NSRect(x: 38, y: (height - 17) / 2, width: max(0, right - 38), height: 17))
    }

    override func mouseUp(with event: NSEvent) {
        guard let browser, let folder, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        browser.toggleTaskFolder(folder.id)
    }

    override func mouseDown(with event: NSEvent) {}

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let browser, let folder else { return nil }
        let id = folder.id
        return KitMenu.make([
            .action("Open Chat") { browser.showTask(id) },
            .action("Mark as Read") { browser.markTaskRead(id) },
            .action("Keep Tabs") { browser.keepTaskTabs(id) },
            .separator,
            .action("Stop", enabled: AgentTasks.shared.running[id] != nil) { AgentTasks.shared.stop(id) },
            .action("Close") {
                AgentTasks.shared.stop(id)
                browser.closeTaskTabs(id)
            },
        ])
    }

    override func accessibilityPerformPress() -> Bool {
        guard let browser, let folder else { return false }
        browser.toggleTaskFolder(folder.id)
        return true
    }
}

extension GroupHeadingView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

import AppKit
import CoreText
import QuartzCore

struct OnboardingLayout: Equatable {
    static let wordSize: CGFloat = 48
    static let headerShare: CGFloat = 0.52
    static let plain: CGFloat = 950
    static let largest: CGFloat = 1.5
    static let cardGap: CGFloat = 28
    static let fill: CGFloat = 1
    static let drift: CGFloat = 1.06
    static let veil = 0.7
    static let quietGrid: Swift.Float = 0.3
    static let quietLine: Swift.Float = 0.05
    static let cardWaits = 0.3
    static let cardFades = 0.42

    let size: CGSize
    let safeTop: CGFloat
    let capHeight: CGFloat

    var unit: CGFloat { min(max((size.height - safeTop) / Self.plain, 1), Self.largest) }
    var header: CGFloat { Self.headerShare }
    var centre: CGPoint { CGPoint(x: size.width / 2, y: (size.height - safeTop) / 2) }
    var focus: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }
    var wide: CGFloat { size.height / BroadwayMap.canvas * Self.fill }
    var wordHeight: CGFloat { capHeight * unit }
    var baseline: CGFloat { centre.y - wordHeight / 2 }
    var stack: CGFloat { wordHeight * header + Self.cardGap + OnboardingCard.size.height }
    var headerCentre: CGPoint { CGPoint(x: centre.x, y: centre.y + stack / 2 - wordHeight * header / 2) }
    var cardCentre: CGPoint { CGPoint(x: centre.x, y: centre.y - stack / 2 + OnboardingCard.size.height / 2) }
    var cardFrame: CGRect {
        let card = OnboardingCard.size
        return CGRect(x: cardCentre.x - card.width / 2, y: cardCentre.y - card.height / 2, width: card.width, height: card.height)
    }
}

enum OnboardingWord {
    static let text = "Broadway"
    static let face = "HelveticaNeue-Bold"

    static func font(_ size: CGFloat) -> NSFont {
        NSFont(name: face, size: size) ?? .systemFont(ofSize: size, weight: .bold)
    }

    static func glyphs(size: CGFloat) -> (paths: [CGPath], bounds: CGRect, capHeight: CGFloat) {
        let font = font(size)
        let string = NSAttributedString(string: text, attributes: [.font: font, .tracking: -size * 0.012])
        let line = CTLineCreateWithAttributedString(string)
        var paths: [CGPath] = []
        var bounds = CGRect.null
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var places = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &places)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let used = (attributes[kCTFontAttributeName] as! CTFont?) ?? font
            for index in 0..<count {
                var move = CGAffineTransform(translationX: places[index].x, y: places[index].y)
                guard let path = CTFontCreatePathForGlyph(used, glyphs[index], &move) else { continue }
                paths.append(path)
                bounds = bounds.union(path.boundingBoxOfPath)
            }
        }
        return (paths, bounds, font.capHeight)
    }
}

enum OnboardingPen {
    static func ease(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    static func stroke(from start: Double, to end: Double, bend: Double, samples: Int = 64) -> [Double] {
        guard end > start, samples > 1 else { return [start, end] }
        let steps = 400
        let span = end - start
        var times: [Double] = [0]
        for step in 0..<steps {
            let at = start + span * (Double(step) + 0.5) / Double(steps)
            let along = (at - start) / span
            let lift = 0.3 + 0.7 * ease(along / 0.14)
            let land = 0.55 + 0.45 * ease((1 - along) / 0.2)
            let corner = 1 - 0.52 * exp(-pow((at - bend) / (span * 0.11), 2))
            let speed = lift * land * corner
            times.append(times[step] + span / Double(steps) / speed)
        }
        let whole = times[steps]
        var values: [Double] = []
        var step = 0
        for sample in 0..<samples {
            let wanted = whole * Double(sample) / Double(samples - 1)
            while step < steps - 1, times[step + 1] < wanted { step += 1 }
            let share = times[step + 1] > times[step] ? (wanted - times[step]) / (times[step + 1] - times[step]) : 0
            values.append(start + span * (Double(step) + min(max(share, 0), 1)) / Double(steps))
        }
        values[0] = start
        values[samples - 1] = end
        return values
    }

    static func reach(in visible: CGRect) -> (enters: Double, bend: Double, leaves: Double) {
        let bend = BroadwayMap.spot(avenue: BroadwayMap.graceChurch.avenue, street: BroadwayMap.graceChurch.street)
        var points: [CGPoint] = []
        BroadwayMap.route().applyWithBlock { element in
            let at = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(at[0])
            case .addQuadCurveToPoint:
                let from = points.last ?? at[1]
                for step in 1...48 {
                    let t = CGFloat(step) / 48
                    let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
                    points.append(CGPoint(x: a * from.x + b * at[0].x + c * at[1].x, y: a * from.y + b * at[0].y + c * at[1].y))
                }
            default: break
            }
        }
        var lengths: [CGFloat] = [0]
        for index in 1..<max(points.count, 1) {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        let whole = max(lengths.last ?? 1, 1)
        let seen = visible.insetBy(dx: -BroadwayMap.lineWidth, dy: -BroadwayMap.lineWidth)
        var first: CGFloat?
        var last: CGFloat = whole
        var nearest = CGFloat.greatestFiniteMagnitude
        var turn: CGFloat = whole / 2
        var along: CGFloat = 0
        let stride: CGFloat = 4
        for index in 1..<max(points.count, 1) {
            let from = points[index - 1], to = points[index]
            let piece = lengths[index] - lengths[index - 1]
            var step: CGFloat = 0
            while step <= piece {
                let t = piece > 0 ? step / piece : 0
                let point = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                if seen.contains(point) {
                    if first == nil { first = along + step }
                    last = along + step
                }
                let away = hypot(point.x - bend.x, point.y - bend.y)
                if away < nearest {
                    nearest = away
                    turn = along + step
                }
                step += stride
            }
            along = lengths[index]
        }
        return (Double((first ?? 0) / whole), Double(turn / whole), Double(last / whole))
    }
}

final class OnboardingSceneView: NSView {
    private let dim = CALayer()
    private let picture = CALayer()
    private let map = CALayer()
    private let grid = CAShapeLayer()
    private let line = CAShapeLayer()
    private let word = CALayer()
    private var outlines: [CAShapeLayer] = []
    private var fills: [CAShapeLayer] = []
    private var glyphs: (paths: [CGPath], bounds: CGRect, capHeight: CGFloat)
    private(set) var placed: OnboardingLayout?
    private(set) var raised = false
    var skip: (() -> Void)?
    var skippable = false

    static func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    override init(frame: NSRect) {
        glyphs = OnboardingWord.glyphs(size: OnboardingLayout.wordSize)
        super.init(frame: frame)
        let root = CALayer()
        layer = root
        wantsLayer = true
        root.masksToBounds = true
        root.addSublayer(dim)
        root.addSublayer(picture)
        picture.addSublayer(map)
        picture.addSublayer(word)
        map.addSublayer(grid)
        map.addSublayer(line)
        dim.backgroundColor = Self.colour(0x08090B, 0.9)
        grid.path = BroadwayMap.grid()
        grid.fillColor = nil
        grid.strokeColor = Self.colour(BroadwayMap.inkGrid, BroadwayMap.inkGridAlpha)
        grid.lineWidth = BroadwayMap.gridWidth
        grid.lineCap = .round
        grid.opacity = OnboardingLayout.quietGrid
        line.path = BroadwayMap.route()
        line.fillColor = nil
        line.strokeColor = Self.colour(BroadwayMap.inkLine)
        line.lineWidth = BroadwayMap.lineWidth
        line.lineCap = .round
        line.opacity = OnboardingLayout.quietLine
        for path in glyphs.paths {
            let fill = CAShapeLayer()
            fill.path = path
            fill.fillColor = CGColor(gray: 1, alpha: 1)
            let outline = CAShapeLayer()
            outline.path = path
            outline.fillColor = nil
            outline.strokeColor = CGColor(gray: 1, alpha: 1)
            outline.lineWidth = 1.1
            outline.lineJoin = .round
            outline.opacity = 0
            word.addSublayer(fill)
            word.addSublayer(outline)
            fills.append(fill)
            outlines.append(outline)
        }
        setAccessibilityRole(.button)
        setAccessibilityLabel("Broadway")
        setAccessibilityHelp("The introduction is playing. Press Return or click to skip it.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func isAccessibilityElement() -> Bool { skippable }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard skippable else { return false }
        skip?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if skippable { skip?() }
    }

    func layout(for size: CGSize, safeTop: CGFloat) -> OnboardingLayout {
        OnboardingLayout(size: size, safeTop: safeTop, capHeight: glyphs.capHeight)
    }

    func place(_ layout: OnboardingLayout) {
        guard layout != placed else { return }
        placed = layout
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let whole = CGRect(origin: .zero, size: layout.size)
        let canvas = CGRect(x: 0, y: 0, width: BroadwayMap.canvas, height: BroadwayMap.canvas)
        dim.frame = whole
        picture.frame = whole
        map.bounds = canvas
        map.position = layout.focus
        map.transform = CATransform3DMakeScale(layout.wide, layout.wide, 1)
        for part in [grid, line] {
            part.frame = canvas
            part.contentsScale = scale
        }
        word.bounds = whole
        word.anchorPoint = CGPoint(x: layout.centre.x / max(layout.size.width, 1), y: layout.centre.y / max(layout.size.height, 1))
        word.position = layout.centre
        let grown = CGAffineTransform(scaleX: layout.unit, y: layout.unit)
        let shift = grown.concatenating(CGAffineTransform(translationX: (layout.centre.x - glyphs.bounds.midX * layout.unit).rounded(),
                                                          y: layout.baseline.rounded()))
        for layer in fills + outlines {
            layer.anchorPoint = .zero
            layer.bounds = whole
            layer.position = .zero
            layer.setAffineTransform(shift)
            layer.contentsScale = scale * layout.unit
        }
        CATransaction.commit()
        if raised { raise(animated: false) }
    }

    var draws: Bool { line.animation(forKey: "strokeEnd") != nil }
    var veiled: Bool { dim.animation(forKey: "opacity") != nil }
    var backdrop: CGRect { map.frame }

    private var parts: [CALayer] { [dim, picture, map, grid, line, word] + fills + outlines }

    func strip(keepingDim: Bool = false) {
        for part in parts where !(keepingDim && part === dim) { part.removeAllAnimations() }
    }

    func dip(takes: Double) {
        dim.kitAnimate("opacity", to: 1, curve: .easeOut(0.3))
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = picture.presentation()?.opacity ?? picture.opacity
        out.toValue = 0
        out.duration = takes
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        picture.add(out, forKey: "opacity")
    }

    func surface(takes: Double) {
        let back = CABasicAnimation(keyPath: "opacity")
        back.fromValue = 0
        back.toValue = 1
        back.duration = takes
        back.timingFunction = CAMediaTimingFunction(name: .easeOut)
        picture.add(back, forKey: "opacity")
    }

    func freeze(at time: CFTimeInterval) {
        guard let layer else { return }
        layer.speed = 0
        layer.timeOffset = time
    }

    private func clock() -> CFTimeInterval {
        (layer?.convertTime(CACurrentMediaTime(), from: nil) ?? CACurrentMediaTime()) + 0.05
    }

    private func move(_ layer: CALayer, _ keyPath: String, from: Any, to: Any, at: Double, takes: Double,
                      curve: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.beginTime = at
        animation.duration = takes
        animation.timingFunction = curve
        animation.fillMode = .backwards
        layer.add(animation, forKey: keyPath)
    }

    private func frames(_ layer: CALayer, _ keyPath: String, values: [Any], times: [Double]? = nil, curves: [CAMediaTimingFunction]? = nil,
                        at: Double, takes: Double) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { $0.map { NSNumber(value: $0) } }
        animation.timingFunctions = curves
        animation.calculationMode = .linear
        animation.beginTime = at
        animation.duration = takes
        animation.fillMode = .backwards
        layer.add(animation, forKey: keyPath)
    }

    @discardableResult
    func play(_ score: OnboardingScore) -> CFTimeInterval {
        strip()
        raised = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        word.transform = CATransform3DIdentity
        picture.opacity = 1
        CATransaction.commit()
        let start = clock()
        guard let layout = placed else { return start }
        let soft = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.3, 1)
        guard score.drawn else {
            move(dim, "opacity", from: 0, to: 1, at: start, takes: score.dimTakes, curve: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.5, 1))
            move(picture, "opacity", from: 0, to: 1, at: start + score.word, takes: score.letterTakes, curve: soft)
            return start
        }
        let wide = layout.wide
        let visible = CGRect(x: BroadwayMap.canvas / 2 - layout.size.width / 2 / wide, y: BroadwayMap.canvas / 2 - layout.size.height / 2 / wide,
                             width: layout.size.width / wide, height: layout.size.height / wide)
        let whole = score.mapRests
        let still = CAMediaTimingFunction(name: .linear)
        frames(grid, "opacity", values: [0, 1, 1, OnboardingLayout.quietGrid],
               times: [0, score.gridTakes / (whole - score.grid), (score.recede - score.grid) / (whole - score.grid), 1],
               curves: [soft, still, soft], at: start + score.grid, takes: whole - score.grid)
        let deepens = score.recede + score.recedeTakes * 0.5
        var veil: [Any] = []
        var veilTimes: [Double] = []
        for step in 0...12 {
            let t = Double(step) / 12
            veil.append(OnboardingLayout.veil * OnboardingPen.ease(t))
            veilTimes.append(score.dimTakes * t / deepens)
        }
        for step in 0...12 {
            let t = Double(step) / 12
            veil.append(OnboardingLayout.veil + (1 - OnboardingLayout.veil) * OnboardingPen.ease(t))
            veilTimes.append((score.recede + score.recedeTakes * 0.5 * t) / deepens)
        }
        frames(dim, "opacity", values: veil, times: veilTimes, at: start, takes: deepens)

        let reach = OnboardingPen.reach(in: visible)
        let drawn = OnboardingPen.stroke(from: reach.enters, to: max(reach.leaves, reach.enters + 0.01), bend: reach.bend)
        frames(line, "strokeEnd", values: drawn, at: start + score.line, takes: score.lineTakes)

        move(line, "opacity", from: 1, to: OnboardingLayout.quietLine, at: start + score.recede, takes: score.recedeTakes, curve: soft)
        move(map, "transform.scale", from: wide * OnboardingLayout.drift, to: wide, at: start, takes: whole,
             curve: CAMediaTimingFunction(controlPoints: 0.2, 0.55, 0.3, 1))
        for (index, outline) in outlines.enumerated() {
            let at = start + score.word + Double(index) * score.letterGap
            move(outline, "strokeEnd", from: 0, to: 1, at: at, takes: score.letterTakes, curve: CAMediaTimingFunction(controlPoints: 0.45, 0, 0.35, 1))
            move(outline, "opacity", from: 1, to: 0, at: at + score.inkAt + score.inkLags, takes: score.inkTakes, curve: soft)
            move(fills[index], "opacity", from: 0, to: 1, at: at + score.inkAt, takes: score.inkTakes, curve: soft)
        }
        return start
    }

    func raise(animated: Bool, takes: Double = 0.6) {
        guard let layout = placed else { return }
        raised = true
        let lift = layout.headerCentre.y - layout.centre.y
        let scale = layout.header
        let wanted = CATransform3DConcat(CATransform3DMakeScale(scale, scale, 1), CATransform3DMakeTranslation(0, lift, 0))
        let curve: KitCurve = animated ? .spring(KitSpring(response: takes * 0.8, damping: 0.88)) : .none
        word.kitAnimate("transform", to: NSValue(caTransform3D: wanted), curve: curve)
    }
}

final class OnboardingView: NSView {
    let onboarding: Onboarding
    let scene = OnboardingSceneView(frame: .zero)
    let card: OnboardingCard
    private var shown = Onboarding.Phase.away
    private var playing = false
    private var began: CFTimeInterval = 0
    private var settles = 0

    static let dipTakes = 0.14

    init(onboarding: Onboarding) {
        self.onboarding = onboarding
        card = OnboardingCard(onboarding: onboarding)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(scene)
        addSubview(card)
        card.isHidden = true
        scene.skip = { [weak onboarding] in onboarding?.endIntro() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Welcome to Broadway")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    private var safeTop: CGFloat {
        guard let window, let screen = window.screen, window.frame.maxY >= screen.frame.maxY - 1 else { return 0 }
        return screen.safeAreaInsets.top
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        scene.frame = bounds
        let layout = scene.layout(for: bounds.size, safeTop: safeTop)
        scene.place(layout)
        card.frame = kitSnap(layout.cardFrame)
        let phase = onboarding.phase
        guard phase != shown else { return }
        let was = shown
        shown = phase
        switch phase {
        case .intro:
            scene.skippable = true
            card.isHidden = true
        case .steps:
            scene.skippable = false
            settle(animated: was == .intro && playing)
        case .leaving, .away:
            scene.skippable = false
        }
    }

    func play(freezeAt: Double? = nil) {
        settles += 1
        playing = true
        began = CACurrentMediaTime()
        let start = scene.play(onboarding.score)
        if let freezeAt { scene.freeze(at: start + freezeAt) }
        needsLayout = true
    }

    private func settle(animated: Bool) {
        let score = onboarding.score
        let calm = !score.drawn
        let plain = calm || CACurrentMediaTime() - began < score.ends - 0.1
        let fades = calm ? score.settleTakes : 0.26
        settles += 1
        if animated, plain {
            let run = settles
            scene.dip(takes: Self.dipTakes)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dipTakes) { [weak self] in
                guard let self, self.settles == run else { return }
                self.scene.strip(keepingDim: true)
                self.scene.raise(animated: false)
                self.scene.surface(takes: fades)
            }
        } else {
            scene.strip()
            scene.raise(animated: animated, takes: score.settleTakes)
        }
        card.isHidden = false
        card.needsLayout = true
        guard animated, let layer = card.layer else {
            NSAccessibility.post(element: card, notification: .layoutChanged)
            return
        }
        layer.removeAllAnimations()
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        let waits = plain ? Self.dipTakes : OnboardingLayout.cardWaits
        if !plain {
            let spring = KitSpring(response: score.settleTakes * 0.8, damping: 0.86)
            let rise = spring.animation("transform.translation.y", from: -44, to: 0)
            rise.isAdditive = true
            rise.beginTime = now + waits
            rise.fillMode = .backwards
            layer.add(rise, forKey: "arrive.rise")
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = now + waits
        fade.duration = plain ? fades : OnboardingLayout.cardFades
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        layer.add(fade, forKey: "arrive.fade")
        window?.makeFirstResponder(card.firstField)
        NSAccessibility.post(element: card, notification: .layoutChanged)
    }

    func leave(takes: Double) {
        guard onboarding.score.drawn, let layer else { return }
        let middle = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        let grown = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                            CATransform3DMakeScale(1.035, 1.035, 1)), middle)
        let grow = CABasicAnimation(keyPath: "sublayerTransform")
        grow.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        grow.toValue = NSValue(caTransform3D: grown)
        grow.duration = takes
        grow.timingFunction = CAMediaTimingFunction(name: .easeIn)
        grow.fillMode = .forwards
        grow.isRemovedOnCompletion = false
        layer.add(grow, forKey: "leave")
    }
}

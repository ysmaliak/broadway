import AppKit
import QuartzCore

struct KitPlayShape: Equatable {
    var size: CGFloat = 21

    static let round: CGFloat = 1.5
    static let bar = CGSize(width: 5.5, height: 18)
    static let gap: CGFloat = 3
    static let wedge = CGSize(width: 13.535, height: 16)

    var unit: CGFloat { size / 21 }
    var round: CGFloat { Self.round * unit }
    var side: CGFloat { (12 * unit).rounded(.up) * 2 }

    static let lead: CGFloat = {
        let wide = wedge.width, half = wedge.height / 2, round = KitPlayShape.round
        let slope = (wide * wide + half * half).squareRoot()
        var area = wide * half
        var moment = area * wide / 3
        area += 2 * half * round
        moment += 2 * half * round * (-round / 2)
        let lean = half / slope
        area += 2 * slope * round
        moment += 2 * slope * round * (wide / 2 + lean * round / 2)
        let back = CGFloat.pi - atan2(wide, half)
        let backArea = back * round * round / 2
        let backReach = 4 * round * sin(back / 2) / (3 * back)
        let across = lean - 1, down = wide / slope
        area += 2 * backArea
        moment += 2 * backArea * (across / (across * across + down * down).squareRoot() * backReach)
        let tip = CGFloat.pi - 2 * atan2(half, wide)
        let tipArea = tip * round * round / 2
        area += tipArea
        moment += tipArea * (wide + 4 * round * sin(tip / 2) / (3 * tip))
        return moment / area
    }()

    static let play = KitPlayShape().points(0)
    static let pause = KitPlayShape().points(1)

    func points(_ progress: Double) -> [CGPoint] {
        let share = CGFloat(progress), scale = unit
        let far = Self.gap / 2 + Self.bar.width - Self.round
        let tall = Self.bar.height / 2 - Self.round
        let back = -Self.lead * (1 - share) - far * share
        let backHalf = Self.wedge.height / 2 * (1 - share) + tall * share
        let front = (Self.wedge.width - Self.lead) * (1 - share) + far * share
        let frontHalf = tall * share
        let slit = (Self.gap / 2 + Self.round) * share * share
        let lean = (frontHalf - backHalf) / (front - back)
        let left = backHalf + lean * (-slit - back), right = backHalf + lean * (slit - back)
        return [CGPoint(x: back, y: -backHalf), CGPoint(x: -slit, y: -left), CGPoint(x: -slit, y: left), CGPoint(x: back, y: backHalf),
                CGPoint(x: slit, y: -right), CGPoint(x: front, y: -frontHalf), CGPoint(x: front, y: frontHalf), CGPoint(x: slit, y: right)]
            .map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
    }

    func path(_ progress: Double, around centre: CGPoint) -> CGPath {
        let points = points(progress).map { CGPoint(x: centre.x + $0.x, y: centre.y + $0.y) }
        let path = CGMutablePath()
        for half in [points[0..<4], points[4..<8]] {
            path.addLines(between: Array(half))
            path.closeSubpath()
        }
        return path
    }

    func draw(_ progress: Double, around centre: CGPoint, colour: CGColor, in context: CGContext) {
        context.saveGState()
        context.addPath(path(progress, around: centre))
        context.setFillColor(colour)
        context.setStrokeColor(colour)
        context.setLineWidth(round * 2)
        context.setLineJoin(.round)
        context.drawPath(using: .fillStroke)
        context.restoreGState()
    }
}

struct KitPlayTurn: Equatable {
    let from: Double
    let to: Double
    let lean: Double
    let began: Double
    let spring: KitSpring

    static let lively = KitSpring(response: 0.26, damping: 0.8)
    static let calm = KitSpring(response: 0.2, damping: 1)
    static let step = 1.0 / 120
    static let longest = 0.8
    static let near = 0.002

    init(from: Double, to: Double, lean: Double = 0, began: Double, spring: KitSpring) {
        self.from = from
        self.to = to
        self.lean = lean
        self.began = began
        self.spring = spring
    }

    func value(at time: Double) -> Double {
        from + (to - from) * spring.progress(time - began, velocity: lean)
    }

    func speed(at time: Double) -> Double {
        (to - from) * spring.rate(time - began, velocity: lean)
    }

    var length: Double {
        let most = Int((Self.longest / Self.step).rounded())
        var last = 0
        for index in 1...most where abs(1 - spring.progress(Double(index) * Self.step, velocity: lean)) > Self.near { last = index }
        return Double(min(most, last + 1)) * Self.step
    }

    var frames: [Double] {
        let count = Int((length / Self.step).rounded())
        return (0...count).map { $0 == count ? to : value(at: began + Double($0) * Self.step) }
    }

    func settled(at time: Double) -> Bool { time - began >= length }

    func turned(to target: Double, at time: Double, spring: KitSpring) -> KitPlayTurn {
        let here = value(at: time)
        let ahead = target - here
        let lean = abs(ahead) > 0.0001 ? max(-40, min(40, speed(at: time) / ahead)) : 0
        return KitPlayTurn(from: here, to: target, lean: lean, began: time, spring: spring)
    }
}

final class KitPlayMark: NSView {
    enum Face: String {
        case play, pause

        var rest: Double { self == .pause ? 1 : 0 }
    }

    static let key = "swap"

    let shape: KitPlayShape
    let ink = CAShapeLayer()
    var tint: NSColor { didSet { if tint != oldValue { paint() } } }
    private(set) var face: Face
    private(set) var turn: KitPlayTurn?
    private(set) var swaps = 0

    init(_ face: Face, size: CGFloat = 21, tint: NSColor = .white) {
        self.face = face
        self.tint = tint
        shape = KitPlayShape(size: size)
        super.init(frame: .zero)
        wantsLayer = true
        ink.lineJoin = .round
        ink.lineWidth = shape.round * 2
        ink.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull()]
        layer?.addSublayer(ink)
        setAccessibilityElement(false)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: shape.side, height: shape.side) }

    private var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    override func layout() {
        super.layout()
        ink.frame = bounds
        ink.path = shape.path(face.rest, around: centre)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        sharpen()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        sharpen()
    }

    private func sharpen() {
        ink.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func paint() {
        let colour = tint.kitResolved(dark: kitDark).cgColor
        ink.fillColor = colour
        ink.strokeColor = colour
    }

    func show(_ next: Face, animated: Bool = true, at time: CFTimeInterval = CACurrentMediaTime()) {
        guard next != face else { return }
        let moving = turn.flatMap { $0.settled(at: time) ? nil : $0 }
        let here = moving?.value(at: time) ?? face.rest
        face = next
        ink.path = shape.path(next.rest, around: centre)
        guard animated, !Motion.reduced, window != nil, abs(next.rest - here) > 0.0001 else {
            turn = nil
            ink.removeAnimation(forKey: Self.key)
            return
        }
        let spring = Motion.light ? KitPlayTurn.calm : KitPlayTurn.lively
        let made = moving?.turned(to: next.rest, at: time, spring: spring) ?? KitPlayTurn(from: here, to: next.rest, began: time, spring: spring)
        turn = made
        swaps += 1
        let film = CAKeyframeAnimation(keyPath: "path")
        film.values = made.frames.map { shape.path($0, around: centre) }
        film.duration = made.length
        film.calculationMode = .linear
        film.beginTime = ink.convertTime(time, from: nil)
        ink.add(film, forKey: Self.key)
    }
}

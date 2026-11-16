import AppKit
import Observation

enum AgentCharacter {
    enum Mood: String, CaseIterable {
        case hello, idle, reading, typing, waving, driving, done, failed, ended

        var title: String {
            switch self {
            case .hello: return "Just connected"
            case .idle: return "Waiting"
            case .reading: return "Reading"
            case .typing: return "Typing"
            case .waving: return "Needs you"
            case .driving: return "You're driving"
            case .done: return "Done"
            case .failed: return "Couldn't finish"
            case .ended: return "Ended"
            }
        }

        init(_ mood: AgentMood?) {
            switch mood {
            case .none: self = .idle
            case .reading?: self = .reading
            case .typing?: self = .typing
            case .waving?: self = .waving
            case .done?: self = .done
            case .failed?: self = .failed
            }
        }
    }

    enum Brows: Equatable {
        case none, raised, worried
    }

    struct Frame: Equatable {
        var look = CGPoint.zero
        var open: CGFloat = 1
        var wide: CGFloat = 1
        var nod: CGFloat = 0
        var tilt: CGFloat = 0
        var squash: CGFloat = 0
        var smile: CGFloat = 0
        var brows = Brows.none
        var tick = false
        var dim: CGFloat = 0
    }

    static let askTilt: CGFloat = 0.1
    static let swayCycle: TimeInterval = 3.2
    static let helloSpan: TimeInterval = 6

    static func still(_ mood: Mood) -> Frame {
        var frame = Frame()
        switch mood {
        case .hello:
            frame.look = CGPoint(x: 0, y: -0.07)
            frame.open = 1.15
            frame.wide = 1.15
            frame.tilt = 0.08
        case .idle: break
        case .reading:
            frame.look = CGPoint(x: 0, y: 0.04)
            frame.open = 0.9
        case .typing:
            frame.look = CGPoint(x: 0, y: 0.12)
            frame.open = 0.85
        case .waving:
            frame.look = CGPoint(x: 0.03, y: -0.05)
            frame.tilt = askTilt
            frame.brows = .raised
        case .driving:
            frame.look = CGPoint(x: 0.12, y: -0.04)
            frame.open = 0.7
            frame.tilt = -0.05
        case .done:
            frame.smile = 1
            frame.tick = true
        case .failed:
            frame.look = CGPoint(x: 0, y: 0.12)
            frame.open = 0.9
            frame.brows = .worried
            frame.squash = 0.07
            frame.nod = 0.02
            frame.tilt = -0.06
        case .ended:
            frame.smile = -1
            frame.dim = 0.45
            frame.squash = 0.04
            frame.nod = 0.03
        }
        return frame
    }

    enum Part: String {
        case squash, tilt, nod, lookX, blink
    }

    struct Track: Equatable {
        var part: Part
        var period: Double
        var times: [Double]
        var values: [CGFloat]
        var offset: Double = 0

        func value(at time: Double) -> CGFloat {
            let wrapped = (time + offset).truncatingRemainder(dividingBy: period)
            let t = (wrapped < 0 ? wrapped + period : wrapped) / period
            guard let next = times.firstIndex(where: { $0 >= t }), next > 0 else { return values[0] }
            let from = times[next - 1], to = times[next]
            let share = to > from ? (t - from) / (to - from) : 1
            let eased = share * share * (3 - 2 * share)
            return values[next - 1] + (values[next] - values[next - 1]) * CGFloat(eased)
        }
    }

    enum Loop: Equatable {
        case breathe(TimeInterval, CGFloat)
        case blink, glance, scan, tap, sway
    }

    static func loops(_ mood: Mood) -> [Loop] {
        switch mood {
        case .hello: return [.breathe(3.6, 0.03), .blink, .glance]
        case .idle: return [.breathe(4.2, 0.03), .blink, .glance]
        case .reading: return [.scan, .blink]
        case .typing: return [.tap, .blink]
        case .waving: return [.sway, .blink]
        case .driving: return [.breathe(4.8, 0.025), .blink]
        case .done: return [.breathe(4.8, 0.025)]
        case .failed: return [.breathe(5.6, 0.035), .blink]
        case .ended: return []
        }
    }

    static func lean(_ look: CGFloat) -> CGFloat { look * 0.5 }

    static func tracks(_ loop: Loop, seed: UInt64) -> [Track] {
        switch loop {
        case .breathe(let period, let depth):
            return [Track(part: .squash, period: period, times: [0, 0.5, 1], values: [0, depth, 0], offset: phase(seed) * period)]
        case .blink:
            let period = blinkPeriod(seed)
            let shut = 0.16 / period
            return [Track(part: .blink, period: period, times: [0, 1 - shut, 1 - shut / 2, 1], values: [1, 1, 0.1, 1], offset: phase(seed) * period)]
        case .glance:
            let period = 9 + Double(seed % 4001) / 1000
            return [Track(part: .lookX, period: period, times: [0, 0.3, 0.35, 0.5, 0.55, 0.75, 0.8, 0.9, 0.95, 1],
                          values: [0, 0, 0.07, 0.07, 0, 0, -0.06, -0.06, 0, 0], offset: phase(seed) * period)]
        case .scan:
            let times: [Double] = [0, 0.18, 0.22, 0.39, 0.43, 0.6, 0.64, 0.82, 1]
            let looks: [CGFloat] = [-0.09, -0.09, -0.03, -0.03, 0.03, 0.03, 0.09, 0.09, -0.09]
            let offset = phase(seed) * 2.4
            return [Track(part: .lookX, period: 2.4, times: times, values: looks, offset: offset),
                    Track(part: .tilt, period: 2.4, times: times, values: looks.map(lean), offset: offset)]
        case .tap:
            return [Track(part: .nod, period: 0.6, times: [0, 0.3, 0.6, 1], values: [0, 0.035, 0, 0], offset: phase(seed) * 0.6)]
        case .sway:
            return [Track(part: .tilt, period: swayCycle, times: [0, 0.5, 1], values: [0, -2 * askTilt, 0])]
        }
    }

    static func tracks(_ mood: Mood, seed: UInt64) -> [Track] {
        loops(mood).flatMap { tracks($0, seed: seed) }
    }

    static func frame(_ mood: Mood, at time: TimeInterval, seed: UInt64) -> Frame {
        var frame = still(mood)
        for track in tracks(mood, seed: seed) {
            let value = track.value(at: time)
            switch track.part {
            case .squash: frame.squash += value
            case .tilt: frame.tilt += value
            case .nod: frame.nod += value
            case .lookX: frame.look.x += value
            case .blink: frame.open *= value
            }
        }
        return frame
    }

    static func loops(_ mood: Mood, reduced: Bool, lowPower: Bool, window: Bool, column: Bool, scrolled: Bool) -> Bool {
        !loops(mood).isEmpty && !reduced && !lowPower && window && column && scrolled
    }

    enum Arrival: Equatable {
        case pop, hop, slump, sleep, settle
    }

    static func arrival(from old: Mood?, to mood: Mood) -> Arrival? {
        guard let old else { return mood == .hello ? .pop : nil }
        guard old != mood else { return nil }
        switch mood {
        case .done, .waving: return .hop
        case .failed: return .slump
        case .ended: return .sleep
        default: return .settle
        }
    }

    static let spring = KitSpring(response: 0.42, damping: 0.72)
    static let slump = KitSpring(response: 0.7, damping: 0.9)
    static let pop = KitSpring(response: 0.5, damping: 0.55)

    static func curve(_ arrival: Arrival?, reduced: Bool, lowPower: Bool) -> KitCurve {
        guard let arrival, !reduced else { return .none }
        if lowPower { return .easeOut(0.2) }
        switch arrival {
        case .slump: return .spring(slump)
        case .sleep: return .easeInOut(0.9)
        case .pop, .hop, .settle: return .spring(spring)
        }
    }

    static func flourishes(_ arrival: Arrival?, reduced: Bool, lowPower: Bool) -> Bool {
        guard let arrival, !reduced, !lowPower else { return false }
        return arrival == .pop || arrival == .hop
    }

    static let hopTimes: [Double] = [0, 0.28, 0.56, 0.78, 1]
    static let hopHeights: [CGFloat] = [0, -0.2, 0, -0.06, 0]
    static let hopLength: TimeInterval = 0.6

    static func face(_ state: AgentLinkState, ended: AgentLinkEnding?, connected: Date, now: Date) -> Mood {
        if ended != nil, case .done(nil) = state { return .ended }
        if ended == nil, state == .idle, now.timeIntervalSince(connected) < helloSpan { return .hello }
        return state.mood
    }

    static func blinkPeriod(_ seed: UInt64) -> TimeInterval {
        3 + Double(seed % 3001) / 1000
    }

    static func phase(_ seed: UInt64) -> Double {
        Double((seed >> 16) % 1000) / 1000
    }

    static func accentColor(_ index: Int) -> NSColor {
        let hues: [(CGFloat, CGFloat, CGFloat)] = [
            (0.13, 0.66, 0.80),
            (0.42, 0.50, 0.92),
            (0.56, 0.38, 0.88),
            (0.84, 0.30, 0.64),
            (0.93, 0.42, 0.34),
            (0.24, 0.62, 0.42)
        ]
        let hue = hues[((index % hues.count) + hues.count) % hues.count]
        return NSColor(srgbRed: hue.0, green: hue.1, blue: hue.2, alpha: 1)
    }

    struct Pose {
        var unit: CGFloat
        var line: CGFloat
        var pivot: CGPoint
        var head: CGRect
        var radius: CGFloat
        var scale: CGSize
        var tilt: CGFloat
        var nod: CGFloat
        var opacity: Swift.Float
        var gaze: CGPoint
        var eyes: [CGPoint]
        var eye: CGSize
        var eyeOpacity: Swift.Float
        var arcs: [CGPoint]
        var arc: CGFloat
        var arcScale: CGFloat
        var arcOpacity: Swift.Float
        var brows: [CGPoint]
        var brow: CGFloat
        var browTurn: [CGFloat]
        var browOpacity: Swift.Float
        var badge: CGPoint
        var badgeSide: CGFloat
        var badgeScale: CGFloat
        var badgeOpacity: Swift.Float
    }

    static func pose(_ frame: Frame, size: CGSize) -> Pose {
        let unit = min(size.width, size.height)
        let line = max(1, (unit * 0.17).rounded() / 2)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let side = unit * 0.78
        let head = CGRect(x: centre.x - side / 2, y: centre.y - side / 2 + unit * 0.04, width: side, height: side)
        let inner = head.insetBy(dx: line / 2 + unit * 0.05, dy: line / 2 + unit * 0.05)
        let eyeY = head.midY - unit * 0.02
        let gap = unit * 0.15
        let eye = CGSize(width: unit * 0.12 * frame.wide, height: max(unit * 0.03, unit * 0.24 * frame.open))
        let reachX = max(0, inner.width / 2 - gap - eye.width / 2)
        let gaze = CGPoint(x: min(reachX, max(-reachX, frame.look.x * unit)),
                           y: min(inner.maxY - eye.height / 2 - eyeY, max(inner.minY + eye.height / 2 - eyeY, frame.look.y * unit)))
        let eyes = [CGPoint(x: centre.x - gap, y: eyeY), CGPoint(x: centre.x + gap, y: eyeY)]
        let shut = min(1, abs(frame.smile))
        let arcY = eyeY + (frame.smile >= 0 ? 0.04 : -0.01) * unit
        let raised = frame.brows == .raised
        let browY = max(inner.minY + line * 0.4 - gaze.y, eyeY - eye.height / 2 - unit * (raised ? 0.09 : 0.07))
        let turn: CGFloat = frame.brows == .worried ? 0.4 : 0
        let badgeSide = unit * 0.3
        return Pose(unit: unit, line: line, pivot: CGPoint(x: centre.x, y: head.maxY), head: head, radius: side * 0.42,
                    scale: CGSize(width: 1 + frame.squash * 0.6, height: 1 - frame.squash), tilt: frame.tilt, nod: frame.nod * unit,
                    opacity: Swift.Float(1 - frame.dim), gaze: gaze, eyes: eyes, eye: eye, eyeOpacity: Swift.Float(1 - shut),
                    arcs: eyes.map { CGPoint(x: $0.x, y: arcY) }, arc: unit * 0.075, arcScale: frame.smile < 0 ? -1 : 1,
                    arcOpacity: Swift.Float(shut), brows: eyes.map { CGPoint(x: $0.x, y: browY) }, brow: unit * 0.14,
                    browTurn: [-turn, turn], browOpacity: frame.brows == .none ? 0 : 1,
                    badge: CGPoint(x: head.maxX - unit * 0.09, y: head.maxY - unit * 0.09), badgeSide: badgeSide,
                    badgeScale: frame.tick ? 1 : 0.4, badgeOpacity: frame.tick ? 1 : 0)
    }
}

@MainActor
@Observable
final class LowPowerWatch {
    static let shared = LowPowerWatch()

    private(set) var on = Motion.light
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    private init() {
        let names = [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification]
        tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LowPowerWatch.shared.on = Motion.light }
            }
        }
    }
}

final class AgentCharacterFace: KitFlippedView {
    var mood: AgentCharacter.Mood = .idle {
        didSet {
            guard mood != oldValue else { return }
            change(from: oldValue)
        }
    }
    var colour: NSColor = KitColor.ink { didSet { if colour != oldValue { recolour(animated: true) } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { recolour(animated: false) } } }
    var seed: UInt64 = 0 { didSet { if seed != oldValue { relive(force: true) } } }
    var columnShown = true { didSet { if columnShown != oldValue { relive() } } }
    var inView = true { didSet { if inView != oldValue { relive() } } }
    private(set) var shownFrame = AgentCharacter.Frame()
    private(set) var looping = false

    private let pose = CALayer()
    private let life = CALayer()
    private let head = CALayer()
    private let gaze = CALayer()
    private let scan = CALayer()
    private let eyes = [CALayer(), CALayer()]
    private let arcs = [CAShapeLayer(), CAShapeLayer()]
    private let brows = [CAShapeLayer(), CAShapeLayer()]
    private let badge = CAShapeLayer()
    private let tick = CAShapeLayer()
    private let shown = KitWindowShown()
    private var laid: CGSize = .zero
    private var greeted = false
    private var loopsFor: (mood: AgentCharacter.Mood, seed: UInt64, size: CGSize)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        head.cornerCurve = .continuous
        layer?.addSublayer(pose)
        pose.addSublayer(life)
        life.addSublayer(head)
        life.addSublayer(gaze)
        gaze.addSublayer(scan)
        for eye in eyes { scan.addSublayer(eye) }
        for part in arcs + brows + [badge, tick] {
            part.lineCap = .round
            part.lineJoin = .round
            part.fillColor = nil
        }
        for part in arcs + brows { scan.addSublayer(part) }
        life.addSublayer(badge)
        badge.addSublayer(tick)
        shown.changed = { [weak self] _ in self?.relive() }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        shown.watch(window)
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for part in arcs + brows + [badge, tick] { part.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        recolour(animated: false)
    }

    private var lowPower: Bool { LowPowerWatch.shared.on || Motion.light }

    static var shownInTests = false

    private var windowShown: Bool { window != nil && (shown.shown || (Store.testing && Self.shownInTests)) }

    private var onScreen: Bool { windowShown && columnShown && inView && laid.width > 0 }

    var benchState: [String: Any] {
        ["mood": mood.rawValue, "looping": looping, "loops": loopKeys.count, "window": window != nil, "shown": shown.shown,
         "column": columnShown, "inView": inView, "visible": window?.occlusionState.contains(.visible) ?? false, "size": [laid.width, laid.height].map(Double.init), "lowPower": lowPower,
         "reduced": Motion.reduced]
    }

    var loopKeys: [String] {
        ([life, scan] + eyes).flatMap { $0.animationKeys() ?? [] }.filter { $0.hasPrefix("loop.") }
    }

    override func layout() {
        super.layout()
        if bounds.size != laid { lay() }
        if onScreen, !greeted {
            greeted = true
            if mood == .hello, AgentCharacter.flourishes(.pop, reduced: Motion.reduced, lowPower: lowPower) { flourish(.pop) }
        }
        relive()
    }

    private func lay() {
        laid = bounds.size
        guard laid.width > 0, laid.height > 0 else { return }
        let base = AgentCharacter.pose(AgentCharacter.Frame(), size: laid)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [pose, life] {
            layer.bounds = CGRect(x: 0, y: base.pivot.y - laid.height / 2, width: laid.width, height: laid.height)
            layer.position = base.pivot
        }
        head.frame = base.head.insetBy(dx: -base.line / 2, dy: -base.line / 2)
        head.cornerRadius = base.radius + base.line / 2
        head.borderWidth = base.line
        gaze.frame = CGRect(origin: .zero, size: laid)
        scan.frame = CGRect(origin: .zero, size: laid)
        let arc = CGMutablePath()
        let start = 200 * CGFloat.pi / 180
        arc.move(to: CGPoint(x: cos(start) * base.arc, y: sin(start) * base.arc))
        arc.addArc(center: .zero, radius: base.arc, startAngle: start, endAngle: 340 * .pi / 180, clockwise: false)
        for part in arcs {
            part.bounds = .zero
            part.path = arc
            part.lineWidth = base.line
        }
        let brow = CGMutablePath()
        brow.move(to: CGPoint(x: -base.brow / 2, y: 0))
        brow.addLine(to: CGPoint(x: base.brow / 2, y: 0))
        for part in brows {
            part.bounds = .zero
            part.path = brow
            part.lineWidth = base.line * 0.8
        }
        let side = base.badgeSide
        badge.bounds = CGRect(x: -side / 2, y: -side / 2, width: side, height: side)
        badge.path = CGPath(ellipseIn: badge.bounds, transform: nil)
        tick.frame = badge.bounds
        tick.bounds = badge.bounds
        let mark = CGMutablePath()
        mark.move(to: CGPoint(x: -side / 2 + side * 0.27, y: 0))
        mark.addLine(to: CGPoint(x: -side / 2 + side * 0.45, y: -side / 2 + side * 0.7))
        mark.addLine(to: CGPoint(x: -side / 2 + side * 0.75, y: -side / 2 + side * 0.32))
        tick.path = mark
        tick.lineWidth = max(1, base.unit * 0.06)
        CATransaction.commit()
        apply(shownFrame == AgentCharacter.Frame() ? AgentCharacter.still(mood) : shownFrame, curve: .none)
        recolour(animated: false)
        relive(force: true)
    }

    private func change(from old: AgentCharacter.Mood) {
        guard laid.width > 0 else {
            shownFrame = AgentCharacter.still(mood)
            return
        }
        let arrival = AgentCharacter.arrival(from: old, to: mood)
        let live = onScreen
        let reduced = Motion.reduced
        apply(AgentCharacter.still(mood), curve: live ? AgentCharacter.curve(arrival, reduced: reduced, lowPower: lowPower) : .none)
        if live, AgentCharacter.flourishes(arrival, reduced: reduced, lowPower: lowPower), let arrival { flourish(arrival) }
        if live, mood == .done, !reduced, !lowPower { drawTick() }
        relive(force: true)
    }

    func paint(_ frame: AgentCharacter.Frame) {
        if bounds.size != laid { lay() }
        apply(frame, curve: .none)
    }

    private func apply(_ frame: AgentCharacter.Frame, curve: KitCurve) {
        shownFrame = frame
        guard laid.width > 0 else { return }
        let to = AgentCharacter.pose(frame, size: laid)
        func move(_ layer: CALayer, _ key: String, _ value: Any) { layer.kitAnimate(key, to: value, curve: curve, key: "pose." + key) }
        func number(_ value: CGFloat) -> NSNumber { NSNumber(value: Double(value)) }
        move(pose, "transform.scale.x", number(to.scale.width))
        move(pose, "transform.scale.y", number(to.scale.height))
        move(pose, "transform.rotation.z", number(to.tilt))
        move(pose, "transform.translation.y", number(to.nod))
        move(pose, "opacity", NSNumber(value: to.opacity))
        move(gaze, "transform.translation", NSValue(size: CGSize(width: to.gaze.x, height: to.gaze.y)))
        for (index, eye) in eyes.enumerated() {
            move(eye, "bounds", NSValue(rect: CGRect(origin: .zero, size: to.eye)))
            move(eye, "position", NSValue(point: to.eyes[index]))
            move(eye, "cornerRadius", number(min(to.eye.width, to.eye.height) / 2))
            move(eye, "opacity", NSNumber(value: to.eyeOpacity))
        }
        for (index, arc) in arcs.enumerated() {
            move(arc, "position", NSValue(point: to.arcs[index]))
            move(arc, "transform.scale.y", number(to.arcScale))
            move(arc, "opacity", NSNumber(value: to.arcOpacity))
        }
        for (index, brow) in brows.enumerated() {
            move(brow, "position", NSValue(point: to.brows[index]))
            move(brow, "transform.rotation.z", number(to.browTurn[index]))
            move(brow, "opacity", NSNumber(value: to.browOpacity))
        }
        move(badge, "position", NSValue(point: to.badge))
        move(badge, "transform.scale", number(to.badgeScale))
        move(badge, "opacity", NSNumber(value: to.badgeOpacity))
    }

    private func flourish(_ arrival: AgentCharacter.Arrival) {
        let unit = AgentCharacter.pose(AgentCharacter.Frame(), size: laid).unit
        switch arrival {
        case .pop:
            for axis in ["x", "y"] {
                let grow = AgentCharacter.pop.animation("transform.scale.\(axis)", from: NSNumber(value: -0.45), to: NSNumber(value: 0))
                grow.isAdditive = true
                life.add(grow, forKey: "flourish.pop.\(axis)")
            }
        case .hop:
            let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
            hop.values = AgentCharacter.hopHeights.map { NSNumber(value: Double($0 * unit)) }
            hop.keyTimes = AgentCharacter.hopTimes.map { NSNumber(value: $0) }
            hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                                   CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
            hop.duration = AgentCharacter.hopLength
            hop.isAdditive = true
            life.add(hop, forKey: "flourish.hop")
        case .slump, .sleep, .settle: break
        }
    }

    private func drawTick() {
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.beginTime = tick.convertTime(CACurrentMediaTime(), from: nil) + 0.18
        draw.duration = 0.28
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        tick.add(draw, forKey: "flourish.tick")
    }

    private func relive(force: Bool = false) {
        let wanted = laid.width > 0 && AgentCharacter.loops(mood, reduced: Motion.reduced, lowPower: lowPower, window: windowShown,
                                                            column: columnShown, scrolled: inView)
        let key = (mood: mood, seed: seed, size: laid)
        if wanted, looping, !force, let loopsFor, loopsFor == key { return }
        if !wanted, !looping { return }
        for layer in [life, scan] + eyes {
            for name in layer.animationKeys() ?? [] where name.hasPrefix("loop.") { layer.removeAnimation(forKey: name) }
        }
        looping = wanted
        loopsFor = wanted ? key : nil
        guard wanted else { return }
        let unit = AgentCharacter.pose(AgentCharacter.Frame(), size: laid).unit
        for (index, track) in AgentCharacter.tracks(mood, seed: seed).enumerated() {
            switch track.part {
            case .squash:
                loop(track, on: life, "transform.scale.y", "loop.\(index).y") { 1 - $0 }
                loop(track, on: life, "transform.scale.x", "loop.\(index).x") { 1 + $0 * 0.6 }
            case .tilt: loop(track, on: life, "transform.rotation.z", "loop.\(index)") { $0 }
            case .nod: loop(track, on: life, "transform.translation.y", "loop.\(index)") { $0 * unit }
            case .lookX: loop(track, on: scan, "transform.translation.x", "loop.\(index)") { $0 * unit }
            case .blink: for eye in eyes { loop(track, on: eye, "transform.scale.y", "loop.\(index)") { $0 } }
            }
        }
    }

    private func loop(_ track: AgentCharacter.Track, on layer: CALayer, _ keyPath: String, _ name: String, _ value: (CGFloat) -> CGFloat) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = track.values.map { NSNumber(value: Double(value($0))) }
        animation.keyTimes = track.times.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(0, track.times.count - 1))
        animation.duration = track.period
        animation.repeatCount = .infinity
        animation.timeOffset = track.offset.truncatingRemainder(dividingBy: track.period)
        layer.add(animation, forKey: name)
    }

    private func recolour(animated: Bool) {
        let resolved = ink.color(colour, KitColor.kind(of: colour), dark: kitDark)
        let line = resolved.cgColor
        let fill = resolved.withAlphaComponent(resolved.alphaComponent * 0.16).cgColor
        let curve: KitCurve = animated && onScreen && !Motion.reduced ? .easeOut(0.3) : .none
        head.kitAnimate("backgroundColor", to: fill, curve: curve)
        head.kitAnimate("borderColor", to: line, curve: curve)
        for eye in eyes { eye.kitAnimate("backgroundColor", to: line, curve: curve) }
        for part in arcs + brows { part.kitAnimate("strokeColor", to: line, curve: curve) }
        badge.kitAnimate("fillColor", to: line, curve: curve)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tick.strokeColor = NSColor.white.cgColor
        CATransaction.commit()
    }
}

extension AgentCharacter {
    @MainActor static func surface(lift: Double) -> NSView {
        let moods: [Mood] = [.idle, .driving, .done, .failed]
        let row = KitFlippedView()
        var x: CGFloat = 4
        for (index, mood) in moods.enumerated() {
            let face = AgentCharacterFace()
            face.mood = mood
            face.seed = UInt64(index * 7919)
            face.colour = index == 0 ? KitColor.ink : accentColor(index)
            face.ink = KitInk(lift: lift)
            let side: CGFloat = index == 3 ? 40 : 22
            face.frame = NSRect(x: x, y: 4 + (40 - side) / 2, width: side, height: side)
            row.addSubview(face)
            x += side + 10
        }
        return BenchFloating.sized(row, NSSize(width: x - 10 + 4, height: 48))
    }
}

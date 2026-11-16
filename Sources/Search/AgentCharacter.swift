import AppKit
import Observation

enum AgentCharacter {
    enum Mood: String, CaseIterable {
        case idle, reading, typing, waving, driving, done, failed

        var title: String {
            switch self {
            case .idle: return "Waiting"
            case .reading: return "Reading"
            case .typing: return "Typing"
            case .waving: return "Needs you"
            case .driving: return "You're driving"
            case .done: return "Done"
            case .failed: return "Couldn't finish"
            }
        }

        var moves: Bool { self == .reading || self == .typing || self == .waving }

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

    struct Frame: Equatable {
        var look = CGPoint.zero
        var open: CGFloat = 1
        var nod: CGFloat = 0
        var tilt: CGFloat = 0
        var squash: CGFloat = 0
        var peer: CGFloat = 0
        var happy = false
        var sad = false
        var tick = false
    }

    static let rate: Double = 15

    static func animates(_ mood: Mood, reduced: Bool, lowPower: Bool) -> Bool {
        mood.moves && !reduced && !lowPower
    }

    static func ticks(moving: Bool, window: Bool, column: Bool, scrolled: Bool) -> Bool {
        moving && window && column && scrolled
    }

    static func still(_ mood: Mood) -> Frame {
        var frame = Frame()
        switch mood {
        case .idle: break
        case .reading:
            frame.look = CGPoint(x: scan(at: 0), y: 0)
            frame.tilt = lean(scan(at: 0))
        case .typing: frame.look = CGPoint(x: 0, y: 0.1)
        case .waving:
            frame.look = CGPoint(x: 0.03, y: -0.13)
            frame.tilt = askTilt
            frame.peer = 0.25
        case .driving: frame.look = CGPoint(x: 0.1, y: -0.07)
        case .done:
            frame.happy = true
            frame.tick = true
        case .failed:
            frame.look = CGPoint(x: 0, y: 0.12)
            frame.sad = true
            frame.squash = 0.07
            frame.nod = 0.02
            frame.tilt = -0.06
        }
        return frame
    }

    static func frame(_ mood: Mood, at time: TimeInterval, seed: UInt64) -> Frame {
        var frame = still(mood)
        guard mood.moves else { return frame }
        frame.open = openness(at: time, seed: seed)
        switch mood {
        case .reading:
            frame.look.x = scan(at: time + phase(seed) * 2.4)
            frame.tilt = lean(frame.look.x)
        case .typing:
            let beat = (time * 6).truncatingRemainder(dividingBy: 1)
            frame.nod = beat < 0.35 ? CGFloat(sin(beat / 0.35 * .pi)) * 0.04 : 0
        case .waving:
            let body = ask(at: time + phase(seed) * 1.8)
            frame.nod = body.nod
            frame.squash = body.squash
            frame.tilt = body.tilt
            frame.look.x = body.tilt * 0.25
            frame.look.y += body.nod * 0.17
            if body.still { frame.open = 1 }
        default: break
        }
        return frame
    }

    static func lean(_ look: CGFloat) -> CGFloat { look * 0.5 }

    static let askCycle: TimeInterval = 3
    static let askTilt: CGFloat = 0.12
    static let hop: [(nod: CGFloat, squash: CGFloat)] = [
        (0, 0.08), (-0.04, -0.03), (-0.08, -0.04), (-0.09, -0.04), (-0.08, -0.03), (-0.04, 0), (0, 0.1), (0, 0.04), (0, 0)
    ]

    static func ask(at time: TimeInterval) -> (nod: CGFloat, squash: CGFloat, tilt: CGFloat, still: Bool) {
        let length = Int((askCycle * rate).rounded())
        let tick = (Int((time * rate).rounded(.down)) + 14) % (length * 2)
        let side: CGFloat = tick < length ? 1 : -1
        let index = tick % length
        let body = index < hop.count ? hop[index] : (nod: CGFloat(0), squash: CGFloat(0))
        let land = 6, settled = 13
        let tilt: CGFloat
        if index < land {
            let p = CGFloat(index) / CGFloat(land)
            tilt = -side * askTilt * (1 - p * p)
        } else if index < settled {
            let p = CGFloat(index - land) / CGFloat(settled - land)
            tilt = side * askTilt * (1 - (1 - p) * (1 - p))
        } else {
            tilt = side * askTilt
        }
        return (body.nod, body.squash, tilt, index < hop.count || index >= length - 2)
    }

    static func arrival(from old: Mood, to mood: Mood) -> [Frame]? {
        let working: Set<Mood> = [.reading, .typing, .waving, .driving]
        guard working.contains(old), mood == .done || mood == .failed else { return nil }
        let end = still(mood)
        if mood == .done {
            let bounce: [(CGFloat, CGFloat)] = [(0, 0.07), (-0.03, -0.03), (-0.07, -0.04), (-0.1, -0.04), (-0.08, -0.03), (-0.04, 0), (0, 0.08), (0, 0.03), (0, 0)]
            return bounce.enumerated().map { index, step in
                var frame = end
                frame.nod = step.0
                frame.squash = step.1
                frame.tick = index >= 6
                return frame
            }
        }
        return [CGFloat(0), 0.05, 0.18, 0.42, 0.75, 0.95, 1].map { sag in
            var frame = end
            frame.squash = end.squash * sag
            frame.nod = end.nod * sag
            frame.tilt = end.tilt * sag
            return frame
        }
    }

    static func scan(at time: TimeInterval) -> CGFloat {
        let cycle = 2.4
        let t = time.truncatingRemainder(dividingBy: cycle)
        let stops: [CGFloat] = [-0.09, -0.03, 0.03, 0.09]
        if t < 2.0 { return stops[min(Int(t / 0.5), 3)] }
        let back = (t - 2.0) / 0.4
        return 0.09 - CGFloat(back) * 0.18
    }

    static func blinkPeriod(_ seed: UInt64) -> TimeInterval {
        3 + Double(seed % 3001) / 1000
    }

    static func phase(_ seed: UInt64) -> Double {
        Double((seed >> 16) % 1000) / 1000
    }

    static func openness(at time: TimeInterval, seed: UInt64) -> CGFloat {
        let period = blinkPeriod(seed)
        let t = (time + phase(seed) * period).truncatingRemainder(dividingBy: period)
        let length = 0.16
        guard t < length else { return 1 }
        let half = length / 2
        let shut = t < half ? t / half : (length - t) / half
        return max(0.08, 1 - CGFloat(shut))
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

    struct Parts {
        var head: CGRect
        var radius: CGFloat
        var eyes: CGPath
        var eyesStroked: Bool
        var brows: CGPath?
        var pose: CGAffineTransform
        var badge: CGPath?
        var tick: CGPath?
        var line: CGFloat
        var tickLine: CGFloat
    }

    static func parts(_ frame: Frame, size: CGSize) -> Parts {
        let unit = min(size.width, size.height)
        let line = max(1, (unit * 0.17).rounded() / 2)
        let face = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
        let side = unit * 0.78
        let head = CGRect(x: -side / 2, y: -side / 2 + unit * 0.04, width: side, height: side)
        let pose = CGAffineTransform(translationX: 0, y: -head.maxY)
            .concatenating(CGAffineTransform(scaleX: 1 + frame.squash * 0.6, y: 1 - frame.squash))
            .concatenating(CGAffineTransform(translationX: 0, y: head.maxY - head.midY))
            .concatenating(CGAffineTransform(rotationAngle: frame.tilt))
            .concatenating(CGAffineTransform(translationX: 0, y: head.midY + frame.nod * unit))
        let headRect = head.applying(face)
        let eyeY = head.midY - unit * 0.02 + frame.look.y * unit
        let gap = unit * 0.15
        let inner = head.insetBy(dx: line / 2 + unit * 0.05, dy: line / 2 + unit * 0.05)
        let eyes = CGMutablePath()
        let brows = CGMutablePath()
        for side in [CGFloat(-1), 1] {
            let x = side * gap + frame.look.x * unit
            if frame.happy {
                let centre = CGPoint(x: x, y: eyeY + unit * 0.04)
                let start = 200 * CGFloat.pi / 180
                eyes.move(to: CGPoint(x: centre.x + cos(start) * unit * 0.075, y: centre.y + sin(start) * unit * 0.075), transform: face)
                eyes.addArc(center: centre, radius: unit * 0.075,
                            startAngle: 200 * .pi / 180, endAngle: 340 * .pi / 180, clockwise: false, transform: face)
                continue
            }
            let width = unit * 0.12
            let open = max(unit * 0.03, unit * 0.24 * frame.open)
            let raised = frame.peer * min(1, max(0, -side * frame.tilt) / askTilt)
            let height = open * (1 + raised)
            var eye = CGRect(x: x - width / 2, y: eyeY + open / 2 - height, width: width, height: height)
            eye.origin.x = min(max(eye.minX, inner.minX), inner.maxX - eye.width)
            eye.origin.y = min(max(eye.minY, inner.minY), inner.maxY - eye.height)
            let radius = min(width / 2, height / 2)
            eyes.addPath(CGPath(roundedRect: eye, cornerWidth: radius, cornerHeight: radius, transform: nil), transform: face)
            if frame.sad {
                brows.move(to: CGPoint(x: x - side * unit * 0.07, y: eyeY - unit * 0.2), transform: face)
                brows.addLine(to: CGPoint(x: x + side * unit * 0.07, y: eyeY - unit * 0.15), transform: face)
            }
        }
        var parts = Parts(head: headRect, radius: side * 0.42, eyes: eyes, eyesStroked: frame.happy, brows: frame.sad ? brows : nil,
                          pose: pose, line: line, tickLine: max(1, unit * 0.06))
        if frame.tick {
            let badge = CGRect(x: head.maxX - unit * 0.24, y: head.maxY - unit * 0.24, width: unit * 0.3, height: unit * 0.3)
            parts.badge = CGPath(ellipseIn: badge, transform: [face])
            let tick = CGMutablePath()
            tick.move(to: CGPoint(x: badge.minX + badge.width * 0.27, y: badge.midY), transform: face)
            tick.addLine(to: CGPoint(x: badge.minX + badge.width * 0.45, y: badge.minY + badge.height * 0.7), transform: face)
            tick.addLine(to: CGPoint(x: badge.minX + badge.width * 0.75, y: badge.minY + badge.height * 0.32), transform: face)
            parts.tick = tick
        }
        return parts
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
            clock = Date.timeIntervalSinceReferenceDate
            arrive(from: oldValue)
            needsLayout = true
        }
    }
    var colour: NSColor = KitColor.ink { didSet { if colour != oldValue { needsLayout = true } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsLayout = true } } }
    var seed: UInt64 = 0
    var columnShown = true { didSet { if columnShown != oldValue { needsLayout = true } } }
    var inView = true { didSet { if inView != oldValue { needsLayout = true } } }

    private let body = CALayer()
    private let head = CALayer()
    private let eyes = CAShapeLayer()
    private let brows = CAShapeLayer()
    private let badge = CAShapeLayer()
    private let tick = CAShapeLayer()
    private let shown = KitWindowShown()
    private var timer: Timer?
    private var clock: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        head.cornerCurve = .continuous
        layer?.addSublayer(body)
        body.addSublayer(head)
        for part in [eyes, brows, badge, tick] {
            part.lineCap = .round
            part.lineJoin = .round
            part.contentsScale = 2
            body.addSublayer(part)
        }
        shown.changed = { [weak self] _ in self?.needsLayout = true }
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
        for part in [eyes, brows, badge, tick] { part.contentsScale = scale }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    var moving: Bool {
        AgentCharacter.animates(mood, reduced: Motion.reduced, lowPower: LowPowerWatch.shared.on || Motion.light)
    }

    private func arrive(from old: AgentCharacter.Mood) {
        body.removeAnimation(forKey: "arrival")
        guard window != nil, shown.shown, columnShown, inView, bounds.width > 0,
              !Motion.reduced, !LowPowerWatch.shared.on, !Motion.light,
              let frames = AgentCharacter.arrival(from: old, to: mood) else { return }
        let poses = frames.map { CATransform3DMakeAffineTransform(AgentCharacter.parts($0, size: bounds.size).pose) }
        let arrival = CAKeyframeAnimation(keyPath: "transform")
        arrival.values = poses.map { NSValue(caTransform3D: $0) }
        arrival.calculationMode = .discrete
        arrival.duration = Double(poses.count) / AgentCharacter.rate
        body.add(arrival, forKey: "arrival")
    }

    var ticking: Bool { AgentCharacter.ticks(moving: moving, window: shown.shown, column: columnShown, scrolled: inView) }

    override func layout() {
        super.layout()
        paint()
        let wanted = ticking
        guard wanted != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard wanted else { return }
        clock = Date.timeIntervalSinceReferenceDate
        let made = Timer(timeInterval: 1 / AgentCharacter.rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.paint() }
        }
        made.tolerance = 0.01
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private func paint() {
        paint(moving && timer != nil ? AgentCharacter.frame(mood, at: Date.timeIntervalSinceReferenceDate - clock, seed: seed) : AgentCharacter.still(mood))
    }

    func paint(_ frame: AgentCharacter.Frame) {
        let parts = AgentCharacter.parts(frame, size: bounds.size)
        let resolved = self.ink.color(colour, KitColor.kind(of: colour), dark: kitDark)
        let ink = resolved.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.setAffineTransform(.identity)
        body.frame = bounds
        body.setAffineTransform(parts.pose)
        for part in [eyes, brows, badge, tick] { part.frame = body.bounds }
        head.frame = parts.head.insetBy(dx: -parts.line / 2, dy: -parts.line / 2)
        head.cornerRadius = parts.radius + parts.line / 2
        head.backgroundColor = resolved.withAlphaComponent(resolved.alphaComponent * 0.16).cgColor
        head.borderColor = ink
        head.borderWidth = parts.line
        eyes.path = parts.eyes
        eyes.fillColor = parts.eyesStroked ? nil : ink
        eyes.strokeColor = parts.eyesStroked ? ink : nil
        eyes.lineWidth = parts.line
        brows.path = parts.brows
        brows.fillColor = nil
        brows.strokeColor = ink
        brows.lineWidth = parts.line * 0.8
        badge.path = parts.badge
        badge.fillColor = ink
        tick.path = parts.tick
        tick.fillColor = nil
        tick.strokeColor = NSColor.white.cgColor
        tick.lineWidth = parts.tickLine
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

import AppKit
import QuartzCore

enum RideClip: Equatable {
    case none
    case sides
    case card(corner: CGFloat, above: CGFloat)
    case round(CGFloat)
}

enum RideFade: Equatable {
    case none
    case out
    case `in`
}

struct RideLook: Equatable {
    var here: Int
    var span: CGFloat? = nil
    var clip: RideClip = .sides
    var band = true
    var hits = true
    var lane: CGFloat = 0
    var fade: RideFade = .none
    var seen = false
    var own = false
}

@MainActor
protocol SpaceRiding: AnyObject {
    func ride(_ offset: CGFloat, width: CGFloat)
    func spring(_ spring: RideSpring)
    func hold()
    func letGo()
    var shown: CGFloat? { get }
}

struct RideSpring {
    let from: CGFloat
    let to: CGFloat
    let velocity: CGFloat
    let rate: CGFloat
    let began: CFTimeInterval
    let width: CGFloat
    let base: CGFloat

    static let within: CGFloat = 0.5

    static func hurry(_ distance: CGFloat, reach: CGFloat) -> CGFloat {
        guard reach > 1, distance > within else { return 1 }
        return settles(distance * reach) / settles(distance)
    }

    static func settles(_ distance: CGFloat) -> CGFloat {
        guard distance > within else { return 0 }
        let left = within / distance
        var u = -log(left)
        for _ in 0..<12 {
            let fall = exp(-u)
            let step = ((1 + u) * fall - left) / (-u * fall)
            u -= step
            if abs(step) < 1e-6 { break }
        }
        return u
    }
}

final class RideView: NSView, SpaceRiding {
    let content: NSView
    private weak var motion: SpaceMotion?
    private var look: RideLook?
    private var holding = false
    private var springing = false
    private let edge = CALayer()
    private let face = CALayer()
    private let brim = CALayer()
    private var shaped: (CGSize, RideClip)?
    private var aim: CGFloat = 0
    var limits: (() -> ClosedRange<CGFloat>)?
    private var pace = CGFloat(2 * Double.pi / Motion.spaceResponse)
    private static let path = "transform.translation.x"
    private static let key = "space"
    private static let fadeKey = "spaceFade"
    private static let catchKey = "spaceCatch"
    private var eased: (gap: CGFloat, began: CFTimeInterval, pace: CGFloat)?

    init(content: NSView, motion: SpaceMotion) {
        self.content = content
        self.motion = motion
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        content.wantsLayer = true
        content.clipsToBounds = false
        addSubview(content)
        for part in [face, brim] {
            part.backgroundColor = NSColor.black.cgColor
            part.cornerCurve = .continuous
            edge.addSublayer(part)
        }
        motion.riders.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if content.frame != bounds {
            content.frame = bounds
            if !springing, !holding, let motion { place(motion.offset, width: motion.width) }
        }
        shape()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { needsDisplay = true }
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        guard let layer = content.layer, layer.value(forKeyPath: Self.path) as? CGFloat != aim else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(aim, forKeyPath: Self.path)
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard look?.hits ?? true else { return nil }
        return super.hitTest(point)
    }

    func set(_ look: RideLook) {
        let old = self.look
        self.look = look
        shape()
        guard old != look || holding, let motion else { return }
        let moved = old.map { $0.here != look.here } ?? false
        let wasHolding = holding
        holding = false
        if springing, !moved, !wasHolding, old?.span == look.span, old?.lane == look.lane, old?.fade == look.fade { return }
        place(motion.offset, width: motion.width)
    }

    private func reach(_ width: CGFloat) -> CGFloat {
        guard let look, width > 0, look.band || limits != nil || motion?.alone != true else { return 0 }
        return (look.span ?? (look.own ? bounds.width : width)) / width
    }

    private func travel(_ offset: CGFloat, base: CGFloat, reach: CGFloat) -> CGFloat {
        let x = origin(offset, base: base) * reach
        guard let limits, reach > 0 else { return x }
        let range = limits()
        return min(max(x, range.lowerBound * bounds.width), range.upperBound * bounds.width)
    }

    private func origin(_ offset: CGFloat, base: CGFloat) -> CGFloat {
        look?.seen == true ? offset - base : offset
    }

    private func alpha(_ offset: CGFloat, base: CGFloat, width: CGFloat) -> Swift.Float {
        guard let look, look.fade != .none, width > 0 else { return 1 }
        let share = min(1, max(0, abs(offset - base) / width))
        return Swift.Float(look.fade == .in ? share : 1 - share)
    }

    private func pixel(_ x: CGFloat) -> CGFloat {
        let scale = window?.backingScaleFactor ?? 2
        return (x * scale).rounded() / scale
    }

    private func lag() -> CGFloat {
        guard let eased else { return 0 }
        let turn = max(0, CACurrentMediaTime() - eased.began) * eased.pace
        let left = eased.gap * (1 + turn) * exp(-turn)
        return abs(left) > RideSpring.within ? left : 0
    }

    private func room() -> ClosedRange<CGFloat>? {
        guard let limits else { return nil }
        let range = limits(), lanes = (look?.lane ?? 0) * bounds.width
        return (range.lowerBound * bounds.width + lanes)...(range.upperBound * bounds.width + lanes)
    }

    private func held(_ x: CGFloat) -> CGFloat {
        guard let room = room() else { return x }
        return min(max(x, room.lowerBound), room.upperBound)
    }

    private func place(_ offset: CGFloat, width: CGFloat) {
        guard let layer = content.layer else { return }
        let base = motion?.base ?? 0
        let lanes = (look?.lane ?? 0) * bounds.width
        let was = springing ? presented(layer) : nil
        let lag = was == nil && limits != nil ? lag() : 0
        springing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.key)
        layer.removeAnimation(forKey: Self.fadeKey)
        aim = pixel(travel(offset, base: base, reach: reach(width)) + lanes)
        layer.setValue(aim, forKeyPath: Self.path)
        layer.opacity = alpha(offset, base: base, width: width)
        if let was {
            ease(layer, from: held(was), onto: aim)
        } else if lag != 0 {
            let shown = aim + lag, kept = held(shown)
            if abs(kept - shown) > 0.01 {
                layer.removeAnimation(forKey: Self.catchKey)
                ease(layer, from: kept, onto: aim)
            }
        }
        CATransaction.commit()
    }

    private func presented(_ layer: CALayer) -> CGFloat {
        layer.presentation()?.value(forKeyPath: Self.path) as? CGFloat ?? layer.value(forKeyPath: Self.path) as? CGFloat ?? aim
    }

    private func ease(_ layer: CALayer, from was: CGFloat, onto aim: CGFloat) {
        let gap = was - aim
        eased = nil
        guard abs(gap) > RideSpring.within, let motion, reach(motion.width) > 1 else { return }
        let animation = CASpringAnimation(keyPath: Self.path)
        animation.mass = 1
        animation.stiffness = pace * pace
        animation.damping = 2 * pace
        animation.fromValue = gap
        animation.toValue = 0
        animation.isAdditive = true
        animation.duration = animation.settlingDuration
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        layer.add(animation, forKey: Self.catchKey)
        eased = (gap, CACurrentMediaTime(), pace)
    }

    func ride(_ offset: CGFloat, width: CGFloat) {
        guard !holding else { return }
        place(offset, width: width)
    }

    func hold() {
        guard let layer = content.layer else { return }
        let x = layer.presentation()?.value(forKeyPath: Self.path) as? CGFloat
            ?? layer.value(forKeyPath: Self.path) as? CGFloat ?? 0
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        holding = true
        springing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.key)
        layer.removeAnimation(forKey: Self.fadeKey)
        layer.removeAnimation(forKey: Self.catchKey)
        eased = nil
        aim = x
        layer.setValue(x, forKeyPath: Self.path)
        layer.opacity = opacity
        CATransaction.commit()
    }

    func letGo() {
        guard holding, let motion else { return }
        holding = false
        place(motion.offset, width: motion.width)
    }

    var shown: CGFloat? {
        guard let layer = content.layer, let motion, reach(motion.width) > 0, reach(motion.width) <= 1, look?.seen != true else { return nil }
        let x = layer.presentation()?.value(forKeyPath: Self.path) as? CGFloat
            ?? layer.value(forKeyPath: Self.path) as? CGFloat ?? 0
        return (x - (look?.lane ?? 0) * bounds.width) / reach(motion.width)
    }

    func spring(_ spring: RideSpring) {
        guard !holding, let layer = content.layer else { return }
        let scale = reach(spring.width)
        let shift = (look?.lane ?? 0) * bounds.width
        let from = travel(spring.from, base: spring.base, reach: scale) + shift
        let to = travel(spring.to, base: spring.base, reach: scale) + shift
        let fadeFrom = alpha(spring.from, base: spring.base, width: spring.width)
        let fadeTo = alpha(spring.to, base: spring.base, width: spring.width)
        let limited = limits != nil
        let lag = limited && !springing ? lag() : 0
        let was = springing ? presented(layer) : lag != 0 ? aim + lag : nil
        let start = limited ? held(was ?? from) : from
        pace = spring.rate * RideSpring.hurry(abs(spring.to - spring.from), reach: scale)
        var relative = spring.velocity / (spring.to - spring.from)
        if limited {
            relative = abs(to - start) > 0.25 ? min(spring.velocity * scale / (to - start), pace) : 0
            if let room = room(), start <= room.lowerBound + 0.5 || start >= room.upperBound - 0.5 { relative = max(0, relative) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.key)
        layer.removeAnimation(forKey: Self.fadeKey)
        if limited {
            layer.removeAnimation(forKey: Self.catchKey)
            eased = nil
        }
        aim = to
        layer.setValue(to, forKeyPath: Self.path)
        layer.opacity = fadeTo
        springing = false
        if abs(to - start) > 0.25 {
            layer.add(Self.animation(Self.path, from: start, to: to, spring: spring, rate: pace, relative: relative, layer: layer), forKey: Self.key)
            springing = true
        }
        if abs(fadeTo - fadeFrom) > 0.004 {
            layer.add(Self.animation("opacity", from: fadeFrom, to: fadeTo, spring: spring, rate: pace, relative: relative, layer: layer), forKey: Self.fadeKey)
            springing = true
        }
        if !limited, let was { ease(layer, from: was, onto: from) }
        CATransaction.commit()
    }

    private static func animation(_ path: String, from: Any, to: Any, spring: RideSpring, rate: CGFloat, relative: CGFloat, layer: CALayer) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: path)
        animation.mass = 1
        animation.stiffness = rate * rate
        animation.damping = 2 * rate
        animation.initialVelocity = relative.isFinite ? relative : 0
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        animation.beginTime = layer.convertTime(spring.began, from: nil)
        animation.fillMode = .backwards
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        return animation
    }

    private func shape() {
        guard let layer else { return }
        let size = bounds.size
        let clip = look?.clip ?? .sides
        if let shaped, shaped.0 == size, shaped.1 == clip { return }
        shaped = (size, clip)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard clip != .none else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        edge.frame = CGRect(x: -4000, y: -4000, width: size.width + 8000, height: size.height + 8000)
        let inside = CGRect(origin: .zero, size: size).offsetBy(dx: 4000, dy: 4000)
        brim.isHidden = true
        switch clip {
        case .none:
            break
        case .sides:
            face.frame = CGRect(x: inside.minX, y: 0, width: size.width, height: size.height + 8000)
            face.cornerRadius = 0
        case .card(let corner, let above):
            face.frame = inside
            face.cornerRadius = max(0, min(corner, size.width / 2, size.height / 2))
            if above > 0 {
                brim.isHidden = false
                brim.frame = CGRect(x: inside.minX, y: isFlipped ? inside.minY - above : inside.maxY, width: size.width, height: above)
            }
        case .round(let corner):
            face.frame = inside
            face.cornerRadius = max(0, min(corner, size.width / 2, size.height / 2))
        }
        if layer.mask !== edge { layer.mask = edge }
    }
}

extension NSView {
    func setLane(_ frame: NSRect, shift: CGFloat) {
        if self.frame != frame { self.frame = frame }
        wantsLayer = true
        guard let layer else { return }
        let moved = CATransform3DMakeTranslation(shift, 0, 0)
        guard !CATransform3DEqualToTransform(layer.sublayerTransform, moved) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = moved
        CATransaction.commit()
    }
}

extension RideView {
    static func report(in root: NSView) -> [[String: Any]] {
        root.kitSubviews(of: RideView.self).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ride in
            guard let motion = ride.motion, let layer = ride.content.layer else { return nil }
            let reach = ride.reach(motion.width)
            guard reach > 0 else { return nil }
            return ["width": Double(ride.bounds.width), "reach": Double(reach), "x": Double(ride.presented(layer)), "aim": Double(ride.aim)]
        }
    }
}

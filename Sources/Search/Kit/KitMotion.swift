import AppKit
import QuartzCore

struct KitSpring: Equatable {
    let response: Double
    let damping: Double

    var stiffness: Double { pow(2 * .pi / response, 2) }
    var dampingCoefficient: Double { 4 * .pi * damping / response }

    func animation(_ keyPath: String, from: Any?, to: Any?, velocity: Double = 0) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = stiffness
        spring.damping = dampingCoefficient
        spring.initialVelocity = velocity
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        return spring
    }

    static let glide = KitSpring(response: 0.18, damping: 1)
    static let settle = KitSpring(response: 0.16, damping: 1)
    static let roll = KitSpring(response: 0.3, damping: 1)
    static let cover = KitSpring(response: 0.3, damping: 1)
}

enum KitCurve: Equatable {
    case none
    case spring(KitSpring)
    case easeOut(Double)
    case easeInOut(Double)

    var animates: Bool { self != .none }

    func animation(_ keyPath: String, from: Any?, to: Any?, velocity: Double = 0) -> CAAnimation? {
        switch self {
        case .none: return nil
        case .spring(let spring): return spring.animation(keyPath, from: from, to: to, velocity: velocity)
        case .easeOut(let duration), .easeInOut(let duration):
            let basic = CABasicAnimation(keyPath: keyPath)
            basic.fromValue = from
            basic.toValue = to
            basic.duration = duration
            basic.timingFunction = CAMediaTimingFunction(name: { if case .easeOut = self { return .easeOut } else { return .easeInEaseOut } }())
            return basic
        }
    }
}

extension Motion {
    static var kitGlide: KitCurve { reduced ? .none : light ? .easeOut(0.16) : .spring(.glide) }
    static var kitSettle: KitCurve { reduced ? .none : light ? .easeOut(0.16) : .spring(.settle) }
    static var kitRoll: KitCurve { reduced ? .none : light ? .easeOut(0.16) : .spring(.roll) }
    static var kitCover: KitCurve { reduced ? .none : light ? .easeOut(0.2) : .spring(.cover) }
    static var kitQuick: KitCurve { reduced ? .none : .easeOut(0.12) }
    static var kitEdge: KitCurve { reduced ? .none : .easeOut(0.18) }
    static var kitSlide: KitCurve { reduced ? .none : .easeOut(pane) }

    static func kitFold(out: Bool) -> KitCurve {
        let fold = fold(out: out)
        return reduced ? .none : .spring(KitSpring(response: fold.response, damping: fold.damping))
    }
}

extension CALayer {
    func kitAnimate(_ keyPath: String, to value: Any?, curve: KitCurve, key: String? = nil) {
        let name = key ?? keyPath
        let from = animation(forKey: name) == nil ? self.value(forKeyPath: keyPath) : (presentation()?.value(forKeyPath: keyPath) ?? self.value(forKeyPath: keyPath))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setValue(value, forKeyPath: keyPath)
        if let animation = curve.animation(keyPath, from: from, to: value) {
            add(animation, forKey: name)
        } else {
            removeAnimation(forKey: name)
        }
        CATransaction.commit()
    }

    func kitTransition(_ curve: KitCurve, type: CATransitionType = .fade, subtype: CATransitionSubtype? = nil) {
        guard curve.animates else { return }
        let transition = CATransition()
        transition.type = type
        transition.subtype = subtype
        switch curve {
        case .spring(let spring): transition.duration = spring.animation("opacity", from: 0, to: 1).settlingDuration
        case .easeOut(let duration), .easeInOut(let duration): transition.duration = duration
        case .none: return
        }
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        add(transition, forKey: kCATransition)
    }
}

extension KitSpring {
    init(_ spring: CASpringAnimation) {
        let omega = (spring.stiffness / max(spring.mass, 0.0001)).squareRoot()
        self.init(response: 2 * .pi / max(omega, 0.0001), damping: spring.damping / (2 * (spring.stiffness * spring.mass).squareRoot()))
    }

    var omega: Double { 2 * .pi / response }

    func progress(_ time: Double, velocity: Double = 0) -> Double {
        guard time > 0 else { return 0 }
        let w = omega
        if damping >= 1 { return 1 - (1 + (w - velocity) * time) * exp(-w * time) }
        let decay = damping * w
        let swing = w * (1 - damping * damping).squareRoot()
        let lean = (velocity - decay) / swing
        return 1 + exp(-decay * time) * (-cos(swing * time) + lean * sin(swing * time))
    }

    func rate(_ time: Double, velocity: Double = 0) -> Double {
        guard time > 0 else { return velocity }
        let w = omega
        if damping >= 1 { return exp(-w * time) * (velocity + w * (w - velocity) * time) }
        let decay = damping * w
        let swing = w * (1 - damping * damping).squareRoot()
        let lean = (velocity - decay) / swing
        return exp(-decay * time) * (velocity * cos(swing * time) + (swing - decay * lean) * sin(swing * time))
    }

    func time(toReach share: Double) -> Double {
        var low = 0.0, high = animation("opacity", from: 0, to: 1).settlingDuration
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if progress(middle) < share { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }
}

enum KitCarry {
    static func components(_ value: Any?) -> [Double]? {
        guard let value = value as? NSValue else { return nil }
        let type = String(cString: value.objCType)
        if !type.hasPrefix("{"), let number = value as? NSNumber { return [number.doubleValue] }
        if type.hasPrefix("{CGPoint") { let p = value.pointValue; return [p.x, p.y].map(Double.init) }
        if type.hasPrefix("{CGSize") { let s = value.sizeValue; return [s.width, s.height].map(Double.init) }
        if type.hasPrefix("{CGRect") { let r = value.rectValue; return [r.minX, r.minY, r.width, r.height].map(Double.init) }
        if type.hasPrefix("{CATransform3D") {
            let m = value.caTransform3DValue
            return [m.m11, m.m12, m.m13, m.m14, m.m21, m.m22, m.m23, m.m24, m.m31, m.m32, m.m33, m.m34, m.m41, m.m42, m.m43, m.m44].map(Double.init)
        }
        return nil
    }

    static func share(_ speed: [Double], from: [Double], to: [Double]) -> Double {
        guard speed.count == from.count, from.count == to.count else { return 0 }
        let ahead = zip(from, to).map { $1 - $0 }
        let length = ahead.reduce(0) { $0 + $1 * $1 }
        guard length > 1e-9 else { return 0 }
        return zip(speed, ahead).reduce(0) { $0 + $1.0 * $1.1 } / length
    }
}

extension CALayer {
    func kitRate(forKey key: String) -> Double? {
        guard let spring = animation(forKey: key) as? CASpringAnimation, !spring.isAdditive else { return nil }
        let elapsed = spring.beginTime > 0 ? max(0, convertTime(CACurrentMediaTime(), from: nil) - spring.beginTime) : 0
        guard elapsed < spring.duration else { return nil }
        return KitSpring(spring).rate(elapsed, velocity: spring.initialVelocity)
    }

    func kitSpeed(forKey key: String) -> [Double]? {
        guard let spring = animation(forKey: key) as? CASpringAnimation, let rate = kitRate(forKey: key),
              let from = KitCarry.components(spring.fromValue), let to = KitCarry.components(spring.toValue), from.count == to.count else { return nil }
        return zip(from, to).map { ($1 - $0) * rate }
    }

    func kitCarry(_ key: String, from: Any?, to: Any?) -> Double {
        guard let speed = kitSpeed(forKey: key), let from = KitCarry.components(from), let to = KitCarry.components(to) else { return 0 }
        return KitCarry.share(speed, from: from, to: to)
    }
}

extension NSView {
    var kitEdgeShown: Bool { !isHidden && (layer?.opacity ?? 1) > 0 }

    func kitEdge(_ shown: Bool) {
        guard kitEdgeShown != shown else { return }
        let curve = Motion.kitEdge
        guard curve.animates, window != nil, let layer else {
            layer?.removeAnimation(forKey: "opacity")
            layer?.opacity = 1
            isHidden = !shown
            return
        }
        if shown {
            if isHidden {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 0
                CATransaction.commit()
                isHidden = false
            }
            layer.kitAnimate("opacity", to: Swift.Float(1), curve: curve)
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let layer = self.layer, layer.opacity == 0 else { return }
                self.isHidden = true
            }
        }
        layer.kitAnimate("opacity", to: Swift.Float(0), curve: curve)
        CATransaction.commit()
    }
}

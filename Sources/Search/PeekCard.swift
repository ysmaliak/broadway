import AppKit

@MainActor
protocol PeekSliding: NSView {
    var shift: CGFloat { get }
}

final class PeekCardView: NSView, PeekSliding {
    let host: NSView
    private var out = false
    private var gone: CGFloat = 0
    private var placed = false
    private var turn = 0
    private var swing: PeekSwing?
    private static var key: String { "peek" }
    private static var path: String { "transform.translation.x" }

    init(host: NSView) {
        self.host = host
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        host.wantsLayer = true
        host.clipsToBounds = false
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if host.frame != bounds { host.frame = bounds }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard out else { return nil }
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    var shift: CGFloat {
        if swing != nil, let shown = host.layer?.presentation()?.value(forKeyPath: Self.path) as? CGFloat {
            return shown
        }
        return out ? 0 : gone
    }

    var isOut: Bool { out }

    func reach(_ gone: CGFloat) {
        self.gone = gone
    }

    @discardableResult
    func place(out: Bool, gone: CGFloat, animated: Bool) -> CAAnimation? {
        self.gone = gone
        guard placed else {
            placed = true
            self.out = out
            host.alphaValue = out ? 1 : 0
            return nil
        }
        guard out != self.out else { return nil }
        self.out = out
        turn += 1
        let now = CACurrentMediaTime()
        guard animated, !Motion.reduced, let layer = host.layer else {
            settle()
            return nil
        }
        let moving = swing.map { $0.state(at: now) }
        let from = moving?.place ?? (out ? gone : 0)
        let to: CGFloat = out ? 0 : gone
        guard abs(to - from) > 0.5 else {
            settle()
            return nil
        }
        let fold = Motion.fold(out: out)
        let speed = moving?.speed ?? 0
        let spring = CASpringAnimation(keyPath: Self.path)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / fold.response, 2)
        spring.damping = 4 * .pi * fold.damping / fold.response
        spring.initialVelocity = speed / (to - from)
        spring.fromValue = from
        spring.toValue = to
        spring.duration = spring.settlingDuration
        spring.fillMode = .forwards
        spring.isRemovedOnCompletion = false
        spring.beginTime = layer.convertTime(now, from: nil)
        swing = PeekSwing(began: now, from: from, to: to, response: fold.response, damping: fold.damping, velocity: speed)
        let mine = turn
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.turn == mine else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.settle()
                CATransaction.commit()
            }
        }
        host.alphaValue = 1
        layer.add(spring, forKey: Self.key)
        CATransaction.commit()
        return spring
    }

    private func settle() {
        swing = nil
        host.layer?.removeAnimation(forKey: Self.key)
        host.alphaValue = out ? 1 : 0
    }
}

private struct PeekSwing {
    let began: CFTimeInterval
    let from: CGFloat
    let to: CGFloat
    let response: Double
    let damping: Double
    let velocity: Double

    func state(at time: CFTimeInterval) -> (place: CGFloat, speed: Double) {
        let t = max(0, time - began)
        let w = 2 * .pi / response
        let x0 = Double(from - to)
        let v0 = velocity
        let x: Double
        let v: Double
        if damping < 1 {
            let sigma = damping * w
            let wd = w * (1 - damping * damping).squareRoot()
            let decay = exp(-sigma * t)
            let a = x0
            let b = (v0 + sigma * a) / wd
            x = decay * (a * cos(wd * t) + b * sin(wd * t))
            v = decay * ((b * wd - sigma * a) * cos(wd * t) - (sigma * b + a * wd) * sin(wd * t))
        } else {
            let decay = exp(-w * t)
            let b = v0 + w * x0
            x = decay * (x0 + b * t)
            v = decay * (b - w * (x0 + b * t))
        }
        return (to + CGFloat(x), v)
    }
}

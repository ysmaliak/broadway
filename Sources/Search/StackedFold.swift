import AppKit
import QuartzCore

struct StackedFold: Equatable {
    var from: CGFloat
    var to: CGFloat
    var velocity: CGFloat
    var began: CFTimeInterval
    var curve: KitCurve

    static func start(folding: Bool, at time: CFTimeInterval, curve: KitCurve) -> StackedFold {
        StackedFold(from: folding ? 1 : 0, to: folding ? 0 : 1, velocity: 0, began: time, curve: curve)
    }

    func turned(folding: Bool, at time: CFTimeInterval, curve: KitCurve) -> StackedFold {
        StackedFold(from: value(at: time), to: folding ? 0 : 1, velocity: rate(at: time), began: time, curve: curve)
    }

    private var distance: CGFloat { to - from }

    func value(at time: CFTimeInterval) -> CGFloat {
        from + distance * share(at: time)
    }

    func share(at time: CFTimeInterval) -> CGFloat {
        let t = max(0, time - began)
        switch curve {
        case .none: return 1
        case .spring(let spring):
            guard abs(distance) > 0.000_1 else { return 1 }
            return CGFloat(spring.progress(t, velocity: Double(velocity / distance)))
        case .easeOut(let duration), .easeInOut(let duration):
            let u = min(1, t / max(duration, 0.001))
            return CGFloat(1 - pow(1 - u, 3))
        }
    }

    func rate(at time: CFTimeInterval) -> CGFloat {
        let t = max(0, time - began)
        switch curve {
        case .none: return 0
        case .spring(let spring):
            guard abs(distance) > 0.000_1 else { return 0 }
            return CGFloat(spring.rate(t, velocity: Double(velocity / distance))) * distance
        case .easeOut(let duration), .easeInOut(let duration):
            let d = max(duration, 0.001)
            let u = min(1, t / d)
            return CGFloat(3 * pow(1 - u, 2) / d) * distance
        }
    }

    func done(at time: CFTimeInterval) -> Bool {
        let t = time - began
        switch curve {
        case .none: return true
        case .spring:
            return t > 0.05 && abs(value(at: time) - to) < 0.001 && abs(rate(at: time)) < 0.02
        case .easeOut(let duration), .easeInOut(let duration):
            return t >= duration
        }
    }

    static func fade(_ open: CGFloat) -> CGFloat {
        min(1, max(0, (open - 0.4) / 0.6))
    }

    static func arrive(_ open: CGFloat) -> CGFloat {
        min(1, max(0, (0.6 - open) / 0.6))
    }

    static var curve: KitCurve { Motion.kitCover }
}

@MainActor
final class StackedFoldMotion: NSObject {
    private(set) var folds: [UUID: StackedFold] = [:]
    private(set) var now: CFTimeInterval = CACurrentMediaTime()
    weak var view: NSView?
    var tick: ((_ ended: Bool) -> Void)?
    private var link: CADisplayLink?
    private var timer: Timer?

    var moving: Bool { !folds.isEmpty }

    func moving(_ id: UUID) -> Bool { folds[id] != nil }

    func openness(_ id: UUID, folded: Bool) -> CGFloat {
        folds[id]?.value(at: now) ?? (folded ? 0 : 1)
    }

    func start(_ id: UUID, folding: Bool, curve: KitCurve = StackedFold.curve) {
        let time = max(CACurrentMediaTime(), now)
        now = time
        guard curve.animates else {
            folds[id] = nil
            return
        }
        folds[id] = folds[id]?.turned(folding: folding, at: time, curve: curve) ?? .start(folding: folding, at: time, curve: curve)
        run()
    }

    func stop(_ id: UUID) {
        folds[id] = nil
    }

    func advance(to time: CFTimeInterval) {
        now = max(now, time)
        var ended = false
        for (id, fold) in folds where fold.done(at: now) {
            folds[id] = nil
            ended = true
        }
        tick?(ended)
        if folds.isEmpty { halt() }
    }

    private func run() {
        guard link == nil, timer == nil else { return }
        if let window = view?.window, window.isVisible, !Store.testing || Store.shownOnScreen {
            let made = window.displayLink(target: self, selector: #selector(frame(_:)))
            made.add(to: .main, forMode: .common)
            link = made
            return
        }
        let made = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(to: CACurrentMediaTime()) }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private func halt() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        advance(to: link.targetTimestamp)
    }
}

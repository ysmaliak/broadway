import AppKit

@MainActor
enum BenchTrackpad {
    static var taken: [String: Int] = [:]

    static func strokes(stops: [Double], hz: Double, speed: Double, momentum: Bool, cancel: Bool) -> [SpaceSwipe.Scroll] {
        var out: [SpaceSwipe.Scroll] = []
        var at = 0.0
        let step = max(0.5, speed / hz)
        for stop in stops {
            var left = stop - at
            while abs(left) > 0.001 {
                let move = left < 0 ? max(left, -step) : min(left, step)
                out.append(SpaceSwipe.Scroll(phase: out.isEmpty ? .began : .changed, dx: move, dy: move * 0.05))
                left -= move
            }
            at = stop
        }
        if out.isEmpty { out.append(SpaceSwipe.Scroll(phase: .began)) }
        out.append(SpaceSwipe.Scroll(phase: cancel ? .cancelled : .ended))
        guard momentum, !cancel else { return out }
        var glide = (out.dropLast().last?.dx ?? 0) * 0.95
        out.append(SpaceSwipe.Scroll(momentum: .began, dx: glide))
        while abs(glide) > 0.4 {
            glide *= 0.9
            out.append(SpaceSwipe.Scroll(momentum: .changed, dx: glide))
        }
        out.append(SpaceSwipe.Scroll(momentum: .ended))
        return out
    }

    static func play(_ browser: Browser, _ request: [String: Any]) {
        let hz = request["hz"] as? Double ?? 120
        let gestures = request["gestures"] as? [[String: Any]] ?? [request]
        var plan: [(at: Double, scroll: SpaceSwipe.Scroll)] = []
        for gesture in gestures {
            let stops = gesture["stops"] as? [Double] ?? [gesture["dx"] as? Double ?? -200]
            let list = strokes(stops: stops, hz: hz, speed: gesture["speed"] as? Double ?? 700,
                               momentum: gesture["momentum"] as? Bool ?? true, cancel: gesture["cancel"] as? Bool ?? false)
            let begins = gesture["at"] as? Double ?? (plan.last.map { $0.at + 1 / hz } ?? 0)
            plan += list.enumerated().map { (begins + Double($0.offset) / hz, $0.element) }
        }
        taken = ["events": plan.count, "taken": 0]
        let start = DispatchTime.now()
        let host = CACurrentMediaTime()
        for step in plan {
            DispatchQueue.main.asyncAfter(deadline: start + step.at) {
                var scroll = step.scroll
                scroll.time = host + step.at
                let took = SpaceSwipe.shared.take(scroll, over: true)
                if took { taken["taken", default: 0] += 1 }
                SwipeTrace.shared.stroke(step.scroll, taken: took)
            }
        }
    }
}

@MainActor
final class SwipeTrace: NSObject {
    static let shared = SwipeTrace()
    private var link: CADisplayLink?
    private weak var browser: Browser?
    private var strokes: [[Double]] = []
    private var frames: [[Double]] = []
    private var bodies: [[String: Any]] = []
    private var counted: [String: Int] = [:]
    private var began: CFTimeInterval = 0

    func start(_ browser: Browser) {
        link?.invalidate()
        link = nil
        self.browser = browser
        strokes = []
        frames = []
        bodies = []
        Bodies.counts = [:]
        Bodies.on = true
        counted = [:]
        began = CACurrentMediaTime()
        guard let window = browser.window else { return }
        let made = window.displayLink(target: self, selector: #selector(tick(_:)))
        made.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        made.add(to: .main, forMode: .common)
        link = made
    }

    private static func code(_ scroll: SpaceSwipe.Scroll) -> Double {
        switch scroll.momentum {
        case .began: return 11
        case .changed: return 12
        case .ended: return 13
        default: break
        }
        switch scroll.phase {
        case .began: return 1
        case .changed: return 2
        case .ended: return 3
        case .cancelled: return 4
        default: return 0
        }
    }

    func stroke(_ scroll: SpaceSwipe.Scroll, taken: Bool) {
        guard link != nil, let browser else { return }
        strokes.append([CACurrentMediaTime(), Double(scroll.dx), Self.code(scroll), taken ? 1 : 0,
                        Double(browser.spaceMotion.offset), Double(browser.spaceNext ?? -1)])
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let browser else { return }
        let here = browser.spaces.firstIndex { $0.id == browser.spaceID } ?? -1
        frames.append([link.timestamp, link.targetTimestamp, CACurrentMediaTime(), Double(browser.spaceMotion.offset),
                       Double(browser.spaceNext ?? -1), Double(here), browser.spaceMotion.moving ? 1 : 0])
        let fresh = Bodies.counts.reduce(into: [String: Int]()) { out, item in
            let more = item.value - (counted[item.key] ?? 0)
            if more > 0 { out[item.key] = more }
        }
        if !fresh.isEmpty { bodies.append(["t": link.timestamp, "n": fresh]) }
        counted = Bodies.counts
    }

    func report() -> [String: Any] {
        link?.invalidate()
        link = nil
        Bodies.on = false
        return ["began": began, "strokes": strokes, "frames": frames, "bodies": bodies,
                "width": Double(browser?.prefs.columnWidth ?? 0)]
    }
}

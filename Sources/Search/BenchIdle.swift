import AppKit

@MainActor
enum Bodies {
    static var on = false
    static var counts: [String: Int] = [:]

    @discardableResult
    static func tick(_ name: String) -> Int {
        guard on else { return 0 }
        counts[name, default: 0] += 1
        return 0
    }
}

@MainActor
enum BenchIdle {
    private static var observer: CFRunLoopObserver?
    private static var wakeups = 0
    private static var began = CACurrentMediaTime()

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "idle only works on a --test run"]) }
        let window = browser.window
        switch request["action"] as? String ?? "report" {
        case "start":
            Bodies.counts = [:]
            Bodies.on = true
            wakeups = 0
            began = CACurrentMediaTime()
            watch()
        case "stop":
            Bodies.on = false
            if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
            observer = nil
        case "front":
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        case "give":
            if let pid = request["pid"] as? Int, let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                app.activate()
            } else {
                NSApp.deactivate()
            }
        case "frames":
            if let window { FrameGaps.shared.start(window) }
        case "gaps":
            return answer(FrameGaps.shared.report())
        case "place":
            guard let window else { return answer(["error": "no window"]) }
            let fastest = NSScreen.screens.max { $0.maximumFramesPerSecond < $1.maximumFramesPerSecond }
            if let fastest {
                let room = fastest.visibleFrame
                let size = NSSize(width: min(window.frame.width, room.width), height: min(window.frame.height, room.height))
                window.setFrame(NSRect(x: room.midX - size.width / 2, y: room.midY - size.height / 2, width: size.width, height: size.height), display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                answer([
                    "screen": window.screen?.localizedName ?? "",
                    "screenHz": window.screen?.maximumFramesPerSecond ?? 0,
                    "frame": NSStringFromRect(window.frame),
                    "screens": NSScreen.screens.map { "\($0.localizedName) \($0.maximumFramesPerSecond)" },
                    "opaque": window.isOpaque,
                    "groundAlpha": Double(window.backgroundColor.alphaComponent),
                    "effects": BenchIdle.effects(in: window.contentView?.superview),
                ])
            }
            return
        case "now":
            return answer(["now": CACurrentMediaTime()])
        case "square":
            guard let window else { return answer(["error": "no window"]) }
            return answer(BenchSquare.run(request, in: window))
        case "hide": NSApp.hide(nil)
        case "unhide": NSApp.unhideWithoutActivation()
        case "mini": window?.miniaturize(nil)
        case "unmini": window?.deminiaturize(nil)
        default: break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            answer(report(window))
        }
    }

    static func effects(in view: NSView?) -> [String: Int] {
        var found: [String: Int] = [:]
        func walk(_ view: NSView) {
            if let effect = view as? NSVisualEffectView, !effect.isHidden {
                found[effect.blendingMode == .behindWindow ? "behindWindow" : "withinWindow", default: 0] += 1
            } else if view is NSGlassEffectView, !view.isHidden {
                found["glass", default: 0] += 1
            }
            view.subviews.forEach(walk)
        }
        if let view { walk(view) }
        return found
    }

    private static func report(_ window: NSWindow?) -> [String: Any] {
        [
            "seconds": CACurrentMediaTime() - began,
            "wakeups": wakeups,
            "bodies": Bodies.counts,
            "active": NSApp.isActive,
            "hidden": NSApp.isHidden,
            "visible": window?.isVisible ?? false,
            "number": window?.windowNumber ?? 0,
            "occluded": !(window?.occlusionState.contains(.visible) ?? false),
            "miniaturized": window?.isMiniaturized ?? false,
        ]
    }

    private static func watch() {
        guard observer == nil else { return }
        let made = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.max) { _, _ in
            MainActor.assumeIsolated { wakeups += 1 }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
        observer = made
    }
}

@MainActor
final class FrameGaps: NSObject {
    static let shared = FrameGaps()
    private var link: CADisplayLink?
    private var stamps: [CFTimeInterval] = []
    private var period: CFTimeInterval = 1.0 / 60
    private var screenHz = 0
    private var began: CFTimeInterval = 0

    private var spans: [CFTimeInterval] = []
    private var spanStarts: [CFTimeInterval] = []
    private var woke: CFTimeInterval?
    private var observer: CFRunLoopObserver?
    private var marks: [(CFTimeInterval, CFTimeInterval, String)] = []
    private(set) var timing = false

    func note(_ name: String, from start: CFTimeInterval) {
        let took = CACurrentMediaTime() - start
        guard timing, took > 0.002 else { return }
        marks.append((start, took, name))
    }

    func start(_ window: NSWindow) {
        link?.invalidate()
        stamps = []
        marks = []
        timing = true
        spans = []
        spanStarts = []
        woke = nil
        screenHz = window.screen?.maximumFramesPerSecond ?? 0
        began = CACurrentMediaTime()
        if observer == nil {
            let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
            let made = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { _, activity in
                MainActor.assumeIsolated { FrameGaps.shared.mark(activity) }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
            observer = made
        }
        let made = window.displayLink(target: self, selector: #selector(tick(_:)))
        made.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        made.add(to: .main, forMode: .common)
        link = made
    }

    private func mark(_ activity: CFRunLoopActivity) {
        let now = CACurrentMediaTime()
        if activity == .afterWaiting {
            woke = now
        } else if let began = woke {
            spans.append(now - began)
            spanStarts.append(began)
            woke = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        period = link.duration > 0 ? link.duration : period
        stamps.append(link.timestamp)
    }

    func report() -> [String: Any] {
        link?.invalidate()
        link = nil
        let gaps = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
        let tick = gaps.isEmpty ? period : max(period, gaps.sorted()[gaps.count / 2])
        let late = gaps.filter { $0 > tick * 1.5 }
        let span = (stamps.last ?? 0) - (stamps.first ?? 0)
        let lost = late.reduce(0) { $0 + ($1 - tick) }
        let budget = 1.0 / 60
        let long = spans.filter { $0 > budget }
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        timing = false
        return [
            "busyMs": (spans.reduce(0, +) * 1000).rounded(),
            "longSpans": long.count,
            "longestMs": ((spans.max() ?? 0) * 1000).rounded(),
            "longMs": long.map { ($0 * 1000).rounded() },
            "hz": (1 / period).rounded(),
            "periodMs": (period * 100_000).rounded() / 100,
            "tickHz": (1 / tick).rounded(),
            "screenHz": screenHz,
            "startHost": began,
            "frames": stamps.count,
            "seconds": span,
            "hitches": late.count,
            "worstMs": ((gaps.max() ?? 0) * 1000).rounded(),
            "hitchMsPerS": span > 0 ? (lost * 1000 / span * 10).rounded() / 10 : 0,
            "gapsMs": late.map { ($0 * 1000).rounded() },
            "spansAt": zip(spanStarts, spans).filter { $0.1 > 0.008 }.map { [(($0.0 - began) * 1000).rounded(), ($0.1 * 1000).rounded()] },
            "marksAt": marks.map { [(($0.0 - began) * 1000).rounded(), ($0.1 * 10000).rounded() / 10, $0.2] as [Any] },
        ]
    }
}

@MainActor
enum BenchSquare {
    static func run(_ request: [String: Any], in window: NSWindow) -> [String: Any] {
        guard let frame = window.contentView?.superview else { return ["error": "no frame view"] }
        let hide = request["hide"] as? [String] ?? []
        var hidden: [NSView] = []
        func walk(_ view: NSView) {
            let name = String(describing: type(of: view))
            if hide.contains(where: { name.contains($0) }), !view.isHidden {
                view.isHidden = true
                hidden.append(view)
                return
            }
            view.subviews.forEach(walk)
        }
        if hide.contains("content"), let content = window.contentView {
            content.isHidden = true
            hidden.append(content)
        } else if let content = window.contentView {
            walk(content)
        }
        let box = NSView(frame: NSRect(x: 20, y: 60, width: 60, height: 60))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.systemRed.cgColor
        frame.addSubview(box)
        let delay = request["delay"] as? Double ?? 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let move = CASpringAnimation(keyPath: "position.x")
            move.fromValue = 50
            move.toValue = 390
            move.mass = 1
            move.stiffness = pow(2 * .pi / 0.6, 2)
            move.damping = 4 * .pi / 0.6
            move.duration = move.settlingDuration
            move.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            box.layer?.position.x = 390
            box.layer?.add(move, forKey: "move")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                box.removeFromSuperview()
                hidden.forEach { $0.isHidden = false }
            }
        }
        return ["hidden": hidden.map { String(describing: type(of: $0)) }]
    }
}

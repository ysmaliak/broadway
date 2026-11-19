import AppKit

@MainActor
final class HelmTrace: NSObject {
    static let shared = HelmTrace()

    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var samples: [[String: Any]] = []
    private weak var browser: Browser?
    private weak var helm: HelmView?
    private var calls: [[String: Any]] = []

    static func note(_ door: NSView, on: Bool, animated: Bool) {
        guard shared.link != nil, let layer = door.layer else { return }
        let running = layer.animation(forKey: "lit") as? CABasicAnimation
        shared.calls.append([
            "t": ((CACurrentMediaTime() - shared.started) * 10000).rounded() / 10,
            "door": (door as? DoorView)?.icon ?? "reload",
            "on": on,
            "animated": animated,
            "shown": Double(layer.presentation()?.opacity ?? -1),
            "model": Double(layer.opacity),
            "runningFrom": (running?.fromValue as? NSNumber)?.doubleValue ?? -1,
            "runningTo": (running?.toValue as? NSNumber)?.doubleValue ?? -1,
            "runningBegin": running.map { $0.beginTime == 0 ? 0 : (($0.beginTime - shared.started) * 10000).rounded() / 10 } ?? -1,
        ])
    }

    static func run(_ ask: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        switch ask["action"] as? String {
        case "start":
            guard let window = browser.window ?? Links.window else { answer(["error": "helmtrace needs a window"]); return }
            guard let helm = helm(in: window) else { answer(["error": "helmtrace found no helm"]); return }
            shared.start(window, helm: helm, browser: browser)
            answer(["ok": true])
        case "stop":
            answer(shared.stop())
        case "read":
            guard let window = browser.window ?? Links.window, let helm = helm(in: window) else { answer(["error": "helmtrace found no helm"]); return }
            answer(read(helm))
        default:
            answer(["error": "helmtrace takes start, stop or read"])
        }
    }

    private static func helm(in window: NSWindow) -> HelmView? {
        guard let root = window.contentView?.superview ?? window.contentView else { return nil }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(root).compactMap { $0 as? HelmView }.first { !$0.isHiddenOrHasHiddenAncestor }
    }

    private static func keys(_ helm: HelmView) -> [(String, NSView)] {
        let doors = helm.kitSubviews(of: DoorView.self)
        var found: [(String, NSView)] = []
        if let back = doors.first(where: { $0.icon == "arrow.left" }) { found.append(("back", back)) }
        if let forward = doors.first(where: { $0.icon == "arrow.right" }) { found.append(("forward", forward)) }
        if let reload = helm.kitSubviews(of: ReloadDoorView.self).first { found.append(("reload", reload)) }
        return found
    }

    private static func read(_ helm: HelmView) -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, view) in keys(helm) {
            guard let layer = view.layer else { continue }
            out[name] = [
                "shown": Double((layer.presentation() ?? layer).opacity),
                "rest": Double(layer.opacity),
                "alpha": Double(view.alphaValue),
                "fading": layer.animation(forKey: "lit") != nil,
            ] as [String: Any]
        }
        if let window = helm.window, let root = window.contentView {
            out["frame"] = NSStringFromRect(helm.convert(helm.bounds, to: root))
            out["flipped"] = root.isFlipped
            out["height"] = Double(root.bounds.height)
        }
        return out
    }

    private func start(_ window: NSWindow, helm: HelmView, browser: Browser) {
        link?.invalidate()
        samples = []
        calls = []
        self.browser = browser
        self.helm = helm
        started = CACurrentMediaTime()
        let made = window.displayLink(target: self, selector: #selector(tick(_:)))
        made.add(to: .main, forMode: .common)
        link = made
        sample()
    }

    @objc private func tick(_ link: CADisplayLink) { sample() }

    private func sample() {
        guard let helm else { return }
        var shot: [String: Any] = ["t": ((CACurrentMediaTime() - started) * 10000).rounded() / 10]
        for (name, view) in Self.keys(helm) {
            guard let layer = view.layer else { continue }
            shot[name] = (Double((layer.presentation() ?? layer).opacity) * 1000).rounded() / 1000
            if let fade = layer.animation(forKey: "lit"), fade.beginTime == 0 { shot["pending"] = true }
            if name == "back" {
                shot["backFades"] = (layer.animationKeys() ?? []).map { key -> String in
                    guard let made = layer.animation(forKey: key) else { return key }
                    let basic = made as? CABasicAnimation
                    let from = (basic?.fromValue as? NSNumber)?.doubleValue ?? -1
                    let to = (basic?.toValue as? NSNumber)?.doubleValue ?? -1
                    let begin = made.beginTime == 0 ? 0 : ((made.beginTime - started) * 10000).rounded() / 10
                    return "\(key):\(basic?.keyPath ?? "?"):\((from * 1000).rounded() / 1000)>\((to * 1000).rounded() / 1000)@\(begin)"
                }
            }
            if name == "back" {
                let now = CACurrentMediaTime()
                shot["backLocal"] = ((layer.convertTime(now, from: nil) - now) * 10000).rounded() / 10
                shot["backKeys"] = (layer.animationKeys() ?? []).map { key -> String in
                    guard let made = layer.animation(forKey: key) else { return key }
                    let basic = made as? CABasicAnimation
                    let from = (basic?.fromValue as? NSNumber)?.doubleValue ?? -1
                    let to = (basic?.toValue as? NSNumber)?.doubleValue ?? -1
                    let begin = made.beginTime == 0 ? 0 : ((made.beginTime - started) * 10000).rounded() / 10
                    return "\(key):\(basic?.keyPath ?? "?"):\((from * 1000).rounded() / 1000)>\((to * 1000).rounded() / 1000)@\(begin)"
                }
            }
        }
        if let browser {
            shot["space"] = browser.space.name
            shot["at"] = browser.spaceAt
            shot["next"] = browser.spaceNext ?? -1
            shot["offset"] = (Double(browser.spaceMotion.offset) * 10).rounded() / 10
            shot["tab"] = browser.shownTab?.title ?? ""
            shot["heading"] = browser.spaceNeighbour.heading ?? -1
            shot["shown"] = browser.spaceShown ?? -1
        }
        samples.append(shot)
    }

    private func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        return ["samples": samples, "calls": calls]
    }
}

import AppKit

@MainActor
final class EndTrace: NSObject {
    static let shared = EndTrace()

    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var samples: [[String: Any]] = []
    private weak var root: NSView?

    static func run(_ ask: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard let window = browser.window ?? Links.window, let root = window.contentView?.superview ?? window.contentView else {
            answer(["error": "endtrace needs a window"]); return
        }
        switch ask["action"] as? String {
        case "start":
            shared.start(window, root: root)
            answer(["ok": true])
        case "stop":
            answer(shared.stop())
        case "now":
            answer(["rows": rows(in: root)])
        case "command":
            let on = ask["on"] as? Bool ?? false
            if on { browser.prefs.showsTabShortcuts = true }
            browser.commandHeld = on
            answer(["ok": true])
        default:
            answer(["error": "endtrace takes start, stop, now or command"])
        }
    }

    static func rows(in root: NSView) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if let row = sub as? TabRowView {
                    if let end = row.benchEnd { found.append(end) }
                } else {
                    walk(sub)
                }
            }
        }
        walk(root)
        return found
    }

    private func start(_ window: NSWindow, root: NSView) {
        link?.invalidate()
        samples = []
        self.root = root
        started = CACurrentMediaTime()
        let made = window.displayLink(target: self, selector: #selector(tick(_:)))
        made.add(to: .main, forMode: .common)
        link = made
        sample()
    }

    @objc private func tick(_ link: CADisplayLink) { sample() }

    private func sample() {
        guard let root else { return }
        samples.append(["t": (CACurrentMediaTime() - started) * 1000, "rows": EndTrace.rows(in: root)])
    }

    private func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        return ["samples": samples]
    }
}

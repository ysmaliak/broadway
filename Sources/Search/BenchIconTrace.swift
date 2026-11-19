import AppKit

@MainActor
final class IconTrace: NSObject {
    static let shared = IconTrace()

    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var samples: [[String: Any]] = []
    private weak var root: NSView?

    static func run(_ ask: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard let window = browser.window, let root = window.contentView?.superview ?? window.contentView else {
            answer(["error": "icontrace needs a window"]); return
        }
        switch ask["action"] as? String {
        case "start":
            shared.start(window, root: root)
            answer(["ok": true])
        case "stop":
            answer(shared.stop())
        case "now":
            answer(["rows": rows(in: root)])
        default:
            answer(["error": "icontrace takes start, stop or now"])
        }
    }

    static func rows(in root: NSView) -> [[String: Any]] {
        var found: [[String: Any]] = []
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                if let row = sub as? TabRowView {
                    guard var read = row.benchIcon, read["seen"] as? Bool == true else { continue }
                    let drawn = TabRowView.iconDrawn(read)
                    guard !drawn else {
                        found.append(["label": read["label"] ?? "", "known": read["known"] ?? false, "drawn": true, "dress": read["dress"] ?? ""])
                        continue
                    }
                    let place = row.convert(row.bounds, to: nil)
                    read["at"] = [Double(place.minX), Double(place.minY)]
                    read["drawn"] = false
                    found.append(read)
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

    func flushed() {
        guard link != nil else { return }
        sample(flush: true)
    }

    private func sample(flush: Bool = false) {
        guard let root else { return }
        samples.append(["t": (CACurrentMediaTime() - started) * 1000, "flush": flush, "rows": IconTrace.rows(in: root)])
    }

    private func stop() -> [String: Any] {
        link?.invalidate()
        link = nil
        return ["samples": samples]
    }
}

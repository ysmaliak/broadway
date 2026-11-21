import AppKit
import QuartzCore

@MainActor
final class PageTrace {
    static let shared = PageTrace()
    private var timer: Timer?
    private var frames: [[String: Any]] = []
    private var began: CFTimeInterval = 0

    func start(_ browser: Browser, seconds: Double) {
        timer?.invalidate()
        frames = []
        began = CACurrentMediaTime()
        let made = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self, weak browser] timer in
            MainActor.assumeIsolated {
                guard let self, let browser, CACurrentMediaTime() - self.began < seconds else {
                    timer.invalidate()
                    return
                }
                self.note(browser)
            }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
        note(browser)
    }

    private func note(_ browser: Browser) {
        guard let content = browser.window?.contentView, let column = content.kitSubviews(of: SideColumnView.self).first else { return }
        var frame = column.benchPages
        frame["t"] = CACurrentMediaTime() - began
        frames.append(frame)
    }

    func report() -> [String: Any] {
        ["frames": frames, "running": timer?.isValid ?? false]
    }
}

import AppKit
import WebKit

@MainActor
enum BenchPull {
    static func disc(in web: PageView) -> GestureDisc? {
        web.subviews.compactMap { $0 as? GestureDisc }.last
    }

    static func look(_ web: PageView) -> [String: Any] {
        CATransaction.flush()
        guard let disc = disc(in: web) else { return ["disc": false] }
        let shown = disc.shown
        return ["disc": true, "top": Double(shown.top), "opacity": Double(shown.opacity), "ring": Double(shown.ring),
                "x": Double(disc.frame.midX), "width": Double(web.bounds.width)]
    }

    static func state(_ web: PageView) -> [String: Any] {
        let refresh = web.refresh
        var out = look(web)
        out["on"] = PullRefresh.on
        out["continues"] = PullRefresh.continues
        out["phase"] = refresh.phase
        out["reloads"] = refresh.reloads
        out["shown"] = refresh.log.shown
        out["peak"] = Double(refresh.log.peak)
        out["armed"] = refresh.log.armed
        out["end"] = refresh.log.end
        out["why"] = refresh.log.why
        out["steps"] = refresh.log.steps
        let log = refresh.log
        func since(_ time: TimeInterval, _ from: TimeInterval) -> Double { time == 0 || from == 0 ? -1 : (time - from) * 1000 }
        out["waits"] = ["moved": since(log.moved, log.began), "top": since(log.top, log.began), "chain": since(log.chain, log.began), "held": since(log.held, log.began)]
        out["discs"] = web.subviews.filter { $0 is GestureDisc }.count
        return out
    }

    static func sample(_ web: PageView, count: Int, every: Double, answer: @escaping ([String: Any]) -> Void) {
        var frames: [[String: Any]] = []
        let started = CACurrentMediaTime()
        func take() {
            var frame = look(web)
            frame["t"] = CACurrentMediaTime() - started
            frame["phase"] = web.refresh.phase
            frames.append(frame)
            guard frames.count < min(600, max(1, count)) else {
                answer(["frames": frames])
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + min(0.5, max(0.004, every))) { take() }
        }
        take()
    }
}

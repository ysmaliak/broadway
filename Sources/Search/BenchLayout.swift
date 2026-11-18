import AppKit

@MainActor
enum BenchLayout {
    static let verbs: Set<String> = ["layoutwatch"]
    private static var windows: [NSWindow] = []

    private final class Ping: NSView {
        var live = false
        var passes = 0

        override func layout() {
            super.layout()
            passes += 1
            if live { superview?.needsLayout = true }
        }
    }

    private final class Pong: NSView {
        let ping = Ping(frame: NSRect(x: 0, y: 0, width: 40, height: 20))

        override func layout() {
            super.layout()
            if ping.live { ping.needsLayout = true }
        }
    }

    static func run(_ verb: String, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "layoutwatch is for test runs"]); return }
        switch request["action"] as? String ?? "list" {
        case "clear":
            LayoutWatch.clear()
            answer(["cleared": true])
        case "fill":
            LayoutWatch.fill(request["count"] as? Int ?? LayoutWatch.kept)
            answer(["kept": LayoutWatch.reports.count])
        case "doors":
            var doors: [FetchDoorView] = []
            func find(_ view: NSView) {
                if let door = view as? FetchDoorView { doors.append(door) }
                view.subviews.forEach(find)
            }
            for window in NSApp.windows { if let top = window.contentView { find(top) } }
            func inCard(_ door: NSView) -> Bool {
                var up = door.superview
                while let view = up {
                    if view is FoldColumnCardView { return true }
                    up = view.superview
                }
                return false
            }
            if let press = request["press"] as? String {
                guard let door = doors.first(where: { inCard($0) == (press == "card") }) else {
                    answer(["error": "no downloads button \(press == "card" ? "on the card" : "in the sidebar")"])
                    return
                }
                door.action?()
            }
            answer(["doors": doors.map { door in
                ["card": inCard(door), "anchor": Browsers.all.contains { $0.downloadsAnchor === door }, "frame": NSStringFromRect(door.doorFrame),
                 "screen": NSStringFromRect(door.window?.convertToScreen(door.convert(door.bounds, to: nil)) ?? .zero)]
            }])
        case "loop":
            let pong = Pong(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            pong.addSubview(pong.ping)
            for _ in 0..<(request["views"] as? Int ?? 0) { pong.addSubview(NSView(frame: .zero)) }
            let window = NSWindow(contentRect: NSRect(x: -24000, y: -24000, width: 200, height: 100), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = pong
            window.benchShowBehind()
            windows.append(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let before = LayoutWatch.made
                pong.ping.live = true
                pong.ping.needsLayout = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let looped = pong.ping.passes
                    pong.ping.live = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                        let settled = pong.ping.passes
                        pong.ping.needsLayout = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let marked = pong.ping.passes
                        window.setContentSize(NSSize(width: 260, height: 140))
                        pong.ping.needsLayout = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            let resized = pong.ping.passes
                            window.orderOut(nil)
                            windows.removeAll { $0 === window }
                            answer(["passes": looped, "laidOutAfter": marked - settled, "laidOutAfterResize": resized - marked,
                                    "reports": LayoutWatch.reports.suffix(LayoutWatch.made - before).map(\.bench)])
                        }
                        }
                    }
                }
            }
        default:
            answer(["reports": LayoutWatch.reports.map(\.bench)])
        }
    }
}

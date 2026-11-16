import AppKit

extension Bench {
    private static var covers: [NSWindow] = []

    func benchSight(_ action: String, _ value: String?, browser: Browser) -> [String: Any] {
        switch action {
        case "sight":
            switch value {
            case "visible": browser.sightForBench = true
            case "hidden": browser.sightForBench = false
            case "front":
                browser.sightForBench = nil
                browser.window?.orderFrontRegardless()
            case "real": browser.sightForBench = nil
            default: break
            }
        case "cover":
            Bench.covers.forEach { $0.orderOut(nil) }
            Bench.covers = []
            if let share = Double(value ?? ""), share > 0, let window = browser.window,
               let box = Bench.coverBox(share, browser: browser, in: window) {
                let cover = NSWindow(contentRect: box, styleMask: [.borderless], backing: .buffered, defer: false)
                cover.isReleasedWhenClosed = false
                cover.backgroundColor = .systemOrange
                cover.isOpaque = true
                cover.hasShadow = false
                cover.level = .normal
                cover.ignoresMouseEvents = true
                cover.setFrame(box, display: true)
                cover.order(.above, relativeTo: window.windowNumber)
                Bench.covers = [cover]
            }
        case "left":
            browser.appLeft()
        case "back":
            browser.appBack()
        default:
            browser.judgeSight()
        }
        return Bench.sightReport(browser)
    }

    private static func coverBox(_ share: Double, browser: Browser, in window: NSWindow) -> NSRect? {
        guard share < 1 else { return window.frame.insetBy(dx: -40, dy: -40) }
        guard let web = browser.active?.web, web.window === window, web.bounds.width > 0 else { return nil }
        let box = window.convertToScreen(web.convert(web.bounds, to: nil))
        return NSRect(x: box.minX, y: box.minY, width: box.width * share, height: box.height)
    }

    static func sightReport(_ browser: Browser) -> [String: Any] {
        let window = browser.window
        return [
            "judged": browser.sightJudged,
            "bench": browser.sightForBench.map { $0 as Any } ?? NSNull(),
            "occlusionVisible": window?.occlusionState.contains(.visible) ?? false,
            "windowVisible": window?.isVisible ?? false,
            "windowNumber": window?.windowNumber ?? 0,
            "covers": covers.map { $0.windowNumber },
            "floating": browser.floater.showing,
            "panel": NSApp.windows.first { "\(type(of: $0))" == "Panel" && $0.isVisible }?.windowNumber ?? 0,
            "active": NSApp.isActive,
            "above": Bench.above(window),
        ]
    }

    private static func above(_ window: NSWindow?) -> [[String: Any]] {
        guard let window, window.windowNumber > 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements],
                                                    CGWindowID(window.windowNumber)) as? [[String: Any]] else { return [] }
        return list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }.map { info in
            [
                "number": info[kCGWindowNumber as String] as? Int ?? 0,
                "pid": info[kCGWindowOwnerPID as String] as? Int ?? 0,
                "bounds": info[kCGWindowBounds as String] ?? NSNull(),
                "alpha": info[kCGWindowAlpha as String] ?? NSNull(),
            ]
        }
    }
}

import AppKit
import WebKit

@MainActor
enum BenchPageClick {
    private static var other: NSPanel?

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "pageclick is for test runs"]); return }
        guard let window = browser.window, let frame = window.contentView?.superview else { answer(["error": "no window"]); return }
        switch request["action"] as? String ?? "hits" {
        case "click":
            click(request, browser: browser, window: window, frame: frame, answer)
        case "firstmouse":
            PageView.webKitDecidesFirstMouse = request["webkit"] as? Bool == true
            answer(["webKitDecides": PageView.webKitDecidesFirstMouse])
        case "resign":
            window.makeFirstResponder(nil)
            answer(state(browser: browser, window: window))
        case "edit":
            browser.edit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { answer(state(browser: browser, window: window)) }
        case "quitfield":
            browser.quitField()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { answer(state(browser: browser, window: window)) }
        case "otherkey":
            other?.close()
            other = nil
            if request["close"] as? Bool != true {
                let panel = NSPanel(contentRect: NSRect(x: window.frame.minX + 40, y: window.frame.minY + 40, width: 200, height: 120),
                                    styleMask: [.titled, .utilityWindow], backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false
                panel.title = "pageclick"
                panel.makeKeyAndOrderFront(nil)
                other = panel
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state(browser: browser, window: window)) }
        case "deactivate":
            NSApp.deactivate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state(browser: browser, window: window)) }
        default:
            answer(hits(request, browser: browser, window: window, frame: frame))
        }
    }

    static func pages(in window: NSWindow, browser: Browser) -> [PageView] {
        let ids = browser.activeSplit?.tabs ?? browser.active.map { [$0.id] } ?? []
        return ids.compactMap { id in browser.tabs.first { $0.id == id }?.built }.filter { page in
            page.window === window && !page.isHiddenOrHasHiddenAncestor
        }
    }

    static func chain(_ view: NSView?) -> String {
        var names: [String] = []
        var at = view
        while let view = at, names.count < 5 {
            names.append(String(describing: type(of: view)))
            at = view.superview
        }
        return names.joined(separator: " < ")
    }

    static func lands(_ hit: NSView?, on page: PageView) -> Bool {
        guard let hit else { return false }
        return hit === page || hit.isDescendant(of: page)
    }

    static func state(browser: Browser, window: NSWindow, page clicked: PageView? = nil) -> [String: Any] {
        let responder = window.firstResponder
        let page = clicked ?? browser.active?.built
        var inPage = false
        if let page, let view = responder as? NSView { inPage = view === page || view.isDescendant(of: page) }
        return [
            "key": window.isKeyWindow, "main": window.isMainWindow, "appActive": NSApp.isActive,
            "appHidden": NSApp.isHidden, "visible": window.isVisible, "onScreen": window.occlusionState.contains(.visible),
            "keyWindow": NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "",
            "responder": responder.map { String(describing: type(of: $0)) } ?? "",
            "responderInPage": inPage,
            "covered": page?.covered ?? false,
            "peeking": browser.peeking, "folded": browser.folded,
            "pageSubviews": page?.subviews.map { "\(type(of: $0))\($0.isHidden ? " hidden" : "")" } ?? [],
        ]
    }

    static func hits(_ request: [String: Any], browser: Browser, window: NSWindow, frame: NSView) -> [String: Any] {
        let columns = request["columns"] as? Int ?? 9
        let rows = request["rows"] as? Int ?? 7
        let height = window.frame.height
        var report: [[String: Any]] = []
        var misses: [[String: Any]] = []
        for page in pages(in: window, browser: browser) {
            let rect = page.convert(page.bounds, to: nil).intersection(page.visibleRect.isEmpty ? .zero : page.convert(page.visibleRect, to: nil))
            guard !rect.isEmpty else { continue }
            var points: [NSPoint] = []
            let inset = CGFloat(request["inset"] as? Double ?? 12)
            for row in 0..<rows {
                for column in 0..<columns {
                    let x = rect.minX + inset + (rect.width - 2 * inset) * CGFloat(column) / CGFloat(max(1, columns - 1))
                    let y = rect.minY + inset + (rect.height - 2 * inset) * CGFloat(row) / CGFloat(max(1, rows - 1))
                    points.append(NSPoint(x: x, y: y))
                }
            }
            var missed = 0
            var firstMouse = 0
            var webKitFirstMouse = 0
            var first: NSView?
            let probe = NSPoint(x: rect.midX, y: rect.midY)
            for point in points {
                let hit = frame.hitTest(frame.convert(point, from: nil))
                if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: Int.random(in: 1...Int(Int32.max)),
                                                  clickCount: 1, pressure: 1),
                   hit?.acceptsFirstMouse(for: event) == true {
                    firstMouse += 1
                }
                if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: Int.random(in: 1...Int(Int32.max)),
                                                  clickCount: 1, pressure: 1),
                   page.webKitAcceptsFirstMouse(for: event) {
                    webKitFirstMouse += 1
                }
                if !lands(hit, on: page) {
                    missed += 1
                    first = first ?? hit
                    if misses.count < 40 {
                        misses.append(["x": Int(point.x), "y": Int(height - point.y), "view": chain(hit)])
                    }
                }
            }
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: probe, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            let centreHit = frame.hitTest(frame.convert(probe, from: nil))
            report.append([
                "page": page.url?.absoluteString ?? "",
                "rect": [Int(rect.minX), Int(height - rect.maxY), Int(rect.width), Int(rect.height)],
                "points": points.count, "missed": missed, "firstMouseAt": firstMouse, "webKitFirstMouseAt": webKitFirstMouse,
                "firstMiss": first.map { chain($0) } ?? "",
                "centre": chain(centreHit),
                "firstMouse": centreHit?.acceptsFirstMouse(for: down) ?? false,
            ])
        }
        return ["pages": report, "misses": misses, "state": state(browser: browser, window: window)]
    }

    static func click(_ request: [String: Any], browser: Browser, window: NSWindow, frame: NSView, _ answer: @escaping ([String: Any]) -> Void) {
        let height = window.frame.height
        let point: NSPoint
        if let x = request["x"] as? Double, let y = request["y"] as? Double {
            point = NSPoint(x: x, y: Double(height) - y)
        } else if let page = browser.active?.built ?? pages(in: window, browser: browser).first {
            let rect = page.convert(page.bounds, to: nil)
            point = NSPoint(x: rect.midX, y: rect.midY)
        } else {
            answer(["error": "no page to click"])
            return
        }
        let hit = frame.hitTest(frame.convert(point, from: nil))
        var target: PageView?
        var climbing = hit
        while let view = climbing, target == nil {
            target = view as? PageView
            climbing = view.superview
        }
        let stamp = ProcessInfo.processInfo.systemUptime
        let before = state(browser: browser, window: window)
        var sent: [String] = []
        let number = Int.random(in: 1...Int(Int32.max))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: stamp + (type == .leftMouseUp ? 0.05 : 0),
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: number,
                                                 clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            else { continue }
            if request["through"] as? String == "view" {
                if type == .leftMouseDown { hit?.mouseDown(with: event) } else { hit?.mouseUp(with: event) }
            } else {
                window.sendEvent(event)
            }
            sent.append("\(type.rawValue)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0.4)) {
            answer([
                "at": [Int(point.x), Int(height - point.y)], "hit": chain(hit), "sent": sent,
                "before": before, "after": state(browser: browser, window: window, page: target),
            ])
        }
    }
}

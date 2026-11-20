import AppKit

@MainActor
enum BenchFullScreenSide {
    static let verbs: Set<String> = ["fullscreenside"]

    static func run(_ verb: String, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "fullscreenside only works on a --test run"]); return }
        let side = FullScreenSide.shared
        let action = request["action"] as? String ?? "state"
        guard action != "state" else { return answer(state()) }
        guard let host = side.host else { return answer(["error": "no page is in full screen", "state": state()]) }
        let frame = host.frame
        let right = (Browsers.front ?? Browsers.primary)?.prefs.sidePosition == .right
        switch action {
        case "edge":
            side.moved(at: NSPoint(x: right ? frame.maxX - 2 : frame.minX + 2, y: frame.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + FullScreenSide.dwell + 0.6) { answer(state()) }
        case "pass":
            side.moved(at: NSPoint(x: right ? frame.maxX - 2 : frame.minX + 2, y: frame.midY))
            side.moved(at: NSPoint(x: frame.midX, y: frame.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + FullScreenSide.dwell + 0.6) { answer(state()) }
        case "inside":
            side.moved(at: NSPoint(x: right ? frame.maxX - 100 : frame.minX + 100, y: frame.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state()) }
        case "away":
            side.moved(at: NSPoint(x: frame.midX, y: frame.midY))
            DispatchQueue.main.asyncAfter(deadline: .now() + FullScreenSide.grace + 0.6) { answer(state()) }
        case "click":
            guard let panel = side.panel, let content = panel.contentView, let id = request["id"] as? String,
                  let row = rows(in: content).first(where: { $0.tab?.id.uuidString.lowercased().hasPrefix(id.lowercased()) == true })
            else { return answer(["error": "no such row in the full-screen sidebar", "state": state()]) }
            let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { answer(state()) }
        default:
            answer(["error": "fullscreenside knows state, edge, pass, inside, away and click"])
        }
    }

    private static func rows(in view: NSView) -> [TabRowView] {
        view.subviews.flatMap { sub -> [TabRowView] in ((sub as? TabRowView).map { [$0] } ?? []) + rows(in: sub) }
    }

    private static func state() -> [String: Any] {
        let side = FullScreenSide.shared
        let host = side.host
        let panel = side.panel
        let shown = panel.flatMap(\.contentView).map { rows(in: $0).filter { !$0.isHiddenOrHasHiddenAncestor }.count } ?? 0
        return ["out": side.out, "host": host?.windowNumber ?? 0, "hostKind": host.map { String(describing: type(of: $0)) } ?? "",
                "parentIsHost": host != nil && panel?.parent === host, "panelVisible": panel?.isVisible ?? false,
                "rows": shown, "hearsMoves": host?.acceptsMouseMovedEvents ?? false, "reminder": FullScreenEscape.shared.showing]
    }
}

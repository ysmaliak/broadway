import AppKit

@MainActor
enum BenchTear {
    private static var held: (window: NSWindow, at: NSPoint, row: NSView)?

    static func handle(_ request: [String: Any]) -> [String: Any] {
        guard Store.testing else { return ["error": "tear only works on a --test run"] }
        let ref = (request["id"] as? String)?.lowercased() ?? ""
        let browser = ref.isEmpty ? nil : Browsers.all.first { $0.tabs.contains { $0.id.uuidString.lowercased().hasPrefix(ref) } }
        let tab = browser?.tabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
        let action = request["action"] as? String ?? "read"
        switch action {
        case "begin":
            for open in Browsers.all { open.window?.contentView?.layoutSubtreeIfNeeded() }
            guard let tab, let window = browser?.window, let content = window.contentView,
                  let row = content.kitSubviews(of: TabRowView.self).first(where: { $0.tab?.id == tab.id && !$0.isHiddenOrHasHiddenAncestor })
            else { return ["error": "no row on screen for that tab"] }
            TearOff.shared.end()
            let frame = row.convert(row.bounds, to: nil)
            let start = NSPoint(x: frame.minX + min(40, frame.width / 2), y: frame.midY)
            send(.leftMouseDown, at: start, in: window, to: row)
            held = (window, start, row)
            for step in 1...3 { send(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y - CGFloat(step * 3)), in: window, to: row) }
        case "move":
            guard let held, let at = request["at"] as? [Double], at.count == 2 else { return ["error": "tear move needs a begun drag and at"] }
            let target = held.window.convertPoint(fromScreen: NSPoint(x: at[0], y: at[1]))
            let steps = max(1, Int((hypot(target.x - held.at.x, target.y - held.at.y) / 16).rounded(.up)))
            for step in 1...steps {
                let f = CGFloat(step) / CGFloat(steps)
                send(.leftMouseDragged, at: NSPoint(x: held.at.x + (target.x - held.at.x) * f, y: held.at.y + (target.y - held.at.y) * f), in: held.window, to: held.row)
            }
            self.held = (held.window, target, held.row)
        case "letgo":
            guard let held else { return ["error": "tear letgo needs a begun drag"] }
            let said = read()
            send(.leftMouseUp, at: held.at, in: held.window, to: held.row)
            self.held = nil
            return said.merging(["released": true]) { $1 }
        case "cancel":
            guard let held else { return ["error": "tear cancel needs a begun drag"] }
            TabDrag.shared.benchCancel()
            send(.leftMouseDragged, at: NSPoint(x: held.at.x + 1, y: held.at.y), in: held.window, to: held.row)
            let said = read()
            send(.leftMouseUp, at: NSPoint(x: held.at.x + 1, y: held.at.y), in: held.window, to: held.row)
            self.held = nil
            return said.merging(["released": true]) { $1 }
        case "read":
            break
        default:
            return ["error": "tear takes begin, move, letgo, cancel or read"]
        }
        return read()
    }

    static func read() -> [String: Any] {
        let tear = TearOff.shared
        var said: [String: Any] = [
            "away": tear.out,
            "picture": tear.ghost.up,
            "card": tear.ghost.up && tear.ghost.picture == nil,
            "point": [Double(tear.point.x), Double(tear.point.y)]
        ]
        if tear.ghost.up {
            let frame = tear.ghost.frame.insetBy(dx: TearLook.room, dy: TearLook.room)
            said["pictureFrame"] = [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }
        }
        guard tear.out else { return said }
        guard let target = tear.target else {
            said["takes"] = "new"
            return said
        }
        said["window"] = (Browsers.all.firstIndex { $0 === target } ?? -1) + 1
        switch tear.place {
        case .loose(let place)?:
            switch place.before {
            case .tab(let id)?: said["index"] = target.tabs.firstIndex { $0.id == id } ?? target.tabs.count
            case .folder(let id)?: said["beforeFolder"] = target.tabGroups.first { $0.id == id }?.name ?? ""
            case nil: said["index"] = target.tabs.count
            }
            said["line"] = true
        case .folder(let drop)?:
            said["folder"] = target.tabGroups.first { $0.id == drop.group }?.name ?? ""
            if let member = drop.member { said["member"] = target.tabs.first { $0.id == member }.map(Bench.short) ?? "" }
            said["after"] = drop.after
            said["line"] = true
        case nil:
            said["index"] = target.placeForNew()
            said["line"] = false
        }
        return said
    }

    private static func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, to row: NSView) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return }
        switch type {
        case .leftMouseDown: row.mouseDown(with: event)
        case .leftMouseDragged: row.mouseDragged(with: event)
        default: row.mouseUp(with: event)
        }
    }
}

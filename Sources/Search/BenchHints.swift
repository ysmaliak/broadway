import AppKit

@MainActor
enum BenchHints {
    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "hints only works on a --test run"]); return }
        switch request["action"] as? String ?? "state" {
        case "state":
            answer(state(browser))
        case "advance":
            HintClock.advance(request["seconds"] as? Double ?? 0)
            answer(state(browser))
        case "forget":
            HintBook.shared.forget()
            browser.hints.forget()
            browser.dismissAnnounced()
            answer(state(browser))
        case "rowclose":
            guard let id = (request["id"] as? String)?.lowercased(), let window = browser.window,
                  let row = views(TabRowView.self, in: window).first(where: { $0.tab?.id.uuidString.lowercased().hasPrefix(id) == true })
            else { answer(["error": "hints rowclose needs the id of a tab with a row"]); return }
            middle(on: row, in: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(state(browser)) }
        case "press":
            guard let window = browser.window, let text = browser.announcement,
                  let note = views(CapsuleNote.self, in: window).first(where: { $0.label.text == text })
            else { answer(["error": "nothing announced to press"]); return }
            guard let hit = click(on: note, in: window) else {
                answer(["error": "the line does not take a click there"]); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                var said = state(browser)
                said["hit"] = "\(type(of: hit))"
                answer(said)
            }
        case "picture":
            guard let window = browser.window, let frame = window.contentView?.superview, let path = request["path"] as? String
            else { answer(["error": "hints picture needs a path"]); return }
            let before = window.appearance
            window.appearance = NSAppearance(named: request["dark"] as? Bool == true ? .darkAqua : .aqua)
            frame.layoutSubtreeIfNeeded()
            frame.displayIfNeeded()
            defer { window.appearance = before }
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { answer(["error": "nothing drawn"]); return }
            frame.cacheDisplay(in: frame.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil
            else { answer(["error": "the picture was not written"]); return }
            var said = state(browser)
            said["saved"] = path
            answer(said)
        default:
            answer(["error": "hints state | advance seconds | forget | rowclose id | press | picture path [dark]"])
        }
    }

    static func state(_ browser: Browser) -> [String: Any] {
        let record = HintBook.shared.record
        return ["on": browser.prefs.hints,
                "shown": record.shown.map(\.rawValue).sorted(),
                "used": record.used.map(\.rawValue).sorted(),
                "last": record.last?.timeIntervalSince1970 ?? 0,
                "announcement": browser.announcement ?? "",
                "showing": browser.hints.showing ?? "",
                "pointerCloses": browser.hints.trail.pointerCloses.count,
                "sinceLaunch": HintClock.now.timeIntervalSince(HintClock.launched),
                "tabs": browser.tabs.count]
    }

    private static func views<View: NSView>(_ kind: View.Type, in window: NSWindow) -> [View] {
        func walk(_ view: NSView) -> [View] {
            ((view as? View).map { [$0] } ?? []) + view.subviews.flatMap(walk)
        }
        return (window.contentView?.superview ?? window.contentView).map(walk) ?? []
    }

    private static func middle(on view: NSView, in window: NSWindow) {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .otherMouseDown ? 1 : 0),
                  let cg = event.cgEvent else { continue }
            cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
            let pressed = NSEvent(cgEvent: cg) ?? event
            if type == .otherMouseDown { view.otherMouseDown(with: pressed) } else { view.otherMouseUp(with: pressed) }
        }
    }

    private static func click(on view: NSView, in window: NSWindow) -> NSView? {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        guard let frame = window.contentView?.superview, let hit = frame.hitTest(frame.convert(point, from: nil)),
              hit === view || hit.isDescendant(of: view) else { return nil }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
        return hit
    }
}

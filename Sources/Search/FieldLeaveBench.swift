import AppKit

@MainActor
enum FieldLeaveBench {
    static func omnibox(in browser: Browser) -> OmniboxView? {
        browser.window?.contentView?.kitSubviews(of: OmniboxView.self).first
    }

    static func drawn(in browser: Browser) -> [String: Any]? {
        omnibox(in: browser)?.benchDrawn
    }

    static func clickOutside(_ browser: Browser) {
        guard let view = omnibox(in: browser), let window = view.window, let frame = window.contentView?.superview else { return }
        let point = view.convert(NSPoint(x: view.bounds.width - 40, y: view.bounds.height - 40), to: nil)
        guard let hit = frame.hitTest(frame.convert(point, from: nil)) else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                 pressure: type == .leftMouseUp ? 0 : 1) else { continue }
            if type == .leftMouseDown { hit.mouseDown(with: event) } else { hit.mouseUp(with: event) }
        }
    }

    static func line(_ browser: Browser, to url: URL) -> Bool {
        guard let image = omnibox(in: browser)?.benchLine,
              let data = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
        else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }
}

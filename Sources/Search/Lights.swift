import AppKit

@MainActor
final class Lights: NSObject {
    static let centre = CGPoint(x: 26, y: 26)

    private static var kept: [ObjectIdentifier: Lights] = [:]

    static func keep(_ window: NSWindow, centreX: @escaping (NSWindow) -> CGFloat) {
        // A freed window's entry goes, and with it the one a new window at
        // the same address would otherwise be taken for.
        kept = kept.filter { $0.value.window != nil }
        guard kept[ObjectIdentifier(window)] == nil else { return }
        kept[ObjectIdentifier(window)] = Lights(window, centreX: centreX)
    }

    static func refresh(_ window: NSWindow?) {
        guard let window else { return }
        kept[ObjectIdentifier(window)]?.place()
    }

    /// Puts the lights back only when something moved them. A page whose
    /// title changes every second asks for this each time, so it only looks.
    static func refreshIfMoved(_ window: NSWindow?) {
        guard let window, let lights = kept[ObjectIdentifier(window)], lights.misplaced() else { return }
        lights.place()
    }

    private weak var window: NSWindow?
    private let centreX: (NSWindow) -> CGFloat
    private var placing = false
    /// AppKit's own spacing between the three, read once from its first
    /// layout and kept. Read again on every pass, it was caught while AppKit
    /// was halfway through putting them back after a resize — one button
    /// moved, the next not yet — and the three closed up from 23 points apart
    /// to 13, on top of each other, a spacing each later pass then copied
    /// from the one before. Reproduced with ./bench resize, 23 Sep 2026.
    private let spacing: CGFloat

    private init(_ window: NSWindow, centreX: @escaping (NSWindow) -> CGFloat) {
        self.window = window
        self.centreX = centreX
        let row = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { window.standardWindowButton($0) }
        let measured = row.count == 2 ? row[1].frame.minX - row[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20
        super.init()
        let centre = NotificationCenter.default
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didChangeScreenNotification,
        ] {
            centre.addObserver(self, selector: #selector(place), name: name, object: window)
        }
        // The title bar's own views moving is the surest sign AppKit has just
        // laid them out again.
        let buttons = self.buttons
        if let bar = buttons.first?.superview, let container = bar.superview {
            for view in [container, bar] + buttons {
                view.postsFrameChangedNotifications = true
                centre.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: view)
            }
        }
        place()
    }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// Whether `place` would move anything: the same arithmetic, changing nothing.
    private func misplaced() -> Bool {
        guard !placing, let window, !window.styleMask.contains(.fullScreen) else { return false }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return false }
        if container.frame.height != Metrics.strip || container.frame.maxY != window.frame.height { return true }
        for (index, button) in buttons.enumerated() where button.frame.origin != origin(of: button, at: index, in: bar, window) {
            return true
        }
        return false
    }

    private func origin(of button: NSButton, at index: Int, in bar: NSView, _ window: NSWindow) -> NSPoint {
        let size = button.frame.size
        return NSPoint(x: centreX(window) - size.width / 2 + CGFloat(index) * spacing,
                       y: bar.bounds.height - Lights.centre.y - size.height / 2)
    }

    @objc private func place() {
        // Full screen keeps its title bar in a window of its own, laid out by
        // macOS; it is left to it.
        guard !placing, let window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return }
        placing = true
        defer { placing = false }

        // A title bar as tall as the strip, so the buttons can sit lower in it.
        let height = Metrics.strip
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height {
            frame.size.height = height
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }
        // Only the row moves; the spacing is AppKit's, from its first layout.
        for (index, button) in buttons.enumerated() {
            let origin = origin(of: button, at: index, in: bar, window)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
        DispatchQueue.main.async { [weak self] in
            if self?.misplaced() == true { self?.place() }
        }
    }
}

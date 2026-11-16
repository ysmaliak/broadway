import AppKit

class KitHoverView: NSView {
    var onHover: ((Bool) -> Void)?
    private(set) var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            hoverChanged()
            onHover?(hovering)
        }
    }
    private var area: NSTrackingArea?
    var inert = false { didSet { if inert != oldValue { updateTrackingAreas() } } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = nil
        guard !inert else {
            hovering = false
            return
        }
        let made = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        area = made
        settleHover()
    }

    static var pointerStandIn: (window: NSWindow, point: NSPoint)?

    static func pointer(in window: NSWindow) -> NSPoint {
        if Store.testing, let standIn = pointerStandIn, standIn.window === window { return standIn.point }
        return window.mouseLocationOutsideOfEventStream
    }

    func settleHover() {
        guard let window, !inert else { return }
        let inside = bounds.contains(convert(Self.pointer(in: window), from: nil)) && !isHiddenOrHasHiddenAncestor
        if inside != hovering { hovering = inside }
    }

    func endHover() {
        hovering = false
    }

    override func mouseEntered(with event: NSEvent) { hovering = !inert }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidHide() {
        super.viewDidHide()
        hovering = false
    }

    func hoverChanged() {}

    func benchPillHover(_ on: Bool) {
        guard Store.testing else { return }
        hovering = on
    }
}

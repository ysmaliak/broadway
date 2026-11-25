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
    var followsPointer = false
    var clipsHover = false

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
        let inside = pointerInside(window)
        if inside != hovering { hovering = inside }
    }

    private func pointerInside(_ window: NSWindow) -> Bool {
        let point = convert(Self.pointer(in: window), from: nil)
        return bounds.contains(point) && (!clipsHover || visibleRect.contains(point)) && !isHiddenOrHasHiddenAncestor
    }

    func endHover() {
        hovering = false
    }

    override func mouseEntered(with event: NSEvent) {
        guard followsPointer, let window else { return hovering = !inert }
        hovering = !inert && pointerInside(window)
    }

    override func mouseExited(with event: NSEvent) {
        guard followsPointer, let window else { return hovering = false }
        hovering = !inert && pointerInside(window)
    }

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

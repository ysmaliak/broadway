import AppKit

final class KitGlassFace: NSGlassEffectView {
    let face: NSView
    private let holder = KitCenteringView()

    init(_ face: NSView) {
        self.face = face
        super.init(frame: .zero)
        holder.addSubview(face)
        contentView = holder
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var nudge: CGVector {
        get { holder.nudge }
        set { holder.nudge = newValue }
    }

    var plate: NSColor? {
        get { holder.plate }
        set { holder.plate = newValue }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override func layout() {
        super.layout()
        cornerRadius = min(bounds.width, bounds.height) / 2
        holder.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class KitCenteringView: NSView {
    var nudge = CGVector.zero { didSet { if nudge != oldValue { needsLayout = true } } }
    var plate: NSColor? { didSet { if plate != oldValue { paint() } } }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        kitGlassOwner?.acceptsFirstMouse(for: event) ?? super.acceptsFirstMouse(for: event)
    }

    override var mouseDownCanMoveWindow: Bool { kitGlassOwner?.mouseDownCanMoveWindow ?? super.mouseDownCanMoveWindow }

    override func menu(for event: NSEvent) -> NSMenu? { kitGlassOwner?.menu(for: event) ?? super.menu(for: event) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        wantsLayer = plate != nil || layer != nil
        layer?.backgroundColor = plate?.kitResolved(dark: kitDark).cgColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = plate == nil ? 0 : min(bounds.width, bounds.height) / 2
        for view in subviews {
            let size = view.intrinsicContentSize
            let width = size.width < 0 ? bounds.width : size.width
            let height = size.height < 0 ? bounds.height : size.height
            view.frame = kitPlace(NSRect(x: (bounds.width - width) / 2 + nudge.dx, y: (bounds.height - height) / 2 + nudge.dy,
                                         width: width, height: height))
        }
    }
}

import AppKit

extension NSPanel {
    func kitFloat(shadow: Bool, hidesWithApp: Bool = false) {
        level = KeepOnTop.panelLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = shadow
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        canHide = hidesWithApp
    }
}

@MainActor
struct KitKeptFrame {
    let key: String
    var store: UserDefaults = Store.settings

    var frame: NSRect? {
        guard let text = store.string(forKey: key) else { return nil }
        let frame = NSRectFromString(text)
        return Self.shown(frame, on: NSScreen.screens.map(\.visibleFrame)) ? frame : nil
    }

    func keep(_ frame: NSRect?) {
        store.set(frame.map(NSStringFromRect), forKey: key)
    }

    static func shown(_ frame: NSRect, on screens: [NSRect]) -> Bool {
        screens.contains {
            let seen = $0.intersection(frame)
            return seen.width * seen.height > 0.6 * frame.width * frame.height
        }
    }
}

extension KitGlass {
    static func floating(radius: CGFloat = 0, capsule: Bool = false, interactive: Bool = false, ground: Bool = true) -> KitGlass {
        let glass = KitGlass(radius: radius, tint: Palette.NS.glassTint, interactive: interactive)
        glass.capsule = capsule
        if ground { glass.ground = Palette.NS.glassGround }
        return glass
    }
}

final class KitGlassGround: NSView {
    var fill: NSColor? { didSet { if fill != oldValue { paint() } } }
    var radius: CGFloat = 0 { didSet { if radius != oldValue { layer?.cornerRadius = radius } } }
    private(set) var held: NSView?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func hold(_ view: NSView?) {
        guard view !== held else { return }
        held?.removeFromSuperview()
        held = view
        if let view { addSubview(view) }
        needsLayout = true
    }

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
        layer?.backgroundColor = fill?.kitResolved(dark: kitDark).cgColor
    }

    override func layout() {
        super.layout()
        held?.frame = bounds
    }
}

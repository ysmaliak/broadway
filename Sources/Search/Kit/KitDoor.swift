import AppKit

final class KitDoor: KitButton {
    var on = false { didSet { if on != oldValue { paintDoor() } } }
    var hover: NSColor = Palette.NS.hover { didSet { paintDoor() } }
    var wash: NSColor = Palette.NS.wash { didSet { paintDoor() } }
    let box: CGFloat

    private let ground = KitBox(fill: nil, corners: .radius(8))
    private let symbol: KitSymbol

    init(icon: String, help: String = "", size: CGFloat = 12, weight: NSFont.Weight = IconLook.control, box: CGFloat = 26,
         action: @escaping () -> Void) {
        self.box = box
        symbol = KitSymbol(icon, style: KitSymbol.Style(size: size, weight: weight), tint: KitColor.muted)
        super.init(.plain(press: 0.9), label: help.isEmpty ? nil : help, action: action)
        addSubview(ground, positioned: .below, relativeTo: nil)
        content = symbol
        if !help.isEmpty { kitAccess(help: help) }
        paintDoor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var icon: String {
        get { symbol.name }
        set { symbol.swap(to: newValue) }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: box, height: box) }

    override func hoverChanged() {
        super.hoverChanged()
        paintDoor()
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
    }

    private func paintDoor() {
        let fill = on ? wash : hovering ? hover : nil
        if fill != ground.fill {
            ground.layer?.kitTransition(Motion.kitQuick)
            ground.fill = fill
        }
        symbol.tint = on || hovering ? KitColor.ink : KitColor.muted
    }
}

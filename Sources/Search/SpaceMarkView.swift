import AppKit

final class SpaceMarkView: NSView {
    var icon: TabIcon { didSet { if icon != oldValue { refresh() } } }
    var size: CGFloat { didSet { if size != oldValue { refresh() } } }
    var tint: NSColor = KitColor.ink {
        didSet {
            symbol.tint = tint
            emoji.color = tint
        }
    }
    var ink: KitInk = .flat {
        didSet {
            symbol.ink = ink
            emoji.ink = ink
        }
    }
    var opacity: Double = 1 {
        didSet {
            symbol.opacity = opacity
            emoji.opacity = opacity
        }
    }
    var byInk = false { didSet { if byInk != oldValue { needsLayout = true } } }

    private let symbol = KitSymbol("square.dashed")
    private let emoji = KitLabel()

    init(icon: TabIcon, size: CGFloat = 15) {
        self.icon = icon
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        emoji.setAccessibilityElement(false)
        addSubview(symbol)
        addSubview(emoji)
        setAccessibilityElement(false)
        refresh()
    }

    convenience init(space: Space, size: CGFloat = 15) {
        self.init(icon: space.shownIcon, size: size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var isEmoji: Bool { !(icon.emoji ?? "").isEmpty }

    override var intrinsicContentSize: NSSize {
        let shown = isEmoji ? emoji.intrinsicContentSize : symbol.intrinsicContentSize
        return NSSize(width: ceil(shown.width), height: max(size, ceil(shown.height)))
    }

    override func layout() {
        super.layout()
        for view in [symbol, emoji] as [NSView] {
            let side = view.intrinsicContentSize
            view.frame = kitSnap(NSRect(x: (bounds.width - side.width) / 2, y: (bounds.height - side.height) / 2,
                                        width: side.width, height: side.height))
        }
        if byInk { symbol.centreInk(in: bounds) }
    }

    func swap(to icon: TabIcon, curve: KitCurve = Motion.kitQuick) {
        guard icon != self.icon else { return }
        self.icon = icon
        guard curve.animates, let layer else { return }
        layer.kitTransition(curve)
        let mid = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        let small = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                            CATransform3DMakeScale(0.8, 0.8, 1)), mid)
        if let grow = curve.animation("transform", from: NSValue(caTransform3D: small), to: NSValue(caTransform3D: CATransform3DIdentity)) {
            layer.add(grow, forKey: "space.mark.grow")
        }
    }

    private func refresh() {
        emoji.isHidden = !isEmoji
        symbol.isHidden = isEmoji
        if isEmoji {
            emoji.font = .systemFont(ofSize: (size * 0.75).rounded())
            emoji.text = icon.emoji ?? ""
        } else {
            symbol.name = icon.symbol ?? "square.dashed"
            symbol.style = KitSymbol.Style(size: size - 1, weight: .medium)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}

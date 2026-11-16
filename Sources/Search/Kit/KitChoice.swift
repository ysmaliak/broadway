import AppKit

final class KitChoice: NSView {
    struct Option: Equatable {
        let title: String
        var symbol: String? = nil
    }

    static let height: CGFloat = 28
    static let rim: CGFloat = 2.5
    static let font: CGFloat = 13
    static let pad: CGFloat = 10

    var options: [Option] { didSet { rebuild() } }
    var picked: Int { didSet { if picked != oldValue { moved(from: oldValue) } } }
    var pick: ((Int) -> Void)?
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.45 } }

    private let track = KitGlass()
    private let thumb = KitGlass()
    private var segments: [Segment] = []
    private var hovered: Int?
    private var pressed: Int?
    private var tracking: NSTrackingArea?

    init(_ label: String, options: [Option], picked: Int, pick: ((Int) -> Void)? = nil) {
        self.options = options
        self.picked = picked
        self.pick = pick
        super.init(frame: .zero)
        track.capsule = true
        thumb.capsule = true
        thumb.effectIsInteractive = true
        addSubview(track)
        addSubview(thumb)
        rebuild()
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { KitFocus.takes(isEnabled) }
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: segments.reduce(Self.rim * 2) { $0 + $1.width }, height: Self.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        var x = Self.rim
        for segment in segments {
            segment.frame = kitSnap(NSRect(x: x, y: Self.rim, width: segment.width, height: bounds.height - Self.rim * 2))
            x += segment.width
        }
        if segments.indices.contains(picked) { thumb.frame = segments[picked].frame }
        paint()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) { hover(at: event) }
    override func mouseEntered(with event: NSEvent) { hover(at: event) }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        paint()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if isEnabled, let caught = thumb.kitCatch(at: convert(point, from: superview), in: self) { return caught }
        return [track, thumb].contains { hit === $0 || hit.isDescendant(of: $0) } ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = index(at: event)
        paint()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            pressed = nil
            paint()
        }
        guard isEnabled, let at = index(at: event), at == pressed, at != picked else { return }
        choose(at)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123 where picked > 0: choose(picked - 1)
        case 124 where picked < options.count - 1: choose(picked + 1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityChildren() -> [Any]? { segments }

    private func choose(_ at: Int) {
        picked = at
        pick?(at)
    }

    private func hover(at event: NSEvent) {
        let at = index(at: event)
        guard at != hovered else { return }
        hovered = at
        paint()
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return segments.firstIndex { $0.frame.insetBy(dx: 0, dy: -Self.rim).contains(point) }
    }

    private func rebuild() {
        segments.forEach { $0.removeFromSuperview() }
        segments = options.enumerated().map { index, option in
            let segment = Segment(option, owner: self, index: index)
            addSubview(segment)
            return segment
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func moved(from old: Int) {
        guard segments.indices.contains(picked) else { return }
        let target = segments[picked].frame
        let curve = Motion.reduced ? KitCurve.easeOut(0.14) : Motion.kitRoll
        if let layer = thumb.layer, window != nil, segments.indices.contains(old) {
            let from = layer.presentation()?.position ?? layer.position
            let fromBounds = layer.presentation()?.bounds ?? layer.bounds
            thumb.frame = target
            if let move = curve.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position)) {
                layer.add(move, forKey: "kit.choice.position")
            }
            if let size = curve.animation("bounds", from: NSValue(rect: fromBounds), to: NSValue(rect: layer.bounds)) {
                layer.add(size, forKey: "kit.choice.bounds")
            }
        } else {
            thumb.frame = target
        }
        paint()
    }

    private func paint() {
        let dark = kitDark
        track.tintColor = KitGlass.trackTint(dark: dark)
        thumb.tintColor = KitGlass.thumbTint(dark: dark)
        for (index, segment) in segments.enumerated() {
            let on = index == picked
            let down = isEnabled && pressed == index && !on
            let alpha: CGFloat = on ? 1 : down ? 0.95 : hovered == index ? 0.85 : 0.62
            segment.show(on: on, opacity: alpha, pressed: down, dark: dark)
        }
    }

    final class Segment: NSView {
        private let label = KitLabel()
        private let symbol: KitSymbol?
        private let fill = KitBox(fill: nil, corners: .capsule)
        private let option: Option
        private weak var owner: KitChoice?
        private let index: Int
        let width: CGFloat

        init(_ option: Option, owner: KitChoice, index: Int) {
            self.option = option
            self.owner = owner
            self.index = index
            symbol = option.symbol.map {
                KitSymbol($0, style: KitSymbol.Style(size: KitChoice.font - 0.5, weight: IconLook.weight))
            }
            let medium = NSAttributedString(string: option.title, attributes: [.font: NSFont.systemFont(ofSize: KitChoice.font, weight: .medium)])
            let text = ceil(medium.size().width * 2) / 2
            let art = symbol.map { ceil($0.intrinsicContentSize.width) + 6 } ?? 0
            width = text + art + KitChoice.pad * 2
            super.init(frame: .zero)
            addSubview(fill)
            if let symbol { addSubview(symbol) }
            label.font = .systemFont(ofSize: KitChoice.font)
            label.text = option.title
            addSubview(label)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func show(on: Bool, opacity: CGFloat, pressed: Bool, dark: Bool) {
            label.font = .systemFont(ofSize: KitChoice.font, weight: on ? .medium : .regular)
            label.opacity = opacity
            symbol?.opacity = opacity
            fill.fill = pressed ? NSColor(white: dark ? 1 : 0, alpha: dark ? 0.14 : 0.08) : nil
            needsLayout = true
        }

        override func layout() {
            super.layout()
            fill.frame = bounds
            let size = label.measure(width: .greatestFiniteMagnitude)
            let art = symbol.map { ceil($0.intrinsicContentSize.width) + 6 } ?? 0
            let total = ceil(size.width) + art
            var x = (bounds.width - total) / 2
            if let symbol {
                let side = symbol.intrinsicContentSize
                symbol.frame = kitSnap(NSRect(x: x, y: (bounds.height - side.height) / 2, width: side.width, height: side.height))
                x += art
            }
            label.frame = kitSnap(NSRect(x: x, y: (bounds.height - size.height) / 2, width: ceil(size.width), height: size.height))
        }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
        override func accessibilityLabel() -> String? { option.title }
        override func accessibilityValue() -> Any? { owner?.picked == index ? 1 : 0 }
        override func accessibilityPerformPress() -> Bool {
            guard let owner, owner.isEnabled, owner.picked != index else { return false }
            owner.choose(index)
            return true
        }
    }
}

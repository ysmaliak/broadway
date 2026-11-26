import AppKit

final class SideCountView: KitFlippedView {
    static let height: CGFloat = 17
    static let pad: CGFloat = 6
    static let tail: CGFloat = 10
    static let gap: CGFloat = 9
    static let wash = 0.07
    static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    var thing: AnyHashable? = 0
    var count = 0 { didSet { if count != oldValue { tally.roll("\(count)", for: thing); needsLayout = true } } }
    var yields = false { didSet { if yields != oldValue { chip.alphaValue = yields ? 0 : 1 } } }
    private(set) var shown: Swift.Float = 0
    private let chip = KitBox(fill: KitColor.ink.withAlphaComponent(SideCountView.wash), corners: .capsule)
    private let tally = KitLabel("", font: SideCountView.font, color: KitColor.muted)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.opacity = 0
        isHidden = true
        addSubview(chip)
        chip.addSubview(tally)
        tally.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var text: String { tally.text }
    var width: CGFloat { tally.intrinsicContentSize.width + 2 * Self.pad }
    var showing: Bool { !isHidden && shown > 0 && !yields }

    func dress(_ ink: KitInk) {
        tally.ink = ink
        chip.fill = ink.color(KitColor.ink, .ink, opacity: Self.wash, dark: kitDark)
    }

    func fold(_ shows: Bool, curve: KitCurve) {
        let target: Swift.Float = shows ? 1 : 0
        guard target != shown, let layer else { return }
        shown = target
        let wasHidden = isHidden
        isHidden = false
        let from = wasHidden ? Swift.Float(0) : (layer.presentation()?.opacity ?? layer.opacity)
        let carry = layer.kitCarry("fold.opacity", from: NSNumber(value: from), to: NSNumber(value: target))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "fold.opacity")
        guard window != nil, let fade = curve.animation("opacity", from: from, to: target, velocity: carry) else { return }
        fade.fillMode = .backwards
        layer.add(fade, forKey: "fold.opacity")
    }

    override func layout() {
        super.layout()
        chip.kitSetFrame(bounds)
        let words = tally.intrinsicContentSize
        tally.kitSetFrame(NSRect(x: Self.pad, y: (bounds.height - words.height) / 2, width: words.width, height: words.height))
    }
}

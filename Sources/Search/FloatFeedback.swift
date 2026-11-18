import AppKit

final class FloatSpeedView: FloatPiece {
    let key: FloatKeyView

    init(chrome: FloatChrome, action: @escaping () -> Void) {
        key = FloatKeyView(text: FloatRate.label(chrome.rate), font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                           label: "Playback Speed", help: "Playback Speed", action: action)
        super.init(chrome: chrome, arrival: .unfold(from: KitArrival.top))
        body.addSubview(key)
    }

    override func arrange() {
        let words = FloatRate.label(chrome.rate)
        key.label?.text = words
        key.setAccessibilityValue(words)
        key.enabled = chrome.controllable
        center(key, in: bounds, size: NSSize(width: 54, height: FloatLayout.circle))
    }
}

final class FloatFeedbackView: KitFlippedView {
    let chrome: FloatChrome
    private let glass = KitGlass.floating()
    private let words = KitLabel(" ", font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold), color: .white)
    private var was: Bool?

    init(chrome: FloatChrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        glass.style = .regular
        addSubview(glass)
        addSubview(words)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let text = chrome.feedback
        let on = text != nil
        words.text = text ?? " "
        let natural = words.intrinsicContentSize
        let size = NSSize(width: natural.width + 28, height: natural.height + 16)
        let box = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        glass.frame = box
        glass.cornerRadius = size.height / 2
        words.frame = kitSnap(NSRect(x: box.minX + 14, y: box.minY + 8, width: natural.width, height: natural.height))
        setAccessibilityLabel(text ?? "")
        setAccessibilityElement(on)
        guard let layer, on != was else { return }
        let curve: KitCurve = was == nil ? .none : Motion.calm ? .easeOut(FloatMotion.calm) : Motion.kitQuick
        was = on
        let mid = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        let scale: CGFloat = Motion.calm || on ? 1 : 0.96
        let transform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                                CATransform3DMakeScale(scale, scale, 1)), mid)
        layer.kitAnimate("opacity", to: on ? 1 : 0, curve: curve)
        layer.kitAnimate("transform", to: NSValue(caTransform3D: transform), curve: curve)
    }
}

@MainActor
enum FloatSurfaces {
    static func feedback(_ text: String) -> NSView {
        let chrome = FloatChrome()
        chrome.feedback = text
        let view = FloatFeedbackView(chrome: chrome)
        let words = KitLabel(text, font: .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)).intrinsicContentSize
        return BenchFloating.sized(view, NSSize(width: words.width + 36, height: words.height + 24))
    }
}

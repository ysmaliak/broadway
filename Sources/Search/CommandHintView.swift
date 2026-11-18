import AppKit

final class CommandHintView: NSView {
    var key: String { didSet { if key != oldValue { refresh() } } }
    var title: String { didSet { if title != oldValue { refresh() } } }
    let word: KitLabel
    private let cap = KitBox(fill: Palette.NS.keycap.withAlphaComponent(0.5), corners: .radius(4))
    private let keyLabel = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)

    init(_ key: String, _ title: String, answers: Bool = false) {
        self.key = key
        self.title = title
        word = KitLabel("", font: .systemFont(ofSize: answers ? BroadwaySize.small.font : 11), color: answers ? KitColor.ink : KitColor.muted)
        super.init(frame: .zero)
        for label in [word, keyLabel] { label.setAccessibilityElement(false) }
        addSubview(word)
        addSubview(cap)
        cap.addSubview(keyLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        word.text = title
        keyLabel.text = key
        setAccessibilityLabel("\(title) \(key)")
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let scale = kitScale
        let height = ceil(keyLabel.measure(width: .greatestFiniteMagnitude).height * scale) / scale + 2
        return NSSize(width: FieldLine.width(word, scale: scale) + 4 + FieldLine.width(keyLabel, scale: scale) + 8, height: height)
    }

    override func layout() {
        super.layout()
        let scale = kitScale
        let wordWidth = FieldLine.width(word, scale: scale)
        word.frame = kitSnap(NSRect(x: 0, y: 0, width: wordWidth, height: bounds.height))
        let capWidth = FieldLine.width(keyLabel, scale: scale) + 8
        cap.frame = kitSnap(NSRect(x: wordWidth + 4, y: 0, width: capWidth, height: bounds.height))
        keyLabel.frame = NSRect(x: 4, y: 0, width: capWidth - 8, height: bounds.height)
    }
}

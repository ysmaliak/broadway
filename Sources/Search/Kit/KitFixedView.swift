import AppKit

final class KitFixedView: NSView {
    private let keep: AnyObject?

    init(_ content: NSView, keep: AnyObject? = nil) {
        self.keep = keep
        super.init(frame: NSRect(origin: .zero, size: content.frame.size))
        content.frame.origin = .zero
        addSubview(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { frame.size }
    override var fittingSize: NSSize { frame.size }
}

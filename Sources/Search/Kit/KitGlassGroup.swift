import AppKit

final class KitGlassGroup: NSGlassEffectContainerView {
    let content = KitFlippedView()

    init(spacing: CGFloat) {
        super.init(frame: .zero)
        self.spacing = spacing
        contentView = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        content.frame = bounds
    }
}

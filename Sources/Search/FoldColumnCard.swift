import AppKit
import Combine

extension PeekCardView: FoldCard {}

@MainActor
final class FoldColumnCardView: NSView {
    static func groundOpacity(dark: Bool) -> CGFloat { dark ? 0.9 : 0.84 }

    let column: SideColumnView
    private let browser: Browser
    private let peek: ColumnPeek
    private let shade = FoldColumnShade()
    private let clip = KitFlippedView()
    private let backdrop = KitGlass(radius: Metrics.floatRadius)
    private let ground: ShellGroundLayer
    private let edge = KitPlate(stroke: KitTone(base: Palette.NS.ink, opacity: 0.1), radius: Metrics.floatRadius)
    private var watch: [AnyCancellable] = []

    init(browser: Browser, peek: ColumnPeek? = nil) {
        self.browser = browser
        column = SideColumnView(browser: browser)
        ground = ShellGroundLayer(browser: browser)
        self.peek = peek ?? browser.columnPeek
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.cornerRadius = Metrics.floatRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        column.floating = true
        column.inksItself = true
        column.facesShown = self.peek.out
        for view in [backdrop, ground, column] as [NSView] { clip.addSubview(view) }
        for view in [shade, clip, edge] as [NSView] { addSubview(view) }
        let watched = self.peek
        watch = [
            kitObserve(initial: false, { [weak watched] in watched?.out ?? false }) { [weak self] _ in self?.followPeek() },
            kitObserve(initial: false, distinct: true, { [weak browser] in
                browser.map { [$0.asCards, $0.fullScreen] } ?? []
            }) { [weak self] _ in self?.relaid() },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func relaid() {
        needsLayout = true
        ground.needsLayout = true
    }

    private func followPeek() {
        column.facesShown = peek.out
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard peek.out else { return nil }
        return super.hitTest(point)
    }

    override func layout() {
        super.layout()
        for view in [shade, clip, edge] as [NSView] where view.frame != bounds { view.frame = bounds }
        if backdrop.frame != clip.bounds { backdrop.frame = clip.bounds }
        let canvas = window?.contentView.map { convert($0.bounds, from: $0) } ?? clip.bounds
        if ground.frame != canvas { ground.frame = canvas }
        ground.alphaValue = Self.groundOpacity(dark: kitDark)
        let lift = Metrics.floatGap
        let docked = NSRect(x: 0, y: -lift, width: clip.bounds.width, height: clip.bounds.height + lift)
        if column.frame != docked { column.frame = docked }
    }
}

private final class FoldColumnShade: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        guard let layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 20
        layer.shadowOffset = CGSize(width: 0, height: 6)
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Metrics.floatRadius, cornerHeight: Metrics.floatRadius, transform: nil)
    }
}

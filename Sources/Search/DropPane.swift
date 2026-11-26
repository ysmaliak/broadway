import AppKit
import Combine

@MainActor
final class DropPaneView: NSView {
    enum Mode: Equatable {
        case slide(TabDrag.Side)
        case fade
        case ring
    }

    let tab: Tab
    let mode: Mode
    private let slab = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let mark = KitMark(icon: nil, letter: "", side: 32)
    private let title = KitLabel("", font: .systemFont(ofSize: 15, weight: .medium), color: KitColor.ink)
    private var watch: AnyCancellable?
    private(set) var corners = PaneLayersView.Corners(topLeft: 0, topRight: 0, bottomLeft: 0, bottomRight: 0)
    private(set) var corner: CGFloat = 0
    private(set) var barHeight: CGFloat = 0
    private(set) var leaving = false

    static let ringWidth: CGFloat = 1.5
    static let veil: CGFloat = 0.12

    init(browser: Browser, tab: Tab, mode: Mode) {
        self.tab = tab
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        let still: [String: CAAction] = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "hidden": NSNull(), "frame": NSNull()]
        for layer in [slab, ring] { layer.actions = still }
        ring.fillColor = nil
        ring.lineWidth = Self.ringWidth
        layer?.addSublayer(slab)
        layer?.addSublayer(ring)
        if mode != .ring {
            addSubview(mark)
            addSubview(title)
        }
        title.alignment = .center
        title.overflow = .tail
        title.opacity = 0.8
        watch = kitObserve(initial: false, { [weak tab] in tab.map { ($0.icon, $0.monogram, $0.label) } }) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var veil: CGFloat { CGFloat(slab.fillColor?.alpha ?? 0) }

    func show(bar height: CGFloat, corner: CGFloat, corners: PaneLayersView.Corners) {
        barHeight = mode == .ring ? 0 : height
        self.corner = corner
        self.corners = corners
        refresh()
    }

    private func refresh() {
        mark.icon = tab.icon
        mark.letter = tab.monogram
        title.text = tab.label.isEmpty ? "New Tab" : tab.label
        paint()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let accent = NSColor.controlAccentColor
            slab.fillColor = accent.withAlphaComponent(Self.veil).cgColor
            ring.strokeColor = accent.withAlphaComponent(0.7).cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        slab.frame = bounds
        slab.path = KitPath.continuous(bounds, radius: corner)
        ring.frame = bounds
        ring.path = FocusCue.path(in: bounds, corner: corner, line: Self.ringWidth)
        let side = mark.side
        let titleHeight = title.intrinsicContentSize.height
        let middle = bounds.midY
        mark.frame = kitSnap(NSRect(x: (bounds.width - side) / 2, y: middle - side - 6, width: side, height: side))
        title.frame = kitSnap(NSRect(x: 24, y: middle + 6, width: max(0, bounds.width - 48), height: titleHeight))
        CATransaction.commit()
    }

    func arrive(from offset: CGFloat) {
        guard let layer else { return }
        layoutSubtreeIfNeeded()
        if case .slide = mode, offset != 0, !Motion.reduced {
            move(layer, from: offset, to: 0)
        } else {
            fade(layer, from: 0, to: 1)
        }
    }

    func leave(to offset: CGFloat, done: @escaping () -> Void) {
        guard let layer, !leaving else { return }
        leaving = true
        let wait: TimeInterval
        if case .slide = mode, offset != 0, !Motion.reduced {
            let now = layer.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
            move(layer, from: now, to: offset)
            wait = Motion.pane
        } else {
            fade(layer, from: layer.presentation()?.opacity ?? 1, to: 0)
            wait = Motion.kitFade.seconds
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: done)
    }

    func land(done: @escaping () -> Void) {
        guard let layer, !leaving else { return }
        leaving = true
        let hold = Motion.kitQuick.seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, let layer = self.layer else { return done() }
            fade(layer, from: layer.presentation()?.opacity ?? 1, to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + Motion.kitFade.seconds, execute: done)
        }
    }

    private func move(_ layer: CALayer, from: CGFloat, to: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setValue(to, forKeyPath: "transform.translation.x")
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = from
        slide.toValue = to
        slide.duration = Motion.pane
        slide.timingFunction = Motion.paneTiming
        layer.add(slide, forKey: "slide")
        CATransaction.commit()
    }

    private func fade(_ layer: CALayer, from: Swift.Float, to value: Swift.Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = value
        if let ease = Motion.kitFade.animation("opacity", from: from, to: value) { layer.add(ease, forKey: "fade") }
        CATransaction.commit()
    }
}

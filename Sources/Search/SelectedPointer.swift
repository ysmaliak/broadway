import AppKit
import QuartzCore

@MainActor
final class SelectedPointerView: KitFlippedView {
    enum Edge: Equatable { case above, below }

    static let words = "Show Selected Tab"
    static let height: CGFloat = ceil(KitLabel("Show", font: .systemFont(ofSize: 12)).measure(width: .greatestFiniteMagnitude).height) + 18
    static let side: CGFloat = 14
    static let gap: CGFloat = 6
    static let inset: CGFloat = 6

    private let glass = KitGlass.floating(capsule: true, interactive: true)
    private let inside = KitFlippedView()
    let mark = MarkView(size: SideLook.rowMark)
    let chevron = KitSymbol("chevron.up", style: .init(size: 11, weight: .semibold), tint: KitColor.muted)
    var onPress: (() -> Void)?
    private(set) var live = false

    var edge: Edge = .above {
        didSet { chevron.name = edge == .above ? "chevron.up" : "chevron.down" }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(glass)
        glass.hold(inside)
        inside.addSubview(mark)
        inside.addSubview(chevron)
        identifier = NSUserInterfaceItemIdentifier("column-selected-pointer")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.words)
        alphaValue = 1
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var chevronSize: NSSize {
        let size = chevron.intrinsicContentSize
        return size.width > 0 ? size : NSSize(width: 11, height: 11)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(Self.side + SideLook.rowMark + Self.gap + chevronSize.width + Self.side), height: Self.height)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        inside.frame = glass.bounds
        let mid = bounds.height / 2
        mark.frame = kitSnap(CGRect(x: Self.side, y: mid - SideLook.rowMark / 2, width: SideLook.rowMark, height: SideLook.rowMark))
        let size = chevronSize
        chevron.frame = kitSnap(CGRect(x: mark.frame.maxX + Self.gap, y: mid - size.height / 2, width: size.width, height: size.height))
    }

    func show(_ tab: Tab) {
        mark.icon = tab.icon
        mark.letter = tab.monogram
    }

    func arrive(_ shown: Bool, animated: Bool = true) {
        live = shown
        if shown { isHidden = false }
        kitArrive(shown, Self.arrival(edge), animated: animated && window != nil)
    }

    static func arrival(_ edge: Edge) -> KitArrival {
        let travel: CGFloat = edge == .above ? -8 : 8
        return KitArrival(anchor: edge == .above ? KitArrival.top : KitArrival.bottom, scale: 0.9, travel: CGSize(width: 0, height: travel),
                          leaveScale: 0.94, leaveTravel: CGSize(width: 0, height: travel * 0.6))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard live, !isHidden, onPress != nil else { return nil }
        let inside = convert(point, from: superview)
        return NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).contains(inside) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard live, let onPress else { return false }
        onPress()
        return true
    }
}

enum SelectedPointer {
    static func edge(row: CGRect?, offset: CGFloat, floor: CGFloat, held: Bool = false) -> SelectedPointerView.Edge? {
        guard let row, !held else { return nil }
        if row.midY < offset { return .above }
        if row.midY > offset + floor { return .below }
        return nil
    }

    static func target(row: CGRect, offset: CGFloat, floor: CGFloat, fade: CGFloat) -> CGFloat? {
        if row.minY < offset + fade { return row.minY - fade }
        if row.maxY > offset + floor - fade { return row.maxY - floor + fade }
        return nil
    }

    static func share(_ curve: KitCurve, at time: Double) -> (share: Double, done: Bool) {
        switch curve {
        case .none:
            return (1, true)
        case .spring(let spring):
            let omega = 2 * Double.pi / spring.response
            let left = (1 + omega * time) * exp(-omega * time)
            return left < 0.002 ? (1, true) : (1 - left, false)
        case .easeOut(let duration), .easeInOut(let duration):
            guard duration > 0, time < duration else { return (1, true) }
            let part = time / duration
            return (1 - pow(1 - part, 3), false)
        }
    }
}

@MainActor
final class ScrollGlide {
    private weak var scroll: NSScrollView?
    private let from: CGFloat
    private let to: CGFloat
    private let curve: KitCurve
    private let start = CACurrentMediaTime()
    private var timer: Timer?
    private var last: CGFloat
    private let done: () -> Void

    init(_ scroll: NSScrollView, to target: CGFloat, curve: KitCurve, done: @escaping () -> Void) {
        self.scroll = scroll
        from = scroll.contentView.bounds.minY
        to = target
        last = from
        self.curve = curve
        self.done = done
        guard curve.animates, abs(target - from) > 0.5 else {
            place(target)
            finish()
            return
        }
        let made = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    var running: Bool { timer != nil }

    private func step() {
        guard let scroll else { return stop() }
        guard abs(scroll.contentView.bounds.minY - last) < 0.5 else { return stop() }
        let (share, over) = SelectedPointer.share(curve, at: CACurrentMediaTime() - start)
        place(over ? to : from + (to - from) * share)
        if over { finish() }
    }

    private func place(_ y: CGFloat) {
        guard let scroll else { return }
        let clip = scroll.contentView
        let origin = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: y), size: clip.bounds.size)).origin
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        last = clip.bounds.minY
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        done()
    }

    func stop() {
        guard timer != nil else { return }
        finish()
    }
}

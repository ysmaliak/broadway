import AppKit
import QuartzCore

@MainActor
final class SelectedShortcutView: KitFlippedView {
    enum Edge: Equatable { case above, below }

    static let words = "Show Selected Tab"
    static let travel: CGFloat = 6

    private let plate = KitPlate(radius: Metrics.sideRadius)
    let mark = RowMarkView()
    private let blank = KitSymbol("plus", style: KitSymbol.Style(size: 12, weight: IconLook.control))
    let title = RowTitleView()
    let chevron = KitSymbol("chevron.up", style: .init(size: 11, weight: .semibold))
    var onPress: (() -> Void)?
    var claims: NSRect?
    private(set) var live = false
    private(set) var tabID: Tab.ID?

    var edge: Edge = .above {
        didSet { chevron.name = edge == .above ? "chevron.up" : "chevron.down" }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        addSubview(plate)
        for view in [mark, blank, title, chevron] as [NSView] { addSubview(view) }
        mark.size = SideLook.rowMark
        identifier = NSUserInterfaceItemIdentifier("column-selected-pointer")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.words)
        alphaValue = 1
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ tab: Tab, ground: RowGround, titleSize: CGFloat, icons: Bool, radius: CGFloat) {
        tabID = tab.id
        SelectedLook.dress(plate, greys: ground.greys, ink: ground.ink)
        plate.radius = radius
        let tone = KitTone.strong
        let marked = !tab.isBlank && (icons || tab.customIcon != nil)
        mark.isHidden = !marked
        blank.isHidden = !tab.isBlank
        if marked {
            mark.icon = tab.icon
            mark.letter = tab.monogram
            mark.ink = ground.ink
        }
        blank.tint = tone.base
        blank.opacity = tone.opacity
        blank.ink = ground.ink
        title.label = tab.label
        title.size = titleSize
        title.tone = tone
        title.ink = ground.ink
        chevron.tint = KitTone.muted.base
        chevron.opacity = KitTone.muted.opacity
        chevron.ink = ground.ink
        toolTip = tab.label
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let width = bounds.width
        plate.kitSetFrame(bounds)
        let square = Metrics.closeSquare(height)
        let inset = Metrics.closeInset(height)
        let side = SideLook.rowMark
        var cursor = SideLook.rowLead
        for view in [blank, mark] as [NSView] where !view.isHidden {
            view.kitSetFrame(NSRect(x: cursor, y: (height - side) / 2, width: side, height: side))
        }
        if !mark.isHidden || !blank.isHidden { cursor += side + SideLook.markGap }
        let size = chevron.intrinsicContentSize
        let slot = NSRect(x: width - inset - square, y: inset, width: square, height: square)
        chevron.kitSetFrame(kitSnap(NSRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                                           width: size.width, height: size.height)))
        let line = SideLook.titleLine
        title.kitSetFrame(NSRect(x: cursor, y: (height - line) / 2, width: max(0, slot.minX - SideGrid.tail - cursor), height: line))
    }

    func arrive(_ shown: Bool, animated: Bool = true) {
        live = shown
        if shown {
            isHidden = false
            kitArrive(false, Self.arrival(edge), animated: false)
            kitArrive(true, Self.arrival(edge), animated: animated && window != nil)
        } else {
            kitArrive(false, Self.leaving(edge), animated: animated && window != nil)
        }
    }

    static func arrival(_ edge: Edge) -> KitArrival {
        KitArrival(anchor: edge == .above ? KitArrival.top : KitArrival.bottom, scale: 1,
                   travel: CGSize(width: 0, height: edge == .above ? -travel : travel))
    }

    static func leaving(_ edge: Edge) -> KitArrival {
        KitArrival(anchor: edge == .above ? KitArrival.top : KitArrival.bottom, scale: 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard live, !isHidden, onPress != nil else { return nil }
        let inside = convert(point, from: superview)
        if NSBezierPath(roundedRect: bounds, xRadius: plate.radius, yRadius: plate.radius).contains(inside) { return self }
        return claims?.contains(point) == true ? self : nil
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

enum SelectedShortcut {
    typealias Edge = SelectedShortcutView.Edge

    static let quiet: CFTimeInterval = 0.18

    static func band(_ edge: Edge, offset: CGFloat, visible: CGFloat, height: CGFloat, gap: CGFloat) -> CGRect {
        let y = edge == .above ? offset + gap : offset + visible - gap - height
        return CGRect(x: 0, y: y, width: 1, height: height)
    }

    static func edge(row: CGRect?, offset: CGFloat, visible: CGFloat, height: CGFloat, gap: CGFloat,
                     on: Bool = true, settled: Bool = true) -> Edge? {
        guard on, settled, let row, visible >= height + 2 * gap else { return nil }
        let edge: Edge
        if row.maxY <= offset + 0.5 {
            edge = .above
        } else if row.minY >= offset + visible - 0.5 {
            edge = .below
        } else {
            return nil
        }
        let dock = band(edge, offset: offset, visible: visible, height: height, gap: gap)
        return dock.minY < row.maxY && row.minY < dock.maxY ? nil : edge
    }

    static func target(row: CGRect, offset: CGFloat, visible: CGFloat, fade: CGFloat) -> CGFloat? {
        if row.minY < offset + fade { return row.minY - fade }
        if row.maxY > offset + visible - fade { return row.maxY - visible + fade }
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
        let (share, over) = SelectedShortcut.share(curve, at: CACurrentMediaTime() - start)
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

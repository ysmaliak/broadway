import AppKit

@MainActor
final class SwipeView: NSView {
    var pull: Pull? {
        didSet {
            guard pull != oldValue else { return }
            update(from: oldValue)
        }
    }

    private var disc: GestureDisc?
    private var list: SwipeList?

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        list?.place(in: bounds, animated: false)
    }

    private func update(from old: Pull?) {
        let curve = Motion.kitSlide
        guard let pull else {
            if old?.going == true { disc?.leave() } else { disc?.back() }
            leave(list, curve: curve)
            disc = nil
            list = nil
            return
        }
        if pull.stops != nil {
            disc?.removeFromSuperview()
            disc = nil
            if let list, list.back != pull.back {
                leave(list, curve: curve)
                self.list = nil
            }
            if list == nil {
                let made = SwipeList(back: pull.back)
                addSubview(made)
                list = made
                made.show(pull, in: bounds, animated: false)
                arrive(made, from: 0.92, x: pull.back ? 0 : 1, curve: curve)
            } else {
                list?.show(pull, in: bounds, animated: true)
            }
            return
        }
        if let list { leave(list, curve: curve) }
        list = nil
        let edge: GestureDisc.Edge = pull.back ? .left : .right
        if let disc, disc.edge != edge {
            disc.back()
            self.disc = nil
        }
        let disc = self.disc ?? {
            let made = GestureDisc(edge)
            addSubview(made)
            made.settle(in: self)
            self.disc = made
            return made
        }()
        if pull.going {
            disc.commit()
        } else {
            disc.follow(pull.travel / PageView.arm, armed: pull.armed)
        }
    }

    private func arrive(_ view: NSView, from scale: CGFloat, x: CGFloat = 0.5, curve: KitCurve) {
        guard let layer = view.layer, case .easeOut = curve else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let grow = CABasicAnimation(keyPath: "transform")
        grow.fromValue = NSValue(caTransform3D: swipeScale(scale, view.bounds.size, x: x))
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let group = CAAnimationGroup()
        group.animations = [fade, grow]
        group.duration = Motion.pane
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "arrive")
    }

    private func leave(_ view: NSView?, curve: KitCurve) {
        guard let view else { return }
        guard let layer = view.layer, case .easeOut = curve else {
            view.removeFromSuperview()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in view?.removeFromSuperview() }
        layer.kitAnimate("opacity", to: 0, curve: curve)
        CATransaction.commit()
    }
}

@MainActor
private final class SwipeList: NSView {
    let back: Bool
    private static let pitch: CGFloat = 30
    private let glass = KitGlass(radius: 12, tint: Palette.NS.glassTint)
    private let body = NSView()
    private var rows: [SwipeRow] = []
    private var pull: Pull?

    init(back: Bool) {
        self.back = back
        super.init(frame: .zero)
        wantsLayer = true
        body.wantsLayer = true
        addSubview(body)
        body.addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ pull: Pull, in bounds: CGRect, animated: Bool) {
        let stops = pull.stops ?? []
        if stops != self.pull?.stops {
            rows.forEach { $0.removeFromSuperview() }
            rows = stops.map { stop in
                let row = SwipeRow(stop)
                body.addSubview(row)
                return row
            }
        }
        let was = self.pull
        self.pull = pull
        for (index, row) in rows.enumerated() { row.picked = index == pull.picked }
        let pickedMoved = was.map { $0.picked != pull.picked } ?? false
        place(in: bounds, animated: animated, settle: pickedMoved)
    }

    func place(in bounds: CGRect, animated: Bool) {
        place(in: bounds, animated: animated, settle: false)
    }

    private func place(in bounds: CGRect, animated: Bool, settle: Bool) {
        guard let pull else { return }
        let count = rows.count
        let height = CGFloat(count) * 28 + CGFloat(max(0, count - 1)) * 2 + 10
        let reach = 150 * (1 - exp(-pull.travel / 110))
        let shift = (pull.back ? 1 : -1) * (10 + reach * 0.2)
        let slide = -(CGFloat(pull.picked) - CGFloat(count - 1) / 2) * Self.pitch
        let x = pull.back ? shift : bounds.width - 240 + shift
        let y = (bounds.height - height) / 2
        let target = NSRect(x: x, y: y, width: 240, height: height)
        body.frame = NSRect(origin: .zero, size: target.size)
        glass.frame = body.bounds
        var top: CGFloat = 5
        for row in rows {
            row.frame = NSRect(x: 5, y: top, width: 230, height: 28)
            top += 30
        }
        let moved = target.offsetBy(dx: 0, dy: slide)
        if settle, !Motion.reduced, let layer {
            let from = layer.presentation()?.position ?? layer.position
            frame = moved
            let spring = KitSpring.settle.animation("position", from: NSValue(point: from), to: NSValue(point: layer.position))
            layer.add(spring, forKey: "position")
        } else {
            frame = moved
        }
        guard let layer = body.layer else { return }
        let curve: KitCurve = animated ? Motion.kitSlide : .none
        layer.kitAnimate("transform", to: NSValue(caTransform3D: swipeScale(pull.going ? 0.96 : 1, target.size)), curve: curve)
        layer.kitAnimate("opacity", to: pull.going ? 0 : 1, curve: curve)
    }
}

@MainActor
private final class SwipeRow: NSView {
    private let back = KitBox(fill: nil, corners: .radius(7))
    private let icon: NSView
    private let label = KitLabel()

    var picked = false {
        didSet {
            guard picked != oldValue else { return }
            paint()
        }
    }

    init(_ stop: Stop) {
        if let image = Favicons.shared.cached(for: stop.url) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyUpOrDown
            icon = view
        } else {
            icon = KitSymbol("globe", style: .init(size: 11), tint: KitColor.muted)
        }
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(back)
        addSubview(icon)
        label.text = stop.title.isEmpty ? (stop.url.host() ?? stop.url.absoluteString) : stop.title
        label.font = .systemFont(ofSize: 13)
        addSubview(label)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func paint() {
        back.fill = picked ? Palette.NS.ink.withAlphaComponent(0.10) : nil
        label.opacity = picked ? 1 : 0.75
    }

    override func layout() {
        super.layout()
        back.frame = bounds
        let mid = bounds.height / 2
        if icon is NSImageView {
            icon.frame = kitSnap(NSRect(x: 9, y: mid - 7, width: 14, height: 14))
        } else {
            let size = icon.intrinsicContentSize
            icon.frame = kitSnap(NSRect(x: 9 + (14 - size.width) / 2, y: mid - size.height / 2, width: size.width, height: size.height))
        }
        let x: CGFloat = 9 + 14 + 8
        let height = ceil(label.measure(width: .greatestFiniteMagnitude).height)
        label.frame = kitSnap(NSRect(x: x, y: mid - height / 2, width: max(0, bounds.width - x - 9), height: height))
    }
}

private func swipeScale(_ scale: CGFloat, _ size: CGSize, x: CGFloat = 0.5) -> CATransform3D {
    var transform = CATransform3DMakeTranslation(size.width * x, size.height / 2, 0)
    transform = CATransform3DScale(transform, scale, scale, 1)
    return CATransform3DTranslate(transform, -size.width * x, -size.height / 2, 0)
}

import AppKit

enum PlaySwap {
    static let leave = "play.swap.leave"
    static let arrive = "play.swap.arrive"
    static let small: CGFloat = 0.35
    static let out: CFTimeInterval = 0.16
    static let delay: CFTimeInterval = 0.1
    static let fadeIn: CFTimeInterval = 0.1
    static let spring = KitSpring(response: 0.34, damping: 0.6)
}

final class PlayGlyph: NSImageView {
    static let sidebar = KitSymbol.Style(size: 11, weight: .bold)
    static let float = KitSymbol.Style(size: 21, weight: .semibold)

    let style: KitSymbol.Style
    var tint: NSColor? { didSet { if tint != oldValue { paint() } } }
    private(set) var name = ""
    private(set) var replaced = 0
    private(set) var swapped = false
    private(set) var arriving: CALayer?
    private(set) var leaving: CALayer?
    private var turn = 0

    init(style: KitSymbol.Style, tint: NSColor? = nil) {
        self.style = style
        self.tint = tint
        super.init(frame: .zero)
        imageScaling = .scaleNone
        imageAlignment = .alignCenter
        contentTintColor = tint
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var allowsVibrancy: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    var drawn: NSRect {
        guard let size = image?.size else { return .zero }
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    func show(_ name: String, animated: Bool) {
        guard let next = KitGlyph.image(name, style) else { return }
        let was = self.name
        self.name = name
        guard animated, kitReplaces, let host = layer, !bounds.isEmpty, let incoming = picture(name),
              let outgoing = arriving.map(still) ?? picture(was) else {
            land()
            swapped = false
            image = next
            return
        }
        replaced += 1
        swapped = true
        image = next
        swap(outgoing, incoming, in: host)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { land() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func picture(_ name: String) -> CALayer? {
        guard let image = KitGlyph.image(name, style) else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let wide = Int((image.size.width * scale).rounded()), high = Int((image.size.height * scale).rounded())
        guard wide > 0, high > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: wide, height: high, bitsPerComponent: 8, bytesPerRow: wide * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let whole = NSRect(origin: .zero, size: image.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            image.draw(in: whole)
            (tint ?? .labelColor).set()
            whole.fill(using: .sourceAtop)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let made = context.makeImage() else { return nil }
        let origin = CGPoint(x: ((bounds.width - image.size.width) / 2).rounded(), y: ((bounds.height - image.size.height) / 2).rounded())
        let piece = CALayer()
        piece.contents = made
        piece.contentsScale = scale
        piece.bounds = whole
        piece.position = CGPoint(x: origin.x + whole.width / 2, y: origin.y + whole.height / 2)
        return piece
    }

    private func still(_ piece: CALayer) -> CALayer {
        let now = piece.presentation()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        piece.transform = now?.transform ?? piece.transform
        piece.opacity = now?.opacity ?? piece.opacity
        piece.removeAllAnimations()
        CATransaction.commit()
        arriving = nil
        return piece
    }

    private func swap(_ outgoing: CALayer, _ incoming: CALayer, in host: CALayer) {
        turn += 1
        let turn = turn
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.turn == turn else { return }
            self.land()
        }
        leaving?.removeFromSuperlayer()
        if outgoing.superlayer == nil { host.addSublayer(outgoing) }
        host.addSublayer(incoming)
        leaving = outgoing
        arriving = incoming
        paint()

        let shrunk = CATransform3DMakeScale(PlaySwap.small, PlaySwap.small, 1)
        let leaveScale = CABasicAnimation(keyPath: "transform")
        leaveScale.fromValue = outgoing.transform
        leaveScale.toValue = shrunk
        leaveScale.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.7, 1)
        let leaveFade = CABasicAnimation(keyPath: "opacity")
        leaveFade.fromValue = outgoing.opacity
        leaveFade.toValue = 0
        leaveFade.timingFunction = CAMediaTimingFunction(controlPoints: 0.7, 0, 1, 1)
        let leave = CAAnimationGroup()
        leave.animations = [leaveScale, leaveFade]
        leave.duration = PlaySwap.out
        outgoing.transform = shrunk
        outgoing.opacity = 0
        outgoing.add(leave, forKey: PlaySwap.leave)

        let start = host.convertTime(CACurrentMediaTime(), from: nil) + PlaySwap.delay
        let grow = PlaySwap.spring.animation("transform", from: NSValue(caTransform3D: shrunk), to: NSValue(caTransform3D: CATransform3DIdentity))
        grow.beginTime = start
        grow.fillMode = .backwards
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.duration = PlaySwap.fadeIn
        show.beginTime = start
        show.fillMode = .backwards
        show.timingFunction = CAMediaTimingFunction(name: .easeOut)
        incoming.add(grow, forKey: PlaySwap.arrive)
        incoming.add(show, forKey: PlaySwap.arrive + ".fade")
        CATransaction.commit()
    }

    private func land() {
        guard arriving != nil || leaving != nil else { return }
        let pieces = [arriving, leaving].compactMap { $0 }
        arriving = nil
        leaving = nil
        turn += 1
        paint()
        displayIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pieces.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
    }

    private func paint() {
        contentTintColor = arriving == nil && leaving == nil ? tint : .clear
    }
}

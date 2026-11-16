import AppKit

@MainActor
final class FindHost: NSView {
    let bar: FindBarView
    private(set) weak var browser: Browser?
    private(set) var up = false
    var arrives = true
    private var placed = false
    var pillFrame: CGRect { bar.frame }

    init(browser: Browser) {
        self.browser = browser
        bar = FindBarView(browser: browser)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(bar)
        bar.wantsLayer = true
        bar.layer?.opacity = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func make(_ browser: Browser) -> FindHost { FindHost(browser: browser) }

    override var isFlipped: Bool { true }

    func fit(_ width: CGFloat?) {
        bar.availableWidth = width
        needsLayout = true
    }

    static func wanted(_ browser: Browser) -> Bool { browser.findState.on && !browser.stageVeiled }

    override func layout() {
        super.layout()
        guard let browser else { return }
        let wanted = Self.wanted(browser)
        if wanted || !placed {
            bar.browser = browser
            bar.shown = FindBarView.Shown(browser)
            bar.focusAsk = browser.findState.focus
            let size = bar.intrinsicContentSize
            let frame = CGRect(x: bounds.width - 14 - size.width, y: 12, width: size.width, height: size.height)
            if bar.frame != frame {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                bar.frame = frame
                CATransaction.commit()
            }
        }
        show(wanted)
    }

    private func show(_ now: Bool) {
        guard now != up || !placed else { return }
        if !placed {
            placed = true
            bar.kitArrive(false, Self.arrival, animated: false)
        }
        up = now
        bar.kitArrive(now, Self.arrival, animated: arrives)
    }

    static let arrival = KitArrival(anchor: KitArrival.top, scale: 0.97, travel: CGSize(width: 0, height: -16))

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard up, !isHidden else { return nil }
        let inside = convert(point, from: superview)
        let pill = bar.frame
        guard NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).contains(inside) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class AccountHost: NSView {
    static weak var shown: AccountHost?
    private let list: AccountCardView
    private(set) var spot = CGRect.zero
    var card: CGRect { list.frame }

    init(browser: Browser) {
        list = AccountCardView(browser: browser)
        super.init(frame: .zero)
        addSubview(list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func make(_ browser: Browser, _ asked: Browser.Suggesting) -> AccountHost {
        let host = AccountHost(browser: browser)
        host.show(browser, asked)
        return host
    }

    override var isFlipped: Bool { true }

    func show(_ browser: Browser, _ asked: Browser.Suggesting) {
        list.browser = browser
        list.asked = asked
        spot = asked.spot
        list.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = list.intrinsicContentSize
        list.frame = CGRect(x: spot.minX, y: spot.maxY + 6, width: max(240, min(360, spot.width)), height: size.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Self.shown = self }
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        guard NSBezierPath(roundedRect: list.frame, xRadius: 10, yRadius: 10).contains(inside) else { return nil }
        return super.hitTest(point)
    }
}

@MainActor
final class PairingHost: NSView {
    private let card: ApplePairingCardView
    private(set) var spot = CGRect.zero

    init(browser: Browser, pairing: Browser.ApplePairing) {
        card = ApplePairingCardView(browser: browser, apple: browser.applePasswords, pairing: pairing)
        super.init(frame: .zero)
        addSubview(card)
        show(browser, pairing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func make(_ browser: Browser, _ pairing: Browser.ApplePairing) -> PairingHost {
        PairingHost(browser: browser, pairing: pairing)
    }

    override var isFlipped: Bool { true }

    func show(_ browser: Browser, _ pairing: Browser.ApplePairing) {
        card.apple = browser.applePasswords
        card.pairing = pairing
        spot = pairing.spot
        card.invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = card.intrinsicContentSize
        card.frame = CGRect(x: spot.minX, y: spot.maxY + 6, width: size.width, height: size.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        let hit = CGRect(x: spot.minX, y: spot.maxY + 6, width: max(240, min(360, spot.width)), height: 110)
        return hit.contains(inside) ? super.hitTest(point) : nil
    }
}

extension NSView {
    func kitFade(_ shown: Bool, curve: KitCurve, then done: (() -> Void)? = nil) {
        wantsLayer = true
        guard let layer else { done?(); return }
        layer.kitAnimate("opacity", to: Swift.Float(shown ? 1 : 0), curve: curve)
        guard let done else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + BarStack.leaveTime) { done() }
    }
}

@MainActor
final class PairingCardSurface: KitFlippedView {
    private let card: ApplePairingCardView

    init(browser: Browser, apple: ApplePasswords, pairing: Browser.ApplePairing) {
        card = ApplePairingCardView(browser: browser, apple: apple, pairing: pairing)
        super.init(frame: .zero)
        addSubview(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var offset: CGPoint { CGPoint(x: card.pairing.spot.minX, y: card.pairing.spot.maxY + 6) }

    override var intrinsicContentSize: NSSize {
        let size = card.intrinsicContentSize
        return NSSize(width: size.width, height: size.height + 36)
    }

    override func layout() {
        super.layout()
        let size = card.intrinsicContentSize
        card.frame = CGRect(origin: offset, size: size)
    }
}

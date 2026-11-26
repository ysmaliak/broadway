import AppKit
import Combine
import WebKit

extension Browser {
    func peek(_ url: URL, from tab: Tab) {
        if tab.pin != nil, let host = url.host()?.lowercased() { tab.peeked = (Vault.registrable(host), Date()) }
        let page = makeTab()
        prepare(page)
        page.go(to: url)
        Extensions.shared.openedAside(page)
        do {
            peekTab = page
            peekFrom = tab.id
        }
    }

    func peeksFromPin(_ url: URL, in tab: Tab, on page: URL?) -> Bool {
        guard tab.pin != nil, peekTab == nil, Browser.peekable(url),
              let there = url.host()?.lowercased(),
              let here = page?.host()?.lowercased()
        else { return false }
        return there != here && Vault.registrable(there) != Vault.registrable(here)
    }

    static func peekable(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host() != nil
    }

    func peekWindow(_ configuration: WKWebViewConfiguration, from tab: Tab, going url: URL) -> Tab {
        let page = Tab(shy: tab.shy, configuration: configuration)
        prepare(page)
        page.opener = tab.id
        page.setAddressOptimistically(url)
        if let host = url.host()?.lowercased() { tab.peeked = (Vault.registrable(host), Date()) }
        Extensions.shared.openedAside(page)
        do {
            peekTab = page
            peekFrom = tab.id
        }
        return page
    }

    func followsPeek(_ url: URL, in tab: Tab) -> Bool {
        guard tab.pin != nil, let peeked = tab.peeked,
              Date().timeIntervalSince(peeked.at) < 3,
              let host = url.host()?.lowercased()
        else { return false }
        return Vault.registrable(host) == peeked.site
    }

    func closePeek() {
        if fileChoice?.tabID == peekTab?.id { fileChoice?.cancel() }
        guard let page = peekTab else { return }
        do {
            peekTab = nil
            peekFrom = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Browser.peekLeaves) { page.close() }
    }

    static var peekLeaves: TimeInterval { Motion.reduced ? 0 : 0.2 }

    func keepPeek(beside: Bool = false) {
        guard let page = peekTab else { return }
        let from = active
        let place = placeForNew()
        if !page.shy, let from = active { page.groupID = from.groupID }
        do {
            peekTab = nil
            peekFrom = nil
        }
        insert(page, at: place)
        if beside, prefs.splitView, let from, canSplit(page, with: from) {
            pair(page, with: from, onLeft: false)
        } else {
            select(page)
        }
    }
}

@MainActor
final class PeekView: NSView {
    let browser: Browser

    private let dim = KitBox(fill: NSColor(white: 0, alpha: KitColor.dim))
    private let panel: PeekPanelView
    private var tab: Tab?
    private var leaving = false
    private var leaveTicket = 0
    private var watching: AnyCancellable?
    private var pressed = false

    init(browser: Browser) {
        self.browser = browser
        panel = PeekPanelView(browser: browser)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        wantsLayer = true
        dim.wantsLayer = true
        addSubview(dim)
        addSubview(panel)
        isHidden = true
        watching = kitObserve({ [weak self] in self?.heard() }) { [weak self] _ in self?.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard browser.peekTab != nil, !leaving, !isHidden, frame.contains(point) else { return nil }
        let hit = super.hitTest(point)
        if hit == nil || hit === dim || hit === panel || hit === self { return self }
        return hit
    }

    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { browser.closePeek() }
    }

    private func heard() {
        let now = browser.peekTab
        _ = (browser.tabs.map(\.id), browser.prefs.splitView)
        guard let now else { return }
        _ = (now.isWeb, now.asleep, now.floating, now.painted, now.failure == nil)
    }

    private func update() {
        guard let now = browser.peekTab else {
            if let tab, !leaving { leave(kept: browser.tabs.contains { $0 === tab }) }
            return
        }
        let arriving = tab == nil || leaving
        if tab !== now {
            tab = now
            panel.tab = now
        }
        leaving = false
        leaveTicket += 1
        panel.split = browser.prefs.splitView
        panel.refresh()
        if arriving { arrive() }
    }

    override func layout() {
        super.layout()
        dim.frame = bounds
        panel.frame = bounds
        if let layer = panel.layer, layer.animation(forKey: "transform") == nil {
            layer.transform = leaving || tab == nil ? shrunk : CATransform3DIdentity
        }
    }

    private var shrunk: CATransform3D {
        let mid = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        return CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                       CATransform3DMakeScale(0.98, 0.98, 1)), mid)
    }

    private func arrive() {
        let fresh = isHidden
        isHidden = false
        needsLayout = true
        layoutSubtreeIfNeeded()
        guard let dimLayer = dim.layer, let panelLayer = panel.layer else { return }
        if fresh {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dimLayer.opacity = 0
            panelLayer.opacity = 0
            panelLayer.transform = shrunk
            CATransaction.commit()
        }
        let curve = Motion.kitSettle
        dimLayer.kitAnimate("opacity", to: NSNumber(value: 1), curve: curve)
        panelLayer.kitAnimate("opacity", to: NSNumber(value: 1), curve: curve)
        panelLayer.kitAnimate("transform", to: NSValue(caTransform3D: CATransform3DIdentity), curve: curve)
    }

    private func leave(kept: Bool) {
        leaving = true
        leaveTicket += 1
        let ticket = leaveTicket
        if kept { panel.release() }
        let curve = Motion.kitQuick
        dim.layer?.kitAnimate("opacity", to: NSNumber(value: 0), curve: curve)
        panel.layer?.kitAnimate("opacity", to: NSNumber(value: 0), curve: curve)
        panel.layer?.kitAnimate("transform", to: NSValue(caTransform3D: shrunk), curve: curve)
        let finish = { [weak self] in
            guard let self, leaving, leaveTicket == ticket else { return }
            leaving = false
            tab = nil
            panel.release()
            panel.tab = nil
            isHidden = true
        }
        if case .easeOut(let duration) = curve {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: finish)
        } else {
            finish()
        }
    }
}

@MainActor
private final class PeekPanelView: NSView {
    let browser: Browser
    var tab: Tab? {
        didSet {
            guard tab !== oldValue else { return }
            overlays?.removeFromSuperview()
            overlays = nil
            dropSkeleton(animated: false)
            if let tab {
                let made = TabPageView.peek(tab)
                clip.addSubview(made, positioned: .above, relativeTo: stage)
                overlays = made
            } else {
                stage.show(nil)
            }
            needsLayout = true
        }
    }
    var split = false { didSet { if split != oldValue { knobs.split = split; needsLayout = true } } }

    private let shade = PeekShadow()
    private let clip = KitBox(fill: Palette.NS.ground, corners: .radius(12))
    private let stage = StageView()
    private var overlays: NSView?
    private var skeleton: PeekSkeletonView?
    private let edge = KitBox(fill: nil, stroke: KitColor.hairline, corners: .radius(12))
    private let knobs: PeekKnobsView

    init(browser: Browser) {
        self.browser = browser
        knobs = PeekKnobsView(split: false,
                              close: { [weak browser] in browser?.closePeek() },
                              open: { [weak browser] in browser?.keepPeek(beside: NSEvent.modifierFlags.contains(.option)) },
                              beside: { [weak browser] in browser?.keepPeek(beside: true) })
        super.init(frame: .zero)
        wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.addSubview(stage)
        for view in [shade, clip, edge, knobs] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func refresh() {
        guard let tab else { return }
        stage.show(!tab.isWeb || tab.asleep || tab.floating ? nil : tab.web)
        if !tab.painted && tab.failure == nil {
            if skeleton == nil {
                let made = PeekSkeletonView()
                made.frame = clip.bounds
                clip.addSubview(made, positioned: .above, relativeTo: overlays ?? stage)
                skeleton = made
            }
        } else {
            dropSkeleton(animated: true)
        }
    }

    func release() {
        stage.show(nil)
        overlays?.removeFromSuperview()
        overlays = nil
        dropSkeleton(animated: false)
    }

    private func dropSkeleton(animated: Bool) {
        guard let skeleton else { return }
        self.skeleton = nil
        let curve = Motion.kitQuick
        guard animated, case .easeOut(let duration) = curve, let layer = skeleton.layer else {
            skeleton.removeFromSuperview()
            return
        }
        layer.kitAnimate("opacity", to: NSNumber(value: 0), curve: curve)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { skeleton.removeFromSuperview() }
    }

    override func layout() {
        super.layout()
        let (whole, knobFrame) = PeekKnobsView.places(in: bounds, split: split)
        let page = kitSnap(whole)
        shade.frame = page
        clip.frame = page
        edge.frame = page
        let inside = NSRect(origin: .zero, size: page.size)
        stage.frame = inside
        overlays?.frame = inside
        skeleton?.frame = inside
        knobs.frame = kitSnap(knobFrame)
    }
}

@MainActor
private final class PeekShadow: NSView {
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
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 30
        layer.shadowOffset = CGSize(width: 0, height: 10)
        layer.shadowPath = KitPath.continuous(bounds, radius: 12)
    }
}

@MainActor
final class PeekKnobsView: NSView {
    var split: Bool { didSet { if split != oldValue { beside.isHidden = !split; invalidateIntrinsicContentSize(); needsLayout = true } } }

    private let container = NSGlassEffectContainerView()
    private let column = PeekKnobColumn()
    private let close: KitButton
    private let open: KitButton
    private let beside: KitButton

    static let edge: CGFloat = 4
    static let lean: CGFloat = 21

    static func places(in bounds: NSRect, split: Bool) -> (page: NSRect, knobs: NSRect) {
        let size = size(split: split)
        let width = max(0, min(bounds.width * 0.82, bounds.width - 2 * (edge + lean)))
        let height = bounds.height * 0.86
        let x = (bounds.width - width) / 2 + lean
        let y = (bounds.height - height) / 2
        return (NSRect(x: x, y: y, width: max(0, width - 10 - size.width), height: height),
                NSRect(x: x + width - size.width, y: y, width: size.width, height: size.height))
    }

    static func size(split: Bool) -> NSSize {
        let count: CGFloat = split ? 3 : 2
        return NSSize(width: 28, height: 28 * count + 8 * (count - 1))
    }

    init(split: Bool, close: @escaping () -> Void, open: @escaping () -> Void, beside: @escaping () -> Void) {
        self.split = split
        func knob(_ symbol: String, label: String, help: String, act: @escaping () -> Void) -> KitButton {
            let button = PeekKnob(.plain(press: 1), label: label, action: act)
            let glass = KitGlassFace(KitSymbol(symbol, style: .init(size: 11, weight: .semibold), tint: KitColor.ink))
            glass.effectIsInteractive = true
            button.content = glass
            button.tint()
            button.height = 28
            button.kitAccess(label: label, role: .button, help: help)
            return button
        }
        self.close = knob("xmark", label: "Close", help: "Close   esc", act: close)
        self.open = knob("arrow.up.left.and.arrow.down.right", label: "Open as a Tab", help: "Open as a Tab   ⌘↩", act: open)
        self.beside = knob("rectangle.split.2x1", label: "Keep Beside This Page", help: "Keep Beside This Page   ⌥⌘↩", act: beside)
        super.init(frame: NSRect(origin: .zero, size: Self.size(split: split)))
        container.spacing = 4
        container.contentView = column
        for button in [self.close, self.open, self.beside] { column.addSubview(button) }
        self.beside.isHidden = !split
        addSubview(container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size(split: split) }

    override func layout() {
        super.layout()
        container.frame = bounds
        column.frame = bounds
        for (index, button) in [close, open, beside].enumerated() {
            button.frame = NSRect(x: 0, y: CGFloat(index) * 36, width: 28, height: 28)
        }
    }
}

private final class PeekKnobColumn: NSView {
    override var isFlipped: Bool { true }
}

final class PeekKnob: KitButton {
    var glass: KitGlassFace? { content as? KitGlassFace }

    func tint() {
        glass?.tintColor = KitGlass.keyTint(.secondary, dark: kitDark)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tint()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? glassCatcher ?? self : nil
    }
}

@MainActor
final class PeekSkeletonView: NSView {
    static let light = NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.225 : 0.975, alpha: 1)
    }

    private let bones = CAShapeLayer()
    private let sheenBox = CALayer()
    private let sheenMask = CAShapeLayer()
    private let sheen = CAGradientLayer()
    private var shown = false
    private var swept: CGSize?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for layer in [bones, sheenBox, sheenMask, sheen] as [CALayer] {
            layer.actions = ["bounds": NSNull(), "position": NSNull(), "path": NSNull(), "hidden": NSNull(),
                             "fillColor": NSNull(), "colors": NSNull(), "contents": NSNull()]
        }
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheenBox.mask = sheenMask
        sheenBox.addSublayer(sheen)
        bones.isHidden = true
        sheenBox.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            shown = true
            needsLayout = true
            needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        guard let layer else { return }
        if bones.superlayer !== layer {
            layer.addSublayer(bones)
            layer.addSublayer(sheenBox)
        }
        let dark = kitDark
        layer.backgroundColor = Palette.NS.ground.kitResolved(dark: dark).cgColor
        bones.fillColor = Palette.NS.wash.kitResolved(dark: dark).cgColor
        let light = Self.light.kitResolved(dark: dark)
        sheen.colors = [light.withAlphaComponent(0).cgColor, light.cgColor, light.withAlphaComponent(0).cgColor]
        sheen.locations = [0, 0.5, 1]
    }

    override func layout() {
        super.layout()
        let size = bounds.size
        let path = Self.bones(in: size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bones.frame = bounds
        bones.path = path
        sheenBox.frame = bounds
        sheenMask.frame = bounds
        sheenMask.path = path
        bones.isHidden = !shown
        sheenBox.isHidden = !shown || Motion.reduced
        let width = size.width * 0.6
        sheen.bounds = CGRect(x: 0, y: 0, width: width, height: size.height)
        sheen.position = CGPoint(x: size.width / 2 - size.width * 0.8, y: size.height / 2)
        CATransaction.commit()
        guard shown, !Motion.reduced, !Motion.calm else {
            sheen.removeAnimation(forKey: "sweep")
            swept = nil
            return
        }
        guard swept != size else { return }
        swept = size
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = size.width / 2 - size.width * 0.8
        sweep.toValue = size.width / 2 + size.width * 0.8
        sweep.duration = 1.3
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.repeatCount = .infinity
        sheen.add(sweep, forKey: "sweep")
    }

    static func bones(in size: CGSize) -> CGPath {
        let width = max(0, min(size.width - 64, 760))
        let left = (size.width - width) / 2
        let path = CGMutablePath()
        func bar(_ x: CGFloat, _ y: CGFloat, _ length: CGFloat, _ height: CGFloat) {
            let rect = CGRect(x: left + x, y: y, width: max(0, length), height: height)
            guard rect.width > 0 else { return }
            let radius = min(rect.width, rect.height) / 2
            path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) {
            path.addEllipse(in: CGRect(x: left + x, y: y, width: side, height: side))
        }
        var y: CGFloat = 28
        circle(0, y, 22)
        bar(32, y + 6, 96, 10)
        bar(width - 36, y + 7, 36, 8)
        bar(width - 36 - 10 - 52, y + 7, 52, 8)
        bar(width - 36 - 10 - 52 - 10 - 44, y + 7, 44, 8)
        y += 22 + 44
        bar(0, y, width * 0.72, 22)
        y += 22 + 12
        bar(0, y, width * 0.46, 22)
        y += 22 + 18
        circle(0, y, 16)
        bar(24, y + 4, 120, 8)
        y += 16 + 26
        let picture = CGRect(x: left, y: y, width: width, height: width * 0.36)
        if picture.width > 0 {
            path.addRoundedRect(in: picture, cornerWidth: min(10, picture.height / 2), cornerHeight: min(10, picture.height / 2))
        }
        y += width * 0.36 + 28
        for part in [1, 0.97, 0.93, 0.98, 0.62] as [CGFloat] {
            bar(0, y, width * part, 9)
            y += 9 + 14
        }
        y += 14
        for part in [0.95, 1, 0.84] as [CGFloat] {
            bar(0, y, width * part, 9)
            y += 9 + 14
        }
        return path
    }
}

import AppKit
import Combine

@MainActor
enum PlanCardsLogic {
    static func cards(_ plans: Plans, _ prefs: Preferences) -> [PlanCard] {
        PlanCards.cards(statuses: plans.statuses, looked: plans.looked, chosen: prefs.aiPlan)
    }
}

final class PlanCardsView: NSView, KitFits {
    let browser: Browser
    let prefs: Preferences
    let plans: Plans

    private let heading = KitLabel("Your plans", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
    private let again: PlanLookAgainButton
    private var tiles: [PlanTileView] = []
    private var helpers: [HelperTileView] = []
    private var watch: AnyCancellable?
    private(set) var cards: [PlanCard] = []

    init(browser: Browser, prefs: Preferences, plans: Plans) {
        self.browser = browser
        self.prefs = prefs
        self.plans = plans
        again = PlanLookAgainButton(plans: plans)
        super.init(frame: .zero)
        heading.setAccessibilityRole(.staticText)
        addSubview(heading)
        addSubview(again)
        watch = kitTrack { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var onResize: (() -> Void)?

    func refresh() {
        let next = PlanCardsLogic.cards(plans, prefs)
        let planCards = next.filter { PlanCardKind.plans.contains($0.kind) }
        let helperCards = next.filter { PlanCardKind.helpers.contains($0.kind) }
        if tiles.map(\.card.kind) != planCards.map(\.kind) {
            tiles.forEach { $0.removeFromSuperview() }
            tiles = planCards.map { PlanTileView(card: $0, browser: browser, prefs: prefs) }
            tiles.forEach(addSubview)
        } else {
            for (tile, card) in zip(tiles, planCards) { tile.show(card) }
        }
        if helpers.map(\.card.kind) != helperCards.map(\.kind) {
            helpers.forEach { $0.removeFromSuperview() }
            helpers = helperCards.map { HelperTileView(card: $0, browser: browser) }
            helpers.forEach(addSubview)
        } else {
            for (tile, card) in zip(helpers, helperCards) { tile.show(card) }
        }
        again.refresh()
        let changed = next != cards
        cards = next
        invalidateIntrinsicContentSize()
        needsLayout = true
        if changed { onResize?() }
    }

    private func columns(_ width: CGFloat, _ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return (width - CGFloat(count - 1) * 12) / CGFloat(count)
    }

    private func rowHeight(_ views: [KitFits], width: CGFloat) -> CGFloat {
        let column = columns(width, views.count)
        return views.map { $0.kitHeight(width: column) }.max() ?? 0
    }

    func kitHeight(width: CGFloat) -> CGFloat {
        22 + 10 + rowHeight(tiles, width: width) + 12 + rowHeight(helpers, width: width)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width > 0 ? bounds.width : 600))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let size = heading.intrinsicContentSize
        heading.frame = kitSnap(NSRect(x: 0, y: (22 - size.height) / 2, width: size.width, height: size.height))
        again.frame = NSRect(x: width - 22, y: 0, width: 22, height: 22)
        var y: CGFloat = 32
        for row in [tiles as [NSView & KitFits], helpers as [NSView & KitFits]] {
            let column = columns(width, row.count)
            let height = row.map { $0.kitHeight(width: column) }.max() ?? 0
            for (index, tile) in row.enumerated() {
                let x = (column + 12) * CGFloat(index)
                tile.frame = kitSnap(NSRect(x: x, y: y, width: column, height: height))
            }
            y += height + 12
        }
    }
}

final class PlanLookAgainButton: KitButton {
    let plans: Plans
    private let arrow = KitSymbol("arrow.clockwise", style: .init(size: 12, weight: .semibold), tint: .secondaryLabelColor)
    private let spinner = NSProgressIndicator()
    private let holder = KitFlippedView()
    private var looking = false

    init(plans: Plans) {
        self.plans = plans
        super.init(.plain(press: 1), label: "Look Again")
        holder.addSubview(arrow)
        holder.addSubview(spinner)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = true
        content = holder
        toolTip = "Look again after installing or signing in"
        action = { [weak self] in
            guard let self else { return }
            Task { await self.plans.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }

    override func layout() {
        super.layout()
        holder.frame = bounds
        let size = arrow.intrinsicContentSize
        arrow.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        spinner.frame = NSRect(x: (bounds.width - 10) / 2, y: (bounds.height - 10) / 2, width: 10, height: 10)
    }

    func refresh() {
        let now = plans.looking
        defer { looking = now }
        if now != looking {
            arrow.layer?.kitTransition(Motion.kitQuick)
            spinner.layer?.kitTransition(Motion.kitQuick)
        }
        arrow.alphaValue = now ? 0 : 1
        spinner.alphaValue = now ? 1 : 0
        if now { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        isEnabled = !now
        setAccessibilityLabel(now ? "Looking for your plans" : "Look Again")
    }
}

final class PlanTileGround: KitBox {
    var tint: NSColor = .clear { didSet { if tint != oldValue { needsDisplay = true } } }
    var chosen = false { didSet { if chosen != oldValue { needsDisplay = true } } }
    var lit = false { didSet { if lit != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        corners = .radius(14)
        gradientAxis = (CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        let dark = kitDark
        fill = dark ? NSColor(white: 1, alpha: lit ? 0.075 : 0.055) : NSColor(white: 0, alpha: lit ? 0.05 : 0.035)
        gradient = chosen ? [tint.withAlphaComponent(dark ? 0.22 : 0.13), tint.withAlphaComponent(dark ? 0.04 : 0.02)] : []
        stroke = chosen ? tint.withAlphaComponent(dark ? 0.85 : 0.75)
            : (dark ? NSColor(white: 1, alpha: lit ? 0.16 : 0.1) : NSColor(white: 0, alpha: lit ? 0.13 : 0.08))
        strokeWidth = chosen ? 1.5 : 0.75
        super.updateLayer()
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = chosen ? (dark ? 0.3 : 0.08) : 0
        layer?.shadowRadius = 3
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
}

final class PlanDefaultMark: NSView {
    enum Mode: Equatable { case none, chosen, offer }

    var tint: NSColor = .controlAccentColor { didSet { capsule.fill = tint } }
    private(set) var mode: Mode = .none
    var hovering = false { didSet { if hovering != oldValue { swapHover() } } }

    private static let line = KitForm.wash(light: 0.224, dark: 0.2475)

    private let capsule = KitBox(fill: nil, corners: .capsule)
    private let tick = KitSymbol("checkmark", style: .init(size: 9, weight: .heavy), tint: .white)
    private let chosenWords = KitLabel("Default", font: .systemFont(ofSize: 11, weight: .semibold), color: .white)
    private let ring = KitBox(fill: nil, corners: .capsule)
    private let offer = KitBox(fill: nil, corners: .capsule)
    private let offerWords = KitLabel("Make Default", font: .systemFont(ofSize: 11, weight: .medium), color: .secondaryLabelColor)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        capsule.addSubview(tick)
        capsule.addSubview(chosenWords)
        offer.addSubview(offerWords)
        for view in [capsule, ring, offer] { addSubview(view) }
        ring.strokeWidth = 1.25
        offer.strokeWidth = 1
        setAccessibilityElement(false)
        set(.none, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var capsuleSize: NSSize {
        NSSize(width: 8 + tick.intrinsicContentSize.width + 4 + chosenWords.intrinsicContentSize.width + 8, height: 20)
    }

    private var offerSize: NSSize { NSSize(width: offerWords.intrinsicContentSize.width + 16, height: 20) }

    override var intrinsicContentSize: NSSize {
        switch mode {
        case .none: return .zero
        case .chosen: return capsuleSize
        case .offer: return NSSize(width: max(19, offerSize.width), height: 20)
        }
    }

    func set(_ next: Mode, animated: Bool) {
        let before = mode
        mode = next
        ring.stroke = Self.line
        offer.stroke = Self.line
        capsule.fill = tint
        capsule.isHidden = next != .chosen
        ring.isHidden = next != .offer
        offer.isHidden = next != .offer
        swapHover(animated: false)
        invalidateIntrinsicContentSize()
        needsLayout = true
        guard animated, before != next, let layer = capsule.layer else { return }
        if next == .chosen {
            capsule.layoutSubtreeIfNeeded()
            let spring = Motion.kitSettle
            capsule.alphaValue = 1
            layer.kitAnimate("opacity", to: 1, curve: spring)
            if let scale = spring.animation("transform.scale", from: 0.8, to: 1) { layer.add(scale, forKey: "arrive") }
            if let fade = spring.animation("opacity", from: 0, to: 1) { layer.add(fade, forKey: "opacity") }
        }
    }

    private func swapHover(animated: Bool = true) {
        let curve: KitCurve = animated ? Motion.kitQuick : .none
        ring.layer?.kitAnimate("opacity", to: hovering ? 0 : 1, curve: curve)
        offer.layer?.kitAnimate("opacity", to: hovering ? 1 : 0, curve: curve)
    }

    override func layout() {
        super.layout()
        let size = capsuleSize
        capsule.frame = NSRect(x: bounds.width - size.width, y: 0, width: size.width, height: 20)
        let tickSize = tick.intrinsicContentSize
        let wordsSize = chosenWords.intrinsicContentSize
        tick.frame = kitSnap(NSRect(x: 8, y: (20 - tickSize.height) / 2, width: tickSize.width, height: tickSize.height))
        chosenWords.frame = kitSnap(NSRect(x: 8 + tickSize.width + 4, y: (20 - wordsSize.height) / 2, width: wordsSize.width, height: wordsSize.height))
        ring.frame = NSRect(x: bounds.width - 19, y: 1, width: 18, height: 18)
        let offer = offerSize
        self.offer.frame = NSRect(x: bounds.width - offer.width, y: 0, width: offer.width, height: 20)
        let offerWordsSize = offerWords.intrinsicContentSize
        offerWords.frame = kitSnap(NSRect(x: 8, y: (20 - offerWordsSize.height) / 2, width: offerWordsSize.width, height: offerWordsSize.height))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ring.needsDisplay = true
        offer.needsDisplay = true
    }
}

final class PlanTileTop: KitFlippedView {
    var enabled = true
    var onPress: (() -> Void)?
    private var pressed = false { didSet { if pressed != oldValue { layer?.kitAnimate("opacity", to: pressed ? 0.82 : 1, curve: Motion.kitQuick) } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit === self || hit.isDescendant(of: self) ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        pressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard enabled else { return }
        pressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let fire = pressed && enabled
        pressed = false
        if fire { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        guard enabled else { return false }
        onPress?()
        return true
    }

    override func isAccessibilityEnabled() -> Bool { enabled }
}

final class PlanTileView: KitHoverView, KitFits {
    private(set) var card: PlanCard
    let browser: Browser
    let prefs: Preferences

    private let ground = PlanTileGround()
    private let top = PlanTileTop()
    private let mark: ProviderMarkView
    private let defaultMark = PlanDefaultMark()
    private let name = KitLabel("", font: .systemFont(ofSize: 15, weight: .semibold), color: .labelColor)
    private let detail = KitParagraph("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private var bottom: PlanFixView?

    init(card: PlanCard, browser: Browser, prefs: Preferences) {
        self.card = card
        self.browser = browser
        self.prefs = prefs
        mark = ProviderMarkView(kind: card.kind, size: 40, lit: card.lit)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(ground)
        addSubview(top)
        for view in [mark, defaultMark, name, detail] { top.addSubview(view) }
        name.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
        top.onPress = { [weak self] in
            guard let self, let plan = PlanCards.choose(self.card) else { return }
            self.prefs.aiPlan = plan
        }
        show(card, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ next: PlanCard, animated: Bool = true) {
        let before = card
        card = next
        let tint = ProviderMarkView.tint(next.kind)
        ground.tint = tint
        defaultMark.tint = tint
        if animated, before.isDefault != next.isDefault { ground.layer?.kitTransition(Motion.kitSettle) }
        ground.chosen = next.isDefault
        defaultMark.set(next.isDefault ? .chosen : next.canBeDefault ? .offer : .none, animated: animated)
        mark.kind = next.kind
        mark.lit = next.lit
        name.text = next.kind.name
        name.color = next.lit ? .labelColor : .secondaryLabelColor
        detail.text = next.detail
        top.enabled = next.canBeDefault
        top.setAccessibilityLabel("\(next.kind.name), \(next.detail)")
        top.setAccessibilityHelp(next.canBeDefault && !next.isDefault ? "Makes \(next.kind.name) the default" : nil)
        top.setAccessibilitySelected(next.isDefault)
        replaceBottom(animated: animated && before != next)
        paintHover()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func replaceBottom(animated: Bool) {
        let wanted = card.state.ready ? nil : card.fix
        guard wanted != bottom?.fix else { return }
        bottom?.removeFromSuperview()
        bottom = wanted.map { PlanFixView(fix: $0, browser: browser) }
        if let bottom { addSubview(bottom) }
        if animated { layer?.kitTransition(Motion.kitSettle) }
    }

    override func hoverChanged() { paintHover(animated: true) }

    private func paintHover(animated: Bool = false) {
        let lit = hovering && card.canBeDefault && !card.isDefault
        if animated, lit != ground.lit { ground.layer?.kitTransition(Motion.kitQuick) }
        ground.lit = lit
        defaultMark.hovering = hovering
    }

    private func topHeight(width: CGFloat) -> CGFloat {
        14 + 40 + 12 + name.intrinsicContentSize.height + 2 + detailHeight(width: width) + 12
    }

    private func detailHeight(width: CGFloat) -> CGFloat {
        let line = ceil(detail.font.ascender - detail.font.descender + detail.font.leading)
        return min(detail.height(for: width - 28), line * 2)
    }

    func kitHeight(width: CGFloat) -> CGFloat {
        topHeight(width: width) + (bottom.map { $0.kitHeight(width: width - 28) + 18 } ?? 4)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width > 0 ? bounds.width : 300))
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let width = bounds.width
        let topHeight = topHeight(width: width)
        top.frame = NSRect(x: 0, y: 0, width: width, height: bottom == nil ? bounds.height : topHeight)
        mark.frame = NSRect(x: 14, y: 14, width: 40, height: 40)
        let markSize = defaultMark.intrinsicContentSize
        defaultMark.frame = NSRect(x: width - 14 - markSize.width, y: 14, width: markSize.width, height: markSize.height)
        let nameSize = name.intrinsicContentSize
        name.frame = kitSnap(NSRect(x: 14, y: 66, width: min(width - 28, nameSize.width), height: nameSize.height))
        detail.frame = kitSnap(NSRect(x: 14, y: 66 + nameSize.height + 2, width: width - 28, height: detailHeight(width: width)))
        bottom?.frame = NSRect(x: 14, y: topHeight, width: width - 28, height: bottom?.kitHeight(width: width - 28) ?? 0)
    }
}

final class PlanFixView: NSView, KitFits {
    let fix: PlanCardFix
    let browser: Browser
    private let box = KitBox(fill: KitForm.wash(light: 0.057, dark: 0.061), corners: .radius(6))
    private let command = NSTextField(labelWithString: "")
    private let button: KitBroadwayButton

    init(fix: PlanCardFix, browser: Browser) {
        self.fix = fix
        self.browser = browser
        let face = PlanFixFace(title: fix.title, symbol: fix.command == nil ? "arrow.up.forward.app" : "doc.on.doc")
        button = KitBroadwayButton(content: face, small: true, label: fix.title) { PlanFix.run(fix, browser: browser) }
        super.init(frame: .zero)
        if let text = fix.command {
            command.stringValue = text
            command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            command.textColor = .secondaryLabelColor
            command.lineBreakMode = .byTruncatingMiddle
            command.isSelectable = true
            command.toolTip = text
            box.addSubview(command)
            addSubview(box)
        }
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func kitHeight(width: CGFloat) -> CGFloat { (fix.command == nil ? 0 : 30) + 22 }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width)) }

    override func layout() {
        super.layout()
        var y: CGFloat = 0
        if fix.command != nil {
            box.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 22)
            let height = ceil(command.intrinsicContentSize.height)
            command.frame = kitSnap(NSRect(x: 6, y: (22 - height) / 2, width: bounds.width - 12, height: height))
            y = 30
        }
        let size = button.intrinsicContentSize
        button.frame = NSRect(x: 0, y: y, width: size.width, height: 22)
    }
}

final class PlanFixFace: KitFlippedView {
    private let glyph: KitSymbol
    private let words: KitLabel

    init(title: String, symbol: String) {
        glyph = KitSymbol(symbol, style: .init(size: 12), tint: KitColor.ink)
        words = KitLabel(title, font: .systemFont(ofSize: 12), color: KitColor.ink)
        super.init(frame: .zero)
        addSubview(glyph)
        addSubview(words)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let glyph = glyph.intrinsicContentSize
        let words = words.intrinsicContentSize
        return NSSize(width: glyph.width + 8 + words.width, height: max(glyph.height, words.height))
    }

    override func layout() {
        super.layout()
        let glyphSize = glyph.intrinsicContentSize
        let wordsSize = words.intrinsicContentSize
        glyph.frame = kitSnap(NSRect(x: 0, y: (bounds.height - glyphSize.height) / 2, width: glyphSize.width, height: glyphSize.height))
        words.frame = kitSnap(NSRect(x: glyphSize.width + 8, y: (bounds.height - wordsSize.height) / 2, width: wordsSize.width, height: wordsSize.height))
    }
}

enum PlanFix {
    static let appleIntelligence = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!

    @MainActor
    static func run(_ fix: PlanCardFix, browser: Browser) {
        switch fix {
        case .install(let command), .signIn(let command):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            browser.announce("Copied. Paste it in Terminal, then look again.")
        case .appleIntelligence:
            NSWorkspace.shared.open(appleIntelligence)
        }
    }
}

final class HelperTileView: NSView, KitFits {
    private(set) var card: PlanCard
    let browser: Browser

    private let ground = PlanTileGround()
    private let mark: ProviderMarkView
    private let name = KitLabel("", font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor)
    private let detail = KitParagraph("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private var trailing: NSView?
    private var trailingKey = ""

    init(card: PlanCard, browser: Browser) {
        self.card = card
        self.browser = browser
        mark = ProviderMarkView(kind: card.kind, size: 32, lit: card.lit)
        super.init(frame: .zero)
        for view in [ground, mark, name, detail] { addSubview(view) }
        setAccessibilityElement(false)
        show(card)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ next: PlanCard) {
        card = next
        ground.tint = ProviderMarkView.tint(next.kind)
        mark.kind = next.kind
        mark.lit = next.lit
        name.text = next.kind.name
        name.color = next.lit ? .labelColor : .secondaryLabelColor
        detail.text = next.state.ready ? next.kind.role : next.detail
        replaceTrailing()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func replaceTrailing() {
        let key: String
        if card.state.ready { key = "ready" }
        else if let fix = card.fix { key = "fix:\(fix.title)" }
        else { key = "" }
        guard key != trailingKey else { return }
        trailingKey = key
        trailing?.removeFromSuperview()
        trailing = nil
        let tint = ProviderMarkView.tint(card.kind)
        if key == "ready" {
            let check = KitSymbol("checkmark.circle.fill", style: .init(size: 14), tint: tint, label: "Ready")
            trailing = check
        } else if let fix = card.fix {
            let button = KitBroadwayButton("Open Settings", small: true)
            button.action = { [weak self] in
                guard let self else { return }
                PlanFix.run(fix, browser: self.browser)
            }
            trailing = button
        }
        if let trailing { addSubview(trailing) }
    }

    private var trailingSize: NSSize {
        guard let trailing else { return .zero }
        return trailing.intrinsicContentSize
    }

    private func textWidth(_ width: CGFloat) -> CGFloat {
        width - 24 - 32 - 12 - (trailing == nil ? 0 : trailingSize.width + 12) + 1
    }

    private func detailHeight(_ width: CGFloat) -> CGFloat {
        let line = ceil(detail.font.ascender - detail.font.descender + detail.font.leading)
        return min(detail.height(for: textWidth(width)), line * 3)
    }

    private func textHeight(_ width: CGFloat) -> CGFloat {
        name.intrinsicContentSize.height + 2 + detailHeight(width)
    }

    func kitHeight(width: CGFloat) -> CGFloat {
        24 + max(32, textHeight(width), trailingSize.height)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: kitHeight(width: bounds.width > 0 ? bounds.width : 300))
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let mid = bounds.height / 2
        mark.frame = kitSnap(NSRect(x: 12, y: mid - 16, width: 32, height: 32))
        let room = textWidth(bounds.width)
        let block = textHeight(bounds.width)
        var y = mid - block / 2
        let nameSize = name.intrinsicContentSize
        name.frame = kitSnap(NSRect(x: 56, y: y, width: nameSize.width, height: nameSize.height))
        y += nameSize.height + 2
        detail.frame = kitSnap(NSRect(x: 56, y: y, width: room, height: detailHeight(bounds.width)))
        if let trailing {
            let size = trailingSize
            trailing.frame = kitSnap(NSRect(x: bounds.width - 12 - size.width, y: mid - size.height / 2, width: size.width, height: size.height))
        }
    }
}

@MainActor
enum PlansSurface {
    static func fixture(_ request: [String: Any]) -> (browser: Browser, plans: Plans) {
        let browser = Browsers.acting
        let plans = Plans()
        let said = request["states"] as? [String: String] ?? ["claude": "ready", "chatGPT": "out", "thisMac": "missing"]
        for plan in Plan.allCases {
            let fake = FakeProvider(plan: plan)
            fake.fakeStatus = status(said[plan.rawValue] ?? "missing", plan: plan)
            fake.fakeModels = models(plan)
            plans.standIn(fake, for: plan)
        }
        browser.prefs.aiPlan = (request["default"] as? String).flatMap(Plan.init(rawValue:)) ?? .claude
        plans.limits[.claude] = PlanLimit(window: "5-hour", used: 0.25, resets: nil)
        Task { await plans.refresh() }
        return (browser, plans)
    }

    static func size(_ request: [String: Any], _ width: Double, _ height: Double) -> CGSize {
        CGSize(width: request["width"] as? Double ?? width, height: request["height"] as? Double ?? height)
    }

    private static func status(_ word: String, plan: Plan) -> PlanStatus {
        switch word {
        case "ready": PlanStatus(path: "/fake/\(plan.executable)", connected: true,
                                 account: plan == .claude ? "Max plan" : plan == .chatGPT ? "ChatGPT plan" : nil)
        case "out": PlanStatus(path: "/fake/\(plan.executable)")
        default: PlanStatus()
        }
    }

    private static func models(_ plan: Plan) -> [PlanModel] {
        switch plan {
        case .claude:
            return [PlanModel(id: "opus", name: "Opus", efforts: [.low, .medium, .high, .max], defaultEffort: .high,
                              note: "Most capable for complex work"),
                    PlanModel(id: "sonnet", name: "Sonnet", efforts: [.low, .medium, .high], defaultEffort: .medium,
                              note: "Fast and capable for everyday work")]
        case .chatGPT:
            let efforts: [Effort] = [.low, .medium, .high, .xhigh]
            return [PlanModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", efforts: efforts, defaultEffort: .low,
                              note: "Latest workhorse model for coding and everyday work"),
                    PlanModel(id: "gpt-6-luna", name: "GPT-6-Luna", efforts: efforts, defaultEffort: .medium,
                              note: "Fast and affordable model for easier tasks")]
        case .thisMac: return [PlanModel(id: "", name: "This Mac")]
        }
    }
}

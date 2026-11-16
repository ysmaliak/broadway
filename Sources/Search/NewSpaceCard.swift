import AppKit
import Combine
import QuartzCore

final class NewSpaceCard: KitFlippedView {
    static let width = OnboardingCard.size.width
    static let title = "Name your new space"
    static let line = "A space keeps its own tabs, pins and look"
    static let arrives = KitSpring(response: 0.34, damping: 0.86)
    static let arrivesFrom: CGFloat = 18
    static let fades = 0.16
    static let leaves = 0.14

    let browser: Browser
    let draft: Onboarding
    private let base = KitBox(fill: Palette.NS.ground, corners: .radius(OnboardingCard.corner))
    private let clip = KitFlippedView()
    private let stage: OnboardingStageView
    private let panel: OnboardingPanel
    private let edge = KitBox(fill: nil, stroke: KitColor.hairline, corners: .radius(OnboardingCard.corner))
    private let icon: KitButton
    private let iconFace: NewSpaceIconFace
    private let accounts: NewSpaceAccountsView
    private let cancel: KitButton
    private let create: KitButton
    private let createFace = OnboardingLead("Create")
    private var watches: [AnyCancellable] = []
    private var made = false

    init(browser: Browser, draft: Onboarding) {
        self.browser = browser
        self.draft = draft
        stage = OnboardingStageView(onboarding: draft)
        panel = OnboardingPanel(step: .space, onboarding: draft, title: Self.title, line: Self.line)
        iconFace = NewSpaceIconFace(icon: browser.draftIcon)
        icon = KitButton(.plain(press: 0.94), label: "Choose an Icon")
        accounts = NewSpaceAccountsView(picked: browser.spaceAsk.accounts)
        cancel = KitButton(.plain(press: 1), label: "Cancel")
        create = KitButton(.plain(press: 0.97), label: "Create")
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        panel.wantsLayer = true
        addSubview(base)
        addSubview(clip)
        clip.addSubview(stage)
        clip.addSubview(panel)
        addSubview(edge)
        addSubview(icon)
        addSubview(accounts)
        addSubview(cancel)
        addSubview(create)
        WelcomeShadow.apply(base, opacity: 0.4, radius: 46, y: 22)

        icon.content = iconFace
        icon.toolTip = "Choose an Icon"
        icon.setAccessibilityIdentifier("newspace.icon")
        icon.onHover = { [weak self] on in self?.iconFace.lifted = on }
        icon.action = { [weak self] in self?.chooseIcon() }

        if let field = panel.field {
            field.field.placeholderString = "Name"
            field.setAccessibilityIdentifier("newspace.name")
            field.onSubmit = { [weak self] in self?.make() }
        }

        accounts.pick = { [weak browser] picked in browser?.spaceAsk.accounts = picked }

        let quiet = KitLabel("Cancel", font: .systemFont(ofSize: 13), color: KitColor.muted)
        quiet.setAccessibilityElement(false)
        cancel.content = quiet
        cancel.padding = 6
        cancel.height = 34
        cancel.setAccessibilityIdentifier("newspace.cancel")
        cancel.action = { [weak browser] in browser?.leaveSpaceCreation() }
        create.content = createFace
        create.setAccessibilityIdentifier("newspace.create")
        create.action = { [weak self] in self?.make() }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("New Space")

        watches = [
            kitObserve({ [weak draft] in draft?.name ?? "" }) { [weak self] name in self?.named(name) },
            kitObserve(initial: false, { [weak browser] in browser?.draftIcon }) { [weak self] icon in
                if let icon { self?.iconFace.show(icon) }
            },
            kitObserve(initial: false, { [weak browser] in browser?.spaceAsk.accounts }) { [weak self] picked in
                if let picked { self?.accounts.picked = picked }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var firstField: NSView? { panel.field?.field }

    override func mouseDown(with event: NSEvent) {}

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
        switch event.keyCode {
        case 36 where plain, 76 where plain: make()
        case 53: browser.leaveSpaceCreation()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { browser.leaveSpaceCreation() }

    func fit(width: CGFloat = NewSpaceCard.width) -> CGFloat {
        place(width: width)
    }

    override func layout() {
        super.layout()
        base.frame = bounds
        clip.frame = bounds
        edge.frame = bounds
        if let layer = clip.layer {
            layer.cornerRadius = OnboardingCard.corner
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        _ = place(width: bounds.width)
    }

    private func place(width: CGFloat) -> CGFloat {
        let inset = OnboardingCard.inset
        let top = OnboardingCard.stageHeight
        stage.frame = NSRect(x: 0, y: 0, width: width, height: top)
        stage.show(step: .space, index: 0, moving: false)
        stage.layoutSubtreeIfNeeded()
        panel.frame = NSRect(x: 0, y: top, width: width, height: 480)
        panel.layoutSubtreeIfNeeded()
        if let field = panel.field {
            let box = field.convert(field.bounds, to: self)
            icon.frame = kitSnap(NSRect(x: box.maxX + 10, y: box.minY, width: box.height, height: box.height))
        }
        let written = panel.subviews.filter { !$0.isHidden }.map(\.frame.maxY).max() ?? 0
        var y = top + written + 18
        let inner = width - inset * 2
        let tall = accounts.fit(width: inner)
        accounts.frame = kitSnap(NSRect(x: inset, y: y, width: inner, height: tall))
        y += tall + 24
        let leadSize = create.intrinsicContentSize
        create.frame = kitSnap(NSRect(x: width - inset - leadSize.width, y: y + (34 - leadSize.height) / 2, width: leadSize.width, height: leadSize.height))
        let quietSize = cancel.intrinsicContentSize
        cancel.frame = kitSnap(NSRect(x: create.frame.minX - 10 - quietSize.width, y: y + (34 - quietSize.height) / 2,
                                      width: quietSize.width, height: quietSize.height))
        return ceil(y + 34 + 28)
    }

    private func named(_ name: String) {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        browser.spaceDraftName.text = name
        create.isEnabled = !typed.isEmpty
    }

    func focus() {
        guard let window, !isHiddenOrHasHiddenAncestor else { return }
        window.makeFirstResponder(firstField)
    }

    private func chooseIcon() {
        browser.iconPicker.pick(draft: browser.draftIcon) { [weak self] chosen in
            guard let self else { return }
            browser.spaceDraftIcon = chosen
            iconFace.show(chosen)
            focus()
        }
    }

    private func make() {
        guard !made else { return }
        guard browser.spaceAsk.draft === draft, !browser.spaceAsk.name.isEmpty else { return focus() }
        made = browser.createAskedSpace()
    }
}

final class NewSpaceIconFace: KitFlippedView {
    static let side: CGFloat = 34

    var lifted = false { didSet { if lifted != oldValue { lift() } } }
    private let disc = KitBox(fill: Palette.NS.wash, corners: .radius(9))
    private let mark: SpaceMarkView

    init(icon: TabIcon) {
        mark = SpaceMarkView(icon: icon, size: 15)
        super.init(frame: .zero)
        wantsLayer = true
        mark.setAccessibilityElement(false)
        addSubview(disc)
        addSubview(mark)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var icon: TabIcon { mark.icon }

    func show(_ icon: TabIcon) {
        guard icon != mark.icon else { return }
        mark.swap(to: icon)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        disc.frame = bounds
        let size = mark.intrinsicContentSize
        mark.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }

    private func lift() {
        guard let layer else { return }
        let grow: CGFloat = lifted ? 1.06 : 1
        let middle = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        let grown = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                            CATransform3DMakeScale(grow, grow, 1)), middle)
        let curve: KitCurve = Motion.reduced ? .none : .spring(KitSpring(response: 0.25, damping: 0.7))
        layer.kitAnimate("transform", to: NSValue(caTransform3D: grown), curve: curve)
    }
}

final class NewSpaceAccountsView: KitFlippedView {
    static let gap: CGFloat = 10

    var picked: SpaceAccounts { didSet { if picked != oldValue { for tile in tiles { tile.picked = tile.kind == picked } } } }
    var pick: ((SpaceAccounts) -> Void)?
    private let tiles: [NewSpaceAccountsTile]

    init(picked: SpaceAccounts) {
        self.picked = picked
        tiles = SpaceAccounts.allCases.map { NewSpaceAccountsTile($0, picked: $0 == picked) }
        super.init(frame: .zero)
        for tile in tiles {
            tile.action = { [weak self, weak tile] in
                guard let self, let tile else { return }
                self.picked = tile.kind
                self.pick?(tile.kind)
            }
            addSubview(tile)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(SpaceAccounts.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityChildren() -> [Any]? { tiles }

    func fit(width: CGFloat) -> CGFloat {
        let each = (width - Self.gap * CGFloat(tiles.count - 1)) / CGFloat(max(tiles.count, 1))
        return tiles.map { $0.fit(width: each) }.max() ?? 0
    }

    override func layout() {
        super.layout()
        let each = (bounds.width - Self.gap * CGFloat(tiles.count - 1)) / CGFloat(max(tiles.count, 1))
        for (index, tile) in tiles.enumerated() {
            tile.frame = kitSnap(NSRect(x: CGFloat(index) * (each + Self.gap), y: 0, width: each, height: bounds.height))
        }
    }
}

final class NewSpaceAccountsTile: KitHoverView {
    static let pad: CGFloat = 13
    static let radius: CGFloat = 12

    let kind: SpaceAccounts
    var picked: Bool { didSet { if picked != oldValue { restyle(animated: true) } } }
    var action: (() -> Void)?
    private let plate = KitBox(fill: Palette.NS.wash, corners: .radius(NewSpaceAccountsTile.radius))
    private let ring = KitBox(fill: nil, stroke: KitColor.ink, corners: .radius(NewSpaceAccountsTile.radius))
    private let symbol: KitSymbol
    private let title: KitLabel
    private let caption: KitParagraph
    private let check = KitSymbol("checkmark.circle.fill", style: .init(size: 15, weight: .semibold))

    init(_ kind: SpaceAccounts, picked: Bool) {
        self.kind = kind
        self.picked = picked
        symbol = KitSymbol(kind.symbol, style: .init(size: 13, weight: .medium))
        title = KitLabel(kind.title, font: .systemFont(ofSize: 13, weight: .semibold))
        caption = KitParagraph(kind.caption, font: .systemFont(ofSize: 12), color: KitColor.muted)
        super.init(frame: .zero)
        wantsLayer = true
        ring.strokeWidth = 1.5
        caption.lineSpacing = 1
        for view in [plate, ring, symbol, title, caption, check] as [NSView] {
            view.setAccessibilityElement(false)
            addSubview(view)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(kind.title)
        setAccessibilityHelp(kind.caption)
        setAccessibilityIdentifier("newspace.accounts.\(kind.rawValue)")
        restyle(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action?() }
    }

    override func accessibilityPerformPress() -> Bool {
        action?()
        return true
    }

    override func hoverChanged() { restyle(animated: true) }

    func fit(width: CGFloat) -> CGFloat {
        let pad = Self.pad
        return ceil(pad + 18 + 5 + caption.height(for: width - pad * 2) + pad)
    }

    override func layout() {
        super.layout()
        let pad = Self.pad
        plate.frame = bounds
        ring.frame = bounds
        let glyph = symbol.intrinsicContentSize
        symbol.frame = kitSnap(NSRect(x: pad, y: pad + (18 - glyph.height) / 2, width: glyph.width, height: glyph.height))
        let mark = check.intrinsicContentSize
        check.frame = kitSnap(NSRect(x: bounds.width - pad - mark.width, y: pad + (18 - mark.height) / 2, width: mark.width, height: mark.height))
        let words = title.intrinsicContentSize
        let left = symbol.frame.maxX + 7
        title.frame = kitSnap(NSRect(x: left, y: pad + (18 - words.height) / 2, width: min(words.width, check.frame.minX - 8 - left), height: words.height))
        let wide = bounds.width - pad * 2
        caption.frame = kitSnap(NSRect(x: pad, y: pad + 18 + 5, width: wide, height: caption.height(for: wide)))
    }

    private func restyle(animated: Bool) {
        setAccessibilityValue(picked ? 1 : 0)
        let curve: KitCurve = animated && !Motion.reduced ? .spring(KitSpring(response: 0.3, damping: 0.72)) : .none
        ring.layer?.kitAnimate("opacity", to: picked ? 1 : 0, curve: curve)
        check.layer?.kitAnimate("opacity", to: picked ? 1 : 0, curve: curve)
        let shown: Double = picked ? 1 : hovering ? 0.86 : 0.66
        if animated, !Motion.reduced { layer?.kitTransition(.easeOut(0.16)) }
        symbol.opacity = shown
        title.opacity = shown
        plate.fill = picked || hovering ? Palette.NS.wash : Palette.NS.wash.withAlphaComponent(0.6)
    }
}

final class NewSpaceLayerView: KitFlippedView {
    let browser: Browser
    let draft: Onboarding
    let card: NewSpaceCard
    private let scrim = KitBox(fill: nil)
    private var arrived = false
    private var leaving = false
    private weak var before: NSResponder?
    private var keyboard: NSKeyValueObservation?
    private var tabWatch: AnyCancellable?

    init(browser: Browser, draft: Onboarding) {
        self.browser = browser
        self.draft = draft
        card = NewSpaceCard(browser: browser, draft: draft)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(scrim)
        addSubview(card)
        setAccessibilityElement(false)
        let front = browser.activeID
        tabWatch = kitObserve(initial: false, { [weak browser] in browser?.activeID }) { [weak self] now in
            guard let self, now != front, self.browser.spaceAsk.draft === self.draft else { return }
            self.browser.leaveSpaceCreation()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let grip: CGFloat = 44

    static func scale(card: NSSize, in room: NSSize) -> CGFloat {
        guard card.width > 0, card.height > 0 else { return 1 }
        return max(0.5, min(1, (room.width - 32) / card.width, (room.height - 32) / card.height))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !leaving, frame.contains(point) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).y < Self.grip { window?.performDrag(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
        keyboard = window?.observe(\.firstResponder) { [weak self] _, _ in
            DispatchQueue.main.async { self?.keyboardMoved() }
        }
    }

    private func keyboardMoved() {
        guard arrived, !leaving, let window, browser.spaceAsk.draft === draft, browser.iconPicker.target == nil else { return }
        guard let holder = window.firstResponder as? NSView else { return card.focus() }
        if !holder.isDescendant(of: self) { browser.leaveSpaceCreation() }
    }

    override func layout() {
        super.layout()
        scrim.fill = NSColor.black.withAlphaComponent(kitDark ? 0.42 : 0.24)
        scrim.frame = bounds
        let natural = NSSize(width: NewSpaceCard.width, height: card.fit())
        let scale = Self.scale(card: natural, in: bounds.size)
        let shown = NSSize(width: natural.width * scale, height: natural.height * scale)
        card.frame = kitSnap(NSRect(x: (bounds.width - shown.width) / 2, y: max(16, (bounds.height - shown.height) / 2),
                                    width: shown.width, height: shown.height))
        card.setBoundsSize(natural)
        if !arrived, window != nil, bounds.width > 0 { arrive() }
    }

    private func arrive() {
        arrived = true
        before = window?.firstResponder
        card.layoutSubtreeIfNeeded()
        card.focus()
        NSAccessibility.post(element: card, notification: .layoutChanged)
        guard let veil = scrim.layer, let face = card.layer else { return }
        let reduced = Motion.reduced
        for (layer, takes) in [(veil, 0.2), (face, reduced ? 0.2 : NewSpaceCard.fades)] {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = takes
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "arrive.fade")
        }
        guard !reduced else { return }
        let rise = NewSpaceCard.arrives.animation("transform.translation.y", from: NewSpaceCard.arrivesFrom, to: 0)
        rise.isAdditive = true
        face.add(rise, forKey: "arrive.rise")
    }

    func leave(created: Bool, then done: @escaping () -> Void) {
        guard !leaving else { return }
        leaving = true
        if let window, let editor = window.firstResponder as? NSView, editor.isDescendant(of: self) {
            let back = (before as? NSView).flatMap { $0.window === window ? $0 : nil }
            window.makeFirstResponder(back)
        }
        guard let veil = scrim.layer, let face = card.layer else { return done() }
        let reduced = Motion.reduced
        let takes = reduced ? 0.2 : NewSpaceCard.leaves
        var moves: [(CALayer, CABasicAnimation)] = []
        for layer in [veil, face] {
            let out = CABasicAnimation(keyPath: "opacity")
            out.fromValue = 1
            out.toValue = 0
            moves.append((layer, out))
        }
        if !reduced {
            let drift = CABasicAnimation(keyPath: "transform.translation.y")
            drift.fromValue = 0
            drift.toValue = created ? -10 : 8
            drift.isAdditive = true
            moves.append((face, drift))
        }
        for (layer, move) in moves {
            move.duration = takes
            move.timingFunction = CAMediaTimingFunction(name: .easeIn)
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
            layer.add(move, forKey: "leave.\(move.keyPath ?? "")")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + takes + 0.02) { done() }
    }
}

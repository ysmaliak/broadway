import AppKit
import Combine
import QuartzCore

extension ImportSource {
    var appName: String {
        switch self {
        case .chromium(let source): return source.app
        case .mozilla(let source): return source.name + ".app"
        }
    }

    static func icon(named name: String) -> NSImage? {
        if name == safariName { return safari ? NSWorkspace.shared.icon(forFile: URL(fileURLWithPath: safariApp).resolvingSymlinksInPath().path) : nil }
        guard let source = installed().first(where: { $0.name == name }) else { return nil }
        for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let path = folder + "/" + source.appName
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }
}

final class OnboardingWindowArt: KitFlippedView {
    private let picture: OnboardingSidePicture
    private let disc = KitBox(fill: .white, corners: .capsule)
    private let symbol: KitSymbol
    private let pointer: KitSymbol?
    private let press: KitBox?

    init(symbol name: String, right: Bool, look: SpaceLook = SpaceLook(), pointing: Bool = false) {
        let ink = NSColor(srgbRed: 0x11 / 255, green: 0x12 / 255, blue: 0x16 / 255, alpha: 1)
        picture = OnboardingSidePicture(right: right, look: look)
        symbol = KitSymbol(name, style: .init(size: 15, weight: .bold), tint: ink)
        pointer = pointing ? KitSymbol("cursorarrow", style: .init(size: 19, weight: .medium, fill: true), tint: ink) : nil
        press = pointing ? KitBox(fill: NSColor(white: 0, alpha: 0.07), stroke: NSColor(white: 0, alpha: 0.16), corners: .capsule) : nil
        super.init(frame: .zero)
        addSubview(picture)
        if let press { addSubview(press) }
        if let pointer { addSubview(pointer) }
        addSubview(disc)
        addSubview(symbol)
        WelcomeShadow.apply(picture.layer, opacity: 0.4, radius: 16, y: 8)
        WelcomeShadow.apply(disc.layer, opacity: 0.4, radius: 8, y: 3)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 122) }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: 16, y: 14, width: 168, height: 108)
        disc.frame = NSRect(x: 166, y: 0, width: 34, height: 34)
        let size = symbol.intrinsicContentSize
        symbol.frame = kitSnap(NSRect(x: disc.frame.midX - size.width / 2, y: disc.frame.midY - size.height / 2, width: size.width, height: size.height))
        let page = picture.pageFrame.offsetBy(dx: picture.frame.minX, dy: picture.frame.minY)
        let spot = CGPoint(x: page.midX - 6, y: page.midY - 4)
        press?.frame = NSRect(x: spot.x - 13, y: spot.y - 13, width: 26, height: 26)
        if let pointer {
            let size = pointer.intrinsicContentSize
            pointer.frame = kitSnap(NSRect(x: spot.x - 3, y: spot.y - 2, width: size.width, height: size.height))
        }
    }
}

final class OnboardingLinkArt: KitFlippedView {
    private let picture: OnboardingSidePicture
    private let chip = KitBox(fill: NSColor(white: 0.93, alpha: 1), corners: .capsule)
    private let link = KitSymbol("link", style: .init(size: 13, weight: .bold), tint: NSColor(white: 0, alpha: 0.72))
    private let bar = KitBox(fill: NSColor(white: 0, alpha: 0.22), corners: .capsule)
    private let arrow = KitSymbol("arrow.right", style: .init(size: 15, weight: .bold), tint: NSColor(white: 1, alpha: 0.7))

    init(right: Bool, look: SpaceLook = SpaceLook()) {
        picture = OnboardingSidePicture(right: right, look: look)
        super.init(frame: .zero)
        for view in [picture, chip, link, bar, arrow] as [NSView] { addSubview(view) }
        WelcomeShadow.apply(picture.layer, opacity: 0.4, radius: 16, y: 8)
        WelcomeShadow.apply(chip.layer, opacity: 0.35, radius: 10, y: 5)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 334, height: 108) }

    override func layout() {
        super.layout()
        chip.frame = NSRect(x: 0, y: 34, width: 108, height: 40)
        let linkSize = link.intrinsicContentSize
        link.frame = kitSnap(NSRect(x: 16, y: chip.frame.midY - linkSize.height / 2, width: linkSize.width, height: linkSize.height))
        bar.frame = NSRect(x: link.frame.maxX + 9, y: chip.frame.midY - 3.5, width: chip.frame.maxX - 18 - link.frame.maxX - 9, height: 7)
        let arrowSize = arrow.intrinsicContentSize
        arrow.frame = kitSnap(NSRect(x: 108 + (58 - arrowSize.width) / 2, y: chip.frame.midY - arrowSize.height / 2, width: arrowSize.width, height: arrowSize.height))
        picture.frame = NSRect(x: 166, y: 0, width: 168, height: 108)
    }
}

final class OnboardingChoice: KitHoverView {
    var picked: Bool { didSet { if picked != oldValue { restyle(animated: true) } } }
    let action: () -> Void
    private let body = KitFlippedView()
    private let ring = CALayer()
    private let content: NSView
    private let caption: KitLabel?
    private let box: CGSize
    private let radius: CGFloat

    init(content: NSView, box: CGSize, radius: CGFloat, caption: String?, label: String, picked: Bool, action: @escaping () -> Void) {
        self.content = content
        self.box = box
        self.radius = radius
        self.picked = picked
        self.action = action
        self.caption = caption.map { KitLabel($0, font: .systemFont(ofSize: 12, weight: .medium), color: NSColor(white: 1, alpha: 0.82)) }
        super.init(frame: .zero)
        wantsLayer = true
        body.wantsLayer = true
        addSubview(body)
        body.addSubview(content)
        body.layer?.addSublayer(ring)
        ring.borderColor = CGColor(gray: 1, alpha: 1)
        ring.borderWidth = 2
        ring.cornerCurve = .continuous
        if let caption = self.caption {
            caption.alignment = .center
            caption.setAccessibilityElement(false)
            addSubview(caption)
        }
        kitAccess(label: label, role: .radioButton)
        restyle(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: box.width + 12, height: box.height + 12 + (caption == nil ? 0 : 22)) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    override func accessibilityPerformPress() -> Bool {
        action()
        return true
    }

    override func hoverChanged() { restyle(animated: true) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.frame = NSRect(x: 0, y: 0, width: box.width + 12, height: box.height + 12)
        content.frame = NSRect(x: 6, y: 6, width: box.width, height: box.height)
        ring.frame = body.bounds
        ring.cornerRadius = radius + 6
        CATransaction.commit()
        if let caption {
            let size = caption.intrinsicContentSize
            caption.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: box.height + 16, width: size.width, height: size.height))
        }
    }

    private func restyle(animated: Bool) {
        setAccessibilityValue(picked ? 1 : 0)
        let curve: KitCurve = animated && !Motion.reduced ? .spring(KitSpring(response: 0.3, damping: 0.72)) : .none
        ring.kitAnimate("opacity", to: picked ? 1 : 0, curve: curve)
        guard let layer = body.layer else { return }
        let grow: CGFloat = hovering && !picked ? 1.035 : 1
        let middle = CATransform3DMakeTranslation(body.bounds.midX, body.bounds.midY, 0)
        let grown = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-body.bounds.midX, -body.bounds.midY, 0),
                                                            CATransform3DMakeScale(grow, grow, 1)), middle)
        layer.kitAnimate("transform", to: NSValue(caTransform3D: grown), curve: curve)
    }
}

final class OnboardingSourceMark: KitFlippedView {
    private let picture: NSImageView?
    private let plate: KitBox?
    private let symbol: KitSymbol?

    init(icon: NSImage?) {
        if let icon {
            let view = NSImageView()
            view.image = icon
            view.imageScaling = .scaleProportionallyUpOrDown
            picture = view
            plate = nil
            symbol = nil
        } else {
            picture = nil
            plate = KitBox(fill: NSColor(white: 1, alpha: 0.1), stroke: NSColor(white: 1, alpha: 0.14), corners: .radius(12))
            symbol = KitSymbol("globe", style: .init(size: 24, weight: .medium), tint: NSColor(white: 1, alpha: 0.82))
        }
        super.init(frame: .zero)
        for view in [picture, plate, symbol] as [NSView?] {
            guard let view else { continue }
            addSubview(view)
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var plain: Bool { picture == nil }

    override func layout() {
        super.layout()
        picture?.frame = bounds
        plate?.frame = bounds.insetBy(dx: 6, dy: 6)
        if let symbol {
            let size = symbol.intrinsicContentSize
            symbol.frame = kitSnap(NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
    }
}

final class OnboardingSidePicture: KitFlippedView {
    let right: Bool
    let look: SpaceLook
    private let body = KitFlippedView()
    private let ground: SpaceGroundView
    private let edge = CALayer()
    private let page = KitBox(fill: .white, corners: .radius(6))
    private let rows: [KitBox] = (0..<4).map { _ in KitBox(fill: nil, corners: .capsule) }

    static let corner: CGFloat = 11

    init(right: Bool, look: SpaceLook = SpaceLook()) {
        self.right = right
        self.look = look
        ground = SpaceGroundView(look: look)
        super.init(frame: .zero)
        wantsLayer = true
        body.wantsLayer = true
        ground.spansWindow = false
        ground.staged = true
        ground.glassCorner = Self.corner
        addSubview(body)
        if look.showsThrough {
            let backdrop = SpaceLookBackdrop(focus: CGPoint(x: 0.08, y: 0.95), bright: look.glass)
            backdrop.autoresizingMask = [.width, .height]
            body.addSubview(backdrop)
        }
        body.addSubview(ground)
        body.addSubview(page)
        for row in rows { body.addSubview(row) }
        layer?.addSublayer(edge)
        edge.borderWidth = 1
        edge.zPosition = 1
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static let column: CGFloat = 46

    var pageFrame: NSRect {
        NSRect(x: right ? 6 : Self.column, y: 6, width: bounds.width - Self.column - 6, height: bounds.height - 12)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let column = Self.column
        let lightInk = look.inkLight(dark: kitDark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.frame = bounds
        body.layer?.cornerRadius = Self.corner
        body.layer?.cornerCurve = .continuous
        body.layer?.masksToBounds = true
        edge.frame = bounds
        edge.cornerRadius = Self.corner
        edge.cornerCurve = .continuous
        edge.borderColor = NSColor(white: lightInk ? 1 : 0, alpha: lightInk ? 0.16 : 0.08).cgColor
        CATransaction.commit()
        ground.frame = body.bounds
        page.frame = pageFrame
        let left = right ? bounds.width - column + 8 : 8
        for (index, row) in rows.enumerated() {
            let width: CGFloat = index == 1 ? 30 : 26 - CGFloat(index * 3)
            row.fill = NSColor(white: lightInk ? 1 : 0, alpha: lightInk ? (index == 1 ? 0.6 : 0.24) : (index == 1 ? 0.5 : 0.18))
            row.frame = NSRect(x: left, y: 14 + CGFloat(index) * 13, width: width, height: 7)
        }
    }
}

final class OnboardingStageView: KitFlippedView {
    private let onboarding: Onboarding
    private let plate = CAGradientLayer()
    private let streets = CAShapeLayer()
    private let route = CAShapeLayer()
    private let art = KitFlippedView()
    private var artView: NSView?
    private var step: Onboarding.Step?
    private var choices: [(id: String, view: OnboardingChoice)] = []
    private var panned: Int?

    init(onboarding: Onboarding) {
        self.onboarding = onboarding
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(plate)
        layer?.addSublayer(streets)
        layer?.addSublayer(route)
        plate.colors = [OnboardingSceneView.colour(BroadwayMap.inkTop), OnboardingSceneView.colour(BroadwayMap.inkBottom)]
        plate.startPoint = CGPoint(x: 0.5, y: 0)
        plate.endPoint = CGPoint(x: 0.5, y: 1)
        for (shape, path, width, colour) in [
            (streets, BroadwayMap.grid(), BroadwayMap.gridWidth, OnboardingSceneView.colour(BroadwayMap.inkGrid, 0.07)),
            (route, BroadwayMap.route(), BroadwayMap.lineWidth, OnboardingSceneView.colour(BroadwayMap.inkLine, 0.045)),
        ] {
            shape.path = path
            shape.fillColor = nil
            shape.strokeColor = colour
            shape.lineWidth = width
            shape.lineCap = .round
            shape.anchorPoint = .zero
            shape.bounds = CGRect(x: 0, y: 0, width: BroadwayMap.canvas, height: BroadwayMap.canvas)
        }
        addSubview(art)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let scale: CGFloat = 0.22

    static func stop(_ index: Int) -> CGPoint {
        let street = 7 + CGFloat(index) * 3.5
        let church = BroadwayMap.graceChurch
        let avenue = street <= church.street
            ? 3.84 + (street - 4) / (church.street - 4) * (church.avenue - 3.84)
            : church.avenue + (street - church.street) / 14 * (5 - church.avenue)
        return BroadwayMap.spot(avenue: avenue, street: street)
    }

    private func pan(to index: Int, moving: Bool) {
        let at = Self.stop(index)
        let scale = Self.scale
        let move = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: bounds.width * 0.2 - at.x * scale, ty: bounds.height * 0.5 + at.y * scale)
        let wanted = NSValue(caTransform3D: CATransform3DMakeAffineTransform(move))
        let curve: KitCurve = moving && !Motion.reduced ? .spring(KitSpring(response: 0.7, damping: 0.9)) : .none
        for shape in [streets, route] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.position = .zero
            CATransaction.commit()
            shape.kitAnimate("transform", to: wanted, curve: curve)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        for choice in choices {
            guard let holder = choice.view.superview else { continue }
            if choice.view.frame.contains(holder.convert(inside, from: self)) { return choice.view }
        }
        for tile in (artView as? SpaceLookChooser)?.picker.tiles ?? [] {
            guard let holder = tile.superview else { continue }
            if tile.frame.contains(holder.convert(inside, from: self)) { return tile }
        }
        return nil
    }

    func show(step: Onboarding.Step, index: Int, moving: Bool) {
        if step != self.step {
            self.step = step
            let old = artView
            choices = []
            let made = makeArt(step)
            made.wantsLayer = true
            artView = made
            art.addSubview(made)
            turn(from: old, to: made, moving: moving)
        }
        if panned != index, bounds.width > 0 {
            pan(to: index, moving: moving && panned != nil)
            panned = index
        }
        needsLayout = true
    }

    private func turn(from old: NSView?, to made: NSView, moving: Bool) {
        guard let old else { return }
        guard moving, let leaving = old.layer, let coming = made.layer else {
            old.removeFromSuperview()
            return
        }
        guard !Motion.reduced else {
            art.wantsLayer = true
            art.layer?.kitTransition(.easeOut(0.2))
            old.removeFromSuperview()
            return
        }
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        out.duration = Self.artLeaves
        out.timingFunction = CAMediaTimingFunction(name: .easeIn)
        out.fillMode = .forwards
        out.isRemovedOnCompletion = false
        leaving.add(out, forKey: "leave")
        let now = coming.convertTime(CACurrentMediaTime(), from: nil)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = now + Self.artLeaves
        fade.duration = 0.24
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        coming.add(fade, forKey: "arrive.fade")
        let rise = OnboardingCard.turn.animation("transform.translation.y", from: 10, to: 0)
        rise.isAdditive = true
        rise.beginTime = now + Self.artLeaves
        rise.fillMode = .backwards
        coming.add(rise, forKey: "arrive.rise")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.artLeaves + 0.02) { old.removeFromSuperview() }
    }

    static let artLeaves = OnboardingCard.leaves

    private var spaceLook: SpaceLook { onboarding.browser?.space.look ?? SpaceLook() }

    private func makeArt(_ step: Onboarding.Step) -> NSView {
        switch step {
        case .space:
            return SpaceLookChooser(picked: onboarding.look, custom: spaceLook, ring: .white) { [weak self] id in
                self?.onboarding.look = id
            }
        case .side:
            let row = KitFlippedView()
            for position in SidebarPosition.allCases {
                let picture = OnboardingSidePicture(right: position == .right, look: spaceLook)
                let choice = OnboardingChoice(content: picture, box: CGSize(width: 168, height: 108), radius: 11, caption: position.title,
                                              label: "Sidebar on the \(position.title.lowercased())", picked: onboarding.side == position) { [weak self] in
                    self?.onboarding.side = position
                }
                choice.setAccessibilityIdentifier("onboarding.side.\(position.rawValue)")
                row.addSubview(choice)
                choices.append((position.rawValue, choice))
            }
            return row
        case .links:
            return OnboardingLinkArt(right: onboarding.side == .right, look: spaceLook)
        case .agents:
            return OnboardingWindowArt(symbol: "sparkles", right: onboarding.side == .right, look: spaceLook, pointing: true)
        case .key:
            return OnboardingWindowArt(symbol: "key.fill", right: onboarding.side == .right, look: spaceLook)
        case .bring:
            let names = Array(onboarding.sources().prefix(4))
            guard !names.isEmpty else { return OnboardingWindowArt(symbol: "arrow.down", right: onboarding.side == .right, look: spaceLook) }
            let row = KitFlippedView()
            for name in names {
                let picture = OnboardingSourceMark(icon: ImportSource.icon(named: name))
                let choice = OnboardingChoice(content: picture, box: CGSize(width: 64, height: 64), radius: 14, caption: name,
                                              label: name, picked: onboarding.source == name) { [weak self] in
                    self?.onboarding.source = name
                }
                choice.setAccessibilityIdentifier("onboarding.source.\(name)")
                row.addSubview(choice)
                choices.append((name, choice))
            }
            return row
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plate.frame = bounds
        CATransaction.commit()
        art.frame = bounds
        if panned == nil, let step, bounds.width > 0 {
            let index = onboarding.steps.firstIndex(of: step) ?? 0
            pan(to: index, moving: false)
            panned = index
        }
        let picked = step == .side ? onboarding.side.rawValue : onboarding.source
        for choice in choices { choice.view.picked = choice.id == picked }
        (artView as? SpaceLookChooser)?.show(picked: onboarding.look, custom: spaceLook)
        guard let artView else { return }
        var size = artView.intrinsicContentSize
        if !choices.isEmpty {
            let gap: CGFloat = step == .side ? 22 : 14
            let sizes = choices.map { $0.view.intrinsicContentSize }
            size = NSSize(width: sizes.map(\.width).reduce(0, +) + gap * CGFloat(sizes.count - 1), height: sizes.map(\.height).max() ?? 0)
            var x: CGFloat = 0
            for (choice, each) in zip(choices, sizes) {
                choice.view.frame = NSRect(x: x, y: 0, width: each.width, height: each.height)
                x += each.width + gap
            }
        }
        artView.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
}

final class OnboardingLead: KitBox {
    let label: KitLabel

    init(_ title: String) {
        label = KitLabel(title, font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ground)
        super.init(frame: .zero)
        fill = KitColor.ink
        corners = .capsule
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { label.text }
        set {
            guard newValue != label.text else { return }
            label.runs = [KitLabel.Run(text: newValue, font: .systemFont(ofSize: 13, weight: .semibold))]
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 36, height: 34)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
}

final class OnboardingDots: KitFlippedView {
    var index: Int { didSet { if index != oldValue { restyle() } } }
    var moves = false
    let go: (Int) -> Void
    private let dots: [KitBox]
    var count: Int { dots.count }

    init(count: Int, index: Int, go: @escaping (Int) -> Void) {
        self.index = index
        self.go = go
        dots = (0..<count).map { _ in KitBox(fill: nil, corners: .capsule) }
        super.init(frame: .zero)
        for dot in dots { addSubview(dot) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let others = CGFloat(max(dots.count - 1, 0))
        return NSSize(width: others * 6 + 18 + others * 6, height: 6)
    }

    override func accessibilityChildren() -> [Any]? { [] }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.insetBy(dx: -4, dy: -6).contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let picked = dots.indices.min(by: { abs(dots[$0].frame.midX - x) < abs(dots[$1].frame.midX - x) }) else { return }
        go(picked)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (at, dot) in dots.enumerated() {
            let width: CGFloat = at == index ? 18 : 6
            dot.kitMove(to: NSRect(x: x, y: 0, width: width, height: 6), animated: moves && !Motion.reduced, curve: .spring(OnboardingCard.turn))
            x += width + 6
        }
    }

    private func restyle() {
        for (at, dot) in dots.enumerated() {
            if moves { dot.layer?.kitTransition(.easeOut(0.2)) }
            dot.fill = at == index ? KitColor.ink : KitColor.faint
        }
        setAccessibilityLabel("Step \(index + 1) of \(dots.count)")
        needsLayout = true
    }
}

final class OnboardingPanel: KitFlippedView {
    let step: Onboarding.Step
    private let onboarding: Onboarding
    private let title: KitParagraph
    private let line: KitParagraph
    private(set) var field: KitField?
    private var link: KitButton?
    private var note: KitParagraph?
    private var watch: AnyCancellable?

    init(step: Onboarding.Step, onboarding: Onboarding, title words: String? = nil, line said: String? = nil) {
        self.step = step
        self.onboarding = onboarding
        title = KitParagraph(words ?? Onboarding.title(step), font: .systemFont(ofSize: 25, weight: .bold), color: KitColor.ink, maxWidth: 488)
        line = KitParagraph(said ?? (step == .key ? onboarding.keyLine() : Onboarding.line(step)), font: .systemFont(ofSize: 15),
                            color: KitColor.muted, maxWidth: 488)
        line.lineSpacing = 2
        super.init(frame: .zero)
        addSubview(title)
        addSubview(line)
        if step == .key {
            makeKeyField()
            return
        }
        guard step == .space else { return }
        let name = KitField(placeholder: "Personal", text: onboarding.name, label: "Space name")
        name.field.font = .systemFont(ofSize: 14)
        name.onChange = { [weak onboarding] typed in onboarding?.name = typed }
        name.onSubmit = { [weak onboarding] in onboarding?.primary() }
        name.setAccessibilityIdentifier("onboarding.name")
        field = name
        addSubview(name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    private func makeKeyField() {
        let typed = KitField(placeholder: AIGroupWords.keyPrompt, text: onboarding.keyTyped, secure: true, label: AIGroupWords.keyTitle)
        typed.field.font = .systemFont(ofSize: 14)
        typed.onChange = { [weak onboarding] said in onboarding?.keyTyped = said }
        typed.onSubmit = { [weak onboarding] in onboarding?.primary() }
        typed.setAccessibilityIdentifier("onboarding.key")
        field = typed
        addSubview(typed)
        let words = KitLabel(AIGroupWords.getKey, font: .systemFont(ofSize: 13), color: KitColor.muted)
        words.setAccessibilityElement(false)
        let made = KitButton(.plain(press: 1), label: AIGroupWords.getKey) { [weak onboarding] in onboarding?.openKeysPage() }
        made.content = words
        made.padding = 6
        made.height = 34
        made.setAccessibilityIdentifier("onboarding.keysPage")
        made.setAccessibilityHelp("Opens OpenRouter's page for keys")
        link = made
        addSubview(made)
        let said = KitParagraph("", font: .systemFont(ofSize: 13), color: KitColor.muted, maxWidth: 220)
        said.setAccessibilityIdentifier("onboarding.keyNote")
        note = said
        addSubview(said)
        watch = kitObserve(initial: false, { [weak onboarding] in
            [onboarding?.keyNote ?? "", onboarding?.keyTyped.isEmpty == true ? "" : "typed", onboarding?.keys.present == true ? "saved" : ""]
        }) { [weak self] _ in
            self?.needsLayout = true
            self?.superview?.superview?.needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let left = OnboardingCard.inset, width = bounds.width - left * 2
        var y: CGFloat = 28
        for text in [title, line] {
            let wide = min(text.naturalWidth, width)
            let high = text.height(for: wide)
            text.frame = kitSnap(NSRect(x: left, y: y, width: wide, height: high))
            y += high + 9
        }
        y += step == .key ? 3 : 11
        guard let field else { return }
        guard step == .key else {
            if field.text != onboarding.name { field.text = onboarding.name }
            field.frame = NSRect(x: left, y: y, width: 240, height: 34)
            return
        }
        if field.text != onboarding.keyTyped { field.text = onboarding.keyTyped }
        field.frame = NSRect(x: left, y: y, width: 240, height: 34)
        let after = field.frame.maxX + 8
        let said = onboarding.keyNote ?? (onboarding.keys.present && onboarding.keyTyped.isEmpty ? AIGroupWords.saved : nil)
        if let note {
            note.text = said ?? ""
            note.isHidden = said == nil
            let wide = min(note.naturalWidth, bounds.width - left - after - 6)
            let high = note.height(for: wide)
            note.frame = kitSnap(NSRect(x: after + 6, y: y + (34 - high) / 2, width: wide, height: high))
        }
        if let link {
            link.isHidden = said != nil
            let size = link.intrinsicContentSize
            link.frame = kitSnap(NSRect(x: after, y: y + (34 - size.height) / 2, width: size.width, height: size.height))
        }
    }
}

final class OnboardingCard: KitFlippedView {
    static let size = CGSize(width: 560, height: 470)
    static let stageHeight: CGFloat = 220
    static let inset: CGFloat = 36
    static let corner: CGFloat = 28
    static let turn = KitSpring(response: 0.42, damping: 0.86)
    static let leaves = 0.12

    let onboarding: Onboarding
    private let base = KitBox(fill: Palette.NS.ground, corners: .radius(OnboardingCard.corner))
    private let clip = KitFlippedView()
    private let stage: OnboardingStageView
    private let edge = KitBox(fill: nil, stroke: KitColor.hairline, corners: .radius(OnboardingCard.corner))
    private var dots: OnboardingDots
    private let later: KitButton
    private let lead: KitButton
    private let leadFace: OnboardingLead
    private(set) var panel: OnboardingPanel?
    private var shownStep: Onboarding.Step?

    init(onboarding: Onboarding) {
        self.onboarding = onboarding
        stage = OnboardingStageView(onboarding: onboarding)
        dots = Self.makeDots(onboarding)
        let title = onboarding.lead(onboarding.step)
        leadFace = OnboardingLead(title)
        lead = KitButton(.plain(press: 0.97), label: title) { [weak onboarding] in onboarding?.primary() }
        lead.content = leadFace
        lead.setAccessibilityIdentifier("onboarding.primary")
        later = KitButton(.plain(press: 1), label: "Not Now") { [weak onboarding] in onboarding?.later() }
        let quiet = KitLabel("Not Now", font: .systemFont(ofSize: 13), color: KitColor.muted)
        quiet.setAccessibilityElement(false)
        later.content = quiet
        later.padding = 6
        later.height = 34
        later.setAccessibilityIdentifier("onboarding.later")
        later.setAccessibilityHelp("Skips this step. Everything here is also in Settings.")
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        addSubview(base)
        addSubview(clip)
        clip.addSubview(stage)
        addSubview(edge)
        addSubview(dots)
        addSubview(later)
        addSubview(lead)
        WelcomeShadow.apply(base, opacity: 0.4, radius: 46, y: 22)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func makeDots(_ onboarding: Onboarding) -> OnboardingDots {
        OnboardingDots(count: onboarding.steps.count, index: onboarding.index) { [weak onboarding] at in
            guard let onboarding, onboarding.steps.indices.contains(at) else { return }
            onboarding.go(onboarding.steps[at])
        }
    }

    var firstField: NSView? { panel?.field?.field }

    override func mouseDown(with event: NSEvent) {}

    override func layout() {
        super.layout()
        base.frame = bounds
        clip.frame = bounds
        edge.frame = bounds
        if let layer = clip.layer {
            layer.cornerRadius = Self.corner
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        let step = onboarding.step
        let index = onboarding.index
        let live = shownStep != nil && !isHiddenOrHasHiddenAncestor
        let moving = live && step != shownStep
        stage.frame = NSRect(x: 0, y: 0, width: bounds.width, height: Self.stageHeight)
        stage.show(step: step, index: index, moving: moving)
        if step != shownStep {
            let forward = index >= (shownStep.flatMap { onboarding.steps.firstIndex(of: $0) } ?? 0)
            swap(to: step, sliding: moving, forward: forward)
            shownStep = step
            setAccessibilityLabel(Onboarding.title(step))
        }
        panel?.frame = NSRect(x: 0, y: Self.stageHeight, width: bounds.width, height: bounds.height - Self.stageHeight)
        foot(index: index, title: onboarding.lead(step), moving: live)
    }

    private func foot(index: Int, title: String, moving: Bool) {
        if dots.count != onboarding.steps.count {
            dots.removeFromSuperview()
            dots = Self.makeDots(onboarding)
            addSubview(dots)
        }
        dots.moves = moving
        dots.index = index
        let changed = leadFace.title != title
        if changed {
            if moving { lead.layer?.kitTransition(.easeOut(0.2)) }
            leadFace.title = title
            lead.setAccessibilityLabel(title)
            lead.invalidateIntrinsicContentSize()
        }
        let top = bounds.height - 28 - 34
        let dotSize = dots.intrinsicContentSize
        dots.frame = NSRect(x: Self.inset, y: top + 14, width: dotSize.width, height: dotSize.height)
        let leadSize = lead.intrinsicContentSize
        lead.frame = kitSnap(NSRect(x: bounds.width - Self.inset - leadSize.width, y: top + (34 - leadSize.height) / 2, width: leadSize.width, height: leadSize.height))
        let laterSize = later.intrinsicContentSize
        let quiet = NSRect(x: lead.frame.minX - 10 - laterSize.width, y: top + (34 - laterSize.height) / 2, width: laterSize.width, height: laterSize.height)
        later.kitMove(to: quiet, animated: moving && changed && !Motion.reduced && !later.frame.isEmpty, curve: .easeOut(0.16))
    }

    private func swap(to step: Onboarding.Step, sliding: Bool, forward: Bool) {
        let old = panel
        let made = OnboardingPanel(step: step, onboarding: onboarding)
        made.wantsLayer = true
        made.frame = NSRect(x: 0, y: Self.stageHeight, width: bounds.width, height: bounds.height - Self.stageHeight)
        clip.addSubview(made)
        panel = made
        if sliding {
            window?.makeFirstResponder(made.field?.field)
            NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        guard let old else { return }
        guard sliding, !Motion.reduced, let leaving = old.layer, let coming = made.layer else {
            if sliding { clip.layer?.kitTransition(.easeOut(0.2)) }
            old.removeFromSuperview()
            return
        }
        made.layoutSubtreeIfNeeded()
        let way: CGFloat = forward ? 1 : -1
        let now = coming.convertTime(CACurrentMediaTime(), from: nil)
        let slide = Self.turn.animation("transform.translation.x", from: 22 * way, to: 0)
        slide.isAdditive = true
        slide.beginTime = now + Self.leaves * 0.7
        slide.fillMode = .backwards
        coming.add(slide, forKey: "slide")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = now + Self.leaves * 0.7
        fade.duration = 0.24
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        coming.add(fade, forKey: "fade")
        let away = CABasicAnimation(keyPath: "transform.translation.x")
        away.fromValue = 0
        away.toValue = -14 * way
        away.isAdditive = true
        let out = CABasicAnimation(keyPath: "opacity")
        out.fromValue = 1
        out.toValue = 0
        for animation in [away, out] {
            animation.duration = Self.leaves
            animation.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
            leaving.add(animation, forKey: animation.keyPath)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.leaves + 0.02) { old.removeFromSuperview() }
    }
}

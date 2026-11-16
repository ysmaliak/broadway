import AppKit

enum SettingsStageLook {
    static let shortBelow: CGFloat = 540
    static let picture = NSSize(width: 280, height: 172)
    static let smallPicture = NSSize(width: 150, height: 92)
    static let words: CGFloat = 460
    static let foot: CGFloat = 13
    static let smallFoot: CGFloat = 8
    static var under: CGFloat { SettingsHead.below - foot }
    static let move: CFTimeInterval = 0.26
    static let fold: CFTimeInterval = 0.24
    static let ringWidth: CGFloat = 2
    static var ring: NSColor { LookInk.primary(0.85) }
    static let edge = KitTone(base: Palette.NS.sideEdge, kind: .stronger(0.8))
    static var curve: CAMediaTimingFunction { CAMediaTimingFunction(controlPoints: 0.3, 0.8, 0.25, 1) }
}

final class SettingsStageCanvas: NSView {
    var scene = SettingsStageScene()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.cornerRadius = SettingsStagePicture.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = kitDark
        context.saveGState()
        PictureArt.clip(context, bounds, radius: SettingsStagePicture.radius)
        SettingsStageArt.draw(scene, in: bounds, dark: dark, context: context)
        context.restoreGState()
        PictureArt.stroke(context, bounds, radius: SettingsStagePicture.radius, width: 1 / max(window?.backingScaleFactor ?? 2, 1),
                          Palette.NS.pictureEdge.kitResolved(dark: dark))
    }
}

final class SettingsStagePicture: NSView {
    static let radius: CGFloat = 10

    private(set) var scene = SettingsStageScene()
    private(set) var marked: SettingsStageSpot?
    private(set) var moves = 0
    private let canvas = SettingsStageCanvas()
    let ring = KitBox(fill: nil, stroke: SettingsStageLook.ring, corners: .radius(5))

    override init(frame: NSRect) {
        super.init(frame: frame)
        ring.strokeWidth = SettingsStageLook.ringWidth
        ring.alphaValue = 0
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: 3)
        addSubview(canvas)
        addSubview(ring)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("A picture of your Broadway window")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilityValue() -> Any? { marked.map { "Marks \($0.words)" } ?? "" }

    var ringFrame: NSRect? {
        guard let marked else { return nil }
        return SettingsStageLayout(scene, in: bounds).frame(marked)
    }

    func show(_ next: SettingsStageScene) {
        guard next != scene else { return }
        scene = next
        canvas.scene = next
        if window != nil, !Motion.reduced, let layer = canvas.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = SettingsPictureView.fade
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            canvas.display()
            layer.add(fade, forKey: SettingsPictureView.fadeKey)
        } else {
            canvas.needsDisplay = true
        }
        place(animated: true)
    }

    func mark(_ spot: SettingsStageSpot?) {
        guard spot != marked else { return }
        marked = spot
        place(animated: true)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func layout() {
        super.layout()
        if canvas.frame.size != bounds.size { canvas.needsDisplay = true }
        canvas.frame = bounds
        shade()
        place(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        shade()
    }

    private func shade() {
        layer?.shadowOpacity = kitDark ? 0.38 : 0.13
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius, cornerHeight: Self.radius, transform: nil)
    }

    private func place(animated: Bool) {
        let slides = animated && window != nil && !Motion.reduced
        guard let marked, bounds.width > 0 else {
            fade(to: 0, animated: slides)
            return
        }
        let layout = SettingsStageLayout(scene, in: bounds)
        let target = kitSnap(layout.frame(marked))
        ring.corners = .radius(layout.radius(marked))
        guard target != ring.frame || ring.alphaValue < 1 else { return }
        if slides, ring.alphaValue > 0, ring.frame.width > 0 {
            moves += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SettingsStageLook.move
                context.timingFunction = SettingsStageLook.curve
                context.allowsImplicitAnimation = true
                ring.animator().frame = target
            }
        } else {
            ring.frame = target
        }
        fade(to: 1, animated: slides)
    }

    private func fade(to alpha: CGFloat, animated: Bool) {
        guard ring.alphaValue != alpha else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = SettingsPictureView.fade
                ring.animator().alphaValue = alpha
            }
        } else {
            ring.alphaValue = alpha
        }
    }
}

final class SettingsStageBand: NSView {
    let picture = SettingsStagePicture()
    let crumb = SettingsText("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    let title = SettingsText("", font: .systemFont(ofSize: 22, weight: .bold))
    let summary = SettingsText("", font: .systemFont(ofSize: 13), color: .secondaryLabelColor, wraps: true)
    private(set) var facts: SettingsStageFacts?

    var compact = false {
        didSet {
            guard compact != oldValue else { return }
            title.font = .systemFont(ofSize: compact ? 17 : 22, weight: compact ? .semibold : .bold)
            summary.isHidden = compact
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        identifier = NSUserInterfaceItemIdentifier("settings.stage")
        crumb.isHidden = true
        crumb.identifier = NSUserInterfaceItemIdentifier("settings.stage.crumb")
        summary.maximumNumberOfLines = 2
        summary.cell?.truncatesLastVisibleLine = true
        title.setAccessibilityRole(.staticText)
        title.setAccessibilitySubrole(.init(rawValue: "AXHeading"))
        title.identifier = NSUserInterfaceItemIdentifier("settings.stage.title")
        summary.identifier = NSUserInterfaceItemIdentifier("settings.stage.summary")
        for view in [crumb, title, summary] {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.alignment = .center
        }
        for view in [picture, crumb, title, summary] as [NSView] {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = SettingsMetrics.cg(SettingsMetrics.ground, dark: kitDark)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func show(_ next: SettingsStageFacts) {
        guard next != facts else { return }
        facts = next
        title.stringValue = next.title
        summary.stringValue = next.summary
        summary.toolTip = next.summary
        crumb.stringValue = next.crumb ?? ""
        crumb.setAccessibilityLabel(next.crumb.map { "In \($0)" })
        crumb.isHidden = next.crumb == nil
        picture.show(next.scene)
        needsLayout = true
    }

    func mark(_ spot: SettingsStageSpot?) {
        picture.mark(spot)
    }

    private func tall(_ field: NSTextField) -> CGFloat {
        guard let font = field.font else { return 0 }
        return ceil(font.ascender - font.descender + font.leading)
    }

    private var rest: NSSize { compact ? SettingsStageLook.smallPicture : SettingsStageLook.picture }
    private var above: CGFloat { compact ? 24 : 29 }
    private var between: CGFloat { compact ? 8 : 12 }
    private var below: CGFloat { compact ? SettingsStageLook.smallFoot : SettingsStageLook.foot }

    private func blocks(_ width: CGFloat) -> [(view: NSView, tall: CGFloat, wide: CGFloat, after: CGFloat)] {
        let pad = SettingsMetrics.margin + SettingsMetrics.inset
        let room = max(0, min(width - pad * 2, SettingsStageLook.words))
        var blocks: [(view: NSView, tall: CGFloat, wide: CGFloat, after: CGFloat)] = []
        if !crumb.isHidden {
            blocks.append((crumb, tall(crumb), room, 1))
        }
        let shows = !compact && !summary.stringValue.isEmpty
        blocks.append((title, tall(title), room, shows ? 3 : 0))
        if shows {
            let line = tall(summary)
            let wants = summary.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: room, height: 1000)).height ?? line
            blocks.append((summary, max(line, min(ceil(wants), line * 2)), room, 0))
        }
        return blocks
    }

    func measure(_ width: CGFloat) -> CGFloat {
        let words = blocks(width).reduce(0) { $0 + $1.tall + $1.after }
        return above + rest.height + between + words + below
    }

    override func layout() {
        super.layout()
        picture.frame = NSRect(x: ((bounds.width - rest.width) / 2).rounded(), y: above, width: rest.width, height: rest.height)
        var y = picture.frame.maxY + between
        for block in blocks(bounds.width) {
            block.view.frame = NSRect(x: ((bounds.width - block.wide) / 2).rounded(), y: y.rounded(), width: block.wide, height: block.tall)
            y += block.tall + block.after
        }
    }
}

final class SettingsStageEdge: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = SettingsStageLook.edge.resolved(.flat, dark: kitDark).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class SettingsStagePane: NSView {
    let band = SettingsStageBand()
    let paper: SettingsPaper
    private let well = KitFlippedView()
    private let line = SettingsStageEdge()
    private let bar: NSView?
    private var tall: NSLayoutConstraint?
    private var watch: NSObjectProtocol?
    private(set) var folded = false
    private(set) var compact = false
    private(set) var folds = 0
    private(set) var full: CGFloat = 0
    private var ticket = 0
    private var passing = false

    init(paper: SettingsPaper, bar: NSView?) {
        self.paper = paper
        self.bar = bar
        super.init(frame: .zero)
        well.wantsLayer = true
        well.layer?.masksToBounds = true
        for view in [paper, well, band] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        wantsLayer = true
        addSubview(paper)
        addSubview(well)
        addSubview(line)
        well.addSubview(band)
        full = band.measure(SettingsSize.opening.width)
        var constraints = [
            paper.leadingAnchor.constraint(equalTo: leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: trailingAnchor),
            paper.bottomAnchor.constraint(equalTo: bottomAnchor),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            band.leadingAnchor.constraint(equalTo: well.leadingAnchor),
            band.trailingAnchor.constraint(equalTo: well.trailingAnchor),
            band.topAnchor.constraint(equalTo: well.topAnchor),
            band.bottomAnchor.constraint(equalTo: well.bottomAnchor),
            well.topAnchor.constraint(equalTo: paper.topAnchor),
        ]
        let tall = well.heightAnchor.constraint(equalToConstant: full)
        if let bar {
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            constraints += [
                bar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
                bar.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                paper.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 10),
            ]
        } else {
            constraints.append(paper.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor))
        }
        self.tall = tall
        NSLayoutConstraint.activate(constraints + [tall])
        if bar == nil { paper.automaticallyAdjustsContentInsets = false }
        inset(full)
        paper.contentView.postsBoundsChangedNotifications = true
        watch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: paper.contentView, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.cut() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = bar == nil ? SettingsMetrics.cg(SettingsMetrics.ground, dark: kitDark) : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    var room: CGFloat { folded ? 0 : full }
    var lined: Bool { line.kitEdgeShown }
    var lineFrame: NSRect { line.frame }

    func covers(_ point: NSPoint) -> Bool {
        guard !folded else { return false }
        return well.frame.contains(convert(point, from: nil))
    }

    func show(_ facts: SettingsStageFacts?, marked: SettingsStageSpot?, animated: Bool) {
        if let facts {
            band.show(facts)
            band.mark(marked)
            needsLayout = true
        }
        fold(facts == nil, animated: animated)
    }

    var wellFrame: NSRect { well.frame }

    override func scrollWheel(with event: NSEvent) {
        guard !passing else { return super.scrollWheel(with: event) }
        passing = true
        defer { passing = false }
        paper.scrollWheel(with: event)
    }

    override func layout() {
        let top = bar.map { 22 + $0.fittingSize.height } ?? safeAreaInsets.top
        let short = bounds.height > 0 && bounds.height - top < SettingsStageLook.shortBelow
        if short != compact {
            compact = short
            band.compact = short
        }
        let next = band.measure(bounds.width)
        var before: CGFloat?
        if next != full {
            before = scrolled
            full = next
            tall?.constant = next
            inset(folded ? 0 : full)
        }
        super.layout()
        if let before {
            paper.layoutSubtreeIfNeeded()
            paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + before))
            paper.reflectScrolledClipView(paper.contentView)
        }
        cut()
    }

    private var scrolled: CGFloat { max(0, paper.contentView.bounds.minY - paper.top) }

    private func cut() {
        let hair = 1 / max(1, window?.backingScaleFactor ?? 2)
        let y = folded ? paper.frame.minY : paper.frame.minY + full - hair
        line.kitSetFrame(NSRect(x: 0, y: y, width: bounds.width, height: hair))
        line.kitEdge(scrolled > 1)
    }

    private func inset(_ height: CGFloat) {
        guard paper.contentInsets.top != height else { return }
        paper.contentInsets = NSEdgeInsets(top: height, left: 0, bottom: 0, right: 0)
        paper.tile()
    }

    private func fold(_ on: Bool, animated: Bool) {
        guard on != folded else { return }
        let height = full
        folded = on
        folds += 1
        ticket += 1
        let mine = ticket
        inset(on ? 0 : full)
        paper.layoutSubtreeIfNeeded()
        paper.rise()
        cut()
        let slides = animated && window != nil && !Motion.reduced
        band.layer?.removeAnimation(forKey: "settings.fold")
        paper.documentView?.layer?.removeAnimation(forKey: "settings.fold")
        if !on { well.isHidden = false }
        guard slides else {
            if on { well.isHidden = true }
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, ticket == mine else { return }
            if folded { well.isHidden = true }
            band.layer?.removeAnimation(forKey: "settings.fold")
        }
        slide(band.layer, from: on ? 0 : -height, to: on ? -height : 0, holds: on)
        slide(paper.documentView?.layer, from: on ? height : -height, to: 0, holds: false)
        CATransaction.commit()
    }

    private func slide(_ layer: CALayer?, from: CGFloat, to: CGFloat, holds: Bool) {
        guard let layer else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = from
        move.toValue = to
        move.duration = SettingsStageLook.fold
        move.timingFunction = SettingsStageLook.curve
        if holds {
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        layer.add(move, forKey: "settings.fold")
    }
}

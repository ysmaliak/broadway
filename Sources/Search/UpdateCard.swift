import AppKit
import Combine

struct UpdateCardLook: Equatable {
    enum Trailing: Equatable {
        case button(String, label: String)
        case percent(String)
        case spinner
    }

    enum Line: Equatable {
        case none
        case waiting
        case part(Double)
    }

    let title: String
    let trailing: Trailing
    let label: String
    let tip: String?
    let line: Line

    static let available = "Update Available"
    static let checking = "Checking for Updates"
    static let downloading = "Downloading"
    static let installing = "Installing"
    static let failed = "Couldn't Update"
    static let install = "Install"
    static let again = "Try Again"

    static func of(_ phase: UpdatePhase, found: UpdateFound?, progress: Double?, trouble: String?) -> UpdateCardLook {
        let tip = found.map { "Version \($0.version)" }
        switch phase {
        case .checking:
            return UpdateCardLook(title: checking, trailing: .spinner, label: UpdateWords.checking, tip: tip, line: .none)
        case .downloading:
            let label = progress.map { "Downloading, \(UpdateWords.percent($0))" } ?? downloading
            return UpdateCardLook(title: downloading, trailing: progress.map { .percent(UpdateWords.percent($0)) } ?? .spinner, label: label, tip: tip,
                                  line: progress.map { .part($0) } ?? .waiting)
        case .installing:
            return UpdateCardLook(title: installing, trailing: .spinner, label: installing, tip: tip, line: .part(1))
        case .failed:
            return UpdateCardLook(title: failed, trailing: .button(again, label: again), label: UpdateWords.failed, tip: trouble ?? tip, line: .none)
        case .idle, .available:
            let label = found.map { "Update available, version \($0.version)" } ?? "Update available"
            return UpdateCardLook(title: available, trailing: .button(install, label: UpdateWords.install), label: label, tip: tip, line: .none)
        }
    }

    @MainActor static func of(_ flow: UpdateFlow) -> UpdateCardLook {
        of(flow.shown, found: flow.found, progress: flow.progress, trouble: flow.trouble)
    }
}

final class UpdateCardView: KitHoverView {
    static let height: CGFloat = 44
    static let closeSize: CGFloat = 18
    static let closeOut: CGFloat = closeSize / 3
    static let closeEdge: CGFloat = 4
    static let hoverScale: CGFloat = 1.01
    static let closeReach: CGFloat = 24
    static let foot: CGFloat = height + 8
    static let room: CGFloat = closeOut + foot
    static let lineHeight: CGFloat = 2
    static let spinnerSize: CGFloat = 16
    static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    let flow: UpdateFlow
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsLayout = true } } }
    var greys: KitGreys = .white { didSet { if greys != oldValue { needsLayout = true } } }
    var onInstall: () -> Void = {}

    private let card = KitFlippedView()
    private let glass = KitGlass.floating(radius: SideLook.cardRadius, ground: false)
    private let titleLabel = KitLabel(UpdateCardLook.available, font: UpdateCardView.titleFont, color: KitColor.ink)
    private var look: UpdateCardLook
    private lazy var action = KitBroadwayButton(UpdateCardLook.install, kind: .primary, small: true, label: UpdateWords.install) { [weak self] in
        self?.onInstall()
    }
    private lazy var actionAgain = KitBroadwayButton(UpdateCardLook.again, kind: .primary, small: true, label: UpdateCardLook.again) { [weak self] in
        self?.onInstall()
    }
    private let percent = KitLabel("0%", font: UpdateCardView.percentFont, color: KitColor.ink)
    private let spinner = NSProgressIndicator()
    private let rail = KitFlippedView()
    private let fill = CALayer()
    private var spins = false
    private lazy var close: KitButton = {
        let made = KitButton(.plain(press: 0.9), label: "Hide") { [weak self] in self?.flow.hide() }
        let face = KitGlassFace(KitSymbol("xmark", style: KitSymbol.Style(size: 7, weight: .bold)))
        face.effectIsInteractive = true
        made.content = face
        made.toolTip = "Hide"
        made.onHover = { [weak self] _ in self?.tintClose() }
        return made
    }()
    private var closeOut = false
    private var out = false
    private var placed = false
    private var shownArrival: Int
    private var focusWatch: NSKeyValueObservation?
    private var follow: AnyCancellable?

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(flow: UpdateFlow) {
        self.flow = flow
        shownArrival = flow.arrivals
        look = UpdateCardLook.of(flow)
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        card.wantsLayer = true
        card.clipsToBounds = false
        addSubview(card)
        card.addSubview(glass)
        rail.wantsLayer = true
        rail.layer?.masksToBounds = true
        rail.layer?.cornerRadius = SideLook.cardRadius
        rail.layer?.cornerCurve = .continuous
        rail.layer?.addSublayer(fill)
        fill.anchorPoint = .zero
        rail.setAccessibilityElement(false)
        card.addSubview(rail)
        titleLabel.setAccessibilityElement(false)
        card.addSubview(titleLabel)
        titleLabel.overflow = .tail
        percent.setAccessibilityElement(false)
        percent.alignment = .right
        card.addSubview(percent)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setAccessibilityElement(false)
        card.addSubview(spinner)
        for button in [action, actionAgain] {
            button.reach = KitReach.least
            card.addSubview(button)
        }
        card.addSubview(close)
        close.wantsLayer = true
        close.layer?.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(look.label)
        follow = kitObserve({ [weak self] () -> [AnyHashable] in
            guard let self else { return [] }
            let flow = self.flow
            return [flow.arrivals, flow.shown.rawValue, flow.found?.build, flow.progress, flow.trouble]
        }) { [weak self] _ in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let pad: CGFloat = SideLook.rowLead
    static let gap: CGFloat = 6

    static func buttonWidth(_ title: String = UpdateCardLook.install) -> CGFloat {
        ceil(KitLabel(title, font: KitBroadwayButton.font(kind: .primary, small: true)).intrinsicContentSize.width) + 18
    }

    static func percentWidth() -> CGFloat {
        ceil(KitLabel("100%", font: percentFont).intrinsicContentSize.width) + 1
    }

    static func trailingWidth(_ trailing: UpdateCardLook.Trailing) -> CGFloat {
        switch trailing {
        case .button(let title, _): return buttonWidth(title)
        case .percent: return percentWidth()
        case .spinner: return spinnerSize
        }
    }

    static func closeAside(card width: CGFloat) -> CGFloat {
        let room = (Metrics.sideInset - closeEdge - (hoverScale - 1) * width / 2) / hoverScale
        return (min(closeOut, room) * 2).rounded(.down) / 2
    }

    static func textRoom(card width: CGFloat, trailing: UpdateCardLook.Trailing = .button(UpdateCardLook.install, label: UpdateWords.install)) -> CGFloat {
        width - pad - trailingWidth(trailing) - gap - pad
    }

    var focused: Bool {
        guard let view = window?.firstResponder as? NSView else { return false }
        return view.isDescendant(of: card)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusWatch = window?.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.showClose() }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, !out else { return nil }
        let local = convert(point, from: superview)
        let grow = (Self.closeReach - Self.closeSize) / 2
        if closeOut, close.frame.insetBy(dx: -grow, dy: -grow).offsetBy(dx: card.frame.minX, dy: card.frame.minY).contains(local) {
            return close.hitTest(NSPoint(x: local.x - card.frame.minX, y: local.y - card.frame.minY)) ?? close
        }
        guard card.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    var benchState: [String: Any] {
        layoutSubtreeIfNeeded()
        let inWindow = window.map { _ in card.convert(card.bounds, to: nil) } ?? .zero
        let closeBox = card.convert(close.frame, to: nil)
        let scaled = card.layer.map { CATransform3DGetAffineTransform($0.transform) } ?? .identity
        let drawn = card.convert(close.frame.applying(scaled), to: nil)
        return ["card": [inWindow.minX, inWindow.minY, inWindow.width, inWindow.height],
                "close": [closeBox.minX, closeBox.minY, closeBox.width, closeBox.height], "closeShown": closeOut,
                "closeDrawn": [drawn.minX, drawn.minY, drawn.width, drawn.height],
                "title": titleLabel.text, "label": accessibilityLabel() ?? "", "tip": toolTip ?? "", "trailing": trailingKind,
                "button": shownButton?.accessibilityLabel() ?? "", "buttonTitle": shownButton?.title ?? "", "buttonWidth": shownButton?.frame.width ?? 0,
                "percent": percent.isHidden ? "" : percent.text, "percentCut": !percent.isHidden && percent.intrinsicContentSize.width > percent.frame.width + 0.5,
                "spinner": !spinner.isHidden, "spinning": spins,
                "hide": close.accessibilityLabel() ?? "", "titleCut": titleLabel.intrinsicContentSize.width > titleLabel.frame.width + 0.5,
                "titleNeeds": titleLabel.intrinsicContentSize.width, "textRoom": titleLabel.frame.width,
                "titleStart": titleLabel.frame.minX, "trailingEnd": card.bounds.width - trailingFrame.maxX,
                "line": lineState, "lineBox": [fill.frame.minX, fill.frame.minY, fill.frame.width, fill.frame.height],
                "lineShown": !fill.isHidden, "lineColour": fill.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
                    .map { [$0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent] } ?? []]
    }

    private var shownButton: KitBroadwayButton? { [action, actionAgain].first { !$0.isHidden } }

    private var trailingKind: String {
        switch look.trailing {
        case .button: return "button"
        case .percent: return "percent"
        case .spinner: return "spinner"
        }
    }

    private var trailingFrame: NSRect {
        if let shownButton { return shownButton.frame }
        if !percent.isHidden { return percent.frame }
        return spinner.frame
    }

    private var lineState: Any {
        switch look.line {
        case .none: return NSNull()
        case .waiting: return -1
        case .part(let part): return part
        }
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: Metrics.sideInset, y: Self.closeOut, width: max(0, bounds.width - Metrics.sideInset * 2), height: Self.height)
        card.frame = box
        glass.frame = card.bounds
        glass.tintColor = Palette.NS.glassTint
        let dark = kitDark
        look = UpdateCardLook.of(flow)
        let width = Self.trailingWidth(look.trailing)
        let right = box.width - Self.pad
        let titleHeight = ceil(12 * 1.3)
        action.isHidden = true
        actionAgain.isHidden = true
        percent.isHidden = true
        var spinning = false
        switch look.trailing {
        case .button(let title, let label):
            let button = title == UpdateCardLook.again ? actionAgain : action
            button.isHidden = false
            button.setAccessibilityLabel(label)
            button.frame = kitSnap(NSRect(x: right - width, y: (Self.height - 22) / 2, width: width, height: 22))
        case .percent(let text):
            percent.isHidden = false
            percent.text = text
            percent.ink = ink
            percent.frame = kitSnap(NSRect(x: right - width, y: (Self.height - titleHeight) / 2, width: width, height: titleHeight))
        case .spinner:
            spinning = true
        }
        spinner.frame = kitSnap(NSRect(x: right - Self.spinnerSize, y: (Self.height - Self.spinnerSize) / 2, width: Self.spinnerSize, height: Self.spinnerSize))
        spin(spinning)
        let start = Self.pad
        let room = max(0, right - width - Self.gap - start)
        titleLabel.text = look.title
        titleLabel.frame = kitSnap(NSRect(x: start, y: (Self.height - titleHeight) / 2, width: room, height: titleHeight))
        titleLabel.ink = ink
        rail.frame = card.bounds
        rail.isHidden = look.line == .none
        drawLine(look.line)
        toolTip = look.tip
        setAccessibilityLabel(look.label)
        close.frame = NSRect(x: -Self.closeAside(card: box.width), y: -Self.closeOut, width: Self.closeSize, height: Self.closeSize)
        tintClose(dark: dark)
        arrive()
    }

    private func spin(_ on: Bool) {
        spinner.isHidden = !on
        let moving = on && !Motion.reduced
        spinner.isDisplayedWhenStopped = on
        guard moving != spins else { return }
        spins = moving
        if moving { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func drawLine(_ line: UpdateCardLook.Line) {
        let size = rail.bounds.size
        var accent = NSColor.controlAccentColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.cgColor }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.backgroundColor = accent
        fill.isHidden = line == .none
        CATransaction.commit()
        let y = size.height - Self.lineHeight
        switch line {
        case .none:
            fill.removeAnimation(forKey: "sweep")
        case .part(let part):
            fill.removeAnimation(forKey: "sweep")
            fill.opacity = 1
            let target = NSRect(x: 0, y: y, width: (size.width * CGFloat(min(1, max(0, part)))).rounded(), height: Self.lineHeight)
            fill.position = target.origin
            fill.kitAnimate("bounds", to: NSValue(rect: NSRect(origin: .zero, size: target.size)), curve: Motion.kitQuick)
        case .waiting:
            let span = (size.width * 0.3).rounded()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fill.bounds = NSRect(x: 0, y: 0, width: Motion.calm ? size.width : span, height: Self.lineHeight)
            fill.position = NSPoint(x: 0, y: y)
            fill.opacity = Motion.calm ? 0.5 : 1
            CATransaction.commit()
            guard !Motion.calm else {
                fill.removeAnimation(forKey: "sweep")
                return
            }
            guard fill.animation(forKey: "sweep") == nil else { return }
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = -span
            sweep.toValue = size.width
            sweep.duration = 1.4
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fill.add(sweep, forKey: "sweep")
        }
    }

    private func arrive() {
        guard flow.arrivals != shownArrival, !isHiddenOrHasHiddenAncestor, window != nil, card.frame.width > 0 else { return }
        shownArrival = flow.arrivals
        NoticeMotion.show(card, false, animated: false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NoticeMotion.show(self.card, true)
        }
    }

    func shown(_ on: Bool) {
        defer { placed = true }
        if on {
            guard out || isHidden || !placed else { return }
            out = false
            isHidden = false
            guard placed, window != nil else { return NoticeMotion.show(card, true, animated: false) }
            NoticeMotion.enter(card)
            return
        }
        guard !out, !isHidden else { return }
        out = true
        guard placed, window != nil else {
            isHidden = true
            return
        }
        NoticeMotion.show(card, false)
        let timer = Timer(timeInterval: NoticeMotion.leaveTime, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.out else { return }
                self.isHidden = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tintClose(dark: Bool? = nil) {
        guard let face = close.content as? KitGlassFace else { return }
        face.tintColor = KitGlass.keyTint(.secondary, dark: dark ?? kitDark)
        guard let symbol = face.face as? KitSymbol else { return }
        symbol.ink = ink
        symbol.tint = KitColor.ink
        symbol.opacity = close.hovering ? 1 : 0.86
    }

    private func showClose() {
        let shown = hovering || focused
        guard shown != closeOut else { return }
        closeOut = shown
        close.layer?.kitAnimate("opacity", to: shown ? 1 : 0, curve: Motion.kitQuick, key: "fade")
    }

    override func hoverChanged() {
        showClose()
        guard let layer = card.layer else { return }
        let scale: CGFloat = hovering ? Self.hoverScale : 1
        let size = card.bounds.size
        let transform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                                CATransform3DMakeScale(scale, scale, 1)),
                                            CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
        layer.kitAnimate("transform", to: NSValue(caTransform3D: transform), curve: Motion.kitQuick)
    }
}

extension UpdateCardView {
    func benchHover(_ on: Bool) {
        guard let window else { return }
        KitHoverView.pointerStandIn = on ? (window, convert(NSPoint(x: card.frame.midX, y: card.frame.midY), to: nil)) : nil
        settleHover()
    }

    static func bench(_ browser: Browser) -> [String: Any] {
        guard let content = browser.window?.contentView else { return ["window": false] }
        func find<View: NSView>(_ view: NSView, _ kind: View.Type) -> View? {
            if let found = view as? View, !found.isHiddenOrHasHiddenAncestor { return found }
            for sub in view.subviews { if let found = find(sub, kind) { return found } }
            return nil
        }
        func box(_ view: NSView?) -> Any {
            guard let view, !view.isHiddenOrHasHiddenAncestor else { return NSNull() }
            let frame = view.convert(view.bounds, to: nil)
            return [frame.minX, content.bounds.height - frame.maxY, frame.width, frame.height]
        }
        let card = find(content, UpdateCardView.self)
        let mini = find(content, MiniPlayerView.self)
        let column = find(content, SideColumnView.self)
        let foot = find(content, SpaceFootView.self)
        let menu = NSApp.mainMenu?.items.first?.submenu?.items ?? []
        return ["shown": card != nil, "card": card?.benchState ?? NSNull(), "view": box(card), "mini": box(mini), "column": box(column),
                "foot": box(foot), "private": browser.isPrivate, "folded": browser.folded,
                "menu": menu.filter { !$0.isHidden }.map(\.title)]
    }
}

import AppKit
import Combine

final class UpdateCardView: KitHoverView {
    static let height: CGFloat = 44
    static let closeSize: CGFloat = 18
    static let closeOut: CGFloat = closeSize / 3
    static let closeReach: CGFloat = 24
    static let foot: CGFloat = height + 8
    static let room: CGFloat = closeOut + foot
    static let title = "Update Ready"
    static let button = "Restart"

    let wait: UpdateWait
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsLayout = true } } }
    var greys: KitGreys = .white { didSet { if greys != oldValue { needsLayout = true } } }
    var onRestart: () -> Void = {}

    private let card = KitFlippedView()
    private let glass = KitGlass.floating(radius: SideLook.cardRadius)
    private let titleLabel = KitLabel(UpdateCardView.title, font: UpdateCardView.titleFont, color: KitColor.ink)
    private lazy var restart = KitBroadwayButton(Self.button, kind: .primary, small: true, label: UpdateWords.restart) { [weak self] in
        self?.onRestart()
    }
    private lazy var close: KitButton = {
        let made = KitButton(.plain(press: 0.9), label: "Hide") { [weak self] in self?.wait.hide() }
        let face = KitGlassFace(KitSymbol("xmark", style: KitSymbol.Style(size: 7, weight: .bold)))
        face.effectIsInteractive = true
        face.plate = Palette.NS.glassGround
        made.content = face
        made.toolTip = "Hide"
        made.onHover = { [weak self] _ in self?.tintClose() }
        return made
    }()
    private var closeOut = false
    private var shownArrival: Int
    private var focusWatch: NSKeyValueObservation?
    private var follow: AnyCancellable?

    static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(wait: UpdateWait) {
        self.wait = wait
        shownArrival = wait.arrivals
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        card.wantsLayer = true
        card.clipsToBounds = false
        addSubview(card)
        card.addSubview(glass)
        titleLabel.setAccessibilityElement(false)
        card.addSubview(titleLabel)
        titleLabel.overflow = .tail
        card.addSubview(restart)
        restart.toolTip = UpdateWords.restart
        restart.reach = KitReach.least
        card.addSubview(close)
        close.wantsLayer = true
        close.layer?.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.title)
        follow = kitObserve({ [weak self] in self?.wait.arrivals }) { [weak self] _ in self?.needsLayout = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static let pad: CGFloat = SideLook.rowLead
    static let gap: CGFloat = 6

    static func buttonWidth() -> CGFloat {
        ceil(KitLabel(button, font: KitBroadwayButton.font(kind: .primary, small: true)).intrinsicContentSize.width) + 18
    }

    static func textRoom(card width: CGFloat) -> CGFloat {
        width - pad - buttonWidth() - gap - pad
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
        guard !isHidden else { return nil }
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
        return ["card": [inWindow.minX, inWindow.minY, inWindow.width, inWindow.height],
                "close": [closeBox.minX, closeBox.minY, closeBox.width, closeBox.height], "closeShown": closeOut,
                "restart": restart.frame.width, "label": accessibilityLabel() ?? "", "button": restart.accessibilityLabel() ?? "",
                "hide": close.accessibilityLabel() ?? "", "titleCut": titleLabel.intrinsicContentSize.width > titleLabel.frame.width + 0.5,
                "titleNeeds": titleLabel.intrinsicContentSize.width, "textRoom": titleLabel.frame.width,
                "titleStart": titleLabel.frame.minX, "restartEnd": card.bounds.width - restart.frame.maxX]
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: Metrics.sideInset, y: Self.closeOut, width: max(0, bounds.width - Metrics.sideInset * 2), height: Self.height)
        card.frame = box
        glass.frame = card.bounds
        glass.tintColor = Palette.NS.glassTint
        let dark = kitDark
        let width = Self.buttonWidth()
        restart.frame = kitSnap(NSRect(x: box.width - Self.pad - width, y: (Self.height - 22) / 2, width: width, height: 22))
        let start = Self.pad
        let room = max(0, restart.frame.minX - Self.gap - start)
        let titleHeight = ceil(12 * 1.3)
        titleLabel.frame = kitSnap(NSRect(x: start, y: (Self.height - titleHeight) / 2, width: room, height: titleHeight))
        titleLabel.ink = ink
        close.frame = NSRect(x: -Self.closeOut, y: -Self.closeOut, width: Self.closeSize, height: Self.closeSize)
        tintClose(dark: dark)
        arrive()
    }

    private func arrive() {
        guard wait.arrivals != shownArrival, !isHiddenOrHasHiddenAncestor, window != nil, card.frame.width > 0 else { return }
        shownArrival = wait.arrivals
        card.kitArrive(false, .rise(by: 8), animated: false)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.card.kitArrive(true, .rise(by: 8))
        }
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
        let scale: CGFloat = hovering ? 1.01 : 1
        let size = card.bounds.size
        let transform = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-size.width / 2, -size.height / 2, 0),
                                                                CATransform3DMakeScale(scale, scale, 1)),
                                            CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0))
        layer.kitAnimate("transform", to: NSValue(caTransform3D: transform), curve: Motion.kitQuick)
    }
}

extension UpdateCardView {
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

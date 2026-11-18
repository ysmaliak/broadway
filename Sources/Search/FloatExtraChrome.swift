import AppKit

final class FloatCaptionsView: FloatPiece {
    static let height: CGFloat = 30
    static let lead: CGFloat = 32
    static let tail: CGFloat = 24

    private let choose: (Int?) -> Void
    private let pill = KitGlass.floating()
    private let row = KitFlippedView()
    private let divider = KitBox(fill: NSColor(white: 1, alpha: 0.24))
    private lazy var toggle = FloatKeyView(symbol: "captions.bubble", size: 12, weight: .semibold, glassed: false, label: "Subtitles",
                                           help: "Toggle Subtitles   C") { [weak self] in self?.choose(nil) }
    private lazy var pick = FloatKeyView(symbol: "chevron.down", size: 10, weight: .semibold, glassed: false, label: "Subtitle Language",
                                         help: "Subtitle Language") { [weak self] in self?.menu() }

    init(chrome: FloatChrome, choose: @escaping (Int?) -> Void) {
        self.choose = choose
        super.init(chrome: chrome, arrival: .unfold(from: KitArrival.top))
        pill.style = .regular
        pill.effectIsInteractive = true
        pill.hold(row)
        body.addSubview(pill)
        row.addSubview(divider)
        row.addSubview(toggle)
        row.addSubview(pick)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        chrome.captions.isEmpty ? nil : super.hitTest(point)
    }

    var capsule: NSRect { pill.frame }
    var divided: Bool { !divider.isHidden }
    var dividerWidth: CGFloat { divider.frame.width }

    override func arrange() {
        let captions = chrome.captions
        let many = captions.count > 1
        body.alphaValue = captions.isEmpty ? 0 : 1
        setAccessibilityElement(false)
        toggle.setAccessibilityElement(!captions.isEmpty)
        pick.isHidden = !many
        toggle.symbol?.name = chrome.captioned ? "captions.bubble.fill" : "captions.bubble"
        toggle.setAccessibilityValue(chrome.captioned ? "On" : "Off")
        let height = Self.height
        let lead = many ? Self.lead : height
        let width = lead + (many ? Self.tail : 0)
        let box = kitSnap(NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height))
        pill.frame = box
        pill.cornerRadius = height / 2
        row.frame = pill.bounds
        toggle.frame = NSRect(x: 0, y: 0, width: lead, height: height)
        pick.frame = NSRect(x: lead, y: 0, width: box.width - lead, height: height)
        let line = 1 / max(1, window?.backingScaleFactor ?? 2)
        divider.isHidden = !many
        divider.frame = NSRect(x: pick.frame.minX - line / 2, y: 8, width: line, height: height - 16)
    }

    private func menu() {
        var items: [KitMenuItem] = [.action("Off") { [weak self] in self?.choose(-1) }]
        for track in chrome.captions {
            items.append(.action(track.name, on: track.selected) { [weak self] in self?.choose(track.id) })
        }
        KitMenu.pop(items, below: pick)
    }
}

final class FloatLiveView: FloatPiece {
    private let goLive: () -> Void
    private let words = KitLabel("Live", font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold), color: .white)
    private lazy var key = FloatKeyView(text: "Go Live", font: .systemFont(ofSize: 10, weight: .semibold), label: "Go Live") { [weak self] in
        self?.goLive()
    }

    init(chrome: FloatChrome, goLive: @escaping () -> Void) {
        self.goLive = goLive
        super.init(chrome: chrome, arrival: .rise(by: 6))
        body.addSubview(words)
        body.addSubview(key)
        words.setAccessibilityElement(false)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        chrome.timeline.live ? super.hitTest(point) : nil
    }

    override func arrange() {
        let live = chrome.timeline.live
        let lag = chrome.lag
        body.alphaValue = live ? 1 : 0
        words.text = lag <= 2 ? "Live" : "−\(FloatTime.label(lag))"
        let going = chrome.timeline.seekable && lag > 2
        key.isHidden = !going
        let text = words.intrinsicContentSize
        let keyWidth = key.face.intrinsicContentSize.width + 16
        let width = text.width + (going ? 6 + keyWidth : 0)
        let x = bounds.width - width
        words.frame = kitSnap(NSRect(x: x, y: (bounds.height - text.height) / 2, width: text.width, height: text.height))
        key.frame = kitSnap(NSRect(x: x + text.width + 6, y: (bounds.height - FloatLayout.line) / 2, width: keyWidth, height: FloatLayout.line))
        setAccessibilityElement(live)
        setAccessibilityRole(.group)
        setAccessibilityValue(!chrome.timeline.seekable ? "Live stream" : lag <= 2 ? "At live edge" : "\(FloatTime.label(lag)) behind live")
    }
}

final class FloatWaitingView: KitFlippedView {
    let chrome: FloatChrome
    private let glass = KitGlass.floating()
    private let words = KitLabel("Buffering", font: .systemFont(ofSize: 11, weight: .medium), color: .white)
    private let spinner = NSProgressIndicator()
    private var was: Bool?

    init(chrome: FloatChrome) {
        self.chrome = chrome
        super.init(frame: .zero)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        glass.style = .regular
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        addSubview(glass)
        addSubview(spinner)
        addSubview(words)
        words.setAccessibilityElement(false)
        kitAccess(label: "Buffering")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let waiting = chrome.waiting
        let spins = !Motion.calm
        let text = words.intrinsicContentSize
        let wheel = spins ? spinner.fittingSize : .zero
        let inner = NSSize(width: text.width + (spins ? wheel.width + 6 : 0), height: max(text.height, wheel.height))
        let size = NSSize(width: inner.width + 20, height: FloatLayout.line)
        let box = kitSnap(NSRect(x: 0, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
        glass.frame = box
        glass.cornerRadius = size.height / 2
        spinner.isHidden = !spins
        spinner.frame = kitSnap(NSRect(x: box.minX + 10, y: box.midY - wheel.height / 2, width: wheel.width, height: wheel.height))
        let x = box.minX + 10 + (spins ? wheel.width + 6 : 0)
        words.frame = kitSnap(NSRect(x: x, y: box.midY - text.height / 2, width: text.width, height: text.height))
        if waiting && spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        setAccessibilityElement(waiting)
        guard waiting != was else { return }
        layer?.kitAnimate("opacity", to: waiting ? 1 : 0, curve: was == nil || Motion.reduced ? .none : .easeOut(0.12))
        was = waiting
    }
}

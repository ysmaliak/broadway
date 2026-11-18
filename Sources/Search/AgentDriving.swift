import AppKit

extension Tab {
    var agentHere: Bool {
        agentActing != nil || (agent && agentTask != nil && agentFinished == nil)
            || AgentDesk.shared.pending.contains { $0.tab == id }
    }
}

extension Browser {
    @discardableResult
    func takeOver() -> Bool {
        guard let tab = active, tab.agentHere, !tab.driving else { return false }
        dropQuestions(for: tab.id)
        tab.driving = true
        tab.agentActing = nil
        for question in AgentDesk.shared.pending where question.tab == tab.id {
            AgentDesk.shared.take(question.id, .dropped)
        }
        return true
    }

    @discardableResult
    func handBack() -> Bool {
        guard let tab = active, tab.driving else { return false }
        tab.driving = false
        tab.handedBack = true
        return true
    }

    func clickTakesOver(in window: NSWindow?, at point: NSPoint) {
        guard let tab = active, tab.agentHere, !tab.driving, let web = tab.built, web.window === window else { return }
        guard web.bounds.contains(web.convert(point, from: nil)) else { return }
        takeOver()
    }

    func drivingKey(_ event: NSEvent) -> Bool {
        guard active?.driving == true, event.keyCode == 36 || event.keyCode == 76 else { return false }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]) == .command else { return false }
        guard !event.isARepeat else { return true }
        return handBack()
    }
}

enum AgentDriving {
    static let acts: Set<String> = ["click", "type", "press", "hover", "choose", "upload", "download", "fill_form", "drag", "select", "resize", "dialog", "scroll", "navigate", "close", "sign_in", "autofill"]

    @MainActor static func settled(_ tab: Tab, patience: Duration) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + patience
        while tab.driving, clock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !tab.driving
    }
}

final class AgentDrivingBarView: KitFlippedView, KitOnGlass {
    var ink: KitInk = .flat { didSet { if ink != oldValue { needsLayout = true } } }

    private let glass = KitGlass.floating(radius: 16)
    private let wheel = KitSymbol("steeringwheel", style: KitSymbol.Style(size: 12))
    private let words = KitLabel("You're driving", font: .systemFont(ofSize: 12, weight: .medium))
    private let back = KitButton(.keycap(.secondary), label: "Hand Back")
    private let pair = KitPairLabel(KitLabel("Hand Back", font: .systemFont(ofSize: 12)),
                                    KitLabel("⌘↩", font: .systemFont(ofSize: 12), color: KitColor.muted), spacing: 5)

    init(handBack: @escaping () -> Void) {
        super.init(frame: .zero)
        addSubview(glass)
        addSubview(wheel)
        addSubview(words)
        back.content = pair
        back.padding = 9
        back.height = 22
        back.action = handBack
        addSubview(back)
        words.setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let width = 12 + wheel.intrinsicContentSize.width + 10 + words.intrinsicContentSize.width + 10
            + back.intrinsicContentSize.width + 6
        return NSSize(width: ceil(width), height: 32)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let size = intrinsicContentSize
        let box = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: 0, width: size.width, height: 32))
        glass.frame = box
        glass.cornerRadius = 16
        wheel.ink = ink
        words.ink = ink
        pair.first.ink = ink
        pair.second.ink = ink
        var x = box.minX + 12
        for view in [wheel, words] as [NSView] {
            let natural = view.intrinsicContentSize
            view.frame = kitSnap(NSRect(x: x, y: box.midY - natural.height / 2, width: natural.width, height: natural.height))
            x += natural.width + 10
        }
        let button = back.intrinsicContentSize
        back.frame = kitSnap(NSRect(x: x, y: box.midY - 11, width: button.width, height: 22))
    }
}

final class KitPairLabel: NSView {
    let first: KitLabel
    let second: KitLabel
    let spacing: CGFloat

    init(_ first: KitLabel, _ second: KitLabel, spacing: CGFloat) {
        self.first = first
        self.second = second
        self.spacing = spacing
        super.init(frame: .zero)
        addSubview(first)
        addSubview(second)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let a = first.intrinsicContentSize, b = second.intrinsicContentSize
        return NSSize(width: a.width + spacing + b.width, height: max(a.height, b.height))
    }

    override func layout() {
        super.layout()
        let a = first.intrinsicContentSize, b = second.intrinsicContentSize
        first.frame = kitSnap(NSRect(x: 0, y: (bounds.height - a.height) / 2, width: a.width, height: a.height))
        second.frame = kitSnap(NSRect(x: a.width + spacing, y: (bounds.height - b.height) / 2, width: b.width, height: b.height))
    }
}

extension AgentDriving {
    @MainActor static func surface() -> NSView {
        let bar = AgentDrivingBarView {}
        let size = bar.intrinsicContentSize
        return BenchFloating.sized(bar, NSSize(width: size.width + 8, height: size.height + 4))
    }
}

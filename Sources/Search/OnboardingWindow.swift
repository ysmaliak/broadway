import AppKit

final class OnboardingWindow: NSWindow {
    let onboarding: Onboarding

    init(onboarding: Onboarding, frame: NSRect) {
        self.onboarding = onboarding
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .normal
        hidesOnDeactivate = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        collectionBehavior = [.fullScreenNone, .ignoresCycle]
        title = "Welcome to Broadway"
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private var composing: Bool {
        (firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), !composing, onboarding.takes(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command), onboarding.takes(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class OnboardingShow: OnboardingStage {
    static let shared = OnboardingShow()
    static let screenKey = "onboarding.screen"
    static let backKey = "onboarding.back"
    static let sizeKey = "onboarding.size"
    static let freezeKey = "onboarding.freeze"
    static let activeKey = "onboarding.active"

    private(set) var window: OnboardingWindow?
    private(set) var view: OnboardingView?
    private weak var held: NSWindow?
    private var watches: [NSObjectProtocol] = []
    private var front = false
    private var aside = false

    static let above = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)

    var waits = false

    func hold(_ window: NSWindow) { held = window }

    func clear() { dismiss() }

    func makeWay() {
        aside = true
        settle()
    }

    func takeBack() {
        aside = false
        settle()
    }

    static func level(front: Bool, active: Bool, aside: Bool) -> NSWindow.Level {
        front && active && !aside ? above : .normal
    }

    private func settle() {
        window?.level = Self.level(front: front, active: NSApp.isActive, aside: aside)
    }

    func roll() {
        guard let view else { return }
        view.alphaValue = 1
        view.play()
    }

    func keeps(_ window: NSWindow) -> Bool {
        held === window && Onboarding.shared.showing
    }

    static func screen(settings: UserDefaults = Store.settings) -> NSScreen? {
        let all = NSScreen.screens
        if Store.testing, let asked = settings.object(forKey: screenKey) as? Int, all.indices.contains(asked) { return all[asked] }
        return NSScreen.main ?? all.first
    }

    private static func frame(on screen: NSScreen?) -> NSRect {
        let whole = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard Store.testing, let asked = Store.settings.array(forKey: sizeKey) as? [Double], asked.count == 2 else { return whole }
        let size = NSSize(width: asked[0], height: asked[1])
        return NSRect(x: whole.midX - size.width / 2, y: whole.midY - size.height / 2, width: size.width, height: size.height)
    }

    func raise(_ onboarding: Onboarding) {
        dismiss()
        let screen = Self.screen()
        let made = OnboardingWindow(onboarding: onboarding, frame: Self.frame(on: screen))
        let view = OnboardingView(onboarding: onboarding)
        view.frame = NSRect(origin: .zero, size: made.frame.size)
        view.autoresizingMask = [.width, .height]
        made.contentView = view
        window = made
        self.view = view
        view.layoutSubtreeIfNeeded()
        let freeze = Store.testing ? Store.settings.object(forKey: Self.freezeKey) as? Double : nil
        if Store.testing, waits { view.alphaValue = 0 } else { view.play(freezeAt: freeze) }
        guard !Store.testing || Store.shownOnScreen else { return }
        if Store.testing, !Store.settings.bool(forKey: Self.activeKey) {
            if Store.settings.bool(forKey: Self.backKey) { made.order(.below, relativeTo: 0) } else { made.orderFrontRegardless() }
            made.makeKey()
        } else {
            front = true
            NSApp.activate()
            settle()
            made.makeKeyAndOrderFront(nil)
        }
        let centre = NotificationCenter.default
        watches.append(centre.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refit() }
        })
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            watches.append(centre.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle() }
            })
        }
    }

    private func refit() {
        guard let window else { return }
        let screen = window.screen ?? Self.screen()
        window.setFrame(Self.frame(on: screen), display: true)
    }

    func handOff(_ onboarding: Onboarding, done: @escaping () -> Void) {
        let main = held ?? SceneWindow.window
        held = nil
        guard let window, window.isVisible else {
            if let main, !Store.testing || Store.shownOnScreen { SceneWindow.show(main) }
            dismiss()
            done()
            return
        }
        let calm = onboarding.score.drawn == false
        let takes = calm ? 0.3 : 0.55
        if let main, !main.isVisible {
            main.alphaValue = 0
            SceneWindow.show(main, below: window)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = calm ? 0.3 : 0.4
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                main.animator().alphaValue = 1
            }
        }
        view?.leave(takes: takes)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = takes
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0
        }
        onboarding.after(takes + 0.03) { [weak self] in
            main?.alphaValue = 1
            if self?.window === window { self?.dismiss() } else { window.orderOut(nil) }
            if let main, main.isVisible, !Store.testing { main.makeKeyAndOrderFront(nil) }
            done()
        }
    }

    private func dismiss() {
        for watch in watches { NotificationCenter.default.removeObserver(watch) }
        watches = []
        front = false
        aside = false
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        view = nil
    }
}

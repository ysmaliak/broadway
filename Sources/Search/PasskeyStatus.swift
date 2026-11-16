import AppKit
import AuthenticationServices

enum PasskeyStatus: String, Equatable {
    case awaitingApple, notAsked, refused, ready

    static func of(entitled: Bool, access: ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState) -> PasskeyStatus {
        guard entitled else { return .awaitingApple }
        switch access {
        case .authorized: return .ready
        case .denied: return .refused
        default: return .notAsked
        }
    }

    @MainActor static var current: PasskeyStatus { of(entitled: Preferences.entitledToPasskeys, access: Passkeys.access) }

    var possible: Bool { self != .awaitingApple }

    var detail: String? {
        switch self {
        case .awaitingApple: return "Off for now, because this build doesn't have Apple's browser permission"
        case .notAsked: return "Allow it once so sign-in boxes can offer your passkeys"
        case .refused: return "Off in macOS: System Settings › Privacy & Security › Passkeys"
        case .ready: return nil
        }
    }
}

extension Passkeys {
    static func askTheMac(then: @escaping @MainActor () -> Void) {
        guard PasskeyStatus.current == .notAsked else { return then() }
        ASAuthorizationWebBrowserPublicKeyCredentialManager().requestAuthorizationForPublicKeyCredentials { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated(then) }
        }
    }
}

final class PasskeySwitchView: KitFlippedView {
    var on = false { didSet { if on != oldValue { toggle.set(on, animated: true) } } }
    var set: (Bool) -> Void = { _ in }

    private var status = PasskeyStatus.current { didSet { if status != oldValue { refresh() } } }
    private let toggle = KitSwitch(small: true, system: true)
    private lazy var allow = KitButton(title: "Allow…", font: .systemFont(ofSize: 13), look: .pill(.secondary)) { [weak self] in
        Passkeys.askTheMac { self?.status = .current }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        allow.padding = 12
        allow.height = 28
        addSubview(allow)
        addSubview(toggle)
        toggle.onChange = { [weak self] on in self?.set(on) }
        toggle.kitAccess(label: "Passkeys")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var asks: Bool { status == .notAsked }

    private func refresh() {
        allow.isHidden = !asks
        let live = status.possible || Store.testing
        toggle.isEnabled = live
        toggle.set(live && on, animated: false)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let knob = toggle.intrinsicContentSize
        let button = asks ? allow.intrinsicContentSize : .zero
        return NSSize(width: knob.width + (asks ? button.width + 8 : 0), height: max(knob.height, asks ? 28 : 0))
    }

    override func layout() {
        super.layout()
        let knob = toggle.intrinsicContentSize
        var x = max(0, (bounds.width - intrinsicContentSize.width) / 2)
        if asks {
            let button = allow.intrinsicContentSize
            allow.frame = kitSnap(NSRect(x: x, y: (bounds.height - 28) / 2, width: button.width, height: 28))
            x += button.width + 8
        }
        toggle.frame = kitSnap(NSRect(x: x, y: (bounds.height - knob.height) / 2, width: knob.width, height: knob.height))
    }
}

extension PasskeyStatus {
    @MainActor static func surface(broadway: Bool) -> NSView {
        let view = PasskeySwitchView()
        view.on = Shared.prefs.passkeys
        let size = view.intrinsicContentSize
        return BenchFloating.sized(view, NSSize(width: size.width + 8, height: size.height + 8))
    }
}

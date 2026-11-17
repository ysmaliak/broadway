import AppKit

enum TroubleKind: String, CaseIterable {
    case notFound, offline, slow, refused, insecure, tooLarge, other

    init(code: Int) {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: self = .notFound
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost: self = .offline
        case NSURLErrorTimedOut: self = .slow
        case NSURLErrorCannotConnectToHost: self = .refused
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
            self = .insecure
        default: self = .other
        }
    }

    @MainActor static var lastSeen = ""

    init(error: NSError) {
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ECONNREFUSED: self = .refused
            case ETIMEDOUT: self = .slow
            case ENETDOWN, ENETUNREACH, EHOSTUNREACH: self = .offline
            default: self = .other
            }
            return
        }
        let kind = error.domain == NSURLErrorDomain ? TroubleKind(code: error.code) : .other
        if kind == .other, let under = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            self = TroubleKind(error: under)
        } else {
            self = kind
        }
    }

    init(message: String?) {
        self = Self.allCases.first { $0.message == message } ?? .other
    }

    var message: String {
        switch self {
        case .notFound: return "No site at that address"
        case .offline: return "You're offline"
        case .slow: return "The site took too long to answer"
        case .refused: return "The site refused the connection"
        case .insecure: return "This connection isn't private"
        case .tooLarge: return MemoryWords.title
        case .other: return "The page didn't load"
        }
    }

    func line(host: String?) -> String {
        let site = host.map { "\u{201C}\($0)\u{201D}" } ?? "this site"
        switch self {
        case .notFound: return "Broadway couldn't find \(site). Check the spelling, or search for it instead."
        case .offline: return "Your Mac isn't connected to the internet. Reconnect, then try again."
        case .slow: return "\(site.prefix(1).uppercased() + site.dropFirst()) is taking its time. It might be busy, so try again in a moment."
        case .refused: return "\(site.prefix(1).uppercased() + site.dropFirst()) is there, but isn't taking visitors right now"
        case .insecure: return "Broadway couldn't confirm \(site) is who it says it is, so it stopped before anything was sent"
        case .tooLarge: return MemoryWords.line
        case .other: return "Something got in the way. Trying again often fixes it."
        }
    }

    var symbol: String {
        switch self {
        case .notFound: return "questionmark.app.dashed"
        case .offline: return "wifi.slash"
        case .slow: return "hourglass"
        case .refused: return "hand.raised"
        case .insecure: return "lock.slash"
        case .tooLarge: return "memorychip"
        case .other: return "exclamationmark.triangle"
        }
    }
}

extension Tab {
    var trouble: TroubleKind? { failure.map { TroubleKind(message: $0) } }
}

final class TroubleView: KitFlippedView {
    var onRetry: () -> Void
    var onSearch: (() -> Void)? { didSet { searchButton.isHidden = !(kind == .notFound && onSearch != nil) } }
    var look: SpaceLook { didSet { if look != oldValue { restyle() } } }

    private(set) var message: String
    private(set) var host: String?
    private var kind: TroubleKind { TroubleKind(message: message) }

    private let ground = PageGroundView()
    private let glow = TroubleGlow()
    private let disc = KitBox(fill: nil, corners: .capsule)
    private let glyph = KitSymbol("exclamationmark.triangle", style: .init(size: 38, weight: .semibold))
    private let title = KitParagraph("", font: .systemFont(ofSize: 26, weight: .bold), color: KitColor.ink, alignment: .center)
    private let line = KitParagraph("", font: .systemFont(ofSize: 15), color: KitColor.muted, alignment: .center, maxWidth: 400)
    private let retryPill = TroublePill("Try Again")
    private let searchPill = TroublePill("Search Instead")
    private lazy var retryButton = KitButton(.plain(press: 0.94), label: "Try Again") { [weak self] in self?.onRetry() }
    private lazy var searchButton = KitButton(.plain(press: 0.94), label: "Search Instead") { [weak self] in self?.onSearch?() }
    private let stack = NSStackView.kit(.vertical, spacing: 14, alignment: .centerX, [])

    init(message: String, host: String? = nil, look: SpaceLook = SpaceLook(),
         search: (() -> Void)? = nil, retry: @escaping () -> Void) {
        self.message = message
        self.host = host
        self.look = look
        self.onRetry = retry
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(ground)
        addSubview(glow)
        disc.kitSize(width: 92, height: 92)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(glyph)
        NSLayoutConstraint.activate([glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
                                     glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor)])
        disc.setAccessibilityElement(false)
        retryButton.content = retryPill
        searchButton.content = searchPill
        searchPill.fill = KitColor.ink.withAlphaComponent(0.07)
        searchPill.label.color = KitColor.ink
        let buttons = NSStackView.kit(.horizontal, spacing: 10, [retryButton, searchButton])
        for view in [disc, title, line, buttons] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(20, after: disc)
        stack.setCustomSpacing(24, after: line)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let wide = stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            wide,
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            line.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        self.onSearch = search
        show(message: message, host: host)
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(message: String, host: String?) {
        self.message = message
        self.host = host
        glyph.name = kind.symbol
        title.text = message
        line.text = kind.line(host: host)
        searchButton.isHidden = !(kind == .notFound && onSearch != nil)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        glow.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private(set) var page: PageGround?

    private func restyle() {
        let page = look.page(dark: kitDark)
        self.page = page
        ground.show(page)
        stack.appearance = page.appearance
        let accent = page.accentColour
        glow.tint = accent
        disc.fill = accent.withAlphaComponent(0.14)
        glyph.tint = accent
        retryPill.fill = accent
        retryPill.label.color = page.accentInk
    }
}

final class TroubleGlow: KitFlippedView {
    var tint: NSColor = KitBrand.blue { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSBezierPath(rect: bounds).addClip()
        let base = tint.kitResolved(dark: kitDark)
        let gradient = NSGradient(colors: [base.withAlphaComponent(0.22 * base.alphaComponent), base.withAlphaComponent(0)])
        let top = NSPoint(x: bounds.midX, y: 0)
        gradient?.draw(fromCenter: top, radius: 0, toCenter: top, radius: 520, options: [])
    }
}

final class TroublePill: KitBox {
    let label: KitLabel

    init(_ title: String) {
        label = KitLabel(title, font: .systemFont(ofSize: 13, weight: .semibold))
        super.init(frame: .zero)
        corners = .capsule
        label.setAccessibilityElement(false)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 36, height: 32)
    }

    override func layout() {
        super.layout()
        let size = label.intrinsicContentSize
        label.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                     width: size.width, height: size.height))
    }
}

@MainActor
enum TroubleSurface {
    static func make(_ request: [String: Any]) -> NSView {
        let kind = TroubleKind(rawValue: request["kind"] as? String ?? "") ?? .notFound
        let look = (request["space"] as? String).flatMap { SpaceLook.named($0) }
            ?? (request["tint"] as? String).map { SpaceLook(colours: [$0], intensity: SpaceLook.bold) } ?? SpaceLook()
        let view = TroubleView(message: kind.message, host: "example.test", look: look, search: {}, retry: {})
        return NSView.kitFixed(view, width: CGFloat(request["width"] as? Double ?? 720),
                               height: CGFloat(request["height"] as? Double ?? 520))
    }
}

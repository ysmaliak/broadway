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

    func line(waiting: Bool = false) -> String {
        switch self {
        case .notFound: return "Check the spelling, or search for it instead"
        case .offline: return waiting ? "This page will load when your Mac is back online" : "Reconnect, then try again"
        case .slow: return "It might be busy. Try again in a moment."
        case .refused: return "It's there, but it isn't answering right now"
        case .insecure: return "The site couldn't be confirmed, so nothing was sent"
        case .tooLarge: return MemoryWords.line
        case .other: return "Trying again often fixes it"
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

    private(set) var message: String
    private(set) var host: String?
    private(set) var waiting: Bool
    private var kind: TroubleKind { TroubleKind(message: message) }

    private let ground = KitBox(fill: KitColor.ground)
    private let glyph = KitSymbol("exclamationmark.triangle", style: .init(size: 22, weight: .regular), tint: KitColor.muted)
    private let title = KitParagraph("", font: SettingsMetrics.headingFont, color: KitColor.ink, alignment: .center)
    private let line = KitParagraph("", font: SettingsMetrics.titleFont, color: KitColor.muted, alignment: .center, maxWidth: 400)
    private let site = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.muted)
    private lazy var retryButton = KitBroadwayButton("Try Again", kind: .primary) { [weak self] in self?.onRetry() }
    private lazy var searchButton = KitBroadwayButton("Search Instead") { [weak self] in self?.onSearch?() }
    private let stack = NSStackView.kit(.vertical, spacing: 6, alignment: .centerX, [])

    init(message: String, host: String? = nil, waiting: Bool = false,
         search: (() -> Void)? = nil, retry: @escaping () -> Void) {
        self.message = message
        self.host = host
        self.waiting = waiting
        self.onRetry = retry
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(ground)
        site.overflow = .head
        site.alignment = .center
        let buttons = NSStackView.kit(.horizontal, spacing: 8, [searchButton, retryButton])
        for view in [glyph, title, line, site, buttons] { stack.addArrangedSubview(view) }
        stack.setCustomSpacing(12, after: glyph)
        stack.setCustomSpacing(20, after: line)
        stack.setCustomSpacing(20, after: site)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -64),
            title.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            line.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            site.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
        ])
        self.onSearch = search
        show(message: message, host: host, waiting: waiting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(message: String, host: String?, waiting: Bool = false) {
        self.message = message
        self.host = host
        self.waiting = waiting
        glyph.name = kind.symbol
        title.text = message
        line.text = kind.line(waiting: waiting)
        site.text = host ?? ""
        site.isHidden = host?.isEmpty ?? true
        stack.setCustomSpacing(site.isHidden ? 20 : 4, after: line)
        searchButton.isHidden = !(kind == .notFound && onSearch != nil)
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
    }
}

@MainActor
enum TroubleSurface {
    static func make(_ request: [String: Any]) -> NSView {
        let kind = TroubleKind(rawValue: request["kind"] as? String ?? "") ?? .notFound
        let view = TroubleView(message: kind.message, host: request["host"] as? String,
                               waiting: request["waiting"] as? Bool ?? false, search: {}, retry: {})
        return NSView.kitFixed(view, width: CGFloat(request["width"] as? Double ?? 720),
                               height: CGFloat(request["height"] as? Double ?? 520))
    }
}

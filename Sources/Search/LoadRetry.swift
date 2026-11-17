import Foundation
import WebKit

enum LoadFault: Hashable {
    case timedOut, connectionLost, cannotConnect, offline, cannotFindHost, dnsFailed
    case cannotParse, badResponse, untrusted, otherCertificate, secureFailed, cancelled, other

    init(code: Int) {
        switch code {
        case NSURLErrorTimedOut: self = .timedOut
        case NSURLErrorNetworkConnectionLost: self = .connectionLost
        case NSURLErrorCannotConnectToHost: self = .cannotConnect
        case NSURLErrorNotConnectedToInternet: self = .offline
        case NSURLErrorCannotFindHost: self = .cannotFindHost
        case NSURLErrorDNSLookupFailed: self = .dnsFailed
        case NSURLErrorCannotParseResponse: self = .cannotParse
        case NSURLErrorBadServerResponse: self = .badResponse
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot: self = .untrusted
        case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            self = .otherCertificate
        case NSURLErrorSecureConnectionFailed: self = .secureFailed
        case NSURLErrorCancelled: self = .cancelled
        default: self = .other
        }
    }

    init(error: NSError) {
        if error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ECONNREFUSED, EHOSTUNREACH: self = .cannotConnect
            case ETIMEDOUT: self = .timedOut
            case ENETDOWN, ENETUNREACH: self = .offline
            case ECONNRESET, EPIPE: self = .connectionLost
            default: self = .other
            }
            return
        }
        let fault = error.domain == NSURLErrorDomain ? LoadFault(code: error.code) : .other
        if fault == .other, let under = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            self = LoadFault(error: under)
        } else {
            self = fault
        }
    }

    var isCertificate: Bool { self == .untrusted || self == .otherCertificate }
}

struct Detour: Equatable {
    enum Kind: Equatable {
        case otherName, https
    }

    var kind: Kind
    var from: URL
    var to: URL
    var failure: String?
    var waits: URLRequest?
}

enum RetryStep: Equatable {
    case nothing
    case go(URL)
    case showFirst(Detour)
    case showAt(URL)
    case loadAgain(URLRequest)
}

struct LoadRetry {
    var network = NetworkWait()
    private(set) var detour: Detour?
    private(set) var tryAgainAt: URL?
    private(set) var typed: SentAddress?
    private var ours = false

    mutating func heads(_ request: URLRequest, redirect: Bool, returns: Int, sent: SentAddress? = nil) {
        if redirect {
            network.redirected(request)
            return
        }
        if ours {
            ours = false
            typed = nil
        } else {
            network.end()
            detour = nil
            tryAgainAt = nil
            typed = sent
        }
        network.began(request, returns: returns)
    }

    func otherNameDue(for host: String, now: Date = Date()) -> Bool {
        guard detour == nil, let typed, OtherName.due(typed, now: now),
              typed.url.host(percentEncoded: false)?.lowercased() == host.lowercased() else { return false }
        return OtherName.of(typed.url) != nil
    }

    mutating func loadsOwn() {
        ours = true
    }

    mutating func failed(_ fault: LoadFault, at failing: URL?, failure: String?, agent: Bool,
                         returns: Int, available: Bool?, onScreen: Bool, now: Date = Date()) -> RetryStep {
        if let detour {
            self.detour = nil
            let answered = detour.kind == .https ? LocalHTTPS.answered(fault) : fault.isCertificate
            if answered { return .showAt(detour.to) }
            tryAgainAt = detour.from
            if let waits = detour.waits { network.waits(on: waits, returns: returns) }
            return .showFirst(detour)
        }
        guard !agent else { return .nothing }
        let waits = NetworkReturn.waits(fault) ? network.request : nil
        let sent = typed
        typed = nil
        if let sent, OtherName.counts(fault), OtherName.due(sent, now: now),
           OtherName.sameHost(failing ?? sent.url, sent.url), let other = OtherName.of(sent.url) {
            detour = Detour(kind: .otherName, from: sent.url, to: other, failure: failure, waits: waits)
            network.end()
            return .go(other)
        }
        if let failing, network.request != nil, LocalHTTPS.counts(fault), let candidate = LocalHTTPS.candidate(for: failing) {
            detour = Detour(kind: .https, from: failing, to: candidate, failure: failure, waits: waits)
            network.end()
            return .go(candidate)
        }
        let request = network.failed(fault, agent: agent, returns: returns, available: available, onScreen: onScreen)
        return request.map { .loadAgain($0) } ?? .nothing
    }

    mutating func dropDetour() {
        detour = nil
    }

    mutating func tryAgain() -> URL? {
        network.end()
        detour = nil
        typed = nil
        defer { tryAgainAt = nil }
        return tryAgainAt
    }

    @discardableResult
    mutating func committed() -> Detour? {
        network.end()
        tryAgainAt = nil
        typed = nil
        defer { detour = nil }
        return detour
    }
}

@MainActor
enum LoadRetries {
    private static var listening = false

    static func listen() {
        guard !listening else { return }
        listening = true
        NetworkPath.shared.listen { _, returned in
            if returned { cameBack() }
        }
    }

    static func cameBack() {
        for tab in Tab.live.allObjects where tab.retry.network.isWaiting {
            let shown = (tab.delegate as? Browser)?.showsNow(tab) ?? false
            if let request = tab.retry.network.returned(onScreen: shown) {
                tab.loadAgain(request)
            }
        }
    }
}

extension Tab {
    func headsForRetry(_ action: WKNavigationAction) {
        LoadRetries.listen()
        let redirect = action.responds(to: NSSelectorFromString("_isRedirect"))
            && (action.value(forKey: "_isRedirect") as? Bool) == true
        let sent = redirect ? nil : SiteNameBook.claim(action.request.url)
        retry.heads(action.request, redirect: redirect, returns: NetworkPath.shared.returns, sent: sent)
    }

    func retryCommitted() {
        let detour = retry.committed()
        guard let host = built?.url?.host(percentEncoded: false), ["http", "https"].contains(built?.url?.scheme ?? "") else { return }
        SiteNameBook.committed(at: host, after: detour, privately: shy)
    }

    func loadAgain(_ request: URLRequest) {
        guard let built else { return }
        retry.loadsOwn()
        failure = nil
        built.load(request)
    }

    func takeDetour(to url: URL) {
        guard let built else { return }
        retry.loadsOwn()
        failure = nil
        built.load(URLRequest(url: url))
    }

    func showFailure(_ message: String?, at url: URL) {
        hold(url)
        failure = message
    }

    var waitingForNetwork: Bool { retry.network.isWaiting }
}

extension Browser {
    func typedAddress(_ url: URL, picked: Int?, typed text: String) -> URL {
        guard picked == nil, let asked = Address.url(from: text), asked == url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return url }
        let sent = SiteNameBook.sent(url)
        SiteNameBook.pending = SentAddress(url: sent, at: Date())
        return sent
    }

    func showsNow(_ tab: Tab) -> Bool {
        guard tabs.contains(where: { $0 === tab }) else { return false }
        return tab.id == activeID || activeSplit?.contains(tab.id) == true
    }

    func loadFailedBeforeCommit(_ webView: WKWebView, _ error: Error) {
        guard let tab = tab(for: webView), !tab.memoryStopped else { return }
        let nsError = error as NSError
        let fault = LoadFault(error: nsError)
        let handedOver = nsError.domain == "WebKitErrorDomain" && [102, 204].contains(nsError.code)
        guard fault != .cancelled, !handedOver else {
            tab.retry.dropDetour()
            return
        }
        let path = NetworkPath.shared
        let failing = ((error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? tab.retry.network.request?.url
        let failure = tab.failure
        switch tab.retry.failed(fault, at: failing, failure: failure, agent: tab.agent, returns: path.returns,
                                available: path.available, onScreen: showsNow(tab)) {
        case .nothing: break
        case .go(let url): tab.takeDetour(to: url)
        case .showFirst(let detour): tab.showFailure(detour.failure ?? failure, at: detour.from)
        case .showAt(let url): tab.showFailure(failure, at: url)
        case .loadAgain(let request): tab.loadAgain(request)
        }
    }

    func loadOwedOnScreen() {
        for tab in tabs where showsNow(tab) {
            if let request = tab.retry.network.cameForward() { tab.loadAgain(request) }
        }
    }
}

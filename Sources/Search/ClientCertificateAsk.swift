import AppKit
import CryptoKit
import Foundation
import Security
import SecurityInterface
import WebKit

protocol IdentitySource: AnyObject {
    func identities() -> [SecIdentity]
}

final class KeychainIdentities: IdentitySource {
    func identities() -> [SecIdentity] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let list = found as? [Any] else { return [] }
        return list.map { $0 as! SecIdentity }
    }
}

final class HeldIdentities: IdentitySource {
    var held: [SecIdentity] = []

    func identities() -> [SecIdentity] { held }

    func load(_ data: Data, password: String) -> Bool {
        let options: [CFString: Any] = [kSecImportExportPassphrase: password, kSecImportToMemoryOnly: true]
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let list = items as? [[CFString: Any]] else { return false }
        let found = list.compactMap { $0[kSecImportItemIdentity].map { $0 as! SecIdentity } }
        held += found
        return !found.isEmpty
    }
}

@MainActor
enum ClientCertificateAsk {
    enum TestAnswer: String {
        case cancel, first
    }

    static var answers = ClientCertificates()
    static var source: IdentitySource = Store.testing ? HeldIdentities() : KeychainIdentities()
    static var answerInTest = TestAnswer.cancel

    private struct Asking {
        weak var webView: WKWebView?
        weak var browser: Browser?
        var tabID: UUID
        var identities: [SecIdentity]
    }

    private static var asking: [ClientEndpoint: Asking] = [:]
    private static var delegate: SheetEnd?

    static func message(_ host: String) -> String {
        "\u{201C}\(host)\u{201D} asks for a certificate that identifies you"
    }

    static func candidate(_ identity: SecIdentity) -> ClientCandidate? {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        let data = SecCertificateCopyData(certificate) as Data
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ClientCandidate(der: data, id: id, name: SecCertificateCopySubjectSummary(certificate) as String?)
    }

    static func handle(
        _ browser: Browser,
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let host = CertificateExceptions.normal(space.host)
        let tab = browser.tab(for: webView)
        let pageHost = tab.flatMap { ($0.address?.host() ?? $0.pending?.host()).map(CertificateExceptions.normal) }
        let onScreen = tab.map { $0.id == browser.activeID || browser.activeSplit?.contains($0.id) == true } ?? false
        let isPage = tab != nil && pageHost == host
        let agent = tab?.agent == true
        let identities = isPage && !agent ? source.identities() : []
        var byID: [String: SecIdentity] = [:]
        var candidates: [ClientCandidate] = []
        for identity in identities {
            guard let candidate = candidate(identity) else { continue }
            byID[candidate.id] = identity
            candidates.append(candidate)
        }
        let fitting = ClientCertificates.fitting(candidates, asked: space.distinguishedNames ?? [], at: Date())
        let endpoint = ClientEndpoint(holder: CertificateTrust.holder(for: webView.configuration.websiteDataStore), host: host, port: space.port)
        let request = ClientCertificates.Request(
            endpoint: endpoint,
            isPage: isPage,
            onScreen: onScreen,
            agent: agent,
            fitting: fitting
        )
        let step = answers.request(request) { reply in
            switch reply {
            case .none:
                completionHandler(.performDefaultHandling, nil)
            case .use(let id):
                guard let identity = byID[id] else {
                    completionHandler(.performDefaultHandling, nil)
                    return
                }
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .none))
            }
        }
        guard case .queued(let showNow) = step, let tab else { return }
        let fits = Set(fitting.map(\.id))
        asking[endpoint] = Asking(webView: webView, browser: browser, tabID: tab.id,
                                  identities: identities.filter { candidate($0).map { fits.contains($0.id) } ?? false })
        if showNow { DispatchQueue.main.async { show(endpoint) } }
    }

    private static func show(_ endpoint: ClientEndpoint) {
        guard let asking = asking[endpoint], let webView = asking.webView, let window = webView.window,
              let browser = asking.browser, browser.tab(for: webView)?.id == asking.tabID, !asking.identities.isEmpty,
              asking.tabID == browser.activeID || browser.activeSplit?.contains(asking.tabID) == true
        else {
            finish(endpoint, nil)
            return
        }
        let text = message(endpoint.host)
        if Store.testing {
            Dialogs.askedInTest.append(text)
            let choice: ClientChoice = answerInTest == .first ? held(asking.identities.first) : .refused
            finish(endpoint, choice)
            return
        }
        guard let panel = SFChooseIdentityPanel.shared() else {
            finish(endpoint, nil)
            return
        }
        panel.setDefaultButtonTitle("Continue")
        panel.setAlternateButtonTitle("Cancel")
        let end = SheetEnd { ok in
            finish(endpoint, ok ? held(panel.identity()?.takeUnretainedValue()) : .refused)
        }
        delegate = end
        panel.beginSheet(for: window, modalDelegate: end, didEnd: #selector(SheetEnd.sheetDidEnd(_:returnCode:contextInfo:)),
                         contextInfo: nil, identities: asking.identities, message: text)
    }

    private static func held(_ identity: SecIdentity?) -> ClientChoice {
        guard let identity, let id = candidate(identity)?.id else { return .refused }
        return .identity(id)
    }

    private static func finish(_ endpoint: ClientEndpoint, _ choice: ClientChoice?) {
        asking[endpoint] = nil
        delegate = nil
        let next = choice.map { answers.answer(endpoint, with: $0) } ?? answers.abandon(endpoint)
        if let next { DispatchQueue.main.async { show(next) } }
    }

    final class SheetEnd: NSObject {
        let done: (Bool) -> Void

        init(_ done: @escaping (Bool) -> Void) {
            self.done = done
        }

        @objc func sheetDidEnd(_ sheet: NSWindow, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
            let ok = returnCode == NSApplication.ModalResponse.OK.rawValue
            DispatchQueue.main.async { MainActor.assumeIsolated { self.done(ok) } }
        }
    }
}

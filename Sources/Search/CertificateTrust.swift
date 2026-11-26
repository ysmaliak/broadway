import CryptoKit
import Foundation
import ObjectiveC
import Security
import WebKit

@MainActor
enum CertificateTrust {
    enum Outcome: Equatable {
        case system
        case pass
        case refuse
    }

    static var book = CertificateExceptions(folder: Store.folder)

    private static var tokenKey: UInt8 = 0

    private final class Token {
        let id = UUID()

        deinit {
            let id = id
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    CertificateTrust.book.drop(passing: id)
                    ClientCertificateAsk.answers.forget(.passing(id))
                    SiteFileAsk.shared.forget(.passing(id))
                }
            }
        }
    }

    static func holder(for store: WKWebsiteDataStore) -> CertificateHolder {
        guard store.isPersistent else {
            if let token = objc_getAssociatedObject(store, &tokenKey) as? Token { return .passing(token.id) }
            let token = Token()
            objc_setAssociatedObject(store, &tokenKey, token, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return .passing(token.id)
        }
        guard let id = store.identifier, id != Store.websites.identifier else { return .space(Space.firstID) }
        return .space(id)
    }

    nonisolated static func chain(of trust: SecTrust) -> [String] {
        let certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        return certificates.map { certificate in
            let data = SecCertificateCopyData(certificate) as Data
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    static func answer(
        store: WKWebsiteDataStore,
        host: String,
        port: Int,
        chain: [String],
        trusted: Bool,
        isPage: Bool,
        otherNameDue: Bool = false,
        ask: (@escaping (Bool) -> Void) -> Void,
        done: @escaping (Outcome) -> Void
    ) {
        if trusted {
            done(.system)
            return
        }
        let host = CertificateExceptions.normal(host)
        if Hosts.isLoopback(host, subdomains: false) {
            done(.pass)
            return
        }
        let holder = holder(for: store)
        if book.covers(holder, host: host, port: port, chain: chain) {
            done(.pass)
            return
        }
        guard isPage, !chain.isEmpty, !otherNameDue else {
            done(.system)
            return
        }
        ask { goOn in
            guard goOn else {
                done(.refuse)
                return
            }
            CertificateTrust.book.excuse(holder, host: host, port: port, chain: chain)
            done(.pass)
        }
    }

    static func clearEverything() {
        book.clearEverything()
        ClientCertificateAsk.answers.clearEverything()
    }

    static func clear(_ site: String, in store: WKWebsiteDataStore) {
        clear(in: store) { SiteClearing.belongs($0, to: site) }
    }

    static func clear(in store: WKWebsiteDataStore, where belongs: (String) -> Bool) {
        let holder = holder(for: store)
        book.clear(holder, where: belongs)
        ClientCertificateAsk.answers.clear(holder, where: belongs)
    }

    static func forget(space: UUID) {
        book.forget(space: space)
        ClientCertificateAsk.answers.forget(.space(space))
        SiteFileAsk.shared.forget(.space(space))
    }
}

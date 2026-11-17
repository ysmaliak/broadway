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
            DispatchQueue.main.async { MainActor.assumeIsolated { CertificateTrust.book.drop(passing: id) } }
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
        ask: (@escaping (Bool) -> Void) -> Void,
        done: @escaping (Outcome) -> Void
    ) {
        if trusted {
            done(.system)
            return
        }
        let host = CertificateExceptions.normal(host)
        if Dialogs.isLoopback(host) {
            done(.pass)
            return
        }
        let holder = holder(for: store)
        if book.covers(holder, host: host, port: port, chain: chain) {
            done(.pass)
            return
        }
        guard isPage, !chain.isEmpty else {
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
    }

    static func clear(_ site: String, in store: WKWebsiteDataStore) {
        book.clear(holder(for: store)) { SiteClearing.belongs($0, to: site) }
    }

    static func forget(space: UUID) {
        book.forget(space: space)
    }
}

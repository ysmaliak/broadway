import CryptoKit
import Foundation

struct SentSignIn: Equatable, Sendable {
    let host: String
    let user: String
    let password: String
    var port: Int? = nil

    static func port(of page: URL?) -> Int? {
        guard let page, let port = page.port else { return nil }
        return port == AgentSignInMatch.defaultPort(page.scheme) ? nil : port
    }
}

struct FillMark {
    let host: String
    let user: String
    private let key = SymmetricKey(size: .bits256)
    private let mark: Data

    init(host: String, user: String, password: String) {
        self.host = host
        self.user = user
        mark = Data(HMAC<SHA256>.authenticationCode(for: Data(password.utf8), using: key))
    }

    func covers(_ host: String, registrable: (String) -> String = Vault.registrable) -> Bool {
        SavedAlready.sameSite(host, self.host, registrable: registrable)
    }

    func matches(host: String, user: String, password: String,
                 registrable: (String) -> String = Vault.registrable) -> Bool {
        guard user.isEmpty || user == self.user, covers(host, registrable: registrable) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mark, authenticating: Data(password.utf8), using: key)
    }
}

enum SavedAlready {
    static let namelessReads = 3

    enum Verdict: Equatable {
        case marked
        case kept(Kept)
        case offer(changed: Bool)
    }

    static func sameSite(_ one: String, _ other: String, registrable: (String) -> String) -> Bool {
        let one = bare(one), other = bare(other)
        return one == other || registrable(one) == registrable(other)
    }

    private static func bare(_ host: String) -> String {
        let host = host.lowercased()
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func marked(_ sent: SentSignIn, by marks: [FillMark?],
                       registrable: (String) -> String = Vault.registrable) -> Bool {
        marks.contains { $0?.matches(host: sent.host, user: sent.user, password: sent.password, registrable: registrable) == true }
    }

    static func reads(_ sent: SentSignIn, kept: [Kept], registrable: (String) -> String = Vault.registrable) -> [Kept] {
        let page = kept
            .filter { sameSite($0.host, sent.host, registrable: registrable) && ($0.port == nil || $0.port == sent.port) }
            .sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
        guard sent.user.isEmpty else {
            let named = page.filter { $0.user == sent.user }
            return named.filter { $0.host == sent.host } + named.filter { $0.host != sent.host }
        }
        let first = page.filter { $0.host == sent.host && $0.user.isEmpty }
        let rest = page.filter { !($0.host == sent.host && $0.user.isEmpty) }
        return Array((first + rest).prefix(namelessReads))
    }

    static func touched(_ kept: Kept, by sent: SentSignIn, clear: Bool) -> Login {
        let same = kept.host == sent.host && kept.user == sent.user
        return Login(host: kept.host, user: kept.user, password: sent.password, used: kept.used, clear: same ? clear : kept.clear, port: kept.port)
    }

    static func login(for sent: SentSignIn, clear: Bool) -> Login {
        Login(host: sent.host, user: sent.user, password: sent.password, used: nil, clear: clear, port: sent.port)
    }

    static func verdict(_ sent: SentSignIn, marks: [FillMark?], registrable: (String) -> String = Vault.registrable,
                        kept: () -> [Kept], read: (Kept) -> String?) -> Verdict {
        if marked(sent, by: marks, registrable: registrable) { return .marked }
        return verdict(sent, kept: kept(), registrable: registrable, read: read)
    }

    static func verdict(_ sent: SentSignIn, kept: [Kept], registrable: (String) -> String = Vault.registrable,
                        read: (Kept) -> String?) -> Verdict {
        for one in reads(sent, kept: kept, registrable: registrable) where read(one) == sent.password {
            return .kept(one)
        }
        return .offer(changed: kept.contains { $0.host == sent.host && $0.user == sent.user && $0.port == sent.port })
    }
}

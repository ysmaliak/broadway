import Foundation
import Security

enum StrongPassword {
    static let small = Array("abcdefghijkmnopqrstuvwxyz")
    static let capital = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    static let digits = Array("23456789")
    static let alphabet = small + capital + digits
    static let length = 20
    static let shortest = 8

    static func secure(below bound: Int) -> Int {
        let limit = UInt32.max - UInt32.max % UInt32(bound)
        while true {
            var value: UInt32 = 0
            let status = withUnsafeMutableBytes(of: &value) { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            guard status == errSecSuccess else { continue }
            if value < limit { return Int(value % UInt32(bound)) }
        }
    }

    static func make(maxLength: Int? = nil, random: (Int) -> Int = secure(below:)) -> String? {
        let limit = maxLength.flatMap { $0 > 0 ? $0 : nil } ?? length
        if limit < shortest { return nil }
        let grouped = limit >= length
        let count = grouped ? 18 : limit
        while true {
            let drawn = (0..<count).map { _ in alphabet[random(alphabet.count)] }
            guard drawn.contains(where: small.contains), drawn.contains(where: capital.contains), drawn.contains(where: digits.contains)
            else { continue }
            guard grouped else { return String(drawn) }
            return [drawn[0..<6], drawn[6..<12], drawn[12..<18]].map { String($0) }.joined(separator: "-")
        }
    }
}

struct StrongPasswordAsk: Equatable {
    var fresh: Int?
    var mainFrame = true
    var shy = false
    var agent = false
    var extensionPage = false
    var never = false
}

struct StrongPasswordKeeping: Equatable {
    var saves = true
    var applePasswords = false
    var savingTakenByExtension = false
}

enum StrongPasswordRule {
    static func offers(_ ask: StrongPasswordAsk, _ keeping: StrongPasswordKeeping) -> Int? {
        guard let fresh = ask.fresh, ask.mainFrame, !ask.shy, !ask.agent, !ask.extensionPage, !ask.never,
              keeping.saves, !keeping.applePasswords, !keeping.savingTakenByExtension
        else { return nil }
        let limit = fresh > 0 ? fresh : StrongPassword.length
        return limit < StrongPassword.shortest ? nil : limit
    }

    static func password(for limit: Int?, random: (Int) -> Int = StrongPassword.secure(below:)) -> String? {
        limit.flatMap { StrongPassword.make(maxLength: $0, random: random) }
    }
}

struct StrongTaken {
    let host: String
    let user: String
    let clear: Bool
    let mark: FillMark

    init(host: String, user: String, password: String, clear: Bool) {
        self.host = host
        self.user = user
        self.clear = clear
        mark = FillMark(host: host, user: user, password: password)
    }

    func sent(host: String, password: String) -> Bool {
        mark.matches(host: host, user: "", password: password)
    }

    enum Settle: Equatable {
        case kept
        case renamed(from: String, to: String)
    }

    func settle(sentUser: String) -> Settle {
        let named = sentUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !named.isEmpty, named != user else { return .kept }
        return .renamed(from: user, to: named)
    }
}

enum StrongPasswordKeep {
    static func rename(host: String, from: String, to: String, password: String, clear: Bool,
                       save: (String, String, String, Bool) -> Bool = { Vault.save(host: $0, user: $1, password: $2, used: Date(), clear: $3) },
                       forget: (String, String) -> Void = { Vault.forget(host: $0, user: $1) }) -> String {
        guard save(host, to, password, clear) else { return from }
        forget(host, from)
        return to
    }
}

extension Tab {
    func fillStrong(_ password: String, onlyOn page: URL?, done: @escaping @MainActor (String?) -> Void) {
        seal(password)
        guard let scheme = page?.scheme?.lowercased(), let host = page?.host()?.lowercased() else { return done(nil) }
        func quoted(_ text: String) -> String {
            (try? JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed)).flatMap { String(data: $0, encoding: .utf8) } ?? "''"
        }
        let script = "(location.protocol === \(quoted(scheme + ":")) && location.hostname.toLowerCase() === \(quoted(host)) && window.__officeForms)"
            + " ? window.__officeForms.strong(\(quoted(password))) : null"
        web.evaluateInSearch(script) { result in
            let user = (result as? [String: Any]).map { $0["user"] as? String ?? "" }
            MainActor.assumeIsolated { done(user) }
        }
    }
}

extension Browser {
    func strongPassword(for tab: Tab, now: Suggesting?) -> String? {
        let host = tab.pageAddress?.host()?.lowercased() ?? ""
        let ask = StrongPasswordAsk(fresh: tab.freshField, mainFrame: tab.fieldFrameHost == nil, shy: tab.shy, agent: tab.agent,
                                    extensionPage: tab.address.flatMap(Browser.extensionHost(of:)) != nil,
                                    never: host.isEmpty || Vault.isNever(host))
        let keeping = StrongPasswordKeeping(saves: prefs.savesPasswords, applePasswords: prefs.applePasswords,
                                            savingTakenByExtension: Extensions.shared.passwordSavingTakenBy != nil)
        guard let limit = StrongPasswordRule.offers(ask, keeping) else { return nil }
        if let now, now.tab == tab.id, let shown = now.strong, shown.count == min(limit, StrongPassword.length) { return shown }
        return StrongPassword.make(maxLength: limit)
    }

    func takeStrongPassword(_ password: String, in tab: Tab, host: String, clear: Bool) {
        tab.fillStrong(password, onlyOn: tab.pageAddress) { [weak self, weak tab] user in
            guard let self, let tab else { return }
            guard let user else { return announce("The sign-in fields are gone") }
            tab.strongTaken = StrongTaken(host: host, user: user, password: password, clear: clear)
            Task { [weak self, weak tab] in
                let saved = await Vault.off { Vault.save(host: host, user: user, password: password, used: Date(), clear: clear) }
                guard let self else { return }
                guard saved else {
                    tab?.strongTaken = nil
                    return announce("The keychain refused it")
                }
                relist()
                announce("Password saved for \(host)")
            }
        }
    }

    func strongPasswordSent(_ tab: Tab, host: String, user: String, password: String) -> Bool {
        guard let taken = tab.strongTaken, taken.sent(host: host, password: password) else { return false }
        tab.strongTaken = nil
        guard case .renamed(let from, let to) = taken.settle(sentUser: user) else { return true }
        let keptHost = taken.host, clear = taken.clear
        Task { [weak self] in
            await Vault.off {
                _ = StrongPasswordKeep.rename(host: keptHost, from: from, to: to, password: password, clear: clear)
            }
            self?.relist()
        }
        return true
    }
}

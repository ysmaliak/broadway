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
}

struct StrongTaken {
    let host: String
    let user: String
    let clear: Bool
    let saved: Bool
    let mark: FillMark

    init(host: String, user: String, password: String, clear: Bool, saved: Bool) {
        self.host = host
        self.user = user
        self.clear = clear
        self.saved = saved
        mark = FillMark(host: host, user: user, password: password)
    }

    func sent(host: String, password: String) -> Bool {
        mark.matches(host: host, user: "", password: password)
    }
}

enum StrongPasswordKeep {
    typealias Save = (String, String, String, Bool) -> Bool
    typealias Forget = (String, String) -> Void

    enum Take: Equatable {
        case kept
        case waits
        case refused
    }

    static func inVault(_ host: String, _ user: String, _ password: String, _ clear: Bool) -> Bool {
        Vault.save(host: host, user: user, password: password, used: Date(), clear: clear)
    }

    static func outOfVault(_ host: String, _ user: String) { Vault.forget(host: host, user: user) }

    static func take(host: String, user: String, password: String, clear: Bool, kept: [Kept],
                     registrable: (String) -> String = Vault.registrable, save: Save = inVault) -> Take {
        if kept.contains(where: { $0.user == user && SavedAlready.sameSite($0.host, host, registrable: registrable) }) { return .waits }
        return save(host, user, password, clear) ? .kept : .refused
    }

    static func sent(host: String, keptUser: String, saved: Bool, sentUser: String, password: String, clear: Bool,
                     save: Save = inVault, forget: Forget = outOfVault) -> String? {
        let named = sentUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = named.isEmpty ? keptUser : named
        guard saved else { return save(host, name, password, clear) ? name : nil }
        guard name != keptUser, save(host, name, password, clear) else { return nil }
        forget(host, keptUser)
        return name
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
        let ask = StrongPasswordAsk(fresh: tab.freshField, mainFrame: tab.fieldFrameHost == nil, shy: tab.shy, agent: tab.agent || tab.agentHere,
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
            Task { [weak self, weak tab] in
                let took = await Vault.off {
                    StrongPasswordKeep.take(host: host, user: user, password: password, clear: clear, kept: Vault.kept(matching: host, wide: true))
                }
                guard let self, let tab else { return }
                switch took {
                case .refused:
                    announce("The keychain refused it")
                case .waits:
                    tab.strongTaken = StrongTaken(host: host, user: user, password: password, clear: clear, saved: false)
                case .kept:
                    tab.strongTaken = StrongTaken(host: host, user: user, password: password, clear: clear, saved: true)
                    relist()
                    announce("Password saved for \(host)")
                }
            }
        }
    }

    func strongPasswordSent(_ tab: Tab, host: String, user: String, password: String) -> Bool {
        guard let taken = tab.strongTaken, taken.sent(host: host, password: password) else { return false }
        tab.strongTaken = nil
        let keptHost = taken.host, keptUser = taken.user, saved = taken.saved, clear = taken.clear
        Task { [weak self] in
            let named = await Vault.off {
                StrongPasswordKeep.sent(host: keptHost, keptUser: keptUser, saved: saved, sentUser: user, password: password, clear: clear)
            }
            guard let self, named != nil else { return }
            relist()
            if !saved { announce("Password saved for \(keptHost)") }
        }
        return true
    }
}

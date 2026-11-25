import BroadwayCLI
import Foundation

@MainActor
enum PersonGive {
    static let name = "logins give"
    static let carriedKey = "over_ssh"
    nonisolated static let place = "Settings › Agents › Let agents ask for a saved password"
    static let typeIt = "Ask the person to type the password where it is wanted"

    static let off = PersonRefusal("person_only", "Handing a saved password to a program is off in Broadway. Nothing was given.",
                                   hint: "The person can turn it on in \(place)")
    static let away = PersonRefusal("person_only", "Only on the Mac that runs Broadway, never over ssh. Nothing was given.", hint: typeIt)
    static let notHere = PersonRefusal("refused", "logins give works only as a command in a terminal on the Mac that runs Broadway, never over MCP. Nothing was given.",
                                       hint: "Run broadway logins give SITE --password-only in a shell")
    static let badSite = PersonRefusal.usage("logins give needs a site, such as appleid.apple.com or https://github.com", hint: "broadway logins give appleid.apple.com --password-only")

    static let mcpWords: Set<String> = ["password", "passwords", "login", "logins", "give", "credential", "credentials"]
    nonisolated static let mcpNames: Set<String> = ["logins_give"]
    nonisolated static let mcpLine = "A saved password is never given over MCP, since the answer would land in your context. In a terminal on the Mac that runs Broadway, broadway logins give SITE --password-only hands one to a program after the person's yes and Touch ID, once they turn it on in \(place)."

    static let verb = PersonVerb("logins", "give", .tool, first: { try check($0) }) { try await run($0) }

    static func check(_ call: PersonCall) throws {
        if remote(call) { throw away }
        guard call.request["op"] as? String == "do" else { throw notHere }
        guard call.browser.prefs.agentsGivePasswords else { throw off }
    }

    static func remote(_ call: PersonCall) -> Bool {
        remote(call.request) || call.link?.remote == true
    }

    static func remote(_ request: [String: Any]) -> Bool {
        let said = request["agent"] as? [String: Any] ?? [:]
        if said["remote"] as? Bool == true { return true }
        if (said["id"] as? String)?.lowercased().hasPrefix("ssh:") == true { return true }
        return request[carriedKey] as? Bool == true
    }

    static func creates(_ request: [String: Any], on: Bool) -> Bool {
        on && asks(request) && !remote(request)
    }

    static func asks(_ request: [String: Any]) -> Bool {
        request["noun"] as? String == "logins" && request["verb"] as? String == "give"
    }

    static func stamp(_ request: [String: Any], peer: Int32) -> [String: Any] {
        guard asks(request) else { return request }
        var out = request
        out[carriedKey] = carried(peer)
        return out
    }

    nonisolated static func carried(_ peer: Int32, lookup: (Int32) -> AgentAncestor.Process? = AgentAncestor.process) -> Bool {
        var at = peer
        var seen: Set<Int32> = []
        while at > 1, seen.insert(at).inserted, let found = lookup(at) {
            let name = found.name.lowercased()
            if AgentAncestor.carrier(name) || name.hasPrefix("mosh-server") { return true }
            at = found.parent
        }
        return false
    }

    static func site(_ text: String?) throws -> String {
        guard let text, !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw badSite }
        let host = Vault.host(of: text)
        guard !host.isEmpty, host.count <= 120, host.contains(".") || host == "localhost",
              host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { throw badSite }
        return host
    }

    static func agentName(_ call: PersonCall) -> String {
        if let name = call.link?.name, !name.isEmpty { return name }
        let said = call.request["agent"] as? [String: Any] ?? [:]
        if let name = AgentLinks.clean(said["name"] as? String) { return name }
        return "A program"
    }

    static func run(_ call: PersonCall) async throws -> [String: Any] {
        let host = try site(call.string("site"))
        let rule = AgentSites.site(of: URL(string: "https://" + host)) ?? host
        if AgentSites.shared.rule(for: rule) == .never {
            throw PersonRefusal("never_here", "The person never lets agents act on \(host). Leave it.")
        }
        let account = call.string("account")
        let kept = await offered(call.box.logins(host), host: host)
        let named = account.map { name in kept.filter { $0.user == name } } ?? kept
        let agent = agentName(call)
        await signed(call.link)
        let title = "Give \(agent == "A program" ? "a program" : agent) the password for \(host)?"
        var question = AgentQuestion(kind: named.count > 1 ? .choice(named.map { label($0, host: host) }) : .approval(.grant), title: AgentQuestion.clean(title, limit: 200))
        question.offersAlways = false
        question.signs = true
        switch named.count {
        case 0:
            question.line = account.map { "Broadway keeps no password for \($0) on \(host)" } ?? "Broadway keeps no password for \(host)"
            question.yesWord = "OK"
        case 1:
            question.line = "It will be able to read the password of \(label(named[0], host: host))"
            question.yesWord = "Give Password"
        default:
            question.line = "It will be able to read the password you pick"
        }
        let chosen: Kept?
        switch try await PersonAsk.put(question, call: call) {
        case .yes, .always:
            chosen = named.count == 1 ? named[0] : nil
        case .picked(let index):
            guard named.count > 1, named.indices.contains(index) else { throw PersonAsk.saidNo }
            chosen = named[index]
        case .no, .never:
            throw PersonAsk.saidNo
        case .dropped:
            throw PersonAsk.unanswered
        }
        guard let chosen else {
            throw PersonRefusal("nothing_kept", "Broadway keeps no password for \(host), so nothing was given", hint: typeIt)
        }
        guard await proven(call, agent: agent, host: host) else {
            throw PersonRefusal("said_no", "The person didn't confirm with Touch ID. Nothing was given.")
        }
        guard let login = await call.box.loginSecret(chosen) else { throw PersonRefusal("failed", "The keychain refused it. Nothing was given.") }
        let link = call.link
        let used = AgentUse(agent: agent, folder: link?.folder.map { ($0 as NSString).lastPathComponent }, at: Date(), given: true)
        _ = await Vault.off { Vault.note(used, on: chosen) }
        return ["user": login.user, "password": login.password, "site": AgentSignInMatch.bare(chosen.host),
                "message": "Broadway gave the password for \(host). Whatever reads this output can read it."]
    }

    static func offered(_ all: [Kept], host: String) -> [Kept] {
        let exact = all.filter { AgentSignInMatch.bare($0.host) == host }
        let site = Vault.registrable(host)
        let pool = exact.isEmpty ? all.filter { Vault.registrable(AgentSignInMatch.bare($0.host)) == site } : exact
        var seen = Set<String>()
        return pool.filter { seen.insert(AgentSignInMatch.bare($0.host) + "\u{1}" + $0.user).inserted }
    }

    static func label(_ kept: Kept, host: String) -> String {
        let own = AgentSignInMatch.bare(kept.host)
        return own == host ? kept.user : "\(kept.user) on \(own)"
    }

    static func signed(_ link: AgentLink?) async {
        guard let id = link?.id else { return }
        for _ in 0..<20 {
            guard let now = AgentLinks.shared.link(id), !now.remote, now.program == nil, now.process != nil else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    static func proven(_ call: PersonCall, agent: String, host: String) async -> Bool {
        await withCheckedContinuation { done in
            call.box.book.prove("give \(agent == "A program" ? "a program" : agent) the password for \(host)") { done.resume(returning: $0) }
        }
    }
}

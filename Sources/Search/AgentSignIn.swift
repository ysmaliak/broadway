import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class AgentSignIns {
    static let shared = AgentSignIns(file: Store.file("agent-sign-ins.json"))

    private(set) var allowed: [String: [String]] = [:]
    @ObservationIgnored private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let read = try? JSONDecoder().decode([String: [String]].self, from: data) {
            allowed = read
        }
    }

    nonisolated static func digest(_ user: String, site: String) -> String {
        SHA256.hash(data: Data((site + "\u{1}" + user).utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    var sites: [String] { allowed.keys.sorted() }

    func covers(_ user: String, site: String) -> Bool {
        allowed[site]?.contains(Self.digest(user, site: site)) == true
    }

    func allow(_ user: String, site: String) {
        let key = Self.digest(user, site: site)
        guard allowed[site]?.contains(key) != true else { return }
        allowed[site, default: []].append(key)
        save()
    }

    func remove(_ digest: String, site: String) {
        allowed[site]?.removeAll { $0 == digest }
        if allowed[site]?.isEmpty == true { allowed[site] = nil }
        save()
    }

    func remove(site: String) {
        allowed[site] = nil
        save()
    }

    func reset() {
        allowed = [:]
        save()
    }

    private func save() {
        let snapshot = allowed
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }
}

@MainActor
enum AgentSignInNames {
    static var all: () -> [Kept] = { Vault.all() }

    static func names(for allowed: [String: [String]]) -> [String: String] {
        guard !allowed.isEmpty else { return [:] }
        var found: [String: String] = [:]
        for kept in all() {
            let site = AgentSites.site(of: URL(string: "https://" + kept.host)) ?? kept.host
            guard let wanted = allowed[site] else { continue }
            let digest = AgentSignIns.digest(kept.user, site: site)
            if wanted.contains(digest) { found[digest] = kept.user }
        }
        return found
    }
}

enum AgentSignInMatch {
    static func bare(_ host: String) -> String {
        let low = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return low.hasPrefix("www.") ? String(low.dropFirst(4)) : low
    }

    static func loopback(_ host: String) -> Bool {
        let low = bare(host)
        return low == "localhost" || low == "127.0.0.1" || low == "::1" || low.hasSuffix(".localhost")
    }

    static func defaultPort(_ scheme: String?) -> Int {
        scheme?.lowercased() == "http" ? 80 : 443
    }

    static func fits(_ kept: Kept, page: URL) -> Bool {
        guard let host = page.host(), !host.isEmpty, bare(kept.host) == bare(host) else { return false }
        let scheme = page.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && kept.clear) else { return false }
        return portFits(kept, page: page)
    }

    static func portFits(_ kept: Kept, page: URL) -> Bool {
        let scheme = page.scheme?.lowercased()
        if kept.port == nil, loopback(page.host() ?? "") { return true }
        let wanted = page.port ?? defaultPort(scheme)
        let held = kept.port ?? defaultPort(scheme)
        return wanted == held
    }
}

enum AgentSignInState: String {
    case signedIn = "signed_in"
    case password, code, captcha, passkey, unsent, moved

    func words(_ user: String, host: String) -> String {
        let filled = "Filled as \(user)"
        switch self {
        case .signedIn: return "\(filled) and sent it. The page no longer asks for a password, so the sign-in looks done."
        case .password: return "\(filled) and sent it. The page still asks for the password, so it may be wrong. Look at the page, or run broadway handoff \"Sign in\"."
        case .code: return "\(filled) and sent it. The page now asks for a one-time code, so run broadway fill code. For a code sent by text or an app, run broadway handoff \"Type the code you were sent\"."
        case .captcha: return "\(filled) and sent it. The page now shows a captcha, so run broadway handoff \"Solve the captcha\"."
        case .passkey: return "\(filled) and sent it. The page now asks for a passkey, so run broadway handoff \"Use your passkey\"."
        case .unsent: return "\(filled). Broadway found no button to send it, so look at the page and send it yourself."
        case .moved: return "\(filled) on the first step. The next step is on \(host), where this sign-in is not kept, so nothing more was filled."
        }
    }
}

@MainActor
enum PersonSignIn {
    static let handHint = "The person can sign in themselves. broadway handoff gives them the tab."
    static let onePasswordHint = "If 1Password asked for Touch ID, run broadway fill login again once it is unlocked. The person can also sign in themselves: broadway handoff gives them the tab."

    static func bare(_ sentence: String) -> String {
        sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }

    static func onePasswordRefusal(_ why: String, locked: Bool) -> PersonRefusal {
        PersonRefusal("failed", "1Password didn't hand the password over, so nothing was filled. \(bare(why)).",
                      hint: locked ? onePasswordHint : handHint)
    }

    static func label(_ kept: Kept, marked: Bool) -> String {
        let name = kept.user.isEmpty ? "No name" : kept.user
        guard marked else { return kept.user }
        return name + (kept.item != nil ? " · 1Password" : " · Broadway")
    }

    static func run(_ call: PersonCall) async throws -> [String: Any] {
        let tab = try call.page.tab
        guard !tab.asleep, tab.isWeb else { throw PersonRefusal("not_a_page", "That tab isn't showing a web page") }
        guard let place = tab.pageAddress, let host = place.host()?.lowercased(), !host.isEmpty else {
            throw PersonRefusal("refused", "That page has no site to sign in to")
        }
        let site = AgentSites.site(of: place) ?? host
        if AgentSites.shared.rule(for: site) == .never {
            throw PersonRefusal("never_here", "The person never lets agents act on \(site). Leave it.")
        }
        let account = call.string("account")
        let prefs = call.browser.prefs
        let found = await call.box.signInAccounts(for: place, onePassword: prefs.onePassword)
        let missedHint = found.late ? onePasswordHint : handHint
        let named = account.map { name in found.kept.filter { $0.user == name } } ?? found.kept
        let mode = prefs.agentMode
        let always = prefs.agentsAskSignIn
        if !always, named.count == 1, mode == .bypass || (mode == .auto && named[0].item == nil && AgentSignIns.shared.covers(named[0].user, site: site)) {
            return try await signIn(call, tab: tab, kept: named[0], place: place, told: true)
        }
        if !always, mode == .bypass, named.isEmpty {
            let what = account.map { "Broadway keeps no sign-in as \($0) for this site" } ?? "Broadway keeps no sign-in for this site"
            guard let missed = found.missed else { throw PersonRefusal("nothing_kept", "\(what), so nothing was filled", hint: handHint) }
            throw PersonRefusal("nothing_kept", "\(what). \(Self.bare(missed)). Nothing was filled.", hint: missedHint)
        }
        let marked = named.contains { $0.item != nil }
        var question = AgentQuestion(kind: named.count > 1 ? .choice(named.map { Self.label($0, marked: marked) }) : .approval(.signIn),
                                     title: AgentAct.signIn.question(on: site))
        question.site = site
        switch named.count {
        case 0:
            let keeper = prefs.onePassword && found.missed == nil ? "Broadway and 1Password have" : "Broadway has"
            question.line = account.map { "\(keeper) no saved sign-in as \($0) on \(site)" } ?? "\(keeper) no saved sign-in on \(site)"
            question.yesWord = "Sign In Myself"
            question.offersAlways = false
        case 1:
            question.line = "As \(named[0].user)" + (named[0].item != nil ? ", from 1Password" : "")
            question.offersAlways = mode == .auto && !always && named[0].item == nil
        default:
            question.line = "Choose an account"
        }
        if let missed = found.missed { question.line += ". " + Self.bare(missed) + "." }
        let answer = try await PersonAsk.put(question, call: call)
        guard tab.pageAddress == call.askedAt, !tab.driving else {
            throw PersonRefusal("refused", "The page changed, so nothing was filled. Look again.")
        }
        switch answer {
        case .yes:
            guard let only = named.first else { return try await handOver(call, tab: tab, site: site) }
            return try await signIn(call, tab: tab, kept: only, place: place, told: false)
        case .always:
            guard let only = named.first else { return try await handOver(call, tab: tab, site: site) }
            if only.item == nil { AgentSignIns.shared.allow(only.user, site: site) }
            return try await signIn(call, tab: tab, kept: only, place: place, told: false)
        case .picked(let index):
            guard named.indices.contains(index) else { throw PersonAsk.saidNo }
            return try await signIn(call, tab: tab, kept: named[index], place: place, told: false)
        case .never:
            AgentSites.shared.set(.never, for: site)
            throw PersonRefusal("never_here", "The person said never here. Leave \(site).")
        case .no:
            throw PersonAsk.saidNo
        case .dropped:
            throw PersonAsk.unanswered
        }
    }

    static func signIn(_ call: PersonCall, tab: Tab, kept: Kept, place: URL, told: Bool) async throws -> [String: Any] {
        let fromOnePassword = kept.item != nil
        if fromOnePassword { call.channel?.send(["event": "asking", "message": "Asking 1Password for the password"]) }
        let read: Login?
        if fromOnePassword {
            switch await OnePassword.fetch(kept) {
            case .login(let login): read = login
            case .refused(let why, let locked): throw onePasswordRefusal(why, locked: locked)
            }
        } else {
            read = await call.box.loginSecret(kept)
        }
        guard let login = read else { throw PersonRefusal("failed", "The keychain refused it") }
        guard tab.pageAddress == place, !tab.driving else {
            throw PersonRefusal("refused", "The page changed, so nothing was filled. Look again.")
        }
        let placeHost = place.host()?.lowercased() ?? ""
        if fromOnePassword { tab.keptFill = FillMark(host: placeHost, user: login.user, password: login.password) }
        AgentSignInRecord.note(call.link?.id, site: AgentSites.site(of: place) ?? placeHost, item: kept.item)
        call.box.acting(tab, "Signing in")
        let state = await tab.signIn(login, on: place)
        guard let state else { throw PersonRefusal("failed", "There's no sign-in form on that page to fill") }
        let link = call.link
        AgentSignInRecord.note(link?.id, site: AgentSites.site(of: place) ?? place.host()?.lowercased() ?? "")
        let used = AgentUse(agent: link?.name ?? "An agent", folder: link?.folder.map { ($0 as NSString).lastPathComponent }, at: Date())
        if !fromOnePassword, used.notes(over: kept.agent) { _ = await Vault.off { Vault.note(used, on: kept) } }
        if told { (call.tab?.browser ?? call.browser).announce("\(link?.name ?? "An agent") signed in as \(kept.user)", seconds: 6) }
        var look: AgentChange.Look?
        var now = state
        if state == .signedIn {
            await settle(tab)
            look = await call.box.look(tab, task: link?.id)
            now = await after(tab, needs: look?.needs)
        } else {
            look = await call.box.look(tab, task: link?.id)
        }
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        var answer: [String: Any] = ["message": now.words(kept.user, host: tab.pageAddress?.host() ?? ""), "account": kept.user, "now": now.rawValue,
                                     "tab": id, "url": AgentSecrets.shown(tab.pageAddress), "title": tab.title]
        if fromOnePassword { answer["from"] = "1password" }
        if let look { answer["lines"] = look.text() }
        return answer
    }

    static func settle(_ tab: Tab) async {
        try? await Task.sleep(for: .milliseconds(300))
        let end = Date().addingTimeInterval(8)
        while tab.loading, Date() < end { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(400))
    }

    static func after(_ tab: Tab, needs: String?) async -> AgentSignInState {
        switch needs {
        case "captcha": return .captcha
        case "code": return .code
        case "password": return .password
        default: break
        }
        switch await tab.searchValue("window.__officeForms ? window.__officeForms.after() : ''") as? String {
        case "captcha": return .captcha
        case "code": return .code
        case "passkey": return .passkey
        case "password": return .password
        default: return .signedIn
        }
    }

    static func handing(_ call: PersonCall) -> Double {
        let wait = call.request["wait"] as? Double ?? (call.request["wait"] as? Int).map(Double.init) ?? 0
        return wait > 0 ? min(wait, AgentHandoff.seconds.standard) : AgentHandoff.seconds.standard
    }

    static func handOver(_ call: PersonCall, tab: Tab, site: String) async throws -> [String: Any] {
        guard let link = call.link else {
            throw PersonRefusal("needs_task", "This needs the person's yes, and only a connected agent can ask for it. Nothing was done.")
        }
        var question = AgentQuestion(kind: .choice(["Done"]), title: AgentQuestion.clean("Sign in on \(site)", limit: AgentHandoff.reasonLimit))
        question.task = link.id
        question.tab = tab.id
        question.site = site
        question.quoteLabel = "Handed to you"
        let seconds = handing(call)
        call.channel?.send(["event": "asking", "message": "Waiting for the person to sign in, in Broadway"])
        let mood = tab.agentMood
        tab.agentMood = .waving
        let started = Date()
        let asking = Task { @MainActor in await AgentDesk.shared.ask(question) }
        var ending = AgentHandoff.ending(await AgentPatience.race(asking, seconds: seconds), optional: false)
        AgentDesk.shared.take(question.id, .dropped)
        if ending == .unanswered, tab.driving {
            let left = max(0, seconds - Date().timeIntervalSince(started))
            if await AgentDriving.settled(tab, patience: .milliseconds(Int(left * 1000))) { ending = .done }
        }
        if tab.agentMood == .waving { tab.agentMood = mood == .waving ? .reading : mood }
        guard ending != .unanswered else {
            throw PersonRefusal("needs_you", "The person didn't give the tab back within \(Int(seconds)) s",
                                hint: "Tell the person, then run broadway handoff \"Sign in\"")
        }
        tab.handedBack = false
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        var answer: [String: Any] = ["message": "The person had the tab to sign in and gave it back after \(Int(Date().timeIntervalSince(started))) s. Look at the page before you go on.",
                                     "tab": id, "url": AgentSecrets.shown(tab.pageAddress), "title": tab.title]
        if let look = await call.box.look(tab, task: link.id) { answer["lines"] = look.text() }
        return answer
    }
}

@MainActor
enum PersonFill {
    static func run(_ call: PersonCall, what: String) async throws -> [String: Any] {
        let tab = try call.page.tab
        guard !tab.asleep, tab.isWeb else { throw PersonRefusal("not_a_page", "That tab isn't showing a web page") }
        let site = AgentSites.site(of: tab.pageAddress)
        if AgentSites.shared.rule(for: site) == .never {
            throw PersonRefusal("never_here", "The person never lets agents act on \(site ?? "this site"). Leave it.")
        }
        let book = call.box.book
        let none = what == "card" ? book.cards.isEmpty : book.addresses.isEmpty && !book.hasProfile
        var question = AgentQuestion(kind: .approval(.address), title: PersonAsk.title(noun: "fill", verb: what, site: site))
        question.site = site
        question.offersAlways = false
        if none {
            question.line = what == "card" ? "Broadway has no saved card" : "Broadway has no saved name or address"
            question.yesWord = "Fill In Myself"
        }
        let answer = try await PersonAsk.put(question, call: call)
        switch answer {
        case .yes, .always, .picked:
            break
        case .never:
            if let site { AgentSites.shared.set(.never, for: site) }
            throw PersonRefusal("never_here", "The person said never here. Leave \(site ?? "this site").")
        case .no:
            throw PersonAsk.saidNo
        case .dropped:
            throw PersonAsk.unanswered
        }
        guard tab.pageAddress == call.askedAt, !tab.driving else {
            throw PersonRefusal("refused", "The page changed, so nothing was filled. Look again.")
        }
        guard !none else { return try await handOver(call, tab: tab, site: site ?? "this page", what: what) }
        let outcome = await call.box.autofill(tab, what: what)
        if outcome.failed {
            let text = outcome.text ?? "That didn't work"
            throw PersonRefusal(outcome.code ?? ToolFailure.code(text), text, hint: outcome.hint)
        }
        return ToolReply.data(outcome)
    }

    static func handOver(_ call: PersonCall, tab: Tab, site: String, what: String) async throws -> [String: Any] {
        guard let link = call.link else {
            throw PersonRefusal("needs_task", "This needs the person's yes, and only a connected agent can ask for it. Nothing was done.")
        }
        let words = what == "card" ? "Fill in your card on \(site)" : "Fill in your details on \(site)"
        var question = AgentQuestion(kind: .choice(["Done"]), title: AgentQuestion.clean(words, limit: AgentHandoff.reasonLimit))
        question.task = link.id
        question.tab = tab.id
        question.site = site
        question.quoteLabel = "Handed to you"
        let seconds = PersonSignIn.handing(call)
        call.channel?.send(["event": "asking", "message": "Waiting for the person to fill it in, in Broadway"])
        let mood = tab.agentMood
        tab.agentMood = .waving
        let started = Date()
        let asking = Task { @MainActor in await AgentDesk.shared.ask(question) }
        let ending = AgentHandoff.ending(await AgentPatience.race(asking, seconds: seconds), optional: false)
        AgentDesk.shared.take(question.id, .dropped)
        if tab.agentMood == .waving { tab.agentMood = mood == .waving ? .reading : mood }
        guard ending != .unanswered else {
            throw PersonRefusal("needs_you", "The person didn't give the tab back within \(Int(seconds)) s",
                                hint: "Tell the person, then run broadway handoff \"\(words)\"")
        }
        tab.handedBack = false
        let what = what == "card" ? "Broadway keeps no card, so the person had the tab to fill it in" : "Broadway keeps no name or address, so the person had the tab to fill them in"
        return ["message": "\(what) and gave it back after \(Int(Date().timeIntervalSince(started))) s. Look at the page before you go on.",
                "tab": String(tab.id.uuidString.prefix(8)).lowercased(), "url": AgentSecrets.shown(tab.pageAddress), "title": tab.title]
    }
}

extension PersonAsk {
    static let saidNo = PersonRefusal("said_no", "The person said not now. Nothing was done.")
    static let unanswered = PersonRefusal("needs_you", "Nobody answered in Broadway. Nothing was done.")

    static func put(_ asked: AgentQuestion, call: PersonCall) async throws -> AgentAnswer {
        let request = call.request
        var wait = request["wait"] as? Double ?? (request["wait"] as? Int).map(Double.init) ?? 0
        if let link = call.link, wait == 0 { wait = AgentLinks.shared.patience(link.id) }
        guard reachable(wait: wait, request: request) else {
            throw PersonRefusal("needs_you", "This needs the person's yes in Broadway. Nothing was done.",
                                hint: "Tell the person, or run it with --wait-person MIN while they are at Broadway")
        }
        let channel = call.channel
        if channel?.gone == true { throw unanswered }
        var question = asked
        question.tab = call.tab?.tab.id
        question.quote = AgentQuestion.clean(call.line)
        question.quoteLabel = call.link.map { "From \($0.title)" } ?? "From a terminal"
        question.task = call.link?.id
        let id = question.id
        channel?.send(["event": "asking", "message": "Waiting for your yes in Broadway"])
        channel?.left = { AgentDesk.shared.take(id, .dropped) }
        let clock = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { AgentDesk.shared.take(id, .dropped) }
        }
        let answer = await AgentDesk.shared.ask(question)
        clock.cancel()
        channel?.left = nil
        return answer
    }
}

extension BrowserToolbox {
    func signIns(for place: URL) async -> [Kept] {
        guard let host = place.host()?.lowercased(), !host.isEmpty else { return [] }
        var seen = Set<String>()
        return await logins(host).filter { AgentSignInMatch.fits($0, page: place) && seen.insert($0.user).inserted }
    }

    func signInAccounts(for place: URL, onePassword: Bool) async -> (kept: [Kept], missed: String?, late: Bool) {
        let own = await signIns(for: place)
        guard onePassword, place.host()?.isEmpty == false else { return (own, nil, false) }
        switch await OnePasswordLookups.shared.lookup(place) {
        case .found(let more):
            var seen = Set(own.map(\.user))
            return (own + more.filter { AgentSignInMatch.fits($0, page: place) && seen.insert($0.user).inserted }, nil, false)
        case .late:
            return (own, "1Password didn't answer within \(Int(OnePassword.listBound)) s", true)
        case .trouble(let words):
            return (own, words, false)
        }
    }
}

@MainActor
extension Tab {
    func searchValue(_ script: String) async -> Any? {
        await withCheckedContinuation { done in
            web.evaluateInSearch(script) { done.resume(returning: $0) }
        }
    }

    private static func literal(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private func guarded(_ script: String, on page: URL) async -> Any? {
        guard let scheme = page.scheme?.lowercased(), let host = page.host()?.lowercased() else { return nil }
        let port = page.port.map(String.init) ?? ""
        let still = "location.protocol === \(Self.literal(scheme + ":")) && location.hostname.toLowerCase() === \(Self.literal(host)) && location.port === \(Self.literal(port)) && window.__officeForms && "
        return await searchValue(still + script)
    }

    func signIn(_ login: Login, on page: URL) async -> AgentSignInState? {
        seal(login.password)
        let ready = Date().addingTimeInterval(5)
        while Date() < ready {
            if !loading, await searchValue("!!window.__officeForms") as? Bool == true { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let user = Self.literal(login.user)
        let password = Self.literal(login.password)
        if await guarded("window.__officeForms.fill(\(user), \(password))", on: page) as? Bool == true {
            return await guarded("window.__officeForms.send()", on: page) as? Bool == true ? .signedIn : .unsent
        }
        guard await guarded("window.__officeForms.name(\(user))", on: page) as? Bool == true else { return nil }
        guard await guarded("window.__officeForms.send()", on: page) as? Bool == true else { return .unsent }
        let end = Date().addingTimeInterval(10)
        try? await Task.sleep(for: .milliseconds(300))
        while Date() < end {
            if !loading, await guarded("window.__officeForms.hasPassword()", on: page) as? Bool == true {
                guard await guarded("window.__officeForms.fill(\(user), \(password))", on: page) as? Bool == true else { break }
                return await guarded("window.__officeForms.send()", on: page) as? Bool == true ? .signedIn : .unsent
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let now = pageAddress, let host = now.host()?.lowercased(), AgentSignInMatch.bare(host) != AgentSignInMatch.bare(page.host() ?? "") { return .moved }
        return .signedIn
    }
}
